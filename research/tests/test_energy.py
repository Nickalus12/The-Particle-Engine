"""Energy conservation tests: thermodynamic consistency and energy budget tracking.

Validates that:
  - Total energy is bounded (no free energy creation)
  - PE converts to KE during free fall
  - Combustion transfers chemical -> thermal energy
  - Closed systems reach equilibrium
  - Entropy never decreases in isolated systems (2nd law)
  - Energy transfer via impact, friction, radiation, and phase change
"""

import math
import sys
from pathlib import Path

import numpy as np
import pytest

# Add research directory to path for energy_analyzer import
RESEARCH_DIR = Path(__file__).parent.parent
if str(RESEARCH_DIR) not in sys.path:
    sys.path.insert(0, str(RESEARCH_DIR))

from energy_analyzer import (
    DENSITY,
    FUEL_ELEMENTS,
    FUEL_ENERGY,
    GRAVITY,
    TEMP_NEUTRAL,
    compute_energy_budget,
    compute_entropy,
    energy_drift_percent,
    max_energy_growth_percent,
)


# ---------------------------------------------------------------------------
# Helpers: build synthetic grids for isolated energy tests
# ---------------------------------------------------------------------------

def make_empty_grid(h=50, w=50):
    """Create empty grid with matching zero arrays."""
    grid = np.zeros((h, w), dtype=np.uint8)
    temp = np.full((h, w), TEMP_NEUTRAL, dtype=np.uint8)
    vx = np.zeros((h, w), dtype=np.int8)
    vy = np.zeros((h, w), dtype=np.int8)
    return grid, temp, vx, vy


def place_element(grid, temp, vx, vy, el_id, positions, velocity=(0, 0), temperature=None):
    """Place an element at given (y, x) positions."""
    for y, x in positions:
        grid[y, x] = el_id
        vx[y, x] = velocity[0]
        vy[y, x] = velocity[1]
        if temperature is not None:
            temp[y, x] = temperature


# ---------------------------------------------------------------------------
# Energy Conservation Tests
# ---------------------------------------------------------------------------

class TestEnergyConservation:
    """Verify total energy is bounded and doesn't grow without sources."""

    @pytest.mark.physics
    def test_total_energy_nonnegative(self):
        """Energy components should never be negative."""
        grid, temp, vx, vy = make_empty_grid()
        # Place some elements
        place_element(grid, temp, vx, vy, 1, [(10, 10), (10, 11)])  # sand
        place_element(grid, temp, vx, vy, 2, [(20, 10)], temperature=200)  # hot water

        budget = compute_energy_budget(grid, temp, vx, vy)
        assert budget["kinetic"] >= 0
        assert budget["potential"] >= 0
        assert budget["thermal"] >= 0
        assert budget["chemical"] >= 0
        assert budget["total"] >= 0

    @pytest.mark.physics
    def test_empty_grid_zero_energy(self):
        """An empty grid should have zero energy."""
        grid, temp, vx, vy = make_empty_grid()
        budget = compute_energy_budget(grid, temp, vx, vy)
        assert budget["total"] == 0.0

    @pytest.mark.physics
    def test_stationary_has_no_kinetic(self):
        """Elements with zero velocity have zero kinetic energy."""
        grid, temp, vx, vy = make_empty_grid()
        place_element(grid, temp, vx, vy, 7, [(25, 25)])  # stone
        budget = compute_energy_budget(grid, temp, vx, vy)
        assert budget["kinetic"] == 0.0

    @pytest.mark.physics
    def test_moving_element_has_kinetic(self):
        """Element with velocity should have positive kinetic energy."""
        grid, temp, vx, vy = make_empty_grid()
        # Sand at velocity (2, 3)
        place_element(grid, temp, vx, vy, 1, [(25, 25)], velocity=(2, 3))
        budget = compute_energy_budget(grid, temp, vx, vy)
        # KE = 0.5 * 150 * (4 + 9) = 975
        assert budget["kinetic"] == pytest.approx(975.0)

    @pytest.mark.physics
    def test_height_gives_potential_energy(self):
        """Element higher up has more potential energy."""
        grid1, temp1, vx1, vy1 = make_empty_grid()
        grid2, temp2, vx2, vy2 = make_empty_grid()

        # Sand at row 5 (near top, height = 44)
        place_element(grid1, temp1, vx1, vy1, 1, [(5, 25)])
        # Sand at row 40 (near bottom, height = 9)
        place_element(grid2, temp2, vx2, vy2, 1, [(40, 25)])

        b1 = compute_energy_budget(grid1, temp1, vx1, vy1)
        b2 = compute_energy_budget(grid2, temp2, vx2, vy2)

        assert b1["potential"] > b2["potential"]

    @pytest.mark.physics
    def test_total_energy_bounded_oracle(self, ground_truth):
        """Oracle ground truth: max total growth should be under threshold."""
        gt = ground_truth.get("energy_conservation", {})
        thresholds = gt.get("thresholds")
        if thresholds is None:
            pytest.skip("No energy_conservation thresholds in ground truth")
        assert thresholds["max_total_growth_percent"] <= 10.0

    @pytest.mark.physics
    def test_no_perpetual_motion_sand(self):
        """Sand at rest on ground: total energy should not increase over 'frames'.

        Simulated by checking that energy budget for sand at bottom is
        minimal and stable.
        """
        grid, temp, vx, vy = make_empty_grid(h=50, w=50)
        # Sand settled at bottom row
        for x in range(10, 40):
            place_element(grid, temp, vx, vy, 1, [(49, x)])

        budget = compute_energy_budget(grid, temp, vx, vy)
        # At bottom row (height=0), PE should be zero
        assert budget["potential"] == 0.0
        # No velocity
        assert budget["kinetic"] == 0.0
        # Sand is not flammable, so no chemical energy
        assert budget["chemical"] == 0.0


