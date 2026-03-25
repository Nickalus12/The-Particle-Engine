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

        # 1. Telemetry Daemon (Backbone)
        tel_cmd = [sys.executable, "-u", str(SCRIPT_DIR / "telemetry_daemon.py")]
        self.launch_task("Telemetry", tel_cmd, "telemetry.log")

        # 2. Physics Optuna (Maximum Parallelism)
        if self.args.all or self.args.physics:
            phys_cmd = [
                sys.executable, "-u", str(SCRIPT_DIR / "benchmark_optuna.py"),
                "--optimize", "--trials", str(self.args.trials),
                "--workers", str(self.args.workers)
            ]
            self.launch_task("Physics-Optuna", phys_cmd, "physics.log")

        # 3. GPU Sequence (Maximized scale)
        if self.args.all or self.args.gpu:
            def gpu_manager():
                # A. Style Evolution (CLIP)
                # Innovation: Feedback best score to status
                style_cmd = [
                    sys.executable, "-u", str(SCRIPT_DIR / "style_evolver_optimized.py"),
                    "--mode", "clip", "--generations", "300", "--population", "256"
                ]
                self.set_status("Style Evolution", "High-Scale CLIP")
                
                # We run this sync within the manager process to handle dependencies
                log_path = LOG_DIR / "style.log"
                with open(log_path, "a") as f:
                    subprocess.run(style_cmd, stdout=f, stderr=f)

                # B. QDax Creature Suite (Massive JAX Batching)
                species = ["worm", "ant", "beetle", "spider", "fish", "bee", "firefly"]
                qdax_script = SCRIPT_DIR / "qdax_creature_trainer.py"
                
                for sp in species:
                    if self.shutdown_event.is_set(): break
                    self.set_status("QDax Training", f"Species: {sp}")
                    
                    # Innovation: Enable Curriculum for Worms to fill behavioral gaps
                    use_curriculum = "--curriculum" if sp == "worm" else ""
                    
                    batch_size = self.args.batch or 16384
                    cmd = [sys.executable, "-u", str(qdax_script), "--species", sp, "--iterations", "5000", "--batch", str(batch_size)]
                    if use_curriculum: cmd.append("--curriculum")
                    
                    env_jax = {
                        "XLA_PYTHON_CLIENT_MEM_FRACTION": "0.9",
                        "JAX_PLATFORM_NAME": "gpu",
                        "XLA_PYTHON_CLIENT_PREALLOCATE": "false",
                        "LD_LIBRARY_PATH": "/usr/local/lib/python3.12/dist-packages/nvidia/cudnn/lib:/usr/local/cuda/lib64:" + os.environ.get("LD_LIBRARY_PATH", "")
                    }
                    
                    logger.info(f"Launching QDax {sp} with batch {batch_size}...")
                    with open(LOG_DIR / "qdax_creatures2.log", "a") as f:
                        subprocess.run(cmd, env=env_jax, stdout=f, stderr=f)

                # C. Chemistry Validation
                self.set_status("Chemistry", "Validating Results")
                chem_cmd = [sys.executable, "-u", str(SCRIPT_DIR / "chemistry_sim.py"), "--validate"]
                with open(LOG_DIR / "chemistry.log", "a") as f:
                    subprocess.run(chem_cmd, stdout=f, stderr=f)

                self.set_status("Complete", "All Tasks Finished")

            p_gpu = mp.Process(target=gpu_manager, name="GPU-Orchestrator")
            p_gpu.start()
            self.processes["GPU-Manager"] = p_gpu

        logger.info("="*60)
        logger.info(" THE RESEARCH ORACLE IS ACTIVE - MAX POTENTIAL ENGAGED")
        logger.info("="*60)

        try:
            while not self.shutdown_event.is_set():
                alive = {n: p for n, p in self.processes.items() if p.is_alive()}
                if not alive:
                    logger.info("All tasks complete.")
                    break
                
                # Check for crashed processes that aren't handling their own retries
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
