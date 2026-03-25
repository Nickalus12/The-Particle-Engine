#!/usr/bin/env python3
"""Staged optimization pipeline for 230+ parameter space.

TPE struggles above ~30 parameters. This pipeline solves the problem with:

Stage 1: Sensitivity analysis -- rank all params by impact (fANOVA + perturbation)
Stage 2: Group top impactful params into manageable clusters (~6-15 each)
Stage 3: CMA-ES per group (6-15 params at a time = efficient)
Stage 4: Cross-group interaction tuning on top interacting pairs
Stage 5: Full-space validation run

Additionally supports:
- Multi-fidelity BOHB-style evaluation (quick reject, full eval on promising)
- Transfer learning / warm-start from previous best
- Auto-freezing of low-importance params
- Conditional parameter skipping

Usage:
    # Full staged pipeline
    python research/cloud/staged_optimizer.py --full-pipeline --trials 500

    # Just sensitivity analysis (Stage 1)
    python research/cloud/staged_optimizer.py --sensitivity-rank

    # Single group with CMA-ES
    python research/cloud/staged_optimizer.py --group density --trials 300

    # With warm-start from previous session
    python research/cloud/staged_optimizer.py --full-pipeline --warm-start --trials 500

    # Multi-fidelity mode (quick reject bad candidates)
    python research/cloud/staged_optimizer.py --full-pipeline --multi-fidelity --trials 500
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from pathlib import Path
from typing import Any

# Add parent to path for imports
SCRIPT_DIR = Path(__file__).resolve().parent
RESEARCH_DIR = SCRIPT_DIR.parent
PROJECT_DIR = RESEARCH_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))

from benchmark_optuna import (
    DEFAULT_PARAMS, PARAM_SPACE, PARAM_GROUPS, _INT_PARAMS,
    score_all, compute_aggregate, compute_sensitivity,
)
from system_profile import resolve_worker_count

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
STUDY_DB = RESEARCH_DIR / "cloud_staged_study.db"
BEST_PARAMS_PATH = RESEARCH_DIR / "cloud_best_params.json"
IMPORTANCE_PATH = RESEARCH_DIR / "cloud_param_importance.json"
PARETO_HISTORY_PATH = RESEARCH_DIR / "cloud_pareto_history.json"

# ---------------------------------------------------------------------------
# Stage 1: Sensitivity Analysis & Parameter Ranking
# ---------------------------------------------------------------------------

def rank_parameters_by_sensitivity(params: dict[str, Any] | None = None,
                                    ) -> list[tuple[str, float]]:
    """Rank all parameters by their impact on the score.

    Uses perturbation-based sensitivity: for each param, measure score
    change from +/-5% and +/-10%. Returns sorted list (most impactful first).
    """
    if params is None:
        params = dict(DEFAULT_PARAMS)

    sens = compute_sensitivity(params)
    ranked = sorted(sens.items(), key=lambda x: -x[1])
    return ranked


def rank_parameters_with_fanova(n_random_trials: int = 200,
                                 ) -> dict[str, float]:
    """Run fANOVA importance analysis using random exploration trials.

    fANOVA needs diverse coverage of the search space, so we use
    RandomSampler to generate trials, then analyze importance.
    """
    import optuna
    optuna.logging.set_verbosity(optuna.logging.WARNING)

    study = optuna.create_study(
        study_name="fanova_exploration",
        storage=f"sqlite:///{STUDY_DB}",
        direction="maximize",
        load_if_exists=True,
        sampler=optuna.samplers.RandomSampler(seed=42),
    )

    def objective(trial):
        params = {}
        for key, (lo, hi) in PARAM_SPACE.items():
            if key in _INT_PARAMS:
                params[key] = trial.suggest_int(key, int(lo), int(hi))
            else:
                params[key] = trial.suggest_float(key, lo, hi)
        scores = score_all(params)
        agg = compute_aggregate(scores)
        return agg["physics"]

    existing = len(study.trials)
    needed = max(0, n_random_trials - existing)
    if needed > 0:
        print(f"  Running {needed} random exploration trials for fANOVA...", flush=True)
        study.optimize(
            objective,
            n_trials=needed,
            n_jobs=resolve_worker_count("fanova"),
        )

    # Run fANOVA
    evaluator = optuna.importance.FanovaImportanceEvaluator(seed=42)
    importances = optuna.importance.get_param_importances(
        study, evaluator=evaluator
    )
    return dict(importances)


def combined_importance(perturbation_params: dict[str, Any] | None = None,
                         n_fanova_trials: int = 200,
                         ) -> dict[str, float]:
    """Combine perturbation sensitivity and fANOVA for robust ranking.

    Returns normalized importance scores (0-1) for each parameter.
    """
    # Perturbation-based
    pert_ranked = rank_parameters_by_sensitivity(perturbation_params)
    pert_max = max(v for _, v in pert_ranked) if pert_ranked else 1.0
    pert_scores = {k: v / pert_max for k, v in pert_ranked}

    # fANOVA-based
    try:
        fanova_scores = rank_parameters_with_fanova(n_fanova_trials)
        fanova_max = max(fanova_scores.values()) if fanova_scores else 1.0
        fanova_norm = {k: v / fanova_max for k, v in fanova_scores.items()}
    except Exception as e:
        print(f"  fANOVA failed ({e}), using perturbation only", flush=True)
        fanova_norm = {}

    # Combine: 60% fANOVA (if available) + 40% perturbation
    combined = {}
    all_keys = set(pert_scores.keys()) | set(fanova_norm.keys())
    for key in all_keys:
        p_score = pert_scores.get(key, 0.0)
        f_score = fanova_norm.get(key, 0.0)
        if fanova_norm:
            combined[key] = 0.6 * f_score + 0.4 * p_score
        else:
            combined[key] = p_score
    return combined


# ---------------------------------------------------------------------------
# Stage 2: Dynamic Group Formation
# ---------------------------------------------------------------------------

def form_dynamic_groups(importance: dict[str, float],
                         top_n: int = 50,
                         group_size: int = 8,
                         freeze_threshold: float = 0.02,
                         ) -> tuple[list[list[str]], list[str]]:
    """Form parameter groups based on importance ranking.

    Returns:
        (active_groups, frozen_params) where:
        - active_groups: list of param lists, each ~group_size, most important first
        - frozen_params: params below threshold, locked at current best
    """
    ranked = sorted(importance.items(), key=lambda x: -x[1])

    # Separate into active and frozen
    active_params = []
    frozen_params = []
    for key, score in ranked:
        if key not in PARAM_SPACE:
            continue
        if score < freeze_threshold and len(active_params) >= top_n:
            frozen_params.append(key)
        else:
            active_params.append(key)
            if len(active_params) >= top_n:
                # Remaining go to frozen unless they're above threshold
                continue

    # Also freeze any remaining params not in importance dict
    for key in PARAM_SPACE:
        if key not in importance:
            frozen_params.append(key)

    # Split active into groups
    groups = []
    for i in range(0, len(active_params), group_size):
        groups.append(active_params[i:i + group_size])

    return groups, frozen_params


# ---------------------------------------------------------------------------
# Stage 3: CMA-ES Per Group
# ---------------------------------------------------------------------------

def optimize_group(group_params: list[str],
                    fixed_params: dict[str, Any],
                    n_trials: int = 300,
                    n_workers: int = 4,
                    group_name: str = "unnamed",
                    use_warm_start: bool = False,
                    multi_fidelity: bool = False,
                    ) -> dict[str, Any]:
    """Optimize a single parameter group using CMA-ES.

    Args:
        group_params: list of param names to optimize
        fixed_params: all other params locked at these values
        n_trials: number of CMA-ES trials
        n_workers: parallel workers (CMA-ES prefers fewer, max 4)
        group_name: for study naming
        use_warm_start: seed initial population from previous best
        multi_fidelity: use quick-reject before full evaluation
    """
    import optuna
    optuna.logging.set_verbosity(optuna.logging.WARNING)

    n_group = len(group_params)
    tuned_workers = resolve_worker_count("staged", n_workers)
    actual_workers = min(tuned_workers, 8)

    # Build CMA-ES sampler with optional warm start
    sampler_kwargs = {"seed": 42}
    if use_warm_start and n_group <= 30:
        # Use separable CMA for larger groups
        if n_group > 15:
            sampler_kwargs["use_separable_cma"] = True
        # Provide initial mean from current best
        x0 = {}
        sigma0 = {}
        for key in group_params:
            if key in PARAM_SPACE:
                lo, hi = PARAM_SPACE[key]
                val = fixed_params.get(key, DEFAULT_PARAMS.get(key, (lo + hi) / 2))
                x0[key] = val
                sigma0[key] = (hi - lo) / 6  # ~3 sigma covers range
        if x0:
            sampler_kwargs["x0"] = x0
            sampler_kwargs["sigma0"] = max(sigma0.values()) if sigma0 else 0.1

    sampler = optuna.samplers.CmaEsSampler(**sampler_kwargs)

    study = optuna.create_study(
        study_name=f"staged_{group_name}",
        storage=f"sqlite:///{STUDY_DB}",
        direction="maximize",
        load_if_exists=True,
        sampler=sampler,
    )

    if multi_fidelity:
        # Multi-fidelity: quick score check, prune if below threshold
        quick_threshold = _estimate_quick_threshold(fixed_params)

        def objective(trial):
            params = dict(fixed_params)
            for key in group_params:
                if key not in PARAM_SPACE:
                    continue
                lo, hi = PARAM_SPACE[key]
                if key in _INT_PARAMS:
                    params[key] = trial.suggest_int(key, int(lo), int(hi))
                else:
                    params[key] = trial.suggest_float(key, lo, hi)

            # Quick evaluation: just score the group-relevant subscores
            scores = score_all(params)
            quick_score = sum(scores.values()) / len(scores) if scores else 0

            # Report intermediate for pruning
            trial.report(quick_score, step=0)
            if trial.should_prune():
                raise optuna.TrialPruned()

            # Full evaluation
            agg = compute_aggregate(scores)
            return agg["physics"]

        # Add median pruner for multi-fidelity
        study.pruner = optuna.pruners.MedianPruner(
            n_startup_trials=max(10, n_trials // 10),
            n_warmup_steps=0,
        )
    else:
        def objective(trial):
            params = dict(fixed_params)
            for key in group_params:
                if key not in PARAM_SPACE:
                    continue
                lo, hi = PARAM_SPACE[key]
                if key in _INT_PARAMS:
                    params[key] = trial.suggest_int(key, int(lo), int(hi))
                else:
                    params[key] = trial.suggest_float(key, lo, hi)

            scores = score_all(params)
            agg = compute_aggregate(scores)
            return agg["physics"]

    start = time.time()
    study.optimize(objective, n_trials=n_trials, n_jobs=actual_workers)
    elapsed = time.time() - start

    # Extract best
    result = dict(fixed_params)
    if study.best_trial:
        for key in group_params:
            if key in study.best_trial.params:
                result[key] = study.best_trial.params[key]

    return {
        "params": result,
        "best_score": study.best_value if study.best_trial else 0,
        "n_trials": len(study.trials),
        "elapsed_s": elapsed,
        "group_name": group_name,
    }


def _estimate_quick_threshold(params: dict[str, Any]) -> float:
    """Estimate a quick score threshold for multi-fidelity pruning."""
    scores = score_all(params)
    return sum(scores.values()) / len(scores) * 0.8  # 80% of current best


# ---------------------------------------------------------------------------
# Stage 4: Cross-Group Interaction Tuning
# ---------------------------------------------------------------------------

def tune_interactions(current_best: dict[str, Any],
                       importance: dict[str, float],
                       n_trials: int = 200,
                       top_interaction_params: int = 20,
                       ) -> dict[str, Any]:
    """Tune interactions between the most important params across groups.

    Takes the top N most important params regardless of group and runs
    a focused CMA-ES on just those, allowing cross-group interactions
    to be discovered.
    """
    import optuna
    optuna.logging.set_verbosity(optuna.logging.WARNING)

    # Pick top N params by importance
    ranked = sorted(importance.items(), key=lambda x: -x[1])
    interaction_params = [k for k, _ in ranked[:top_interaction_params]
                          if k in PARAM_SPACE]

    if len(interaction_params) < 2:
        print("  Too few important params for interaction tuning", flush=True)
        return {"params": current_best, "best_score": 0}

    print(f"\n  --- Cross-group interaction tuning ({len(interaction_params)} params) ---",
          flush=True)

    sampler = optuna.samplers.CmaEsSampler(
        seed=42,
        use_separable_cma=(len(interaction_params) > 15),
    )

    study = optuna.create_study(
        study_name="staged_interactions",
        storage=f"sqlite:///{STUDY_DB}",
        direction="maximize",
        load_if_exists=True,
        sampler=sampler,
    )

    def objective(trial):
        params = dict(current_best)
        for key in interaction_params:
            lo, hi = PARAM_SPACE[key]
            if key in _INT_PARAMS:
                params[key] = trial.suggest_int(key, int(lo), int(hi))
            else:
                params[key] = trial.suggest_float(key, lo, hi)
        scores = score_all(params)
        agg = compute_aggregate(scores)
        return agg["physics"]

    start = time.time()
    study.optimize(
        objective,
        n_trials=n_trials,
        n_jobs=min(resolve_worker_count("staged"), 8),
    )
    elapsed = time.time() - start

    result = dict(current_best)
    if study.best_trial:
        for key in interaction_params:
            if key in study.best_trial.params:
                result[key] = study.best_trial.params[key]

    return {
        "params": result,
        "best_score": study.best_value if study.best_trial else 0,
        "n_trials": len(study.trials),
        "elapsed_s": elapsed,
    }


# ---------------------------------------------------------------------------
# Stage 5: Full-Space Validation
# ---------------------------------------------------------------------------

def validate_full_space(params: dict[str, Any]) -> dict[str, float]:
    """Run full scoring on final parameters and report."""
    scores = score_all(params)
    agg = compute_aggregate(scores)

    # Sensitivity check
    sens = compute_sensitivity(params)
    flat = [k for k, v in sens.items() if v <= 0.001]

    return {
        **agg,
        "n_scores": len(scores),
        "n_flat_params": len(flat),
        "flat_params": flat,
    }


# ---------------------------------------------------------------------------
# Transfer Learning / Warm Start
# ---------------------------------------------------------------------------

def load_previous_best() -> dict[str, Any] | None:
    """Load previous best parameters for warm-starting."""
    if BEST_PARAMS_PATH.exists():
        with open(BEST_PARAMS_PATH) as f:
            data = json.load(f)
        if "params" in data:
            return data["params"]
    return None


def save_pareto_history(params: dict[str, Any], scores: dict[str, float]):
    """Append to Pareto history for future transfer learning."""
    history = []
    if PARETO_HISTORY_PATH.exists():
        try:
            with open(PARETO_HISTORY_PATH) as f:
                history = json.load(f)
        except (json.JSONDecodeError, KeyError):
            history = []

    history.append({
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "params": {k: (round(v, 6) if isinstance(v, float) else v)
                   for k, v in params.items()},
        "scores": scores,
    })

    # Keep last 50 entries
    if len(history) > 50:
        history = history[-50:]

    with open(PARETO_HISTORY_PATH, "w") as f:
        json.dump(history, f, indent=2)


def seed_from_history(study, param_keys: list[str], n_seeds: int = 10):
    """Seed a study with previous Pareto-optimal points.

    Enqueues the top N historical results as fixed trials so CMA-ES
    starts from a good region instead of random.
    """
    if not PARETO_HISTORY_PATH.exists():
        return 0

    try:
        with open(PARETO_HISTORY_PATH) as f:
            history = json.load(f)
    except (json.JSONDecodeError, KeyError):
        return 0

    if not history:
        return 0

    # Sort by physics score descending
    scored = [(h, h.get("scores", {}).get("physics", 0)) for h in history]
    scored.sort(key=lambda x: -x[1])

    seeded = 0
    for entry, _ in scored[:n_seeds]:
        trial_params = {}
        for key in param_keys:
            if key in entry.get("params", {}):
                val = entry["params"][key]
                if key in PARAM_SPACE:
                    lo, hi = PARAM_SPACE[key]
                    val = max(lo, min(hi, val))  # Clamp to bounds
                trial_params[key] = val

        if trial_params:
            study.enqueue_trial(trial_params)
            seeded += 1

    return seeded


# ---------------------------------------------------------------------------
# Full Pipeline
# ---------------------------------------------------------------------------

def run_full_pipeline(n_trials_per_group: int = 300,
                       n_workers: int = 4,
                       use_warm_start: bool = False,
                       multi_fidelity: bool = False,
                       top_params: int = 50,
                       freeze_threshold: float = 0.02,
                       ):
    """Run the complete 5-stage optimization pipeline."""
    pipeline_start = time.time()

    print(f"\n{'='*70}", flush=True)
    print(f"  STAGED OPTIMIZATION PIPELINE", flush=True)
    print(f"{'='*70}", flush=True)
    print(f"  Total params:      {len(PARAM_SPACE)}", flush=True)
    print(f"  Trials/group:      {n_trials_per_group}", flush=True)
    print(f"  Workers:           {n_workers}", flush=True)
    print(f"  Warm-start:        {use_warm_start}", flush=True)
    print(f"  Multi-fidelity:    {multi_fidelity}", flush=True)
    print(f"  Active top-N:      {top_params}", flush=True)
    print(f"  Freeze threshold:  {freeze_threshold}", flush=True)
    print(flush=True)

    # Initialize from previous best or defaults
    current_best = dict(DEFAULT_PARAMS)
    if use_warm_start:
        prev = load_previous_best()
        if prev:
            current_best.update(prev)
            print(f"  Warm-started from {BEST_PARAMS_PATH}", flush=True)

    # ── Stage 1: Sensitivity Analysis ──
    print(f"\n  {'─'*50}", flush=True)
    print(f"  STAGE 1: Sensitivity Analysis", flush=True)
    print(f"  {'─'*50}", flush=True)

    importance = combined_importance(current_best, n_fanova_trials=200)

    # Save importance
    with open(IMPORTANCE_PATH, "w") as f:
        json.dump({k: round(v, 6) for k, v in
                   sorted(importance.items(), key=lambda x: -x[1])}, f, indent=2)
    print(f"  Saved importance to {IMPORTANCE_PATH}", flush=True)

    # Show top 20
    ranked = sorted(importance.items(), key=lambda x: -x[1])
    print(f"\n  Top 20 most impactful parameters:", flush=True)
    for i, (k, v) in enumerate(ranked[:20]):
        bar = "#" * min(40, int(v * 40))
        print(f"    {i+1:3d}. {k:35s} {v:.4f}  {bar}", flush=True)

    n_frozen = sum(1 for _, v in ranked if v < freeze_threshold)
    print(f"\n  Frozen (importance < {freeze_threshold}): {n_frozen} params", flush=True)

    # ── Stage 2: Dynamic Group Formation ──
    print(f"\n  {'─'*50}", flush=True)
    print(f"  STAGE 2: Dynamic Group Formation", flush=True)
    print(f"  {'─'*50}", flush=True)

    groups, frozen = form_dynamic_groups(
        importance, top_n=top_params, group_size=8,
        freeze_threshold=freeze_threshold,
    )

    print(f"  Active groups: {len(groups)}", flush=True)
    for i, g in enumerate(groups):
        print(f"    Group {i+1}: {len(g)} params "
              f"({', '.join(g[:3])}{'...' if len(g) > 3 else ''})", flush=True)
    print(f"  Frozen params: {len(frozen)}", flush=True)

    # ── Stage 3: CMA-ES Per Group ──
    print(f"\n  {'─'*50}", flush=True)
    print(f"  STAGE 3: CMA-ES Per Group", flush=True)
    print(f"  {'─'*50}", flush=True)

    for i, group in enumerate(groups):
        group_name = f"dynamic_group_{i+1}"
        print(f"\n  Group {i+1}/{len(groups)}: {len(group)} params", flush=True)

        result = optimize_group(
            group_params=group,
            fixed_params=current_best,
            n_trials=n_trials_per_group,
            n_workers=n_workers,
            group_name=group_name,
            use_warm_start=use_warm_start,
            multi_fidelity=multi_fidelity,
        )

        # Merge results
        for key in group:
            if key in result["params"]:
                current_best[key] = result["params"][key]

        print(f"    Score: {result['best_score']:.2f} "
              f"({result['n_trials']} trials, {result['elapsed_s']:.0f}s)", flush=True)

    # ── Stage 4: Cross-Group Interaction Tuning ──
    print(f"\n  {'─'*50}", flush=True)
    print(f"  STAGE 4: Cross-Group Interaction Tuning", flush=True)
    print(f"  {'─'*50}", flush=True)

    interaction_result = tune_interactions(
        current_best, importance,
        n_trials=n_trials_per_group,
        top_interaction_params=min(20, top_params),
    )
    if interaction_result["best_score"] > 0:
        current_best.update(
            {k: v for k, v in interaction_result["params"].items()
             if k in PARAM_SPACE}
        )
        print(f"    Score: {interaction_result['best_score']:.2f} "
              f"({interaction_result['n_trials']} trials, "
              f"{interaction_result['elapsed_s']:.0f}s)", flush=True)

    # ── Stage 5: Full-Space Validation ──
    print(f"\n  {'─'*50}", flush=True)
    print(f"  STAGE 5: Full-Space Validation", flush=True)
    print(f"  {'─'*50}", flush=True)

    validation = validate_full_space(current_best)
    pipeline_elapsed = time.time() - pipeline_start

    print(f"\n{'='*70}", flush=True)
    print(f"  PIPELINE COMPLETE ({pipeline_elapsed:.0f}s total)", flush=True)
    print(f"{'='*70}", flush=True)
    for k, v in sorted(validation.items()):
        if k in ("flat_params",):
            continue
        print(f"    {k}: {v}", flush=True)

    if validation.get("n_flat_params", 0) > 0:
        print(f"\n  WARNING: {validation['n_flat_params']} params have zero sensitivity:",
              flush=True)
        for p in validation.get("flat_params", []):
            print(f"    - {p}", flush=True)

    # Save results
    with open(BEST_PARAMS_PATH, "w") as f:
        json.dump({
            "params": {k: (round(v, 6) if isinstance(v, float) else v)
                       for k, v in current_best.items()},
            "scores": {k: v for k, v in validation.items()
                       if isinstance(v, (int, float))},
            "strategy": "staged_pipeline",
            "pipeline_time_s": round(pipeline_elapsed, 1),
            "n_active_params": sum(len(g) for g in groups),
            "n_frozen_params": len(frozen),
        }, f, indent=2)
    print(f"\n  Saved: {BEST_PARAMS_PATH}", flush=True)

    # Save to Pareto history for future warm-starts
    save_pareto_history(current_best, validation)
    print(f"  Saved to Pareto history: {PARETO_HISTORY_PATH}", flush=True)

    return current_best, validation


# ---------------------------------------------------------------------------
# Predefined Group Optimization (uses PARAM_GROUPS from benchmark_optuna)
# ---------------------------------------------------------------------------

def run_predefined_groups(groups: list[str] | None = None,
                           n_trials: int = 300,
                           n_workers: int = 4,
                           use_warm_start: bool = False,
                           multi_fidelity: bool = False,
                           ):
    """Run CMA-ES on predefined parameter groups from benchmark_optuna."""
    target_groups = groups or list(PARAM_GROUPS.keys())
    current_best = dict(DEFAULT_PARAMS)

    if use_warm_start:
        prev = load_previous_best()
        if prev:
            current_best.update(prev)
            print(f"  Warm-started from {BEST_PARAMS_PATH}", flush=True)

    print(f"\n{'='*60}", flush=True)
    print(f"  PREDEFINED GROUP OPTIMIZATION", flush=True)
    print(f"{'='*60}", flush=True)
    total_start = time.time()

    for group_name in target_groups:
        if group_name not in PARAM_GROUPS:
            print(f"  WARNING: Unknown group '{group_name}', skipping", flush=True)
            continue

        group_params = PARAM_GROUPS[group_name]
        print(f"\n  Group: {group_name} ({len(group_params)} params)", flush=True)

        result = optimize_group(
            group_params=group_params,
            fixed_params=current_best,
            n_trials=n_trials,
            n_workers=n_workers,
            group_name=group_name,
            use_warm_start=use_warm_start,
            multi_fidelity=multi_fidelity,
        )

        for key in group_params:
            if key in result["params"]:
                current_best[key] = result["params"][key]

        print(f"    Score: {result['best_score']:.2f} "
              f"({result['n_trials']} trials, {result['elapsed_s']:.0f}s)", flush=True)

    total_elapsed = time.time() - total_start

    # Validate
    validation = validate_full_space(current_best)

    print(f"\n{'='*60}", flush=True)
    print(f"  FINAL RESULTS ({total_elapsed:.0f}s total)", flush=True)
    print(f"{'='*60}", flush=True)
    for k, v in sorted(validation.items()):
        if k in ("flat_params",):
            continue
        print(f"    {k}: {v}", flush=True)

    # Save
    with open(BEST_PARAMS_PATH, "w") as f:
        json.dump({
            "params": current_best,
            "scores": {k: v for k, v in validation.items()
                       if isinstance(v, (int, float))},
            "strategy": "predefined_groups",
        }, f, indent=2)
    print(f"\n  Saved: {BEST_PARAMS_PATH}", flush=True)

    save_pareto_history(current_best, validation)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Staged optimization pipeline for 230+ parameter space")

    parser.add_argument("--full-pipeline", action="store_true",
                        help="Run complete 5-stage pipeline")
    parser.add_argument("--predefined", action="store_true",
                        help="Run predefined group optimization")
    parser.add_argument("--sensitivity-rank", action="store_true",
                        help="Just run sensitivity ranking (Stage 1)")
    parser.add_argument("--group", type=str, default=None,
                        help="Optimize a single predefined group")

    parser.add_argument("--trials", type=int, default=300,
                        help="Trials per group (default: 300)")
    parser.add_argument("--workers", type=int, default=0,
                        help="Parallel workers (0 = auto-tune for host)")
    parser.add_argument("--warm-start", action="store_true",
                        help="Warm-start from previous best params")
    parser.add_argument("--multi-fidelity", action="store_true",
                        help="Use multi-fidelity (quick reject bad candidates)")
    parser.add_argument("--top-params", type=int, default=50,
                        help="Number of params to actively optimize (default: 50)")
    parser.add_argument("--freeze-threshold", type=float, default=0.02,
                        help="Importance threshold below which params are frozen")

    args = parser.parse_args()

    if args.sensitivity_rank:
        print("\n  Running combined sensitivity + fANOVA analysis...", flush=True)
        importance = combined_importance(n_fanova_trials=200)
        ranked = sorted(importance.items(), key=lambda x: -x[1])

        print(f"\n  Parameter Importance Ranking ({len(ranked)} params):", flush=True)
        print(f"  {'─'*60}", flush=True)
        for i, (k, v) in enumerate(ranked):
            bar = "#" * min(50, int(v * 50))
            status = "FROZEN" if v < args.freeze_threshold else ""
            print(f"  {i+1:4d}. {k:35s} {v:.4f}  {bar}  {status}", flush=True)

        with open(IMPORTANCE_PATH, "w") as f:
            json.dump({k: round(v, 6) for k, v in ranked}, f, indent=2)
        print(f"\n  Saved: {IMPORTANCE_PATH}", flush=True)
        return

    if args.group:
        run_predefined_groups(
            groups=[args.group],
            n_trials=args.trials,
            n_workers=args.workers,
            use_warm_start=args.warm_start,
            multi_fidelity=args.multi_fidelity,
        )
        return

    if args.predefined:
        run_predefined_groups(
            n_trials=args.trials,
            n_workers=args.workers,
            use_warm_start=args.warm_start,
            multi_fidelity=args.multi_fidelity,
        )
        return

    if args.full_pipeline:
        run_full_pipeline(
            n_trials_per_group=args.trials,
            n_workers=args.workers,
            use_warm_start=args.warm_start,
            multi_fidelity=args.multi_fidelity,
            top_params=args.top_params,
            freeze_threshold=args.freeze_threshold,
        )
        return

    # Default: show help
    parser.print_help()


if __name__ == "__main__":
    main()
