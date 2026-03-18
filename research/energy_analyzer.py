"""
Energy Budget Analyzer
======================

Computes total system energy across simulation frames for thermodynamic
consistency validation. Tracks kinetic, potential, thermal, and chemical
energy components using real physics formulas adapted to the cellular
automaton grid.

Energy components:
  - Kinetic:   0.5 * density * (vx^2 + vy^2) per occupied cell
  - Potential: density * |gravity| * height per occupied cell
  - Thermal:   |temperature - 128| per occupied cell (deviation from neutral)
  - Chemical:  fuel_energy per flammable cell (stored combustion potential)
"""

import numpy as np

# Element IDs (must match element_registry.dart El class)
EMPTY = 0
SAND = 1
WATER = 2
FIRE = 3
ICE = 4
LIGHTNING = 5
SEED = 6
STONE = 7
TNT = 8
RAINBOW = 9
MUD = 10
STEAM = 11
ANT = 12
OIL = 13
ACID = 14
GLASS = 15
DIRT = 16
PLANT = 17
LAVA = 18
SNOW = 19
WOOD = 20
METAL = 21
SMOKE = 22
BUBBLE = 23
ASH = 24

NUM_ELEMENTS = 25

# Density table (index = element ID, from element_registry.dart)
DENSITY = np.zeros(NUM_ELEMENTS, dtype=np.float64)
DENSITY[EMPTY] = 0
DENSITY[SAND] = 150
DENSITY[WATER] = 100
DENSITY[FIRE] = 5
DENSITY[ICE] = 90
DENSITY[LIGHTNING] = 0
DENSITY[SEED] = 130
DENSITY[STONE] = 255
DENSITY[TNT] = 140
DENSITY[RAINBOW] = 8
DENSITY[MUD] = 120
DENSITY[STEAM] = 3
DENSITY[ANT] = 80
DENSITY[OIL] = 80
DENSITY[ACID] = 110
DENSITY[GLASS] = 220
DENSITY[DIRT] = 145
DENSITY[PLANT] = 60
DENSITY[LAVA] = 200
DENSITY[SNOW] = 50
DENSITY[WOOD] = 85
DENSITY[METAL] = 240
DENSITY[SMOKE] = 4
DENSITY[BUBBLE] = 2
DENSITY[ASH] = 30

# Gravity table (signed, from element_registry.dart)
GRAVITY = np.zeros(NUM_ELEMENTS, dtype=np.float64)
GRAVITY[SAND] = 2
GRAVITY[WATER] = 1
GRAVITY[FIRE] = -1
GRAVITY[ICE] = 1
GRAVITY[LIGHTNING] = 1
GRAVITY[SEED] = 1
GRAVITY[STONE] = 1
GRAVITY[TNT] = 2
GRAVITY[RAINBOW] = -1
GRAVITY[MUD] = 1
GRAVITY[STEAM] = -1
GRAVITY[OIL] = 1
GRAVITY[ACID] = 1
GRAVITY[GLASS] = 1
GRAVITY[DIRT] = 1
GRAVITY[LAVA] = 1
GRAVITY[SNOW] = 1
GRAVITY[WOOD] = 1
GRAVITY[METAL] = 1
GRAVITY[SMOKE] = -1
GRAVITY[BUBBLE] = -1
GRAVITY[ASH] = 1

# Fuel elements and their chemical energy potential.
# Higher values = more stored energy released on combustion.
FUEL_ELEMENTS = {WOOD, OIL, PLANT, SEED, TNT}
FUEL_ENERGY = {
    WOOD: 500.0,    # Burns slowly, lots of stored energy
    OIL: 800.0,     # High energy density fuel
    PLANT: 200.0,   # Burns quickly, less energy
    SEED: 150.0,    # Small fuel
    TNT: 2000.0,    # Explosive: massive chemical energy release
}

TEMP_NEUTRAL = 128


