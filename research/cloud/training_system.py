#!/usr/bin/env python3
"""Single entrypoint for large-scale training, calibration, and validation.

This system unifies the existing cloud runners behind one profile-driven
configuration layer backed by the shared parameter manifest.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
RESEARCH_DIR = SCRIPT_DIR.parent
PROJECT_DIR = RESEARCH_DIR.parent
CONFIG_PATH = SCRIPT_DIR / "training_profiles.json"
PLAN_PATH = SCRIPT_DIR / "last_training_plan.json"
SUMMARY_PATH = SCRIPT_DIR / "training_system_summary.json"


def load_config() -> dict[str, Any]:
    with open(CONFIG_PATH, encoding="utf-8") as f:
        return json.load(f)


def build_plan(args: argparse.Namespace) -> dict[str, Any]:
    config = load_config()
    profiles = config.get("profiles", {})
    profile_name = args.profile or config.get("default_profile")
    if profile_name not in profiles:
        raise SystemExit(f"Unknown profile: {profile_name}")

    profile = dict(profiles[profile_name])
    resolved_mode = args.mode or profile.get("mode", "full-stack")
    resolved_trials = args.trials or profile.get("trials", 2000)
    resolved_workers = args.workers or profile.get("workers", 4)
    resolved_warm_start = args.warm_start or profile.get("warm_start", False)
    resolved_multi_fidelity = args.multi_fidelity or profile.get("multi_fidelity", False)

    env = {
        **os.environ,
        "TPE_PARAMETER_MANIFEST": str((RESEARCH_DIR / "parameter_manifest.json").resolve()),
        "TPE_TRAINING_PROFILE": profile_name,
    }

    steps: list[dict[str, Any]] = []
    if resolved_mode == "legacy":
        steps.append(
            {
                "name": "legacy_cloud_optimizer",
                "cmd": [
                    sys.executable,
                    str(SCRIPT_DIR / "run_optimizer.py"),
                    "--workers",
                    str(resolved_workers),
                    "--trials",
                    str(resolved_trials),
                ],
            }
        )
    elif resolved_mode == "staged":
        cmd = [
            sys.executable,
            str(SCRIPT_DIR / "staged_optimizer.py"),
            "--full-pipeline",
            "--trials",
            str(resolved_trials),
            "--workers",
            str(resolved_workers),
        ]
        if resolved_warm_start:
            cmd.append("--warm-start")
        if resolved_multi_fidelity:
            cmd.append("--multi-fidelity")
        steps.append({"name": "staged_optimizer", "cmd": cmd})
    elif resolved_mode == "chemistry":
        steps.append(
            {
                "name": "gpu_chemistry_optimizer",
                "cmd": [
                    sys.executable,
                    str(SCRIPT_DIR / "gpu_chemistry_optimizer.py"),
                    "run",
                    "--trials",
                    str(resolved_trials),
                    "--workers",
                    str(min(resolved_workers, 4)),
                ],
            }
        )
    elif resolved_mode == "worldgen":
        steps.append(
            {
                "name": "worldgen_optimizer",
                "cmd": [
                    sys.executable,
                    str(SCRIPT_DIR / "worldgen_optimizer.py"),
                    "--trials",
                    str(resolved_trials),
                    "--workers",
                    str(min(resolved_workers, 6)),
                ],
            }
        )
    elif resolved_mode == "full-stack":
        steps.append(
            {
                "name": "gpu_validation",
                "cmd": [
                    sys.executable,
                    str(SCRIPT_DIR / "unified_physics_pipeline.py"),
                    "--validate",
                ],
            }
        )
        staged_cmd = [
            sys.executable,
            str(SCRIPT_DIR / "staged_optimizer.py"),
            "--full-pipeline",
            "--trials",
            str(resolved_trials),
            "--workers",
            str(resolved_workers),
        ]
        if resolved_warm_start:
            staged_cmd.append("--warm-start")
        if resolved_multi_fidelity:
            staged_cmd.append("--multi-fidelity")
        steps.append({"name": "staged_optimizer", "cmd": staged_cmd})
        steps.append(
            {
                "name": "gpu_chemistry_optimizer",
                "cmd": [
                    sys.executable,
                    str(SCRIPT_DIR / "gpu_chemistry_optimizer.py"),
                    "run",
                    "--trials",
                    str(max(1000, resolved_trials * 2)),
                    "--workers",
                    str(min(resolved_workers, 4)),
                ],
            }
        )
        steps.append(
            {
                "name": "worldgen_optimizer",
                "cmd": [
                    sys.executable,
                    str(SCRIPT_DIR / "worldgen_optimizer.py"),
                    "--trials",
                    str(max(1000, resolved_trials)),
                    "--workers",
                    str(min(resolved_workers, 6)),
                ],
            }
        )
    else:
        raise SystemExit(f"Unsupported mode: {resolved_mode}")

    return {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "profile": profile_name,
        "mode": resolved_mode,
        "parameter_manifest": str((RESEARCH_DIR / "parameter_manifest.json").resolve()),
        "gpu": profile.get("gpu"),
        "vcpus": profile.get("vcpus"),
        "workers": resolved_workers,
        "trials": resolved_trials,
        "warm_start": resolved_warm_start,
        "multi_fidelity": resolved_multi_fidelity,
        "steps": steps,
        "env": {
            "TPE_PARAMETER_MANIFEST": env["TPE_PARAMETER_MANIFEST"],
            "TPE_TRAINING_PROFILE": env["TPE_TRAINING_PROFILE"],
        },
    }


def save_plan(plan: dict[str, Any]) -> None:
    with open(PLAN_PATH, "w", encoding="utf-8") as f:
        json.dump(plan, f, indent=2)


def run_plan(plan: dict[str, Any]) -> dict[str, Any]:
    env = {
        **os.environ,
        **plan["env"],
    }
    results: list[dict[str, Any]] = []
    start = time.time()

    for step in plan["steps"]:
        step_start = time.time()
        result = subprocess.run(
            step["cmd"],
            cwd=str(PROJECT_DIR),
            env=env,
            capture_output=True,
            text=True,
        )
        results.append(
            {
                "name": step["name"],
                "returncode": result.returncode,
                "elapsed_seconds": round(time.time() - step_start, 2),
                "stdout_tail": result.stdout[-4000:],
                "stderr_tail": result.stderr[-4000:],
            }
        )
        if result.returncode != 0:
          break

    summary = {
        "generated_at": plan["generated_at"],
        "profile": plan["profile"],
        "mode": plan["mode"],
        "parameter_manifest": plan["parameter_manifest"],
        "elapsed_seconds": round(time.time() - start, 2),
        "results": results,
    }
    with open(SUMMARY_PATH, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Cloud training and calibration system")
    parser.add_argument("--profile", type=str, default=None,
                        help="Training profile from training_profiles.json")
    parser.add_argument("--mode", type=str, default=None,
                        choices=["legacy", "staged", "chemistry", "worldgen", "full-stack"],
                        help="Override the profile mode")
    parser.add_argument("--trials", type=int, default=None,
                        help="Override trial count")
    parser.add_argument("--workers", type=int, default=None,
                        help="Override worker count")
    parser.add_argument("--warm-start", action="store_true",
                        help="Enable warm-start even if the profile disables it")
    parser.add_argument("--multi-fidelity", action="store_true",
                        help="Enable multi-fidelity even if the profile disables it")
    parser.add_argument("--plan-only", action="store_true",
                        help="Only write and print the resolved plan")

    args = parser.parse_args()
    plan = build_plan(args)
    save_plan(plan)
    print(json.dumps(plan, indent=2))

    if args.plan_only:
        return

    summary = run_plan(plan)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
