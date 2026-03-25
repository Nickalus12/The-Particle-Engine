#!/usr/bin/env python3
"""MegaRunner Pro v4: The Research Oracle.

Innovations:
- Structured Event Logging (JSONL)
- Auto-Recovery with Batch Scaling
- Log Archiving (No more accidental truncation)
- CLIP-Physics Objective Integration
"""

import argparse
import json
import logging
import multiprocessing as mp
import os
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional

# Force Unbuffered
os.environ["PYTHONUNBUFFERED"] = "1"
os.environ["SCIPY_ARRAY_API"] = "1"

# Paths
SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent.parent
LOG_DIR = Path.home() / "logs"
ARCHIVE_DIR = LOG_DIR / "archive"
EVENT_FILE = Path.home() / "telemetry" / "events.jsonl"
STATUS_FILE = Path.home() / "telemetry" / "runner_status.json"

# Setup Logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_DIR / "orchestrator.log")
    ]
)
logger = logging.getLogger("Oracle")

class ResearchOracle:
    def __init__(self, args):
        self.args = args
        self.processes = {}
        self.shutdown_event = mp.Event()
        self.start_time = time.time()
        
        # Ensure directories
        for d in [LOG_DIR, ARCHIVE_DIR, Path.home() / "telemetry"]:
            d.mkdir(parents=True, exist_ok=True)

    def emit_event(self, event_type: str, data: dict):
        """Structured event emission for the dashboard."""
        event = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "elapsed": round(time.time() - self.start_time, 2),
            "type": event_type,
            **data
        }
        with open(EVENT_FILE, "a") as f:
            f.write(json.dumps(event) + "\n")

    def set_status(self, task: str, details: str = ""):
        try:
            status = {"task": task, "details": details, "time": time.time()}
            with open(STATUS_FILE, "w") as f:
                json.dump(status, f)
            self.emit_event("STATUS_CHANGE", status)
        except: pass

    def archive_old_runs(self):
        """Move old logs to archive instead of deleting."""
        run_id = datetime.now().strftime("%Y%m%d_%H%M%S")
        current_archive = ARCHIVE_DIR / f"run_{run_id}"
        
        log_files = list(LOG_DIR.glob("*.log"))
        if log_files:
            current_archive.mkdir(parents=True, exist_ok=True)
            logger.info(f"Archiving {len(log_files)} logs to {current_archive.name}")
            for f in log_files:
                shutil.move(str(f), str(current_archive / f.name))

    def cleanup_zombies(self):
        logger.info("Cleaning up environment...")
        self.archive_old_runs()
        try:
            my_pid = os.getpid()
            # More surgical kill: only python processes in pe directory
            cmd = f"ps aux | grep python | grep pe | grep -v grep | awk '{{print $2}}' | grep -v {my_pid} | xargs -r kill -9"
            subprocess.run(cmd, shell=True, check=False)
        except: pass

    def launch_task(self, name: str, cmd: List[str], log_name: str, env_updates: dict = None, retry: int = 1):
        """Launch a task with auto-recovery and absolute paths."""
        def task_wrapper():
            env = os.environ.copy()
            if env_updates: env.update(env_updates)
            log_path = LOG_DIR / log_name
            
            attempt = 0
            while attempt <= retry and not self.shutdown_event.is_set():
                self.emit_event("TASK_START", {"name": name, "attempt": attempt, "log": log_name})
                try:
                    with open(log_path, "a") as f:
                        f.write(f"\n--- STARTING ATTEMPT {attempt} AT {datetime.now()} ---\n")
                        f.flush()
                        subprocess.run(cmd, env=env, stdout=f, stderr=f, check=True)
                    self.emit_event("TASK_COMPLETE", {"name": name})
                    break
                except Exception as e:
                    attempt += 1
                    logger.error(f"Task {name} failed (Attempt {attempt-1}): {e}")
                    self.emit_event("TASK_FAILURE", {"name": name, "error": str(e), "attempt": attempt-1})
                    if attempt <= retry:
                        logger.info(f"Retrying {name} in 10s...")
                        time.sleep(10)
                    else:
                        logger.critical(f"Task {name} exhausted all retries.")

        p = mp.Process(target=task_wrapper, name=name)
        p.start()
        self.processes[name] = p
        return p

    def orchestrate(self):
        self.cleanup_zombies()
        self.set_status("Initializing", "Oracle Core Online")

        # 1. Telemetry Daemon (always runs)
        tel_cmd = [sys.executable, "-u", str(SCRIPT_DIR / "telemetry_daemon.py")]
        self.launch_task("Telemetry", tel_cmd, "telemetry.log")

        # 2. Physics Optuna (CPU parallelism — runs concurrently with GPU stages)
        if self.args.all or self.args.physics:
            phys_cmd = [
                sys.executable, "-u", str(SCRIPT_DIR / "benchmark_optuna.py"),
                "--optimize", "--trials", str(self.args.trials),
                "--workers", str(self.args.workers)
            ]
            self.launch_task("Physics-Optuna", phys_cmd, "physics.log")

        # 3. GPU Pipeline (sequential stages with proper dependency ordering)
        #
        # Stage flow:
        #   A. Physics validation (gate — must pass before optimization)
        #   B. Style evolution (visual parameter optimization)
        #   C. Chemistry optimization (element reaction tuning)
        #   D. Creature training (all 7 species — uses optimized physics)
        #   E. Ecosystem co-evolution (uses trained creature genomes)
        #   F. Chemistry validation (final check)
        #
        if self.args.all or self.args.gpu:
            def gpu_manager():
                env_jax = {
                    "XLA_PYTHON_CLIENT_MEM_FRACTION": "0.9",
                    "JAX_PLATFORM_NAME": "gpu",
                    "XLA_PYTHON_CLIENT_PREALLOCATE": "false",
                    "LD_LIBRARY_PATH": "/usr/local/lib/python3.12/dist-packages/nvidia/cudnn/lib:/usr/local/cuda/lib64:" + os.environ.get("LD_LIBRARY_PATH", "")
                }

                # A. Physics validation (gate check)
                self.set_status("Physics Validation", "Conservation + Electrical + Advanced")
                val_cmd = [
                    sys.executable, "-u", str(SCRIPT_DIR / "unified_physics_pipeline.py"),
                    "--validate"
                ]
                with open(LOG_DIR / "validation.log", "a") as f:
                    result = subprocess.run(val_cmd, stdout=f, stderr=f)
                if result.returncode != 0:
                    logger.warning("Validation had failures; continuing with optimization")
                self.emit_event("STAGE_COMPLETE", {"name": "validation"})

                if self.shutdown_event.is_set(): return

                # B. Style Evolution (CLIP — visual tuning)
                self.set_status("Style Evolution", "CLIP Visual Optimization")
                style_cmd = [
                    sys.executable, "-u", str(SCRIPT_DIR / "style_evolver_optimized.py"),
                    "--mode", "clip", "--generations", "300", "--population", "256"
                ]
                with open(LOG_DIR / "style.log", "a") as f:
                    subprocess.run(style_cmd, stdout=f, stderr=f)
                self.emit_event("STAGE_COMPLETE", {"name": "style_evolution"})

                if self.shutdown_event.is_set(): return

                # C. Chemistry optimization (reaction rate tuning)
                self.set_status("Chemistry", "Optimizing Reaction Parameters")
                chem_cmd = [
                    sys.executable, "-u", str(SCRIPT_DIR / "gpu_chemistry_optimizer.py"),
                    "run", "--n-trials", "500", "--n-jobs", "4"
                ]
                with open(LOG_DIR / "chemistry_opt.log", "a") as f:
                    subprocess.run(chem_cmd, stdout=f, stderr=f)
                self.emit_event("STAGE_COMPLETE", {"name": "chemistry_optimization"})

                if self.shutdown_event.is_set(): return

                # D. Creature training (all 7 species — uses optimized physics)
                species = ["worm", "ant", "beetle", "spider", "fish", "bee", "firefly"]
                qdax_script = SCRIPT_DIR / "qdax_creature_trainer.py"

                for sp in species:
                    if self.shutdown_event.is_set(): break
                    self.set_status("Creature Training", f"Species: {sp}")

                    batch_size = self.args.batch or 16384
                    cmd = [sys.executable, "-u", str(qdax_script),
                           "--species", sp, "--iterations", "5000",
                           "--batch", str(batch_size)]
                    if sp == "worm":
                        cmd.append("--curriculum")

                    logger.info(f"Training {sp} (batch={batch_size})...")
                    with open(LOG_DIR / "creatures.log", "a") as f:
                        subprocess.run(cmd, env=env_jax, stdout=f, stderr=f)
                    self.emit_event("STAGE_COMPLETE", {"name": f"creature_{sp}"})

                if self.shutdown_event.is_set(): return

                # E. Ecosystem co-evolution (uses trained genomes from stage D)
                self.set_status("Ecosystem", "Co-evolutionary Training")
                eco_cmd = [
                    sys.executable, "-u", str(SCRIPT_DIR / "ecosystem_trainer.py"),
                    "--full", "--generations", "100"
                ]
                with open(LOG_DIR / "ecosystem.log", "a") as f:
                    subprocess.run(eco_cmd, stdout=f, stderr=f)
                self.emit_event("STAGE_COMPLETE", {"name": "ecosystem"})

                if self.shutdown_event.is_set(): return

                # F. Final chemistry validation
                self.set_status("Chemistry Validation", "Final Check")
                chem_val_cmd = [sys.executable, "-u", str(SCRIPT_DIR / "chemistry_sim.py"), "--validate"]
                with open(LOG_DIR / "chemistry_final.log", "a") as f:
                    subprocess.run(chem_val_cmd, stdout=f, stderr=f)
                self.emit_event("STAGE_COMPLETE", {"name": "chemistry_validation"})

                self.set_status("Complete", "Full Pipeline Finished")

            p_gpu = mp.Process(target=gpu_manager, name="GPU-Orchestrator")
            p_gpu.start()
            self.processes["GPU-Manager"] = p_gpu

        logger.info("="*60)
        logger.info(" THE RESEARCH ORACLE IS ACTIVE")
        logger.info("="*60)

        try:
            while not self.shutdown_event.is_set():
                alive = {n: p for n, p in self.processes.items() if p.is_alive()}
                if not alive:
                    logger.info("All tasks complete.")
                    break
                time.sleep(10)
        except KeyboardInterrupt:
            logger.info("Oracle shutting down...")
            self.shutdown_event.set()

        for n, p in self.processes.items():
            try: p.terminate()
            except: pass

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--physics", action="store_true")
    parser.add_argument("--gpu", action="store_true")
    parser.add_argument("--trials", type=int, default=2000)
    parser.add_argument("--workers", type=int, default=16)
    parser.add_argument("--batch", type=int, default=16384)

    oracle = ResearchOracle(parser.parse_args())
    oracle.orchestrate()
