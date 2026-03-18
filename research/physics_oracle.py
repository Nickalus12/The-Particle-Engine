#!/usr/bin/env python3
"""
Physics Ground Truth Oracle
============================

Generates ground-truth physics values using established Python libraries
(numpy, scipy). Output is JSON consumed by the Dart physics_accuracy.dart
benchmark for comparison against our cellular automaton simulation.

Run:
    pip install -r research/requirements.txt
    python research/physics_oracle.py

Output:
    research/ground_truth.json
"""

import json
import math
import sys

import numpy as np
from scipy.integrate import odeint
from scipy.optimize import curve_fit

# =============================================================================
# Engine scale constants (must match physics_accuracy.dart)
# =============================================================================

FPS = 30.0
DT = 1.0 / FPS
CELL_SIZE_M = 0.01  # 1 cm per cell
REAL_G = 9.81       # m/s^2
TEMP_NEUTRAL = 128  # our 0-255 scale midpoint

# Our engine's element gravity values (cells/frame, applied each frame)
SAND_GRAVITY = 2
WATER_GRAVITY = 1
SAND_MAX_VEL = 3


def generate_ground_truth() -> dict:
    results = {}

    # =========================================================================
    # 1. GRAVITY FREE-FALL TRAJECTORY
    # =========================================================================
    # Real physics: y(t) = 0.5 * g * t^2
    # Our engine: each frame, velY += gravity, clamped to maxVelocity.
    # Total distance = sum of velY over frames.
    #
    # We generate BOTH real-physics and engine-model trajectories.

    frames = list(range(1, 61))

    # Real physics trajectory (continuous)
    real_positions = []
    for f in frames:
        t = f * DT
        d_meters = 0.5 * REAL_G * t * t
        d_cells = d_meters / CELL_SIZE_M
        real_positions.append(round(d_cells, 2))

    # Engine-model trajectory (discrete with velY clamping)
    engine_positions = []
    vel = 0
    pos = 0.0
    for f in frames:
        vel = min(vel + SAND_GRAVITY, SAND_MAX_VEL)
        pos += vel
        engine_positions.append(pos)

    results["gravity_trajectory"] = {
        "frames": frames,
        "real_physics_cells": real_positions,
        "engine_model_cells": engine_positions,
        "g_real_m_s2": REAL_G,
        "g_cells_per_frame2": REAL_G / CELL_SIZE_M / (FPS * FPS),
        "engine_gravity": SAND_GRAVITY,
        "engine_max_velocity": SAND_MAX_VEL,
    }

    # =========================================================================
    # 2. NEWTON'S COOLING CURVE
    # =========================================================================
    # T(t) = T_ambient + (T0 - T_ambient) * exp(-k * t)
    #
    # We solve the ODE numerically and also provide the analytical curve.
    # The cooling constant k is calibrated to our engine's heat conductivity.
    # Stone heatConductivity = 0.5, scaled to 0-255 -> 128.
    # Our engine transfer: (tDiff * min_cond) >> 10, every 3 frames.

    T0 = 250
    T_ambient = TEMP_NEUTRAL  # 128

    # Calibrate k from our engine's diffusion model:
    # Stone conductivity = 0.5 -> heatCond = 128 (out of 255)
    # Transfer per tick ~ (T_diff * 128) / 1024 ~ T_diff * 0.125
    # This fires every 3 frames, so effective rate ~ 0.125/3 ~ 0.042 per frame
    k = 0.042

    sample_frames = list(range(0, 301, 10))

    # Analytical solution
    analytical_temps = []
    for f in sample_frames:
        T = T_ambient + (T0 - T_ambient) * math.exp(-k * f)
        analytical_temps.append(round(T, 2))

    # ODE solution for verification
    def cooling_ode(T, t, k, T_amb):
        return -k * (T[0] - T_amb)

    t_span = np.array(sample_frames, dtype=float)
    ode_solution = odeint(cooling_ode, [T0], t_span, args=(k, T_ambient))
    ode_temps = [round(float(T[0]), 2) for T in ode_solution]

    results["cooling_curve"] = {
        "frames": sample_frames,
        "analytical_temps": analytical_temps,
        "ode_temps": ode_temps,
        "T_initial": T0,
        "T_ambient": T_ambient,
        "k": k,
        "equation": "T(t) = T_amb + (T0 - T_amb) * exp(-k*t)",
    }

    # =========================================================================
    # 3. DENSITY ORDERING (Real-world kg/m^3)
    # =========================================================================

    real_densities = {
        "metal": 7800,    # steel
        "stone": 2700,    # granite
        "glass": 2500,    # soda-lime glass
        "sand": 1600,     # quartz sand
        "dirt": 1500,     # topsoil
        "mud": 1300,      # wet mud
        "water": 1000,
        "oil": 800,       # motor oil
        "ice": 917,       # water ice
        "wood": 600,      # softwood
        "ash": 200,       # volcanic ash
        "snow": 100,      # fresh snow
    }

    # Our engine's density values (from element_registry.dart)
    our_densities = {
        "metal": 240,
        "stone": 255,   # NOTE: stone > metal in our engine (inaccurate)
        "glass": 220,
        "sand": 150,
        "dirt": 145,
        "mud": 120,
        "water": 100,
        "oil": 80,
        "ice": 90,
        "wood": 85,
        "ash": 30,
        "snow": 50,
    }

    # Expected ordering (heaviest first)
    real_order = sorted(real_densities.keys(), key=lambda x: -real_densities[x])
    our_order = sorted(our_densities.keys(), key=lambda x: -our_densities[x])

    # Kendall tau distance between orderings
    def kendall_distance(a, b):
        """Count pairwise inversions between two orderings."""
        pos_b = {v: i for i, v in enumerate(b)}
        inversions = 0
        total = 0
        for i in range(len(a)):
            for j in range(i + 1, len(a)):
                if a[i] in pos_b and a[j] in pos_b:
                    total += 1
                    if pos_b[a[i]] > pos_b[a[j]]:
                        inversions += 1
        return inversions, total

    inv, total = kendall_distance(real_order, our_order)

    results["density_ordering"] = {
        "real_densities_kg_m3": real_densities,
        "our_densities_0_255": our_densities,
        "real_order": real_order,
        "our_order": our_order,
        "kendall_inversions": inv,
        "kendall_total_pairs": total,
        "ordering_accuracy": round(1.0 - inv / max(total, 1), 4),
    }

    # =========================================================================
    # 4. ANGLE OF REPOSE (real values in degrees)
    # =========================================================================

    # scipy geometry: tan(angle) = height/halfWidth
    # Sand: typical 34 degrees -> tan(34 deg) ~ 0.6745
    angle_data = {
        "sand": {
            "min": 30, "max": 35, "typical": 34,
            "tan_typical": round(math.tan(math.radians(34)), 4),
        },
        "dirt": {
            "min": 35, "max": 45, "typical": 40,
            "tan_typical": round(math.tan(math.radians(40)), 4),
        },
        "snow": {
            "min": 35, "max": 45, "typical": 38,
            "tan_typical": round(math.tan(math.radians(38)), 4),
        },
        "ash": {
            "min": 30, "max": 40, "typical": 35,
            "tan_typical": round(math.tan(math.radians(35)), 4),
        },
    }
    angle_data["note"] = "Cellular automata with 8-connectivity have a natural 45-deg bias"

    results["angle_of_repose"] = angle_data

    # =========================================================================
    # 5. VISCOSITY RATIOS (real-world Pa*s)
    # =========================================================================

    real_viscosity = {
        "water": 0.001,       # 1 mPa*s at 20C
        "oil": 0.03,          # ~30 mPa*s (motor oil SAE 10)
        "mud": 0.1,           # ~100 mPa*s (thick slurry)
        "lava": 100.0,        # basaltic lava ~100 Pa*s
    }

    # Our engine viscosity values (1-10 scale, frames between lateral moves)
    our_viscosity = {
        "water": 1,
        "oil": 2,
        "mud": 3,
        "lava": 4,
    }

    # Expected flow speed ratios relative to water (inverse of viscosity ratio)
    flow_ratios = {}
    for name, visc in real_viscosity.items():
        flow_ratios[name] = round(real_viscosity["water"] / visc, 6)

    results["viscosity"] = {
        "real_viscosity_pa_s": real_viscosity,
        "our_viscosity_1_10": our_viscosity,
        "expected_flow_ratio_vs_water": flow_ratios,
        "expected_spread_ordering": ["water", "oil", "mud", "lava"],
        "note": "Real lava is 100000x more viscous than water; our 4:1 ratio is a game-feel compression",
    }

    # =========================================================================
    # 6. PHASE CHANGE TEMPERATURES
    # =========================================================================

    phase_changes = {
        "water_freeze": {
            "real_C": 0,
            "our_threshold": 113,
            "our_freezePoint": 30,
            "element": "water",
            "becomes": "ice",
        },
        "water_boil": {
            "real_C": 100,
            "our_threshold": 218,
            "our_boilPoint": 180,
            "element": "water",
            "becomes": "steam",
        },
        "ice_melt": {
            "real_C": 0,
            "our_threshold": 148,
            "our_meltPoint": 40,
            "element": "ice",
            "becomes": "water",
        },
        "sand_melt": {
            "real_C": 1700,
            "our_threshold": 252,
            "our_meltPoint": 248,
            "element": "sand",
            "becomes": "glass",
        },
        "stone_melt": {
            "real_C": 1200,
            "our_threshold": 238,
            "our_meltPoint": 220,
            "element": "stone",
            "becomes": "lava",
        },
        "metal_melt": {
            "real_C": 1500,
            "our_threshold": 248,
            "our_meltPoint": 240,
            "element": "metal",
            "becomes": "lava",
        },
        "snow_melt": {
            "real_C": 0,
            "our_threshold": 153,
            "our_meltPoint": 50,
            "element": "snow",
            "becomes": "water",
        },
        "lava_freeze": {
            "real_C": 700,
            "our_threshold": 98,
            "our_freezePoint": 60,
            "element": "lava",
            "becomes": "stone",
        },
    }

    results["phase_changes"] = phase_changes

    # =========================================================================
    # 7. THERMAL CONDUCTIVITY (real W/m*K)
    # =========================================================================

    real_conductivity = {
        "metal": 50.0,      # steel ~50 W/m*K
        "stone": 2.5,       # granite ~2.5
        "water": 0.6,       # water ~0.6
        "ice": 2.2,         # ice ~2.2
        "glass": 1.0,       # glass ~1.0
        "wood": 0.15,       # wood ~0.15
        "sand": 0.25,       # sand ~0.25
        "dirt": 0.5,        # soil ~0.5
        "oil": 0.15,        # oil ~0.15
        "air": 0.025,       # air ~0.025
    }

    our_conductivity = {
        "metal": 0.9,
        "stone": 0.5,
        "water": 0.4,
        "ice": 0.6,
        "glass": 0.4,
        "wood": 0.1,
        "sand": 0.3,
        "dirt": 0.2,
        "oil": 0.15,
        "air": 0.02,
    }

    # Check if the ordering matches (most to least conductive)
    real_order_cond = sorted(real_conductivity.keys(),
                             key=lambda x: -real_conductivity[x])
    our_order_cond = sorted(our_conductivity.keys(),
                            key=lambda x: -our_conductivity[x])

    results["thermal_conductivity"] = {
        "real_W_per_mK": real_conductivity,
        "our_0_to_1": our_conductivity,
        "real_ordering": real_order_cond,
        "our_ordering": our_order_cond,
    }

    # =========================================================================
    # 8. TORRICELLI OUTFLOW VELOCITY
    # =========================================================================
    # v = sqrt(2 * g * h)
    # In our grid with g ~ 1 cell/frame^2:

    g_eff = 1.0  # effective gravity for water in cells/frame^2
    heights = [5, 10, 15, 20, 25, 30]
    velocities = [round(math.sqrt(2 * g_eff * h), 3) for h in heights]

    results["torricelli"] = {
        "heights_cells": heights,
        "expected_velocity_cells_per_frame": velocities,
        "g_effective": g_eff,
        "equation": "v = sqrt(2 * g * h)",
        "note": "Ratio between heights is key: v(h1)/v(h2) = sqrt(h1/h2)",
    }

    # =========================================================================
    # 9. PRESSURE AT DEPTH (Pascal's Law)
    # =========================================================================
    # P = rho * g * h (linear with depth)

    depths = list(range(1, 51))
    expected_pressure = [d for d in depths]  # p = d (our simple model)

    results["pressure_depth"] = {
        "depths_cells": depths,
        "expected_pressure": expected_pressure,
        "equation": "P = depth (our model: column count)",
        "real_equation": "P = rho * g * h",
        "note": "Our model is linear by construction; test validates implementation",
    }

    # =========================================================================
    # 10. EXPLOSION ENERGY FALLOFF (Inverse Square Law)
    # =========================================================================
    # E(r) proportional to 1/r^2

    distances = list(range(1, 16))
    inv_square = [round(1.0 / (d * d), 6) for d in distances]

    results["explosion_falloff"] = {
        "distances": distances,
        "expected_energy_ratio": inv_square,
        "equation": "E(r) = E0 / r^2",
    }

    # =========================================================================
    # 11. FOURIER HEAT CONDUCTION (1D steady-state)
    # =========================================================================

    T_hot = 250  # lava
    T_amb = 128  # neutral
    L = 30       # length of stone chain in cells

    # Steady-state linear gradient
    x_positions = list(range(0, L))
    steady_state = [round(T_hot - (T_hot - T_amb) * x / L, 2) for x in x_positions]

    # Transient solution using Fourier series (first 10 terms)
    alpha = 0.001  # thermal diffusivity (arbitrary units)
    t_frames = 300  # simulation frames

    transient_profile = []
    for x in x_positions:
        T = T_amb + (T_hot - T_amb) * (1 - x / L)
        correction = 0
        for n in range(1, 11):
            coeff = 2 * (T_hot - T_amb) / (n * math.pi)
            correction += coeff * math.sin(n * math.pi * x / L) * \
                          math.exp(-alpha * (n * math.pi / L) ** 2 * t_frames)
        T -= correction
        transient_profile.append(round(T, 2))

    results["heat_conduction"] = {
        "x_positions": x_positions,
        "steady_state_temps": steady_state,
        "transient_profile_300frames": transient_profile,
        "T_hot": T_hot,
        "T_ambient": T_amb,
        "chain_length": L,
        "equation": "Fourier: q = -k * dT/dx",
        "key_property": "monotonically_decreasing_from_source",
    }

    # =========================================================================
    # 12. BUOYANCY CLASSIFICATION
    # =========================================================================

    buoyancy = {}
    for name, dens in real_densities.items():
        if name == "water":
            continue
        buoyancy[name] = {
            "real_density_kg_m3": dens,
            "water_density_kg_m3": 1000,
            "should_sink": dens > 1000,
            "should_float": dens < 1000,
        }

    results["buoyancy"] = buoyancy

    # =========================================================================
    # 13. CONNECTED VESSELS EQUILIBRIUM
    # =========================================================================

    results["connected_vessels"] = {
        "principle": "Water seeks same level in connected vessels",
        "expected_level_difference": 0,
        "tolerance_cells": 2,
        "equation": "Pascal: P = rho*g*h constant at connection point",
    }

    # =========================================================================
    # 14. U-TUBE WITH DIFFERENT FLUIDS
    # =========================================================================

    rho_water = 1000
    rho_oil = 800
    height_ratio = rho_water / rho_oil  # oil column should be 1.25x taller

    results["u_tube_fluids"] = {
        "water_density": rho_water,
        "oil_density": rho_oil,
        "expected_oil_to_water_height_ratio": round(height_ratio, 4),
        "equation": "h_oil / h_water = rho_water / rho_oil",
        "our_density_water": 100,
        "our_density_oil": 80,
        "our_expected_ratio": round(100 / 80, 4),
    }

    # =========================================================================
    # 15. FIRE TRIANGLE REQUIREMENTS
    # =========================================================================

    results["fire_triangle"] = {
        "requirements": ["fuel", "oxygen", "heat"],
        "flammable_materials": ["wood", "oil", "plant", "seed"],
        "non_flammable": ["stone", "metal", "glass", "water", "sand"],
        "expected_behaviors": {
            "fire_without_fuel": "extinguishes (decays to smoke/empty)",
            "fire_with_wood": "spreads to wood",
            "fire_with_stone": "stone unchanged",
            "fire_with_oil": "rapid chain ignition",
        },
    }

    # =========================================================================
    # 16. MASS CONSERVATION
    # =========================================================================

    results["conservation_mass"] = {
        "principle": "In a closed system with no reactions, total cell count is constant",
        "expected_drift": 0,
        "tolerance_percent": 1.0,
    }

    # =========================================================================
    # 17. ENERGY CONSERVATION (Temperature)
    # =========================================================================

    results["conservation_energy"] = {
        "principle": "Without heat sources/sinks, total thermal energy is constant",
        "expected_drift_percent": 0,
        "tolerance_percent": 5.0,
        "note": "Our engine has inherent dissipation from integer rounding in heat transfer",
    }

    # =========================================================================
    # 18. BEVERLOO EQUATION (Hourglass Flow)
    # =========================================================================
    # Q = C * rho * sqrt(g) * (D - k*d)^(5/2)

    def beverloo_flow(D, d=1, k=1.4, C=0.58, g=1.0):
        effective = D - k * d
        if effective <= 0:
            return 0
        return C * math.sqrt(g) * effective ** 2.5

    openings = [1, 2, 3, 4, 5]
    flows = [round(beverloo_flow(D), 4) for D in openings]

    results["beverloo"] = {
        "openings_cells": openings,
        "expected_relative_flow": flows,
        "equation": "Q = C * sqrt(g) * (D - k*d)^(5/2)",
        "note": "1-cell opening has zero Beverloo flow; CA always allows it",
    }

    # =========================================================================
    # 19. ACID DISSOLUTION (Surface Area Dependence)
    # =========================================================================

    results["acid_dissolution"] = {
        "principle": "Dissolution time proportional to thickness",
        "expected_ratio_3x_to_1x": 3.0,
        "tolerance": 1.5,
        "equation": "rate ~ surface_area * concentration",
    }

    # =========================================================================
    # 20. THERMAL STRATIFICATION
    # =========================================================================

    results["thermal_stratification"] = {
        "principle": "Hot water rises above cold water (convection)",
        "expected_ordering": "temperature decreases from top to bottom",
        "mechanism": "buoyancy-driven convection",
    }

    # =========================================================================
    # 21. MOMENTUM CONSERVATION
    # =========================================================================

    results["conservation_momentum"] = {
        "principle": "In a symmetric system, net horizontal momentum should be zero",
        "expected_net_horizontal_momentum": 0,
        "tolerance": 1,
        "note": "Symmetric sand drop should preserve zero net horizontal momentum",
    }

    # =========================================================================
    # 22. FIRE SPREAD RATE
    # =========================================================================
    # Fire spreading through uniform fuel should have roughly constant velocity.
    # Model: constant-velocity front in 1D, v ~ sqrt(k * alpha) where k is
    # reaction rate and alpha is thermal diffusivity.

    results["fire_spread"] = {
        "principle": "Fire in uniform fuel propagates at roughly constant velocity",
        "expected_cv_below": 0.5,
        "note": "Coefficient of variation of velocity < 0.5 means roughly constant",
        "equation": "v_front ~ sqrt(k * alpha) (Fisher-KPP reaction-diffusion)",
    }

    # =========================================================================
    # 23. FLASH POINT ORDERING
    # =========================================================================
    # Arrhenius equation: k = A * exp(-Ea / (R*T))
    # Oil has lower activation energy (easier ignition) than wood.

    R_gas = 8.314  # J/(mol*K)
    # Approximate activation energies for ignition
    Ea_oil = 50000.0   # J/mol (~50 kJ/mol for light hydrocarbons)
    Ea_wood = 120000.0  # J/mol (~120 kJ/mol for cellulose pyrolysis)
    A = 1e10  # pre-exponential factor (same for comparison)
    T_flame = 800 + 273.15  # flame temperature in K

    k_oil = A * math.exp(-Ea_oil / (R_gas * T_flame))
    k_wood = A * math.exp(-Ea_wood / (R_gas * T_flame))

    results["flash_point"] = {
        "principle": "Oil ignites faster than wood (lower activation energy)",
        "expected_ordering": ["oil", "wood"],
        "arrhenius_rate_oil": round(k_oil, 4),
        "arrhenius_rate_wood": round(k_wood, 4),
        "rate_ratio_oil_to_wood": round(k_oil / max(k_wood, 1e-30), 2),
        "equation": "k = A * exp(-Ea / (R*T))",
        "Ea_oil_J_per_mol": Ea_oil,
        "Ea_wood_J_per_mol": Ea_wood,
    }

    # =========================================================================
    # 24. JAMMING TRANSITION
    # =========================================================================

    results["jamming_transition"] = {
        "principle": "Granular materials can form arches over narrow openings",
        "expected_jam_probability_1cell": 0.5,
        "note": "With 1-cell opening, expect intermittent jamming (some trials jam, some don't)",
        "reference": "Zuriguel et al., Physical Review Letters (2005)",
    }

    # =========================================================================
    # 25. GRADED BEDDING
    # =========================================================================
    # Stokes' law for terminal velocity in fluid:
    # v_t = (2/9) * (rho_p - rho_f) * g * r^2 / eta
    # Denser particles settle faster.

    rho_f = 1000.0  # water density kg/m^3
    eta = 0.001     # water viscosity Pa*s
    g = 9.81
    r_particle = 0.005  # 5mm particle radius

    rho_sand = 1600.0
    rho_dirt = 1500.0

    vt_sand = (2.0 / 9.0) * (rho_sand - rho_f) * g * r_particle**2 / eta
    vt_dirt = (2.0 / 9.0) * (rho_dirt - rho_f) * g * r_particle**2 / eta

    results["graded_bedding"] = {
        "principle": "Denser particles settle faster in fluid (Stokes' law)",
        "stokes_vt_sand_m_s": round(vt_sand, 4),
        "stokes_vt_dirt_m_s": round(vt_dirt, 4),
        "expected_settling_order": ["sand", "dirt"],
        "equation": "v_t = (2/9) * (rho_p - rho_f) * g * r^2 / eta",
        "note": "Sand (1600 kg/m3) should settle below dirt (1500 kg/m3)",
    }

    # =========================================================================
    # 26. DOMINO CASCADE TIMING
    # =========================================================================
    # Free-fall time: t = sqrt(2*h/g)
    # For h=20 cells at engine gravity=2 cells/frame^2 with maxVel=3:
    # Discrete: frames needed for sand to fall 20 cells

    fall_height = 20  # cells
    # Discrete engine model
    v = 0
    d = 0
    fall_frames = 0
    while d < fall_height:
        v = min(v + SAND_GRAVITY, SAND_MAX_VEL)
        d += v
        fall_frames += 1

    results["domino_cascade"] = {
        "principle": "Unsupported elements fall progressively, not instantly",
        "expected_fall_frames_20cells": fall_frames,
        "expected_min_frames": 3,
        "expected_max_frames": 30,
        "note": "Collapse should take multiple frames (finite gravity, not teleportation)",
    }

    # =========================================================================
    # 27. THERMAL EQUILIBRIUM (Calorimetry)
    # =========================================================================
    # T_eq = (m1*c1*T1 + m2*c2*T2) / (m1*c1 + m2*c2)
    # Hot stone (c=0.84 kJ/kg*K) in cold stone

    # In our engine: same material, so c1 = c2
    # T_eq = (n1*T1 + n2*T2) / (n1 + n2)
    # Left half: 11 cols * 13 rows = 143 cells at T=220
    # Right half: 12 cols * 13 rows = 156 cells at T=36
    n1 = 143
    T1 = 220
    n2 = 156
    T2 = 36

    T_eq = (n1 * T1 + n2 * T2) / (n1 + n2)

    results["thermal_equilibrium"] = {
        "principle": "Hot + cold objects reach weighted-average equilibrium temperature",
        "expected_T_eq": round(T_eq, 2),
        "n_hot_cells": n1,
        "T_hot": T1,
        "n_cold_cells": n2,
        "T_cold": T2,
        "equation": "T_eq = (n1*T1 + n2*T2) / (n1 + n2)",
        "expected_spread_zero": True,
        "note": "Same material: heat capacity cancels; equilibrium is cell-count weighted average",
    }

    # =========================================================================
    # 28. CAPILLARY WICKING (Washburn equation)
    # =========================================================================
    # L^2 = (gamma * r * cos(theta) * t) / (2 * eta)
    # For water in dirt pores:
    #   gamma = 0.072 N/m (surface tension of water)
    #   r ~ 0.001 m (pore radius, ~1mm)
    #   theta ~ 0 degrees (complete wetting)
    #   eta = 0.001 Pa*s (water viscosity)

    gamma = 0.072  # N/m
    r_pore = 0.001  # m
    theta = 0  # degrees (complete wetting)
    eta_w = 0.001  # Pa*s

    # Wicking distance over time
    times_s = [0.1, 0.5, 1.0, 2.0, 5.0, 10.0]
    wicking_distances = []
    for t in times_s:
        L_sq = (gamma * r_pore * math.cos(math.radians(theta)) * t) / (2 * eta_w)
        L = math.sqrt(max(L_sq, 0))
        wicking_distances.append(round(L * 100, 4))  # convert to cm

    results["capillary_wicking"] = {
        "principle": "Porous materials absorb water against gravity via capillary action",
        "washburn_equation": "L^2 = (gamma * r * cos(theta) * t) / (2 * eta)",
        "gamma_N_per_m": gamma,
        "pore_radius_m": r_pore,
        "contact_angle_deg": theta,
        "viscosity_Pa_s": eta_w,
        "times_s": times_s,
        "wicking_distance_cm": wicking_distances,
        "note": "In our engine, dirt porosity=0.6 should absorb water, forming mud",
    }

    # =========================================================================
    # 29. HYDROSTATIC PARADOX
    # =========================================================================

    results["hydrostatic_paradox"] = {
        "principle": "Pressure at bottom depends only on height, not container shape",
        "expected_pressure_difference": 0,
        "tolerance": 2,
        "equation": "P = rho * g * h (independent of container width)",
        "note": "Narrow and wide columns of same height should have equal bottom pressure",
    }

    # =========================================================================
    # 30. RIPPLE DAMPING
    # =========================================================================

    results["ripple_damping"] = {
        "principle": "Surface disturbances should decay over time, not amplify",
        "expected_late_less_than_early": True,
        "mechanism": "Viscous dissipation damps water surface waves",
        "note": "Late variance should be less than early variance after disturbance",
    }

    # =========================================================================
    # 31. LOAD DISTRIBUTION
    # =========================================================================

    results["load_distribution"] = {
        "principle": "Taller liquid column exerts more pressure at base",
        "expected_pressure_ratio": 3.0,
        "tall_height": 30,
        "short_height": 10,
        "equation": "P_tall / P_short = h_tall / h_short",
    }

    return results


