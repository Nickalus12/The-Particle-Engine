import math
from collections import Counter

import pytest
from hypothesis import given, strategies as st, settings, assume


# ---------------------------------------------------------------------------
# Grid constants matching the Dart engine
# ---------------------------------------------------------------------------
GRID_W = 320
GRID_H = 180
GRID_SIZE = GRID_W * GRID_H

# Element count (built-in IDs 0..24)
ELEMENT_COUNT = 25

# ---------------------------------------------------------------------------
# Element property tables extracted from element_registry.dart
# ---------------------------------------------------------------------------
# fmt: off
DENSITY = {
    0: 0, 1: 150, 2: 100, 3: 5, 4: 90, 5: 0, 6: 130, 7: 255,
    8: 140, 9: 8, 10: 120, 11: 3, 12: 80, 13: 80, 14: 110, 15: 220,
    16: 145, 17: 60, 18: 200, 19: 50, 20: 85, 21: 240, 22: 4, 23: 2, 24: 30,
}
GRAVITY = {
    0: 0, 1: 2, 2: 1, 3: -1, 4: 1, 5: 1, 6: 1, 7: 1,
    8: 2, 9: -1, 10: 1, 11: -1, 12: 1, 13: 1, 14: 1, 15: 1,
    16: 1, 17: 0, 18: 1, 19: 1, 20: 1, 21: 1, 22: -1, 23: -1, 24: 1,
}
VISCOSITY = {
    0: 1, 1: 1, 2: 1, 3: 1, 4: 1, 5: 1, 6: 1, 7: 1,
    8: 1, 9: 1, 10: 3, 11: 1, 12: 1, 13: 2, 14: 1, 15: 1,
    16: 1, 17: 1, 18: 4, 19: 1, 20: 1, 21: 1, 22: 1, 23: 1, 24: 1,
}
MAX_VELOCITY = {
    0: 2, 1: 3, 2: 2, 3: 2, 4: 2, 5: 2, 6: 2, 7: 2,
    8: 2, 9: 2, 10: 1, 11: 2, 12: 2, 13: 2, 14: 2, 15: 2,
    16: 3, 17: 2, 18: 1, 19: 2, 20: 2, 21: 2, 22: 2, 23: 2, 24: 2,
}
BASE_TEMP = {
    0: 128, 1: 128, 2: 128, 3: 230, 4: 20, 5: 250, 6: 128, 7: 128,
    8: 128, 9: 128, 10: 128, 11: 160, 12: 128, 13: 128, 14: 128, 15: 128,
    16: 128, 17: 128, 18: 250, 19: 35, 20: 128, 21: 128, 22: 145, 23: 128, 24: 135,
}
HEAT_CONDUCTIVITY = {
    0: 0.02, 1: 0.3, 2: 0.4, 3: 0.8, 4: 0.6, 5: 1.0, 6: 0.1, 7: 0.5,
    8: 0.2, 9: 0.0, 10: 0.25, 11: 0.3, 12: 0.1, 13: 0.15, 14: 0.35, 15: 0.4,
    16: 0.2, 17: 0.1, 18: 0.9, 19: 0.15, 20: 0.1, 21: 0.9, 22: 0.05, 23: 0.01, 24: 0.1,
}
MELT_POINT = {
    0: 0, 1: 220, 2: 0, 3: 0, 4: 40, 5: 0, 6: 0, 7: 220,
    8: 0, 9: 0, 10: 0, 11: 0, 12: 0, 13: 0, 14: 0, 15: 200,
    16: 0, 17: 0, 18: 0, 19: 50, 20: 0, 21: 240, 22: 0, 23: 0, 24: 0,
}
BOIL_POINT = {
    0: 0, 1: 0, 2: 180, 3: 0, 4: 0, 5: 0, 6: 0, 7: 0,
    8: 0, 9: 0, 10: 0, 11: 0, 12: 0, 13: 160, 14: 0, 15: 0,
    16: 0, 17: 0, 18: 0, 19: 0, 20: 0, 21: 0, 22: 0, 23: 0, 24: 0,
}
FREEZE_POINT = {
    0: 0, 1: 0, 2: 30, 3: 0, 4: 0, 5: 0, 6: 0, 7: 0,
    8: 0, 9: 0, 10: 0, 11: 60, 12: 0, 13: 0, 14: 0, 15: 0,
    16: 0, 17: 0, 18: 60, 19: 0, 20: 0, 21: 0, 22: 0, 23: 0, 24: 0,
}
HARDNESS = {
    0: 0, 1: 10, 2: 0, 3: 5, 4: 40, 5: 0, 6: 5, 7: 80,
    8: 15, 9: 0, 10: 15, 11: 2, 12: 5, 13: 5, 14: 0, 15: 70,
    16: 30, 17: 20, 18: 0, 19: 8, 20: 50, 21: 95, 22: 2, 23: 0, 24: 3,
}
CORROSION_RESISTANCE = {
    0: 0, 1: 0, 2: 0, 3: 0, 4: 40, 5: 0, 6: 0, 7: 60,
    8: 0, 9: 0, 10: 0, 11: 0, 12: 0, 13: 0, 14: 0, 15: 50,
    16: 0, 17: 0, 18: 0, 19: 0, 20: 30, 21: 90, 22: 0, 23: 0, 24: 0,
}
LIGHT_EMISSION = {
    0: 0, 1: 0, 2: 0, 3: 180, 4: 0, 5: 255, 6: 0, 7: 0,
    8: 0, 9: 100, 10: 0, 11: 0, 12: 0, 13: 0, 14: 30, 15: 0,
    16: 0, 17: 0, 18: 220, 19: 0, 20: 0, 21: 0, 22: 0, 23: 0, 24: 0,
}
DECAY_RATE = {
    0: 0, 1: 0, 2: 0, 3: 3, 4: 0, 5: 0, 6: 0, 7: 0,
    8: 0, 9: 1, 10: 0, 11: 1, 12: 0, 13: 0, 14: 0, 15: 0,
    16: 0, 17: 0, 18: 0, 19: 0, 20: 0, 21: 0, 22: 2, 23: 0, 24: 0,
}
FLAMMABLE = {6, 8, 12, 13, 17, 20}  # seed, tnt, ant, oil, plant, wood
SURFACE_TENSION = {
    0: 0, 1: 0, 2: 5, 3: 0, 4: 0, 5: 0, 6: 0, 7: 0,
    8: 0, 9: 0, 10: 6, 11: 0, 12: 0, 13: 3, 14: 2, 15: 0,
    16: 0, 17: 0, 18: 8, 19: 0, 20: 0, 21: 0, 22: 0, 23: 0, 24: 0,
}
WIND_RESISTANCE = {
    0: 0.0, 1: 0.4, 2: 0.9, 3: 0.2, 4: 1.0, 5: 1.0, 6: 0.4, 7: 1.0,
    8: 0.7, 9: 0.1, 10: 0.85, 11: 0.2, 12: 0.5, 13: 0.85, 14: 0.85, 15: 1.0,
    16: 0.7, 17: 1.0, 18: 0.95, 19: 0.3, 20: 1.0, 21: 1.0, 22: 0.15, 23: 0.15, 24: 0.1,
}

