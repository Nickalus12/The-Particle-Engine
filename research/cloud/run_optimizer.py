#!/usr/bin/env python3
# =========================================================================
#  DEPRECATED  --  Use training_system.py instead.
#
#  This file is kept for backward compatibility with pipeline_concurrent_gpu.py
#  which imports `objective` from here. New code should use training_system.py
#  as the single entrypoint for cloud training and optimization.
# =========================================================================
"""Massively parallel Optuna optimizer for ThunderCompute.

Runs N worker processes in parallel, each executing Optuna trials against
a shared SQLite study. Designed for 8-144 vCPU cloud instances.

Usage:
    python research/cloud/run_optimizer.py --workers 6 --trials 2000
    python research/cloud/run_optimizer.py --workers 6 --trials 5000 --extended
    python research/cloud/run_optimizer.py --show
"""

from __future__ import annotations

import argparse
import json
import multiprocessing as mp
import os
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent
RESEARCH_DIR = SCRIPT_DIR.parent
PROJECT_DIR = RESEARCH_DIR.parent
sys.path.insert(0, str(RESEARCH_DIR))

from parameter_contract import (
    build_optuna_suggestion_spec,
    select_optuna_manifest_parameters,
    write_trial_config as write_manifest_trial_config,
)

STUDY_DB = RESEARCH_DIR / "cloud_optuna_study.db"
TRIAL_CONFIG = RESEARCH_DIR / "trial_config.json"
RESULTS_FILE = RESEARCH_DIR / "cloud_optimization_results.json"

LEGACY_EXTRA_DEFAULTS: dict[str, int | float] = {
    "evaporation_rate": 1000,
    "fire_spread_prob": 0.15,
    "erosion_rate": 200,
}

CLOUD_OPTUNA_PROFILE = "balanced"
CLOUD_FAST_MANIFEST_PARAMS = select_optuna_manifest_parameters(
    profile=CLOUD_OPTUNA_PROFILE,
    runtime_mutable=True,
)
CLOUD_EXTENDED_MANIFEST_PARAMS = select_optuna_manifest_parameters(
    profile=CLOUD_OPTUNA_PROFILE,
)

DEFAULTS: dict[str, int | float] = {
    **{
        str(meta.get("legacy_flat")): meta.get("default")
        for _, meta in CLOUD_FAST_MANIFEST_PARAMS
        if meta.get("legacy_flat") is not None
    },
    **LEGACY_EXTRA_DEFAULTS,
}
EXTENDED_DEFAULTS: dict[str, int | float] = {
    **{
        str(meta.get("legacy_flat")): meta.get("default")
        for _, meta in CLOUD_EXTENDED_MANIFEST_PARAMS
        if meta.get("legacy_flat") is not None
    },
    **LEGACY_EXTRA_DEFAULTS,
}


def _set_cloud_optuna_profile(profile: str) -> None:
    global CLOUD_OPTUNA_PROFILE, CLOUD_FAST_MANIFEST_PARAMS, CLOUD_EXTENDED_MANIFEST_PARAMS, DEFAULTS, EXTENDED_DEFAULTS
    CLOUD_OPTUNA_PROFILE = profile
    CLOUD_FAST_MANIFEST_PARAMS = select_optuna_manifest_parameters(
        profile=profile,
        runtime_mutable=True,
    )
    CLOUD_EXTENDED_MANIFEST_PARAMS = select_optuna_manifest_parameters(
        profile=profile,
    )
    DEFAULTS = {
        **{
            str(meta.get("legacy_flat")): meta.get("default")
            for _, meta in CLOUD_FAST_MANIFEST_PARAMS
            if meta.get("legacy_flat") is not None
        },
        **LEGACY_EXTRA_DEFAULTS,
    }
    EXTENDED_DEFAULTS = {
        **{
            str(meta.get("legacy_flat")): meta.get("default")
            for _, meta in CLOUD_EXTENDED_MANIFEST_PARAMS
            if meta.get("legacy_flat") is not None
        },
        **LEGACY_EXTRA_DEFAULTS,
    }


def _build_cloud_optuna_metadata(*, extended: bool) -> dict[str, Any]:
    manifest_params = (
        CLOUD_EXTENDED_MANIFEST_PARAMS if extended else CLOUD_FAST_MANIFEST_PARAMS
    )
    group_counts = Counter(str(meta.get("group", "unknown")) for _, meta in manifest_params)
    return {
        "profile": CLOUD_OPTUNA_PROFILE,
        "source_label": "cloud_optuna",
        "execution_mode": "extended" if extended else "fast",
        "param_count": len(manifest_params) + len(LEGACY_EXTRA_DEFAULTS),
        "runtime_mutable_only": not extended,
        "search_groups": dict(sorted(group_counts.items())),
    }


