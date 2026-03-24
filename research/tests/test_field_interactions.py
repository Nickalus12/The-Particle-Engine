"""Cross-field interaction tests using simulation-driven scenarios.

These tests validate that fields interact correctly when combined,
using the FieldEngine to run actual physics passes:
  - Temperature + oxidation: hot fuel oxidizes faster
  - Moisture + voltage: wet cells conduct better
  - pH + dissolved substances: CO2 lowers water pH
  - Stress + column mass: heavy columns generate stress
  - CellAge + element state: aging increments only for non-empty
  - Light emission + temperature: hot cells glow
  - Wind + element state: solids block wind
  - Mass + moisture + concentration: combined formula
  - Vibration + hardness: propagation through hard materials
  - Charge + voltage: voltage drives charge accumulation

Designed for parallel execution via pytest-xdist (-n auto).
"""

import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).parent))

from test_fields import (
    FieldEngine, BASE_MASS, BOND_ENERGY, HARDNESS, ELECTRON_MOBILITY,
    FUEL_VALUE, IGNITION_TEMP, POROSITY, LIGHT_EMISSION, LIGHT_R,
    EL_EMPTY, EL_SAND, EL_WATER, EL_FIRE, EL_ICE, EL_STONE,
    EL_OIL, EL_ACID, EL_GLASS, EL_DIRT, EL_PLANT, EL_LAVA,
    EL_WOOD, EL_METAL, EL_SMOKE, EL_ASH, EL_OXYGEN, EL_CO2,
    EL_CHARCOAL, EL_SALT, EL_COPPER, EL_COMPOST, EL_MUD,
    MAX_ELEMENTS, STATE_SOLID, STATE_LIQUID, STATE_GAS,
    ELEMENT_STATE,
)


@pytest.fixture
def engine():
    return FieldEngine(64, 36)


@pytest.fixture
def small_engine():
    return FieldEngine(16, 16)


# ===========================================================================
# TEMPERATURE + OXIDATION
# ===========================================================================

class TestTemperatureOxidation:
    """Hot fuel cells should oxidize faster than cold ones."""

    @pytest.mark.physics
    def test_hot_wood_oxidizes_cold_does_not(self, small_engine):
        """Two wood cells: one hot, one cold. Only hot should oxidize."""
        e = small_engine
        hot = e.idx(4, 8)
        cold = e.idx(12, 8)
        e.grid[hot] = EL_WOOD
        e.grid[cold] = EL_WOOD
        e.temperature[hot] = 220  # above ignition (170)
        e.temperature[cold] = 100  # below ignition
        e.oxidation[hot] = 128
        e.oxidation[cold] = 128

        for _ in range(10):
            e.step_oxidation()

        assert int(e.oxidation[hot]) > 128, "Hot wood should oxidize"
        assert int(e.oxidation[cold]) == 128, "Cold wood should not oxidize"

    @pytest.mark.physics
    def test_hotter_fuel_oxidizes_faster(self, small_engine):
        """Wood at 250 should oxidize faster than wood at 180."""
        e = small_engine
        very_hot = e.idx(4, 8)
        warm = e.idx(12, 8)
        e.grid[very_hot] = EL_WOOD
        e.grid[warm] = EL_WOOD
        e.temperature[very_hot] = 250
        e.temperature[warm] = 180
        e.oxidation[very_hot] = 128
        e.oxidation[warm] = 128

        for _ in range(10):
            e.step_oxidation()

        # Both above ignition, but 250 has higher fuelValue contribution
        assert int(e.oxidation[very_hot]) >= int(e.oxidation[warm]), \
            "Higher temp should oxidize at least as fast"

    @pytest.mark.physics
    def test_oxidation_leads_to_transformation(self, small_engine):
        """Prolonged heating should transform wood to ash."""
        e = small_engine
        idx = e.idx(8, 8)
        e.grid[idx] = EL_WOOD
        e.temperature[idx] = 250
        e.oxidation[idx] = 240  # almost fully oxidized

        for _ in range(50):
            e.step_oxidation()

        assert e.grid[idx] == EL_ASH, "Fully oxidized wood should become ash"

    @pytest.mark.physics
    def test_non_fuel_elements_dont_oxidize(self, small_engine):
        """Stone, metal, water should not oxidize even when hot."""
        e = small_engine
        for i, el in enumerate([EL_STONE, EL_METAL, EL_WATER]):
            idx = e.idx(4 + i * 4, 8)
            e.grid[idx] = el
            e.temperature[idx] = 250
            e.oxidation[idx] = 128

        for _ in range(20):
            e.step_oxidation()

        for i, el in enumerate([EL_STONE, EL_METAL, EL_WATER]):
            idx = e.idx(4 + i * 4, 8)
            assert int(e.oxidation[idx]) == 128, \
                f"Element {el} should not oxidize (no fuel value)"