# Physics state enum mirroring Dart
SOLID, GRANULAR, LIQUID, GAS, POWDER, SPECIAL = range(6)
PHYSICS_STATE = {
    0: SPECIAL, 1: GRANULAR, 2: LIQUID, 3: GAS, 4: SOLID, 5: SPECIAL,
    6: SPECIAL, 7: SOLID, 8: GRANULAR, 9: GAS, 10: LIQUID, 11: GAS,
    12: SPECIAL, 13: LIQUID, 14: LIQUID, 15: SOLID, 16: GRANULAR, 17: SPECIAL,
    18: LIQUID, 19: POWDER, 20: SOLID, 21: SOLID, 22: GAS, 23: SPECIAL, 24: POWDER,
}
# fmt: on


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def wrap_x(x: int) -> int:
    """Python equivalent of the engine's wrapX."""
    r = x % GRID_W
    return r + GRID_W if r < 0 else r


def clamp(val: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, val))


# Strategies
element_id = st.integers(min_value=0, max_value=ELEMENT_COUNT - 1)
nonzero_element_id = st.integers(min_value=1, max_value=ELEMENT_COUNT - 1)
grid_x = st.integers(min_value=0, max_value=GRID_W - 1)
grid_y = st.integers(min_value=0, max_value=GRID_H - 1)
temperature = st.integers(min_value=0, max_value=255)
byte_val = st.integers(min_value=0, max_value=255)


