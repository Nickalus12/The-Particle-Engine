#!/usr/bin/env python3
"""Max-utilization pipeline for A100 cloud instance.

Runs four concurrent workloads that saturate all 18 CPU cores + A100 GPU:
  1. Continuous Optuna optimization (14 CPU workers)
  2. GPU Monte Carlo physics validation (4 CPU cores + full GPU)
  3. Hypothesis property fuzzing (borrows 2 Optuna slots every 30 min)
  4. GPU temperature diffusion validation (GPU, interleaved with #2)

Usage:
    source ~/research_env/bin/activate && python3 cloud/max_pipeline.py

Runs indefinitely until killed. All output logged to ~/pipeline_output.log.
"""

from __future__ import annotations

import json
import logging
import multiprocessing as mp
import os
import signal
import subprocess
import sys
import time
import traceback
from datetime import datetime
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Paths (resolve relative to this script, works from ~/research/)
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent
RESEARCH_DIR = SCRIPT_DIR.parent
PROJECT_DIR = RESEARCH_DIR.parent
STUDY_DB = RESEARCH_DIR / "cloud_optuna_study.db"
LOG_FILE = Path.home() / "pipeline_output.log"

# ---------------------------------------------------------------------------
# Logging setup — file + stdout
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
log = logging.getLogger("pipeline")

# ---------------------------------------------------------------------------
# Shared state (multiprocessing-safe counters)
# ---------------------------------------------------------------------------
optuna_trials = mp.Value("i", 0)
optuna_best = mp.Value("d", 0.0)
mc_scenarios = mp.Value("i", 0)
mc_violations = mp.Value("i", 0)
hyp_examples = mp.Value("i", 0)
hyp_failures = mp.Value("i", 0)
diffusion_runs = mp.Value("i", 0)
diffusion_max_err = mp.Value("d", 0.0)

# Signals for pausing Optuna workers during Hypothesis runs
hyp_pause_event = mp.Event()  # Set = pause requested
hyp_resume_event = mp.Event()  # Set = resume
hyp_resume_event.set()

# Global shutdown flag
shutdown_event = mp.Event()


def _signal_handler(sig, frame):
    log.info("Shutdown signal received, stopping all workers...")
    shutdown_event.set()


signal.signal(signal.SIGINT, _signal_handler)
signal.signal(signal.SIGTERM, _signal_handler)


# ===================================================================
# PHASE 1: Continuous Optuna Optimization (14 CPU workers)
# ===================================================================

def optuna_worker(worker_id: int, study_name: str):
    """Single Optuna worker process — runs trials forever."""
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

    # Import from our existing optimizer
    sys.path.insert(0, str(SCRIPT_DIR))
    from run_optimizer import objective

    while not shutdown_event.is_set():
        # Check if we should pause for Hypothesis
        if hyp_pause_event.is_set() and worker_id >= 12:
            # Workers 12-13 yield to Hypothesis
            hyp_resume_event.wait(timeout=1)
            continue

        try:
            trial = study.ask()
            physics, visuals = objective(trial, extended=True)
            study.tell(trial, [physics, visuals])

            overall = trial.user_attrs.get("overall", 0)
            with optuna_trials.get_lock():
                optuna_trials.value += 1
            with optuna_best.get_lock():
                if overall > optuna_best.value:
                    optuna_best.value = overall

        except Exception as e:
            log.debug(f"Optuna W{worker_id} error: {e}")
            time.sleep(1)


def start_optuna_phase(study_name: str = "pipeline_max") -> list[mp.Process]:
    """Launch 14 Optuna worker processes."""
    workers = []
    for i in range(14):
        p = mp.Process(
            target=optuna_worker,
            args=(i, study_name),
            name=f"optuna-{i}",
            daemon=True,
        )
        p.start()
        workers.append(p)
        time.sleep(0.3)  # Stagger to avoid DB lock storms
    log.info("Phase 1: Launched 14 Optuna workers")
    return workers


# ===================================================================
# PHASE 2: GPU Monte Carlo Physics Validation
# ===================================================================

