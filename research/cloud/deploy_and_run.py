#!/usr/bin/env python3
"""Full-lifecycle GPU deployment for The Particle Engine research pipeline.

One command to go from "I want trained creatures" to "here are the genomes
on my machine." Creates a ThunderCompute instance, bootstraps it, uploads
code, runs the pipeline, downloads results, and tears down the instance.

Usage:
    # Full pipeline on A100 (default)
    python research/cloud/deploy_and_run.py --mode full

    # Creature training only
    python research/cloud/deploy_and_run.py --mode creatures --gpu a100xl

    # Budget-friendly quick test on A6000
    python research/cloud/deploy_and_run.py --mode quick --gpu a6000

    # Physics optimization (CPU is fine)
    python research/cloud/deploy_and_run.py --mode physics --gpu a6000

    # Just bootstrap an instance (don't run pipeline)
    python research/cloud/deploy_and_run.py --bootstrap-only --gpu a100xl

    # Destroy any lingering instance
    python research/cloud/deploy_and_run.py --destroy

    # Check status
    python research/cloud/deploy_and_run.py --status
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent.parent
STATE_FILE = SCRIPT_DIR / ".instance_state.json"
KEY_FILE = Path.home() / ".ssh" / "thundercompute"

# ThunderCompute API
API_BASE = "https://api.thundercompute.com:8443/v1"
TOKEN = os.environ.get(
    "TNR_API_TOKEN",
    "e53b9e616ded72419e90d54627e310f99a8b737ab53b557e61716d7e77d524ed",
)

# GPU pricing for cost estimates
GPU_PRICING = {
    "a6000": 0.27,
    "a100xl": 1.79,  # production mode
    "h100": 2.49,    # production mode
}

# Friendly name -> API gpu_type
GPU_MAP = {
    "a6000": "a6000",
    "a100": "a100xl",
    "a100xl": "a100xl",
    "h100": "h100",
}

# Result directories to download (remote path -> local path)
RESULT_PATHS = {
    "research/cloud/trained_genomes/": "research/trained_genomes/",
    "research/cloud/shader_results/": "research/cloud/shader_results/",
    "research/cloud/chemistry_results/": "research/cloud/chemistry_results/",
    "research/cloud/audio_output/": "research/cloud/audio_output/",
    "research/cloud/style_results/": "research/cloud/style_results/",
    "research/cloud/worldgen_results/": "research/cloud/worldgen_results/",
    "research/cloud/regression_results/": "research/cloud/regression_results/",
    "research/cloud/atlas_output/": "research/cloud/atlas_output/",
    "research/cloud_proper_study.db": "research/cloud_proper_study.db",
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

class Colors:
    RED = "\033[0;31m"
    GREEN = "\033[0;32m"
    YELLOW = "\033[1;33m"
    BLUE = "\033[0;34m"
    NC = "\033[0m"


def log(msg: str):
    ts = time.strftime("%H:%M:%S")
    print(f"{Colors.BLUE}[{ts}]{Colors.NC} {msg}", flush=True)


def success(msg: str):
    ts = time.strftime("%H:%M:%S")
    print(f"{Colors.GREEN}[{ts}] OK:{Colors.NC} {msg}", flush=True)


def warn(msg: str):
    ts = time.strftime("%H:%M:%S")
    print(f"{Colors.YELLOW}[{ts}] WARN:{Colors.NC} {msg}", flush=True)


def fail(msg: str):
    ts = time.strftime("%H:%M:%S")
    print(f"{Colors.RED}[{ts}] FAIL:{Colors.NC} {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def api(method: str, path: str, data: dict | None = None) -> dict:
    """Make a ThunderCompute API call via curl."""
    url = f"{API_BASE}{path}"
    cmd = [
        "curl", "-s", "-X", method,
        "-H", f"Authorization: Bearer {TOKEN}",
        "-H", "Content-Type: application/json",
    ]
    if data:
        cmd += ["-d", json.dumps(data)]
    cmd.append(url)

    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if result.returncode != 0:
        fail(f"API call failed: {result.stderr}")

    try:
        return json.loads(result.stdout) if result.stdout.strip() else {}
    except json.JSONDecodeError:
        fail(f"API parse error: {result.stdout[:300]}")
        return {}


def ssh_cmd(host: str, port: int, command: str, key: Path = KEY_FILE,
            timeout: int = 600, stream: bool = False) -> subprocess.CompletedProcess | None:
    """Run a command over SSH."""
    base = [
        "ssh", "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "-i", str(key),
        "-p", str(port),
        f"ubuntu@{host}",
        command,
    ]

    if stream:
        proc = subprocess.Popen(base, stdout=sys.stdout, stderr=sys.stderr)
        proc.wait()
        return None

    return subprocess.run(base, capture_output=True, text=True, timeout=timeout)


def scp_upload(host: str, port: int, local: str, remote: str, key: Path = KEY_FILE):
    """Upload a file/directory via SCP."""
    cmd = [
        "scp", "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "-i", str(key),
        "-P", str(port),
        "-r", local,
        f"ubuntu@{host}:{remote}",
    ]
    subprocess.run(cmd, capture_output=True, text=True, timeout=300)


def scp_download(host: str, port: int, remote: str, local: str, key: Path = KEY_FILE):
    """Download a file/directory via SCP."""
    Path(local).parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "scp", "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "-i", str(key),
        "-P", str(port),
        "-r",
        f"ubuntu@{host}:{remote}",
        local,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    return result.returncode == 0


def save_state(state: dict):
    """Save instance state to disk."""
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)


def load_state() -> dict | None:
    """Load instance state from disk."""
    if not STATE_FILE.exists():
        return None
    with open(STATE_FILE) as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# Instance lifecycle
# ---------------------------------------------------------------------------

def create_instance(gpu_type: str, vcpus: int = 18, disk_gb: int = 200) -> dict:
    """Create a ThunderCompute instance."""
    gpu = GPU_MAP.get(gpu_type, gpu_type)
    log(f"Creating instance: {gpu} x1, {vcpus} vCPUs, {disk_gb}GB disk...")

    # Read SSH public key for instance access
    pub_key_file = KEY_FILE.with_suffix(".pub")
    if pub_key_file.exists():
        pub_key = pub_key_file.read_text().strip()
    else:
        pub_key = ""
        warn(f"No SSH public key at {pub_key_file}")

    result = api("POST", "/instances/create", {
        "gpu_type": gpu,
        "num_gpus": 1,
        "cpu_cores": vcpus,
        "disk_size_gb": disk_gb,
        "mode": "production",
        "template": "base",
        "public_key": pub_key,
    })

    instance_id = result.get("uuid", "")
    identifier = result.get("identifier", 0)
    private_key = result.get("key", "")

    if not instance_id:
        fail(f"Failed to create instance: {result}")

    state = {
        "instance_id": instance_id,
        "identifier": identifier,
        "gpu_type": gpu,
        "vcpus": vcpus,
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "start_time": time.time(),
    }
    save_state(state)

    if private_key:
        KEY_FILE.write_text(private_key)
        os.chmod(str(KEY_FILE), 0o600)

    success(f"Instance created: {instance_id}")
    return state


def get_instance_connection(instance_id: str) -> tuple[str, int] | None:
    """Get SSH connection details for an instance."""
    result = api("GET", "/instances/list")
    for key, inst in result.items():
        if not isinstance(inst, dict):
            continue
        if inst.get("uuid") == instance_id or inst.get("name") == instance_id:
            ip = inst.get("ip", "") or inst.get("ip_address", "")
            port = inst.get("port", 22)
            status = inst.get("status", "")
            if ip and port and status == "RUNNING":
                return (ip, int(port))
    return None


def wait_for_ready(instance_id: str, timeout: int = 600) -> tuple[str, int]:
    """Wait for instance to be ready and return (host, port)."""
    log("Waiting for instance to be ready...")
    start = time.time()
    while time.time() - start < timeout:
        conn = get_instance_connection(instance_id)
        if conn:
            host, port = conn
            # Try SSH connection
            try:
                result = ssh_cmd(host, port, "echo ready", timeout=10)
                if result and result.returncode == 0:
                    success(f"Instance ready at {host}:{port}")
                    return (host, port)
            except (subprocess.TimeoutExpired, Exception):
                pass
        print(".", end="", flush=True)
        time.sleep(15)
    print(flush=True)
    fail(f"Instance not ready after {timeout}s")
    return ("", 0)  # unreachable


def destroy_instance(state: dict | None = None):
    """Destroy instance and clean up."""
    if state is None:
        state = load_state()
    if not state or not state.get("instance_id"):
        print("No instance to destroy.", flush=True)
        return

    instance_id = state["instance_id"]
    # ThunderCompute uses numeric identifier (0, 1, ...) not UUID for delete
    identifier = state.get("identifier", 0)
    log(f"Destroying instance {instance_id} (identifier={identifier})...")
    api("POST", f"/instances/{identifier}/delete")

    # Log cost
    if "start_time" in state:
        duration = int(time.time() - state["start_time"])
        gpu = state.get("gpu_type", "unknown")
        mode = state.get("mode", "unknown")
        try:
            from cost_tracker import log_session
            log_session(gpu, mode, duration)
        except Exception:
            rate = GPU_PRICING.get(gpu, 0)
            cost = rate * duration / 3600
            log(f"Session cost: ${cost:.4f} ({duration // 60}m on {gpu})")

    STATE_FILE.unlink(missing_ok=True)
    KEY_FILE.unlink(missing_ok=True)
    success("Instance destroyed")


def show_status():
    """Show current instance status."""
    state = load_state()
    if state and state.get("instance_id"):
        elapsed = time.time() - state.get("start_time", time.time())
        gpu = state.get("gpu_type", "?")
        rate = GPU_PRICING.get(gpu, 0)
        cost = rate * elapsed / 3600
        print(f"\nLocal state:", flush=True)
        print(f"  Instance: {state['instance_id']}", flush=True)
        print(f"  GPU:      {gpu}", flush=True)
        print(f"  Created:  {state.get('created', '?')}", flush=True)
        print(f"  Uptime:   {int(elapsed) // 60}m", flush=True)
        print(f"  Cost:     ~${cost:.2f}", flush=True)
    else:
        print("No local instance state.", flush=True)

    print("\nAPI instances:", flush=True)
    result = api("GET", "/instances/list")
    found = False
    for key, inst in result.items():
        if not isinstance(inst, dict):
            continue
        found = True
        iid = inst.get("uuid", inst.get("name", "?"))
        port = inst.get("port", "?")
        gpu = inst.get("gpu_type", "?")
        print(f"  {iid}  port={port}  gpu={gpu}", flush=True)
    if not found:
        print("  (none)", flush=True)


# ---------------------------------------------------------------------------
# Pipeline execution
# ---------------------------------------------------------------------------

def run_bootstrap(host: str, port: int):
    """Bootstrap the remote instance."""
    log("Running bootstrap on remote instance...")

    # Upload bootstrap script
    bootstrap_path = SCRIPT_DIR / "bootstrap.sh"
    scp_upload(host, port, str(bootstrap_path), "~/bootstrap.sh")

    # Run it
    ssh_cmd(host, port, "bash ~/bootstrap.sh", timeout=600, stream=True)
    success("Bootstrap complete")


def upload_code(host: str, port: int):
    """Upload latest project code to the instance."""
    log("Uploading latest code...")

    # Upload key directories
    dirs_to_upload = [
        "research/cloud/",
        "research/tests/",
        "research/conftest.py",
        "research/physics_oracle.py",
        "research/visual_oracle.py",
        "research/export_frame.dart",
        "research/neat_benchmark.dart",
        "lib/",
        "pubspec.yaml",
    ]

    for d in dirs_to_upload:
        local = str(PROJECT_DIR / d)
        if Path(local).exists():
            remote = f"~/pe/{d}"
            ssh_cmd(host, port, f"mkdir -p ~/pe/{Path(d).parent}")
            scp_upload(host, port, local, remote)

    success("Code uploaded")


def run_pipeline(host: str, port: int, mode: str, env_vars: str = ""):
    """Run the pipeline on the remote instance."""
    log(f"Starting pipeline: mode={mode}")

    cmd = (
        f"source ~/research_env/bin/activate && "
        f"cd ~/pe && "
        f"export PATH=\"$PATH:/usr/lib/dart/bin\" && "
        f"{env_vars} "
        f"bash research/cloud/run_everything.sh {mode}"
    )

    ssh_cmd(host, port, cmd, timeout=14400, stream=True)
    success(f"Pipeline {mode} complete")


def download_results(host: str, port: int):
    """Download all results from the remote instance."""
    log("Downloading results...")

    downloaded = []
    for remote_path, local_path in RESULT_PATHS.items():
        remote = f"~/pe/{remote_path}"
        local = str(PROJECT_DIR / local_path)

        # Check if remote path exists
        check = ssh_cmd(host, port, f"test -e {remote} && echo exists", timeout=10)
        if check and "exists" in (check.stdout or ""):
            Path(local).parent.mkdir(parents=True, exist_ok=True)
            if scp_download(host, port, remote, local):
                downloaded.append(local_path)
                log(f"  Downloaded: {local_path}")

    # Also grab the pipeline log
    scp_download(host, port, "~/pipeline.log", str(PROJECT_DIR / "research/cloud/last_pipeline.log"))

    success(f"Downloaded {len(downloaded)} result sets")
    return downloaded


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Deploy and run The Particle Engine research pipeline on GPU cloud"
    )
    parser.add_argument("--mode", default="full",
                        help="Pipeline mode: full, classic, v2, creatures, physics, shaders, "
                             "chemistry, audio, style, worldgen, regression, textures, quick")
    parser.add_argument("--gpu", default="a100xl",
                        help="GPU type: a6000, a100, a100xl, h100")
    parser.add_argument("--vcpus", type=int, default=8, help="Number of vCPUs")
    parser.add_argument("--disk", type=int, default=100, help="Disk size GB")
    parser.add_argument("--budget", type=float, default=50.0, help="Budget limit ($)")
    parser.add_argument("--no-destroy", action="store_true",
                        help="Don't destroy instance after run")
    parser.add_argument("--bootstrap-only", action="store_true",
                        help="Just bootstrap, don't run pipeline")
    parser.add_argument("--destroy", action="store_true",
                        help="Destroy existing instance")
    parser.add_argument("--status", action="store_true",
                        help="Show instance status")
    parser.add_argument("--env", default="",
                        help="Extra env vars for pipeline (e.g., 'CREATURE_GENS=1000')")

    args = parser.parse_args()

    if args.status:
        show_status()
        return

    if args.destroy:
        destroy_instance()
        return

    # Budget check
    gpu = GPU_MAP.get(args.gpu, args.gpu)
    rate = GPU_PRICING.get(gpu, 0)
    estimated_hours = {"full": 3, "classic": 2, "v2": 1, "quick": 0.25,
                       "creatures": 1.5, "physics": 0.5}.get(args.mode, 1)
    estimated_cost = rate * estimated_hours

    log(f"Estimated cost: ${estimated_cost:.2f} ({gpu} x {estimated_hours}h @ ${rate}/hr)")

    # Check existing cost log
    try:
        sys.path.insert(0, str(SCRIPT_DIR))
        from cost_tracker import load_sessions
        sessions = load_sessions()
        spent = sum(s["cost_usd"] for s in sessions)
        if spent + estimated_cost > args.budget:
            warn(f"This would exceed budget: ${spent:.2f} spent + ${estimated_cost:.2f} = "
                 f"${spent + estimated_cost:.2f} > ${args.budget:.2f}")
            resp = input("Continue anyway? [y/N] ").strip().lower()
            if resp != "y":
                print("Aborted.", flush=True)
                return
    except Exception:
        pass

    pipeline_start = time.time()

    # Step 1: Create instance
    state = create_instance(gpu, args.vcpus, args.disk)
    state["mode"] = args.mode

    try:
        # Step 2: Wait for ready
        host, port = wait_for_ready(state["instance_id"])

        # Step 3: Bootstrap
        run_bootstrap(host, port)

        if args.bootstrap_only:
            log(f"Instance ready. Connect with:")
            log(f"  ssh -i {KEY_FILE} -p {port} ubuntu@{host}")
            save_state(state)
            return

        # Step 4: Upload latest code
        upload_code(host, port)

        # Step 5: Run pipeline
        env_str = args.env + " " if args.env else ""
        run_pipeline(host, port, args.mode, env_str)

        # Step 6: Download results
        downloaded = download_results(host, port)

        pipeline_end = time.time()
        duration = int(pipeline_end - pipeline_start)
        cost = rate * duration / 3600

        # Step 7: Log cost
        try:
            from cost_tracker import log_session
            log_session(gpu, args.mode, duration)
        except Exception:
            pass

        # Step 8: Destroy (unless --no-destroy)
        if not args.no_destroy:
            destroy_instance(state)
        else:
            save_state(state)
            log(f"Instance left running. Destroy with: python {__file__} --destroy")

        # Summary
        print(flush=True)
        print("=" * 50, flush=True)
        print("  DEPLOYMENT COMPLETE", flush=True)
        print("=" * 50, flush=True)
        print(f"  Mode:     {args.mode}", flush=True)
        print(f"  GPU:      {gpu}", flush=True)
        print(f"  Duration: {duration // 60}m {duration % 60}s", flush=True)
        print(f"  Cost:     ${cost:.2f}", flush=True)
        print(flush=True)
        if downloaded:
            print("  Downloaded results:", flush=True)
            for d in downloaded:
                print(f"    {d}", flush=True)
        print("=" * 50, flush=True)

    except KeyboardInterrupt:
        warn("Interrupted!")
        if not args.no_destroy:
            warn("Destroying instance to avoid charges...")
            destroy_instance(state)
        else:
            save_state(state)
            warn(f"Instance still running! Destroy with: python {__file__} --destroy")
        sys.exit(1)

    except Exception as e:
        fail_msg = str(e)
        warn(f"Pipeline failed: {fail_msg}")
        # Log failed session
        try:
            duration = int(time.time() - pipeline_start)
            from cost_tracker import log_session
            log_session(gpu, args.mode, duration, note=f"FAILED: {fail_msg}", success=False)
        except Exception:
            pass

        if not args.no_destroy:
            warn("Destroying instance to avoid charges...")
            destroy_instance(state)
        sys.exit(1)


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        print("Self-test: imports OK", flush=True)
        assert len(GPU_PRICING) > 0, "No GPU pricing"
        print("Self-test: PASSED", flush=True)
        sys.exit(0)
    main()