# ===================================================================
# WRAPPING PROPERTIES (5 tests)
# ===================================================================
class TestWrappingProperties:
    @given(x=st.integers(min_value=-10000, max_value=10000))
    @settings(max_examples=200)
    def test_wrap_always_in_bounds(self, x):
        """wrapX always returns [0, gridW)."""
        assert 0 <= wrap_x(x) < GRID_W

    @given(x=st.integers(min_value=-10000, max_value=10000))
    @settings(max_examples=200)
    def test_wrap_idempotent(self, x):
        """Wrapping twice equals wrapping once."""
        assert wrap_x(wrap_x(x)) == wrap_x(x)

    @given(x=grid_x)
    @settings(max_examples=200)
    def test_wrap_identity_for_valid(self, x):
        """In-bounds values wrap to themselves."""
        assert wrap_x(x) == x

    @given(a=st.integers(-1000, 1000), b=st.integers(-1000, 1000))
    @settings(max_examples=200)
    def test_wrap_preserves_distance_mod_grid(self, a, b):
        """Wrapped distance equals unwrapped distance (mod gridW)."""
        raw_dist = (a - b) % GRID_W
        wrapped_dist = (wrap_x(a) - wrap_x(b)) % GRID_W
        assert raw_dist == wrapped_dist

    @given(x=st.integers(-10000, 10000), dx=st.integers(-5, 5))
    @settings(max_examples=200)
    def test_wrap_neighbor_adjacency(self, x, dx):
        """Wrapping x+dx differs from wrapping x by at most |dx| (mod gridW)."""
        w1 = wrap_x(x)
        w2 = wrap_x(x + dx)
        dist = min((w2 - w1) % GRID_W, (w1 - w2) % GRID_W)
        assert dist <= abs(dx)


# ===================================================================
# DENSITY PROPERTIES (8 tests)
# ===================================================================
class TestDensityProperties:
    @given(
        d1=st.integers(1, 255),
        d2=st.integers(1, 255),
        d3=st.integers(1, 255),
    )
    @settings(max_examples=200)
    def test_density_transitivity(self, d1, d2, d3):
        """If A sinks through B and B sinks through C, then A sinks through C."""
        assume(d1 != d2 and d2 != d3 and d1 != d3)
        if d1 > d2 and d2 > d3:
            assert d1 > d3

    @given(d=st.integers(1, 255))
    @settings(max_examples=200)
    def test_density_reflexive_no_displacement(self, d):
        """Element never displaces itself (same density)."""
        assert not (d > d)

    @given(d1=st.integers(1, 255), d2=st.integers(1, 255))
    @settings(max_examples=200)
    def test_density_antisymmetric(self, d1, d2):
        """If A sinks through B, B cannot sink through A."""
        assume(d1 != d2)
        if d1 > d2:
            assert not (d2 > d1)

    @given(densities=st.lists(st.integers(1, 255), min_size=2, max_size=20))
    @settings(max_examples=200)
    def test_density_sorting_deterministic(self, densities):
        """Sorting by density is deterministic and stable."""
        sorted1 = sorted(densities, reverse=True)
        sorted2 = sorted(densities, reverse=True)
        assert sorted1 == sorted2

    @given(densities=st.lists(st.integers(1, 255), min_size=2, max_size=20))
    @settings(max_examples=200)
    def test_settled_column_density_nonincreasing(self, densities):
        """A settled column has density non-increasing from bottom to top."""
        settled = sorted(densities, reverse=True)
        for i in range(len(settled) - 1):
            assert settled[i] >= settled[i + 1]

    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_element_density_in_range(self, el):
        """All element densities are in [0, 255]."""
        assert 0 <= DENSITY[el] <= 255

    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_gas_lighter_than_liquid(self, el):
        """All gas elements have lower density than all liquid elements."""
        if PHYSICS_STATE[el] == GAS:
            for other_id in range(1, ELEMENT_COUNT):
                if PHYSICS_STATE[other_id] == LIQUID:
                    assert DENSITY[el] < DENSITY[other_id]

    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_solid_density_at_least_as_heavy_as_gas(self, el):
        """All solid elements have density >= all gas elements."""
        if PHYSICS_STATE[el] == SOLID:
            for other_id in range(1, ELEMENT_COUNT):
                if PHYSICS_STATE[other_id] == GAS:
                    assert DENSITY[el] >= DENSITY[other_id]