def compute_energy_budget(grid, temperature, vel_x, vel_y):
    """Compute all energy components for a simulation state.

    Parameters
    ----------
    grid : ndarray (H, W) uint8
        Element IDs per cell.
    temperature : ndarray (H, W) uint8
        Per-cell temperature (0-255, 128 = neutral).
    vel_x : ndarray (H, W) int8
        Per-cell horizontal velocity.
    vel_y : ndarray (H, W) int8
        Per-cell vertical velocity.

    Returns
    -------
    dict with keys: kinetic, potential, thermal, chemical, total,
                    element_counts (dict of element_id -> count)
    """
    h, w = grid.shape
    occupied = grid != EMPTY

    # Build per-cell density and gravity arrays via lookup
    cell_density = DENSITY[grid]   # (H, W) float
    cell_gravity = GRAVITY[grid]   # (H, W) float

    # Height: distance from bottom (row 0 = top, row H-1 = bottom)
    height = np.arange(h - 1, -1, -1, dtype=np.float64).reshape(-1, 1)
    height = np.broadcast_to(height, (h, w))

    # Kinetic energy: KE = 0.5 * density * (vx^2 + vy^2)
    vx = vel_x.astype(np.float64)
    vy = vel_y.astype(np.float64)
    v_squared = vx ** 2 + vy ** 2
    ke_grid = 0.5 * cell_density * v_squared
    ke_grid[~occupied] = 0.0
    kinetic = float(np.sum(ke_grid))

    # Potential energy: PE = density * |gravity| * height
    pe_grid = cell_density * np.abs(cell_gravity) * height
    pe_grid[~occupied] = 0.0
    potential = float(np.sum(pe_grid))

    # Thermal energy: deviation from neutral temperature
    temp_float = temperature.astype(np.float64)
    thermal_grid = np.abs(temp_float - TEMP_NEUTRAL)
    thermal_grid[~occupied] = 0.0
    thermal = float(np.sum(thermal_grid))

    # Chemical energy: sum of fuel potential for flammable elements
    chemical = 0.0
    element_counts = {}
    for el_id in range(NUM_ELEMENTS):
        count = int(np.sum(grid == el_id))
        if count > 0:
            element_counts[el_id] = count
        if el_id in FUEL_ELEMENTS:
            chemical += count * FUEL_ENERGY[el_id]

    total = kinetic + potential + thermal + chemical

    return {
        "kinetic": kinetic,
        "potential": potential,
        "thermal": thermal,
        "chemical": chemical,
        "total": total,
        "element_counts": element_counts,
    }


def compute_entropy(grid, temperature):
    """Compute Shannon entropy of element distribution and temperature variance.

    Parameters
    ----------
    grid : ndarray (H, W) uint8
    temperature : ndarray (H, W) uint8

    Returns
    -------
    dict with keys: element_entropy, temperature_variance, temperature_std
    """
    h, w = grid.shape
    total_cells = h * w

    # Shannon entropy of element distribution
    counts = np.bincount(grid.ravel(), minlength=NUM_ELEMENTS).astype(np.float64)
    probs = counts / total_cells
    probs = probs[probs > 0]
    element_entropy = -float(np.sum(probs * np.log2(probs)))

    # Temperature statistics (occupied cells only)
    occupied = grid != EMPTY
    if np.any(occupied):
        occ_temps = temperature[occupied].astype(np.float64)
        temp_var = float(np.var(occ_temps))
        temp_std = float(np.std(occ_temps))
    else:
        temp_var = 0.0
        temp_std = 0.0

    return {
        "element_entropy": element_entropy,
        "temperature_variance": temp_var,
        "temperature_std": temp_std,
    }


def compute_energy_timeseries(grids, temperatures, vel_xs, vel_ys):
    """Compute energy budget for a series of frames.

    Parameters
    ----------
    grids : list of ndarray (H, W) uint8
    temperatures : list of ndarray (H, W) uint8
    vel_xs : list of ndarray (H, W) int8
    vel_ys : list of ndarray (H, W) int8

    Returns
    -------
    list of energy budget dicts (one per frame)
    """
    return [
        compute_energy_budget(g, t, vx, vy)
        for g, t, vx, vy in zip(grids, temperatures, vel_xs, vel_ys)
    ]


def energy_drift_percent(series):
    """Compute percent change in total energy from first to last frame.

    Returns positive if energy grew, negative if it decreased.
    """
    if len(series) < 2:
        return 0.0
    e0 = series[0]["total"]
    ef = series[-1]["total"]
    if e0 == 0:
        return 0.0 if ef == 0 else float("inf")
    return 100.0 * (ef - e0) / abs(e0)


def max_energy_growth_percent(series):
    """Maximum energy growth relative to initial energy across the series."""
    if len(series) < 2:
        return 0.0
    e0 = series[0]["total"]
    if e0 == 0:
        return 0.0
    return max(100.0 * (s["total"] - e0) / abs(e0) for s in series[1:])
