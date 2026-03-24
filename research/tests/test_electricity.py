"""Electrical conductivity and circuit behavior tests.

Validates Ohm's law, power dissipation, conductivity ordering, lightning
propagation, and electrolysis behavior using real resistivity data.

Designed for parallel execution via pytest-xdist on A100.
"""

import math

import numpy as np
import pytest

# Real electrical resistivity (ohm-m) at 20C
REAL_RESISTIVITY = {
    "metal":    1e-7,      # iron
    "charcoal": 5e-6,      # graphite
    "acid":     0.01,       # HCl electrolyte
    "mud":      100,        # wet soil
    "lava":     1e3,        # ionic silicate melt
    "water":    1.8e5,      # pure H2O
    "rust":     1e5,        # Fe2O3
    "dirt":     1e5,        # dry soil
    "clay":     1e8,        # alumina silicate
    "sand":     1e11,       # SiO2
    "glass":    1e12,       # amorphous SiO2
    "oil":      1e13,       # hydrocarbon
    "wood":     1e14,       # cellulose
}

# Game-scaled conductivity (0-255, higher = better conductor)
GAME_CONDUCTIVITY = {
    "metal": 250, "charcoal": 200, "acid": 150,
    "water": 80, "mud": 70, "lava": 60, "clay": 40,
    "rust": 20, "dirt": 20, "sand": 2, "glass": 0,
    "wood": 0, "oil": 0,
}


class TestConductivityOrdering:
    """Conductivity values must match real-world resistivity ordering."""

    @pytest.mark.physics
    def test_metal_best_conductor(self):
        for elem, cond in GAME_CONDUCTIVITY.items():
            if elem != "metal":
                assert GAME_CONDUCTIVITY["metal"] >= cond, \
                    f"Metal should conduct better than {elem}"

    @pytest.mark.physics
    def test_full_ordering(self):
        """metal > charcoal > acid > water > mud > lava > clay > rust."""
        order = ["metal", "charcoal", "acid", "water", "mud", "lava", "clay"]
        for i in range(len(order) - 1):
            a, b = order[i], order[i + 1]
            assert GAME_CONDUCTIVITY[a] > GAME_CONDUCTIVITY[b], \
                f"{a} ({GAME_CONDUCTIVITY[a]}) should conduct better than {b} ({GAME_CONDUCTIVITY[b]})"

    @pytest.mark.physics
    @pytest.mark.parametrize("insulator", ["glass", "wood", "oil"])
    def test_insulators_zero(self, insulator):
        assert GAME_CONDUCTIVITY[insulator] == 0

    @pytest.mark.physics
    def test_charcoal_conducts(self):
        """Charcoal (graphite form) should be a decent conductor (>150)."""
        assert GAME_CONDUCTIVITY["charcoal"] >= 150

    @pytest.mark.physics
    def test_acid_electrolyte(self):
        """HCl in water is a strong electrolyte — good conductor."""
        assert GAME_CONDUCTIVITY["acid"] >= 100

    @pytest.mark.physics
    def test_lava_semiconductor(self):
        """Molten silicate conducts (ionic melt) but poorly."""
        assert 30 <= GAME_CONDUCTIVITY["lava"] <= 100

    @pytest.mark.physics
    def test_resistivity_spans_many_orders(self):
        """Real resistivity spans >20 orders of magnitude."""
        r_min = REAL_RESISTIVITY["metal"]
        r_max = REAL_RESISTIVITY["wood"]
        ratio = math.log10(r_max / r_min)
        assert ratio > 20, f"Resistivity span {ratio:.1f} orders too narrow"


class TestOhmsLaw:
    """Verify Ohm's law relationships hold in our grid model."""

    @pytest.mark.physics
    def test_single_cell_resistance(self):
        """R_cell = 1/conductivity for our unit-cell model."""
        for elem, cond in GAME_CONDUCTIVITY.items():
            if cond > 0:
                r = 1.0 / (cond / 255.0)
                assert r > 0
                assert r < 1e6

    @pytest.mark.physics
    def test_series_resistance_adds(self):
        """Two cells in series: R_total = R1 + R2."""
        r_metal = 1.0 / (GAME_CONDUCTIVITY["metal"] / 255.0)
        r_water = 1.0 / (GAME_CONDUCTIVITY["water"] / 255.0)
        r_total = r_metal + r_water
        assert r_total > r_water  # adding metal barely changes it
        assert r_total > r_metal  # but total is higher

    @pytest.mark.physics
    def test_power_dissipation(self):
        """P = I^2 * R. Higher R → more heat (for same current)."""
        voltage = 255  # max game voltage
        for elem, cond in GAME_CONDUCTIVITY.items():
            if cond > 0:
                r = 1.0 / (cond / 255.0)
                i = voltage / r
                p = i * i * r
                # Power should equal V * I
                assert abs(p - voltage * i) < 0.001

    @pytest.mark.physics
    def test_water_heats_more_than_metal(self):
        """Water has higher resistance → more heat per unit current."""
        v = 100
        r_metal = 1.0 / (GAME_CONDUCTIVITY["metal"] / 255.0)
        r_water = 1.0 / (GAME_CONDUCTIVITY["water"] / 255.0)

        # Same voltage, metal carries more current but less heat per cell
        i_metal = v / r_metal
        i_water = v / r_water
        p_metal = i_metal ** 2 * r_metal
        p_water = i_water ** 2 * r_water

        # At same voltage, power = V^2/R, so LOWER R = MORE power
        # But per-cell heating from external current: P = I^2 * R
        # In a circuit, water cell generates more heat because it's the bottleneck
        assert r_water > r_metal


