"""Performance tests: FPS budget, frame time, throughput.

Runs the real Dart simulation engine via export_frame.dart and measures
wall-clock performance to ensure the engine meets its frame budget.
"""

import shutil
import subprocess
import time
from pathlib import Path

import pytest

RESEARCH_DIR = Path(__file__).parent.parent
PROJECT_DIR = RESEARCH_DIR.parent


def _run_simulation(frames: int, timeout: int = 60) -> subprocess.CompletedProcess:
    """Run the Dart simulation for N frames, returning the completed process."""
    dart_exe = shutil.which("dart")
    if dart_exe is None:
        pytest.skip("Dart not found on PATH")
    return subprocess.run(
        [dart_exe, "run", str(RESEARCH_DIR / "export_frame.dart"), str(frames)],
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
        timeout=timeout,
    )


class TestFPS:
    """Simulation must maintain acceptable frame rates."""

    @pytest.mark.performance
    def test_fps_above_30(self):
        """300 frames on 320x180 grid should complete in under 10 seconds (30+ FPS)."""
        start = time.perf_counter()
        result = _run_simulation(300, timeout=30)
        elapsed = time.perf_counter() - start
        assert result.returncode == 0, f"Simulation failed: {result.stderr}"
        fps = 300 / elapsed
        assert fps >= 30, f"FPS={fps:.1f}, expected >= 30 (elapsed={elapsed:.2f}s)"

    @pytest.mark.performance
    def test_fps_above_60_target(self):
        """600 frames should ideally complete in under 10 seconds (60+ FPS)."""
        start = time.perf_counter()
        result = _run_simulation(600, timeout=30)
        elapsed = time.perf_counter() - start
        assert result.returncode == 0, f"Simulation failed: {result.stderr}"
        fps = 600 / elapsed
        # Soft target: warn but don't fail below 60
        if fps < 60:
            pytest.xfail(f"FPS={fps:.1f} below 60 target (elapsed={elapsed:.2f}s)")


class TestFrameTimeBudget:
    """Individual frame times should stay within budget."""

    @pytest.mark.performance
    def test_average_frame_time_under_33ms(self):
        """Average frame time should be < 33ms (30fps budget)."""
        start = time.perf_counter()
        result = _run_simulation(300, timeout=30)
        elapsed = time.perf_counter() - start
        assert result.returncode == 0, f"Simulation failed: {result.stderr}"
        avg_frame_ms = (elapsed / 300) * 1000
        assert avg_frame_ms < 33.0, (
            f"Average frame time {avg_frame_ms:.1f}ms exceeds 33ms budget"
        )

    @pytest.mark.performance
    def test_simulation_does_not_timeout(self):
        """1000-frame simulation should complete without timeout."""
        result = _run_simulation(1000, timeout=60)
        assert result.returncode == 0, f"Simulation failed or timed out: {result.stderr}"


class TestThroughput:
    """Throughput should scale reasonably with frame count."""

    @pytest.mark.performance
    def test_100_frames_completes(self):
        """100-frame baseline should complete quickly."""
        start = time.perf_counter()
        result = _run_simulation(100, timeout=15)
        elapsed = time.perf_counter() - start
        assert result.returncode == 0, f"Simulation failed: {result.stderr}"
        assert elapsed < 10.0, f"100 frames took {elapsed:.2f}s, expected < 10s"

    @pytest.mark.performance
    def test_output_files_created(self):
        """Simulation should produce all expected output files."""
        result = _run_simulation(10, timeout=15)
        assert result.returncode == 0
        assert (RESEARCH_DIR / "frame.rgba").exists()
        assert (RESEARCH_DIR / "grid.bin").exists()
        assert (RESEARCH_DIR / "frame_meta.json").exists()
