#!/usr/bin/env python3
"""High-Signal Telemetry Daemon v4 - Absolute Monitoring.

Captures system metrics and parses all research lane logs for real-time dashboarding.
"""

import json
import os
import psutil
import re
import signal
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

# Paths
STATE_FILE = Path.home() / "telemetry" / "current_state.json"
LOG_DIR = Path.home() / "logs"
EVENT_FILE = Path.home() / "telemetry" / "events.jsonl"

GPU_RATES = {"a100xl": 1.79, "a100": 1.21, "v100": 0.81}

class TelemetryDaemon:
    def __init__(self, interval=2, gpu_type="a100xl"):
        self.interval = interval
        self.gpu_type = gpu_type
        self.rate = GPU_RATES.get(gpu_type, 1.79)
        self.start_time = time.time()
        self.running = True
        Path.home().joinpath("telemetry").mkdir(parents=True, exist_ok=True)

    def collect_gpu(self):
        try:
            cmd = ["nvidia-smi", "--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw", "--format=csv,noheader,nounits"]
            res = subprocess.check_output(cmd).decode().strip().split(", ")
            return {
                "util": float(res[0]),
                "mem_used": int(res[1]),
                "mem_total": int(res[2]),
                "temp": int(res[3]),
                "power": float(res[4])
            }
        except:
            return {"util": 0, "mem_used": 0, "mem_total": 0, "temp": 0, "power": 0}

    def collect_workloads(self):
        workloads = {}
        
        # 1. Parse Style Evolution
        style_log = LOG_DIR / "style.log"
        if style_log.exists():
            try:
                tail = subprocess.run(["tail", "-n", "50", str(style_log)], capture_output=True, text=True).stdout
                m = re.findall(r"Gen\s+(\d+):\s+best=([\d.]+)", tail)
                if m:
                    gen, best = m[-1]
                    workloads["style"] = {"gen": int(gen), "best": float(best), "pct": round(int(gen)/300 * 100, 1)}
            except: pass

        # 2. Parse Physics (Optuna)
        phys_log = LOG_DIR / "physics.log"
        if phys_log.exists():
            try:
                tail = subprocess.run(["tail", "-n", "50", str(phys_log)], capture_output=True, text=True).stdout
                m = re.findall(r"Trial\s+(\d+)\s+finished\s+with\s+value:\s+([\d.]+)", tail)
                if m:
                    trial, score = m[-1]
                    workloads["physics"] = {"trial": int(trial), "score": float(score), "pct": round(int(trial)/2000 * 100, 1)}
                else:
                    # Alternative regex for the [x/2000] format
                    m2 = re.findall(r"\[(\d+)/2000\]\s+#\d+\s+Physics=([\d.]+)", tail)
                    if m2:
                        trial, score = m2[-1]
                        workloads["physics"] = {"trial": int(trial), "score": float(score), "pct": round(int(trial)/2000 * 100, 1)}
            except: pass

        # 3. Parse QDax Creatures
        qdax_log = LOG_DIR / "qdax_creatures2.log"
        if qdax_log.exists():
            try:
                tail = subprocess.run(["tail", "-n", "100", str(qdax_log)], capture_output=True, text=True).stdout
                # Look for fitness updates
                m = re.findall(r"fitness=([\d.]+)", tail)
                if m:
                    best = max([float(x) for x in m])
                    workloads["creatures"] = {"iter": 0, "best": best, "pct": 0} # Simplified
            except: pass

        return workloads

    def run(self):
        while self.running:
            try:
                now = time.time()
                elapsed = now - self.start_time
                gpu = self.collect_gpu()
                workloads = self.collect_workloads()
                
                # Check for Oracle events to populate the timeline
                events = []
                if EVENT_FILE.exists():
                    try:
                        with open(EVENT_FILE, "r") as f:
                            lines = f.readlines()
                            events = [json.loads(l) for l in lines[-10:]]
                    except: pass

                state = {
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                    "elapsed": round(elapsed, 1),
                    "cost": round((elapsed / 3600) * self.rate, 4),
                    "gpu": gpu,
                    "cpu_util": psutil.cpu_percent(),
                    "ram_util": psutil.virtual_memory().percent,
                    "workloads": workloads,
                    "status": {"task": "Active", "details": "Oracle Monitoring"}
                }
                
                # Try to get active status from status file
                status_file = Path.home() / "telemetry" / "runner_status.json"
                if status_file.exists():
                    try:
                        with open(status_file, "r") as f:
                            state["status"] = json.load(f)
                    except: pass

                with open(STATE_FILE, "w") as f:
                    json.dump(state, f)
                    
            except Exception as e:
                print(f"Telemetry error: {e}")
                
            time.sleep(self.interval)

if __name__ == "__main__":
    TelemetryDaemon().run()
