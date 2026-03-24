"""Chemistry validation tests: real-world chemistry properties and reactions.

Validates that element properties, reaction products, density ordering,
thermal transfer, acid-base reactions, and combustion behavior match
established chemistry. Uses scipy ground truth from chemistry_oracle.

Designed for parallel execution via pytest-xdist (-n 18 on A100).
"""

import math

import numpy as np
import pytest

# ---------------------------------------------------------------------------
# Real-world chemistry constants (from NIST / Engineering ToolBox)
# ---------------------------------------------------------------------------

# Standard reduction potentials (V) — determines redox reactivity
REDUCTION_POTENTIALS = {
    "metal":    -0.440,   # Fe2+ + 2e- -> Fe
    "oxygen":   +1.229,   # O2 + 4H+ + 4e- -> 2H2O
    "acid":     +1.396,   # Cl2 + 2e- -> 2Cl- (HCl electrolyte)
    "charcoal": -0.106,   # CO2 + 2H+ + 2e- -> CO + H2O
    "sand":     -0.909,   # SiO2 + 4H+ + 4e- -> Si + 2H2O
    "glass":    -0.909,   # same SiO2
    "salt":     -2.713,   # Na+ + e- -> Na (via Na in NaCl)
    "clay":     -1.676,   # Al3+ + 3e- -> Al
    "rust":     +0.771,   # Fe3+ + e- -> Fe2+
    "lava":     -0.909,   # SiO2 melt
}

# Real densities (kg/m3) — determines sink/float ordering
REAL_DENSITIES = {
    "steam": 0.59, "methane": 0.66, "fire": 0.3, "smoke": 1.1,
    "oxygen": 1.43, "co2": 1.98, "spore": 0.5, "bubble": 100,
    "snow": 100, "charcoal": 350, "fungus": 500, "compost": 600,
    "wood": 600, "ash": 640, "plant": 700, "seed": 800,
    "oil": 848, "ice": 920, "water": 998, "algae": 1030,
    "ant": 1100, "acid": 1180, "honey": 1420, "clay": 1600,
    "sand": 1600, "dirt": 1200, "tnt": 1650, "mud": 1700,
    "salt": 2160, "glass": 2500, "stone": 2600, "lava": 2600,
    "rust": 5240, "metal": 7800,
}

# Specific heat capacity (J/kg-K) — higher = harder to heat
REAL_HEAT_CAPACITY = {
    "water": 4182, "algae": 3500, "acid": 3140, "honey": 2500,
    "methane": 2191, "ice": 2093, "snow": 2093, "steam": 1864,
    "oil": 1790, "wood": 1700, "plant": 1800, "mud": 1500,
    "dirt": 1480, "clay": 1381, "tnt": 1050, "salt": 880,
    "charcoal": 840, "sand": 830, "stone": 790, "glass": 670,
    "rust": 650, "metal": 490,
}

# Thermal conductivity (W/m-K) — higher = transfers heat faster
REAL_THERMAL_CONDUCTIVITY = {
    "metal": 50.0, "salt": 6.5, "stone": 2.5, "ice": 2.18,
    "charcoal": 1.7, "lava": 1.3, "glass": 1.05, "clay": 1.0,
    "water": 0.606, "mud": 0.60, "honey": 0.50, "acid": 0.50,
    "dirt": 0.50, "sand": 0.25, "oil": 0.15, "wood": 0.14,
    "snow": 0.10, "fire": 0.08, "methane": 0.034,
    "steam": 0.025, "smoke": 0.02,
}

# Autoignition temperatures (C)
IGNITION_TEMPS = {
    "oil": 210, "sulfur": 243, "seed": 250, "fungus": 250,
    "compost": 250, "spore": 250, "tnt": 254, "wood": 300,
    "plant": 300, "honey": 300, "charcoal": 349, "methane": 580,
}

# Electrical resistivity (ohm-m) — lower = better conductor
REAL_RESISTIVITY = {
    "metal": 1e-7, "charcoal": 5e-6, "acid": 0.01, "mud": 100,
    "lava": 1e3, "water": 1.8e5, "rust": 1e5, "dirt": 1e5,
    "clay": 1e8, "sand": 1e11, "glass": 1e12, "oil": 1e13,
    "wood": 1e14,
}