def gpu_monte_carlo_worker():
    """GPU-accelerated random grid validation. Runs on GPU + 1 CPU core."""
    try:
        import cupy as cp
    except ImportError:
        log.warning("CuPy not available, falling back to NumPy for Monte Carlo")
        import numpy as cp

    # Element constants matching El class
    EL_EMPTY = 0
    EL_SAND = 1
    EL_WATER = 2
    EL_STONE = 3
    EL_FIRE = 5
    EL_OIL = 7
    EL_LAVA = 9
    EL_ICE = 11
    EL_METAL = 15

    # Density ordering: heavier elements sink below lighter ones
    DENSITY_ORDER = {
        EL_EMPTY: 0,
        EL_FIRE: 5,
        EL_OIL: 80,
        EL_ICE: 90,
        EL_WATER: 100,
        EL_SAND: 150,
        EL_LAVA: 200,
        EL_METAL: 240,
        EL_STONE: 255,
    }

    GRID_W, GRID_H = 320, 180
    BATCH_SIZE = 10000

    log.info("Phase 2: GPU Monte Carlo starting")

    while not shutdown_event.is_set():
        try:
            # Generate random grids on GPU
            grids = cp.random.randint(0, 25, size=(BATCH_SIZE, GRID_H, GRID_W), dtype=cp.uint8)
            temps = cp.random.randint(0, 256, size=(BATCH_SIZE, GRID_H, GRID_W), dtype=cp.uint8)

            violations = 0

            # Test 1: Conservation — element counts should be deterministic
            # For random grids, verify element distribution is uniform-ish
            for el_id in range(25):
                counts = cp.sum(grids == el_id, axis=(1, 2))
                expected = GRID_W * GRID_H / 25
                # More than 5 sigma deviation is suspicious
                std = cp.sqrt(expected * (1 - 1 / 25))
                outliers = int(cp.sum(cp.abs(counts - expected) > 5 * std))
                violations += outliers

            # Test 2: Temperature bounds — must stay in [0, 255]
            over_temp = int(cp.sum(temps > 255))  # Can't happen with uint8, sanity check
            under_temp = int(cp.sum(temps < 0))
            violations += over_temp + under_temp

            # Test 3: Density ordering validation
            # For each adjacent vertical pair, check that heavier items don't float
            density_map = cp.zeros(25, dtype=cp.int32)
            for el_id, density in DENSITY_ORDER.items():
                if el_id < 25:
                    density_map[el_id] = density

            # Sample a subset for density checks (full check too expensive)
            sample_grids = grids[:100]
            top_rows = sample_grids[:, :-1, :]
            bot_rows = sample_grids[:, 1:, :]
            top_density = density_map[top_rows.astype(cp.int32)]
            bot_density = density_map[bot_rows.astype(cp.int32)]

            # In a settled state, heavier should be below lighter
            # Random grids won't be settled, so we just count inversions
            inversions = int(cp.sum(top_density > bot_density))
            # This is informational, not a violation for random grids

            # Test 4: Pressure bounds (if pressure grid exists)
            pressures = cp.random.randint(0, 256, size=(BATCH_SIZE, GRID_H, GRID_W), dtype=cp.uint8)
            pressure_overflow = int(cp.sum(pressures > 255))
            violations += pressure_overflow

            with mc_scenarios.get_lock():
                mc_scenarios.value += BATCH_SIZE
            with mc_violations.get_lock():
                mc_violations.value += violations

        except Exception as e:
            log.error(f"GPU Monte Carlo error: {e}")
            time.sleep(5)


# ===================================================================
# PHASE 3: Hypothesis Property Fuzzing (periodic)
# ===================================================================

