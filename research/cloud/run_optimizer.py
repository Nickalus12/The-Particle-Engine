#!/usr/bin/env python3
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
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent
RESEARCH_DIR = SCRIPT_DIR.parent
PROJECT_DIR = RESEARCH_DIR.parent
STUDY_DB = RESEARCH_DIR / "cloud_optuna_study.db"
TRIAL_CONFIG = RESEARCH_DIR / "trial_config.json"
RESULTS_FILE = RESEARCH_DIR / "cloud_optimization_results.json"

# ---------------------------------------------------------------------------
# Extended parameter space (more params than local optimizer)
# ---------------------------------------------------------------------------
DEFAULTS: dict[str, int | float] = {
    # Densities (9 params)
    "sand_density": 150,
    "water_density": 100,
    "oil_density": 80,
    "stone_density": 255,
    "metal_density": 240,
    "ice_density": 90,
    "wood_density": 85,
    "dirt_density": 145,
    "lava_density": 200,
    # Gravity (2 params)
    "sand_gravity": 2,
    "water_gravity": 1,
    # Temperature thresholds (4 params)
    "water_boil_point": 180,
    "water_freeze_point": 30,
    "sand_melt_point": 220,
    "ice_melt_point": 40,
    # Viscosity (3 params)
    "oil_viscosity": 2,
    "mud_viscosity": 3,
    "lava_viscosity": 4,
    # Behavioral (3 params)
    "evaporation_rate": 1000,
    "fire_spread_prob": 0.15,
    "erosion_rate": 200,
}

# Extended params only searched in --extended mode
EXTENDED_DEFAULTS: dict[str, int | float] = {
    # Heat conductivity
    "stone_conductivity": 50,
    "metal_conductivity": 200,
    "water_conductivity": 100,
    # Structural
    "stone_structural_integrity": 200,
    "wood_structural_integrity": 80,
    # Combustion
    "wood_ignition_temp": 180,
    "oil_ignition_temp": 160,
    "plant_ignition_temp": 170,
    # Acid
    "acid_dissolve_rate": 150,
    "acid_strength": 200,
}


def suggest_params(trial, extended: bool = False) -> dict[str, Any]:
    """Define the Optuna parameter search space."""
    params: dict[str, Any] = {}

    # Core densities
    params["sand_density"] = trial.suggest_int("sand_density", 120, 180)
    params["water_density"] = trial.suggest_int("water_density", 80, 120)
    params["oil_density"] = trial.suggest_int("oil_density", 60, 95)
    params["stone_density"] = trial.suggest_int("stone_density", 230, 255)
    params["metal_density"] = trial.suggest_int("metal_density", 235, 255)
    params["ice_density"] = trial.suggest_int("ice_density", 80, 100)
    params["wood_density"] = trial.suggest_int("wood_density", 60, 100)
    params["dirt_density"] = trial.suggest_int("dirt_density", 130, 160)
    params["lava_density"] = trial.suggest_int("lava_density", 180, 220)

    # Gravity
    params["sand_gravity"] = trial.suggest_int("sand_gravity", 1, 3)
    params["water_gravity"] = trial.suggest_int("water_gravity", 1, 2)

    # Temperature thresholds
    params["water_boil_point"] = trial.suggest_int("water_boil_point", 160, 200)
    params["water_freeze_point"] = trial.suggest_int("water_freeze_point", 20, 50)
    params["sand_melt_point"] = trial.suggest_int("sand_melt_point", 200, 250)
    params["ice_melt_point"] = trial.suggest_int("ice_melt_point", 30, 60)

    # Viscosity
    params["oil_viscosity"] = trial.suggest_int("oil_viscosity", 1, 4)
    params["mud_viscosity"] = trial.suggest_int("mud_viscosity", 2, 5)
    params["lava_viscosity"] = trial.suggest_int("lava_viscosity", 3, 6)

    # Behavioral
    params["evaporation_rate"] = trial.suggest_int("evaporation_rate", 500, 3000)
    params["fire_spread_prob"] = trial.suggest_float(
        "fire_spread_prob", 0.05, 0.40, step=0.05
    )
    params["erosion_rate"] = trial.suggest_int("erosion_rate", 50, 500)

    if extended:
        params["stone_conductivity"] = trial.suggest_int("stone_conductivity", 20, 100)
        params["metal_conductivity"] = trial.suggest_int("metal_conductivity", 150, 255)
        params["water_conductivity"] = trial.suggest_int("water_conductivity", 60, 150)
        params["stone_structural_integrity"] = trial.suggest_int(
            "stone_structural_integrity", 150, 255
        )
        params["wood_structural_integrity"] = trial.suggest_int(
            "wood_structural_integrity", 50, 120
        )
        params["wood_ignition_temp"] = trial.suggest_int("wood_ignition_temp", 160, 210)
        params["oil_ignition_temp"] = trial.suggest_int("oil_ignition_temp", 140, 190)
        params["plant_ignition_temp"] = trial.suggest_int("plant_ignition_temp", 150, 200)
        params["acid_dissolve_rate"] = trial.suggest_int("acid_dissolve_rate", 80, 250)
        params["acid_strength"] = trial.suggest_int("acid_strength", 150, 255)

    return params