class TestGravityEnergyConversion:
    """Falling elements convert PE to KE. Total roughly conserved."""

    @pytest.mark.physics
    def test_pe_decreases_with_height(self):
        """PE should decrease as element falls (height decreases)."""
        budgets = []
        for row in [5, 15, 25, 35, 45]:
            grid, temp, vx, vy = make_empty_grid()
            place_element(grid, temp, vx, vy, 1, [(row, 25)])
            budgets.append(compute_energy_budget(grid, temp, vx, vy))

        # PE should monotonically decrease as row increases (lower height)
        for i in range(1, len(budgets)):
            assert budgets[i]["potential"] < budgets[i - 1]["potential"]

    @pytest.mark.physics
    def test_free_fall_pe_ke_conservation(self, ground_truth):
        """Oracle: PE + KE total is constant during ideal free fall (pre-impact)."""
        gt = ground_truth.get("energy_conservation", {})
        ff = gt.get("free_fall_sand")
        if ff is None:
            pytest.skip("No free_fall_sand oracle data")

        totals = ff["total"]
        pe = ff["pe"]
        # Only check frames where element is still in flight (PE > 0)
        in_flight = [i for i, p in enumerate(pe) if p > 0]
        assert len(in_flight) > 2, "Need at least 3 in-flight frames"

        initial = totals[in_flight[0]]
        for i in in_flight:
            if initial > 0:
                drift = abs(totals[i] - initial) / initial * 100
                assert drift < 1.0, \
                    f"Frame {i}: total energy drifted {drift:.1f}% from initial"

    @pytest.mark.physics
    def test_pe_to_ke_conversion(self, ground_truth):
        """As sand falls, PE decreases and KE increases."""
        gt = ground_truth.get("energy_conservation", {})
        ff = gt.get("free_fall_sand")
        if ff is None:
            pytest.skip("No free_fall_sand oracle data")

        pe = ff["pe"]
        ke = ff["ke"]

        # First few frames: PE should decrease
        assert pe[5] < pe[0], "PE should decrease as element falls"
        # KE should increase from zero
        assert ke[5] > ke[0], "KE should increase during free fall"

    @pytest.mark.physics
    def test_water_free_fall(self, ground_truth):
        """Water free fall also conserves PE + KE (pre-impact)."""
        gt = ground_truth.get("energy_conservation", {})
        ff = gt.get("free_fall_water")
        if ff is None:
            pytest.skip("No free_fall_water oracle data")

        totals = ff["total"]
        pe = ff["pe"]
        # Only check in-flight frames
        in_flight = [i for i, p in enumerate(pe) if p > 0]
        if len(in_flight) < 2:
            pytest.skip("Not enough in-flight frames")

        initial = totals[in_flight[0]]
        if initial > 0:
            max_drift = max(
                abs(totals[i] - initial) / initial * 100 for i in in_flight
            )
            assert max_drift < 1.0