def _annotate_study(study, *, extended: bool) -> None:
    metadata = _build_cloud_optuna_metadata(extended=extended)
    study.set_user_attr("optuna_profile", CLOUD_OPTUNA_PROFILE)
    study.set_user_attr("optuna_execution_mode", metadata["execution_mode"])
    study.set_user_attr("optuna_param_count", metadata["param_count"])
    study.set_user_attr("optuna_runtime_mutable_only", metadata["runtime_mutable_only"])
    study.set_user_attr("optuna_search_groups", metadata["search_groups"])


def suggest_params(trial, extended: bool = False) -> dict[str, Any]:
    """Define the Optuna parameter search space."""
    params: dict[str, Any] = {}
    manifest_params = (
        CLOUD_EXTENDED_MANIFEST_PARAMS if extended else CLOUD_FAST_MANIFEST_PARAMS
    )

    for _, meta in manifest_params:
        spec = build_optuna_suggestion_spec(meta)
        if spec is None:
            continue

        name = str(spec["name"])
        if spec["type"] == "float":
            kwargs: dict[str, Any] = {}
            if "step" in spec:
                kwargs["step"] = float(spec["step"])
            elif spec.get("log"):
                kwargs["log"] = True
            params[name] = trial.suggest_float(
                name,
                float(spec["low"]),
                float(spec["high"]),
                **kwargs,
            )
        else:
            kwargs = {}
            if "step" in spec:
                kwargs["step"] = int(spec["step"])
            elif spec.get("log"):
                kwargs["log"] = True
            params[name] = trial.suggest_int(
                name,
                int(spec["low"]),
                int(spec["high"]),
                **kwargs,
            )

    params["evaporation_rate"] = trial.suggest_int("evaporation_rate", 500, 3000)
    params["fire_spread_prob"] = trial.suggest_float(
        "fire_spread_prob", 0.05, 0.40, step=0.05
    )
    params["erosion_rate"] = trial.suggest_int("erosion_rate", 50, 500)

    return params


def write_trial_config(params: dict[str, Any], *, extended: bool = False) -> Path:
    """Write trial parameters to JSON for the benchmark to consume."""
    # Write to a worker-specific file to avoid conflicts
    pid = os.getpid()
    config_path = RESEARCH_DIR / f"trial_config_{pid}.json"
    metadata = _build_cloud_optuna_metadata(extended=extended)
    return write_manifest_trial_config(config_path, params, metadata=metadata)


def run_benchmark(config_path: Path, fast: bool = True) -> tuple[float, float, float]:
    """Run benchmark and return (physics_score, visual_score, overall).

    In fast mode, uses the Dart-only headless benchmark (~2s per trial).
    In full mode, uses the Python pytest benchmark (~30s per trial).
    """
    if fast:
        return _run_fast_benchmark(config_path)
    return _run_full_benchmark(config_path)


def _run_fast_benchmark(config_path: Path) -> tuple[float, float, float]:
    """Fast Dart-only benchmark: ~2s per trial, physics + interactions."""
    try:
        dart_exe = "dart"
        result = subprocess.run(
            [dart_exe, "run", str(SCRIPT_DIR / "fast_benchmark.dart"), str(config_path)],
            capture_output=True,
            text=True,
            timeout=30,
            cwd=str(PROJECT_DIR),
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, Exception):
        return 0.0, 0.0, 0.0

    stdout = result.stdout.strip()
    if not stdout:
        return 0.0, 0.0, 0.0

    try:
        data = json.loads(stdout)
    except json.JSONDecodeError:
        return 0.0, 0.0, 0.0

    physics = data.get("physics", 0.0)
    interactions = data.get("interactions", 0.0)
    overall = data.get("overall", 0.0)
    return physics, interactions, overall


def _run_full_benchmark(config_path: Path) -> tuple[float, float, float]:
    """Full Python pytest benchmark: ~30s per trial, all domains."""
    try:
        result = subprocess.run(
            [
                sys.executable,
                str(RESEARCH_DIR / "benchmark.py"),
                "--quick",
                "--json",
            ],
            capture_output=True,
            text=True,
            timeout=300,
            cwd=str(PROJECT_DIR),
            env={**os.environ, "TRIAL_CONFIG": str(config_path)},
        )
    except (subprocess.TimeoutExpired, Exception):
        return 0.0, 0.0, 0.0

    stdout = result.stdout.strip()
    if not stdout:
        return 0.0, 0.0, 0.0

    try:
        data = json.loads(stdout)
    except json.JSONDecodeError:
        for line in stdout.splitlines():
            if line.strip().startswith("{"):
                try:
                    data = json.loads(line)
                    break
                except json.JSONDecodeError:
                    continue
        else:
            return 0.0, 0.0, 0.0

    physics = data.get("domain_scores", {}).get("Physics", {}).get("score", 0.0)
    visuals = data.get("domain_scores", {}).get("Visuals", {}).get("score", 0.0)
    overall = data.get("overall_score", 0.0)
    return physics, visuals, overall


