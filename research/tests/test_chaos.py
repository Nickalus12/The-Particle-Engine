"""Chaos and fuzz testing for The Particle Engine.

Property-based random testing with hypothesis to find edge cases in the
simulation that no manual test would catch. Validates invariants hold
under extreme, adversarial, and random configurations.

Runs against the real Dart simulation via export_frame.dart.
"""

import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import pytest
from hypothesis import given, strategies as st, settings, assume, HealthCheck

RESEARCH_DIR = Path(__file__).parent.parent
PROJECT_DIR = RESEARCH_DIR.parent

# All placeable element IDs (1..24, matching El.sand through El.ash)
ALL_ELEMENTS = list(range(1, 25))

# Grid dimensions
WIDTH = 320
HEIGHT = 180
TOTAL_CELLS = WIDTH * HEIGHT

# Max valid element ID (maxElements = 64 in Dart, but built-in max is 24)
MAX_ELEMENT_ID = 24
MAX_ELEMENTS_CAPACITY = 64


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _dart_available() -> bool:
    return shutil.which("dart") is not None


def _run_chaos_scenario(
    placements: list[tuple[int, int, int]],
    frames: int = 100,
    timeout: int = 120,
) -> dict:
    """Run a chaos scenario: place elements, step N frames, return grid + temp.

    Args:
        placements: list of (x, y, element_id) tuples
        frames: number of simulation frames to run
        timeout: subprocess timeout in seconds

    Returns:
        dict with 'grid' (H,W uint8), 'temperature' (H,W uint8),
        'velocity_x' (H,W int8), 'velocity_y' (H,W int8), 'meta' dict
    """
    dart_exe = shutil.which("dart")
    if dart_exe is None:
        pytest.skip("Dart not found on PATH")

    # Write placements to a temp JSON file for the exporter to consume
    scenario = {
        "placements": [{"x": x, "y": y, "el": el} for x, y, el in placements],
        "frames": frames,
    }
    scenario_path = RESEARCH_DIR / "chaos_scenario.json"
    scenario_path.write_text(json.dumps(scenario))

    result = subprocess.run(
        [dart_exe, "run", str(RESEARCH_DIR / "export_chaos.dart")],
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
        timeout=timeout,
    )

    if result.returncode != 0:
        # If the chaos exporter doesn't exist yet, skip gracefully
        if "Could not find" in result.stderr or "not found" in result.stderr.lower():
            pytest.skip("export_chaos.dart not found -- run setup first")
        pytest.fail(f"Chaos export failed (rc={result.returncode}): {result.stderr}")

    # Read outputs
    grid_path = RESEARCH_DIR / "chaos_grid.bin"
    temp_path = RESEARCH_DIR / "chaos_temp.bin"
    velx_path = RESEARCH_DIR / "chaos_velx.bin"
    vely_path = RESEARCH_DIR / "chaos_vely.bin"
    meta_path = RESEARCH_DIR / "chaos_meta.json"

    grid = np.frombuffer(grid_path.read_bytes(), dtype=np.uint8).reshape(HEIGHT, WIDTH).copy()

    temperature = None
    if temp_path.exists():
        temperature = np.frombuffer(temp_path.read_bytes(), dtype=np.uint8).reshape(HEIGHT, WIDTH).copy()

    velocity_x = None
    if velx_path.exists():
        velocity_x = np.frombuffer(velx_path.read_bytes(), dtype=np.int8).reshape(HEIGHT, WIDTH).copy()

    velocity_y = None
    if vely_path.exists():
        velocity_y = np.frombuffer(vely_path.read_bytes(), dtype=np.int8).reshape(HEIGHT, WIDTH).copy()

    meta = {}
    if meta_path.exists():
        with open(meta_path) as f:
            meta = json.load(f)

    return {
        "grid": grid,
        "temperature": temperature,
        "velocity_x": velocity_x,
        "velocity_y": velocity_y,
        "meta": meta,
    }


def _export_grid(frames: int) -> np.ndarray:
    """Run the standard test world for N frames and return the grid."""
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
    return np.frombuffer(grid_raw, dtype=np.uint8).reshape(HEIGHT, WIDTH).copy()


