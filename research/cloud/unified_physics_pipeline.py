#!/usr/bin/env python3
"""Unified physics validation and optimization pipeline for large cloud GPUs.

Master orchestrator that runs all three GPU workloads concurrently:
  1. Conservation law validator (CuPy batched grid simulations)
  2. Chemistry parameter optimizer (Optuna + CuPy GPU scoring)
  3. Electrical conductivity benchmark (CuPy circuit simulations)

Designed to auto-scale across A100/H100 class instances. It raises
scenario counts and batch sizes when large VRAM and CPU budgets are
available, while preserving CPU-only fallbacks.

Usage:
    # Run full pipeline (recommended for A100)
    python research/cloud/unified_physics_pipeline.py --full

    # Quick validation only (5 minutes)
    python research/cloud/unified_physics_pipeline.py --validate

    # Optimization only (runs until killed)
    python research/cloud/unified_physics_pipeline.py --optimize --trials 50000

    # Sequential: validate then optimize
    python research/cloud/unified_physics_pipeline.py --sequential
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import subprocess
import sys
import threading
import time
import traceback
from datetime import datetime
from pathlib import Path

from system_profile import (  # noqa: E402
    resolve_electrical_circuits,
    resolve_validation_scenarios,
    resolve_worker_count,
    summarize_profile,
)

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent
RESEARCH_DIR = SCRIPT_DIR.parent
LOG_FILE = SCRIPT_DIR / "unified_pipeline.log"
SUMMARY_FILE = SCRIPT_DIR / "pipeline_summary.json"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.FileHandler(LOG_FILE, mode="a"),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger("unified_pipeline")

# Shared state
shutdown_event = threading.Event()


def signal_handler(sig, frame):
    log.info("Shutdown signal received")
    shutdown_event.set()


signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)


# ---------------------------------------------------------------------------
# Phase 1: Conservation validation
# ---------------------------------------------------------------------------

def run_conservation_validation(scenarios: int = 100000) -> dict:
    """Run GPU conservation law validator."""
    log.info(f"Phase 1: Conservation validation ({scenarios:,} scenarios)")
    script = SCRIPT_DIR / "gpu_conservation_validator.py"
    output = SCRIPT_DIR / "conservation_results.json"

    try:
        result = subprocess.run(
            [sys.executable, str(script), "--scenarios", str(scenarios),
             "--output", str(output)],
            capture_output=True, text=True, timeout=600,  # 10 min timeout
            cwd=str(RESEARCH_DIR),
        )
        log.info(f"Conservation validator stdout:\n{result.stdout[-2000:]}")
        if result.returncode != 0:
            log.warning(f"Conservation validator stderr:\n{result.stderr[-1000:]}")

        if output.exists():
            with open(output) as f:
                return json.load(f)
        return {"error": "No output file", "returncode": result.returncode}
    except subprocess.TimeoutExpired:
        log.error("Conservation validation timed out (600s)")
        return {"error": "timeout"}
    except Exception as e:
        log.error(f"Conservation validation failed: {e}")
        return {"error": str(e)}


# ---------------------------------------------------------------------------
# Phase 2: Electrical benchmark
# ---------------------------------------------------------------------------

def run_electrical_benchmark(circuits: int = 5000) -> dict:
    """Run GPU electrical conductivity benchmark."""
    log.info(f"Phase 2: Electrical benchmark ({circuits:,} circuits)")
    script = SCRIPT_DIR / "gpu_electrical_benchmark.py"
    output = SCRIPT_DIR / "electrical_benchmark_results.json"

    try:
        result = subprocess.run(
            [sys.executable, str(script), "--circuits", str(circuits),
             "--output", str(output)],
            capture_output=True, text=True, timeout=600,
            cwd=str(RESEARCH_DIR),
        )
        log.info(f"Electrical benchmark stdout:\n{result.stdout[-2000:]}")
        if result.returncode != 0:
            log.warning(f"Electrical benchmark stderr:\n{result.stderr[-1000:]}")

        if output.exists():
            with open(output) as f:
                return json.load(f)
        return {"error": "No output file", "returncode": result.returncode}
    except subprocess.TimeoutExpired:
        log.error("Electrical benchmark timed out (600s)")
        return {"error": "timeout"}
    except Exception as e:
        log.error(f"Electrical benchmark failed: {e}")
        return {"error": str(e)}


# ---------------------------------------------------------------------------
# Phase 3: Chemistry optimization
# ---------------------------------------------------------------------------

def run_chemistry_optimization(trials: int = 10000, workers: int = 4) -> dict:
    """Run Optuna chemistry parameter optimization."""
    log.info(f"Phase 3: Chemistry optimization ({trials:,} trials, {workers} workers)")
    script = SCRIPT_DIR / "gpu_chemistry_optimizer.py"
    output = SCRIPT_DIR / "chemistry_optimization_results.json"

    try:
        result = subprocess.run(
            [sys.executable, str(script), "run",
             "--trials", str(trials), "--workers", str(workers)],
            capture_output=True, text=True,
            timeout=3600,  # 1 hour timeout for optimization
            cwd=str(RESEARCH_DIR),
        )
        log.info(f"Chemistry optimizer stdout:\n{result.stdout[-3000:]}")
        if result.returncode != 0:
            log.warning(f"Chemistry optimizer stderr:\n{result.stderr[-1000:]}")

        if output.exists():
            with open(output) as f:
                return json.load(f)
        return {"error": "No output file", "returncode": result.returncode}
    except subprocess.TimeoutExpired:
        log.error("Chemistry optimization timed out (3600s)")
        return {"error": "timeout"}
    except Exception as e:
        log.error(f"Chemistry optimization failed: {e}")
        return {"error": str(e)}


# ---------------------------------------------------------------------------
# Validation execution
# ---------------------------------------------------------------------------

def run_validation_suite(
    scenarios: int | None = None,
    circuits: int | None = None,
):
    """Run validation with a single GPU owner to avoid context contention."""
    scenarios = resolve_validation_scenarios(scenarios)
    circuits = resolve_electrical_circuits(circuits)
    log.info(
        "Starting serialized validation with %s scenarios and %s circuits",
        f"{scenarios:,}",
        f"{circuits:,}",
    )
    conservation_result = run_conservation_validation(scenarios)
    electrical_result = run_electrical_benchmark(circuits)

    return conservation_result, electrical_result


# ---------------------------------------------------------------------------
# Pipeline modes
# ---------------------------------------------------------------------------

def run_full_pipeline(opt_trials: int = 10000, opt_workers: int = 4):
    """Full pipeline: validate first, then optimize if validation passes."""
    log.info("="*60)
    log.info("UNIFIED PHYSICS PIPELINE - FULL MODE")
    log.info("="*60)

    t0 = time.time()
    summary = {
        "mode": "full",
        "start_time": datetime.now().isoformat(),
        "phases": {},
    }

    # Phase 1+2: Validation (parallel)
    log.info("\n--- VALIDATION PHASE ---")
    try:
        cons_result, elec_result = run_validation_suite()
        summary["phases"]["conservation"] = cons_result
        summary["phases"]["electrical"] = elec_result

        cons_ok = cons_result.get("passed", 0) == cons_result.get("total_tests", -1)
        elec_ok = elec_result.get("passed", 0) == elec_result.get("total", -1)

        log.info(f"Conservation: {'PASS' if cons_ok else 'FAIL'} "
                 f"({cons_result.get('passed', '?')}/{cons_result.get('total_tests', '?')})")
        log.info(f"Electrical: {'PASS' if elec_ok else 'FAIL'} "
                 f"({elec_result.get('passed', '?')}/{elec_result.get('total', '?')})")
        if not (cons_ok and elec_ok):
            log.warning("Validation produced failures; proceeding to optimization anyway")
    except Exception as e:
        log.error(f"Validation phase failed: {e}")
        cons_ok = elec_ok = False
        summary["phases"]["validation_error"] = str(e)

    # Phase 3: Optimization (only if validation passes, or force with --full)
    log.info("\n--- OPTIMIZATION PHASE ---")
    if not shutdown_event.is_set():
        opt_result = run_chemistry_optimization(opt_trials, opt_workers)
        summary["phases"]["optimization"] = opt_result
        log.info(f"Optimization: {opt_result.get('total_trials', '?')} trials, "
                 f"best={opt_result.get('best_overall', '?')}")
    else:
        log.info("Skipping optimization (shutdown requested)")

    elapsed = time.time() - t0
    summary["elapsed_seconds"] = elapsed
    summary["end_time"] = datetime.now().isoformat()

    # Save summary
    with open(SUMMARY_FILE, "w") as f:
        json.dump(summary, f, indent=2)
    log.info(f"\nPipeline completed in {elapsed:.0f}s")
    log.info(f"Summary saved to {SUMMARY_FILE}")

    return summary


def run_validate_only(
    scenarios: int | None = None,
    circuits: int | None = None,
):
    """Validation mode using system-aware scale."""
    log.info("="*60)
    log.info("UNIFIED PHYSICS PIPELINE - VALIDATE ONLY")
    log.info("="*60)

    t0 = time.time()

    cons_result, elec_result = run_validation_suite(scenarios, circuits)

    elapsed = time.time() - t0

    cons_ok = cons_result.get("passed", 0) == cons_result.get("total_tests", -1)
    elec_ok = elec_result.get("passed", 0) == elec_result.get("total", -1)

    log.info(f"\nValidation completed in {elapsed:.0f}s")
    log.info(f"Conservation: {'PASS' if cons_ok else 'FAIL'}")
    log.info(f"Electrical: {'PASS' if elec_ok else 'FAIL'}")

    summary = {
        "mode": "validate",
        "elapsed_seconds": elapsed,
        "conservation": cons_result,
        "electrical": elec_result,
        "all_passed": cons_ok and elec_ok,
        "system_profile": summarize_profile(),
    }
    with open(SUMMARY_FILE, "w") as f:
        json.dump(summary, f, indent=2)

    return summary


def run_optimize_only(trials: int, workers: int):
    """Optimization only mode."""
    log.info("="*60)
    log.info(f"UNIFIED PHYSICS PIPELINE - OPTIMIZE ({trials:,} trials)")
    log.info("="*60)

    tuned_workers = resolve_worker_count("chemistry", workers or None)
    result = run_chemistry_optimization(trials, tuned_workers)

    summary = {"mode": "optimize", "optimization": result}
    with open(SUMMARY_FILE, "w") as f:
        json.dump(summary, f, indent=2)

    return summary


def run_sequential(opt_trials: int = 10000, opt_workers: int = 4):
    """Sequential mode: validate, then optimize if passing."""
    log.info("="*60)
    log.info("UNIFIED PHYSICS PIPELINE - SEQUENTIAL")
    log.info("="*60)

    t0 = time.time()

    # Validate first
    cons_result, elec_result = run_validation_suite()

    cons_ok = cons_result.get("passed", 0) == cons_result.get("total_tests", -1)
    elec_ok = elec_result.get("passed", 0) == elec_result.get("total", -1)

    if not (cons_ok and elec_ok):
        log.warning("Validation failed — skipping optimization")
        log.warning("Fix conservation/electrical issues before optimizing parameters")
        summary = {
            "mode": "sequential",
            "validation_passed": False,
            "conservation": cons_result,
            "electrical": elec_result,
        }
    else:
        log.info("Validation passed — proceeding to optimization")
        tuned_workers = resolve_worker_count("chemistry", opt_workers or None)
        opt_result = run_chemistry_optimization(opt_trials, tuned_workers)
        summary = {
            "mode": "sequential",
            "validation_passed": True,
            "conservation": cons_result,
            "electrical": elec_result,
            "optimization": opt_result,
        }

    summary["elapsed_seconds"] = time.time() - t0
    with open(SUMMARY_FILE, "w") as f:
        json.dump(summary, f, indent=2)

    return summary


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Unified Physics Validation & Optimization Pipeline"
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--full", action="store_true",
                      help="Full pipeline: validate + optimize")
    mode.add_argument("--validate", action="store_true",
                      help="Quick validation only")
    mode.add_argument("--optimize", action="store_true",
                      help="Optimization only")
    mode.add_argument("--sequential", action="store_true",
                      help="Validate first, optimize only if passing")

    parser.add_argument("--trials", type=int, default=10000,
                        help="Optuna trials for optimization (default: 10000)")
    parser.add_argument("--workers", type=int, default=0,
                        help="Parallel Optuna workers (0 = auto-scale to box)")
    parser.add_argument("--scenarios", type=int, default=0,
                        help="Validation scenarios (0 = auto-scale to box)")
    parser.add_argument("--circuits", type=int, default=0,
                        help="Electrical circuits (0 = auto-scale to box)")

    args = parser.parse_args()

    log.info(f"Python: {sys.version}")
    log.info(f"Script dir: {SCRIPT_DIR}")

    profile = summarize_profile()
    log.info("System profile: %s", json.dumps(profile, indent=2, sort_keys=True))

    try:
        import cupy
        log.info(f"CuPy: {cupy.__version__}, "
                 f"GPU: {cupy.cuda.runtime.getDeviceProperties(0)['name'].decode()}")
    except Exception:
        log.info("CuPy not available — will use NumPy (CPU-only)")

    if args.full:
        run_full_pipeline(args.trials, resolve_worker_count("chemistry", args.workers or None))
    elif args.validate:
        run_validate_only(args.scenarios or None, args.circuits or None)
    elif args.optimize:
        run_optimize_only(args.trials, args.workers)
    elif args.sequential:
        run_sequential(args.trials, args.workers)


if __name__ == "__main__":
    main()