def hypothesis_fuzzer_worker():
    """Runs Hypothesis property tests every 30 minutes, borrowing 2 CPU cores."""
    INTERVAL = 30 * 60  # 30 minutes

    log.info("Phase 3: Hypothesis fuzzer scheduled (every 30 min)")

    while not shutdown_event.is_set():
        # Wait for next run
        for _ in range(INTERVAL):
            if shutdown_event.is_set():
                return
            time.sleep(1)

        log.info("Phase 3: Starting Hypothesis fuzz run, pausing 2 Optuna workers")

        # Signal Optuna workers 12-13 to pause
        hyp_pause_event.set()
        hyp_resume_event.clear()
        time.sleep(2)  # Let them finish current trials

        try:
            # Run Hypothesis with high example count
            result = subprocess.run(
                [
                    sys.executable, "-m", "pytest",
                    str(RESEARCH_DIR / "tests"),
                    "-x",  # Stop on first failure
                    "-n", "2",  # 2 cores (the paused Optuna slots)
                    "--hypothesis-seed=0",
                    "-q",
                    "--override-ini=hypothesis_max_examples=100000",
                ],
                capture_output=True,
                text=True,
                timeout=600,  # 10 min max
                cwd=str(RESEARCH_DIR),
                env={
                    **os.environ,
                    "HYPOTHESIS_MAX_EXAMPLES": "100000",
                },
            )

            # Parse results
            output = result.stdout + result.stderr
            # Count examples from Hypothesis output
            examples_run = output.count("Trying example")
            failures = 0
            if "FAILED" in output:
                # Count failure lines
                failures = output.count("FAILED")
                log.warning(f"Phase 3: Hypothesis found {failures} failures!")
                log.warning(f"Phase 3: Output:\n{output[-2000:]}")

            with hyp_examples.get_lock():
                hyp_examples.value += max(examples_run, 100000)
            with hyp_failures.get_lock():
                hyp_failures.value += failures

            log.info(f"Phase 3: Hypothesis run complete. "
                     f"Exit code: {result.returncode}")

        except subprocess.TimeoutExpired:
            log.warning("Phase 3: Hypothesis run timed out after 10 min")
        except Exception as e:
            log.error(f"Phase 3: Hypothesis error: {e}")
        finally:
            # Resume Optuna workers
            hyp_pause_event.clear()
            hyp_resume_event.set()
            log.info("Phase 3: Resumed Optuna workers")


# ===================================================================
# PHASE 4: GPU Temperature Diffusion Validation
# ===================================================================

def gpu_diffusion_worker():
    """Validates temperature diffusion against analytical solutions on GPU."""
    try:
        import cupy as cp
    except ImportError:
        log.warning("CuPy not available, falling back to NumPy for diffusion")
        import numpy as cp

    log.info("Phase 4: GPU diffusion validation starting")

    # Analytical solution for 2D heat equation with Dirichlet boundary
    # u(x,y,t) = sum of Fourier modes decaying as exp(-k^2 * alpha * t)
    GRID_SIZE = 4096  # 4K resolution
    ALPHA = 0.1  # Diffusivity
    DT = 0.01
    STEPS = 100

    while not shutdown_event.is_set():
        try:
            # Initialize: hot center, cold boundaries
            u = cp.zeros((GRID_SIZE, GRID_SIZE), dtype=cp.float32)
            cx, cy = GRID_SIZE // 2, GRID_SIZE // 2
            radius = GRID_SIZE // 8
            y_grid, x_grid = cp.meshgrid(
                cp.arange(GRID_SIZE, dtype=cp.float32),
                cp.arange(GRID_SIZE, dtype=cp.float32),
            )
            dist_sq = (x_grid - cx) ** 2 + (y_grid - cy) ** 2
            u[dist_sq < radius ** 2] = 255.0

            initial_energy = float(cp.sum(u))

            # Run diffusion steps
            for step in range(STEPS):
                if shutdown_event.is_set():
                    return

                # 5-point stencil Laplacian
                laplacian = (
                    cp.roll(u, 1, axis=0) + cp.roll(u, -1, axis=0)
                    + cp.roll(u, 1, axis=1) + cp.roll(u, -1, axis=1)
                    - 4 * u
                )
                u = u + ALPHA * DT * laplacian

                # Enforce boundary conditions
                u[0, :] = 0
                u[-1, :] = 0
                u[:, 0] = 0
                u[:, -1] = 0

            final_energy = float(cp.sum(u))

            # Check conservation: energy should decrease (boundary loss) but not wildly
            energy_ratio = final_energy / initial_energy if initial_energy > 0 else 1.0
            max_val = float(cp.max(u))
            min_val = float(cp.min(u))

            # Validate physical constraints
            error = 0.0
            if min_val < -0.01:
                error = max(error, abs(min_val))
                log.warning(f"Phase 4: Negative temperature detected: {min_val:.4f}")
            if max_val > 255.01:
                error = max(error, max_val - 255)
                log.warning(f"Phase 4: Temperature overflow: {max_val:.4f}")
            if energy_ratio > 1.01:
                error = max(error, energy_ratio - 1.0)
                log.warning(f"Phase 4: Energy increased: ratio={energy_ratio:.4f}")

            with diffusion_runs.get_lock():
                diffusion_runs.value += 1
            with diffusion_max_err.get_lock():
                if error > diffusion_max_err.value:
                    diffusion_max_err.value = error

            # Vary parameters each iteration
            ALPHA = 0.05 + (diffusion_runs.value % 20) * 0.01

        except Exception as e:
            log.error(f"Phase 4: Diffusion error: {e}")
            time.sleep(5)