def objective(trial, extended: bool = False, fast: bool = True) -> tuple[float, float]:
    """Optuna objective: maximize physics and interaction scores."""
    params = suggest_params(trial, extended=extended)
    config_path = write_trial_config(params, extended=extended)

    try:
        physics, visuals, overall = run_benchmark(config_path, fast=fast)
    finally:
        # Cleanup worker-specific config
        config_path.unlink(missing_ok=True)

    trial.set_user_attr("overall", overall)
    trial.set_user_attr("physics", physics)
    trial.set_user_attr("visuals", visuals)

    return physics, visuals


def worker_process(
    worker_id: int,
    n_trials: int,
    study_name: str,
    profile: str,
    extended: bool,
    result_queue: mp.Queue,
):
    """Worker process that runs a batch of Optuna trials."""
    import optuna

    _set_cloud_optuna_profile(profile)
    optuna.logging.set_verbosity(optuna.logging.WARNING)

    storage_url = f"sqlite:///{STUDY_DB}"
    study = optuna.create_study(
        study_name=study_name,
        storage=storage_url,
        directions=["maximize", "maximize"],
        load_if_exists=True,
        sampler=optuna.samplers.TPESampler(
            seed=42 + worker_id, multivariate=True
        ),
    )
    _annotate_study(study, extended=extended)

    start = time.time()
    completed = 0
    best_overall = 0.0

    for i in range(n_trials):
        try:
            trial = study.ask()
            physics, visuals = objective(trial, extended=extended)
            study.tell(trial, [physics, visuals])
            completed += 1
            overall = trial.user_attrs.get("overall", 0)
            if overall > best_overall:
                best_overall = overall

            elapsed = time.time() - start
            rate = completed / elapsed * 3600 if elapsed > 0 else 0
            print(
                f"  [W{worker_id}] Trial {completed}/{n_trials}  "
                f"P={physics:.1f}% V={visuals:.1f}% O={overall:.1f}%  "
                f"({rate:.0f} trials/hr)"
            )
        except Exception as e:
            print(f"  [W{worker_id}] Trial error: {e}")

    elapsed = time.time() - start
    result_queue.put(
        {
            "worker_id": worker_id,
            "completed": completed,
            "elapsed": elapsed,
            "best_overall": best_overall,
        }
    )