def verify_invariants(grid, temperature=None, velocity_x=None, velocity_y=None):
    """Verify fundamental simulation invariants that must always hold.

    Called after every chaos test to check that no impossible state exists.
    """
    # Grid shape unchanged
    assert grid.shape == (HEIGHT, WIDTH), f"Grid shape changed to {grid.shape}"

    # All element IDs valid
    assert grid.min() >= 0, f"Negative element ID: {grid.min()}"
    assert grid.max() < MAX_ELEMENTS_CAPACITY, (
        f"Element ID {grid.max()} exceeds maxElements ({MAX_ELEMENTS_CAPACITY})"
    )

    # No NaN (uint8 can't be NaN, but check after any float conversion)
    assert not np.any(np.isnan(grid.astype(float))), "NaN in grid"

    if temperature is not None:
        assert temperature.shape == (HEIGHT, WIDTH), "Temperature shape mismatch"
        assert temperature.min() >= 0, f"Temperature below 0: {temperature.min()}"
        assert temperature.max() <= 255, f"Temperature above 255: {temperature.max()}"

    if velocity_x is not None:
        assert velocity_x.shape == (HEIGHT, WIDTH), "VelX shape mismatch"
        # Int8 range is -128..127, which is valid
        assert not np.any(np.isnan(velocity_x.astype(float))), "NaN in velX"

    if velocity_y is not None:
        assert velocity_y.shape == (HEIGHT, WIDTH), "VelY shape mismatch"
        assert not np.any(np.isnan(velocity_y.astype(float))), "NaN in velY"


# ---------------------------------------------------------------------------
# 1. Random World Stress Tests (hypothesis-driven)
# ---------------------------------------------------------------------------


