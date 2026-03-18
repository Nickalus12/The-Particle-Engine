"""Stability tests: element count drift, no teleportation, deterministic replay.

Runs the real Dart simulation engine and validates that the simulation
remains stable and consistent over extended runs.
"""

import json
import shutil
import subprocess
from pathlib import Path

import numpy as np
import pytest

RESEARCH_DIR = Path(__file__).parent.parent
PROJECT_DIR = RESEARCH_DIR.parent


def _export_grid(frames: int) -> np.ndarray:
    """Run simulation for N frames and return the 320x180 grid."""
    dart_exe = shutil.which("dart")
    if dart_exe is None:
        pytest.skip("Dart not found on PATH")
    result = subprocess.run(
        [dart_exe, "run", str(RESEARCH_DIR / "export_frame.dart"), str(frames)],
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert result.returncode == 0, f"Simulation failed: {result.stderr}"
    grid_raw = (RESEARCH_DIR / "grid.bin").read_bytes()
    return np.frombuffer(grid_raw, dtype=np.uint8).reshape(180, 320).copy()


class TestElementCountDrift:
    """Element count should not drift excessively over long simulations."""

    @pytest.mark.stability
    def test_total_cells_constant(self, simulation_frame):
        """Grid should always have exactly 320*180 cells."""
        grid = simulation_frame["grid"]
        assert grid.size == 320 * 180

    @pytest.mark.stability
    def test_no_invalid_element_ids(self, simulation_frame):
        """All grid values should be valid element IDs (0-24)."""
        grid = simulation_frame["grid"]
        assert grid.max() <= 24, f"Invalid element ID {grid.max()} in grid"
        assert grid.min() >= 0

    @pytest.mark.stability
    def test_element_count_drift_100_vs_200(self):
        """Element counts at frame 100 vs 200 should not drift > 10%."""
        grid_100 = _export_grid(100)
        grid_200 = _export_grid(200)
        for el_id in range(25):
            count_100 = int((grid_100 == el_id).sum())
            count_200 = int((grid_200 == el_id).sum())
            if count_100 < 50:
                continue  # Skip rare elements
            drift = abs(count_200 - count_100) / count_100
            assert drift < 0.10, (
                f"Element {el_id}: count drifted {drift*100:.1f}% "
                f"({count_100} -> {count_200})"
            )


class TestNoTeleportation:
    """Elements should not appear in physically impossible locations."""

    @pytest.mark.stability
    def test_no_solid_in_sky(self, simulation_frame):
        """Heavy solids (stone, metal) should not appear in the top 10 rows."""
        grid = simulation_frame["grid"]
        top_strip = grid[:10, :]
        stone_id = simulation_frame["meta"]["elements"].get("Stone", -1)
        metal_id = simulation_frame["meta"]["elements"].get("Metal", -1)
        for el_id, name in [(stone_id, "Stone"), (metal_id, "Metal")]:
            if el_id < 0:
                continue
            count = int((top_strip == el_id).sum())
            assert count == 0, f"{name} found {count} times in top 10 rows"

    @pytest.mark.stability
    def test_no_lava_at_surface(self, simulation_frame):
        """Lava pocket is underground; no lava should be in top third."""
        grid = simulation_frame["grid"]
        top_third = grid[:60, :]
        lava_id = simulation_frame["meta"]["elements"].get("Lava", -1)
        if lava_id < 0:
            pytest.skip("No lava element")
        lava_count = int((top_third == lava_id).sum())
        assert lava_count == 0, f"Lava found {lava_count} times in top third"


class TestDeterministicReplay:
    """Same initial state + same seed should produce the same result."""

    @pytest.mark.stability
    def test_deterministic_100_frames(self):
        """Two runs of 100 frames should produce identical grids."""
        grid_a = _export_grid(100)
        grid_b = _export_grid(100)
        np.testing.assert_array_equal(
            grid_a, grid_b,
            err_msg="Two runs with same seed produced different grids"
        )

    @pytest.mark.stability
    def test_grid_not_all_empty(self):
        """After 100 frames, grid should not be entirely empty."""
        grid = _export_grid(100)
        non_empty = int((grid != 0).sum())
        assert non_empty > 1000, (
            f"Only {non_empty} non-empty cells after 100 frames"
        )

    @pytest.mark.stability
    def test_grid_has_multiple_elements(self):
        """After 100 frames, grid should contain multiple distinct element types."""
        grid = _export_grid(100)
        unique_elements = len(np.unique(grid))
        assert unique_elements >= 5, (
            f"Only {unique_elements} unique elements in grid"
        )