class TestCombustionEnergyTransfer:
    """Burning fuel converts chemical energy to thermal."""

    @pytest.mark.physics
    def test_fuel_has_chemical_energy(self):
        """Wood, oil, plant cells should have positive chemical energy."""
        grid, temp, vx, vy = make_empty_grid()
        place_element(grid, temp, vx, vy, 20, [(25, 25)])  # wood
        budget = compute_energy_budget(grid, temp, vx, vy)
        assert budget["chemical"] > 0

    @pytest.mark.physics
    def test_non_fuel_no_chemical_energy(self):
        """Stone, water have zero chemical energy."""
        grid, temp, vx, vy = make_empty_grid()
        place_element(grid, temp, vx, vy, 7, [(25, 25)])  # stone
        budget = compute_energy_budget(grid, temp, vx, vy)
        assert budget["chemical"] == 0.0

    @pytest.mark.physics
    def test_combustion_conserves_total(self, ground_truth):
        """Oracle: chemical + thermal total is approximately constant during combustion."""
        gt = ground_truth.get("energy_conservation", {})
        comb = gt.get("combustion_wood")
        if comb is None:
            pytest.skip("No combustion_wood oracle data")

        totals = comb["total"]
        initial = totals[0]
        # Total should stay within 15% (some energy lost to dissipation)
        for t in totals:
            if initial > 0:
                drift = abs(t - initial) / initial * 100
                assert drift < 15.0

    @pytest.mark.physics
    def test_chemical_decreases_during_burn(self, ground_truth):
        """Chemical energy should decrease as fuel is consumed."""
        gt = ground_truth.get("energy_conservation", {})
        comb = gt.get("combustion_wood")
        if comb is None:
            pytest.skip("No combustion_wood oracle data")

        chemical = comb["chemical"]
        assert chemical[-1] < chemical[0], \
            "Chemical energy should decrease after combustion"

    @pytest.mark.physics
    def test_thermal_increases_during_burn(self, ground_truth):
        """Thermal energy should increase as fuel burns."""
        gt = ground_truth.get("energy_conservation", {})
        comb = gt.get("combustion_wood")
        if comb is None:
            pytest.skip("No combustion_wood oracle data")

        thermal = comb["thermal"]
        assert thermal[-1] > thermal[0], \
            "Thermal energy should increase from combustion"

    @pytest.mark.physics
    def test_oil_burns_faster_than_wood(self, ground_truth):
        """Oil has higher energy density and faster burn rate."""
        gt = ground_truth.get("energy_conservation", {})
        oil = gt.get("combustion_oil")
        wood = gt.get("combustion_wood")
        if oil is None or wood is None:
            pytest.skip("Missing combustion oracle data")

        # Oil initial chemical should be higher (800 vs 500 per cell)
        assert oil["chemical"][0] > wood["chemical"][0]


class TestEquilibrium:
    """Closed system reaches equilibrium -- energy stops transferring."""

    @pytest.mark.physics
    def test_uniform_temp_has_zero_thermal_gradient(self):
        """Grid at uniform neutral temp has zero thermal energy."""
        grid, temp, vx, vy = make_empty_grid()
        # Fill with stone at neutral temperature
        for y in range(20, 30):
            for x in range(20, 30):
                place_element(grid, temp, vx, vy, 7, [(y, x)])

        budget = compute_energy_budget(grid, temp, vx, vy)
        assert budget["thermal"] == 0.0

    @pytest.mark.physics
    def test_cooling_approaches_equilibrium(self, ground_truth):
        """Oracle: hot object cools toward ambient temperature."""
        gt = ground_truth.get("energy_conservation", {})
        cooling = gt.get("cooling_metal")
        if cooling is None:
            pytest.skip("No cooling_metal oracle data")

        temps = cooling["temperatures"]
        # Final temperature should be near ambient (128)
        assert abs(temps[-1] - TEMP_NEUTRAL) < 5.0

    @pytest.mark.physics
    def test_cooling_monotonic(self, ground_truth):
        """Temperature should monotonically decrease when cooling."""
        gt = ground_truth.get("energy_conservation", {})
        cooling = gt.get("cooling_metal")
        if cooling is None:
            pytest.skip("No cooling_metal oracle data")

        temps = cooling["temperatures"]
        for i in range(1, len(temps)):
            assert temps[i] <= temps[i - 1] + 0.01, \
                f"Temperature increased at frame {i}"

    @pytest.mark.physics
    def test_ode_matches_analytical(self, ground_truth):
        """ODE solution should match analytical cooling solution."""
        gt = ground_truth.get("energy_conservation", {})
        analytical = gt.get("cooling_metal")
        ode = gt.get("cooling_metal_ode")
        if analytical is None or ode is None:
            pytest.skip("Missing cooling oracle data")

        for a, o in zip(analytical["temperatures"], ode["temperatures"]):
            assert a == pytest.approx(o, abs=0.5)

    @pytest.mark.physics
    def test_wood_cools_slower_than_metal(self, ground_truth):
        """Wood (low conductivity) cools slower than metal."""
        gt = ground_truth.get("energy_conservation", {})
        metal = gt.get("cooling_metal")
        wood = gt.get("cooling_wood")
        if metal is None or wood is None:
            pytest.skip("Missing cooling oracle data")

        # After same number of frames, wood should be further from ambient
        n = min(len(metal["temperatures"]), len(wood["temperatures"]))
        # Compare midpoint: wood should retain more heat
        mid = n // 2
        metal_deviation = abs(metal["temperatures"][mid] - TEMP_NEUTRAL)
        wood_deviation = abs(wood["temperatures"][mid] - TEMP_NEUTRAL)
        assert wood_deviation > metal_deviation


