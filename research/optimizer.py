#!/usr/bin/env python3
"""The Particle Engine -- Optuna Parameter Optimizer.

Bayesian-optimized automatic parameter tuning using multi-objective
optimization (Physics vs Visuals). Persists studies in SQLite for
resumable, incremental search.

Usage:
    python research/optimizer.py run --n-trials 50
    python research/optimizer.py run --n-trials 25 --resume
    python research/optimizer.py show --top 10
    python research/optimizer.py viz
    python research/optimizer.py apply
    python research/optimizer.py test --param sand_density 160 --param water_viscosity 2
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import textwrap
import time
from collections import Counter
from pathlib import Path
from typing import Any

# Ensure research/ is on sys.path so parameter_contract can be found
# regardless of the cwd the user invokes from.
_RESEARCH_DIR = Path(__file__).resolve().parent
if str(_RESEARCH_DIR) not in sys.path:
    sys.path.insert(0, str(_RESEARCH_DIR))

from parameter_contract import (
    build_optuna_suggestion_spec,
    select_optuna_manifest_parameters,
    write_trial_config as write_manifest_trial_config,
)

# ---------------------------------------------------------------------------
# Windows UTF-8 fix
# ---------------------------------------------------------------------------
if sys.platform == "win32":
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except Exception:
                pass

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
RESEARCH_DIR = Path(__file__).resolve().parent
PROJECT_DIR = RESEARCH_DIR.parent
STUDY_DB = RESEARCH_DIR / "optuna_study.db"
TRIAL_CONFIG = RESEARCH_DIR / "trial_config.json"
PLOTS_DIR = RESEARCH_DIR / "plots"

# ---------------------------------------------------------------------------
# Manifest-backed defaults and curated legacy extras
# ---------------------------------------------------------------------------
LEGACY_EXTRA_DEFAULTS: dict[str, int | float] = {
    "evaporation_rate": 1000,
    "fire_spread_prob": 0.15,
    "erosion_rate": 200,
}

OPTUNA_PROFILE = "balanced"
MANIFEST_OPTUNA_PARAMS = select_optuna_manifest_parameters(profile=OPTUNA_PROFILE)
DEFAULTS: dict[str, int | float] = {
    **{
        str(meta.get("legacy_flat")): meta.get("default")
        for _, meta in MANIFEST_OPTUNA_PARAMS
        if meta.get("legacy_flat") is not None
    },
    **LEGACY_EXTRA_DEFAULTS,
}


def _set_optuna_profile(profile: str) -> None:
    global OPTUNA_PROFILE, MANIFEST_OPTUNA_PARAMS, DEFAULTS
    OPTUNA_PROFILE = profile
    MANIFEST_OPTUNA_PARAMS = select_optuna_manifest_parameters(profile=profile)
    DEFAULTS = {
        **{
            str(meta.get("legacy_flat")): meta.get("default")
            for _, meta in MANIFEST_OPTUNA_PARAMS
            if meta.get("legacy_flat") is not None
        },
        **LEGACY_EXTRA_DEFAULTS,
    }


def _build_optuna_run_metadata(
    *,
    profile: str,
    manifest_params: list[tuple[str, dict[str, Any]]],
    source_label: str,
) -> dict[str, Any]:
    group_counts = Counter(str(meta.get("group", "unknown")) for _, meta in manifest_params)
    return {
        "profile": profile,
        "source_label": source_label,
        "param_count": len(manifest_params) + len(LEGACY_EXTRA_DEFAULTS),
        "runtime_mutable_count": sum(
            1 for _, meta in manifest_params if bool(meta.get("runtime_mutable"))
        ),
        "search_groups": dict(sorted(group_counts.items())),
        "search_space": [
            {
                "canonical_path": canonical_path,
                "name": str(meta.get("legacy_flat")),
                "group": str(meta.get("group", "unknown")),
                "runtime_mutable": bool(meta.get("runtime_mutable")),
                "mobile_priority": meta.get("mobile_priority"),
            }
            for canonical_path, meta in manifest_params
            if meta.get("legacy_flat")
        ],
    }


def _annotate_study(study) -> None:
    metadata = _build_optuna_run_metadata(
        profile=OPTUNA_PROFILE,
        manifest_params=MANIFEST_OPTUNA_PARAMS,
        source_label="local_optuna",
    )
    study.set_user_attr("optuna_profile", OPTUNA_PROFILE)
    study.set_user_attr("optuna_param_count", metadata["param_count"])
    study.set_user_attr("optuna_runtime_mutable_count", metadata["runtime_mutable_count"])
    study.set_user_attr("optuna_search_groups", metadata["search_groups"])


# ---------------------------------------------------------------------------
# Search space definition
# ---------------------------------------------------------------------------
def suggest_params(trial) -> dict[str, Any]:
    """Define the Optuna parameter search space from the manifest."""
    params: dict[str, Any] = {}

    for _, meta in MANIFEST_OPTUNA_PARAMS:
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


# ---------------------------------------------------------------------------
# Config writer
# ---------------------------------------------------------------------------
def write_trial_config(params: dict[str, Any]) -> Path:
    """Write trial parameters to JSON for the benchmark to consume."""
    metadata = _build_optuna_run_metadata(
        profile=OPTUNA_PROFILE,
        manifest_params=MANIFEST_OPTUNA_PARAMS,
        source_label="local_optuna",
    )
    return write_manifest_trial_config(TRIAL_CONFIG, params, metadata=metadata)


# ---------------------------------------------------------------------------
# Objective function
# ---------------------------------------------------------------------------
def objective(trial) -> tuple[float, float]:
    """Run benchmark and return (physics_score, visual_score)."""
    params = suggest_params(trial)
    write_trial_config(params)

    try:
        result = subprocess.run(
            [sys.executable, str(RESEARCH_DIR / "benchmark.py"), "--quick", "--json"],
            capture_output=True,
            text=True,
            timeout=300,
            cwd=str(PROJECT_DIR),
            env={**os.environ, "TRIAL_CONFIG": str(TRIAL_CONFIG)},
        )
    except subprocess.TimeoutExpired as exc:
        print(f"  Trial {trial.number}: TIMEOUT (300s)")
        trial.set_user_attr("error", "timeout")
        if exc.stderr:
            stderr_tail = exc.stderr.strip().splitlines()[-5:] if isinstance(exc.stderr, str) else []
            trial.set_user_attr("stderr_tail", "\n".join(stderr_tail))
        return float("nan"), float("nan")
    except Exception as e:
        print(f"  Trial {trial.number}: ERROR ({e})")
        trial.set_user_attr("error", str(e))
        return float("nan"), float("nan")

    # Parse JSON from stdout
    stdout = result.stdout.strip()
    if not stdout:
        print(f"  Trial {trial.number}: No output from benchmark")
        trial.set_user_attr("error", "no_output")
        if result.stderr:
            stderr_tail = result.stderr.strip().splitlines()[-3:]
            trial.set_user_attr("stderr_tail", "\n".join(stderr_tail))
        return 0.0, 0.0

    try:
        data = json.loads(stdout)
    except json.JSONDecodeError as e:
        print(f"  Trial {trial.number}: JSON parse error: {e}")
        # Try to find JSON in output (benchmark may print other text)
        for i, line in enumerate(stdout.splitlines()):
            if line.strip().startswith("{"):
                try:
                    data = json.loads("\n".join(stdout.splitlines()[i:]))
                    break
                except json.JSONDecodeError:
                    continue
        else:
            trial.set_user_attr("error", "json_parse")
            return 0.0, 0.0

    physics = data.get("domain_scores", {}).get("Physics", {}).get("score", 0.0)
    visuals = data.get("domain_scores", {}).get("Visuals", {}).get("score", 0.0)

    # Store extra info
    trial.set_user_attr("overall", data.get("overall_score", 0.0))
    trial.set_user_attr("passed", data.get("total_passed", 0))
    trial.set_user_attr("failed", data.get("total_failed", 0))
    trial.set_user_attr("duration", data.get("duration_seconds", 0))

    infra = data.get("domain_scores", {}).get("Infrastructure", {}).get("score", 0.0)
    trial.set_user_attr("infra", infra)

    # Log to MLflow (optional)
    try:
        from research.mlflow_setup import log_optuna_trial

        overall = data.get("overall_score", 0.0)
        log_optuna_trial(trial.number, params, physics, visuals, overall)
    except ImportError:
        pass
    except Exception:
        pass  # MLflow logging is best-effort

    return physics, visuals


# ---------------------------------------------------------------------------
# Study management
# ---------------------------------------------------------------------------
def create_or_load_study(study_name: str = "particle_engine", load_if_exists: bool = True):
    """Create a new study or load an existing one from SQLite."""
    import optuna

    storage_url = f"sqlite:///{STUDY_DB}"
    study = optuna.create_study(
        study_name=study_name,
        storage=storage_url,
        directions=["maximize", "maximize"],
        load_if_exists=load_if_exists,
        sampler=optuna.samplers.TPESampler(seed=42, multivariate=True),
    )
    _annotate_study(study)
    return study


def load_study(study_name: str = "particle_engine"):
    """Load an existing study."""
    import optuna

    storage_url = f"sqlite:///{STUDY_DB}"
    study = optuna.load_study(study_name=study_name, storage=storage_url)
    _annotate_study(study)
    return study


# ---------------------------------------------------------------------------
# Run optimization
# ---------------------------------------------------------------------------
def run_optimization(args: argparse.Namespace) -> None:
    """Run optimization trials."""
    import optuna

    _set_optuna_profile(args.profile)
    optuna.logging.set_verbosity(optuna.logging.WARNING)

    study = create_or_load_study(
        study_name=args.study_name,
        load_if_exists=args.resume or True,
    )

    existing = len(study.trials)
    n_trials = args.n_trials

    print()
    print("=" * 60)
    print("  PARTICLE ENGINE PARAMETER OPTIMIZER")
    print("=" * 60)
    print()
    print(f"  Study:        {args.study_name}")
    print(f"  Storage:      {STUDY_DB.name}")
    print(f"  Existing:     {existing} trials")
    print(f"  New trials:   {n_trials}")
    print(f"  Timeout:      {args.timeout}s")
    print(f"  Objectives:   Physics (maximize), Visuals (maximize)")
    print(f"  Profile:      {args.profile}")
    print(f"  Parameters:   {len(MANIFEST_OPTUNA_PARAMS) + len(LEGACY_EXTRA_DEFAULTS)}")
    print()
    print("-" * 60)
    print()

    start = time.time()

    def trial_callback(study, trial):
        elapsed = time.time() - start
        n_done = trial.number - existing + 1
        phys = trial.values[0] if trial.values else 0
        vis = trial.values[1] if trial.values else 0
        overall = trial.user_attrs.get("overall", 0)
        err = trial.user_attrs.get("error", "")

        if err:
            status = f"ERROR: {err}"
        else:
            status = f"Physics={phys:.1f}%  Visual={vis:.1f}%  Overall={overall:.1f}%"

        print(f"  [{n_done}/{n_trials}] Trial #{trial.number}  {status}  ({elapsed:.0f}s)")

    study.optimize(
        objective,
        n_trials=n_trials,
        timeout=args.timeout,
        callbacks=[trial_callback],
        show_progress_bar=False,
    )

    total_elapsed = time.time() - start
    total_trials = len(study.trials)
    pareto = study.best_trials

    print()
    print("-" * 60)
    print()
    print(f"  Completed in {total_elapsed:.0f}s")
    print(f"  Total trials: {total_trials}")
    print(f"  Pareto-optimal: {len(pareto)}")

    if pareto:
        best = max(pareto, key=lambda t: sum(t.values))
        print()
        print(f"  Best combined trial: #{best.number}")
        print(f"    Physics: {best.values[0]:.1f}%")
        print(f"    Visual:  {best.values[1]:.1f}%")
        print(f"    Overall: {best.user_attrs.get('overall', 0):.1f}%")
        print()
        _print_param_diff(best.params)

    print()


# ---------------------------------------------------------------------------
# Show results
# ---------------------------------------------------------------------------
def show_results(args: argparse.Namespace) -> None:
    """Display optimization results."""
    _set_optuna_profile(args.profile)
    study = load_study(args.study_name)
    trials = [t for t in study.trials if t.values is not None]

    if not trials:
        print("No completed trials found.")
        return

    pareto = study.best_trials

    print()
    print("=" * 60)
    print("  OPTIMIZATION RESULTS")
    print("=" * 60)
    print()
    print(f"  Study:          {args.study_name}")
    print(f"  Total trials:   {len(study.trials)}")
    print(f"  Completed:      {len(trials)}")
    print(f"  Pareto-optimal: {len(pareto)}")
    print()

    # Top trials by combined score
    sorted_trials = sorted(
        trials,
        key=lambda t: sum(t.values) if t.values else 0,
        reverse=True,
    )

    top_n = min(args.top, len(sorted_trials))
    print(f"  Top {top_n} trials (by combined score):")
    print()
    print(f"  {'#':>5s}  {'Physics':>8s}  {'Visual':>8s}  {'Combined':>10s}  {'Overall':>8s}  {'P/F':>6s}")
    print(f"  {'---':>5s}  {'-------':>8s}  {'------':>8s}  {'--------':>10s}  {'-------':>8s}  {'---':>6s}")

    for trial in sorted_trials[:top_n]:
        phys = trial.values[0]
        vis = trial.values[1]
        combined = phys + vis
        overall = trial.user_attrs.get("overall", 0)
        passed = trial.user_attrs.get("passed", "?")
        failed = trial.user_attrs.get("failed", "?")
        print(
            f"  {trial.number:5d}  {phys:7.1f}%  {vis:7.1f}%  {combined:9.1f}%  {overall:7.1f}%  {passed}/{failed}"
        )

    # Show best trial's params
    if sorted_trials:
        best = sorted_trials[0]
        print()
        print(f"  Best trial #{best.number} parameters vs defaults:")
        print()
        _print_param_diff(best.params)

    print()


# ---------------------------------------------------------------------------
# Visualization
# ---------------------------------------------------------------------------
def generate_all_visualizations(args: argparse.Namespace) -> None:
    """Generate interactive HTML plots from the study."""
    import optuna

    study = load_study(args.study_name)
    completed = [t for t in study.trials if t.values is not None]

    if len(completed) < 2:
        print(f"Need at least 2 completed trials for visualizations (have {len(completed)}).")
        return

    PLOTS_DIR.mkdir(exist_ok=True)

    from optuna.visualization import (
        plot_optimization_history,
        plot_parallel_coordinate,
        plot_param_importances,
        plot_pareto_front,
        plot_slice,
    )

    plots: list[tuple[str, str, Any]] = []

    # Pareto front: physics vs visuals tradeoff
    print("  Generating Pareto front...")
    try:
        fig = plot_pareto_front(study, target_names=["Physics %", "Visual %"])
        path = PLOTS_DIR / "pareto_front.html"
        fig.write_html(str(path))
        plots.append(("Pareto Front", str(path), fig))
    except Exception as e:
        print(f"    Skipped: {e}")

    # Parameter importance for physics
    print("  Generating parameter importance (physics)...")
    try:
        fig = plot_param_importances(study, target=lambda t: t.values[0])
        path = PLOTS_DIR / "param_importance_physics.html"
        fig.write_html(str(path))
        plots.append(("Param Importance (Physics)", str(path), fig))
    except Exception as e:
        print(f"    Skipped: {e}")

    # Parameter importance for visuals
    print("  Generating parameter importance (visuals)...")
    try:
        fig = plot_param_importances(study, target=lambda t: t.values[1])
        path = PLOTS_DIR / "param_importance_visuals.html"
        fig.write_html(str(path))
        plots.append(("Param Importance (Visuals)", str(path), fig))
    except Exception as e:
        print(f"    Skipped: {e}")

    # Optimization history (physics)
    print("  Generating optimization history...")
    try:
        fig = plot_optimization_history(study, target=lambda t: t.values[0])
        path = PLOTS_DIR / "history_physics.html"
        fig.write_html(str(path))
        plots.append(("History (Physics)", str(path), fig))
    except Exception as e:
        print(f"    Skipped: {e}")

    # Parallel coordinate plot
    print("  Generating parallel coordinates...")
    try:
        fig = plot_parallel_coordinate(study, target=lambda t: t.values[0])
        path = PLOTS_DIR / "parallel_coords.html"
        fig.write_html(str(path))
        plots.append(("Parallel Coordinates", str(path), fig))
    except Exception as e:
        print(f"    Skipped: {e}")

    # Slice plot
    print("  Generating slice plots...")
    try:
        fig = plot_slice(study, target=lambda t: t.values[0])
        path = PLOTS_DIR / "slice_physics.html"
        fig.write_html(str(path))
        plots.append(("Slice (Physics)", str(path), fig))
    except Exception as e:
        print(f"    Skipped: {e}")

    print()
    print(f"  Generated {len(plots)} visualizations in {PLOTS_DIR}/")
    for name, path, _ in plots:
        print(f"    {name}: {Path(path).name}")
    print()


# ---------------------------------------------------------------------------
# Apply best parameters
# ---------------------------------------------------------------------------
def apply_best_params(args: argparse.Namespace) -> None:
    """Write the best trial's parameters to trial_config.json."""
    _set_optuna_profile(args.profile)
    study = load_study(args.study_name)
    completed = [t for t in study.trials if t.values is not None]

    if not completed:
        print("No completed trials found.")
        return

    if args.trial is not None:
        matching = [t for t in study.trials if t.number == args.trial]
        if not matching:
            print(f"Trial #{args.trial} not found.")
            return
        trial = matching[0]
    else:
        best = max(study.best_trials, key=lambda t: sum(t.values))
        trial = best

    print()
    print(f"  Applying trial #{trial.number}")
    print(f"    Physics: {trial.values[0]:.1f}%")
    print(f"    Visual:  {trial.values[1]:.1f}%")
    print(f"    Overall: {trial.user_attrs.get('overall', 0):.1f}%")
    print()

    _print_param_diff(trial.params)

    write_trial_config(trial.params)
    print()
    print(f"  Config written to {TRIAL_CONFIG.name}")
    print("  To apply to Dart code, update element_registry.dart with these values.")
    print()