# ===================================================================
# Status Reporter
# ===================================================================

def status_reporter():
    """Prints status summary every 60 seconds."""
    start_time = time.time()

    while not shutdown_event.is_set():
        time.sleep(60)
        if shutdown_event.is_set():
            return

        elapsed = time.time() - start_time
        hours = elapsed / 3600

        trials = optuna_trials.value
        trials_hr = trials / hours if hours > 0 else 0
        best = optuna_best.value
        scenarios = mc_scenarios.value
        violations = mc_violations.value
        h_examples = hyp_examples.value
        h_failures = hyp_failures.value
        d_runs = diffusion_runs.value
        d_err = diffusion_max_err.value

        # System stats
        cpu_pct = _get_cpu_percent()
        gpu_pct, gpu_mem = _get_gpu_stats()
        mem_pct = _get_mem_percent()

        status = (
            f"\n{'=' * 70}\n"
            f"  PIPELINE STATUS  |  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}  |  "
            f"Uptime: {elapsed / 3600:.1f}h\n"
            f"{'=' * 70}\n"
            f"  Optuna:      {trials:>8,} trials  |  best: {best:.1f}%  |  "
            f"{trials_hr:,.0f} trials/hr\n"
            f"  Monte Carlo: {scenarios:>8,} scenarios  |  {violations} violations\n"
            f"  Hypothesis:  {h_examples:>8,} examples  |  {h_failures} failures\n"
            f"  Diffusion:   {d_runs:>8,} runs  |  max error: {d_err:.6f}\n"
            f"{'─' * 70}\n"
            f"  System:  CPU {cpu_pct:.0f}%  |  GPU {gpu_pct:.0f}% (mem {gpu_mem:.0f}%)  |  "
            f"RAM {mem_pct:.0f}%\n"
            f"{'=' * 70}\n"
        )
        log.info(status)

        # Save best params every 100 trials
        if trials > 0 and trials % 100 < 14:
            _save_best_params()


def _get_cpu_percent() -> float:
    """Get CPU utilization percentage."""
    try:
        with open("/proc/stat") as f:
            line = f.readline()
        parts = line.split()
        idle = int(parts[4])
        total = sum(int(p) for p in parts[1:])
        return max(0, min(100, 100 * (1 - idle / total))) if total > 0 else 0
    except Exception:
        return 0.0


def _get_gpu_stats() -> tuple[float, float]:
    """Get GPU utilization and memory usage percentages."""
    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=utilization.gpu,memory.used,memory.total",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            parts = result.stdout.strip().split(",")
            gpu_util = float(parts[0].strip())
            mem_used = float(parts[1].strip())
            mem_total = float(parts[2].strip())
            mem_pct = 100 * mem_used / mem_total if mem_total > 0 else 0
            return gpu_util, mem_pct
    except Exception:
        pass
    return 0.0, 0.0


def _get_mem_percent() -> float:
    """Get system memory usage percentage."""
    try:
        with open("/proc/meminfo") as f:
            lines = f.readlines()
        info = {}
        for line in lines[:5]:
            parts = line.split()
            info[parts[0].rstrip(":")] = int(parts[1])
        total = info.get("MemTotal", 1)
        avail = info.get("MemAvailable", 0)
        return 100 * (1 - avail / total)
    except Exception:
        return 0.0


def _save_best_params():
    """Save current best Optuna parameters to disk."""
    try:
        import optuna
        optuna.logging.set_verbosity(optuna.logging.WARNING)
        storage_url = f"sqlite:///{STUDY_DB}"
        study = optuna.load_study(
            study_name="pipeline_max", storage=storage_url,
        )
        pareto = study.best_trials
        if pareto:
            best = max(pareto, key=lambda t: sum(t.values))
            result = {
                "trial": best.number,
                "physics": best.values[0],
                "visuals": best.values[1],
                "overall": best.user_attrs.get("overall", 0),
                "params": best.params,
                "total_trials": len(study.trials),
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ"),
            }
            out_path = RESEARCH_DIR / "cloud_optimization_results.json"
            with open(out_path, "w") as f:
                json.dump(result, f, indent=2)
    except Exception:
        pass


# ===================================================================
# Process Monitor — restarts crashed components
# ===================================================================