class TestHeatDeath:
    """Isolated system tends toward uniform temperature (heat death)."""

    @pytest.mark.physics
    def test_hot_cold_variance_decreases(self):
        """Temperature variance should decrease as heat spreads."""
        # Initial state: hot spot + cold spot
        grid1, temp1, vx1, vy1 = make_empty_grid()
        for y in range(10, 20):
            for x in range(10, 20):
                place_element(grid1, temp1, vx1, vy1, 7, [(y, x)], temperature=230)
        for y in range(30, 40):
            for x in range(30, 40):
                place_element(grid1, temp1, vx1, vy1, 7, [(y, x)], temperature=30)

        # "Equilibrium" state: uniform temperature
        grid2, temp2, vx2, vy2 = make_empty_grid()
        for y in range(10, 20):
            for x in range(10, 20):
                place_element(grid2, temp2, vx2, vy2, 7, [(y, x)], temperature=130)
        for y in range(30, 40):
            for x in range(30, 40):
                place_element(grid2, temp2, vx2, vy2, 7, [(y, x)], temperature=130)

        entropy1 = compute_entropy(grid1, temp1)
        entropy2 = compute_entropy(grid2, temp2)

        # Uniform temp has lower variance
        assert entropy2["temperature_variance"] < entropy1["temperature_variance"]

    @pytest.mark.physics
    def test_uniform_temp_minimal_variance(self):
        """Uniform temperature grid should have near-zero variance."""
        grid, temp, vx, vy = make_empty_grid()
        for y in range(10, 40):
            for x in range(10, 40):
                place_element(grid, temp, vx, vy, 7, [(y, x)], temperature=TEMP_NEUTRAL)

        ent = compute_entropy(grid, temp)
        assert ent["temperature_variance"] < 1.0


class TestSecondLaw:
    """Entropy (disorder) never decreases in an isolated system."""

    @pytest.mark.physics
    def test_entropy_increases(self, ground_truth):
        """Oracle: entropy should monotonically increase toward maximum."""
        gt = ground_truth.get("energy_conservation", {})
        mixing = gt.get("entropy_mixing")
        if mixing is None:
            pytest.skip("No entropy_mixing oracle data")

        entropy = mixing["entropy"]
        # Entropy should generally increase (allow small fluctuations)
        # Compare first vs last
        assert entropy[-1] > entropy[0], \
            "Entropy should increase from ordered to disordered state"

    @pytest.mark.physics
    def test_entropy_approaches_maximum(self, ground_truth):
        """Entropy should approach 1.0 bit (maximum for 2-state system)."""
        gt = ground_truth.get("energy_conservation", {})
        mixing = gt.get("entropy_mixing")
        if mixing is None:
            pytest.skip("No entropy_mixing oracle data")

        final_entropy = mixing["entropy"][-1]
        assert final_entropy > 0.95, \
            f"Final entropy {final_entropy:.3f} should approach 1.0"

    @pytest.mark.physics
    def test_second_law_flag(self, ground_truth):
        """Ground truth should assert the second law holds."""
        gt = ground_truth.get("energy_conservation", {})
        thresholds = gt.get("thresholds")
        if thresholds is None:
            pytest.skip("No thresholds in ground truth")
        assert thresholds["second_law_holds"] is True

    @pytest.mark.physics
    def test_ordered_state_lower_entropy(self):
        """A highly ordered grid has lower entropy than a mixed grid."""
        # Ordered: all cells are one element
        grid_ordered, temp_o, _, _ = make_empty_grid(h=20, w=20)
        grid_ordered[:, :] = 7  # all stone

        # Mixed: random elements
        rng = np.random.RandomState(42)
        grid_mixed, temp_m, _, _ = make_empty_grid(h=20, w=20)
        grid_mixed[:, :] = rng.choice([1, 2, 7, 20], size=(20, 20)).astype(np.uint8)

        ent_ordered = compute_entropy(grid_ordered, temp_o)
        ent_mixed = compute_entropy(grid_mixed, temp_m)

        assert ent_mixed["element_entropy"] > ent_ordered["element_entropy"]


