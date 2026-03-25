#!/usr/bin/env python3
"""Single entrypoint for large-scale training, calibration, and validation.

This system unifies the existing cloud runners behind one profile-driven
configuration layer backed by the shared parameter manifest.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import fcntl
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from system_profile import (  # noqa: E402
    profile_label,
    resolve_worker_count,
    summarize_profile,
)

SCRIPT_DIR = Path(__file__).resolve().parent
RESEARCH_DIR = SCRIPT_DIR.parent
PROJECT_DIR = RESEARCH_DIR.parent
CONFIG_PATH = SCRIPT_DIR / "training_profiles.json"
PLAN_PATH = SCRIPT_DIR / "last_training_plan.json"
SUMMARY_PATH = SCRIPT_DIR / "training_system_summary.json"
LOCK_PATH = SCRIPT_DIR / "training_system.lock"


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
    system_profile = summarize_profile()
    resolved_mode = args.mode or profile.get("mode", "full-stack")
    resolved_trials = args.trials or profile.get("trials", 2000)
    configured_workers = args.workers if args.workers is not None else profile.get("workers", 0)
    resolved_workers = configured_workers or 0
    resolved_warm_start = args.warm_start or profile.get("warm_start", False)
    resolved_multi_fidelity = args.multi_fidelity or profile.get("multi_fidelity", False)
    resolved_validation_mode = args.validation_mode or profile.get("validation_mode", "standard")

    env = {
        **os.environ,
        "TPE_PARAMETER_MANIFEST": str((RESEARCH_DIR / "parameter_manifest.json").resolve()),
        "TPE_TRAINING_PROFILE": profile_name,
        "TPE_BOX_PROFILE": profile_label(system_profile),
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
                    str(resolve_worker_count("staged", resolved_workers or None)),
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
            str(resolve_worker_count("staged", resolved_workers or None)),
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
                    str(resolve_worker_count("chemistry", resolved_workers or None)),
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
                    str(resolve_worker_count("worldgen", resolved_workers or None)),
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
            str(resolve_worker_count("staged", resolved_workers or None)),
        ]
        if resolved_warm_start:
            staged_cmd.append("--warm-start")
        if resolved_multi_fidelity:
            staged_cmd.append("--multi-fidelity")
        steps.append({
            "name": "staged_optimizer",
            "cmd": staged_cmd,
            "parallel_group": "mixed_optimization",
        })
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
                    str(resolve_worker_count("chemistry", resolved_workers or None)),
                ],
                "parallel_group": "mixed_optimization",
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
                    str(resolve_worker_count("worldgen", resolved_workers or None)),
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
        "validation_mode": resolved_validation_mode,
        "system_profile": system_profile,
        "steps": steps,
        "env": {
            "TPE_PARAMETER_MANIFEST": env["TPE_PARAMETER_MANIFEST"],
            "TPE_TRAINING_PROFILE": env["TPE_TRAINING_PROFILE"],
            "TPE_BOX_PROFILE": env["TPE_BOX_PROFILE"],
            "TPE_VALIDATION_MODE": resolved_validation_mode,
        },
    }


def save_plan(plan: dict[str, Any]) -> None:
    with open(PLAN_PATH, "w", encoding="utf-8") as f:
        json.dump(plan, f, indent=2)


def run_plan(plan: dict[str, Any]) -> dict[str, Any]:
    with open(LOCK_PATH, "w", encoding="utf-8") as lock_file:
        try:
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise SystemExit("Another training_system run is already active") from exc

        lock_file.write(f"{os.getpid()}\n")
        lock_file.flush()

        env = {
            **os.environ,
            **plan["env"],
        }
        results: list[dict[str, Any]] = []
        start = time.time()

        index = 0
        steps = plan["steps"]
        while index < len(steps):
            step = steps[index]
            parallel_group = step.get("parallel_group")
            if parallel_group:
                grouped_steps = [step]
                index += 1
                while index < len(steps) and steps[index].get("parallel_group") == parallel_group:
                    grouped_steps.append(steps[index])
                    index += 1
                group_results = _run_parallel_group(grouped_steps, env)
                results.extend(group_results)
                if any(result["returncode"] != 0 for result in group_results):
                    break
                continue

            results.append(_run_step(step, env))
            if results[-1]["returncode"] != 0:
                break
            index += 1

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


def _run_step(step: dict[str, Any], env: dict[str, str]) -> dict[str, Any]:
    step_start = time.time()
    log_path = SCRIPT_DIR / f"{step['name']}.log"
    with open(log_path, "w", encoding="utf-8") as log_file:
        result = subprocess.run(
            step["cmd"],
            cwd=str(PROJECT_DIR),
            env=env,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            text=True,
        )
    stdout_tail = ""
    if log_path.exists():
        stdout_tail = log_path.read_text(encoding="utf-8")[-4000:]
    return {
        "name": step["name"],
        "returncode": result.returncode,
        "elapsed_seconds": round(time.time() - step_start, 2),
        "stdout_tail": stdout_tail,
        "stderr_tail": "",
        "log_path": str(log_path),
    }


def _run_parallel_group(
    steps: list[dict[str, Any]],
    env: dict[str, str],
) -> list[dict[str, Any]]:
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(steps)) as executor:
        futures = [executor.submit(_run_step, step, env) for step in steps]
        return [future.result() for future in futures]


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
    parser.add_argument("--validation-mode", type=str, default=None,
                        choices=["quick", "standard", "heavy"],
                        help="Validation envelope mode (quick < standard < heavy)")
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
