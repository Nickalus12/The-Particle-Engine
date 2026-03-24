#!/usr/bin/env python3
"""Launch a ThunderCompute instance for parameter optimization.

Creates an instance, waits for it to be ready, uploads the project,
runs setup, and starts the optimizer.

Usage:
    python research/cloud/launch.py                    # Default: A100, 16 vCPUs, foundation profile
    python research/cloud/launch.py --trials 5000      # More trials
    python research/cloud/launch.py --gpu h100 --vcpus 16  # Bigger instance
    python research/cloud/launch.py --mode staged      # Staged runtime optimization only
    python research/cloud/launch.py --status            # Check running instance
    python research/cloud/launch.py --destroy           # Tear down instance
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from env_utils import load_cloud_env

API_BASE = "https://api.thundercompute.com:8443"
load_cloud_env()
TOKEN = os.environ.get("TNR_API_TOKEN", "")
PROJECT_DIR = Path(__file__).resolve().parent.parent.parent
STATE_FILE = PROJECT_DIR / "research" / "cloud" / ".instance_state.json"


def api(method: str, path: str, data: dict | None = None) -> dict:
    """Make an API call to ThunderCompute via curl (bypasses Cloudflare blocks)."""
    if not TOKEN:
        print("Missing ThunderCompute API token. Set TNR_API_TOKEN or research/cloud/.thundercompute.env.")
        sys.exit(1)
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
        print(f"API error: {result.stderr}")
        sys.exit(1)

    try:
        return json.loads(result.stdout) if result.stdout.strip() else {}
    except json.JSONDecodeError:
        print(f"API parse error: {result.stdout[:200]}")
        sys.exit(1)


def create_instance(gpu_type: str, vcpus: int, disk_gb: int) -> dict:
    """Create a new ThunderCompute instance."""
    # Map friendly names to API gpu_type values
    gpu_map = {
        "a6000": "a6000",
        "a100": "a100xl",
        "h100": "h100",
    }
    gpu = gpu_map.get(gpu_type, gpu_type)

    print(f"Creating instance: {gpu} x1, {vcpus} vCPUs, {disk_gb}GB disk...")

    result = api("POST", "/instances/create", {
        "gpu_type": gpu,
        "num_gpus": 1,
        "cpu_cores": vcpus,
        "disk_size_gb": disk_gb,
        "mode": "prototyping",
        "template": "base",
    })

    instance_id = result.get("uuid") or result.get("identifier")
    private_key = result.get("key", "")

    # Save state
    state = {
        "instance_id": instance_id,
        "gpu_type": gpu_type,
        "vcpus": vcpus,
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "private_key": private_key,
    }
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)

    # Save private key for SSH
    if private_key:
        key_path = STATE_FILE.parent / "instance_key.pem"
        with open(key_path, "w") as f:
            f.write(private_key)
        os.chmod(str(key_path), 0o600)

    print(f"Instance created: {instance_id}")
    return state


def get_instance_ip(instance_id: str) -> str | None:
    """Get the IP address of a running instance."""
    result = api("GET", "/instances/list")
    # API returns {"0": {...}, "1": {...}} not a list
    for key, inst in result.items():
        if not isinstance(inst, dict):
            continue
        if inst.get("uuid") == instance_id or inst.get("name") == instance_id:
            port = inst.get("port", 0)
            if port and port > 0:
                return f"ssh.thundercompute.com -p {port}"
            return inst.get("ip_address")
    return None


def wait_for_ready(instance_id: str, timeout: int = 300) -> str:
    """Wait for instance to be ready and return IP."""
    print("Waiting for instance to be ready...", end="", flush=True)
    start = time.time()
    while time.time() - start < timeout:
        ip = get_instance_ip(instance_id)
        if ip:
            print(f" Ready! IP: {ip}")
            return ip
        print(".", end="", flush=True)
        time.sleep(10)
    print(" TIMEOUT")
    sys.exit(1)


def destroy_instance() -> None:
    """Destroy the running instance."""
    if not STATE_FILE.exists():
        print("No instance state found.")
        return

    with open(STATE_FILE) as f:
        state = json.load(f)

    instance_id = state["instance_id"]
    print(f"Destroying instance {instance_id}...")
    api("POST", f"/instances/{instance_id}/delete")
    STATE_FILE.unlink(missing_ok=True)
    (STATE_FILE.parent / "instance_key.pem").unlink(missing_ok=True)
    print("Instance destroyed.")


def show_status() -> None:
    """Show status of running instances."""
    result = api("GET", "/instances/list")
    instances = result.get("instances", [])
    if not instances:
        print("No running instances.")
        return

    print(f"\n{'ID':<20} {'IP':<16} {'GPU':<12} {'vCPUs':<8} {'RAM':<8}")
    print("-" * 64)
    for inst in instances:
        print(
            f"{inst.get('identifier', '?'):<20} "
            f"{inst.get('ip_address', '?'):<16} "
            f"{inst.get('gpu_type', '?'):<12} "
            f"{inst.get('vcpu_count', '?'):<8} "
            f"{inst.get('ram_gb', '?'):<8}"
        )
    print()


def main():
    parser = argparse.ArgumentParser(description="ThunderCompute Instance Manager")
    parser.add_argument("--gpu", default="a100", help="GPU type: a6000, a100, h100")
    parser.add_argument("--vcpus", type=int, default=16, help="Number of vCPUs")
    parser.add_argument("--disk", type=int, default=100, help="Disk size GB")
    parser.add_argument("--trials", type=int, default=2000, help="Optuna trials to run")
    parser.add_argument("--workers", type=int, default=8, help="Parallel workers")
    parser.add_argument("--extended", action="store_true", help="Extended param space")
    parser.add_argument("--mode", default="full-stack",
                        choices=["legacy", "staged", "chemistry", "full-stack"],
                        help="Unified training-system mode")
    parser.add_argument("--profile", default="a100_foundation",
                        help="Unified training profile")
    parser.add_argument("--status", action="store_true", help="Show instance status")
    parser.add_argument("--destroy", action="store_true", help="Destroy instance")
    parser.add_argument("--create-only", action="store_true", help="Create but don't start optimizer")

    args = parser.parse_args()

    if args.status:
        show_status()
        return

    if args.destroy:
        destroy_instance()
        return

    # Create instance
    state = create_instance(args.gpu, args.vcpus, args.disk)
    ip = wait_for_ready(state["instance_id"])

    if args.create_only:
        print(f"\nInstance ready at {ip}")
        print(f"Connect with: ssh -i research/cloud/instance_key.pem root@{ip}")
        return

    print(f"\nInstance ready at {ip}")
    print(f"To connect: ssh -i research/cloud/instance_key.pem root@{ip}")
    print(f"\nOn the instance, run:")
    print(f"  bash ~/particle-engine/research/cloud/setup.sh")
    print(f"  cd ~/particle-engine && source ~/optenv/bin/activate")
    print(f"  python3 research/cloud/training_system.py"
          f" --profile {args.profile} --mode {args.mode}"
          f" --workers {args.workers} --trials {args.trials}")
    print(f"\nWhen done, pull results:")
    print(f"  scp -i research/cloud/instance_key.pem root@{ip}:~/particle-engine/research/cloud/training_system_summary.json research/cloud/")
    print(f"\nThen destroy:")
    print(f"  python research/cloud/launch.py --destroy")


if __name__ == "__main__":
    main()