def print_summary(results: dict):
    """Print a human-readable summary of the ground truth."""
    print("=" * 60)
    print("  Physics Ground Truth Oracle")
    print("=" * 60)
    print()

    # Gravity
    gt = results["gravity_trajectory"]
    print(f"Gravity: g_real = {gt['g_real_m_s2']} m/s^2")
    print(f"  -> {gt['g_cells_per_frame2']:.3f} cells/frame^2")
    print(f"  Engine uses gravity={gt['engine_gravity']}, maxVel={gt['engine_max_velocity']}")
    print(f"  After 30 frames: real={gt['real_physics_cells'][29]:.0f} cells, "
          f"engine model={gt['engine_model_cells'][29]:.0f} cells")
    print()

    # Density
    do = results["density_ordering"]
    print(f"Density ordering accuracy: {do['ordering_accuracy']*100:.1f}%")
    print(f"  Real:  {' > '.join(do['real_order'][:5])}...")
    print(f"  Ours:  {' > '.join(do['our_order'][:5])}...")
    print(f"  Kendall inversions: {do['kendall_inversions']}/{do['kendall_total_pairs']}")
    print()

    # Viscosity
    v = results["viscosity"]
    print("Viscosity ratios (flow speed relative to water):")
    for name, ratio in v["expected_flow_ratio_vs_water"].items():
        our_v = v["our_viscosity_1_10"][name]
        print(f"  {name:8s}: real={ratio:.6f}x, our viscosity={our_v}")
    print()

    # Cooling
    cc = results["cooling_curve"]
    print(f"Cooling curve: T0={cc['T_initial']}, T_amb={cc['T_ambient']}, k={cc['k']}")
    print(f"  At frame 100: analytical={cc['analytical_temps'][10]:.1f}, "
          f"ODE={cc['ode_temps'][10]:.1f}")
    print(f"  At frame 300: analytical={cc['analytical_temps'][-1]:.1f}")
    print()

    # Thermal equilibrium
    te = results["thermal_equilibrium"]
    print(f"Thermal equilibrium: T_eq = {te['expected_T_eq']}")
    print(f"  {te['n_hot_cells']} cells at T={te['T_hot']} + "
          f"{te['n_cold_cells']} cells at T={te['T_cold']}")
    print()

    # Flash point
    fp = results["flash_point"]
    print(f"Flash point: oil/wood rate ratio = {fp['rate_ratio_oil_to_wood']}")
    print(f"  Arrhenius: k_oil={fp['arrhenius_rate_oil']:.4f}, k_wood={fp['arrhenius_rate_wood']:.4f}")
    print()

    # Graded bedding (Stokes)
    gb = results["graded_bedding"]
    print(f"Graded bedding (Stokes): sand vt={gb['stokes_vt_sand_m_s']:.4f} m/s, "
          f"dirt vt={gb['stokes_vt_dirt_m_s']:.4f} m/s")
    print()

    # U-tube
    ut = results["u_tube_fluids"]
    print(f"U-tube: oil/water height ratio = {ut['expected_oil_to_water_height_ratio']}")
    print(f"  Our density ratio: {ut['our_expected_ratio']}")
    print()

    # Beverloo
    bv = results["beverloo"]
    print("Beverloo hourglass flow:")
    for i, D in enumerate(bv["openings_cells"]):
        print(f"  Opening {D} cells: relative flow = {bv['expected_relative_flow'][i]:.4f}")
    print()

    # Capillary
    cw = results["capillary_wicking"]
    print("Capillary wicking (Washburn):")
    for i, t in enumerate(cw["times_s"]):
        print(f"  t={t}s: L={cw['wicking_distance_cm'][i]:.4f} cm")
    print()

    print(f"Total categories: {len(results)}")


if __name__ == "__main__":
    truth = generate_ground_truth()

    # Write to JSON
    output_path = "research/ground_truth.json"
    with open(output_path, "w") as f:
        json.dump(truth, f, indent=2, default=float)

    print_summary(truth)
    print(f"\nSaved to {output_path}")