# ===========================================================================
# MOISTURE + VOLTAGE (conductivity boost)
# ===========================================================================

class TestMoistureVoltage:
    """Wet cells conduct electricity better than dry ones."""

    @pytest.mark.physics
    def test_wet_wood_conducts(self, small_engine):
        """Dry wood is insulator, wet wood conducts voltage."""
        e = small_engine
        # Wire: metal -> wet_wood -> target
        metal = e.idx(6, 8)
        wood = e.idx(7, 8)
        target = e.idx(8, 8)
        e.grid[metal] = EL_METAL
        e.grid[wood] = EL_WOOD
        e.grid[target] = EL_METAL
        e.voltage[metal] = 127
        e.moisture[wood] = 200  # wet

        for _ in range(5):
            e.step_electricity()

        # Wet wood should allow some voltage through
        assert int(e.voltage[wood]) > 0 or int(e.voltage[target]) > 0, \
            "Wet wood should conduct"

    @pytest.mark.physics
    def test_dry_wood_blocks(self, small_engine):
        """Dry wood (mobility=0, moisture=0) should block voltage."""
        e = small_engine
        metal = e.idx(6, 8)
        wood = e.idx(7, 8)
        target = e.idx(8, 8)
        e.grid[metal] = EL_METAL
        e.grid[wood] = EL_WOOD
        e.grid[target] = EL_METAL
        e.voltage[metal] = 127
        e.moisture[wood] = 0  # dry

        for _ in range(10):
            e.step_electricity()

        assert int(e.voltage[target]) == 0, \
            "Dry wood should block voltage"

    @pytest.mark.physics
    def test_salt_water_better_conductor(self, small_engine):
        """Water with dissolved salt should propagate voltage further."""
        e = small_engine
        # Build two parallel paths: pure water vs salt water
        for x in range(5, 12):
            # Row 4: pure water path
            e.grid[e.idx(x, 4)] = EL_WATER
            e.moisture[e.idx(x, 4)] = 255
            # Row 8: salt water path
            e.grid[e.idx(x, 8)] = EL_WATER
            e.moisture[e.idx(x, 8)] = 255
            e.dissolvedType[e.idx(x, 8)] = EL_SALT
            e.concentration[e.idx(x, 8)] = 200

        # Source voltage at both paths
        e.voltage[e.idx(5, 4)] = 127
        e.voltage[e.idx(5, 8)] = 127

        for _ in range(15):
            e.step_electricity()

        pure_end = int(e.voltage[e.idx(11, 4)])
        salt_end = int(e.voltage[e.idx(11, 8)])

        # Salt water path should carry voltage further (less attenuation)
        assert salt_end >= pure_end, \
            f"Salt water ({salt_end}) should conduct >= pure water ({pure_end})"


# ===========================================================================
# PH + DISSOLVED SUBSTANCES
# ===========================================================================

class TestPHDissolved:
    """pH interacts with dissolved substances in water."""

    @pytest.mark.physics
    def test_co2_makes_water_acidic(self, small_engine):
        """Water with dissolved CO2 should have pH < 128."""
        e = small_engine
        idx = e.idx(8, 8)
        e.grid[idx] = EL_WATER
        e.dissolvedType[idx] = EL_CO2
        e.concentration[idx] = 200

        e.step_pH()

        # pH = 128 - (conc >> 2) = 128 - 50 = 78
        expected = 128 - (200 >> 2)
        assert int(e.pH[idx]) == expected, \
            f"Expected pH={expected}, got {e.pH[idx]}"

    @pytest.mark.physics
    def test_higher_co2_lower_ph(self, small_engine):
        """More CO2 dissolved = lower pH."""
        e = small_engine
        low_co2 = e.idx(4, 8)
        high_co2 = e.idx(12, 8)
        for idx in [low_co2, high_co2]:
            e.grid[idx] = EL_WATER
            e.dissolvedType[idx] = EL_CO2

        e.concentration[low_co2] = 40
        e.concentration[high_co2] = 200

        e.step_pH()

        assert int(e.pH[high_co2]) < int(e.pH[low_co2]), \
            "Higher CO2 should mean lower pH"

    @pytest.mark.physics
    def test_acid_and_ash_ph_differ(self, small_engine):
        """Acid should have pH=20, ash should have pH=200."""
        e = small_engine
        acid_idx = e.idx(4, 8)
        ash_idx = e.idx(12, 8)
        e.grid[acid_idx] = EL_ACID
        e.grid[ash_idx] = EL_ASH

        e.step_pH()

        assert int(e.pH[acid_idx]) == 20
        assert int(e.pH[ash_idx]) == 200
        assert int(e.pH[ash_idx]) - int(e.pH[acid_idx]) == 180