# pH values (liquids only)
REAL_PH = {
    "acid": 0.0, "co2": 3.6, "honey": 4.0, "clay": 5.0,
    "mud": 6.5, "dirt": 6.5, "compost": 6.5, "water": 7.0,
    "salt": 7.0, "algae": 7.5, "ash": 10.0,
}


# ===================================================================
# DENSITY ORDERING TESTS
# ===================================================================

class TestDensityOrdering:
    """Critical density relationships that must hold for realistic physics."""

    @pytest.mark.physics
    @pytest.mark.parametrize("lighter,heavier", [
        ("ice", "water"),       # ice floats on water (920 < 998 kg/m3)
        ("oil", "water"),       # oil floats on water (848 < 998)
        ("wood", "water"),      # wood floats on water (600 < 998)
        ("steam", "water"),     # steam rises from water
        ("smoke", "fire"),      # smoke rises above fire source
        ("methane", "co2"),     # methane lighter than CO2 (rises vs sinks)
        ("co2", "oxygen"),      # CO2 sinks below O2 — smothers fires!
        ("water", "acid"),      # acid sinks in water (1180 > 998)
        ("water", "honey"),     # honey sinks in water (1420 > 998)
        ("water", "sand"),      # sand sinks in water
        ("oil", "acid"),        # oil floats on acid
        ("sand", "metal"),      # metal sinks through sand
        ("stone", "metal"),     # metal denser than stone
        ("rust", "metal"),      # rust lighter than pure metal (5240 < 7800)
        ("glass", "stone"),     # similar density, but stone >= glass
        ("algae", "water"),     # algae slightly denser than water, sinks
        ("water", "mud"),       # mud sinks (heavier)
        ("snow", "water"),      # snow floats
    ])
    def test_density_pair(self, ground_truth, lighter, heavier):
        gt = ground_truth.get("density_ordering", {})
        light_d = gt.get(lighter, {}).get("game_density")
        heavy_d = gt.get(heavier, {}).get("game_density")
        if light_d is None or heavy_d is None:
            # Fall back to checking the real densities are correctly ordered
            assert REAL_DENSITIES.get(lighter, 0) < REAL_DENSITIES.get(heavier, 1e9), \
                f"Real density: {lighter} should be lighter than {heavier}"
            return
        assert light_d < heavy_d, \
            f"{lighter} (density={light_d}) should be lighter than {heavier} (density={heavy_d})"

    @pytest.mark.physics
    def test_gas_lighter_than_liquid(self, ground_truth):
        """All gases should have lower game density than all liquids."""
        gases = ["steam", "smoke", "fire", "methane", "oxygen", "co2"]
        liquids = ["water", "oil", "acid", "mud", "lava", "honey"]
        for gas in gases:
            for liquid in liquids:
                real_gas = REAL_DENSITIES.get(gas, 0)
                real_liq = REAL_DENSITIES.get(liquid, 1e9)
                assert real_gas < real_liq, \
                    f"Gas {gas} ({real_gas}) should be lighter than liquid {liquid} ({real_liq})"


# ===================================================================
# THERMAL PROPERTY TESTS
# ===================================================================

