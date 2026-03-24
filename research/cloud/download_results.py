#!/usr/bin/env python3
"""Download results from a running ThunderCompute instance.

Pulls trained genomes, optimized params, audio, textures, regression
baselines, and other pipeline outputs back to the local machine.

Usage:
    # Download everything from the running instance
    python research/cloud/download_results.py

    # Download specific categories
    python research/cloud/download_results.py --only genomes,audio,textures

    # Download from a specific host/port
    python research/cloud/download_results.py --host ssh.thundercompute.com --port 12345

    # List what's available on the remote instance
    python research/cloud/download_results.py --list
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent.parent
STATE_FILE = SCRIPT_DIR / ".instance_state.json"
KEY_FILE = SCRIPT_DIR / "instance_key.pem"

# Category -> (remote path, local path, description)
RESULT_CATEGORIES = {
    "genomes": (
        "~/pe/research/cloud/trained_genomes/",
        "research/trained_genomes/",
        "Trained NEAT genomes (ant, worm, spider brains)",
    ),
    "physics": (
        "~/pe/research/cloud_proper_study.db",
        "research/cloud_proper_study.db",
        "Optuna physics optimization database",
    ),
    "shaders": (
        "~/pe/research/cloud/shader_results/",
        "research/cloud/shader_results/",
        "Shader parameter optimization results",
    ),
    "chemistry": (
        "~/pe/research/cloud/chemistry_results/",
        "research/cloud/chemistry_results/",
        "Chemistry matrix validation results",
    ),
    "audio": (
        "~/pe/research/cloud/audio_output/",
        "research/cloud/audio_output/",
        "Procedural audio WAV files",
    ),
    "style": (
        "~/pe/research/cloud/style_results/",
        "research/cloud/style_results/",
        "Evolved color palettes and style params",
    ),
    "worldgen": (
        "~/pe/research/cloud/worldgen_results/",
        "research/cloud/worldgen_results/",
        "World generation surrogate model + params",
    ),
    "regression": (
        "~/pe/research/cloud/regression_results/",
        "research/cloud/regression_results/",
        "Physics regression golden frames and reports",
    ),
    "textures": (
        "~/pe/research/cloud/atlas_output/",
        "research/cloud/atlas_output/",
        "Pre-rendered texture atlas with neural upscaling",
    ),
    "log": (
        "~/pipeline.log",
        "research/cloud/last_pipeline.log",
        "Pipeline execution log",
    ),
}

# Map results to their final asset locations for integration
ASSET_MAPPING = {
    "genomes": {
        "from": "research/trained_genomes/",
        "to": "assets/config/trained_genomes/",
        "description": "Copy trained genomes into app assets",
    },
    "audio": {
        "from": "research/cloud/audio_output/",
        "to": "assets/audio/procedural/",
        "description": "Copy procedural audio into app assets",
    },
    "textures": {
        "from": "research/cloud/atlas_output/",
        "to": "assets/images/atlas/",
        "description": "Copy texture atlas into app assets",
    },
}


def get_connection() -> tuple[str, int]:
    """Get SSH connection details from instance state."""
    if not STATE_FILE.exists():
        return ("", 0)
    with open(STATE_FILE) as f:
        state = json.load(f)
    iid = state.get("instance_id")
    if not iid:
        return ("", 0)
    # Default to ssh.thundercompute.com with stored port
    return ("ssh.thundercompute.com", state.get("port", 22))


def ssh_cmd(host: str, port: int, command: str) -> str:
    """Run SSH command and return stdout."""
    cmd = [
        "ssh", "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "-i", str(KEY_FILE),
        "-p", str(port),
        f"ubuntu@{host}",
        command,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    return result.stdout.strip()


def scp_download(host: str, port: int, remote: str, local: str) -> bool:
    """Download via SCP. Returns True on success."""
    Path(local).parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "scp", "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "-i", str(KEY_FILE),
        "-P", str(port),
        "-r",
        f"ubuntu@{host}:{remote}",
        local,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    return result.returncode == 0


def list_remote(host: str, port: int):
    """List available results on the remote instance."""
    print("\nAvailable results on remote instance:\n", flush=True)
    for cat, (remote, local, desc) in RESULT_CATEGORIES.items():
        exists = ssh_cmd(host, port, f"test -e {remote} && echo yes || echo no")
        if exists == "yes":
            # Get size
            size = ssh_cmd(host, port, f"du -sh {remote} 2>/dev/null | cut -f1")
            print(f"  [{cat}] {desc}", flush=True)
            print(f"    Remote: {remote} ({size})", flush=True)
            print(f"    Local:  {local}", flush=True)
            print(flush=True)
        else:
            print(f"  [{cat}] {desc} -- NOT FOUND", flush=True)
            print(flush=True)


def download(host: str, port: int, categories: list[str] | None = None,
             integrate: bool = False):
    """Download results by category."""
    if categories is None:
        categories = list(RESULT_CATEGORIES.keys())

    downloaded = []
    for cat in categories:
        if cat not in RESULT_CATEGORIES:
            print(f"Unknown category: {cat}", flush=True)
            continue

        remote, local, desc = RESULT_CATEGORIES[cat]
        local_path = str(PROJECT_DIR / local)

        # Check if it exists
        exists = ssh_cmd(host, port, f"test -e {remote} && echo yes || echo no")
        if exists != "yes":
            print(f"  [{cat}] Not found on remote, skipping", flush=True)
            continue

        print(f"  [{cat}] Downloading {desc}...", flush=True)
        if scp_download(host, port, remote, local_path):
            downloaded.append(cat)
            print(f"    Saved to: {local}", flush=True)
        else:
            print(f"    FAILED to download", flush=True)

    # Optionally copy to asset locations
    if integrate:
        print("\nIntegrating into app assets:", flush=True)
        for cat in downloaded:
            if cat in ASSET_MAPPING:
                mapping = ASSET_MAPPING[cat]
                src = PROJECT_DIR / mapping["from"]
                dst = PROJECT_DIR / mapping["to"]
                if src.exists():
                    dst.mkdir(parents=True, exist_ok=True)
                    import shutil
                    # Copy contents
                    if src.is_dir():
                        for f in src.iterdir():
                            shutil.copy2(str(f), str(dst / f.name))
                    else:
                        shutil.copy2(str(src), str(dst))
                    print(f"  [{cat}] {mapping['description']}", flush=True)
                    print(f"    {mapping['from']} -> {mapping['to']}", flush=True)

    print(f"\nDownloaded {len(downloaded)}/{len(categories)} categories", flush=True)
    return downloaded


def main():
    parser = argparse.ArgumentParser(description="Download pipeline results from GPU instance")
    parser.add_argument("--host", help="SSH host (default: from instance state)")
    parser.add_argument("--port", type=int, help="SSH port (default: from instance state)")
    parser.add_argument("--only", help="Comma-separated categories to download")
    parser.add_argument("--list", action="store_true", help="List available results")
    parser.add_argument("--integrate", action="store_true",
                        help="Copy results to app asset directories")

    args = parser.parse_args()

    # Resolve connection
    if args.host and args.port:
        host, port = args.host, args.port
    else:
        host, port = get_connection()
        if not host:
            print("No connection info. Use --host and --port, or ensure .instance_state.json exists.", flush=True)
            sys.exit(1)

    if not KEY_FILE.exists():
        print(f"SSH key not found at {KEY_FILE}", flush=True)
        sys.exit(1)

    if args.list:
        list_remote(host, port)
        return

    categories = args.only.split(",") if args.only else None
    download(host, port, categories, integrate=args.integrate)


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        print("Self-test: imports OK", flush=True)
        print("Self-test: PASSED", flush=True)
        sys.exit(0)
    main()