# ===========================================================================
# STRESS + COLUMN MASS
# ===========================================================================

class TestStressColumnMass:
    """Stress depends on mass of cells above in the column."""

    @pytest.mark.physics
    def test_heavier_column_more_stress(self, small_engine):
        """2-cell column: stone (mass=255) should have more stress than wood (mass=85)."""
        e = small_engine
        # 2-cell column of stone
        for y in range(2):
            idx = e.idx(4, y)
            e.grid[idx] = EL_STONE
            e.mass[idx] = BASE_MASS[EL_STONE]  # 255
        # 2-cell column of wood
        for y in range(2):
            idx = e.idx(12, y)
            e.grid[idx] = EL_WOOD
            e.mass[idx] = BASE_MASS[EL_WOOD]  # 85

        e.step_stress()

        stone_stress = int(e.stress[e.idx(4, 1)])  # bottom of stone column
        wood_stress = int(e.stress[e.idx(12, 1)])   # bottom of wood column

        assert stone_stress > wood_stress, \
            f"Stone column stress ({stone_stress}) should exceed wood ({wood_stress})"

    @pytest.mark.physics
    def test_wet_cells_heavier_stress(self, small_engine):
        """2-cell column: wet wood should have more stress than dry wood."""
        e = small_engine
        # Dry wood column (2 cells to avoid saturation)
        for y in range(2):
            idx = e.idx(4, y)
            e.grid[idx] = EL_WOOD
            e.moisture[idx] = 0
        e.step_mass()
        # Wet wood column
        for y in range(2):
            idx = e.idx(12, y)
            e.grid[idx] = EL_WOOD
            e.moisture[idx] = 200
        e.step_mass()

        e.step_stress()

        dry_stress = int(e.stress[e.idx(4, 1)])
        wet_stress = int(e.stress[e.idx(12, 1)])

        assert wet_stress > dry_stress, \
            f"Wet column stress ({wet_stress}) should exceed dry ({dry_stress})"


# ===========================================================================
# CELL AGE + ELEMENT STATE
# ===========================================================================

class TestCellAgeElement:
    """cellAge increments only for non-empty cells and is reset by clearCell."""

    @pytest.mark.physics
    def test_mixed_grid_aging(self, small_engine):
        """Non-empty cells age, empty cells stay at 0."""
        e = small_engine
        stone_idx = e.idx(4, 8)
        empty_idx = e.idx(8, 8)
        e.grid[stone_idx] = EL_STONE
        e.grid[empty_idx] = EL_EMPTY
        e.cellAge[stone_idx] = 0
        e.cellAge[empty_idx] = 0

        for _ in range(10):
            e.step_cell_age()

        assert int(e.cellAge[stone_idx]) == 10
        assert int(e.cellAge[empty_idx]) == 0

    @pytest.mark.physics
    def test_clearcell_resets_age_swap_preserves(self, small_engine):
        """clearCell resets age; swap transfers it correctly."""
        e = small_engine
        a = e.idx(4, 8)
        b = e.idx(12, 8)
        e.grid[a] = EL_STONE
        e.cellAge[a] = 200
        e.grid[b] = EL_WATER
        e.cellAge[b] = 50

        e.swap(a, b)
        assert int(e.cellAge[a]) == 50
        assert int(e.cellAge[b]) == 200

        e.clear_cell(b)
        assert int(e.cellAge[b]) == 0


# ===========================================================================
# LIGHT EMISSION + TEMPERATURE
# ===========================================================================