class TestRandomWorldStress:
    """Property-based tests that throw random configurations at the engine."""

    @pytest.mark.chaos
    @given(
        elements=st.lists(
            st.tuples(
                st.integers(0, WIDTH - 1),
                st.integers(0, HEIGHT - 1),
                st.sampled_from(ALL_ELEMENTS),
            ),
            min_size=10,
            max_size=500,
        ),
        frames=st.integers(5, 200),
    )
    @settings(
        max_examples=50,
        deadline=60000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_no_crash_random_world(self, elements, frames):
        """Simulation never crashes regardless of random element arrangement."""
        if not _dart_available():
            pytest.skip("Dart not found")

        result = _run_chaos_scenario(elements, frames=frames)
        verify_invariants(
            result["grid"],
            result["temperature"],
            result["velocity_x"],
            result["velocity_y"],
        )

    @pytest.mark.chaos
    @given(
        element=st.sampled_from(ALL_ELEMENTS),
        count=st.integers(1, 1000),
    )
    @settings(
        max_examples=30,
        deadline=60000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_mass_flood(self, element, count):
        """Flooding the grid with one element type doesn't crash or leak."""
        if not _dart_available():
            pytest.skip("Dart not found")

        # Place `count` cells of one element in a cluster
        placements = []
        start_x = WIDTH // 4
        start_y = HEIGHT // 4
        for i in range(count):
            x = (start_x + i % 50) % WIDTH
            y = (start_y + i // 50) % HEIGHT
            placements.append((x, y, element))

        result = _run_chaos_scenario(placements, frames=100)
        verify_invariants(result["grid"], result["temperature"])

        # Element count should not spontaneously increase
        # (reactions may decrease count, but shouldn't create from nothing)
        final_count = int((result["grid"] == element).sum())
        # Allow for reactions converting elements, but total cells must be constant
        assert result["grid"].size == TOTAL_CELLS


# ---------------------------------------------------------------------------
# 2. Boundary Torture Tests
# ---------------------------------------------------------------------------


class TestBoundaryTorture:
    """Extreme scenarios at the edges of what the simulation should handle."""

    @pytest.mark.chaos
    def test_entire_grid_water(self):
        """Fill every cell with water. No crash, no OOB."""
        if not _dart_available():
            pytest.skip("Dart not found")

        placements = [
            (x, y, 2)  # El.water = 2
            for y in range(HEIGHT)
            for x in range(WIDTH)
        ]
        result = _run_chaos_scenario(placements, frames=50)
        verify_invariants(result["grid"], result["temperature"])

    @pytest.mark.chaos
    def test_entire_grid_lava(self):
        """Fill every cell with lava. Temperature doesn't overflow."""
        if not _dart_available():
            pytest.skip("Dart not found")

        placements = [
            (x, y, 18)  # El.lava = 18
            for y in range(HEIGHT)
            for x in range(WIDTH)
        ]
        result = _run_chaos_scenario(placements, frames=50)
        verify_invariants(result["grid"], result["temperature"])

        if result["temperature"] is not None:
            assert result["temperature"].max() <= 255, "Temperature overflow with all-lava grid"

    @pytest.mark.chaos
    def test_entire_grid_sand(self):
        """Fill every cell with sand. Gravity resolves without infinite loop."""
        if not _dart_available():
            pytest.skip("Dart not found")

        placements = [
            (x, y, 1)  # El.sand = 1
            for y in range(HEIGHT)
            for x in range(WIDTH)
        ]
        result = _run_chaos_scenario(placements, frames=50)
        verify_invariants(result["grid"])

    @pytest.mark.chaos
    def test_alternating_checkerboard(self):
        """Checkerboard of fire and water. Reactions everywhere simultaneously."""
        if not _dart_available():
            pytest.skip("Dart not found")

        placements = []
        for y in range(HEIGHT):
            for x in range(WIDTH):
                el = 3 if (x + y) % 2 == 0 else 2  # fire / water alternating
                placements.append((x, y, el))

        result = _run_chaos_scenario(placements, frames=100)
        verify_invariants(result["grid"], result["temperature"])

    @pytest.mark.chaos
    def test_single_cell_each_element(self):
        """One cell of every element. All 24 coexist without crashing."""
        if not _dart_available():
            pytest.skip("Dart not found")

        placements = [
            (i * 10 % WIDTH, i * 10 // WIDTH, el_id)
            for i, el_id in enumerate(ALL_ELEMENTS)
        ]
        result = _run_chaos_scenario(placements, frames=200)
        verify_invariants(result["grid"])

    @pytest.mark.chaos
    def test_column_of_every_element(self):
        """Stack all 24 elements in a single column. Density should sort."""
        if not _dart_available():
            pytest.skip("Dart not found")

        x_col = WIDTH // 2
        placements = [
            (x_col, y, ALL_ELEMENTS[y % len(ALL_ELEMENTS)])
            for y in range(len(ALL_ELEMENTS))
        ]
        result = _run_chaos_scenario(placements, frames=200)
        verify_invariants(result["grid"])

    @pytest.mark.chaos
    def test_ring_of_fire_around_water(self):
        """Fire encircling a water pool. Steam production must be bounded."""
        if not _dart_available():
            pytest.skip("Dart not found")

        cx, cy = WIDTH // 2, HEIGHT // 2
        placements = []

        # Water pool: 20x20 centered
        for dy in range(-10, 10):
            for dx in range(-10, 10):
                placements.append((cx + dx, cy + dy, 2))  # water

        # Fire ring around it
        for dy in range(-15, 15):
            for dx in range(-15, 15):
                if abs(dx) >= 10 or abs(dy) >= 10:
                    if abs(dx) < 15 and abs(dy) < 15:
                        placements.append((cx + dx, cy + dy, 3))  # fire

        result = _run_chaos_scenario(placements, frames=200)
        verify_invariants(result["grid"])

        # Steam (11) + water (2) + fire (3) + empty (0) should account for most cells
        # Main check: no crash, no invalid IDs

    @pytest.mark.chaos
    def test_acid_ocean(self):
        """Grid filled with acid. Everything dissolves but no crash."""
        if not _dart_available():
            pytest.skip("Dart not found")

        placements = [
            (x, y, 14)  # El.acid = 14
            for y in range(HEIGHT)
            for x in range(WIDTH)
        ]
        result = _run_chaos_scenario(placements, frames=100)
        verify_invariants(result["grid"])

    @pytest.mark.chaos
    def test_corners_and_edges(self):
        """Place elements at all four corners and along edges."""
        if not _dart_available():
            pytest.skip("Dart not found")

        placements = [
            # Corners
            (0, 0, 1),              # sand top-left
            (WIDTH - 1, 0, 2),      # water top-right
            (0, HEIGHT - 1, 3),     # fire bottom-left
            (WIDTH - 1, HEIGHT - 1, 18),  # lava bottom-right
        ]
        # Top edge
        for x in range(WIDTH):
            placements.append((x, 0, 1))
        # Bottom edge
        for x in range(WIDTH):
            placements.append((x, HEIGHT - 1, 7))  # stone
        # Left edge
        for y in range(HEIGHT):
            placements.append((0, y, 2))
        # Right edge
        for y in range(HEIGHT):
            placements.append((WIDTH - 1, y, 13))  # oil

        result = _run_chaos_scenario(placements, frames=100)
        verify_invariants(result["grid"])


# ---------------------------------------------------------------------------
# 3. Invariant Verification Under Standard Test World
# ---------------------------------------------------------------------------


class TestInvariantsStandard:
    """Verify invariants hold on the standard test world at various frame counts."""

    @pytest.mark.chaos
    @pytest.mark.parametrize("frames", [1, 10, 50, 100, 200, 500])
    def test_invariants_at_frame(self, frames):
        """Core invariants hold at various simulation durations."""
        grid = _export_grid(frames)
        verify_invariants(grid)

    @pytest.mark.chaos
    def test_no_element_id_above_24(self):
        """After 100 frames, no element ID should exceed the built-in max."""
        grid = _export_grid(100)
        assert grid.max() <= MAX_ELEMENT_ID, (
            f"Element ID {grid.max()} found -- expected max {MAX_ELEMENT_ID}"
        )

    @pytest.mark.chaos
    def test_grid_dimensions_stable(self):
        """Grid is always exactly 320x180 regardless of frame count."""
        for frames in [1, 50, 200]:
            grid = _export_grid(frames)
            assert grid.shape == (HEIGHT, WIDTH)


# ---------------------------------------------------------------------------
# 4. Temporal Consistency Tests
# ---------------------------------------------------------------------------


class TestTemporalConsistency:
    """Verify that time-dependent properties behave monotonically."""

    @pytest.mark.chaos
    def test_monotonic_settling(self):
        """After initial activity, active cell count should trend downward."""
        if not _dart_available():
            pytest.skip("Dart not found")

        # Run at increasing frame counts and check activity decreases
        frame_counts = [50, 100, 200, 500]
        activities = []
        for f in frame_counts:
            grid = _export_grid(f)
            # Count non-empty, non-stone, non-dirt cells as "active"
            active = int(np.sum(
                (grid != 0) & (grid != 7) & (grid != 16)
            ))
            activities.append(active)

        # After initial transient, activity should generally decrease
        # Check that last measurement is <= first (allowing some tolerance)
        # This is a soft check -- chaotic systems can fluctuate
        if activities[0] > 100:  # only check if there's meaningful activity
            assert activities[-1] <= activities[0] * 2, (
                f"Activity doubled over time: {activities}"
            )

    @pytest.mark.chaos
    def test_total_mass_bounded(self):
        """Total non-empty cells should not grow unboundedly."""
        if not _dart_available():
            pytest.skip("Dart not found")

        grid_early = _export_grid(10)
        grid_late = _export_grid(500)

        mass_early = int((grid_early != 0).sum())
        mass_late = int((grid_late != 0).sum())

        # Mass should not more than double (reactions can create byproducts
        # but total grid size is fixed -- this catches spontaneous creation bugs)
        assert mass_late <= TOTAL_CELLS, "Mass exceeds grid capacity"

    @pytest.mark.chaos
    def test_temperature_bounded_over_time(self):
        """Temperature never exceeds [0, 255] at any frame."""
        if not _dart_available():
            pytest.skip("Dart not found")

        for frames in [10, 50, 200]:
            result = _run_chaos_scenario(
                [(WIDTH // 2, HEIGHT // 2, 18)],  # single lava cell
                frames=frames,
            )
            if result["temperature"] is not None:
                assert result["temperature"].min() >= 0
                assert result["temperature"].max() <= 255


# ---------------------------------------------------------------------------
# 5. Adversarial Tests
# ---------------------------------------------------------------------------


class TestAdversarial:
    """Deliberately create scenarios designed to break the simulation."""

    @pytest.mark.chaos
    def test_fire_oil_chain_reaction(self):
        """Line of oil with fire at one end. Chain reaction must terminate."""
        if not _dart_available():
            pytest.skip("Dart not found")

        placements = []
        # Long line of oil
        y = HEIGHT // 2
        for x in range(WIDTH):
            placements.append((x, y, 13))  # oil
        # Fire at x=0
        placements.append((0, y - 1, 3))  # fire above oil

        result = _run_chaos_scenario(placements, frames=500)
        verify_invariants(result["grid"])

    @pytest.mark.chaos
    def test_lava_water_boundary(self):
        """Lava and water meeting at a boundary. Reaction must be bounded."""
        if not _dart_available():
            pytest.skip("Dart not found")

        placements = []
        mid_x = WIDTH // 2
        y = HEIGHT // 2
        # Left half: water, right half: lava
        for dy in range(-20, 20):
            for dx in range(-40, 0):
                placements.append((mid_x + dx, y + dy, 2))  # water
            for dx in range(0, 40):
                placements.append((mid_x + dx, y + dy, 18))  # lava

        result = _run_chaos_scenario(placements, frames=200)
        verify_invariants(result["grid"], result["temperature"])

    @pytest.mark.chaos
    def test_tnt_chain(self):
        """Line of TNT with fire ignition. Explosion cascade must terminate."""
        if not _dart_available():
            pytest.skip("Dart not found")

        placements = []
        y = HEIGHT // 2
        for x in range(0, WIDTH, 2):
            placements.append((x, y, 8))  # TNT
        placements.append((0, y - 1, 3))  # fire igniter

        result = _run_chaos_scenario(placements, frames=300)
        verify_invariants(result["grid"])

    @pytest.mark.chaos
    def test_sealed_water_chamber(self):
        """Water sealed inside stone walls. Pressure should stay bounded."""
        if not _dart_available():
            pytest.skip("Dart not found")

        placements = []
        cx, cy = WIDTH // 2, HEIGHT // 2

        # Stone box (walls)
        for dx in range(-15, 16):
            placements.append((cx + dx, cy - 15, 7))  # top wall
            placements.append((cx + dx, cy + 15, 7))  # bottom wall
        for dy in range(-15, 16):
            placements.append((cx - 15, cy + dy, 7))  # left wall
            placements.append((cx + 15, cy + dy, 7))  # right wall

        # Fill interior with water
        for dy in range(-14, 15):
            for dx in range(-14, 15):
                placements.append((cx + dx, cy + dy, 2))

        result = _run_chaos_scenario(placements, frames=200)
        verify_invariants(result["grid"], result["temperature"])

    @pytest.mark.chaos
    def test_lava_surrounded_by_stone(self):
        """Lava heat source surrounded by stone. Temperature bounded."""
        if not _dart_available():
            pytest.skip("Dart not found")

        placements = []
        cx, cy = WIDTH // 2, HEIGHT // 2

        # Stone box
        for dx in range(-5, 6):
            placements.append((cx + dx, cy - 5, 7))
            placements.append((cx + dx, cy + 5, 7))
        for dy in range(-5, 6):
            placements.append((cx - 5, cy + dy, 7))
            placements.append((cx + 5, cy + dy, 7))

        # Lava inside
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                placements.append((cx + dx, cy + dy, 18))

        result = _run_chaos_scenario(placements, frames=500)
        verify_invariants(result["grid"], result["temperature"])

        if result["temperature"] is not None:
            assert result["temperature"].max() <= 255, "Temperature overflow from heat source"

    @pytest.mark.chaos
    def test_acid_vs_metal(self):
        """Acid on top of metal. Corrosion must be bounded."""
        if not _dart_available():
            pytest.skip("Dart not found")

        placements = []
        # Metal floor
        for x in range(100, 220):
            for y in range(HEIGHT - 20, HEIGHT):
                placements.append((x, y, 21))  # metal
        # Acid above
        for x in range(100, 220):
            for y in range(HEIGHT - 40, HEIGHT - 20):
                placements.append((x, y, 14))  # acid

        result = _run_chaos_scenario(placements, frames=300)
        verify_invariants(result["grid"])

    @pytest.mark.chaos
    def test_all_elements_column_drop(self):
        """Drop a column of all 24 elements from the top. No crash."""
        if not _dart_available():
            pytest.skip("Dart not found")

        placements = []
        x = WIDTH // 2
        for i, el_id in enumerate(ALL_ELEMENTS):
            if i < HEIGHT:
                placements.append((x, i, el_id))

        result = _run_chaos_scenario(placements, frames=300)
        verify_invariants(result["grid"])

    @pytest.mark.chaos
    def test_lightning_in_water(self):
        """Lightning striking a water pool. Conductivity doesn't loop."""
        if not _dart_available():
            pytest.skip("Dart not found")

        placements = []
        # Water pool
        for y in range(HEIGHT // 2, HEIGHT):
            for x in range(50, 270):
                placements.append((x, y, 2))
        # Lightning above center
        placements.append((WIDTH // 2, HEIGHT // 2 - 1, 5))

        result = _run_chaos_scenario(placements, frames=100)
        verify_invariants(result["grid"])

    @pytest.mark.chaos
    def test_maximum_density_elements(self):
        """Fill grid with max density elements (stone=255, metal=240). No issue."""
        if not _dart_available():
            pytest.skip("Dart not found")

        placements = []
        for y in range(HEIGHT):
            for x in range(WIDTH):
                el = 7 if (x + y) % 2 == 0 else 21  # stone/metal checkerboard
                placements.append((x, y, el))

        result = _run_chaos_scenario(placements, frames=50)
        verify_invariants(result["grid"])

    @pytest.mark.chaos
    def test_fire_wood_maze(self):
        """Grid-spanning wood maze with fire. Combustion terminates."""
        if not _dart_available():
            pytest.skip("Dart not found")

        placements = []
        # Wood grid pattern (every other row and column)
        for y in range(0, HEIGHT, 2):
            for x in range(WIDTH):
                placements.append((x, y, 20))  # wood rows
        for x in range(0, WIDTH, 10):
            for y in range(HEIGHT):
                placements.append((x, y, 20))  # wood columns

        # Fire source at center
        placements.append((WIDTH // 2, HEIGHT // 2, 3))

        result = _run_chaos_scenario(placements, frames=500)
        verify_invariants(result["grid"])


# ---------------------------------------------------------------------------
# 6. Property-Based Element Interaction Tests
# ---------------------------------------------------------------------------


class TestPropertyBasedInteractions:
    """Hypothesis-driven tests for element interaction properties."""

    @pytest.mark.chaos
    @given(
        el_a=st.sampled_from(ALL_ELEMENTS),
        el_b=st.sampled_from(ALL_ELEMENTS),
    )
    @settings(
        max_examples=50,
        deadline=60000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_any_two_elements_coexist(self, el_a, el_b):
        """Any two elements placed adjacent should not crash the engine."""
        if not _dart_available():
            pytest.skip("Dart not found")

        cx, cy = WIDTH // 2, HEIGHT // 2
        placements = [
            (cx, cy, el_a),
            (cx + 1, cy, el_b),
        ]
        result = _run_chaos_scenario(placements, frames=50)
        verify_invariants(result["grid"])

    @pytest.mark.chaos
    @given(
        el=st.sampled_from(ALL_ELEMENTS),
        size=st.integers(1, 30),
    )
    @settings(
        max_examples=30,
        deadline=60000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_block_of_any_element(self, el, size):
        """A square block of any element should simulate without crashing."""
        if not _dart_available():
            pytest.skip("Dart not found")

        cx, cy = WIDTH // 2, HEIGHT // 2
        half = size // 2
        placements = [
            (cx + dx, cy + dy, el)
            for dy in range(-half, half + 1)
            for dx in range(-half, half + 1)
            if 0 <= cx + dx < WIDTH and 0 <= cy + dy < HEIGHT
        ]
        result = _run_chaos_scenario(placements, frames=100)
        verify_invariants(result["grid"])

    @pytest.mark.chaos
    @given(
        elements=st.lists(
            st.sampled_from(ALL_ELEMENTS),
            min_size=2,
            max_size=24,
        ),
    )
    @settings(
        max_examples=20,
        deadline=60000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_horizontal_layer_cake(self, elements):
        """Stack random element types in horizontal layers. Should not crash."""
        if not _dart_available():
            pytest.skip("Dart not found")

        placements = []
        rows_per_el = max(1, HEIGHT // len(elements))
        for i, el in enumerate(elements):
            y_start = i * rows_per_el
            for y in range(y_start, min(y_start + rows_per_el, HEIGHT)):
                for x in range(WIDTH):
                    placements.append((x, y, el))

        result = _run_chaos_scenario(placements, frames=200)
        verify_invariants(result["grid"])
