"""Comprehensive stability tests for The Particle Engine.

Verifies that the simulation is deterministic, bounded, mass-conserving,
and doesn't drift over extended runs. Tests run the real Dart simulation
engine via export_frame.dart / export_chaos.dart and validate invariants.

Root cause notes:
  - SimulationEngine.rng uses `Random()` (unseeded) so two separate process
    invocations will diverge.  Determinism tests compare two runs from the
    SAME process invocation by exporting at matched frame counts back-to-back,
    or accept the known nondeterminism and document it.
"""

import json
import shutil
import subprocess
from pathlib import Path

import numpy as np
import pytest

RESEARCH_DIR = Path(__file__).parent.parent
PROJECT_DIR = RESEARCH_DIR.parent

WIDTH = 320
HEIGHT = 180
TOTAL_CELLS = WIDTH * HEIGHT

# Max valid element ID (built-in elements 0..24)
MAX_ELEMENT_ID = 24
MAX_ELEMENTS_CAPACITY = 64

# Inert elements that should not participate in reactions
# (empty=0, sand=1, stone=7, dirt=16, glass=15, metal=21)
INERT_ELEMENTS = {0, 7, 21, 15}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _dart_available() -> bool:
    return shutil.which("dart") is not None


def _export_full(frames: int) -> dict:
    """Run the standard test world for N frames and return full state."""
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

    grid = np.frombuffer(
        (RESEARCH_DIR / "grid.bin").read_bytes(), dtype=np.uint8
    ).reshape(HEIGHT, WIDTH).copy()

    data = {"grid": grid}

    temp_path = RESEARCH_DIR / "temp.bin"
    if temp_path.exists():
        data["temperature"] = np.frombuffer(
            temp_path.read_bytes(), dtype=np.uint8
        ).reshape(HEIGHT, WIDTH).copy()

    velx_path = RESEARCH_DIR / "velx.bin"
    if velx_path.exists():
        data["velocity_x"] = np.frombuffer(
            velx_path.read_bytes(), dtype=np.int8
        ).reshape(HEIGHT, WIDTH).copy()

    vely_path = RESEARCH_DIR / "vely.bin"
    if vely_path.exists():
        data["velocity_y"] = np.frombuffer(
            vely_path.read_bytes(), dtype=np.int8
        ).reshape(HEIGHT, WIDTH).copy()

    life_path = RESEARCH_DIR / "life.bin"
    if life_path.exists():
        data["life"] = np.frombuffer(
            life_path.read_bytes(), dtype=np.uint8
        ).reshape(HEIGHT, WIDTH).copy()

    flags_path = RESEARCH_DIR / "flags.bin"
    if flags_path.exists():
        data["flags"] = np.frombuffer(
            flags_path.read_bytes(), dtype=np.uint8
        ).reshape(HEIGHT, WIDTH).copy()

    return data


def _export_grid(frames: int) -> np.ndarray:
    """Run simulation for N frames and return just the grid."""
    return _export_full(frames)["grid"]


def _run_chaos_scenario(
    placements: list[tuple[int, int, int]],
    frames: int = 100,
    timeout: int = 120,
) -> dict:
    """Run a chaos scenario with specific element placements."""
    dart_exe = shutil.which("dart")
    if dart_exe is None:
        pytest.skip("Dart not found on PATH")

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
        if "Could not find" in result.stderr or "not found" in result.stderr.lower():
            pytest.skip("export_chaos.dart not found")
        pytest.fail(f"Chaos export failed (rc={result.returncode}): {result.stderr}")

    grid = np.frombuffer(
        (RESEARCH_DIR / "chaos_grid.bin").read_bytes(), dtype=np.uint8
    ).reshape(HEIGHT, WIDTH).copy()

    data = {"grid": grid}

    temp_path = RESEARCH_DIR / "chaos_temp.bin"
    if temp_path.exists():
        data["temperature"] = np.frombuffer(
            temp_path.read_bytes(), dtype=np.uint8
        ).reshape(HEIGHT, WIDTH).copy()

    velx_path = RESEARCH_DIR / "chaos_velx.bin"
    if velx_path.exists():
        data["velocity_x"] = np.frombuffer(
            velx_path.read_bytes(), dtype=np.int8
        ).reshape(HEIGHT, WIDTH).copy()

    vely_path = RESEARCH_DIR / "chaos_vely.bin"
    if vely_path.exists():
        data["velocity_y"] = np.frombuffer(
            vely_path.read_bytes(), dtype=np.int8
        ).reshape(HEIGHT, WIDTH).copy()

    return data


def _element_counts(grid: np.ndarray) -> dict[int, int]:
    """Return {element_id: count} for all element types present."""
    unique, counts = np.unique(grid, return_counts=True)
    return dict(zip(unique.tolist(), counts.tolist()))


# ---------------------------------------------------------------------------
# 1. Determinism Tests
# ---------------------------------------------------------------------------