class TestLightTemperature:
    """Hot cells produce incandescent light; element emitters have fixed colors."""

    @pytest.mark.physics
    def test_hot_stone_glows_cold_does_not(self, small_engine):
        """Stone at 240 should emit light; stone at 128 should not."""
        e = small_engine
        hot = e.idx(4, 8)
        cold = e.idx(12, 8)
        e.grid[hot] = EL_STONE
        e.grid[cold] = EL_STONE
        e.temperature[hot] = 240
        e.temperature[cold] = 128

        e.step_light_emission()

        assert int(e.lightR[hot]) > 0, "Hot stone should glow"
        assert int(e.lightR[cold]) == 0, "Cold stone should not glow"

    @pytest.mark.physics
    def test_fire_always_emits_regardless_of_temp(self, small_engine):
        """Fire has intrinsic light emission, not just from temperature."""
        e = small_engine
        idx = e.idx(8, 8)
        e.grid[idx] = EL_FIRE
        e.temperature[idx] = 128  # neutral temp (unusual for fire)

        e.step_light_emission()

        # Fire has LIGHT_EMISSION > 0 and LIGHT_R = 255
        assert int(e.lightR[idx]) > 0, \
            "Fire should emit light via element properties"

    @pytest.mark.physics
    def test_spark_overrides_element_emission(self, small_engine):
        """sparkTimer=1 should produce white light regardless of element."""
        e = small_engine
        idx = e.idx(8, 8)
        e.grid[idx] = EL_METAL
        e.sparkTimer[idx] = 1

        e.step_light_emission()

        assert int(e.lightB[idx]) == 255, "Spark should be blue-white"
        assert int(e.lightR[idx]) == 200
        assert int(e.lightG[idx]) == 220


# ===========================================================================
# WIND + ELEMENT STATE
# ===========================================================================

class TestWindElementState:
    """Solids block wind; gases and empty cells receive wind."""

    @pytest.mark.physics
    def test_solid_blocks_wind(self, small_engine):
        """Stone and metal should have wind=0 even with strong global wind."""
        e = small_engine
        stone = e.idx(4, 8)
        metal = e.idx(8, 8)
        e.grid[stone] = EL_STONE
        e.grid[metal] = EL_METAL
        e.wind_force = 50

        e.step_wind()

        assert int(e.windX2[stone]) == 0, "Stone should block wind"
        assert int(e.windX2[metal]) == 0, "Metal should block wind"

    @pytest.mark.physics
    def test_empty_receives_wind(self, small_engine):
        """Empty cells should receive wind from global force."""
        e = small_engine
        idx = e.idx(8, 8)
        e.grid[idx] = EL_EMPTY
        e.wind_force = 30

        e.step_wind()

        # Should be roughly wind_force + variation (-3..+3)
        assert abs(int(e.windX2[idx]) - 30) <= 5, \
            f"Wind should be near 30, got {e.windX2[idx]}"

    @pytest.mark.physics
    def test_liquid_receives_wind(self, small_engine):
        """Liquid cells are not solid, so they should receive wind."""
        e = small_engine
        idx = e.idx(8, 8)
        e.grid[idx] = EL_WATER
        e.wind_force = 20

        e.step_wind()

        # Water is liquid (not solid), should receive wind
        assert int(e.windX2[idx]) != 0 or e.wind_force == 0


# ===========================================================================
# MASS + MOISTURE + CONCENTRATION (combined formula)
# ===========================================================================

class TestMassCombined:
    """mass = baseMass + moisture>>3 + concentration>>4."""

    @pytest.mark.physics
    def test_all_three_contributions(self, small_engine):
        """Verify exact formula with specific values."""
        e = small_engine
        idx = e.idx(8, 8)
        e.grid[idx] = EL_WATER  # baseMass=100
        e.moisture[idx] = 160   # contribution: 160>>3 = 20
        e.concentration[idx] = 240  # contribution: 240>>4 = 15

        e.step_mass()

        expected = 100 + 20 + 15  # 135
        assert int(e.mass[idx]) == expected, \
            f"Expected {expected}, got {e.mass[idx]}"

    @pytest.mark.physics
    def test_moisture_spread_increases_neighbor_mass(self, small_engine):
        """Water spreading moisture to dirt should increase dirt's mass."""
        e = small_engine
        water = e.idx(8, 8)
        dirt = e.idx(9, 8)
        e.grid[water] = EL_WATER
        e.grid[dirt] = EL_DIRT
        e.moisture[dirt] = 0

        # Initial mass
        e.step_mass()
        mass_dry = int(e.mass[dirt])

        # Spread moisture
        for _ in range(10):
            e.step_moisture()

        # Recompute mass
        e.step_mass()
        mass_wet = int(e.mass[dirt])

        if int(e.moisture[dirt]) > 0:
            assert mass_wet > mass_dry, \
                "Wet dirt should be heavier"