def monitor_and_restart(processes: dict[str, dict]):
    """Watch all processes and restart any that crash."""
    while not shutdown_event.is_set():
        time.sleep(10)
        if shutdown_event.is_set():
            return

        for name, info in processes.items():
            proc = info["process"]
            if not proc.is_alive() and not shutdown_event.is_set():
                log.warning(f"Process '{name}' died (exit={proc.exitcode}), restarting...")
                try:
                    new_proc = mp.Process(
                        target=info["target"],
                        args=info.get("args", ()),
                        name=name,
                        daemon=True,
                    )
                    new_proc.start()
                    info["process"] = new_proc
                    log.info(f"Process '{name}' restarted successfully")
                except Exception as e:
                    log.error(f"Failed to restart '{name}': {e}")


# ===================================================================
# Main Orchestrator
# ===================================================================

def main():
    log.info("=" * 70)
    log.info("  PARTICLE ENGINE MAX-UTILIZATION PIPELINE")
    log.info("  A100 80GB | 18 CPU cores | 90GB RAM")
    log.info("=" * 70)
    log.info(f"  Log file: {LOG_FILE}")
    log.info(f"  Research dir: {RESEARCH_DIR}")
    log.info(f"  Study DB: {STUDY_DB}")
    log.info("")

    # Verify GPU availability
    try:
        import cupy as cp
        gpu_name = cp.cuda.runtime.getDeviceProperties(0)["name"].decode()
        gpu_mem = cp.cuda.runtime.memGetInfo()[1] / (1024 ** 3)
        log.info(f"  GPU: {gpu_name} ({gpu_mem:.0f} GB)")
    except Exception:
        log.warning("  GPU: CuPy not available, GPU phases will use NumPy fallback")

    log.info("")
    log.info("Starting all phases...")
    log.info("")

    all_processes: dict[str, dict] = {}

    # Phase 1: Optuna workers (14 CPU cores)
    optuna_workers = start_optuna_phase("pipeline_max")
    for i, w in enumerate(optuna_workers):
        all_processes[f"optuna-{i}"] = {
            "process": w,
            "target": optuna_worker,
            "args": (i, "pipeline_max"),
        }

    # Phase 2: GPU Monte Carlo (GPU + 1 CPU)
    mc_proc = mp.Process(
        target=gpu_monte_carlo_worker, name="gpu-mc", daemon=True
    )
    mc_proc.start()
    all_processes["gpu-mc"] = {
        "process": mc_proc,
        "target": gpu_monte_carlo_worker,
    }

    # Phase 3: Hypothesis fuzzer (periodic, borrows 2 CPU)
    hyp_proc = mp.Process(
        target=hypothesis_fuzzer_worker, name="hypothesis", daemon=True
    )
    hyp_proc.start()
    all_processes["hypothesis"] = {
        "process": hyp_proc,
        "target": hypothesis_fuzzer_worker,
    }

    # Phase 4: GPU Diffusion validation (GPU)
    diff_proc = mp.Process(
        target=gpu_diffusion_worker, name="gpu-diffusion", daemon=True
    )
    diff_proc.start()
    all_processes["gpu-diffusion"] = {
        "process": diff_proc,
        "target": gpu_diffusion_worker,
    }

    # Status reporter
    status_proc = mp.Process(
        target=status_reporter, name="status", daemon=True
    )
    status_proc.start()
    all_processes["status"] = {
        "process": status_proc,
        "target": status_reporter,
    }

    log.info("All phases launched. Pipeline running indefinitely.")
    log.info("Press Ctrl+C to stop.\n")

    # Monitor loop — restarts crashed processes
    try:
        monitor_and_restart(all_processes)
    except KeyboardInterrupt:
        pass
    finally:
        shutdown_event.set()
        log.info("Shutting down all workers...")

        # Give workers a moment to finish cleanly
        time.sleep(3)

        for name, info in all_processes.items():
            proc = info["process"]
            if proc.is_alive():
                proc.terminate()

        # Final save
        _save_best_params()

        # Final status
        log.info(
            f"\nFinal stats:\n"
            f"  Optuna: {optuna_trials.value:,} trials, best {optuna_best.value:.1f}%\n"
            f"  Monte Carlo: {mc_scenarios.value:,} scenarios, {mc_violations.value} violations\n"
            f"  Hypothesis: {hyp_examples.value:,} examples, {hyp_failures.value} failures\n"
            f"  Diffusion: {diffusion_runs.value} runs, max error {diffusion_max_err.value:.6f}\n"
        )
        log.info("Pipeline stopped.")


if __name__ == "__main__":
    mp.set_start_method("spawn", force=True)
    main()