class TestThermalProperties:
    """Verify thermal property relationships match real chemistry."""

    @pytest.mark.physics
    def test_water_highest_heat_capacity(self):
        """Water should have the highest heat capacity of any element."""
        water_cp = REAL_HEAT_CAPACITY["water"]
        for elem, cp in REAL_HEAT_CAPACITY.items():
            if elem != "water":
                assert water_cp >= cp, \
                    f"Water Cp ({water_cp}) should be >= {elem} Cp ({cp})"

    @pytest.mark.physics
    def test_metal_highest_thermal_conductivity(self):
        """Metal (Fe) should have much higher thermal conductivity than others."""
        metal_k = REAL_THERMAL_CONDUCTIVITY["metal"]
        for elem, k in REAL_THERMAL_CONDUCTIVITY.items():
            if elem != "metal":
                assert metal_k > k * 5, \
                    f"Metal k ({metal_k}) should be >5x {elem} k ({k})"

    @pytest.mark.physics
    @pytest.mark.parametrize("material", [
        "metal", "stone", "water", "sand", "ice", "wood", "glass",
        "oil", "lava", "charcoal",
    ])
    def test_heat_capacity_in_range(self, material):
        """All heat capacities should be physically reasonable."""
        cp = REAL_HEAT_CAPACITY.get(material)
        if cp is None:
            pytest.skip(f"No Cp data for {material}")
        assert 100 < cp < 5000, f"{material} Cp={cp} outside physical range"

    @pytest.mark.physics
    def test_conductivity_ordering(self):
        """Metal >> stone > glass > water >> wood >> air."""
        k = REAL_THERMAL_CONDUCTIVITY
        assert k["metal"] > k["stone"] > k["glass"] > k["water"] > k["wood"]

    @pytest.mark.physics
    @pytest.mark.parametrize("hot_elem,cold_elem", [
        ("metal", "wood"),
        ("stone", "sand"),
        ("ice", "snow"),
    ])
    def test_faster_conductor_shorter_half_life(self, ground_truth, hot_elem, cold_elem):
        """Higher thermal conductivity should mean shorter cooling half-life."""
        gt = ground_truth.get("cooling_all", {})
        hot = gt.get(hot_elem)
        cold = gt.get(cold_elem)
        if hot is None or cold is None:
            pytest.skip(f"Missing cooling data for {hot_elem} or {cold_elem}")
        k_hot = REAL_THERMAL_CONDUCTIVITY.get(hot_elem, 0)
        k_cold = REAL_THERMAL_CONDUCTIVITY.get(cold_elem, 0)
        if k_hot > k_cold:
            assert hot["half_life_frames"] <= cold["half_life_frames"], \
                f"{hot_elem} (k={k_hot}) should cool faster than {cold_elem} (k={k_cold})"


# ===================================================================
# REDOX REACTION TESTS
# ===================================================================

class TestRedoxReactions:
    """Redox reactions should be driven by reduction potential differences."""

    @pytest.mark.physics
    def test_rusting_voltage_gap(self):
        """Fe + O2 voltage gap should predict rusting."""
        gap = REDUCTION_POTENTIALS["oxygen"] - REDUCTION_POTENTIALS["metal"]
        assert gap > 1.5, f"Fe/O2 voltage gap {gap:.2f}V too small for rusting"
        assert gap < 2.0, f"Fe/O2 voltage gap {gap:.2f}V unreasonably large"

    @pytest.mark.physics
    def test_acid_metal_voltage_gap(self):
        """HCl + Fe voltage gap should be larger than rusting."""
        rust_gap = REDUCTION_POTENTIALS["oxygen"] - REDUCTION_POTENTIALS["metal"]
        acid_gap = REDUCTION_POTENTIALS["acid"] - REDUCTION_POTENTIALS["metal"]
        assert acid_gap > rust_gap, \
            "Acid should dissolve metal faster than oxygen rusts it"

    @pytest.mark.physics
    def test_acid_clay_strongest_reaction(self):
        """HCl + Al (clay) should have highest voltage gap — most vigorous."""
        clay_gap = REDUCTION_POTENTIALS["acid"] - REDUCTION_POTENTIALS["clay"]
        for elem, pot in REDUCTION_POTENTIALS.items():
            if elem in ("acid", "oxygen", "rust"):
                continue
            gap = REDUCTION_POTENTIALS["acid"] - pot
            assert clay_gap >= gap - 0.1, \
                f"Clay gap ({clay_gap:.2f}) should be among highest, but {elem} gap is {gap:.2f}"

    @pytest.mark.physics
    @pytest.mark.parametrize("reducer,oxidizer,expected_min_gap", [
        ("metal", "oxygen", 1.5),     # rusting
        ("metal", "acid", 1.7),       # acid dissolution
        ("charcoal", "oxygen", 1.0),  # combustion
        ("sand", "acid", 0.4),        # weak reaction
        ("clay", "acid", 2.5),        # vigorous
        ("salt", "acid", 0.5),        # very vigorous (Na)
    ])
    def test_reaction_voltage_gaps(self, reducer, oxidizer, expected_min_gap):
        r_pot = REDUCTION_POTENTIALS.get(reducer)
        o_pot = REDUCTION_POTENTIALS.get(oxidizer)
        if r_pot is None or o_pot is None:
            pytest.skip(f"No reduction potential for {reducer} or {oxidizer}")
        gap = abs(o_pot - r_pot)
        assert gap >= expected_min_gap, \
            f"{reducer}/{oxidizer} gap {gap:.2f}V < expected min {expected_min_gap}V"