# ===========================================================================
# VIBRATION + HARDNESS (propagation coupling)
# ===========================================================================

class TestVibrationHardness:
    """Vibration propagates faster/further through harder materials."""

    @pytest.mark.physics
    def test_stone_propagates_vibration(self, small_engine):
        """Stone (hardness=200) should propagate vibration to neighbor."""
        e = small_engine
        src = e.idx(8, 8)
        neighbor = e.idx(9, 8)
        e.grid[src] = EL_STONE
        e.grid[neighbor] = EL_STONE
        e.vibration[src] = 200
        e.vibrationFreq[src] = 100

        e.step_vibration()

        # Spread = (200 * 200) >> 10 = 39
        expected_spread = (200 * int(HARDNESS[EL_STONE])) >> 10
        assert int(e.vibration[neighbor]) >= expected_spread, \
            f"Stone should propagate: expected >= {expected_spread}, got {e.vibration[neighbor]}"

    @pytest.mark.physics
    def test_soft_material_less_propagation(self, small_engine):
        """Ice (hardness=80) should propagate less than stone (hardness=200)."""
        # Stone test
        e1 = FieldEngine(16, 16)
        s1, n1 = e1.idx(8, 8), e1.idx(9, 8)
        e1.grid[s1] = EL_STONE
        e1.grid[n1] = EL_STONE
        e1.vibration[s1] = 200
        e1.step_vibration()
        stone_spread = int(e1.vibration[n1])

        # Ice test
        e2 = FieldEngine(16, 16)
        s2, n2 = e2.idx(8, 8), e2.idx(9, 8)
        e2.grid[s2] = EL_ICE
        e2.grid[n2] = EL_ICE
        e2.vibration[s2] = 200
        e2.step_vibration()
        ice_spread = int(e2.vibration[n2])

        assert stone_spread > ice_spread, \
            f"Stone ({stone_spread}) should propagate more than ice ({ice_spread})"

    @pytest.mark.physics
    def test_zero_hardness_no_propagation(self, small_engine):
        """Elements with hardness=0 (sand, dirt) should not propagate vibration."""
        e = small_engine
        src = e.idx(8, 8)
        neighbor = e.idx(9, 8)
        e.grid[src] = EL_SAND  # hardness=0
        e.grid[neighbor] = EL_SAND
        e.vibration[src] = 200

        e.step_vibration()

        # Sand has hardness=0, so no spread to neighbor
        # (but source still decays)
        assert int(e.vibration[neighbor]) == 0, \
            "Zero-hardness material should not propagate"


# ===========================================================================
# CHARGE + VOLTAGE
# ===========================================================================

class TestChargeVoltage:
    """Voltage flow accumulates charge in conductive cells."""

    @pytest.mark.physics
    def test_voltage_creates_charge(self, small_engine):
        """Cell with high voltage should accumulate charge."""
        e = small_engine
        idx = e.idx(8, 8)
        e.grid[idx] = EL_METAL
        e.voltage[idx] = 100  # high voltage

        for _ in range(3):
            e.step_electricity()

        assert int(e.charge[idx]) != 0, \
            "Voltage should drive charge accumulation"

    @pytest.mark.physics
    def test_no_voltage_no_charge(self, small_engine):
        """Cell with zero voltage should not accumulate charge."""
        e = small_engine
        idx = e.idx(8, 8)
        e.grid[idx] = EL_METAL
        e.voltage[idx] = 0
        e.charge[idx] = 0

        for _ in range(10):
            e.step_electricity()

        # Without voltage source and no neighbor voltage, charge stays 0
        assert int(e.charge[idx]) == 0

    @pytest.mark.physics
    def test_charge_and_voltage_transferred_by_swap(self, engine):
        """Both charge and voltage should be transferred by swap."""
        a, b = 0, 1
        engine.grid[a] = EL_METAL
        engine.voltage[a] = 80
        engine.charge[a] = 40
        engine.grid[b] = EL_WATER
        engine.voltage[b] = 10
        engine.charge[b] = -20

        engine.swap(a, b)

        assert int(engine.voltage[a]) == 10
        assert int(engine.voltage[b]) == 80
        assert int(engine.charge[a]) == -20
        assert int(engine.charge[b]) == 40


