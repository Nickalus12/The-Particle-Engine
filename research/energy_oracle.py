"""
Energy Oracle
==============

Computes expected energy behavior using scipy for comparison against
the simulation engine. Generates analytical curves for:
  - Free-fall PE->KE conversion
  - Newton cooling thermal redistribution
  - Combustion chemical->thermal conversion

Output is merged into ground_truth.json under the "energy_conservation" key.

Usage:
    python research/energy_oracle.py
"""

import json
import math
from pathlib import Path

import numpy as np
from scipy.integrate import odeint

# Engine constants (must match physics_oracle.py / element_registry.dart)
FPS = 30.0
DT = 1.0 / FPS
CELL_SIZE_M = 0.01   # 1 cm per cell
REAL_G = 9.81         # m/s^2
TEMP_NEUTRAL = 128


def expected_free_fall_energy(density, gravity_cells, height_cells, num_frames):
    """Compute PE and KE during ideal free fall in cell units.

    In the simulation, gravity is applied as cell-per-frame velocity increment.
    PE(t) = density * |g| * (h0 - y(t))
    KE(t) = 0.5 * density * vy(t)^2
    Total = PE + KE should remain constant (ideal case, no drag).

    Parameters
    ----------
    density : float
        Element density (0-255 scale).
    gravity_cells : float
        Gravity strength in cells/frame^2 (positive = falls).
    height_cells : float
        Initial height above ground in cells.
    num_frames : int
        Number of frames to simulate.

    Returns
    -------
    dict with keys: frames, pe, ke, total
    """
    g = abs(gravity_cells)
    frames = list(range(num_frames))
    pe = []
    ke = []
    total = []

    for t in frames:
        # Position: y(t) = 0.5 * g * t^2 (cells fallen from start)
        y_fallen = min(0.5 * g * t * t, height_cells)
        remaining_height = height_cells - y_fallen

        # Velocity: v(t) = g * t (cells/frame)
        if y_fallen < height_cells:
            vy = g * t
        else:
            vy = 0  # hit ground

        p = density * g * remaining_height
        k = 0.5 * density * vy * vy

        pe.append(p)
        ke.append(k)
        total.append(p + k)

    return {"frames": frames, "pe": pe, "ke": ke, "total": total}


def expected_cooling_energy(T_hot, T_ambient, k, num_frames):
    """Compute thermal energy during Newton cooling.

    dT/dt = -k * (T - T_ambient)
    Thermal energy = |T(t) - T_neutral|

    Parameters
    ----------
    T_hot : float
        Initial temperature (0-255 scale).
    T_ambient : float
        Ambient temperature.
    k : float
        Cooling rate constant.
    num_frames : int
        Number of frames.

    Returns
    -------
    dict with keys: frames, temperatures, thermal_energy
    """
    frames = list(range(num_frames))
    temps = []
    thermal_e = []

    for t in frames:
        T = T_ambient + (T_hot - T_ambient) * math.exp(-k * t)
        temps.append(T)
        thermal_e.append(abs(T - TEMP_NEUTRAL))

    return {"frames": frames, "temperatures": temps, "thermal_energy": thermal_e}


def expected_cooling_ode(T_hot, T_ambient, k, num_frames):
    """Same as above but solved with scipy ODE integrator for validation."""

    def dTdt(T, t):
        return -k * (T[0] - T_ambient)

    t_span = np.linspace(0, num_frames - 1, num_frames)
    sol = odeint(dTdt, [T_hot], t_span)
    temps = sol[:, 0].tolist()
    thermal_e = [abs(T - TEMP_NEUTRAL) for T in temps]

    return {"frames": list(range(num_frames)), "temperatures": temps, "thermal_energy": thermal_e}


def expected_combustion_energy(fuel_count, fuel_energy, heat_per_unit, burn_rate_frames):
    """Compute energy transfer during combustion.

    Chemical energy decreases as fuel burns. Thermal energy increases.
    Total (chemical + thermal) should be approximately conserved.

    Parameters
    ----------
    fuel_count : int
        Number of fuel cells.
    fuel_energy : float
        Chemical energy per fuel cell.
    heat_per_unit : float
        Thermal energy released per fuel cell burned.
    burn_rate_frames : int
        Frames to burn one fuel cell.

    Returns
    -------
    dict with keys: frames, chemical, thermal, total
    """
    total_chemical = fuel_count * fuel_energy
    frames = []
    chemical = []
    thermal = []
    total = []

    remaining_fuel = fuel_count
    accumulated_heat = 0.0

    for f in range(fuel_count * burn_rate_frames + 1):
        frames.append(f)
        chem = remaining_fuel * fuel_energy
        chemical.append(chem)
        thermal.append(accumulated_heat)
        total.append(chem + accumulated_heat)

        if f > 0 and f % burn_rate_frames == 0 and remaining_fuel > 0:
            remaining_fuel -= 1
            accumulated_heat += heat_per_unit

    return {"frames": frames, "chemical": chemical, "thermal": thermal, "total": total}