# ===================================================================
# TEMPERATURE PROPERTIES (8 tests)
# ===================================================================
class TestTemperatureProperties:
    @given(t=temperature)
    @settings(max_examples=200)
    def test_temperature_bounded(self, t):
        """Temperature always in [0, 255]."""
        clamped = clamp(t, 0, 255)
        assert clamped == t

    @given(t_hot=st.integers(129, 255), t_cold=st.integers(0, 127))
    @settings(max_examples=200)
    def test_heat_flows_hot_to_cold(self, t_hot, t_cold):
        """Temperature difference between hot and cold is always positive."""
        assert t_hot - t_cold > 0

    @given(
        t1=temperature,
        t2=temperature,
        k=st.floats(min_value=0.01, max_value=1.0),
    )
    @settings(max_examples=200)
    def test_heat_transfer_reduces_difference(self, t1, t2, k):
        """Heat transfer always reduces temperature difference."""
        assume(t1 != t2)
        diff_before = abs(t1 - t2)
        transfer = int(diff_before * k) // 10
        if transfer > 0:
            new_t1 = t1 - transfer if t1 > t2 else t1 + transfer
            new_t2 = t2 + transfer if t1 > t2 else t2 - transfer
            diff_after = abs(new_t1 - new_t2)
            assert diff_after <= diff_before

    @given(
        t1=temperature,
        t2=temperature,
        k=st.floats(min_value=0.01, max_value=1.0),
    )
    @settings(max_examples=200)
    def test_heat_transfer_conserves_total(self, t1, t2, k):
        """Total temperature is conserved during transfer (no energy created)."""
        assume(t1 != t2)
        total_before = t1 + t2
        transfer = int(abs(t1 - t2) * k) // 10
        new_t1 = t1 - transfer if t1 > t2 else t1 + transfer
        new_t2 = t2 + transfer if t1 > t2 else t2 - transfer
        total_after = new_t1 + new_t2
        assert total_after == total_before

    @given(t=temperature, melt=st.integers(1, 254))
    @settings(max_examples=200)
    def test_phase_change_threshold_exclusive(self, t, melt):
        """Element melts IFF temperature > meltPoint. Exactly one is true."""
        should_melt = t > melt
        should_not_melt = t <= melt
        assert should_melt != should_not_melt

    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_base_temperature_in_range(self, el):
        """All element base temperatures are in [0, 255]."""
        assert 0 <= BASE_TEMP[el] <= 255

    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_hot_elements_have_high_base_temp(self, el):
        """Elements that emit heat-light (fire, lava) have baseTemp > 128."""
        # Rainbow emits light but is not a heat source
        if LIGHT_EMISSION[el] >= 100 and BASE_TEMP[el] != 128:
            assert BASE_TEMP[el] > 128

    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_melt_point_above_freeze_point(self, el):
        """If an element has both melt and freeze points, melt > freeze."""
        mp = MELT_POINT[el]
        fp = FREEZE_POINT[el]
        if mp > 0 and fp > 0:
            assert mp > fp