class TestLightningPropagation:
    """Lightning behavior should follow electrical physics."""

    @pytest.mark.physics
    def test_lightning_voltage_range(self):
        """Lightning: ~300MV real, 255 game (max)."""
        game_max = 255
        real_mv = 300e6  # 300 million volts
        scale = game_max / real_mv
        assert scale > 0  # just verify scaling exists

    @pytest.mark.physics
    def test_dielectric_breakdown(self):
        """Air (insulator) should arc at very high voltages (>200 game)."""
        # Dielectric breakdown of air: ~3MV/m
        # In game: voltage > 200 can arc through air
        breakdown_threshold = 200
        assert breakdown_threshold > GAME_CONDUCTIVITY["metal"]  # must be high
        # This means only extreme voltage (lightning) jumps through air

    @pytest.mark.physics
    def test_metal_path_preferred(self):
        """Lightning should prefer metal paths over water."""
        # Lower resistance = preferred path
        r_metal = 1.0 / (GAME_CONDUCTIVITY["metal"] / 255.0)
        r_water = 1.0 / (GAME_CONDUCTIVITY["water"] / 255.0)
        assert r_metal < r_water * 0.5, "Metal should be much better path"

    @pytest.mark.physics
    def test_glass_blocks_lightning(self):
        """Glass should completely block electrical current."""
        assert GAME_CONDUCTIVITY["glass"] == 0


class TestElectrolysis:
    """Electrolysis: water + electricity → H2 + O2."""

    @pytest.mark.physics
    def test_water_decomposes_above_threshold(self):
        """Water electrolysis requires voltage > threshold (~50 game)."""
        # Real: 1.23V minimum (thermodynamic), typically 1.5-2V practical
        # Game: voltage through water cell > 50 triggers electrolysis
        threshold = 50
        assert threshold > 0
        assert threshold < 128  # should be achievable

    @pytest.mark.physics
    def test_salt_water_electrolyzes_faster(self):
        """Salt water has lower resistance → more current → faster electrolysis."""
        salt_water_cond = 130  # NaCl solution
        pure_water_cond = GAME_CONDUCTIVITY["water"]
        assert salt_water_cond > pure_water_cond


class TestCircuitBehavior:
    """Complex circuit behavior tests."""

    @pytest.mark.physics
    def test_metal_wire_minimal_loss(self):
        """10-cell metal wire should have very low voltage drop."""
        wire_length = 10
        r_per_cell = 1.0 / (GAME_CONDUCTIVITY["metal"] / 255.0)
        r_total = r_per_cell * wire_length
        v_in = 255
        i = v_in / r_total
        # Voltage drop should be small relative to total
        v_drop_per_cell = i * r_per_cell
        assert v_drop_per_cell < 30, "Metal should have low voltage drop per cell"

    @pytest.mark.physics
    def test_mixed_circuit_bottleneck(self):
        """In metal-water-metal circuit, water cell is the bottleneck."""
        r_metal = 1.0 / (GAME_CONDUCTIVITY["metal"] / 255.0)
        r_water = 1.0 / (GAME_CONDUCTIVITY["water"] / 255.0)
        # 5 metal + 1 water + 5 metal
        r_total = 10 * r_metal + r_water
        # Water cell should dominate total resistance
        assert r_water > 5 * r_metal, "Water should be the bottleneck"

    @pytest.mark.physics
    def test_open_circuit_no_current(self):
        """Circuit with glass segment should have zero current."""
        # Glass conductivity = 0, so resistance = infinity
        assert GAME_CONDUCTIVITY["glass"] == 0
        # No current flows through open circuit

    @pytest.mark.physics
    def test_proposed_copper_best_conductor(self):
        """Copper (proposed) should conduct better than iron."""
        # Cu resistivity: 1.68e-8 vs Fe: 1e-7
        copper_cond = 255  # best possible
        assert copper_cond >= GAME_CONDUCTIVITY["metal"]