# ---------------------------------------------------------------------------
# Test specific parameters
# ---------------------------------------------------------------------------
def test_params(args: argparse.Namespace) -> None:
    """Run benchmark with specific parameter overrides."""
    _set_optuna_profile(args.profile)
    params = dict(DEFAULTS)

    if args.param:
        for key, value in args.param:
            if key not in DEFAULTS:
                print(f"  Warning: unknown parameter '{key}', using anyway")
            try:
                if "." in value:
                    params[key] = float(value)
                else:
                    params[key] = int(value)
            except ValueError:
                print(f"  Error: cannot parse value '{value}' for '{key}'")
                return

    print()
    print("  Testing parameters:")
    for key, value in sorted(params.items()):
        default = DEFAULTS.get(key)
        marker = " *" if default is not None and value != default else ""
        print(f"    {key}: {value}{marker}")
    print()

    write_trial_config(params)

    print("  Running benchmark (--quick --json)...")
    print()

    result = subprocess.run(
        [sys.executable, str(RESEARCH_DIR / "benchmark.py"), "--quick"],
        cwd=str(PROJECT_DIR),
        env={**os.environ, "TRIAL_CONFIG": str(TRIAL_CONFIG)},
    )

    print()
    if result.returncode == 0:
        print("  Benchmark completed successfully.")
    else:
        print(f"  Benchmark exited with code {result.returncode}.")
    print()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _print_param_diff(params: dict[str, Any]) -> None:
    """Print parameter values highlighting differences from defaults."""
    changed = []
    unchanged = []

    for key in sorted(DEFAULTS.keys()):
        default = DEFAULTS[key]
        current = params.get(key, default)

        if isinstance(default, float):
            diff = abs(current - default) > 0.001
        else:
            diff = current != default

        if diff:
            if isinstance(default, float):
                changed.append(f"    {key}: {default} -> {current:.3f}")
            else:
                changed.append(f"    {key}: {default} -> {current}")
        else:
            unchanged.append(key)

    if changed:
        print(f"  Changed ({len(changed)}):")
        for line in changed:
            print(line)
    else:
        print("  No changes from defaults.")

    if unchanged:
        print(f"  Unchanged ({len(unchanged)}): {', '.join(unchanged)}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Particle Engine Parameter Optimizer",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent("""\
            examples:
              %(prog)s run --n-trials 50          Run 50 optimization trials
              %(prog)s run --n-trials 25 --resume  Resume and add 25 more trials
              %(prog)s show --top 10               Show top 10 results
              %(prog)s viz                         Generate interactive HTML plots
              %(prog)s apply                       Apply best Pareto-front params
              %(prog)s apply --trial 42            Apply specific trial's params
              %(prog)s test --param sand_density 160 --param oil_viscosity 3
        """),
    )

    subparsers = parser.add_subparsers(dest="command")

    # -- run --
    run_parser = subparsers.add_parser("run", help="Run optimization trials")
    run_parser.add_argument(
        "--n-trials", type=int, default=50, help="Number of trials (default: 50)"
    )
    run_parser.add_argument(
        "--timeout", type=int, default=3600, help="Max total seconds (default: 3600)"
    )
    run_parser.add_argument(
        "--study-name", default="particle_engine", help="Study name (default: particle_engine)"
    )
    run_parser.add_argument(
        "--resume", action="store_true", help="Resume existing study"
    )
    run_parser.add_argument(
        "--profile",
        choices=["balanced", "mobile", "exploratory"],
        default="balanced",
        help="Search-surface profile (default: balanced)",
    )

    # -- show --
    show_parser = subparsers.add_parser("show", help="Show optimization results")
    show_parser.add_argument(
        "--study-name", default="particle_engine", help="Study name"
    )
    show_parser.add_argument(
        "--top", type=int, default=10, help="Number of top results (default: 10)"
    )
    show_parser.add_argument(
        "--profile",
        choices=["balanced", "mobile", "exploratory"],
        default="balanced",
        help="Interpret results against this profile's manifest surface",
    )

    # -- viz --
    viz_parser = subparsers.add_parser("viz", help="Generate visualization plots")
    viz_parser.add_argument(
        "--study-name", default="particle_engine", help="Study name"
    )
    viz_parser.add_argument(
        "--profile",
        choices=["balanced", "mobile", "exploratory"],
        default="balanced",
        help="Profile label for visualization context",
    )

    # -- apply --
    apply_parser = subparsers.add_parser("apply", help="Apply best parameters")
    apply_parser.add_argument(
        "--study-name", default="particle_engine", help="Study name"
    )
    apply_parser.add_argument(
        "--trial", type=int, default=None, help="Specific trial number to apply"
    )
    apply_parser.add_argument(
        "--profile",
        choices=["balanced", "mobile", "exploratory"],
        default="balanced",
        help="Profile metadata to write with the applied config",
    )

    # -- test --
    test_parser = subparsers.add_parser("test", help="Test specific parameter values")
    test_parser.add_argument(
        "--param",
        nargs=2,
        action="append",
        metavar=("KEY", "VALUE"),
        help="Parameter key-value pair (repeatable)",
    )
    test_parser.add_argument(
        "--profile",
        choices=["balanced", "mobile", "exploratory"],
        default="balanced",
        help="Profile metadata for the generated trial config",
    )

    args = parser.parse_args()

    if args.command == "run":
        run_optimization(args)
    elif args.command == "show":
        show_results(args)
    elif args.command == "viz":
        generate_all_visualizations(args)
    elif args.command == "apply":
        apply_best_params(args)
    elif args.command == "test":
        test_params(args)
    else:
        parser.print_help()
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