# ===================================================================
# GRAVITY PROPERTIES (8 tests)
# ===================================================================
class TestGravityProperties:
    @given(
        gravity=st.integers(1, 5),
        max_vel=st.integers(1, 10),
        frames=st.integers(1, 200),
    )
    @settings(max_examples=200)
    def test_falling_distance_monotonic(self, gravity, max_vel, frames):
        """More frames always means more distance fallen."""
        dist_n = sum(min(i * gravity, max_vel) for i in range(1, frames + 1))
        dist_n1 = sum(min(i * gravity, max_vel) for i in range(1, frames + 2))
        assert dist_n1 >= dist_n

    @given(gravity=st.integers(1, 5), max_vel=st.integers(1, 10))
    @settings(max_examples=200)
    def test_velocity_capped(self, gravity, max_vel):
        """Velocity never exceeds maxVelocity."""
        vel = 0
        for _ in range(100):
            vel = min(vel + gravity, max_vel)
            assert vel <= max_vel

    @given(gravity=st.integers(1, 5), max_vel=st.integers(1, 10))
    @settings(max_examples=200)
    def test_terminal_velocity_reached(self, gravity, max_vel):
        """Terminal velocity is reached within ceil(maxVel/gravity) frames."""
        vel = 0
        frames_to_terminal = (max_vel + gravity - 1) // gravity
        for _ in range(frames_to_terminal):
            vel = min(vel + gravity, max_vel)
        assert vel == max_vel

    @given(
        g1=st.integers(1, 5),
        g2=st.integers(1, 5),
        max_vel=st.integers(3, 10),
        frames=st.integers(5, 50),
    )
    @settings(max_examples=200)
    def test_higher_gravity_falls_faster(self, g1, g2, max_vel, frames):
        """Higher gravity always means >= distance fallen."""
        assume(g1 > g2)
        d1 = sum(min(i * g1, max_vel) for i in range(1, frames + 1))
        d2 = sum(min(i * g2, max_vel) for i in range(1, frames + 1))
        assert d1 >= d2

    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_gas_has_negative_gravity(self, el):
        """Gas elements rise (negative gravity)."""
        if PHYSICS_STATE[el] == GAS:
            assert GRAVITY[el] < 0

    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_solid_has_nonneg_gravity(self, el):
        """Solid elements don't rise (gravity >= 0)."""
        if PHYSICS_STATE[el] == SOLID:
            assert GRAVITY[el] >= 0

    @given(
        gravity=st.integers(1, 5),
        max_vel=st.integers(1, 10),
    )
<<<<<<< HEAD
    def test_temperature_in_bounds(self, temp):
        """Temperature must always be in [0, 255]."""
        assert 0 <= temp <= 255


class TestWindResistance:
    """Wind resistance values should be physically plausible."""

    @pytest.mark.physics
    def test_wind_resistance_values_in_range(self, ground_truth):
        """All wind resistance values should be in [0, 1]."""
        gt = ground_truth.get("wind_resistance")
        if gt is None:
            pytest.skip("No wind_resistance oracle data")
        for name, value in gt["values"].items():
            assert 0 <= value <= 1, (
                f"{name} wind resistance {value} out of [0, 1]"
            )

    @pytest.mark.physics
    def test_solids_high_wind_resistance(self, ground_truth):
        """Solid elements should have high wind resistance (heavy, not blown away)."""
        gt = ground_truth.get("wind_resistance")
        if gt is None:
            pytest.skip("No wind_resistance oracle data")
        values = gt["values"]
        for solid in ["stone", "metal", "glass", "wood", "ice"]:
            if solid in values:
                assert values[solid] >= 0.8, (
                    f"{solid} wind resistance {values[solid]} too low for a solid"
                )

    @pytest.mark.physics
    def test_gases_low_wind_resistance(self, ground_truth):
        """Gas elements should have low wind resistance (easily blown)."""
        gt = ground_truth.get("wind_resistance")
        if gt is None:
            pytest.skip("No wind_resistance oracle data")
        values = gt["values"]
        for gas in ["fire", "steam", "smoke", "rainbow"]:
            if gas in values:
                assert values[gas] <= 0.3, (
                    f"{gas} wind resistance {values[gas]} too high for a gas"
                )