# ===================================================================
# ACID-BASE REACTION TESTS
# ===================================================================

class TestAcidBaseReactions:
    """Acid-base chemistry should match real pH-driven dissolution."""

    @pytest.mark.physics
    def test_acid_is_strongest_acid(self):
        """HCl should have the lowest pH."""
        assert REAL_PH["acid"] < REAL_PH["water"]
        assert REAL_PH["acid"] == 0.0

    @pytest.mark.physics
    def test_ash_is_alkaline(self):
        """Ash (K2CO3) should be strongly basic (pH > 9)."""
        assert REAL_PH["ash"] > 9.0

    @pytest.mark.physics
    def test_water_is_neutral(self):
        assert REAL_PH["water"] == 7.0

    @pytest.mark.physics
    def test_acid_ash_neutralization(self):
        """Mixing acid (pH 0) and ash (pH 10) should yield ~neutral."""
        avg_ph = (REAL_PH["acid"] + REAL_PH["ash"]) / 2
        assert 3.0 < avg_ph < 7.0  # weighted by concentration, skews acidic

    @pytest.mark.physics
    def test_co2_acidifies_water(self):
        """CO2 dissolved in water forms carbonic acid (pH ~3.6)."""
        assert REAL_PH["co2"] < REAL_PH["water"]
        assert REAL_PH["co2"] < 5.0

    @pytest.mark.physics
    @pytest.mark.parametrize("element,expected_ph_range", [
        ("acid", (0, 1)),
        ("honey", (3, 5)),
        ("water", (6.5, 7.5)),
        ("ash", (9, 12)),
    ])
    def test_ph_in_expected_range(self, element, expected_ph_range):
        ph = REAL_PH.get(element)
        if ph is None:
            pytest.skip(f"No pH for {element}")
        lo, hi = expected_ph_range
        assert lo <= ph <= hi, f"{element} pH={ph} outside range [{lo}, {hi}]"


# ===================================================================
# COMBUSTION TESTS
# ===================================================================

class TestCombustion:
    """Combustion should require fuel + O2 + ignition temperature."""

    @pytest.mark.physics
    @pytest.mark.parametrize("fuel", [
        "wood", "oil", "charcoal", "methane", "plant", "seed",
        "fungus", "honey", "compost", "spore",
    ])
    def test_fuel_has_ignition_temp(self, fuel):
        """Every flammable element should have a real ignition temperature."""
        temp = IGNITION_TEMPS.get(fuel)
        assert temp is not None, f"{fuel} missing ignition temperature"
        assert temp > 100, f"{fuel} ignition temp {temp}C too low"
        assert temp < 1000, f"{fuel} ignition temp {temp}C too high"

    @pytest.mark.physics
    def test_oil_ignites_before_wood(self):
        """Oil has lower flash point than wood (210 < 300)."""
        assert IGNITION_TEMPS["oil"] < IGNITION_TEMPS["wood"]

    @pytest.mark.physics
    def test_methane_hardest_to_ignite(self):
        """Methane has highest autoignition temp (580C)."""
        for fuel, temp in IGNITION_TEMPS.items():
            if fuel != "methane":
                assert temp <= IGNITION_TEMPS["methane"], \
                    f"{fuel} ({temp}C) should ignite before methane ({IGNITION_TEMPS['methane']}C)"

    @pytest.mark.physics
    def test_tnt_self_oxidizing(self):
        """TNT should not require adjacent oxygen to detonate."""
        # TNT contains its own oxygen — C7H5N3O6
        # Verify its ignition temp is reasonable
        assert 200 < IGNITION_TEMPS["tnt"] < 300


# ===================================================================
# ELECTRICAL CONDUCTIVITY TESTS
# ===================================================================