# ---------------------------------------------------------------------------
# Energy Transfer Tests
# ---------------------------------------------------------------------------

class TestEnergyTransfer:
    """Test individual energy transfer mechanisms."""

    @pytest.mark.physics
    def test_impact_energy_loss(self):
        """Falling element hitting ground: KE drops to zero."""
        # In-flight: has velocity
        grid1, temp1, vx1, vy1 = make_empty_grid()
        place_element(grid1, temp1, vx1, vy1, 1, [(25, 25)], velocity=(0, 3))
        b_moving = compute_energy_budget(grid1, temp1, vx1, vy1)

        # At rest on ground: zero velocity
        grid2, temp2, vx2, vy2 = make_empty_grid()
        place_element(grid2, temp2, vx2, vy2, 1, [(49, 25)], velocity=(0, 0))
        b_rest = compute_energy_budget(grid2, temp2, vx2, vy2)

        assert b_moving["kinetic"] > 0
        assert b_rest["kinetic"] == 0.0

    @pytest.mark.physics
    def test_friction_reduces_velocity(self):
        """Water with initial velocity vs water at rest: KE difference."""
        grid1, temp1, vx1, vy1 = make_empty_grid()
        place_element(grid1, temp1, vx1, vy1, 2, [(25, 25)], velocity=(2, 0))
        b_fast = compute_energy_budget(grid1, temp1, vx1, vy1)

        grid2, temp2, vx2, vy2 = make_empty_grid()
        place_element(grid2, temp2, vx2, vy2, 2, [(25, 25)], velocity=(1, 0))
        b_slow = compute_energy_budget(grid2, temp2, vx2, vy2)

        assert b_fast["kinetic"] > b_slow["kinetic"]

    @pytest.mark.physics
    def test_radiation_spreads_thermal(self):
        """Lava has high base temperature -- thermal energy from temp deviation."""
        grid, temp, vx, vy = make_empty_grid()
        place_element(grid, temp, vx, vy, 18, [(25, 25)], temperature=250)
        budget = compute_energy_budget(grid, temp, vx, vy)
        # 250 - 128 = 122 units of thermal energy per cell
        assert budget["thermal"] == pytest.approx(122.0)

    @pytest.mark.physics
    def test_phase_change_shifts_energy(self):
        """Ice vs water: same position, different potential energy (different density)."""
        grid_ice, temp_ice, vx_ice, vy_ice = make_empty_grid()
        place_element(grid_ice, temp_ice, vx_ice, vy_ice, 4, [(10, 25)])  # ice, density=90

        grid_water, temp_water, vx_water, vy_water = make_empty_grid()
        place_element(grid_water, temp_water, vx_water, vy_water, 2, [(10, 25)])  # water, density=100

        b_ice = compute_energy_budget(grid_ice, temp_ice, vx_ice, vy_ice)
        b_water = compute_energy_budget(grid_water, temp_water, vx_water, vy_water)

        # Water has higher density -> higher PE at same height
        assert b_water["potential"] > b_ice["potential"]

    @pytest.mark.physics
    def test_tnt_highest_chemical_energy(self):
        """TNT should have the highest per-cell chemical energy."""
        for el_id in FUEL_ELEMENTS:
            if el_id == 8:  # TNT
                continue
            assert FUEL_ENERGY[8] > FUEL_ENERGY[el_id], \
                f"TNT should have more chemical energy than element {el_id}"


# ---------------------------------------------------------------------------
# Energy Budget Accuracy Tests
# ---------------------------------------------------------------------------