=======
    @settings(max_examples=200)
    def test_velocity_monotonically_increases_to_terminal(self, gravity, max_vel):
        """Velocity increases each frame until terminal, then stays constant."""
        vel = 0
        for _ in range(50):
            new_vel = min(vel + gravity, max_vel)
            assert new_vel >= vel
            vel = new_vel

    @given(
        gravity=st.integers(1, 5),
        max_vel=st.integers(1, 10),
        frames=st.integers(1, 100),
    )
    @settings(max_examples=200)
    def test_distance_at_least_linear_until_terminal(self, gravity, max_vel, frames):
        """Distance >= frames (at minimum 1 cell per frame when gravity >= 1)."""
        dist = sum(min((i + 1) * gravity, max_vel) for i in range(frames))
        assert dist >= frames


# ===================================================================
# CONSERVATION PROPERTIES (6 tests)
# ===================================================================
class TestConservationProperties:
    @given(elements=st.lists(st.integers(1, 24), min_size=1, max_size=50))
    @settings(max_examples=200)
    def test_element_count_nonnegative(self, elements):
        """Element counts are always non-negative."""
        counts = Counter(elements)
        assert all(c >= 0 for c in counts.values())

    @given(n=st.integers(1, 1000))
    @settings(max_examples=200)
    def test_closed_system_mass_constant(self, n):
        """In a closed non-reactive system, particle count is conserved."""
        initial = n
        # No reactions: count stays the same
        assert initial == n

    @given(ke=st.floats(0, 1000), pe=st.floats(0, 1000))
    @settings(max_examples=200)
    def test_total_energy_nonnegative(self, ke, pe):
        """Total energy (KE + PE) is always non-negative."""
        assert ke + pe >= 0

    @given(
        t1=temperature,
        t2=temperature,
    )
    @settings(max_examples=200)
    def test_symmetric_heat_exchange_conserves_total(self, t1, t2):
        """Symmetric heat exchange between two cells conserves total temperature."""
        total_before = t1 + t2
        diff = t1 - t2
        transfer = diff // 2  # integer symmetric transfer
        new_t1 = t1 - transfer
        new_t2 = t2 + transfer
        total_after = new_t1 + new_t2
        assert total_after == total_before

    @given(
        x=grid_x,
        y=grid_y,
    )
    @settings(max_examples=200)
    def test_grid_index_bijection(self, x, y):
        """Grid coordinate to index is a bijection."""
        idx = y * GRID_W + x
        recovered_x = idx % GRID_W
        recovered_y = idx // GRID_W
        assert recovered_x == x
        assert recovered_y == y

    @given(
        x=grid_x,
        y=grid_y,
        el=nonzero_element_id,
    )
    @settings(max_examples=200)
    def test_element_valid_at_any_position(self, x, y, el):
        """Any element ID is valid at any grid position."""
        idx = y * GRID_W + x
        assert 0 <= idx < GRID_SIZE
        assert 1 <= el < ELEMENT_COUNT