def write_trial_config(params: dict[str, Any]) -> Path:
    """Write trial parameters to JSON for the benchmark to consume."""
    config = {
        "elements": {
            "sand": {
                "density": params.get("sand_density", 150),
                "gravity": params.get("sand_gravity", 2),
                "meltPoint": params.get("sand_melt_point", 220),
            },
            "water": {
                "density": params.get("water_density", 100),
                "gravity": params.get("water_gravity", 1),
                "boilPoint": params.get("water_boil_point", 180),
                "freezePoint": params.get("water_freeze_point", 30),
            },
            "oil": {
                "density": params.get("oil_density", 80),
                "viscosity": params.get("oil_viscosity", 2),
            },
            "stone": {"density": params.get("stone_density", 255)},
            "metal": {"density": params.get("metal_density", 240)},
            "ice": {
                "density": params.get("ice_density", 90),
                "meltPoint": params.get("ice_melt_point", 40),
            },
            "wood": {"density": params.get("wood_density", 85)},
            "dirt": {"density": params.get("dirt_density", 145)},
            "lava": {
                "density": params.get("lava_density", 200),
                "viscosity": params.get("lava_viscosity", 4),
            },
            "mud": {"viscosity": params.get("mud_viscosity", 3)},
        },
        "behavior": {
            "evaporation_rate": params.get("evaporation_rate", 1000),
            "fire_spread_prob": params.get("fire_spread_prob", 0.15),
            "erosion_rate": params.get("erosion_rate", 200),
        },
    }
    # Write to a worker-specific file to avoid conflicts
    pid = os.getpid()
    config_path = RESEARCH_DIR / f"trial_config_{pid}.json"
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
    return config_path


def run_benchmark(config_path: Path) -> tuple[float, float, float]:
    """Run benchmark and return (physics_score, visual_score, overall)."""
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
    except subprocess.TimeoutExpired:
        return 0.0, 0.0, 0.0
    except Exception:
        return 0.0, 0.0, 0.0

    stdout = result.stdout.strip()
    if not stdout:
        return 0.0, 0.0, 0.0

    try:
        data = json.loads(stdout)
    except json.JSONDecodeError:
        # Try to find JSON in output
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


def objective(trial, extended: bool = False) -> tuple[float, float]:
    """Optuna objective: maximize physics and visual scores."""
    params = suggest_params(trial, extended=extended)
    config_path = write_trial_config(params)

    try:
        physics, visuals, overall = run_benchmark(config_path)
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
    extended: bool,
    result_queue: mp.Queue,
):
    """Worker process that runs a batch of Optuna trials."""
    import optuna

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
    print(f"  Parameters:     {21 + (10 if extended else 0)}")
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
            args=(w, trials_per_worker, study_name, extended, result_queue),
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
        write_trial_config(best.params)
        print(f"  Trial config written to: trial_config.json")

    print()


def show_results(args: argparse.Namespace) -> None:
    """Display optimization results."""
    import optuna

    storage_url = f"sqlite:///{STUDY_DB}"
    try:
        study = optuna.load_study(
            study_name=args.study_name, storage=storage_url
        )
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
    for key in sorted(DEFAULTS.keys()):
        default = DEFAULTS[key]
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
        default=6,
        help="Number of parallel workers (default: 6)",
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

    show_p = sub.add_parser("show", help="Show results")
    show_p.add_argument("--study-name", default="cloud_particle_engine")
    show_p.add_argument("--top", type=int, default=20)

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
