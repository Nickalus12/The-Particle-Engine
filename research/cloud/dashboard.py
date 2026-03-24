#!/usr/bin/env python3
"""MegaRunner Pro Dashboard v3 - Ultra High Signal.

The definitive monitoring interface for the Particle Engine Research Pipeline.
Features real-time GPU sparklines, workload tracking, and Gemini Art Director status.
"""

import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from collections import deque

from rich.console import Console
from rich.live import Live
from rich.layout import Layout
from rich.panel import Panel
from rich.table import Table
from rich import box
from rich.align import Align
from rich.text import Text
from rich.progress import Progress, BarColumn, TextColumn, TaskProgressColumn
from rich.columns import Columns

# Configuration
STATE_FILE = Path.home() / "telemetry" / "current_state.json"
LOG_DIR = Path.home() / "logs"

console = Console()

class Dashboard:
    def __init__(self):
        self.gpu_history = deque([0]*40, maxlen=40)
        self.cpu_history = deque([0]*40, maxlen=40)
        self.start_time = time.time()
        
    def make_layout(self) -> Layout:
        layout = Layout()
        layout.split_column(
            Layout(name="header", size=3),
            Layout(name="main"),
            Layout(name="logs", ratio=1),
            Layout(name="footer", size=3),
        )
        layout["main"].split_row(
            Layout(name="left", ratio=1),
            Layout(name="workload_stats", ratio=2), # Changed from "right" to match main loop
        )
        layout["left"].split_column(
            Layout(name="system_stats", ratio=1),
            Layout(name="processes", ratio=1),
        )
        return layout

    def get_header(self, state: dict) -> Panel:
        status = state.get("status", {})
        task = status.get("task", "Initializing...")
        details = status.get("details", "Preparing GPU...")
        
        # Check for stale data
        ts_str = state.get("timestamp")
        is_stale = False
        if ts_str:
            try:
                ts = datetime.fromisoformat(ts_str)
                if (datetime.now(timezone.utc) - ts).total_seconds() > 10:
                    is_stale = True
            except: pass

        # Color the task based on activity
        color = "cyan"
        if is_stale: 
            task = "[blink red]STALE DATA[/]"
            color = "red"
        elif "Gemini" in task: color = "magenta"
        elif "QDax" in task: color = "green"
        elif "Style" in task: color = "yellow"
        elif "CRASHED" in task: color = "bold red"
        
        grid = Table.grid(expand=True)
        grid.add_column(justify="left", ratio=1)
        grid.add_column(justify="center", ratio=1)
        grid.add_column(justify="right", ratio=1)
        grid.add_row(
            f"[b]Pipeline:[/b] [{color}]{task}[/{color}] [dim]({details})[/dim]",
            "[b white]A100 MEGA-RUN PRO[/b white]",
            datetime.now().strftime("%H:%M:%S"),
        )
        return Panel(grid, style="white on blue")

    def get_sparkline(self, data, color="green"):
        chars = " ▂▃▄▅▆▇█"
        # Safety clamp to 0-100 to avoid IndexError
        line = "".join(chars[int(max(0, min(99.9, v)) / 100 * 8)] for v in data)
        return f"[{color}]{line}[/]"

    def get_system_panel(self, state: dict) -> Panel:
        gpu = state.get("gpu", {})
        gpu_util = float(gpu.get("util", 0))
        cpu_util = float(state.get("cpu_util", 0))
        ram_util = float(state.get("ram_util", 0))
        
        self.gpu_history.append(gpu_util)
        self.cpu_history.append(cpu_util)

        table = Table(show_header=False, box=box.SIMPLE, expand=True)
        table.add_column("Metric", style="bold cyan")
        table.add_column("Value", style="magenta")
        
        gpu_color = "green" if gpu_util < 50 else "yellow" if gpu_util < 85 else "red"
        cpu_color = "green" if cpu_util < 50 else "yellow" if cpu_util < 85 else "red"
        
        table.add_row("GPU Util", f"[{gpu_color}]{gpu_util:>3.0f}%[/] " + self.get_sparkline(self.gpu_history, gpu_color))
        table.add_row("VRAM", f"{gpu.get('mem_used',0):>6,d} / {gpu.get('mem_total',0):,d} MB")
        table.add_row("Power", f"{gpu.get('power',0):>5.1f}W / 300W")
        table.add_row("Temp", f"{gpu.get('temp',0):>3d}°C")
        table.add_row("", "")
        table.add_row("CPU Load", f"[{cpu_color}]{cpu_util:>3.0f}%[/] " + self.get_sparkline(self.cpu_history, "blue"))
        table.add_row("RAM Util", f"{ram_util:>3.1f}%")
        
        return Panel(table, title="[b]Real-Time Health[/b]", border_style="blue")

    def get_proc_panel(self, state: dict) -> Panel:
        procs = state.get("processes", [])
        table = Table(box=box.SIMPLE, expand=True, show_header=True, header_style="bold dim")
        table.add_column("PID", style="dim")
        table.add_column("Task", style="bold white")
        table.add_column("CPU%", justify="right")
        table.add_column("MEM", justify="right")
        
        for p in procs:
            table.add_row(str(p['pid']), p['script'], f"{p['cpu']}%", f"{p['mem']}M")
            
        if not procs:
            return Panel(Align.center("\n[dim]Waking up workers...[/dim]", vertical="middle"), title="[b]Active Tasks[/b]", border_style="dim")
            
        return Panel(table, title="[b]Active Tasks[/b]", border_style="cyan")

    def get_progress_bar(self, pct, width=25, color="green"):
        pct = max(0.0, min(100.0, pct))
        filled = int(pct / 100 * width)
        empty = width - filled
        return f"[{color}]{'█' * filled}{'░' * empty}[/] {pct:.1f}%"

    def get_workload_panel(self, state: dict) -> Panel:
        workloads = state.get("workloads", {})
        
        if not workloads:
            return Panel(Align.center("\n\n[dim]Orchestrator online... awaiting workload metrics.[/dim]", vertical="middle"), title="[b]Research Progress[/b]")
            
        table = Table(box=box.SIMPLE, expand=True)
        table.add_column("Research Lane", style="bold white", width=15)
        table.add_column("Progress", ratio=1)
        table.add_column("Latest Metrics", justify="right", style="dim")
        
        # Lane 1: Style
        style = workloads.get("style", {"pct": 0, "gen": 0, "best": 0})
        table.add_row("AESTHETICS", self.get_progress_bar(style['pct'], color="yellow"), f"Gen {style['gen']} | Best: {style['best']:.1f}")
        
        # Lane 2: Creatures
        creatures = workloads.get("creatures", {"pct": 0, "iter": 0, "best": 0, "coverage": "0/4096"})
        table.add_row("CREATURES", self.get_progress_bar(creatures['pct'], color="green"), f"Iter {creatures['iter']} | Fit: {creatures['best']:.1f}")
        
        # Lane 3: Physics
        physics = workloads.get("physics", {"pct": 0, "trial": 0, "score": 0})
        table.add_row("PHYSICS", self.get_progress_bar(physics['pct'], color="blue"), f"Trial {physics['trial']} | Score: {physics['score']:.1f}")
        
        return Panel(table, title="[b]Workload Orchestration[/b]", border_style="green")

    def get_log_panel(self) -> Panel:
        # Display the new Event Timeline
        event_file = Path.home() / "telemetry" / "events.jsonl"
        events_to_show = []
        if event_file.exists():
            try:
                with open(event_file, "r") as f:
                    lines = f.readlines()
                    for line in lines[-12:]: # Get last 12 events
                        ev = json.loads(line)
                        t = ev.get("timestamp", "").split("T")[-1][:8]
                        etype = ev.get("type", "EVENT")
                        
                        # Format based on event type
                        if etype == "STATUS_CHANGE":
                            msg = f"[{t}] [cyan]STATUS:[/] {ev.get('task')} - {ev.get('details')}"
                        elif etype == "TASK_START":
                            msg = f"[{t}] [yellow]LAUNCH:[/] {ev.get('name')} (Attempt {ev.get('attempt')})"
                        elif etype == "TASK_COMPLETE":
                            msg = f"[{t}] [green]SUCCESS:[/] {ev.get('name')}"
                        elif etype == "TASK_FAILURE":
                            msg = f"[{t}] [red]FAILED:[/] {ev.get('name')} - {ev.get('error')}"
                        else:
                            msg = f"[{t}] [dim]{etype}[/]"
                        events_to_show.append(msg)
            except: pass
            
        if not events_to_show:
            events_to_show = ["[dim]Awaiting Oracle events...[/dim]"]
            
        display_text = "\n".join(events_to_show)
        return Panel(Text.from_markup(display_text), title="[b]Oracle Event Timeline[/b]", border_style="yellow")

    def get_footer(self, state: dict) -> Panel:
        elapsed = state.get("elapsed", 0)
        cost = state.get("cost", 0)
        grid = Table.grid(expand=True)
        grid.add_column(justify="left")
        grid.add_column(justify="right")
        
        time_str = f"{int(elapsed//3600)}h {int((elapsed%3600)//60)}m {int(elapsed%60)}s"
        grid.add_row(
            f" [b]UPTIME:[/b] {time_str}  [dim]|  JAX Optim: Vectorized 1024-batch  |  Gemini: Pro-Vision Enabled[/dim]", 
            f"[b]TOTAL COST:[/b] [bold green]${cost:.4f}[/bold green]  "
        )
        return Panel(grid, style="bold white on black")

def main():
    db = Dashboard()
    layout = db.make_layout()
    
    with Live(layout, refresh_per_second=4, screen=True) as live:
        while True:
            try:
                state = {}
                if STATE_FILE.exists():
                    with open(STATE_FILE, "r") as f:
                        state = json.load(f)
                
                layout["header"].update(db.get_header(state))
                layout["system_stats"].update(db.get_system_panel(state))
                layout["processes"].update(db.get_proc_panel(state))
                layout["workload_stats"].update(db.get_workload_panel(state))
                layout["logs"].update(db.get_log_panel())
                layout["footer"].update(db.get_footer(state))
            except: pass
            time.sleep(0.25)

if __name__ == "__main__":
    try: main()
    except KeyboardInterrupt: pass