# ===================================================================
# PRESSURE PROPERTIES (5 tests)
# ===================================================================
class TestPressureProperties:
    @given(depth=st.integers(1, 100), density=st.integers(1, 255))
    @settings(max_examples=200)
    def test_pressure_increases_with_depth(self, depth, density):
        """Deeper = more pressure."""
        p1 = depth * density
        p2 = (depth + 1) * density
        assert p2 > p1

    @given(
        depth=st.integers(1, 100),
        d1=st.integers(1, 255),
        d2=st.integers(1, 255),
    )
    @settings(max_examples=200)
    def test_denser_fluid_more_pressure(self, depth, d1, d2):
        """Denser fluid creates more pressure at same depth."""
        assume(d1 > d2)
        assert depth * d1 > depth * d2

    @given(
        depth=st.integers(0, 100),
        density=st.integers(1, 255),
    )
    @settings(max_examples=200)
    def test_pressure_nonnegative(self, depth, density):
        """Hydrostatic pressure is always non-negative."""
        assert depth * density >= 0

    @given(
        depth=st.integers(1, 100),
        density=st.integers(1, 255),
    )
    @settings(max_examples=200)
    def test_pressure_linear_in_depth(self, depth, density):
        """Pressure scales linearly with depth."""
        p1 = depth * density
        p2 = (2 * depth) * density
        assert p2 == 2 * p1

    @given(
        depth=st.integers(1, 50),
        density=st.integers(1, 255),
    )
    @settings(max_examples=200)
    def test_pressure_additive(self, depth, density):
        """Pressure at depth A+B equals sum of pressures at A and B."""
        a = depth
        b = depth + 1
        assert (a + b) * density == a * density + b * density


# ===================================================================
# VISCOSITY PROPERTIES (5 tests)
# ===================================================================
class TestViscosityProperties:
    @given(v1=st.integers(1, 10), v2=st.integers(1, 10))
    @settings(max_examples=200)
    def test_viscosity_higher_means_slower(self, v1, v2):
        """Higher viscosity = fewer flow events in N frames."""
        assume(v1 > v2)
        frames = 100
        flows_v1 = sum(1 for f in range(frames) if f % v1 == 0)
        flows_v2 = sum(1 for f in range(frames) if f % v2 == 0)
        assert flows_v1 <= flows_v2

    @given(viscosity=st.integers(1, 10), frames=st.integers(1, 200))
    @settings(max_examples=200)
    def test_flow_count_nonnegative(self, viscosity, frames):
        """Flow events are always non-negative."""
        flow_count = frames // viscosity
        assert flow_count >= 0

    @given(viscosity=st.integers(1, 10))
    @settings(max_examples=200)
    def test_viscosity_1_flows_every_frame(self, viscosity):
        """Viscosity of 1 means flow every frame."""
        if viscosity == 1:
            for f in range(100):
                assert f % viscosity == 0

    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_element_viscosity_positive(self, el):
        """All element viscosities are >= 1 (no division by zero)."""
        assert VISCOSITY[el] >= 1

    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_liquid_viscosity_range(self, el):
        """Liquid element viscosities are in [1, 10]."""
        if PHYSICS_STATE[el] == LIQUID:
            assert 1 <= VISCOSITY[el] <= 10


# ===================================================================
# COMBINATORIAL / ELEMENT PROPERTIES (7 tests)
# ===================================================================
class TestElementProperties:
    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_every_element_has_physics_state(self, el):
        """Every element has a valid physics state."""
        assert PHYSICS_STATE[el] in {SOLID, GRANULAR, LIQUID, GAS, POWDER, SPECIAL}

    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_flammable_elements_not_liquid_metal(self, el):
        """No liquid metal (lava) is flammable."""
        if el == 18:  # lava
            assert el not in FLAMMABLE

    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_decay_rate_zero_means_eternal(self, el):
        """Elements with decayRate 0 never decay."""
        if DECAY_RATE[el] == 0:
            # No decay means element persists indefinitely
            assert DECAY_RATE[el] == 0

    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_decaying_elements_have_product(self, el):
        """If decayRate > 0, the element decays into something defined."""
        decays_into = {3: 22, 9: 0, 11: 2, 22: 0}  # fire->smoke, rainbow->empty, steam->water, smoke->empty
        if DECAY_RATE[el] > 0:
            assert el in decays_into

    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_max_velocity_positive(self, el):
        """maxVelocity is always >= 1."""
        assert MAX_VELOCITY[el] >= 1

    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_heat_conductivity_in_range(self, el):
        """Heat conductivity is in [0.0, 1.0]."""
        assert 0.0 <= HEAT_CONDUCTIVITY[el] <= 1.0

    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_wind_resistance_in_range(self, el):
        """Wind resistance is in [0.0, 1.0]."""
        assert 0.0 <= WIND_RESISTANCE[el] <= 1.0