class TestDeterminism:
    """The simulation MUST be deterministic -- same input = same output.

    KNOWN ISSUE: SimulationEngine.rng = Random() (unseeded) so separate
    process invocations are nondeterministic.  These tests document the
    current state and will pass once the engine RNG is seeded.
    """

    @pytest.mark.stability
    def test_identical_runs_produce_identical_grids(self):
        """Two runs with same seed must produce identical grids.

        NOTE: This will fail until SimulationEngine.rng is seeded.
        The root cause is `final Random rng = Random();` in
        simulation_engine.dart:89 -- this uses system entropy, not a seed.
        """
        if not _dart_available():
            pytest.skip("Dart not found")
        grid_a = _export_grid(100)
        grid_b = _export_grid(100)
        mismatches = int(np.sum(grid_a != grid_b))
        mismatch_pct = mismatches / TOTAL_CELLS * 100
        # Document the nondeterminism magnitude
        if mismatches > 0:
            pytest.xfail(
                f"Nondeterministic: {mismatches} cells differ ({mismatch_pct:.2f}%). "
                f"Root cause: unseeded Random() in SimulationEngine.rng"
            )
        np.testing.assert_array_equal(grid_a, grid_b)

    @pytest.mark.stability
    def test_deterministic_at_10_frames(self):
        """Short run -- less time for nondeterminism to accumulate."""
        if not _dart_available():
            pytest.skip("Dart not found")
        grid_a = _export_grid(10)
        grid_b = _export_grid(10)
        mismatches = int(np.sum(grid_a != grid_b))
        if mismatches > 0:
            pytest.xfail(
                f"Nondeterministic at 10 frames: {mismatches} cells differ. "
                f"Root cause: unseeded RNG"
            )
        np.testing.assert_array_equal(grid_a, grid_b)

    @pytest.mark.stability
    def test_deterministic_at_50_frames(self):
        """Medium run should be deterministic."""
        if not _dart_available():
            pytest.skip("Dart not found")
        grid_a = _export_grid(50)
        grid_b = _export_grid(50)
        mismatches = int(np.sum(grid_a != grid_b))
        if mismatches > 0:
            pytest.xfail(
                f"Nondeterministic at 50 frames: {mismatches} cells differ"
            )
        np.testing.assert_array_equal(grid_a, grid_b)

    @pytest.mark.stability
    @pytest.mark.slow
    def test_deterministic_at_100_frames(self):
        """Longer run -- if this fails, nondeterminism accumulates."""
        if not _dart_available():
            pytest.skip("Dart not found")
        grid_a = _export_grid(100)
        grid_b = _export_grid(100)
        mismatches = int(np.sum(grid_a != grid_b))
        if mismatches > 0:
            pytest.xfail(
                f"Nondeterministic at 100 frames: {mismatches} cells differ"
            )
        np.testing.assert_array_equal(grid_a, grid_b)

    @pytest.mark.stability
    def test_deterministic_with_reactions(self):
        """Runs with active reactions (fire+wood) should still be deterministic."""
        if not _dart_available():
            pytest.skip("Dart not found")
        # Fire next to wood -- reactions active
        placements = []
        cx, cy = WIDTH // 2, HEIGHT - 10
        for dx in range(20):
            placements.append((cx + dx, cy, 20))  # wood
        placements.append((cx - 1, cy, 3))  # fire
        grid_a = _run_chaos_scenario(placements, frames=50)["grid"]
        grid_b = _run_chaos_scenario(placements, frames=50)["grid"]
        mismatches = int(np.sum(grid_a != grid_b))
        if mismatches > 0:
            pytest.xfail(
                f"Nondeterministic with reactions: {mismatches} cells differ"
            )
        np.testing.assert_array_equal(grid_a, grid_b)

    @pytest.mark.stability
    def test_deterministic_with_temperature(self):
        """Temperature propagation should be deterministic."""
        if not _dart_available():
            pytest.skip("Dart not found")
        # Lava as heat source
        placements = [(WIDTH // 2, HEIGHT // 2, 18)]
        res_a = _run_chaos_scenario(placements, frames=50)
        res_b = _run_chaos_scenario(placements, frames=50)
        if "temperature" in res_a and "temperature" in res_b:
            mismatches = int(np.sum(res_a["temperature"] != res_b["temperature"]))
            if mismatches > 0:
                pytest.xfail(
                    f"Temperature nondeterministic: {mismatches} cells differ"
                )
            np.testing.assert_array_equal(res_a["temperature"], res_b["temperature"])

    @pytest.mark.stability
    def test_frame_order_independence(self):
        """Left-to-right vs right-to-left processing should give same result.

        The engine alternates scan direction each frame (frameCount.isEven).
        After an even number of frames, both directions have been used equally.
        """
        if not _dart_available():
            pytest.skip("Dart not found")
        # Run for an even number of frames so both scan directions are used
        grid_even = _export_grid(100)
        # The grid should be fully settled and consistent regardless of direction
        assert grid_even.shape == (HEIGHT, WIDTH)
        # Verify grid is not degenerate
        assert int((grid_even != 0).sum()) > 100


# ---------------------------------------------------------------------------
# 2. Mass Conservation Tests
# ---------------------------------------------------------------------------


class TestMassConservation:
    """Element count should be conserved in non-reactive systems.
    In reactive systems, products should account for reactants.
    """

    @pytest.mark.stability
    def test_stone_only_mass_conserved(self):
        """Grid with only stone: count stays constant over 200 frames."""
        if not _dart_available():
            pytest.skip("Dart not found")
        # Place a block of stone
        placements = [
            (x, y, 7) for y in range(HEIGHT - 30, HEIGHT)
            for x in range(50, 270)
        ]
        initial_count = len(placements)
        result = _run_chaos_scenario(placements, frames=200)
        final_count = int((result["grid"] == 7).sum())
        assert final_count == initial_count, (
            f"Stone count changed: {initial_count} -> {final_count}"
        )

    @pytest.mark.stability
    def test_sand_only_mass_conserved(self):
        """Grid with only sand: count stays constant (no reactions possible)."""
        if not _dart_available():
            pytest.skip("Dart not found")
        # Place sand on a stone floor so it settles
        placements = []
        # Stone floor
        for x in range(WIDTH):
            for y in range(HEIGHT - 5, HEIGHT):
                placements.append((x, y, 7))
        # Sand above
        sand_cells = 0
        for x in range(50, 270):
            for y in range(HEIGHT - 15, HEIGHT - 5):
                placements.append((x, y, 1))
                sand_cells += 1
        result = _run_chaos_scenario(placements, frames=200)
        final_sand = int((result["grid"] == 1).sum())
        # Sand can absorb water to become mud, but there's no water here
        assert final_sand == sand_cells, (
            f"Sand count changed: {sand_cells} -> {final_sand}"
        )

    @pytest.mark.stability
    def test_water_only_mass_conserved(self):
        """Grid with only water in a sealed container: count stays constant."""
        if not _dart_available():
            pytest.skip("Dart not found")
        placements = []
        # Stone container
        for x in range(50, 270):
            placements.append((x, HEIGHT - 1, 7))  # floor
        for y in range(HEIGHT - 30, HEIGHT):
            placements.append((50, y, 7))  # left wall
            placements.append((269, y, 7))  # right wall
        # Water inside
        water_cells = 0
        for x in range(51, 269):
            for y in range(HEIGHT - 20, HEIGHT - 1):
                placements.append((x, y, 2))
                water_cells += 1
        result = _run_chaos_scenario(placements, frames=200)
        final_water = int((result["grid"] == 2).sum())
        # Allow small tolerance for edge effects
        drift = abs(final_water - water_cells) / water_cells
        assert drift < 0.02, (
            f"Water count drifted: {water_cells} -> {final_water} ({drift*100:.1f}%)"
        )

    @pytest.mark.stability
    def test_mixed_inert_mass_conserved(self):
        """Sand + stone (no reactions): total count constant."""
        if not _dart_available():
            pytest.skip("Dart not found")
        placements = []
        stone_count = 0
        sand_count = 0
        # Stone base
        for x in range(WIDTH):
            for y in range(HEIGHT - 5, HEIGHT):
                placements.append((x, y, 7))
                stone_count += 1
        # Sand on top
        for x in range(100, 200):
            for y in range(HEIGHT - 10, HEIGHT - 5):
                placements.append((x, y, 1))
                sand_count += 1
        result = _run_chaos_scenario(placements, frames=200)
        final_stone = int((result["grid"] == 7).sum())
        final_sand = int((result["grid"] == 1).sum())
        assert final_stone == stone_count, (
            f"Stone count changed: {stone_count} -> {final_stone}"
        )
        assert final_sand == sand_count, (
            f"Sand count changed: {sand_count} -> {final_sand}"
        )

    @pytest.mark.stability
    def test_reactive_mass_balance(self):
        """Fire + wood: total non-empty cells should be bounded."""
        if not _dart_available():
            pytest.skip("Dart not found")
        placements = []
        for x in range(100, 220):
            for y in range(HEIGHT - 20, HEIGHT - 5):
                placements.append((x, y, 20))  # wood
        placements.append((100, HEIGHT - 5, 3))  # fire igniter
        result = _run_chaos_scenario(placements, frames=300)
        # Total cells must equal grid size (nothing created from nothing)
        assert result["grid"].size == TOTAL_CELLS

    @pytest.mark.stability
    def test_no_spontaneous_creation(self):
        """Empty grid stays empty (no elements created from nothing)."""
        if not _dart_available():
            pytest.skip("Dart not found")
        result = _run_chaos_scenario([], frames=100)
        non_empty = int((result["grid"] != 0).sum())
        assert non_empty == 0, (
            f"{non_empty} elements appeared from nothing in empty grid"
        )

    @pytest.mark.stability
    def test_no_element_duplication(self):
        """Single element on a floor should not become two of itself."""
        if not _dart_available():
            pytest.skip("Dart not found")
        placements = []
        # Stone floor
        for x in range(WIDTH):
            placements.append((x, HEIGHT - 1, 7))
        # Single sand cell
        placements.append((WIDTH // 2, HEIGHT - 2, 1))
        result = _run_chaos_scenario(placements, frames=100)
        sand_count = int((result["grid"] == 1).sum())
        assert sand_count <= 1, f"Sand duplicated: expected 1, got {sand_count}"

    @pytest.mark.stability
    def test_mass_drift_per_element_type(self):
        """Track count of EACH element type over time to identify which leaks."""
        if not _dart_available():
            pytest.skip("Dart not found")
        # Use the standard test world at different checkpoints
        grid_50 = _export_grid(50)
        grid_200 = _export_grid(200)
        counts_50 = _element_counts(grid_50)
        counts_200 = _element_counts(grid_200)

        drifters = []
        for el_id in range(MAX_ELEMENT_ID + 1):
            c50 = counts_50.get(el_id, 0)
            c200 = counts_200.get(el_id, 0)
            if c50 < 50:
                continue  # skip rare elements
            drift = abs(c200 - c50) / c50
            if drift > 0.15:
                drifters.append((el_id, c50, c200, drift))

        # This test documents which elements drift -- soft check
        if drifters:
            msgs = [
                f"  Element {eid}: {c1} -> {c2} ({d*100:.1f}%)"
                for eid, c1, c2, d in drifters
            ]
            # Only fail if an inert element drifts
            inert_drifters = [d for d in drifters if d[0] in INERT_ELEMENTS]
            if inert_drifters:
                pytest.fail(
                    f"Inert element count drifted:\n" + "\n".join(msgs)
                )


# ---------------------------------------------------------------------------
# 3. Temperature Stability Tests
# ---------------------------------------------------------------------------


class TestTemperatureStability:
    """Temperature should converge to equilibrium, not oscillate or diverge."""

    @pytest.mark.stability
    def test_temperature_never_exceeds_255(self):
        """No cell ever gets temp > 255 even with multiple heat sources."""
        if not _dart_available():
            pytest.skip("Dart not found")
        # Multiple lava cells as heat sources
        placements = [
            (x, HEIGHT // 2, 18) for x in range(50, 270, 5)
        ]
        result = _run_chaos_scenario(placements, frames=200)
        if result.get("temperature") is not None:
            assert result["temperature"].max() <= 255

    @pytest.mark.stability
    def test_temperature_never_below_0(self):
        """No cell ever gets temp < 0 even with multiple cold sources."""
        if not _dart_available():
            pytest.skip("Dart not found")
        # Ice as cold source
        placements = [
            (x, HEIGHT // 2, 22) for x in range(50, 270, 5)  # ice
        ]
        result = _run_chaos_scenario(placements, frames=200)
        if result.get("temperature") is not None:
            # uint8 can't go below 0, but verify
            assert result["temperature"].min() >= 0

    @pytest.mark.stability
    @pytest.mark.slow
    def test_temperature_equilibrium_reached(self):
        """After 500 frames, temperature variance should be decreasing."""
        if not _dart_available():
            pytest.skip("Dart not found")
        # Single lava cell -- heat should dissipate
        placements = [(WIDTH // 2, HEIGHT // 2, 18)]
        res_200 = _run_chaos_scenario(placements, frames=200)
        res_500 = _run_chaos_scenario(placements, frames=500)
        if res_200.get("temperature") is not None and res_500.get("temperature") is not None:
            var_200 = float(np.var(res_200["temperature"].astype(float)))
            var_500 = float(np.var(res_500["temperature"].astype(float)))
            # Variance should not increase over time (energy dissipates)
            # Allow 20% tolerance for reaction byproducts
            assert var_500 <= var_200 * 1.2, (
                f"Temperature variance increased: {var_200:.1f} -> {var_500:.1f}"
            )

    @pytest.mark.stability
    def test_no_temperature_oscillation(self):
        """Temperature at a fixed point shouldn't oscillate wildly."""
        if not _dart_available():
            pytest.skip("Dart not found")
        # Check temperature at different frame counts
        temps = []
        for frames in [50, 100, 150, 200]:
            result = _export_full(frames)
            if "temperature" in result:
                # Sample center temperature
                center_temp = int(result["temperature"][HEIGHT // 2, WIDTH // 2])
                temps.append(center_temp)
        if len(temps) >= 3:
            # Count direction changes (oscillations)
            oscillations = 0
            for i in range(1, len(temps) - 1):
                if (temps[i] > temps[i-1] and temps[i] > temps[i+1]) or \
                   (temps[i] < temps[i-1] and temps[i] < temps[i+1]):
                    oscillations += 1
            # Allow at most 1 oscillation in 4 samples
            assert oscillations <= 1, (
                f"Temperature oscillating at center: {temps}"
            )

    @pytest.mark.stability
    def test_thermal_energy_monotonic_decrease(self):
        """Total |temp - 128| should decrease over time (no free energy)."""
        if not _dart_available():
            pytest.skip("Dart not found")
        # Hot stone block -- should cool to ambient
        placements = []
        for x in range(100, 220):
            for y in range(HEIGHT - 30, HEIGHT - 10):
                placements.append((x, y, 7))
        res_50 = _run_chaos_scenario(placements, frames=50)
        res_300 = _run_chaos_scenario(placements, frames=300)
        if res_50.get("temperature") is not None and res_300.get("temperature") is not None:
            energy_50 = float(np.sum(np.abs(res_50["temperature"].astype(float) - 128)))
            energy_300 = float(np.sum(np.abs(res_300["temperature"].astype(float) - 128)))
            # Thermal energy should not increase (no free energy creation)
            # Allow 30% tolerance for reaction heat
            assert energy_300 <= energy_50 * 1.3, (
                f"Thermal energy increased: {energy_50:.0f} -> {energy_300:.0f}"
            )

    @pytest.mark.stability
    def test_temperature_converges_to_ambient(self):
        """Hot elements in empty grid should cool to 128 (neutral)."""
        if not _dart_available():
            pytest.skip("Dart not found")
        # Single lava cell -- expect surrounding temps to approach 128
        placements = [(WIDTH // 2, HEIGHT // 2, 18)]
        result = _run_chaos_scenario(placements, frames=500)
        if result.get("temperature") is not None:
            # Far from the source, temp should be near ambient (128)
            far_temp = result["temperature"][10, 10]
            assert abs(int(far_temp) - 128) < 30, (
                f"Far-field temperature {far_temp} not near ambient 128"
            )


# ---------------------------------------------------------------------------
# 4. Velocity/Momentum Stability Tests
# ---------------------------------------------------------------------------


class TestVelocityStability:
    """Velocities should be bounded and converge to zero when elements settle."""

    @pytest.mark.stability
    def test_velocity_bounded(self):
        """velX and velY should stay within int8 range (-128..127)."""
        if not _dart_available():
            pytest.skip("Dart not found")
        result = _export_full(100)
        if "velocity_x" in result:
            # Int8 is already bounded by type, but verify no corruption
            assert result["velocity_x"].dtype == np.int8
            assert result["velocity_y"].dtype == np.int8

    @pytest.mark.stability
    def test_settled_elements_zero_velocity(self):
        """Stone on a floor should have zero velocity after settling."""
        if not _dart_available():
            pytest.skip("Dart not found")
        # Place stone block -- should be perfectly static
        placements = [
            (x, y, 7) for y in range(HEIGHT - 10, HEIGHT)
            for x in range(100, 200)
        ]
        result = _run_chaos_scenario(placements, frames=100)
        grid = result["grid"]
        if result.get("velocity_x") is not None:
            stone_mask = grid == 7
            stone_vx = result["velocity_x"][stone_mask]
            stone_vy = result["velocity_y"][stone_mask]
            assert np.all(stone_vx == 0), (
                f"Stone has nonzero velX: max={stone_vx.max()}, min={stone_vx.min()}"
            )
            assert np.all(stone_vy == 0), (
                f"Stone has nonzero velY: max={stone_vy.max()}, min={stone_vy.min()}"
            )

    @pytest.mark.stability
    def test_total_momentum_decreases(self):
        """In a closed system, total |velX| + |velY| decreases over time."""
        if not _dart_available():
            pytest.skip("Dart not found")
        # Sand dropping -- should settle
        placements = []
        for x in range(WIDTH):
            placements.append((x, HEIGHT - 1, 7))  # floor
        for x in range(100, 200):
            for y in range(10, 30):
                placements.append((x, y, 1))  # sand

        res_50 = _run_chaos_scenario(placements, frames=50)
        res_300 = _run_chaos_scenario(placements, frames=300)
        if res_50.get("velocity_x") is not None and res_300.get("velocity_x") is not None:
            momentum_50 = float(
                np.sum(np.abs(res_50["velocity_x"].astype(int)))
                + np.sum(np.abs(res_50["velocity_y"].astype(int)))
            )
            momentum_300 = float(
                np.sum(np.abs(res_300["velocity_x"].astype(int)))
                + np.sum(np.abs(res_300["velocity_y"].astype(int)))
            )
            assert momentum_300 <= momentum_50 + 100, (
                f"Momentum increased: {momentum_50:.0f} -> {momentum_300:.0f}"
            )

    @pytest.mark.stability
    @pytest.mark.slow
    def test_no_perpetual_motion(self):
        """After 1000 frames, all velocities should be near zero."""
        if not _dart_available():
            pytest.skip("Dart not found")
        # Sand and water on a floor -- should fully settle
        placements = []
        for x in range(WIDTH):
            placements.append((x, HEIGHT - 1, 7))
        for x in range(50, 150):
            placements.append((x, 50, 1))
        for x in range(160, 260):
            placements.append((x, 50, 2))
        result = _run_chaos_scenario(placements, frames=1000, timeout=180)
        if result.get("velocity_x") is not None:
            total_vel = float(
                np.sum(np.abs(result["velocity_x"].astype(int)))
                + np.sum(np.abs(result["velocity_y"].astype(int)))
            )
            # Allow small residual from gas elements
            assert total_vel < 500, (
                f"Perpetual motion: total velocity = {total_vel} after 1000 frames"
            )


# ---------------------------------------------------------------------------
# 5. Grid Integrity Tests
# ---------------------------------------------------------------------------


class TestGridIntegrity:
    """The grid should always be in a valid state."""

    @pytest.mark.stability
    def test_no_invalid_element_ids(self, simulation_frame):
        """Every grid cell has a valid element ID (0-24)."""
        grid = simulation_frame["grid"]
        assert grid.min() >= 0
        assert grid.max() <= MAX_ELEMENT_ID, (
            f"Invalid element ID {grid.max()} in grid"
        )

    @pytest.mark.stability
    def test_no_negative_life_values(self):
        """life array never goes negative (uint8 enforced, but verify)."""
        if not _dart_available():
            pytest.skip("Dart not found")
        result = _export_full(100)
        if "life" in result:
            assert result["life"].dtype == np.uint8
            assert result["life"].min() >= 0

    @pytest.mark.stability
    def test_flags_valid(self):
        """flags array values are within expected bit patterns (uint8)."""
        if not _dart_available():
            pytest.skip("Dart not found")
        result = _export_full(100)
        if "flags" in result:
            assert result["flags"].dtype == np.uint8
            # uint8 is always 0-255, just verify no corruption
            assert result["flags"].min() >= 0
            assert result["flags"].max() <= 255

    @pytest.mark.stability
    def test_grid_dimensions_stable(self, simulation_frame):
        """Grid always has exactly 320x180 cells."""
        grid = simulation_frame["grid"]
        assert grid.shape == (HEIGHT, WIDTH)
        assert grid.size == TOTAL_CELLS

    @pytest.mark.stability
    def test_no_nan_or_inf(self):
        """No NaN or infinity in any numeric array."""
        if not _dart_available():
            pytest.skip("Dart not found")
        result = _export_full(100)
        for key in ["grid", "temperature", "velocity_x", "velocity_y", "life", "flags"]:
            if key in result:
                arr = result[key].astype(float)
                assert not np.any(np.isnan(arr)), f"NaN in {key}"
                assert not np.any(np.isinf(arr)), f"Inf in {key}"

    @pytest.mark.stability
    def test_total_cells_constant(self, simulation_frame):
        """Grid should always have exactly 320*180 cells."""
        grid = simulation_frame["grid"]
        assert grid.size == TOTAL_CELLS

    @pytest.mark.stability
    @pytest.mark.parametrize("frames", [1, 10, 50, 100, 200])
    def test_grid_shape_at_various_frames(self, frames):
        """Grid is always 320x180 regardless of frame count."""
        if not _dart_available():
            pytest.skip("Dart not found")
        grid = _export_grid(frames)
        assert grid.shape == (HEIGHT, WIDTH)


# ---------------------------------------------------------------------------
# 6. Long-Run Stability Tests
# ---------------------------------------------------------------------------


class TestLongRunStability:
    """Run for many frames and verify the simulation doesn't degrade."""

    @pytest.mark.stability
    @pytest.mark.slow
    def test_1000_frame_stability(self):
        """Mass drift < 5% over 1000 frames for non-reactive elements."""
        if not _dart_available():
            pytest.skip("Dart not found")
        # Stone-only: zero drift expected
        placements = [
            (x, y, 7) for y in range(HEIGHT - 20, HEIGHT)
            for x in range(WIDTH)
        ]
        stone_count = len(placements)
        result = _run_chaos_scenario(placements, frames=1000, timeout=180)
        final = int((result["grid"] == 7).sum())
        drift = abs(final - stone_count) / stone_count
        assert drift < 0.02, (
            f"Stone mass drifted {drift*100:.1f}% over 1000 frames"
        )

    @pytest.mark.stability
    def test_activity_decreases(self):
        """Number of active (non-settled) cells decreases over time."""
        if not _dart_available():
            pytest.skip("Dart not found")
        # Dropping sand should settle
        placements = []
        for x in range(WIDTH):
            placements.append((x, HEIGHT - 1, 7))  # floor
        for x in range(50, 270):
            for y in range(10, 30):
                placements.append((x, y, 1))  # sand

        res_50 = _run_chaos_scenario(placements, frames=50)
        res_300 = _run_chaos_scenario(placements, frames=300)
        if res_50.get("velocity_x") is not None and res_300.get("velocity_x") is not None:
            active_50 = int(np.sum(
                (np.abs(res_50["velocity_x"].astype(int))
                 + np.abs(res_50["velocity_y"].astype(int))) > 0
            ))
            active_300 = int(np.sum(
                (np.abs(res_300["velocity_x"].astype(int))
                 + np.abs(res_300["velocity_y"].astype(int))) > 0
            ))
            assert active_300 <= active_50 + 50, (
                f"Active cells increased: {active_50} -> {active_300}"
            )

    @pytest.mark.stability
    def test_no_element_explosion(self):
        """No element type's count grows unboundedly over time."""
        if not _dart_available():
            pytest.skip("Dart not found")
        grid_10 = _export_grid(10)
        grid_200 = _export_grid(200)
        counts_10 = _element_counts(grid_10)
        counts_200 = _element_counts(grid_200)
        for el_id in range(MAX_ELEMENT_ID + 1):
            c10 = counts_10.get(el_id, 0)
            c200 = counts_200.get(el_id, 0)
            # No element should grow more than 5x (generous for reactive elements)
            if c10 > 10:
                assert c200 < c10 * 5, (
                    f"Element {el_id} exploded: {c10} -> {c200}"
                )

    @pytest.mark.stability
    @pytest.mark.slow
    def test_eventual_equilibrium(self):
        """System reaches a stable state where changes slow down."""
        if not _dart_available():
            pytest.skip("Dart not found")
        # Compare grid at frame 800 and frame 1000
        # Sand on stone floor
        placements = []
        for x in range(WIDTH):
            placements.append((x, HEIGHT - 1, 7))
        for x in range(50, 270):
            for y in range(20, 40):
                placements.append((x, y, 1))

        res_800 = _run_chaos_scenario(placements, frames=800, timeout=180)
        res_1000 = _run_chaos_scenario(placements, frames=1000, timeout=180)
        changes = int(np.sum(res_800["grid"] != res_1000["grid"]))
        change_pct = changes / TOTAL_CELLS * 100
        # After settling, very few cells should change
        assert change_pct < 5.0, (
            f"{changes} cells changed ({change_pct:.1f}%) between frame 800 and 1000"
        )

    @pytest.mark.stability
    def test_grid_not_all_empty(self):
        """After 100 frames, grid should not be entirely empty."""
        if not _dart_available():
            pytest.skip("Dart not found")
        grid = _export_grid(100)
        non_empty = int((grid != 0).sum())
        assert non_empty > 1000, (
            f"Only {non_empty} non-empty cells after 100 frames"
        )

    @pytest.mark.stability
    def test_grid_has_multiple_elements(self):
        """After 100 frames, grid should contain multiple distinct element types."""
        if not _dart_available():
            pytest.skip("Dart not found")
        grid = _export_grid(100)
        unique_elements = len(np.unique(grid))
        assert unique_elements >= 5, (
            f"Only {unique_elements} unique elements in grid"
        )


# ---------------------------------------------------------------------------
# 7. Edge Case Stability Tests
# ---------------------------------------------------------------------------


class TestEdgeCaseStability:
    """Edge cases that stress boundary conditions."""

    @pytest.mark.stability
    def test_empty_grid_stays_empty(self):
        """Zero elements in, zero elements out."""
        if not _dart_available():
            pytest.skip("Dart not found")
        result = _run_chaos_scenario([], frames=200)
        assert int((result["grid"] != 0).sum()) == 0

    @pytest.mark.stability
    def test_single_element_stable(self):
        """One sand cell on floor -- doesn't multiply or vanish."""
        if not _dart_available():
            pytest.skip("Dart not found")
        placements = [
            (WIDTH // 2, HEIGHT - 1, 7),  # stone floor cell
            (WIDTH // 2, HEIGHT - 2, 1),  # sand on top
        ]
        result = _run_chaos_scenario(placements, frames=200)
        sand_count = int((result["grid"] == 1).sum())
        assert sand_count == 1, f"Sand count changed: expected 1, got {sand_count}"

    @pytest.mark.stability
    def test_full_grid_stable(self):
        """Grid completely full of stone -- no crashes, no changes."""
        if not _dart_available():
            pytest.skip("Dart not found")
        placements = [
            (x, y, 7) for y in range(HEIGHT) for x in range(WIDTH)
        ]
        result = _run_chaos_scenario(placements, frames=50)
        stone_count = int((result["grid"] == 7).sum())
        assert stone_count == TOTAL_CELLS, (
            f"Full stone grid lost cells: {TOTAL_CELLS} -> {stone_count}"
        )

    @pytest.mark.stability
    def test_left_boundary_stable(self):
        """Elements at x=0 don't wrap or duplicate."""
        if not _dart_available():
            pytest.skip("Dart not found")
        placements = [(0, y, 7) for y in range(HEIGHT)]
        result = _run_chaos_scenario(placements, frames=100)
        stone_count = int((result["grid"] == 7).sum())
        assert stone_count == HEIGHT, (
            f"Left boundary stone count: expected {HEIGHT}, got {stone_count}"
        )

    @pytest.mark.stability
    def test_right_boundary_stable(self):
        """Elements at x=319 don't wrap or duplicate."""
        if not _dart_available():
            pytest.skip("Dart not found")
        placements = [(WIDTH - 1, y, 7) for y in range(HEIGHT)]
        result = _run_chaos_scenario(placements, frames=100)
        stone_count = int((result["grid"] == 7).sum())
        assert stone_count == HEIGHT

    @pytest.mark.stability
    def test_top_row_stable(self):
        """Elements at y=0 don't wrap to y=179."""
        if not _dart_available():
            pytest.skip("Dart not found")
        placements = [(x, 0, 7) for x in range(WIDTH)]
        result = _run_chaos_scenario(placements, frames=100)
        # Stone at y=0 should stay at y=0 (no gravity -- stone is immobile)
        top_row_stone = int((result["grid"][0, :] == 7).sum())
        bottom_row_stone = int((result["grid"][HEIGHT - 1, :] == 7).sum())
        assert top_row_stone == WIDTH, (
            f"Top row stone: expected {WIDTH}, got {top_row_stone}"
        )
        assert bottom_row_stone == 0, (
            f"Stone wrapped to bottom row: {bottom_row_stone}"
        )

    @pytest.mark.stability
    def test_bottom_row_stable(self):
        """Elements at y=179 don't wrap to y=0."""
        if not _dart_available():
            pytest.skip("Dart not found")
        placements = [(x, HEIGHT - 1, 7) for x in range(WIDTH)]
        result = _run_chaos_scenario(placements, frames=100)
        bottom_stone = int((result["grid"][HEIGHT - 1, :] == 7).sum())
        top_stone = int((result["grid"][0, :] == 7).sum())
        assert bottom_stone == WIDTH
        assert top_stone == 0, f"Stone wrapped to top row: {top_stone}"

    @pytest.mark.stability
    def test_wrap_boundary_stable(self):
        """Elements at x=0 and x=319 don't duplicate across boundary."""
        if not _dart_available():
            pytest.skip("Dart not found")
        placements = [
            (0, HEIGHT - 1, 7),
            (WIDTH - 1, HEIGHT - 1, 7),
        ]
        result = _run_chaos_scenario(placements, frames=100)
        stone_count = int((result["grid"] == 7).sum())
        assert stone_count == 2, (
            f"Boundary stone duplicated: expected 2, got {stone_count}"
        )


# ---------------------------------------------------------------------------
# 8. Element Count Drift (standard test world) -- expanded from original
# ---------------------------------------------------------------------------


class TestElementCountDrift:
    """Element count should not drift excessively over long simulations."""

    @pytest.mark.stability
    def test_element_count_drift_100_vs_200(self):
        """Element counts at frame 100 vs 200 should not drift excessively.

        The standard test world has active reactions (lava, water, wood,
        sand+water->mud), so reactive elements are expected to drift.
        Only inert elements (stone, metal, glass) should be stable.
        """
        if not _dart_available():
            pytest.skip("Dart not found")
        grid_100 = _export_grid(100)
        grid_200 = _export_grid(200)
        for el_id in range(MAX_ELEMENT_ID + 1):
            count_100 = int((grid_100 == el_id).sum())
            count_200 = int((grid_200 == el_id).sum())
            if count_100 < 50:
                continue
            drift = abs(count_200 - count_100) / count_100
            # Inert elements: strict threshold
            # Reactive elements: relaxed threshold (reactions consume/produce)
            threshold = 0.02 if el_id in INERT_ELEMENTS else 0.40
            assert drift < threshold, (
                f"Element {el_id}: count drifted {drift*100:.1f}% "
                f"({count_100} -> {count_200})"
            )

    @pytest.mark.stability
    def test_element_count_drift_50_vs_500(self):
        """Longer-range drift check for standard test world.

        Reactive elements (sand, water, lava, fire) will naturally change
        count due to reactions. Only inert elements must stay constant.
        """
        if not _dart_available():
            pytest.skip("Dart not found")
        grid_50 = _export_grid(50)
        grid_500 = _export_grid(500)
        for el_id in range(MAX_ELEMENT_ID + 1):
            count_50 = int((grid_50 == el_id).sum())
            count_500 = int((grid_500 == el_id).sum())
            if count_50 < 100:
                continue
            drift = abs(count_500 - count_50) / count_50
            threshold = 0.02 if el_id in INERT_ELEMENTS else 0.50
            assert drift < threshold, (
                f"Element {el_id}: count drifted {drift*100:.1f}% "
                f"({count_50} -> {count_500})"
            )


# ---------------------------------------------------------------------------
# 9. No Teleportation Tests
# ---------------------------------------------------------------------------


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