def expected_entropy_increase(initial_ordered_fraction, num_frames, mixing_rate=0.01):
    """Model entropy increase as ordered elements mix into disordered state.

    Shannon entropy of a two-state system increases as it approaches 50/50 mix.

    Parameters
    ----------
    initial_ordered_fraction : float
        Initial fraction of cells in "ordered" state (0-1).
    num_frames : int
        Number of frames.
    mixing_rate : float
        Rate at which ordered fraction approaches 0.5.

    Returns
    -------
    dict with keys: frames, entropy (in bits)
    """
    frames = list(range(num_frames))
    entropies = []

    for t in frames:
        # Ordered fraction decays toward 0.5 (maximum disorder)
        p = 0.5 + (initial_ordered_fraction - 0.5) * math.exp(-mixing_rate * t)
        q = 1.0 - p
        if p > 0 and q > 0:
            H = -(p * math.log2(p) + q * math.log2(q))
        else:
            H = 0.0
        entropies.append(H)

    return {"frames": frames, "entropy": entropies}


def generate_energy_ground_truth():
    """Generate all energy conservation ground truth data."""
    results = {}

    # 1. Free-fall energy conservation (sand, density=150, gravity=2, height=50)
    results["free_fall_sand"] = expected_free_fall_energy(
        density=150, gravity_cells=2, height_cells=50, num_frames=30
    )

    # 2. Free-fall for water (density=100, gravity=1, height=30)
    results["free_fall_water"] = expected_free_fall_energy(
        density=100, gravity_cells=1, height_cells=30, num_frames=60
    )

    # 3. Cooling energy redistribution (hot metal block cooling)
    k_metal = 0.9 * 0.1  # heatCond * coupling factor
    results["cooling_metal"] = expected_cooling_energy(
        T_hot=230, T_ambient=TEMP_NEUTRAL, k=k_metal, num_frames=200
    )
    results["cooling_metal_ode"] = expected_cooling_ode(
        T_hot=230, T_ambient=TEMP_NEUTRAL, k=k_metal, num_frames=200
    )

    # 4. Cooling for wood (slow conductor)
    k_wood = 0.1 * 0.1
    results["cooling_wood"] = expected_cooling_energy(
        T_hot=200, T_ambient=TEMP_NEUTRAL, k=k_wood, num_frames=500
    )

    # 5. Combustion energy transfer (10 wood cells burning)
    results["combustion_wood"] = expected_combustion_energy(
        fuel_count=10, fuel_energy=500.0, heat_per_unit=450.0,
        burn_rate_frames=20
    )

    # 6. Combustion: oil (higher energy density)
    results["combustion_oil"] = expected_combustion_energy(
        fuel_count=10, fuel_energy=800.0, heat_per_unit=720.0,
        burn_rate_frames=10
    )

    # 7. Entropy increase from ordered initial state
    results["entropy_mixing"] = expected_entropy_increase(
        initial_ordered_fraction=0.9, num_frames=500, mixing_rate=0.01
    )

    # 8. Thresholds and constraints
    results["thresholds"] = {
        "max_total_growth_percent": 5.0,
        "equilibrium_threshold_frames": 3000,
        "second_law_holds": True,
        "max_pe_ke_error_percent": 10.0,
        "cooling_convergence_threshold": 5.0,
    }

    return results


def main():
    gt_path = Path(__file__).parent / "ground_truth.json"

    if gt_path.exists():
        with open(gt_path) as f:
            gt = json.load(f)
    else:
        gt = {}

    gt["energy_conservation"] = generate_energy_ground_truth()

    with open(gt_path, "w") as f:
        json.dump(gt, f, indent=2)

    print(f"Energy ground truth written to {gt_path}")
    print(f"  Keys: {list(gt['energy_conservation'].keys())}")


if __name__ == "__main__":
    main()