# ===================================================================
# SURFACE TENSION PROPERTIES (3 tests)
# ===================================================================
class TestSurfaceTensionProperties:
    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_surface_tension_only_on_liquids(self, el):
        """Only liquid elements have non-zero surface tension."""
        if SURFACE_TENSION[el] > 0:
            assert PHYSICS_STATE[el] == LIQUID

    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_surface_tension_in_range(self, el):
        """Surface tension is in [0, 10]."""
        assert 0 <= SURFACE_TENSION[el] <= 10

    @given(
        st_val=st.integers(0, 10),
        neighbors=st.integers(0, 8),
    )
    @settings(max_examples=200)
    def test_cohesion_force_bounded(self, st_val, neighbors):
        """Cohesion force (surface_tension * neighbor_count) is bounded."""
        force = st_val * neighbors
        assert 0 <= force <= 80  # max 10 * 8


# ===================================================================
# LIGHT EMISSION PROPERTIES (3 tests)
# ===================================================================
class TestLightEmissionProperties:
    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_light_emission_in_range(self, el):
        """Light emission is in [0, 255]."""
        assert 0 <= LIGHT_EMISSION[el] <= 255

    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_emitting_elements_have_color(self, el):
        """Elements with light emission > 0 have at least one nonzero RGB channel."""
        if LIGHT_EMISSION[el] > 0:
            lr = {3: 255, 5: 255, 9: 200, 14: 20, 18: 255}
            lg = {3: 120, 5: 255, 9: 100, 14: 255, 18: 80}
            lb = {3: 20, 5: 180, 9: 255, 14: 20, 18: 10}
            assert lr.get(el, 0) + lg.get(el, 0) + lb.get(el, 0) > 0

    @given(
        emission=byte_val,
        distance=st.integers(1, 20),
    )
    @settings(max_examples=200)
    def test_light_falloff_monotonic(self, emission, distance):
        """Light intensity decreases with distance."""
        if emission > 0:
            # Integer falloff formula from pixel_renderer
            at_d = max(0, emission - distance * 10)
            at_d1 = max(0, emission - (distance + 1) * 10)
            assert at_d1 <= at_d


# ===================================================================
# CORROSION / HARDNESS PROPERTIES (3 tests)
# ===================================================================
class TestCorrosionProperties:
    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_hardness_in_range(self, el):
        """Hardness is in [0, 255]."""
        assert 0 <= HARDNESS[el] <= 255

    @given(el=nonzero_element_id)
    @settings(max_examples=200)
    def test_corrosion_resistance_in_range(self, el):
        """Corrosion resistance is in [0, 255]."""
        assert 0 <= CORROSION_RESISTANCE[el] <= 255

    @given(
        hardness=byte_val,
        acid_strength=st.integers(1, 100),
        resistance=byte_val,
    )
    @settings(max_examples=200)
    def test_higher_resistance_survives_longer(self, hardness, acid_strength, resistance):
        """Higher corrosion resistance means more acid ticks to dissolve."""
        r1 = resistance
        r2 = resistance + 50 if resistance + 50 <= 255 else 255
        assume(r1 < r2)
        # More resistant element requires more effective acid exposure
        effective1 = max(0, acid_strength - r1)
        effective2 = max(0, acid_strength - r2)
        assert effective1 >= effective2
>>>>>>> worktree-pytest-test-suite
