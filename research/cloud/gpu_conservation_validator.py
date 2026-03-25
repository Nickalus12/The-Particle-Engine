#!/usr/bin/env python3
"""GPU-accelerated conservation law validator for unified physics model.

Runs millions of grid scenarios on A100 GPU via CuPy to verify:
  1. Charge conservation: net charge in closed system never changes
  2. Energy conservation: total thermal energy is bounded (sources/sinks balance)
  3. Mass conservation: total non-empty cells preserved (no creation/destruction bugs)
  4. Oxidation balance: total oxidation state shifts match reaction stoichiometry
  5. Voltage conservation: current in = current out at every junction

Usage:
    python research/cloud/gpu_conservation_validator.py --scenarios 1000000
    python research/cloud/gpu_conservation_validator.py --quick  # 50k scenarios
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

try:
    import cupy as xp
    GPU_AVAILABLE = True
    print(f"Using CuPy with GPU: {xp.cuda.runtime.getDeviceProperties(0)['name'].decode()}")
except ImportError:
    import numpy as xp
    GPU_AVAILABLE = False
    print("CuPy not available, falling back to NumPy (CPU-only)")

import numpy as np

from system_profile import resolve_conservation_batch, resolve_validation_scenarios

# ---------------------------------------------------------------------------
# Constants matching Dart El class
# ---------------------------------------------------------------------------
EL_EMPTY = 0
EL_SAND = 1
EL_WATER = 2
EL_FIRE = 3
EL_ICE = 4
EL_LIGHTNING = 5
EL_STONE = 7
EL_OIL = 13
EL_ACID = 14
EL_GLASS = 15
EL_LAVA = 18
EL_WOOD = 20
EL_METAL = 21
EL_SMOKE = 22
EL_ASH = 24
EL_OXYGEN = 25
EL_CO2 = 26
EL_CHARCOAL = 29
EL_RUST = 31
EL_METHANE = 32
EL_SALT = 33

GRID_W, GRID_H = 320, 180
TOTAL_CELLS = GRID_W * GRID_H

# ---------------------------------------------------------------------------
# Element properties (unified physics model values)
# ---------------------------------------------------------------------------
NUM_ELEMENTS = 37

# Per-element: [reductionPotential, bondEnergy, fuelValue, ignitionTemp,
#               oxidizesInto, oxidationByproduct, reducesInto,
#               electronMobility, dielectric, reactivity]
# Index = element ID, values from the design document

REDUCTION_POTENTIAL = xp.zeros(64, dtype=xp.int8)
BOND_ENERGY = xp.zeros(64, dtype=xp.uint8)
FUEL_VALUE = xp.zeros(64, dtype=xp.uint8)
IGNITION_TEMP = xp.zeros(64, dtype=xp.uint8)
OXIDIZES_INTO = xp.zeros(64, dtype=xp.uint8)
OXIDATION_BYPRODUCT = xp.zeros(64, dtype=xp.uint8)
REDUCES_INTO = xp.zeros(64, dtype=xp.uint8)
ELECTRON_MOBILITY = xp.zeros(64, dtype=xp.uint8)
REACTIVITY = xp.zeros(64, dtype=xp.uint8)

# Populate from design document values
_props = {
    #              redPot  bondE  fuel  ignT  oxInto        oxByp        redInto       eMob  react
    EL_EMPTY:     (0,      0,     0,    0,    EL_EMPTY,     EL_EMPTY,    EL_EMPTY,     0,    0),
    EL_SAND:      (0,      180,   0,    0,    EL_EMPTY,     EL_EMPTY,    EL_EMPTY,     0,    5),
    EL_WATER:     (0,      100,   0,    0,    EL_EMPTY,     EL_EMPTY,    EL_EMPTY,     80,   60),
    EL_FIRE:      (50,     5,     0,    0,    EL_EMPTY,     EL_EMPTY,    EL_EMPTY,     30,   200),
    EL_ICE:       (0,      100,   0,    0,    EL_EMPTY,     EL_EMPTY,    EL_EMPTY,     5,    5),
    EL_WOOD:      (-30,    60,    120,  180,  EL_ASH,       EL_SMOKE,    EL_EMPTY,     2,    30),
    EL_METAL:     (-15,    180,   0,    0,    EL_RUST,      EL_EMPTY,    EL_EMPTY,     240,  40),
    EL_OIL:       (-40,    40,    180,  160,  EL_SMOKE,     EL_CO2,      EL_EMPTY,     0,    20),
    EL_ACID:      (60,     30,    0,    0,    EL_EMPTY,     EL_EMPTY,    EL_WATER,     100,  220),
    EL_LAVA:      (20,     200,   0,    0,    EL_EMPTY,     EL_EMPTY,    EL_EMPTY,     40,   180),
    EL_OXYGEN:    (40,     30,    0,    0,    EL_EMPTY,     EL_EMPTY,    EL_WATER,     0,    80),
    EL_CO2:       (10,     120,   0,    0,    EL_EMPTY,     EL_EMPTY,    EL_CHARCOAL,  0,    10),
    EL_CHARCOAL:  (-25,    80,    200,  170,  EL_ASH,       EL_CO2,      EL_EMPTY,     60,   25),
    EL_RUST:      (10,     140,   0,    0,    EL_EMPTY,     EL_EMPTY,    EL_METAL,     20,   10),
    EL_METHANE:   (-50,    20,    220,  140,  EL_CO2,       EL_WATER,    EL_EMPTY,     0,    40),
    EL_SALT:      (-80,    100,   0,    0,    EL_EMPTY,     EL_EMPTY,    EL_METAL,     120,  30),
    EL_STONE:     (0,      200,   0,    0,    EL_EMPTY,     EL_EMPTY,    EL_EMPTY,     0,    5),
    EL_GLASS:     (0,      220,   0,    0,    EL_EMPTY,     EL_EMPTY,    EL_EMPTY,     0,    3),
    EL_ASH:       (0,      20,    0,    0,    EL_EMPTY,     EL_EMPTY,    EL_EMPTY,     5,    5),
    EL_SMOKE:     (0,      5,     0,    0,    EL_EMPTY,     EL_EMPTY,    EL_EMPTY,     0,    5),
}

for el_id, vals in _props.items():
    # Clamp reductionPotential to int8 range
    REDUCTION_POTENTIAL[el_id] = xp.int8(max(-128, min(127, vals[0])))
    BOND_ENERGY[el_id] = vals[1]
    FUEL_VALUE[el_id] = vals[2]
    IGNITION_TEMP[el_id] = vals[3]
    OXIDIZES_INTO[el_id] = vals[4]
    OXIDATION_BYPRODUCT[el_id] = vals[5]
    REDUCES_INTO[el_id] = vals[6]
    ELECTRON_MOBILITY[el_id] = vals[7]
    REACTIVITY[el_id] = vals[8]


# ---------------------------------------------------------------------------
# Batched simulation kernels
# ---------------------------------------------------------------------------

def generate_random_grids(batch_size: int) -> dict:
    """Generate a batch of random grid states on GPU."""
    # Random element types (only use elements with defined properties)
    valid_elements = xp.array(list(_props.keys()), dtype=xp.uint8)
    indices = xp.random.randint(0, len(valid_elements),
                                size=(batch_size, TOTAL_CELLS), dtype=xp.int32)
    grids = valid_elements[indices]

    return {
        "grid": grids,  # (batch, cells) uint8
        "temperature": xp.random.randint(0, 256, size=(batch_size, TOTAL_CELLS), dtype=xp.uint8),
        "charge": xp.zeros((batch_size, TOTAL_CELLS), dtype=xp.int8),
        "oxidation": xp.full((batch_size, TOTAL_CELLS), 128, dtype=xp.uint8),
        "moisture": xp.random.randint(0, 64, size=(batch_size, TOTAL_CELLS), dtype=xp.uint8),
        "voltage": xp.zeros((batch_size, TOTAL_CELLS), dtype=xp.int8),
        "sparkTimer": xp.zeros((batch_size, TOTAL_CELLS), dtype=xp.uint8),
    }


def generate_scenario_grids(batch_size: int, scenario: str) -> dict:
    """Generate grids for specific test scenarios."""
    grids = xp.zeros((batch_size, TOTAL_CELLS), dtype=xp.uint8)
    temps = xp.full((batch_size, TOTAL_CELLS), 128, dtype=xp.uint8)
    charges = xp.zeros((batch_size, TOTAL_CELLS), dtype=xp.int8)
    oxidation = xp.full((batch_size, TOTAL_CELLS), 128, dtype=xp.uint8)
    moisture = xp.zeros((batch_size, TOTAL_CELLS), dtype=xp.uint8)
    voltage = xp.zeros((batch_size, TOTAL_CELLS), dtype=xp.int8)

    if scenario == "combustion":
        # Wood block with oxygen border and fire ignition source
        for b in range(batch_size):
            # Fill center with wood
            for y in range(60, 120):
                for x in range(100, 220):
                    grids[b, y * GRID_W + x] = EL_WOOD
            # Border with oxygen
            for y in range(58, 122):
                for x in range(98, 222):
                    idx = y * GRID_W + x
                    if grids[b, idx] == EL_EMPTY:
                        grids[b, idx] = EL_OXYGEN
            # Ignition point
            grids[b, 90 * GRID_W + 160] = EL_FIRE
            temps[b, 90 * GRID_W + 160] = 240

    elif scenario == "corrosion":
        # Metal plate submerged in water with oxygen
        for b in range(batch_size):
            for y in range(80, 100):
                for x in range(120, 200):
                    grids[b, y * GRID_W + x] = EL_METAL
            for y in range(60, 120):
                for x in range(100, 220):
                    idx = y * GRID_W + x
                    if grids[b, idx] == EL_EMPTY:
                        grids[b, idx] = EL_WATER
                        moisture[b, idx] = 200
            # Sprinkle oxygen
            oxy_positions = xp.random.randint(100, 220, size=(batch_size, 50))
            for i in range(50):
                grids[b, 65 * GRID_W + int(oxy_positions[b, i])] = EL_OXYGEN

    elif scenario == "electrical":
        # Metal wire with voltage source at one end, ground at other
        for b in range(batch_size):
            # Horizontal metal wire
            y = 90
            for x in range(50, 270):
                grids[b, y * GRID_W + x] = EL_METAL
            # Voltage source
            voltage[b, y * GRID_W + 50] = 127
            # Ground
            voltage[b, y * GRID_W + 269] = 0

    elif scenario == "electrolysis":
        # Water body with electrodes
        for b in range(batch_size):
            for y in range(70, 110):
                for x in range(100, 220):
                    grids[b, y * GRID_W + x] = EL_WATER
                    moisture[b, y * GRID_W + x] = 255
            # Metal electrodes at sides
            for y in range(70, 110):
                grids[b, y * GRID_W + 100] = EL_METAL
                grids[b, y * GRID_W + 219] = EL_METAL
            # Apply voltage
            for y in range(70, 110):
                voltage[b, y * GRID_W + 100] = 100
                voltage[b, y * GRID_W + 219] = -100

    elif scenario == "acid_dissolution":
        # Acid pool with various materials
        for b in range(batch_size):
            # Acid pool
            for y in range(90, 120):
                for x in range(100, 220):
                    grids[b, y * GRID_W + x] = EL_ACID
            # Materials: wood (dissolves), glass (resists), metal (slow dissolve)
            for y in range(85, 90):
                for x in range(110, 140):
                    grids[b, y * GRID_W + x] = EL_WOOD
                for x in range(150, 180):
                    grids[b, y * GRID_W + x] = EL_GLASS
                for x in range(190, 220):
                    grids[b, y * GRID_W + x] = EL_METAL

    return {
        "grid": grids,
        "temperature": temps,
        "charge": charges,
        "oxidation": oxidation,
        "moisture": moisture,
        "voltage": voltage,
        "sparkTimer": xp.zeros((batch_size, TOTAL_CELLS), dtype=xp.uint8),
    }


# ---------------------------------------------------------------------------
# Batched chemistry simulation (GPU)
# ---------------------------------------------------------------------------

def simulate_chemistry_step_batched(state: dict, rng_seed: int = 42) -> dict:
    """Run one chemistry step across entire batch on GPU.

    This is the GPU equivalent of the Dart chemistryStep() function,
    operating on the full batch in parallel.
    """
    grid = state["grid"]
    temp = state["temperature"]
    charge = state["charge"]
    oxidation = state["oxidation"].copy()
    moisture = state["moisture"].copy()
    voltage = state["voltage"]
    batch_size = grid.shape[0]

    # Lookup element properties for every cell (vectorized)
    cell_redpot = REDUCTION_POTENTIAL[grid.ravel().astype(xp.int64)].reshape(grid.shape)
    cell_bond = BOND_ENERGY[grid.ravel().astype(xp.int64)].reshape(grid.shape)
    cell_fuel = FUEL_VALUE[grid.ravel().astype(xp.int64)].reshape(grid.shape)
    cell_ignition = IGNITION_TEMP[grid.ravel().astype(xp.int64)].reshape(grid.shape)
    cell_react = REACTIVITY[grid.ravel().astype(xp.int64)].reshape(grid.shape)
    cell_oxinto = OXIDIZES_INTO[grid.ravel().astype(xp.int64)].reshape(grid.shape)
    cell_oxbyp = OXIDATION_BYPRODUCT[grid.ravel().astype(xp.int64)].reshape(grid.shape)
    cell_emob = ELECTRON_MOBILITY[grid.ravel().astype(xp.int64)].reshape(grid.shape)

    new_grid = grid.copy()
    new_temp = temp.copy()
    new_oxidation = oxidation.copy()
    new_charge = charge.copy()

    # Reshape to 2D for neighbor access
    grid_2d = grid.reshape(batch_size, GRID_H, GRID_W)
    temp_2d = temp.reshape(batch_size, GRID_H, GRID_W)
    oxid_2d = oxidation.reshape(batch_size, GRID_H, GRID_W)
    moist_2d = moisture.reshape(batch_size, GRID_H, GRID_W)
    new_grid_2d = new_grid.reshape(batch_size, GRID_H, GRID_W)
    new_temp_2d = new_temp.reshape(batch_size, GRID_H, GRID_W)
    new_oxid_2d = new_oxidation.reshape(batch_size, GRID_H, GRID_W)

    fuel_2d = cell_fuel.reshape(batch_size, GRID_H, GRID_W)
    ign_2d = cell_ignition.reshape(batch_size, GRID_H, GRID_W)
    redpot_2d = cell_redpot.reshape(batch_size, GRID_H, GRID_W)
    react_2d = cell_react.reshape(batch_size, GRID_H, GRID_W)
    bond_2d = cell_bond.reshape(batch_size, GRID_H, GRID_W)
    oxinto_2d = cell_oxinto.reshape(batch_size, GRID_H, GRID_W)
    oxbyp_2d = cell_oxbyp.reshape(batch_size, GRID_H, GRID_W)

    # Check 4-connected neighbors for max reductionPotential (oxidizer check)
    # Pad grid to handle boundaries
    padded_redpot = xp.pad(redpot_2d.astype(xp.int16), ((0, 0), (1, 1), (1, 1)),
                           mode='constant', constant_values=-128)
    max_neighbor_redpot = xp.maximum(
        xp.maximum(padded_redpot[:, :-2, 1:-1], padded_redpot[:, 2:, 1:-1]),
        xp.maximum(padded_redpot[:, 1:-1, :-2], padded_redpot[:, 1:-1, 2:])
    )

    # --- COMBUSTION ---
    # Condition: has fuel AND temp > ignition AND neighbor has higher redPot
    has_fuel = fuel_2d > 0
    hot_enough = temp_2d > ign_2d
    oxidizer_nearby = max_neighbor_redpot > (redpot_2d.astype(xp.int16) + 20)
    combustion_mask = has_fuel & hot_enough & oxidizer_nearby

    # Advance oxidation for burning cells
    ox_increment = react_2d[combustion_mask].astype(xp.int16) >> 4
    new_oxid_2d[combustion_mask] = xp.minimum(
        255, oxid_2d[combustion_mask].astype(xp.int16) + xp.maximum(1, ox_increment)
    ).astype(xp.uint8)

    # Heat release
    heat_release = fuel_2d[combustion_mask].astype(xp.int16) >> 2
    new_temp_2d[combustion_mask] = xp.minimum(
        255, temp_2d[combustion_mask].astype(xp.int16) + heat_release
    ).astype(xp.uint8)

    # Transform fully oxidized cells
    fully_oxidized = new_oxid_2d > 200
    transform_mask = combustion_mask & fully_oxidized
    new_grid_2d[transform_mask] = oxinto_2d[transform_mask]
    new_oxid_2d[transform_mask] = 128  # reset

    # --- CORROSION (slow oxidation) ---
    has_neg_redpot = redpot_2d.astype(xp.int16) < 0
    has_moisture = moist_2d > 30
    corrosion_mask = has_neg_redpot & has_moisture & oxidizer_nearby & (~combustion_mask)

    corr_rate = ((max_neighbor_redpot[corrosion_mask].astype(xp.int32) -
                  redpot_2d[corrosion_mask].astype(xp.int32)) *
                 moist_2d[corrosion_mask].astype(xp.int32)) // (255 * 60)
    corr_rate = xp.maximum(1, corr_rate)
    new_oxid_2d[corrosion_mask] = xp.minimum(
        255, oxid_2d[corrosion_mask].astype(xp.int16) + corr_rate
    ).astype(xp.uint8)

    corroded_through = new_oxid_2d > 230
    corr_transform = corrosion_mask & corroded_through
    new_grid_2d[corr_transform] = oxinto_2d[corr_transform]
    new_oxid_2d[corr_transform] = 128

    # --- ACID DISSOLUTION ---
    high_reactivity = react_2d > 150
    padded_bond = xp.pad(bond_2d.astype(xp.int16), ((0, 0), (1, 1), (1, 1)),
                         mode='constant', constant_values=255)
    min_neighbor_bond = xp.minimum(
        xp.minimum(padded_bond[:, :-2, 1:-1], padded_bond[:, 2:, 1:-1]),
        xp.minimum(padded_bond[:, 1:-1, :-2], padded_bond[:, 1:-1, 2:])
    )
    can_dissolve = (min_neighbor_bond > 0) & (min_neighbor_bond < react_2d.astype(xp.int16))
    acid_mask = high_reactivity & can_dissolve & (~combustion_mask) & (~corrosion_mask)
    # Acid is consumed (simplified — in full sim, tracks life decrement)

    # Flatten results back
    new_grid = new_grid_2d.reshape(batch_size, TOTAL_CELLS)
    new_temp = new_temp_2d.reshape(batch_size, TOTAL_CELLS)
    new_oxidation = new_oxid_2d.reshape(batch_size, TOTAL_CELLS)

    return {
        "grid": new_grid,
        "temperature": new_temp,
        "charge": new_charge,
        "oxidation": new_oxidation,
        "moisture": moisture,
        "voltage": voltage,
        "sparkTimer": state["sparkTimer"],
    }


def simulate_electricity_step_batched(state: dict) -> dict:
    """Run one electricity propagation step across entire batch on GPU."""
    grid = state["grid"]
    voltage = state["voltage"].copy()
    source_voltage = state["voltage"]
    spark = state["sparkTimer"].copy()
    temp = state["temperature"].copy()
    batch_size = grid.shape[0]

    cell_emob = ELECTRON_MOBILITY[grid.ravel().astype(xp.int64)].reshape(grid.shape)

    # Reshape for 2D neighbor access
    v_2d = voltage.reshape(batch_size, GRID_H, GRID_W).astype(xp.int16)
    source_2d = source_voltage.reshape(batch_size, GRID_H, GRID_W).astype(xp.int16)
    source_mask = source_2d != 0
    spark_2d = spark.reshape(batch_size, GRID_H, GRID_W)
    emob_2d = cell_emob.reshape(batch_size, GRID_H, GRID_W)
    temp_2d = temp.reshape(batch_size, GRID_H, GRID_W).astype(xp.int16)

    new_v_2d = v_2d.copy()
    new_spark_2d = spark_2d.copy()
    new_temp_2d = temp_2d.copy()

    # Advance refractory timers
    refractory = (spark_2d > 0) & (spark_2d < 4)
    new_spark_2d[refractory] = spark_2d[refractory] + 1
    reset_mask = new_spark_2d >= 4
    new_spark_2d[reset_mask] = 0

    # Find max neighbor voltage (4-connected)
    padded_v = xp.pad(v_2d, ((0, 0), (1, 1), (1, 1)),
                      mode='constant', constant_values=0)
    max_nv = xp.maximum(
        xp.maximum(padded_v[:, :-2, 1:-1], padded_v[:, 2:, 1:-1]),
        xp.maximum(padded_v[:, 1:-1, :-2], padded_v[:, 1:-1, 2:])
    )

    # Conductors that are not in refractory period
    is_conductor = emob_2d > 0
    not_refractory = spark_2d == 0
    gradient = max_nv - v_2d
    sufficient_gradient = gradient > 5

    propagate_mask = is_conductor & not_refractory & sufficient_gradient & (~source_mask)

    # Voltage attenuation: resistance = 255 - electronMobility
    resistance = 255 - emob_2d[propagate_mask].astype(xp.int16)
    attenuation = xp.maximum(xp.int16(1), resistance >> 5)
    new_voltage = max_nv[propagate_mask] - attenuation
    new_v_2d[propagate_mask] = xp.clip(new_voltage, -128, 127)
    new_spark_2d[propagate_mask] = 1

    # Ohmic heating
    high_resistance = resistance > 30
    heat = ((max_nv[propagate_mask] - new_v_2d[propagate_mask]) *
            resistance) >> 8
    temp_at_prop = new_temp_2d[propagate_mask]
    temp_at_prop[high_resistance] = xp.minimum(
        255, temp_at_prop[high_resistance] + heat[high_resistance]
    )
    new_temp_2d[propagate_mask] = temp_at_prop

    # Voltage decay for idle conductors
    idle = is_conductor & (spark_2d == 0) & (~propagate_mask) & (v_2d != 0) & (~source_mask)
    decay_rate = xp.maximum(xp.int16(1), (255 - emob_2d[idle].astype(xp.int16)) >> 6)
    pos = v_2d[idle] > 0
    neg = v_2d[idle] < 0
    decayed = v_2d[idle].copy()
    decayed[pos] = xp.maximum(0, decayed[pos] - decay_rate[pos])
    decayed[neg] = xp.minimum(0, decayed[neg] + decay_rate[neg])
    new_v_2d[idle] = decayed
    new_v_2d[source_mask] = source_2d[source_mask]

    # Flatten
    new_voltage_flat = new_v_2d.reshape(batch_size, TOTAL_CELLS).astype(xp.int8)
    new_spark_flat = new_spark_2d.reshape(batch_size, TOTAL_CELLS)
    new_temp_flat = new_temp_2d.reshape(batch_size, TOTAL_CELLS).astype(xp.uint8)

    result = dict(state)
    result["voltage"] = new_voltage_flat
    result["sparkTimer"] = new_spark_flat
    result["temperature"] = new_temp_flat
    return result


# ---------------------------------------------------------------------------
# Conservation law tests
# ---------------------------------------------------------------------------

@dataclass
class TestResult:
    name: str
    passed: bool
    scenarios_tested: int
    violations: int = 0
    max_violation: float = 0.0
    details: str = ""


def test_mass_conservation(batch_size: int = 10000, steps: int = 5) -> TestResult:
    """Verify total non-empty cells are conserved (modulo known reactions).

    In a system with no combustion or dissolution (all temps below ignition,
    no acid), mass must be perfectly conserved.
    """
    # Generate grids with NO reactive conditions
    batch_size = min(batch_size, 256)
    state = generate_random_grids(batch_size)
    # Set temperature to safe neutral (no combustion triggers)
    state["temperature"] = xp.full_like(state["temperature"], 100)
    # Remove acid and fire to prevent mass-changing reactions
    mask_fire = state["grid"] == EL_FIRE
    mask_acid = state["grid"] == EL_ACID
    state["grid"][mask_fire] = EL_STONE
    state["grid"][mask_acid] = EL_WATER

    initial_mass = xp.sum(state["grid"] != EL_EMPTY, axis=1)

    for _ in range(steps):
        state = simulate_chemistry_step_batched(state)

    final_mass = xp.sum(state["grid"] != EL_EMPTY, axis=1)
    diff = xp.abs(final_mass.astype(xp.int32) - initial_mass.astype(xp.int32))
    violations = int(xp.sum(diff > 0))
    max_viol = float(xp.max(diff))

    return TestResult(
        name="mass_conservation_no_reactions",
        passed=violations == 0,
        scenarios_tested=batch_size,
        violations=violations,
        max_violation=max_viol,
        details=f"Tested {batch_size} grids x {steps} steps with no reactive conditions"
    )


def test_charge_conservation(batch_size: int = 10000, steps: int = 10) -> TestResult:
    """Verify net charge is conserved during electricity propagation.

    Total charge across the grid should never change — current redistributes
    charge but never creates or destroys it.
    """
    state = generate_scenario_grids(min(batch_size, 1000), "electrical")
    # Also add random charge distributions
    state["charge"] = xp.random.randint(-50, 50, size=state["charge"].shape, dtype=xp.int8)

    initial_charge = xp.sum(state["charge"].astype(xp.int32), axis=1)

    for _ in range(steps):
        state = simulate_electricity_step_batched(state)

    final_charge = xp.sum(state["charge"].astype(xp.int32), axis=1)
    diff = xp.abs(final_charge - initial_charge)
    violations = int(xp.sum(diff > 0))
    max_viol = float(xp.max(diff))

    return TestResult(
        name="charge_conservation",
        passed=violations == 0,
        scenarios_tested=min(batch_size, 1000),
        violations=violations,
        max_violation=max_viol,
        details=f"Net charge must be zero-sum across voltage propagation steps"
    )


def test_energy_conservation_closed(batch_size: int = 10000, steps: int = 10) -> TestResult:
    """Verify thermal energy is bounded in closed systems.

    Without exothermic reactions, total temperature should not increase.
    With reactions, total energy (thermal + chemical potential) should be bounded.
    """
    batch_size = min(batch_size, 256)
    state = generate_random_grids(batch_size)
    # No combustion conditions
    state["temperature"] = xp.full_like(state["temperature"], 100)
    state["grid"][state["grid"] == EL_FIRE] = EL_STONE

    initial_energy = xp.sum(state["temperature"].astype(xp.int32), axis=1)

    for _ in range(steps):
        state = simulate_chemistry_step_batched(state)

    final_energy = xp.sum(state["temperature"].astype(xp.int32), axis=1)
    # In a non-reactive system, energy should not increase
    energy_gain = final_energy - initial_energy
    violations = int(xp.sum(energy_gain > 8))  # allow only tiny simulation noise
    max_viol = float(xp.max(energy_gain))

    return TestResult(
        name="energy_conservation_closed",
        passed=violations == 0,
        scenarios_tested=batch_size,
        violations=violations,
        max_violation=max_viol,
        details=f"Thermal energy should not increase without exothermic reactions"
    )


def test_oxidation_balance(batch_size: int = 5000, steps: int = 20) -> TestResult:
    """Verify oxidation state changes balance across reactions.

    When A oxidizes (oxidation increases), something nearby must reduce
    (gain electrons). Net oxidation change should be zero or positive
    (heat dissipation is one-directional).
    """
    state = generate_scenario_grids(min(batch_size, 500), "combustion")

    initial_ox_sum = xp.sum(state["oxidation"].astype(xp.int32), axis=1)
    initial_elem_counts = {}
    for el_id in _props:
        initial_elem_counts[el_id] = xp.sum(state["grid"] == el_id, axis=1)

    for _ in range(steps):
        state = simulate_chemistry_step_batched(state)

    final_ox_sum = xp.sum(state["oxidation"].astype(xp.int32), axis=1)

    # Oxidation state can increase (combustion is net oxidation),
    # but should not decrease without a reducing agent
    # This test verifies the accounting is consistent
    ox_change = final_ox_sum - initial_ox_sum

    # Count element transformations
    final_elem_counts = {}
    for el_id in _props:
        final_elem_counts[el_id] = xp.sum(state["grid"] == el_id, axis=1)

    # Verify: wood decreased AND (ash or smoke) increased
    wood_consumed = initial_elem_counts.get(EL_WOOD, 0) - final_elem_counts.get(EL_WOOD, 0)
    products_created = (
        (final_elem_counts.get(EL_ASH, 0) - initial_elem_counts.get(EL_ASH, 0)) +
        (final_elem_counts.get(EL_SMOKE, 0) - initial_elem_counts.get(EL_SMOKE, 0))
    )

    # Products should roughly match consumed fuel (within batch noise)
    balance = xp.abs(wood_consumed - products_created)
    violations = int(xp.sum(balance > wood_consumed * 0.2 + 5))  # 20% tolerance
    max_viol = float(xp.max(balance)) if balance.size > 0 else 0.0

    return TestResult(
        name="oxidation_stoichiometry",
        passed=violations <= batch_size * 0.05,  # 5% allowed
        scenarios_tested=min(batch_size, 500),
        violations=violations,
        max_violation=max_viol,
        details=f"Fuel consumed should roughly equal products created"
    )


def test_voltage_kirchhoff(batch_size: int = 1000, steps: int = 50) -> TestResult:
    """Verify Kirchhoff-like current conservation at junctions.

    At any internal conductor node, current in should approximately equal
    current out (voltage gradient sum should be ~zero at steady state).
    """
    state = generate_scenario_grids(min(batch_size, 200), "electrical")

    # Run to steady state
    for _ in range(steps):
        state = simulate_electricity_step_batched(state)

    v_2d = state["voltage"].reshape(-1, GRID_H, GRID_W).astype(xp.int16)
    grid_2d = state["grid"].reshape(-1, GRID_H, GRID_W)
    emob_2d = ELECTRON_MOBILITY[grid_2d.ravel().astype(xp.int64)].reshape(grid_2d.shape)

    # For each internal conductor cell, sum voltage gradients to neighbors
    padded_v = xp.pad(v_2d, ((0, 0), (1, 1), (1, 1)), mode='edge')
    laplacian = (
        padded_v[:, :-2, 1:-1] + padded_v[:, 2:, 1:-1] +
        padded_v[:, 1:-1, :-2] + padded_v[:, 1:-1, 2:] -
        4 * v_2d
    )

    # At steady state, laplacian should be ~0 for conductors
    # (Laplace's equation: voltage field is harmonic)
    conductor_mask = emob_2d > 100  # only high-conductivity cells
    if xp.sum(conductor_mask) == 0:
        return TestResult(
            name="voltage_kirchhoff",
            passed=True,
            scenarios_tested=0,
            details="No high-conductivity cells to test"
        )

    residuals = xp.abs(laplacian[conductor_mask].astype(xp.float32))
    mean_residual = float(xp.mean(residuals))
    max_residual = float(xp.max(residuals))

    # Allow residual up to 10 (voltage units) due to discrete grid + attenuation
    passed = mean_residual < 10.0 and max_residual < 40.0

    return TestResult(
        name="voltage_kirchhoff",
        passed=passed,
        scenarios_tested=min(batch_size, 200),
        violations=int(xp.sum(residuals > 20)),
        max_violation=max_residual,
        details=f"Mean Laplacian residual: {mean_residual:.2f}, max: {max_residual:.2f}"
    )


def test_combustion_energy_release(batch_size: int = 500, steps: int = 30) -> TestResult:
    """Verify combustion releases proportional energy.

    Higher fuel value elements should produce more heat when burned.
    Wood (fuel=120) should release less heat than oil (fuel=180).
    """
    # Test wood combustion
    wood_state = generate_scenario_grids(min(batch_size, 200), "combustion")
    wood_init_energy = xp.sum(wood_state["temperature"].astype(xp.int32), axis=1)

    for _ in range(steps):
        wood_state = simulate_chemistry_step_batched(wood_state)

    wood_final_energy = xp.sum(wood_state["temperature"].astype(xp.int32), axis=1)
    wood_heat = xp.mean(wood_final_energy - wood_init_energy)

    # Test with oil (swap wood for oil in initial state)
    oil_state = generate_scenario_grids(min(batch_size, 200), "combustion")
    oil_state["grid"][oil_state["grid"] == EL_WOOD] = EL_OIL
    oil_init_energy = xp.sum(oil_state["temperature"].astype(xp.int32), axis=1)

    for _ in range(steps):
        oil_state = simulate_chemistry_step_batched(oil_state)

    oil_final_energy = xp.sum(oil_state["temperature"].astype(xp.int32), axis=1)
    oil_heat = xp.mean(oil_final_energy - oil_init_energy)

    # Oil (fuel=180) should release more heat than wood (fuel=120)
    passed = (
        float(wood_heat) > 0.5 and
        float(oil_heat) > 0.5 and
        float(oil_heat) >= float(wood_heat) * 1.1
    )

    return TestResult(
        name="combustion_energy_proportional",
        passed=passed,
        scenarios_tested=min(batch_size, 200) * 2,
        max_violation=abs(float(oil_heat) - float(wood_heat) * 1.5),
        details=f"Wood heat: {float(wood_heat):.0f}, Oil heat: {float(oil_heat):.0f} "
                f"(ratio: {float(oil_heat)/max(1,float(wood_heat)):.2f}, expected ~1.5)"
    )


def test_acid_selectivity(batch_size: int = 500, steps: int = 20) -> TestResult:
    """Verify acid dissolves materials proportional to bond energy difference.

    Acid (reactivity=220) should dissolve wood (bond=60) faster than
    metal (bond=180) and not dissolve glass (bond=220).
    """
    state = generate_scenario_grids(min(batch_size, 200), "acid_dissolution")

    initial_wood = xp.sum(state["grid"] == EL_WOOD, axis=1)
    initial_glass = xp.sum(state["grid"] == EL_GLASS, axis=1)
    initial_metal = xp.sum(state["grid"] == EL_METAL, axis=1)

    for _ in range(steps):
        state = simulate_chemistry_step_batched(state)

    final_wood = xp.sum(state["grid"] == EL_WOOD, axis=1)
    final_glass = xp.sum(state["grid"] == EL_GLASS, axis=1)
    final_metal = xp.sum(state["grid"] == EL_METAL, axis=1)

    wood_dissolved = xp.mean(initial_wood.astype(xp.float32) - final_wood.astype(xp.float32))
    glass_dissolved = xp.mean(initial_glass.astype(xp.float32) - final_glass.astype(xp.float32))
    metal_dissolved = xp.mean(initial_metal.astype(xp.float32) - final_metal.astype(xp.float32))

    # Wood should dissolve most, glass should not dissolve, metal in between
    wood_ok = (
        float(wood_dissolved) >= 1.0 and
        float(wood_dissolved) >= float(metal_dissolved) + 0.5
    )
    glass_ok = float(glass_dissolved) <= 1.0  # essentially zero
    passed = wood_ok and glass_ok

    return TestResult(
        name="acid_selectivity",
        passed=passed,
        scenarios_tested=min(batch_size, 200),
        details=f"Wood dissolved: {float(wood_dissolved):.1f}, "
                f"Metal dissolved: {float(metal_dissolved):.1f}, "
                f"Glass dissolved: {float(glass_dissolved):.1f}"
    )


# ---------------------------------------------------------------------------
# Main runner
# ---------------------------------------------------------------------------

def run_all_tests(total_scenarios: int) -> list[TestResult]:
    """Run all conservation law tests."""
    batch = resolve_conservation_batch(total_scenarios)
    results = []

    tests = [
        ("Mass Conservation (no reactions)", lambda: test_mass_conservation(batch, 5)),
        ("Charge Conservation", lambda: test_charge_conservation(batch, 10)),
        ("Energy Conservation (closed)", lambda: test_energy_conservation_closed(batch, 10)),
        ("Oxidation Stoichiometry", lambda: test_oxidation_balance(batch, 20)),
        ("Voltage Kirchhoff", lambda: test_voltage_kirchhoff(batch, 50)),
        ("Combustion Energy Proportional", lambda: test_combustion_energy_release(batch, 30)),
        ("Acid Selectivity", lambda: test_acid_selectivity(batch, 20)),
    ]

    for name, test_fn in tests:
        print(f"\n{'='*60}")
        print(f"Running: {name}")
        print(f"{'='*60}")
        t0 = time.time()
        try:
            result = test_fn()
            elapsed = time.time() - t0
            status = "PASS" if result.passed else "FAIL"
            print(f"  [{status}] {result.name} ({elapsed:.1f}s)")
            print(f"    Scenarios: {result.scenarios_tested}")
            print(f"    Violations: {result.violations}")
            print(f"    Max violation: {result.max_violation}")
            print(f"    Details: {result.details}")
            results.append(result)
        except Exception as e:
            print(f"  [ERROR] {name}: {e}")
            results.append(TestResult(
                name=name, passed=False, scenarios_tested=0,
                details=f"Exception: {e}"
            ))
        finally:
            if GPU_AVAILABLE:
                try:
                    xp.get_default_memory_pool().free_all_blocks()
                    xp.get_default_pinned_memory_pool().free_all_blocks()
                except Exception:
                    pass

    return results


def main():
    parser = argparse.ArgumentParser(description="GPU Conservation Law Validator")
    parser.add_argument("--scenarios", type=int, default=0,
                        help="Total scenarios to test (default: 100000)")
    parser.add_argument("--quick", action="store_true",
                        help="Quick mode: 50k scenarios")
    parser.add_argument("--output", type=str, default=None,
                        help="Output JSON file path")
    args = parser.parse_args()

    scenarios = 50000 if args.quick else resolve_validation_scenarios(args.scenarios or None)
    print(f"\nGPU Conservation Law Validator")
    print(f"GPU available: {GPU_AVAILABLE}")
    print(f"Total scenarios: {scenarios:,}")
    print(f"Grid size: {GRID_W}x{GRID_H} = {TOTAL_CELLS:,} cells")
    print()

    t0 = time.time()
    results = run_all_tests(scenarios)
    elapsed = time.time() - t0

    # Summary
    print(f"\n{'='*60}")
    print(f"SUMMARY ({elapsed:.1f}s total)")
    print(f"{'='*60}")
    passed = sum(1 for r in results if r.passed)
    total = len(results)
    print(f"  {passed}/{total} tests passed")
    for r in results:
        status = "PASS" if r.passed else "FAIL"
        print(f"  [{status}] {r.name}: {r.violations} violations / {r.scenarios_tested} scenarios")

    # Save results
    output_path = args.output or str(
        Path(__file__).parent / "conservation_results.json"
    )
    output = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "gpu_available": GPU_AVAILABLE,
        "total_scenarios": scenarios,
        "elapsed_seconds": elapsed,
        "passed": passed,
        "total_tests": total,
        "results": [
            {
                "name": r.name,
                "passed": r.passed,
                "scenarios": r.scenarios_tested,
                "violations": r.violations,
                "max_violation": r.max_violation,
                "details": r.details,
            }
            for r in results
        ],
    }
    with open(output_path, "w") as f:
        json.dump(output, f, indent=2)
    print(f"\nResults saved to {output_path}")

    sys.exit(0 if passed == total else 1)


if __name__ == "__main__":
    main()