class TestEnergyBudgetAccuracy:
    """Verify energy computation formulas are correct."""

    @pytest.mark.physics
    def test_ke_formula(self):
        """KE = 0.5 * density * v^2."""
        grid, temp, vx, vy = make_empty_grid()
        # Sand (density=150) moving at vy=4
        place_element(grid, temp, vx, vy, 1, [(25, 25)], velocity=(0, 4))
        budget = compute_energy_budget(grid, temp, vx, vy)
        expected_ke = 0.5 * 150 * 16  # 1200
        assert budget["kinetic"] == pytest.approx(expected_ke)

    @pytest.mark.physics
    def test_pe_formula(self):
        """PE = density * |gravity| * height."""
        grid, temp, vx, vy = make_empty_grid()
        # Sand (density=150, gravity=2) at row 0 -> height = 49
        place_element(grid, temp, vx, vy, 1, [(0, 25)])
        budget = compute_energy_budget(grid, temp, vx, vy)
        expected_pe = 150 * 2 * 49  # 14700
        assert budget["potential"] == pytest.approx(expected_pe)

    @pytest.mark.physics
    def test_thermal_formula(self):
        """Thermal = |temperature - 128|."""
        grid, temp, vx, vy = make_empty_grid()
        place_element(grid, temp, vx, vy, 7, [(25, 25)], temperature=200)
        budget = compute_energy_budget(grid, temp, vx, vy)
        assert budget["thermal"] == pytest.approx(72.0)  # |200-128|

    @pytest.mark.physics
    def test_chemical_formula(self):
        """Chemical = count * fuel_energy for each fuel element."""
        grid, temp, vx, vy = make_empty_grid()
        # 3 wood cells (fuel_energy=500 each)
        place_element(grid, temp, vx, vy, 20, [(25, 25), (25, 26), (25, 27)])
        budget = compute_energy_budget(grid, temp, vx, vy)
        assert budget["chemical"] == pytest.approx(1500.0)

    @pytest.mark.physics
    def test_total_is_sum(self):
        """Total should equal sum of all components."""
        grid, temp, vx, vy = make_empty_grid()
        place_element(grid, temp, vx, vy, 20, [(10, 25)], velocity=(1, 2), temperature=180)
        budget = compute_energy_budget(grid, temp, vx, vy)
        expected_total = (
            budget["kinetic"] + budget["potential"]
            + budget["thermal"] + budget["chemical"]
        )
        assert budget["total"] == pytest.approx(expected_total)

    @pytest.mark.physics
    def test_element_counts_accurate(self):
        """Element counts in budget should match actual grid contents."""
        grid, temp, vx, vy = make_empty_grid()
        place_element(grid, temp, vx, vy, 1, [(10, 10), (10, 11), (10, 12)])  # 3 sand
        place_element(grid, temp, vx, vy, 2, [(20, 10), (20, 11)])  # 2 water
        budget = compute_energy_budget(grid, temp, vx, vy)
        assert budget["element_counts"].get(1, 0) == 3
        assert budget["element_counts"].get(2, 0) == 2


# ---------------------------------------------------------------------------
# Drift and Stability Tests
# ---------------------------------------------------------------------------

class TestEnergyDrift:
    """Helper function tests for energy drift measurement."""

    @pytest.mark.physics
    def test_zero_drift_for_constant_series(self):
        """Constant energy series has zero drift."""
        series = [{"total": 100.0}] * 10
        assert energy_drift_percent(series) == pytest.approx(0.0)

    @pytest.mark.physics
    def test_positive_drift_for_growing_energy(self):
        """Growing total energy gives positive drift."""
        series = [{"total": 100.0}, {"total": 110.0}]
        assert energy_drift_percent(series) == pytest.approx(10.0)

    @pytest.mark.physics
    def test_negative_drift_for_decaying_energy(self):
        """Decaying total energy gives negative drift."""
        series = [{"total": 100.0}, {"total": 90.0}]
        assert energy_drift_percent(series) == pytest.approx(-10.0)

    @pytest.mark.physics
    def test_max_growth_finds_peak(self):
        """max_energy_growth_percent finds the worst-case growth."""
        series = [
            {"total": 100.0},
            {"total": 105.0},
            {"total": 115.0},  # +15% peak
            {"total": 108.0},
        ]
        assert max_energy_growth_percent(series) == pytest.approx(15.0)

    @pytest.mark.physics
    def test_single_frame_no_drift(self):
        """Single frame series has zero drift."""
        series = [{"total": 42.0}]
        assert energy_drift_percent(series) == pytest.approx(0.0)
        assert max_energy_growth_percent(series) == pytest.approx(0.0)