def run_optimization(args: argparse.Namespace) -> None:
    """Launch parallel workers to run optimization."""
    import optuna

    _set_cloud_optuna_profile(args.profile)
    optuna.logging.set_verbosity(optuna.logging.WARNING)

    n_workers = args.workers
    total_trials = args.trials
    trials_per_worker = total_trials // n_workers
    study_name = args.study_name
    extended = args.extended

    # Create the study first
    storage_url = f"sqlite:///{STUDY_DB}"
    study = optuna.create_study(
        study_name=study_name,
        storage=storage_url,
        directions=["maximize", "maximize"],
        load_if_exists=True,
        sampler=optuna.samplers.TPESampler(seed=42, multivariate=True),
    )
    _annotate_study(study, extended=extended)
    existing = len(study.trials)

    print()
    print("=" * 70)
    print("  PARTICLE ENGINE CLOUD PARAMETER OPTIMIZER")
    print("=" * 70)
    print()
    print(f"  Workers:        {n_workers}")
    print(f"  Trials/worker:  {trials_per_worker}")
    print(f"  Total trials:   {trials_per_worker * n_workers}")
    print(f"  Existing:       {existing}")
    print(f"  Extended mode:  {extended}")
    print(f"  Profile:        {args.profile}")
    print(
        f"  Parameters:     "
        f"{len(EXTENDED_DEFAULTS if extended else DEFAULTS)}"
    )
    print(f"  Study:          {study_name}")
    print(f"  Database:       {STUDY_DB.name}")
    print()
    print("-" * 70)
    print()

    result_queue = mp.Queue()
    processes = []

    start = time.time()

    for w in range(n_workers):
        p = mp.Process(
            target=worker_process,
            args=(w, trials_per_worker, study_name, args.profile, extended, result_queue),
        )
        p.start()
        processes.append(p)
        time.sleep(0.5)  # Stagger starts to avoid DB lock contention

    # Wait for all workers
    for p in processes:
        p.join()

    total_elapsed = time.time() - start

    # Collect results
    results = []
    while not result_queue.empty():
        results.append(result_queue.get())

    total_completed = sum(r["completed"] for r in results)
    best_overall = max((r["best_overall"] for r in results), default=0)

    # Reload study for final analysis
    study = optuna.load_study(study_name=study_name, storage=storage_url)
    _annotate_study(study, extended=extended)
    pareto = study.best_trials

    print()
    print("-" * 70)
    print()
    print(f"  Completed:      {total_completed} trials in {total_elapsed:.0f}s")
    print(f"  Rate:           {total_completed / total_elapsed * 3600:.0f} trials/hr")
    print(f"  Total in study: {len(study.trials)}")
    print(f"  Pareto-optimal: {len(pareto)}")
    print(f"  Best overall:   {best_overall:.1f}%")

    if pareto:
        best = max(pareto, key=lambda t: sum(t.values))
        print()
        print(f"  Best Pareto trial: #{best.number}")
        print(f"    Physics: {best.values[0]:.1f}%")
        print(f"    Visual:  {best.values[1]:.1f}%")
        print(f"    Overall: {best.user_attrs.get('overall', 0):.1f}%")

        # Save best params
        best_result = {
            "trial": best.number,
            "physics": best.values[0],
            "visuals": best.values[1],
            "overall": best.user_attrs.get("overall", 0),
            "params": best.params,
            "total_trials": len(study.trials),
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        with open(RESULTS_FILE, "w") as f:
            json.dump(best_result, f, indent=2)
        print(f"\n  Best params saved to: {RESULTS_FILE.name}")

        # Also write as trial_config for immediate use
        write_trial_config(best.params, extended=extended)
        print(f"  Trial config written to: trial_config.json")

    print()


def show_results(args: argparse.Namespace) -> None:
    """Display optimization results."""
    import optuna

    _set_cloud_optuna_profile(args.profile)
    storage_url = f"sqlite:///{STUDY_DB}"
    try:
        study = optuna.load_study(
            study_name=args.study_name, storage=storage_url
        )
        _annotate_study(study, extended=args.extended)
    except Exception:
        print("No study found. Run optimization first.")
        return

    trials = [t for t in study.trials if t.values is not None]
    if not trials:
        print("No completed trials.")
        return

    sorted_trials = sorted(
        trials, key=lambda t: sum(t.values) if t.values else 0, reverse=True
    )

    print()
    print(f"  Study: {args.study_name}  |  {len(trials)} completed trials")
    print()
    print(f"  {'#':>5}  {'Physics':>8}  {'Visual':>8}  {'Overall':>8}")
    print(f"  {'---':>5}  {'-------':>8}  {'------':>8}  {'-------':>8}")

    for t in sorted_trials[: args.top]:
        overall = t.user_attrs.get("overall", 0)
        print(
            f"  {t.number:5d}  {t.values[0]:7.1f}%  {t.values[1]:7.1f}%  {overall:7.1f}%"
        )

    # Show best params diff
    best = sorted_trials[0]
    print(f"\n  Best trial #{best.number} params vs defaults:")
    default_set = EXTENDED_DEFAULTS if args.extended else DEFAULTS
    for key in sorted(default_set.keys()):
        default = default_set[key]
        current = best.params.get(key, default)
        if isinstance(default, float):
            diff = abs(current - default) > 0.001
        else:
            diff = current != default
        if diff:
            print(f"    {key}: {default} -> {current}")
    print()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Particle Engine Cloud Parameter Optimizer"
    )
    sub = parser.add_subparsers(dest="command")

    run_p = sub.add_parser("run", help="Run parallel optimization")
    run_p.add_argument(
        "--workers",
        type=int,
        default=14,
        help="Number of parallel workers (default: 14 for H100 production)",
    )
    run_p.add_argument(
        "--trials",
        type=int,
        default=2000,
        help="Total trials across all workers (default: 2000)",
    )
    run_p.add_argument(
        "--study-name",
        default="cloud_particle_engine",
        help="Study name",
    )
    run_p.add_argument(
        "--extended",
        action="store_true",
        help="Include extended parameter space (31 params instead of 21)",
    )
    run_p.add_argument(
        "--profile",
        choices=["balanced", "mobile", "exploratory"],
        default="balanced",
        help="Search-surface profile (default: balanced)",
    )

    show_p = sub.add_parser("show", help="Show results")
    show_p.add_argument("--study-name", default="cloud_particle_engine")
    show_p.add_argument("--top", type=int, default=20)
    show_p.add_argument(
        "--profile",
        choices=["balanced", "mobile", "exploratory"],
        default="balanced",
        help="Interpret results against this profile's manifest surface",
    )
    show_p.add_argument(
        "--extended",
        action="store_true",
        help="Compare results against the extended manifest-backed defaults",
    )

    args = parser.parse_args()

    if args.command == "run":
        run_optimization(args)
    elif args.command == "show":
        show_results(args)
    else:
        parser.print_help()

    return 0


if __name__ == "__main__":
    sys.exit(main())