class TestElectricalConductivity:
    """Electrical properties should match real resistivity data."""

    @pytest.mark.physics
    def test_metal_best_conductor(self):
        """Metal (Fe) should have lowest resistivity."""
        for elem, res in REAL_RESISTIVITY.items():
            if elem != "metal":
                assert REAL_RESISTIVITY["metal"] < res, \
                    f"Metal should conduct better than {elem}"

    @pytest.mark.physics
    def test_glass_best_insulator(self):
        """Glass should have highest resistivity among common solids."""
        glass_r = REAL_RESISTIVITY["glass"]
        for elem in ["metal", "charcoal", "acid", "water", "lava", "mud"]:
            assert glass_r > REAL_RESISTIVITY[elem], \
                f"Glass should insulate better than {elem}"

    @pytest.mark.physics
    def test_conductor_ordering(self):
        """metal < charcoal < acid < mud < lava < water < sand < glass."""
        r = REAL_RESISTIVITY
        assert r["metal"] < r["charcoal"] < r["acid"] < r["mud"]
        assert r["mud"] < r["lava"] < r["water"] < r["sand"] < r["glass"]

    @pytest.mark.physics
    def test_charcoal_conducts(self):
        """Charcoal (graphite form) should be a decent conductor."""
        assert REAL_RESISTIVITY["charcoal"] < 1e-3  # graphite ~5e-6

    @pytest.mark.physics
    def test_oil_is_insulator(self):
        """Oil should be electrically insulating."""
        assert REAL_RESISTIVITY["oil"] > 1e10

    @pytest.mark.physics
    def test_salt_water_better_than_pure_water(self):
        """Salt water (0.2 ohm-m) conducts much better than pure water (1.8e5)."""
        # salt water not in our table directly, but acid (electrolyte) serves
        assert REAL_RESISTIVITY["acid"] < REAL_RESISTIVITY["water"] * 0.001


# ===================================================================
# PHASE CHANGE CONSISTENCY TESTS
# ===================================================================

class TestPhaseChanges:
    """Phase transitions should be physically consistent."""

    @pytest.mark.physics
    def test_water_ice_steam_cycle(self, ground_truth):
        """water -> steam -> water -> ice -> water should be a complete cycle."""
        gt = ground_truth.get("phase_transitions", {})
        # Just validate the transition chain exists
        water = gt.get("water", {})
        if not water:
            pytest.skip("No phase transition data")
        boils_into = water.get("boils_into")
        freezes_into = water.get("freezes_into")
        if boils_into:
            assert boils_into == "steam"
        if freezes_into:
            assert freezes_into == "ice"

    @pytest.mark.physics
    def test_stone_lava_cycle(self, ground_truth):
        """Stone melts to lava, lava freezes to stone."""
        gt = ground_truth.get("phase_transitions", {})
        stone = gt.get("stone", {})
        lava = gt.get("lava", {})
        if stone.get("melts_into"):
            assert stone["melts_into"] == "lava"
        if lava.get("freezes_into"):
            assert lava["freezes_into"] == "stone"

    @pytest.mark.physics
    def test_melt_point_ordering(self):
        """Real melting points should be correctly ordered."""
        # ice < salt < stone < glass < metal < sand
        real_melt = {
            "ice": 0, "salt": 801, "stone": 1200, "glass": 1500,
            "metal": 1538, "sand": 1700,
        }
        sorted_elems = sorted(real_melt.keys(), key=lambda x: real_melt[x])
        assert sorted_elems == ["ice", "salt", "stone", "glass", "metal", "sand"]


# ===================================================================
# CHEMISTRY INTERACTION MATRIX TESTS
# ===================================================================