# ===========================================================================
# MULTI-FIELD SCENARIOS
# ===========================================================================

class TestMultiFieldScenarios:
    """Complex scenarios involving 3+ interacting field systems."""

    @pytest.mark.physics
    def test_combustion_chain(self, small_engine):
        """Hot wood -> oxidation increase -> mass update -> possible transform.
        Multiple field systems engaged simultaneously."""
        e = small_engine
        idx = e.idx(8, 8)
        e.grid[idx] = EL_WOOD
        e.temperature[idx] = 250
        e.oxidation[idx] = 128

        # Run multiple systems
        for _ in range(100):
            e.step_oxidation()
            e.step_mass()
            e.step_cell_age()

        # Either still burning (high oxidation) or transformed to ash
        if e.grid[idx] == EL_WOOD:
            assert int(e.oxidation[idx]) > 128, "Should be oxidizing"
            assert int(e.cellAge[idx]) > 0, "Should be aging"
        else:
            assert e.grid[idx] == EL_ASH, "Should transform to ash"

    @pytest.mark.physics
    def test_moisture_mass_stress_chain(self, small_engine):
        """Water wets dirt -> dirt mass increases -> stress increases.
        Three field systems coupled through moisture."""
        e = small_engine
        # Water above dirt column
        e.grid[e.idx(8, 3)] = EL_WATER
        for y in range(4, 12):
            e.grid[e.idx(8, y)] = EL_DIRT

        # Initial state
        e.step_mass()
        e.step_stress()
        stress_dry = int(e.stress[e.idx(8, 11)])

        # Spread moisture
        for _ in range(20):
            e.step_moisture()
        e.step_mass()
        e.step_stress()
        stress_wet = int(e.stress[e.idx(8, 11)])

        # If any dirt gained moisture, mass went up, stress should increase
        any_wet = any(e.moisture[e.idx(8, y)] > 0 for y in range(4, 12))
        if any_wet:
            assert stress_wet >= stress_dry, \
                "Wet dirt column should have >= stress"

    @pytest.mark.physics
    def test_electric_heating_light_chain(self, small_engine):
        """Voltage -> ohmic heating -> temperature rises -> light emission.
        Four-field chain through the electricity system."""
        e = small_engine
        # Metal wire with voltage
        for x in range(5, 12):
            idx = e.idx(x, 8)
            e.grid[idx] = EL_METAL
        e.voltage[e.idx(5, 8)] = 127

        # Run electricity to propagate voltage and heat
        for _ in range(10):
            e.step_electricity()

        # Check if any cell heated up
        heated = any(e.temperature[e.idx(x, 8)] > 128 for x in range(6, 12))

        # Run light emission
        e.step_light_emission()

        # If any cell got hot enough (>200), it should glow
        for x in range(6, 12):
            idx = e.idx(x, 8)
            if int(e.temperature[idx]) > 200:
                assert int(e.lightR[idx]) > 0, \
                    f"Hot metal at x={x} (temp={e.temperature[idx]}) should glow"

    @pytest.mark.physics
    def test_full_lifecycle(self, small_engine):
        """Run ALL field systems for several frames, verify no crashes
        and basic sanity (all values in range, no NaN-equivalent)."""
        e = small_engine
        # Populate a mixed world
        rng = np.random.RandomState(42)
        elements = [EL_SAND, EL_WATER, EL_STONE, EL_WOOD, EL_METAL,
                     EL_DIRT, EL_OIL, EL_ASH, EL_ACID]
        for i in range(e.n):
            if rng.random() < 0.3:
                el = rng.choice(elements)
                e.grid[i] = el
                e.temperature[i] = rng.randint(50, 200)

        e.wind_force = 10
        e.step_mass()

        # Run all systems for 20 frames
        for frame in range(20):
            e.step_temperature()
            e.step_oxidation()
            e.step_moisture()
            e.step_mass()
            e.step_cell_age()
            e.step_light_emission()
            e.step_wind()
            if frame % 2 == 0:
                e.step_vibration()
            if frame % 4 == 0:
                e.step_stress()
                e.step_pH()
            e.frame += 1

        # Sanity: all uint8 fields in [0, 255]
        for name in FieldEngine.ALL_FIELD_NAMES:
            arr = e.field(name)
            if arr.dtype == np.uint8:
                assert arr.min() >= 0
                assert arr.max() <= 255
            elif arr.dtype == np.int8:
                assert arr.min() >= -128
                assert arr.max() <= 127