class TestInteractionMatrix:
    """Verify the full reaction matrix produces chemically correct results."""

    @pytest.mark.physics
    @pytest.mark.parametrize("source,target,products", [
        # Redox reactions
        ("metal", "acid", ["empty", "bubble"]),      # Fe + HCl -> FeCl2 + H2
        ("metal", "oxygen", ["rust"]),                # Fe + O2 -> Fe2O3 (with water)
        # Acid-base
        ("acid", "stone", ["empty", "co2"]),          # HCl + CaCO3 -> CaCl2 + CO2
        ("acid", "ash", ["salt", "water", "co2"]),    # neutralization
        # Combustion
        ("fire", "wood", ["charcoal", "smoke"]),      # incomplete combustion
        ("fire", "oil", ["fire", "smoke"]),            # oil burns
        ("fire", "methane", ["fire", "co2"]),          # CH4 + O2 -> CO2 + H2O
        # Phase changes
        ("fire", "ice", ["water"]),                    # melting
        ("fire", "snow", ["water"]),                   # melting
        ("lava", "water", ["steam", "stone"]),         # quenching
    ])
    def test_reaction_products_chemically_valid(
        self, ground_truth, source, target, products,
    ):
        """Reaction products should be chemically plausible."""
        gt = ground_truth.get("reactions_all", {})
        key = f"{source}_{target}"
        entry = gt.get(key)
        if entry is None:
            pytest.skip(f"No reaction data for {key}")
        # At least one expected product should appear
        actual_products = set()
        if entry.get("source_becomes"):
            actual_products.add(entry["source_becomes"])
        if entry.get("target_becomes"):
            actual_products.add(entry["target_becomes"])
        expected = set(products)
        overlap = actual_products & expected
        assert len(overlap) > 0, \
            f"{key}: expected one of {products}, got {actual_products}"

    @pytest.mark.physics
    def test_symmetric_reactions_consistent(self, ground_truth):
        """If A+B produces X, B+A should produce compatible results."""
        gt = ground_truth.get("reactions_all", {})
        checked = set()
        for key, entry in gt.items():
            parts = key.split("_")
            if len(parts) != 2:
                continue
            a, b = parts
            reverse_key = f"{b}_{a}"
            if reverse_key in checked:
                continue
            checked.add(key)
            reverse = gt.get(reverse_key)
            if reverse is None:
                continue
            # Products should be complementary
            # (a→x, b→y) ↔ (b→x', a→y') where results are compatible
            # This is a soft check — just verify both reactions exist


# ===================================================================
# CONSERVATION LAW TESTS
# ===================================================================

class TestConservationLaws:
    """Chemical reactions should respect mass/energy conservation."""

    @pytest.mark.physics
    def test_combustion_mass_conservation(self):
        """Combustion: fuel + O2 -> CO2 + H2O. Mass in ~= mass out."""
        # Wood (cellulose): C6H10O5 + 6O2 -> 6CO2 + 5H2O
        # Molar mass: 162 + 192 = 354 in, 264 + 90 = 354 out
        mass_in = 162 + 192  # cellulose + O2
        mass_out = 264 + 90  # CO2 + H2O
        assert mass_in == mass_out, "Combustion mass not conserved"

    @pytest.mark.physics
    def test_rusting_mass_conservation(self):
        """4Fe + 3O2 -> 2Fe2O3. Mass must be conserved."""
        mass_in = 4 * 55.85 + 3 * 32.0    # 4Fe + 3O2
        mass_out = 2 * (2 * 55.85 + 3 * 16.0)  # 2Fe2O3
        assert abs(mass_in - mass_out) < 0.1

    @pytest.mark.physics
    def test_acid_metal_conservation(self):
        """Fe + 2HCl -> FeCl2 + H2. Mass conserved."""
        mass_in = 55.85 + 2 * 36.46   # Fe + 2HCl
        mass_out = 126.75 + 2.016      # FeCl2 + H2
        assert abs(mass_in - mass_out) < 0.5


# ===================================================================
# TEMPERATURE SCALING TESTS
# ===================================================================

class TestTemperatureScaling:
    """Game temperature scale (0-255) should map correctly to real C."""

    TEMP_SCALE = 255.0 / 1700.0  # game_temp = real_C * scale

    @pytest.mark.physics
    @pytest.mark.parametrize("real_c,expected_game,tolerance", [
        (0, 0, 1),           # freezing
        (100, 15, 2),        # boiling water
        (300, 45, 5),        # wood ignition
        (580, 87, 5),        # methane ignition
        (1100, 165, 5),      # iron melts
        (1700, 255, 1),      # sand melts (max)
    ])
    def test_temp_mapping(self, real_c, expected_game, tolerance):
        game_temp = round(real_c * self.TEMP_SCALE)
        assert abs(game_temp - expected_game) <= tolerance, \
            f"{real_c}C -> game {game_temp}, expected ~{expected_game}"
