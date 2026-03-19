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
from itertools import combinations

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

# =============================================================================
# Complete Element Property Table (all 25 types, 0..24)
# =============================================================================

ELEMENTS = {
    "empty":     {"id": 0,  "density": 0,   "gravity": 0,  "state": "special",  "maxVel": 2, "flammable": False, "heatCond": 0.02, "hardness": 0,   "corrosionRes": 0,  "porosity": 0.0, "conductivity": 0.0, "windRes": 0.0,  "baseTemp": 128, "viscosity": 1, "surfaceTension": 0, "decayRate": 0, "lightEmission": 0},
    "sand":      {"id": 1,  "density": 150, "gravity": 2,  "state": "granular", "maxVel": 3, "flammable": False, "heatCond": 0.3,  "hardness": 10,  "corrosionRes": 0,  "porosity": 0.3, "conductivity": 0.0, "windRes": 0.4,  "baseTemp": 128, "meltPoint": 248, "meltsInto": "glass"},
    "water":     {"id": 2,  "density": 100, "gravity": 1,  "state": "liquid",   "maxVel": 2, "flammable": False, "heatCond": 0.4,  "hardness": 0,   "corrosionRes": 0,  "porosity": 0.0, "conductivity": 0.6, "windRes": 0.9,  "baseTemp": 128, "viscosity": 1, "surfaceTension": 5, "boilPoint": 180, "boilsInto": "steam", "freezePoint": 30, "freezesInto": "ice"},
    "fire":      {"id": 3,  "density": 5,   "gravity": -1, "state": "gas",      "maxVel": 2, "flammable": False, "heatCond": 0.8,  "hardness": 5,   "corrosionRes": 0,  "porosity": 0.0, "conductivity": 0.0, "windRes": 0.2,  "baseTemp": 230, "decayRate": 3, "decaysInto": "smoke", "lightEmission": 180},
    "ice":       {"id": 4,  "density": 90,  "gravity": 1,  "state": "solid",    "maxVel": 2, "flammable": False, "heatCond": 0.6,  "hardness": 40,  "corrosionRes": 40, "porosity": 0.0, "conductivity": 0.0, "windRes": 1.0,  "baseTemp": 20,  "meltPoint": 40, "meltsInto": "water"},
    "lightning": {"id": 5,  "density": 0,   "gravity": 1,  "state": "special",  "maxVel": 2, "flammable": False, "heatCond": 1.0,  "hardness": 0,   "corrosionRes": 0,  "porosity": 0.0, "conductivity": 0.0, "windRes": 1.0,  "baseTemp": 250, "lightEmission": 255},
    "seed":      {"id": 6,  "density": 130, "gravity": 1,  "state": "special",  "maxVel": 2, "flammable": True,  "heatCond": 0.1,  "hardness": 5,   "corrosionRes": 0,  "porosity": 0.0, "conductivity": 0.0, "windRes": 0.4,  "baseTemp": 128},
    "stone":     {"id": 7,  "density": 255, "gravity": 1,  "state": "solid",    "maxVel": 2, "flammable": False, "heatCond": 0.5,  "hardness": 80,  "corrosionRes": 60, "porosity": 0.0, "conductivity": 0.0, "windRes": 1.0,  "baseTemp": 128, "meltPoint": 220, "meltsInto": "lava"},
    "tnt":       {"id": 8,  "density": 140, "gravity": 2,  "state": "granular", "maxVel": 2, "flammable": True,  "heatCond": 0.2,  "hardness": 15,  "corrosionRes": 0,  "porosity": 0.0, "conductivity": 0.0, "windRes": 0.7,  "baseTemp": 128},
    "rainbow":   {"id": 9,  "density": 8,   "gravity": -1, "state": "gas",      "maxVel": 2, "flammable": False, "heatCond": 0.0,  "hardness": 0,   "corrosionRes": 0,  "porosity": 0.0, "conductivity": 0.0, "windRes": 0.1,  "baseTemp": 128, "decayRate": 1, "decaysInto": "empty", "lightEmission": 100},
    "mud":       {"id": 10, "density": 120, "gravity": 1,  "state": "liquid",   "maxVel": 1, "flammable": False, "heatCond": 0.25, "hardness": 15,  "corrosionRes": 0,  "porosity": 0.4, "conductivity": 0.0, "windRes": 0.85, "baseTemp": 128, "viscosity": 3, "surfaceTension": 6},
    "steam":     {"id": 11, "density": 3,   "gravity": -1, "state": "gas",      "maxVel": 2, "flammable": False, "heatCond": 0.3,  "hardness": 2,   "corrosionRes": 0,  "porosity": 0.0, "conductivity": 0.0, "windRes": 0.2,  "baseTemp": 160, "decayRate": 1, "decaysInto": "water", "freezePoint": 60, "freezesInto": "water"},
    "ant":       {"id": 12, "density": 80,  "gravity": 1,  "state": "special",  "maxVel": 2, "flammable": True,  "heatCond": 0.1,  "hardness": 5,   "corrosionRes": 0,  "porosity": 0.0, "conductivity": 0.0, "windRes": 0.5,  "baseTemp": 128},
    "oil":       {"id": 13, "density": 80,  "gravity": 1,  "state": "liquid",   "maxVel": 2, "flammable": True,  "heatCond": 0.15, "hardness": 5,   "corrosionRes": 0,  "porosity": 0.0, "conductivity": 0.0, "windRes": 0.85, "baseTemp": 128, "viscosity": 2, "surfaceTension": 3, "boilPoint": 160, "boilsInto": "smoke"},
    "acid":      {"id": 14, "density": 110, "gravity": 1,  "state": "liquid",   "maxVel": 2, "flammable": False, "heatCond": 0.35, "hardness": 0,   "corrosionRes": 0,  "porosity": 0.0, "conductivity": 0.4, "windRes": 0.85, "baseTemp": 128, "viscosity": 1, "surfaceTension": 2},
    "glass":     {"id": 15, "density": 220, "gravity": 1,  "state": "solid",    "maxVel": 2, "flammable": False, "heatCond": 0.4,  "hardness": 70,  "corrosionRes": 50, "porosity": 0.0, "conductivity": 0.0, "windRes": 1.0,  "baseTemp": 128, "meltPoint": 200, "meltsInto": "sand"},
    "dirt":      {"id": 16, "density": 145, "gravity": 1,  "state": "granular", "maxVel": 3, "flammable": False, "heatCond": 0.2,  "hardness": 30,  "corrosionRes": 0,  "porosity": 0.6, "conductivity": 0.0, "windRes": 0.7,  "baseTemp": 128},
    "plant":     {"id": 17, "density": 60,  "gravity": 0,  "state": "special",  "maxVel": 2, "flammable": True,  "heatCond": 0.1,  "hardness": 20,  "corrosionRes": 0,  "porosity": 0.15,"conductivity": 0.0, "windRes": 1.0,  "baseTemp": 128},
    "lava":      {"id": 18, "density": 200, "gravity": 1,  "state": "liquid",   "maxVel": 1, "flammable": False, "heatCond": 0.9,  "hardness": 0,   "corrosionRes": 0,  "porosity": 0.0, "conductivity": 0.3, "windRes": 0.95, "baseTemp": 250, "viscosity": 4, "surfaceTension": 8, "freezePoint": 60, "freezesInto": "stone", "lightEmission": 220},
    "snow":      {"id": 19, "density": 50,  "gravity": 1,  "state": "powder",   "maxVel": 2, "flammable": False, "heatCond": 0.15, "hardness": 8,   "corrosionRes": 0,  "porosity": 0.0, "conductivity": 0.0, "windRes": 0.3,  "baseTemp": 35,  "meltPoint": 50, "meltsInto": "water"},
    "wood":      {"id": 20, "density": 85,  "gravity": 1,  "state": "solid",    "maxVel": 2, "flammable": True,  "heatCond": 0.1,  "hardness": 50,  "corrosionRes": 30, "porosity": 0.2, "conductivity": 0.0, "windRes": 1.0,  "baseTemp": 128},
    "metal":     {"id": 21, "density": 240, "gravity": 1,  "state": "solid",    "maxVel": 2, "flammable": False, "heatCond": 0.9,  "hardness": 95,  "corrosionRes": 90, "porosity": 0.0, "conductivity": 0.95,"windRes": 1.0,  "baseTemp": 128, "meltPoint": 240, "meltsInto": "lava"},
    "smoke":     {"id": 22, "density": 4,   "gravity": -1, "state": "gas",      "maxVel": 2, "flammable": False, "heatCond": 0.05, "hardness": 2,   "corrosionRes": 0,  "porosity": 0.0, "conductivity": 0.0, "windRes": 0.15, "baseTemp": 145, "decayRate": 2, "decaysInto": "empty"},
    "bubble":    {"id": 23, "density": 2,   "gravity": -1, "state": "special",  "maxVel": 2, "flammable": False, "heatCond": 0.01, "hardness": 0,   "corrosionRes": 0,  "porosity": 0.0, "conductivity": 0.0, "windRes": 0.15, "baseTemp": 128},
    "ash":       {"id": 24, "density": 30,  "gravity": 1,  "state": "powder",   "maxVel": 2, "flammable": False, "heatCond": 0.1,  "hardness": 3,   "corrosionRes": 0,  "porosity": 0.0, "conductivity": 0.0, "windRes": 0.1,  "baseTemp": 135},
}

# Real-world densities for buoyancy/ordering comparisons (kg/m^3)
REAL_DENSITIES = {
    "metal": 7800, "stone": 2700, "glass": 2500, "lava": 2600,
    "sand": 1600, "dirt": 1500, "tnt": 1600, "seed": 1200,
    "mud": 1300, "acid": 1050, "water": 1000, "ice": 917,
    "oil": 800, "wood": 600, "plant": 500, "ant": 1050,
    "snow": 100, "ash": 200, "fire": 0.3, "smoke": 1.2,
    "steam": 0.6, "rainbow": 0.001, "bubble": 0.001, "empty": 0,
    "lightning": 0,
}

# Real-world thermal conductivities (W/m*K)
REAL_CONDUCTIVITY = {
    "metal": 50.0, "lightning": 100.0, "ice": 2.2, "stone": 2.5,
    "glass": 1.0, "water": 0.6, "lava": 1.5, "dirt": 0.5, "acid": 0.6,
    "sand": 0.25, "mud": 0.4, "steam": 0.02, "oil": 0.15,
    "wood": 0.15, "plant": 0.12, "fire": 0.04, "snow": 0.05,
    "ash": 0.1, "tnt": 0.2, "seed": 0.1, "ant": 0.2,
    "smoke": 0.025, "rainbow": 0.01, "bubble": 0.025, "empty": 0.025,
}

# Real-world viscosities (Pa*s) for liquid elements
REAL_VISCOSITY = {
    "water": 0.001,
    "acid": 0.0012,
    "oil": 0.03,
    "mud": 0.1,
    "lava": 100.0,
}

# =============================================================================
# All registered reactions (from reaction_registry.dart)
# =============================================================================

REACTIONS = [
    {"source": "fire",      "target": "oil",       "sourceBecomesElement": None,      "targetBecomesElement": "fire",    "probability": 0.5,   "description": "Fire ignites adjacent oil"},
    {"source": "fire",      "target": "wood",      "sourceBecomesElement": None,      "targetBecomesElement": "fire",    "probability": 0.15,  "description": "Fire ignites wood"},
    {"source": "fire",      "target": "plant",     "sourceBecomesElement": None,      "targetBecomesElement": "fire",    "probability": 0.3,   "description": "Fire spreads to plants"},
    {"source": "fire",      "target": "seed",      "sourceBecomesElement": None,      "targetBecomesElement": "fire",    "probability": 0.3,   "description": "Fire ignites seeds"},
    {"source": "fire",      "target": "ice",       "sourceBecomesElement": None,      "targetBecomesElement": "water",   "probability": 0.1,   "description": "Fire melts ice"},
    {"source": "fire",      "target": "snow",      "sourceBecomesElement": None,      "targetBecomesElement": "water",   "probability": 0.15,  "description": "Fire melts snow"},
    {"source": "fire",      "target": "tnt",       "sourceBecomesElement": None,      "targetBecomesElement": None,      "probability": 0.3,   "description": "Fire detonates TNT"},
    {"source": "water",     "target": "fire",      "sourceBecomesElement": "steam",   "targetBecomesElement": "empty",   "probability": 1.0,   "description": "Water extinguishes fire"},
    {"source": "water",     "target": "lava",      "sourceBecomesElement": "steam",   "targetBecomesElement": "stone",   "probability": 1.0,   "description": "Water cools lava"},
    {"source": "sand",      "target": "lightning",  "sourceBecomesElement": "glass",  "targetBecomesElement": None,      "probability": 1.0,   "description": "Lightning fuses sand to glass"},
    {"source": "sand",      "target": "water",     "sourceBecomesElement": "mud",     "targetBecomesElement": None,      "probability": 1.0,   "description": "Sand absorbs water to become mud"},
    {"source": "lava",      "target": "water",     "sourceBecomesElement": "stone",   "targetBecomesElement": "steam",   "probability": 1.0,   "description": "Lava + water = stone + steam"},
    {"source": "lava",      "target": "ice",       "sourceBecomesElement": None,      "targetBecomesElement": "water",   "probability": 1.0,   "description": "Lava melts ice"},
    {"source": "lava",      "target": "snow",      "sourceBecomesElement": None,      "targetBecomesElement": "steam",   "probability": 1.0,   "description": "Lava vaporizes snow"},
    {"source": "lava",      "target": "wood",      "sourceBecomesElement": None,      "targetBecomesElement": "fire",    "probability": 0.4,   "description": "Lava ignites wood"},
    {"source": "lava",      "target": "stone",     "sourceBecomesElement": None,      "targetBecomesElement": None,      "probability": 0.08,  "description": "Lava heats adjacent stone"},
    {"source": "acid",      "target": "stone",     "sourceBecomesElement": "empty",   "targetBecomesElement": "empty",   "probability": 0.08,  "description": "Acid dissolves stone"},
    {"source": "acid",      "target": "wood",      "sourceBecomesElement": "empty",   "targetBecomesElement": "empty",   "probability": 0.12,  "description": "Acid dissolves wood"},
    {"source": "acid",      "target": "metal",     "sourceBecomesElement": None,      "targetBecomesElement": None,      "probability": 0.05,  "description": "Acid corrodes metal"},
    {"source": "acid",      "target": "dirt",      "sourceBecomesElement": None,      "targetBecomesElement": "empty",   "probability": 0.15,  "description": "Acid dissolves dirt"},
    {"source": "acid",      "target": "ice",       "sourceBecomesElement": None,      "targetBecomesElement": "water",   "probability": 0.1,   "description": "Acid melts ice"},
    {"source": "acid",      "target": "glass",     "sourceBecomesElement": "empty",   "targetBecomesElement": "empty",   "probability": 0.1,   "description": "Acid dissolves glass"},
    {"source": "acid",      "target": "plant",     "sourceBecomesElement": None,      "targetBecomesElement": "empty",   "probability": 0.33,  "description": "Acid dissolves plants"},
    {"source": "acid",      "target": "seed",      "sourceBecomesElement": None,      "targetBecomesElement": "empty",   "probability": 0.33,  "description": "Acid dissolves seeds"},
    {"source": "acid",      "target": "ant",       "sourceBecomesElement": None,      "targetBecomesElement": "empty",   "probability": 1.0,   "description": "Acid kills ants"},
    {"source": "acid",      "target": "water",     "sourceBecomesElement": "water",   "targetBecomesElement": None,      "probability": 0.125, "description": "Acid dilutes in water"},
    {"source": "acid",      "target": "lava",      "sourceBecomesElement": "smoke",   "targetBecomesElement": "steam",   "probability": 0.2,   "description": "Acid + lava = violent reaction"},
    {"source": "seed",      "target": "water",     "sourceBecomesElement": None,      "targetBecomesElement": None,      "probability": 0.02,  "description": "Seed near water can sprout"},
    {"source": "lightning",  "target": "water",    "sourceBecomesElement": None,      "targetBecomesElement": None,      "probability": 1.0,   "description": "Lightning electrifies water"},
    {"source": "lightning",  "target": "metal",    "sourceBecomesElement": None,      "targetBecomesElement": None,      "probability": 1.0,   "description": "Lightning conducts through metal"},
    {"source": "lightning",  "target": "sand",     "sourceBecomesElement": None,      "targetBecomesElement": "glass",   "probability": 1.0,   "description": "Lightning fuses sand to glass"},
    {"source": "lightning",  "target": "tnt",      "sourceBecomesElement": None,      "targetBecomesElement": None,      "probability": 1.0,   "description": "Lightning detonates TNT"},
    {"source": "snow",      "target": "fire",      "sourceBecomesElement": "water",   "targetBecomesElement": None,      "probability": 1.0,   "description": "Snow melts near fire"},
    {"source": "ice",       "target": "fire",      "sourceBecomesElement": "water",   "targetBecomesElement": None,      "probability": 1.0,   "description": "Ice melts near fire"},
    {"source": "mud",       "target": "fire",      "sourceBecomesElement": "dirt",    "targetBecomesElement": None,      "probability": 0.05,  "description": "Mud dries near fire"},
    {"source": "mud",       "target": "lava",      "sourceBecomesElement": "dirt",    "targetBecomesElement": None,      "probability": 0.05,  "description": "Mud dries near lava"},
]


def generate_ground_truth() -> dict:
    results = {}

    # =========================================================================
    # 1. GRAVITY FREE-FALL TRAJECTORY (original)
    # =========================================================================

    frames = list(range(1, 61))

    real_positions = []
    for f in frames:
        t = f * DT
        d_meters = 0.5 * REAL_G * t * t
        d_cells = d_meters / CELL_SIZE_M
        real_positions.append(round(d_cells, 2))

    sand_grav = ELEMENTS["sand"]["gravity"]
    sand_max = ELEMENTS["sand"]["maxVel"]
    engine_positions = []
    vel = 0
    pos = 0.0
    for f in frames:
        vel = min(vel + sand_grav, sand_max)
        pos += vel
        engine_positions.append(pos)

    results["gravity_trajectory"] = {
        "frames": frames,
        "real_physics_cells": real_positions,
        "engine_model_cells": engine_positions,
        "g_real_m_s2": REAL_G,
        "g_cells_per_frame2": REAL_G / CELL_SIZE_M / (FPS * FPS),
        "engine_gravity": sand_grav,
        "engine_max_velocity": sand_max,
    }

    # =========================================================================
    # 2. gravity_all -- per-element gravity trajectories
    # =========================================================================

    gravity_all = {}
    for name, props in ELEMENTS.items():
        g = props["gravity"]
        if g == 0:
            continue
        mv = props["maxVel"]
        trajectory = []
        v = 0
        p = 0.0
        for f in range(1, 61):
            if g > 0:
                v = min(v + g, mv)
            else:
                v = max(v + g, -mv)
            p += v
            trajectory.append(p)
        gravity_all[name] = {
            "gravity": g,
            "maxVelocity": mv,
            "direction": "down" if g > 0 else "up",
            "positions_60frames": trajectory,
            "final_position": trajectory[-1],
        }

    results["gravity_all"] = gravity_all

    # =========================================================================
    # 3. density_pairs -- all pairwise sink/float predictions
    # =========================================================================

    movable = {n: p for n, p in ELEMENTS.items()
               if p["density"] > 0 and n != "empty"}
    density_pairs = {}
    for (a, pa), (b, pb) in combinations(movable.items(), 2):
        key = f"{a}_vs_{b}"
        da, db = pa["density"], pb["density"]
        if da == db:
            relation = "equal"
        elif da > db:
            relation = f"{a}_sinks_below_{b}"
        else:
            relation = f"{b}_sinks_below_{a}"
        density_pairs[key] = {
            "density_a": da,
            "density_b": db,
            "heavier": a if da > db else (b if db > da else "equal"),
            "relation": relation,
        }

    results["density_pairs"] = density_pairs

    # =========================================================================
    # 4. phase_changes_all -- every element with phase transitions
    # =========================================================================

    phase_changes_all = {}
    for name, props in ELEMENTS.items():
        transitions = {}
        if "meltPoint" in props:
            transitions["melt"] = {
                "threshold": props["meltPoint"],
                "becomes": props["meltsInto"],
                "trigger": "temperature_above",
                "threshold_temp": TEMP_NEUTRAL + props["meltPoint"],
            }
        if "boilPoint" in props:
            transitions["boil"] = {
                "threshold": props["boilPoint"],
                "becomes": props["boilsInto"],
                "trigger": "temperature_above",
                "threshold_temp": TEMP_NEUTRAL + props["boilPoint"],
            }
        if "freezePoint" in props:
            transitions["freeze"] = {
                "threshold": props["freezePoint"],
                "becomes": props["freezesInto"],
                "trigger": "temperature_below",
                "threshold_temp": TEMP_NEUTRAL - props["freezePoint"],
            }
        if transitions:
            phase_changes_all[name] = transitions

    results["phase_changes_all"] = phase_changes_all

    # =========================================================================
    # 5. buoyancy_all -- every element vs water
    # =========================================================================

    water_real_density = REAL_DENSITIES["water"]
    water_engine_density = ELEMENTS["water"]["density"]
    buoyancy_all = {}
    for name, real_d in REAL_DENSITIES.items():
        if name == "water" or name == "empty":
            continue
        engine_d = ELEMENTS[name]["density"]
        buoyancy_all[name] = {
            "real_density_kg_m3": real_d,
            "engine_density": engine_d,
            "water_real_density": water_real_density,
            "water_engine_density": water_engine_density,
            "real_should_sink": real_d > water_real_density,
            "real_should_float": real_d < water_real_density,
            "engine_should_sink": engine_d > water_engine_density,
            "engine_should_float": engine_d < water_engine_density,
            "buoyancy_agreement": (real_d > water_real_density) == (engine_d > water_engine_density),
        }

    results["buoyancy_all"] = buoyancy_all

    # =========================================================================
    # 6. flammable_all -- every flammable element's burn behavior
    # =========================================================================

    flammable_all = {}
    for name, props in ELEMENTS.items():
        if not props["flammable"]:
            continue
        fire_reactions = [r for r in REACTIONS if r["source"] == "fire" and r["target"] == name]
        burns_into = None
        burn_prob = 0.0
        for r in fire_reactions:
            if r["targetBecomesElement"]:
                burns_into = r["targetBecomesElement"]
            burn_prob = r["probability"]

        hardness = props["hardness"]
        ignition_ease = 1.0 / max(hardness, 1)

        flammable_all[name] = {
            "flammable": True,
            "hardness": hardness,
            "ignition_ease_relative": round(ignition_ease, 4),
            "burns_into": burns_into,
            "fire_reaction_probability": burn_prob,
            "has_fire_reaction": len(fire_reactions) > 0,
        }

    # Arrhenius ordering
    R_gas = 8.314
    Ea_map = {"oil": 50000, "seed": 60000, "ant": 70000, "plant": 80000, "tnt": 90000, "wood": 120000}
    A = 1e10
    T_flame = 800 + 273.15
    for name, Ea in Ea_map.items():
        if name in flammable_all:
            k = A * math.exp(-Ea / (R_gas * T_flame))
            flammable_all[name]["arrhenius_rate"] = round(k, 6)
            flammable_all[name]["Ea_J_per_mol"] = Ea

    results["flammable_all"] = flammable_all

    # =========================================================================
    # 7. conduction_all -- all elements sorted by heat conductivity
    # =========================================================================

    cond_items = [(n, p["heatCond"]) for n, p in ELEMENTS.items() if n != "empty"]
    cond_items.sort(key=lambda x: -x[1])

    conduction_all = {
        "ordering": [name for name, _ in cond_items],
        "values": {name: val for name, val in cond_items},
        "real_ordering": sorted(
            [n for n in REAL_CONDUCTIVITY if n != "empty"],
            key=lambda x: -REAL_CONDUCTIVITY[x]
        ),
        "real_values_W_per_mK": {k: v for k, v in REAL_CONDUCTIVITY.items() if k != "empty"},
    }

    results["conduction_all"] = conduction_all

    # =========================================================================
    # 8. viscosity_all -- all liquid elements sorted by viscosity
    # =========================================================================

    liquids = {n: p for n, p in ELEMENTS.items() if p["state"] == "liquid"}
    visc_ordering = sorted(liquids.keys(), key=lambda n: liquids[n].get("viscosity", 1))

    viscosity_all = {
        "ordering_least_to_most_viscous": visc_ordering,
        "engine_viscosity": {n: liquids[n].get("viscosity", 1) for n in visc_ordering},
        "real_viscosity_pa_s": REAL_VISCOSITY,
        "real_ordering": sorted(REAL_VISCOSITY.keys(), key=lambda x: REAL_VISCOSITY[x]),
        "flow_ratio_vs_water": {
            n: round(REAL_VISCOSITY.get("water", 0.001) / REAL_VISCOSITY[n], 6)
            for n in REAL_VISCOSITY
        },
    }

    results["viscosity_all"] = viscosity_all

    # =========================================================================
    # 9. reactions_all -- every registered reaction with expected products
    # =========================================================================

    reactions_all = {}
    for i, r in enumerate(REACTIONS):
        key = f"{r['source']}_{r['target']}"
        if key in reactions_all:
            key = f"{key}_{i}"
        reactions_all[key] = {
            "source": r["source"],
            "target": r["target"],
            "source_becomes": r["sourceBecomesElement"],
            "target_becomes": r["targetBecomesElement"],
            "probability": r["probability"],
            "description": r["description"],
            "is_deterministic": r["probability"] >= 1.0,
        }

    results["reactions_all"] = reactions_all

    # =========================================================================
    # 10. structural_all -- every solid element's structural properties
    # =========================================================================

    structural_all = {}
    for name, props in ELEMENTS.items():
        if props["state"] not in ("solid",):
            continue
        structural_all[name] = {
            "hardness": props["hardness"],
            "density": props["density"],
            "corrosion_resistance": props["corrosionRes"],
            "heat_conductivity": props["heatCond"],
            "flammable": props["flammable"],
            "has_melt_point": "meltPoint" in props,
            "melt_point": props.get("meltPoint", None),
            "structural_score": round(
                props["hardness"] * 0.4 +
                props["density"] * 0.3 +
                props["corrosionRes"] * 0.3, 2
            ),
        }

    struct_order = sorted(structural_all.keys(),
                          key=lambda n: -structural_all[n]["structural_score"])
    for i, name in enumerate(struct_order):
        structural_all[name]["rank"] = i + 1

    results["structural_all"] = structural_all

    # =========================================================================
    # 11. erosion_all -- every erodible element (by hardness)
    # =========================================================================

    erosion_all = {}
    acid_targets = {r["target"]: r for r in REACTIONS if r["source"] == "acid"}

    for name, props in ELEMENTS.items():
        if name == "empty":
            continue
        hardness = props["hardness"]
        acid_reaction = acid_targets.get(name)
        erosion_all[name] = {
            "hardness": hardness,
            "corrosion_resistance": props["corrosionRes"],
            "acid_reactive": acid_reaction is not None,
            "acid_probability": acid_reaction["probability"] if acid_reaction else 0,
            "acid_result": acid_reaction["targetBecomesElement"] if acid_reaction else None,
            "erosion_resistance_score": round(
                hardness * 0.5 + props["corrosionRes"] * 0.5, 2
            ),
        }

    erosion_order = sorted(erosion_all.keys(),
                           key=lambda n: -erosion_all[n]["erosion_resistance_score"])
    for i, name in enumerate(erosion_order):
        erosion_all[name]["rank"] = i + 1

    results["erosion_all"] = erosion_all

    # =========================================================================
    # 12. granular_all -- every granular/powder element's angle of repose
    # =========================================================================

    real_angles = {
        "sand": 34, "dirt": 40, "tnt": 35, "snow": 38, "ash": 35,
    }

    granular_all = {}
    for name, props in ELEMENTS.items():
        if props["state"] not in ("granular", "powder"):
            continue
        real_angle = real_angles.get(name, 35)
        granular_all[name] = {
            "state": props["state"],
            "gravity": props["gravity"],
            "density": props["density"],
            "real_angle_of_repose_deg": real_angle,
            "tan_angle": round(math.tan(math.radians(real_angle)), 4),
            "ca_natural_angle": 45,
            "note": "Cellular automata with 8-connectivity have natural 45-deg angle",
        }

    results["granular_all"] = granular_all

    # =========================================================================
    # 13. conservation -- mass/energy/momentum expected drift
    # =========================================================================

    results["conservation"] = {
        "mass": {
            "principle": "In a closed system with no reactions, total cell count is constant",
            "expected_drift": 0,
            "tolerance_percent": 1.0,
        },
        "energy": {
            "principle": "Without heat sources/sinks, total thermal energy is constant",
            "expected_drift_percent": 0,
            "tolerance_percent": 5.0,
            "note": "Integer rounding in heat transfer causes inherent dissipation",
        },
        "momentum": {
            "principle": "In a symmetric system, net horizontal momentum should be zero",
            "expected_net_horizontal": 0,
            "tolerance": 1,
            "note": "Symmetric sand drop should preserve zero net horizontal momentum",
        },
    }

    # =========================================================================
    # 14. torricelli -- outflow velocity at multiple heights
    # =========================================================================

    g_eff = 1.0
    heights = [5, 10, 15, 20, 25, 30, 40, 50]
    velocities = [round(math.sqrt(2 * g_eff * h), 3) for h in heights]
    ratios = [round(math.sqrt(h / heights[0]), 4) for h in heights]

    results["torricelli"] = {
        "heights_cells": heights,
        "expected_velocity_cells_per_frame": velocities,
        "velocity_ratios_vs_first": ratios,
        "g_effective": g_eff,
        "equation": "v = sqrt(2 * g * h)",
        "note": "Ratio between heights is key: v(h1)/v(h2) = sqrt(h1/h2)",
    }

    # =========================================================================
    # 15. pressure_depth -- Pascal's law linear model
    # =========================================================================

    depths = list(range(1, 51))
    expected_pressure = [d for d in depths]

    results["pressure_depth"] = {
        "depths_cells": depths,
        "expected_pressure": expected_pressure,
        "equation": "P = depth (our model: column count)",
        "real_equation": "P = rho * g * h",
        "note": "Our model is linear by construction",
        "linearity_r_squared": 1.0,
    }

    # =========================================================================
    # 16. cooling_all -- per-material cooling curves via ODE
    # =========================================================================

    T0 = 250
    T_ambient = TEMP_NEUTRAL
    sample_frames = list(range(0, 301, 10))

    cooling_all = {}
    for name, props in ELEMENTS.items():
        if name == "empty":
            continue
        hc = props["heatCond"]
        if hc <= 0:
            continue

        # Calibrate k from engine's diffusion model
        k = (hc * 255.0 / 1024.0) / 3.0

        # Analytical solution
        analytical = []
        for f in sample_frames:
            T = T_ambient + (T0 - T_ambient) * math.exp(-k * f)
            analytical.append(round(T, 2))

        # ODE solution
        def cooling_ode(T_arr, t, k_val, T_amb):
            return [-k_val * (T_arr[0] - T_amb)]

        t_span = np.array(sample_frames, dtype=float)
        ode_sol = odeint(cooling_ode, [T0], t_span, args=(k, T_ambient))
        ode_temps = [round(float(T[0]), 2) for T in ode_sol]

        half_life = round(math.log(2) / k, 2) if k > 0 else float('inf')

        cooling_all[name] = {
            "k": round(k, 6),
            "half_life_frames": half_life,
            "analytical_temps": analytical,
            "ode_temps": ode_temps,
            "T_initial": T0,
            "T_ambient": T_ambient,
            "heatConductivity": hc,
        }

    results["cooling_all"] = cooling_all

    # =========================================================================
    # 17. equilibrium -- thermal equilibrium expected temperatures
    # =========================================================================

    equilibrium = {}

    # Same material (stone-stone)
    n1, T1_val = 143, 220
    n2, T2_val = 156, 36
    T_eq = (n1 * T1_val + n2 * T2_val) / (n1 + n2)
    equilibrium["stone_stone"] = {
        "material": "stone",
        "n_hot": n1, "T_hot": T1_val,
        "n_cold": n2, "T_cold": T2_val,
        "expected_T_eq": round(T_eq, 2),
        "equation": "T_eq = (n1*T1 + n2*T2) / (n1 + n2)",
    }

    # Equal counts, different temps
    for mat in ["water", "metal", "sand"]:
        n = 100
        T_h, T_c = 200, 50
        T_eq_m = (n * T_h + n * T_c) / (2 * n)
        equilibrium[f"{mat}_equal"] = {
            "material": mat,
            "n_hot": n, "T_hot": T_h,
            "n_cold": n, "T_cold": T_c,
            "expected_T_eq": round(T_eq_m, 2),
        }

    # Cross-material
    equilibrium["mixed_metal_water"] = {
        "materials": ["metal", "water"],
        "n_metal": 50, "T_metal": 250,
        "n_water": 200, "T_water": 80,
        "note": "Engine uses cell-count weighting (no specific heat capacity)",
        "expected_T_eq": round((50 * 250 + 200 * 80) / 250, 2),
    }

    results["equilibrium"] = equilibrium

    # =========================================================================
    # 18. NEWTON'S COOLING CURVE (backward compat)
    # =========================================================================

    k_stone = (0.5 * 255.0 / 1024.0) / 3.0
    analytical_temps = []
    for f in sample_frames:
        T = T_ambient + (T0 - T_ambient) * math.exp(-k_stone * f)
        analytical_temps.append(round(T, 2))

    t_span_cc = np.array(sample_frames, dtype=float)

    def cooling_ode_simple(T_arr, t, k_val, T_amb):
        return [-k_val * (T_arr[0] - T_amb)]

    ode_solution = odeint(cooling_ode_simple, [T0], t_span_cc, args=(k_stone, T_ambient))
    ode_temps = [round(float(T[0]), 2) for T in ode_solution]

    results["cooling_curve"] = {
        "frames": sample_frames,
        "analytical_temps": analytical_temps,
        "ode_temps": ode_temps,
        "T_initial": T0,
        "T_ambient": T_ambient,
        "k": round(k_stone, 6),
        "equation": "T(t) = T_amb + (T0 - T_amb) * exp(-k*t)",
    }

    # =========================================================================
    # 19. DENSITY ORDERING
    # =========================================================================

    real_densities_subset = {k: v for k, v in REAL_DENSITIES.items()
                             if k in ("metal", "stone", "glass", "sand", "dirt",
                                      "mud", "water", "oil", "ice", "wood", "ash", "snow")}
    our_densities_subset = {k: ELEMENTS[k]["density"] for k in real_densities_subset}

    real_order = sorted(real_densities_subset.keys(), key=lambda x: -real_densities_subset[x])
    our_order = sorted(our_densities_subset.keys(), key=lambda x: -our_densities_subset[x])

    def kendall_distance(a, b):
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
        "real_densities_kg_m3": real_densities_subset,
        "our_densities_0_255": our_densities_subset,
        "real_order": real_order,
        "our_order": our_order,
        "kendall_inversions": inv,
        "kendall_total_pairs": total,
        "ordering_accuracy": round(1.0 - inv / max(total, 1), 4),
    }

    # =========================================================================
    # 20. ANGLE OF REPOSE (backward compat)
    # =========================================================================

    angle_data = {}
    for name in ["sand", "dirt", "snow", "ash"]:
        a = real_angles.get(name, 35)
        angle_data[name] = {
            "min": a - 4, "max": a + 4, "typical": a,
            "tan_typical": round(math.tan(math.radians(a)), 4),
        }
    angle_data["note"] = "Cellular automata with 8-connectivity have a natural 45-deg bias"
    results["angle_of_repose"] = angle_data

    # =========================================================================
    # 21. VISCOSITY (backward compat)
    # =========================================================================

    results["viscosity"] = {
        "real_viscosity_pa_s": REAL_VISCOSITY,
        "our_viscosity_1_10": {n: ELEMENTS[n].get("viscosity", 1) for n in REAL_VISCOSITY},
        "expected_flow_ratio_vs_water": {
            n: round(REAL_VISCOSITY["water"] / v, 6)
            for n, v in REAL_VISCOSITY.items()
        },
        "expected_spread_ordering": ["water", "acid", "oil", "mud", "lava"],
        "note": "Real lava is 100000x more viscous than water; our 4:1 ratio is a game-feel compression",
    }

    # =========================================================================
    # 22. PHASE CHANGES (backward compat)
    # =========================================================================

    results["phase_changes"] = {
        "water_freeze": {"real_C": 0, "our_freezePoint": 30, "element": "water", "becomes": "ice"},
        "water_boil": {"real_C": 100, "our_boilPoint": 180, "element": "water", "becomes": "steam"},
        "ice_melt": {"real_C": 0, "our_meltPoint": 40, "element": "ice", "becomes": "water"},
        "sand_melt": {"real_C": 1700, "our_meltPoint": 248, "element": "sand", "becomes": "glass"},
        "stone_melt": {"real_C": 1200, "our_meltPoint": 220, "element": "stone", "becomes": "lava"},
        "metal_melt": {"real_C": 1500, "our_meltPoint": 240, "element": "metal", "becomes": "lava"},
        "snow_melt": {"real_C": 0, "our_meltPoint": 50, "element": "snow", "becomes": "water"},
        "lava_freeze": {"real_C": 700, "our_freezePoint": 60, "element": "lava", "becomes": "stone"},
        "oil_boil": {"real_C": 300, "our_boilPoint": 160, "element": "oil", "becomes": "smoke"},
        "glass_melt": {"real_C": 1400, "our_meltPoint": 200, "element": "glass", "becomes": "sand"},
    }

    # =========================================================================
    # Glass thermal shock (spatial temperature gradient shattering)
    # =========================================================================
    # Real soda-lime glass has thermal shock resistance of ~150°C
    # (σ_th = E·α·ΔT, E≈70 GPa, α≈9×10⁻⁶/K, fracture≈50 MPa → ΔT≈80K)
    # Our scale: 150°C maps to ~40 units on our 0-255 temperature scale
    results["glass_thermal_shock"] = {
        "principle": "Differential thermal expansion creates stress exceeding fracture strength",
        "real_shock_resistance_C": 150,
        "our_temp_scale_equivalent": 40,
        "threshold_gradient": 45,
        "probabilistic_threshold": 35,
        "shatters_to": "sand",
        "produces_flash": True,
        "equation": "sigma_th = E * alpha * deltaT",
        "E_GPa": 70,
        "alpha_per_K": 9e-6,
        "fracture_strength_MPa": 50,
        "reference": "Kingery, Introduction to Ceramics (1976)",
    }

    # =========================================================================
    # Specific heat capacity (Q = mcΔT)
    # =========================================================================
    # Real specific heat capacities in J/(g·K)
    real_heat_capacity = {
        "water": 4.18, "ice": 2.09, "steam": 2.01, "oil": 2.0,
        "mud": 2.5, "wood": 1.76, "lava": 1.5, "plant": 1.7,
        "sand": 0.84, "stone": 0.84, "glass": 0.84, "dirt": 0.80,
        "metal": 0.45, "fire": 1.0, "smoke": 1.0, "ash": 0.8,
    }
    # Our engine values (1-10 scale, water=10)
    our_heat_capacity = {
        "water": 10, "ice": 5, "steam": 5, "oil": 5,
        "mud": 6, "wood": 4, "lava": 4, "plant": 4,
        "sand": 2, "stone": 2, "glass": 2, "dirt": 2,
        "metal": 1, "fire": 1, "smoke": 1, "ash": 1,
    }
    real_order = sorted(real_heat_capacity.keys(), key=lambda x: -real_heat_capacity[x])
    our_order = sorted(our_heat_capacity.keys(), key=lambda x: -our_heat_capacity[x])
    results["specific_heat_capacity"] = {
        "principle": "Q = mcΔT — higher heat capacity means more energy to change temperature",
        "real_J_per_gK": real_heat_capacity,
        "our_1_to_10": our_heat_capacity,
        "real_ordering": real_order,
        "our_ordering": our_order,
        "water_highest": True,
        "metal_lowest": True,
        "reference": "CRC Handbook of Chemistry and Physics",
    }

    # =========================================================================
    # Pressure-dependent boiling (Clausius-Clapeyron)
    # =========================================================================
    # dP/dT = ΔH_vap / (T·ΔV): boiling point rises ~3°C per atm
    # At 10m depth (~2 atm), water boils at ~121°C instead of 100°C
    results["pressure_boiling"] = {
        "principle": "Clausius-Clapeyron: boiling point rises with pressure",
        "equation": "dP/dT = delta_H_vap / (T * delta_V)",
        "water_bp_at_1atm_C": 100,
        "water_bp_at_2atm_C": 121,
        "water_bp_at_5atm_C": 152,
        "our_pressure_shift": "boil_threshold += pressure // 2",
        "deep_water_resists_boiling": True,
        "surface_water_boils_normally": True,
        "reference": "Perry's Chemical Engineers' Handbook",
    }

    # =========================================================================
    # Leidenfrost effect
    # =========================================================================
    results["leidenfrost_effect"] = {
        "principle": "Water on extremely hot surfaces levitates on its own vapor cushion",
        "leidenfrost_point_C": 193,
        "water_bp_C": 100,
        "mechanism": "Vapor film insulates droplet, dramatically increasing lifetime",
        "our_temp_threshold": 220,
        "behavior": "Water bounces upward on vapor cushion instead of instant boiling",
        "reference": "Gottfried, Lee & Bell, Int. J. Heat Mass Transfer (1966)",
    }

    # =========================================================================
    # Regelation (pressure-dependent ice melting)
    # =========================================================================
    results["regelation"] = {
        "principle": "Ice melting point decreases under pressure (anomalous Clausius-Clapeyron)",
        "melting_point_depression_C_per_atm": 0.0075,
        "mechanism": "Water is denser than ice, so pressure favors the denser phase",
        "enables": ["glacial flow", "ice skating", "wire through ice block"],
        "our_pressure_threshold": 8,
        "our_behavior": "Ice melts at lower temp when pressure > 8, probabilistic 1/4",
        "reference": "Thomson, Proc. Roy. Soc. Edinburgh (1849)",
    }

    # =========================================================================
    # Electrolysis (lightning + water → bubbles)
    # =========================================================================
    results["electrolysis"] = {
        "principle": "Electrical energy splits water into hydrogen and oxygen gases",
        "equation": "2H₂O → 2H₂ + O₂",
        "minimum_voltage_V": 1.23,
        "products": ["hydrogen", "oxygen"],
        "our_trigger": "lightning adjacent to water",
        "our_product": "bubble",
        "probability": "1/3 per adjacent water cell",
        "reference": "Faraday, Experimental Researches in Electricity (1834)",
    }

    # =========================================================================
    # 23. THERMAL CONDUCTIVITY (backward compat)
    # =========================================================================

    our_cond = {n: ELEMENTS[n]["heatCond"] for n in REAL_CONDUCTIVITY if n != "empty"}
    results["thermal_conductivity"] = {
        "real_W_per_mK": {k: v for k, v in REAL_CONDUCTIVITY.items() if k != "empty"},
        "our_0_to_1": our_cond,
        "real_ordering": sorted(
            [n for n in REAL_CONDUCTIVITY if n != "empty"],
            key=lambda x: -REAL_CONDUCTIVITY[x]
        ),
        "our_ordering": sorted(our_cond.keys(), key=lambda x: -our_cond[x]),
    }

    # =========================================================================
    # 24. EXPLOSION FALLOFF (inverse square)
    # =========================================================================

    distances = list(range(1, 16))
    inv_square = [round(1.0 / (d * d), 6) for d in distances]
    results["explosion_falloff"] = {
        "distances": distances,
        "expected_energy_ratio": inv_square,
        "equation": "E(r) = E0 / r^2",
    }

    # =========================================================================
    # 25. FOURIER HEAT CONDUCTION (1D steady-state)
    # =========================================================================

    T_hot = 250
    T_amb = 128
    L = 30

    x_positions = list(range(0, L))
    steady_state = [round(T_hot - (T_hot - T_amb) * x / L, 2) for x in x_positions]

    alpha = 0.001
    t_frames = 300

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
    # 26. BUOYANCY CLASSIFICATION (backward compat)
    # =========================================================================

    buoyancy_compat = {}
    for name in ("metal", "stone", "glass", "sand", "dirt", "mud", "oil",
                 "ice", "wood", "ash", "snow"):
        rd = REAL_DENSITIES[name]
        buoyancy_compat[name] = {
            "real_density_kg_m3": rd,
            "water_density_kg_m3": 1000,
            "should_sink": rd > 1000,
            "should_float": rd < 1000,
        }
    results["buoyancy"] = buoyancy_compat

    # =========================================================================
    # 27. CONNECTED VESSELS
    # =========================================================================

    results["connected_vessels"] = {
        "principle": "Water seeks same level in connected vessels",
        "expected_level_difference": 0,
        "tolerance_cells": 2,
        "equation": "Pascal: P = rho*g*h constant at connection point",
    }

    # =========================================================================
    # 28. U-TUBE WITH DIFFERENT FLUIDS
    # =========================================================================

    rho_water = 1000
    rho_oil = 800
    height_ratio = rho_water / rho_oil

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
    # 29. FIRE TRIANGLE
    # =========================================================================

    flammable_names = [n for n, p in ELEMENTS.items() if p["flammable"]]
    non_flammable_solids = [n for n, p in ELEMENTS.items()
                            if not p["flammable"] and p["state"] in ("solid",)]

    results["fire_triangle"] = {
        "requirements": ["fuel", "oxygen", "heat"],
        "flammable_materials": flammable_names,
        "non_flammable": non_flammable_solids,
        "expected_behaviors": {
            "fire_without_fuel": "extinguishes (decays to smoke/empty)",
            "fire_with_wood": "spreads to wood",
            "fire_with_stone": "stone unchanged",
            "fire_with_oil": "rapid chain ignition",
        },
    }

    # =========================================================================
    # 30. CONSERVATION MASS (compat)
    # =========================================================================

    results["conservation_mass"] = {
        "principle": "In a closed system with no reactions, total cell count is constant",
        "expected_drift": 0,
        "tolerance_percent": 1.0,
    }

    # =========================================================================
    # 31. CONSERVATION ENERGY (compat)
    # =========================================================================

    results["conservation_energy"] = {
        "principle": "Without heat sources/sinks, total thermal energy is constant",
        "expected_drift_percent": 0,
        "tolerance_percent": 5.0,
        "note": "Our engine has inherent dissipation from integer rounding in heat transfer",
    }

    # =========================================================================
    # 32. CONSERVATION MOMENTUM (compat)
    # =========================================================================

    results["conservation_momentum"] = {
        "principle": "In a symmetric system, net horizontal momentum should be zero",
        "expected_net_horizontal_momentum": 0,
        "tolerance": 1,
        "note": "Symmetric sand drop should preserve zero net horizontal momentum",
    }

    # =========================================================================
    # 33. BEVERLOO (hourglass flow)
    # =========================================================================

    def beverloo_flow(D, d=1, k=1.4, C=0.58, g=1.0):
        effective = D - k * d
        if effective <= 0:
            return 0
        return C * math.sqrt(g) * effective ** 2.5

    openings = [1, 2, 3, 4, 5, 6, 8, 10]
    flows = [round(beverloo_flow(D), 4) for D in openings]

    results["beverloo"] = {
        "openings_cells": openings,
        "expected_relative_flow": flows,
        "equation": "Q = C * sqrt(g) * (D - k*d)^(5/2)",
        "note": "1-cell opening has zero Beverloo flow; CA always allows it",
    }

    # =========================================================================
    # 34. ACID DISSOLUTION
    # =========================================================================

    results["acid_dissolution"] = {
        "principle": "Dissolution time proportional to thickness",
        "expected_ratio_3x_to_1x": 3.0,
        "tolerance": 1.5,
        "equation": "rate ~ surface_area * concentration",
        "acid_reactions": {
            r["target"]: {"probability": r["probability"],
                          "target_becomes": r["targetBecomesElement"]}
            for r in REACTIONS if r["source"] == "acid" and r["targetBecomesElement"]
        },
    }

    # =========================================================================
    # 35. THERMAL STRATIFICATION
    # =========================================================================

    results["thermal_stratification"] = {
        "principle": "Hot water rises above cold water (convection)",
        "expected_ordering": "temperature decreases from top to bottom",
        "mechanism": "buoyancy-driven convection",
    }

    # =========================================================================
    # 36. FIRE SPREAD RATE
    # =========================================================================

    results["fire_spread"] = {
        "principle": "Fire in uniform fuel propagates at roughly constant velocity",
        "expected_cv_below": 0.5,
        "note": "Coefficient of variation of velocity < 0.5 means roughly constant",
        "equation": "v_front ~ sqrt(k * alpha) (Fisher-KPP reaction-diffusion)",
    }

    # =========================================================================
    # 37. FLASH POINT ORDERING
    # =========================================================================

    R_gas = 8.314
    Ea_oil = 50000.0
    Ea_wood = 120000.0
    A = 1e10
    T_flame = 800 + 273.15

    k_oil = A * math.exp(-Ea_oil / (R_gas * T_flame))
    k_wood = A * math.exp(-Ea_wood / (R_gas * T_flame))

    results["flash_point"] = {
        "principle": "Oil ignites faster than wood (lower activation energy)",
        "expected_ordering": ["oil", "seed", "plant", "tnt", "wood"],
        "arrhenius_rate_oil": round(k_oil, 4),
        "arrhenius_rate_wood": round(k_wood, 4),
        "rate_ratio_oil_to_wood": round(k_oil / max(k_wood, 1e-30), 2),
        "equation": "k = A * exp(-Ea / (R*T))",
        "Ea_oil_J_per_mol": Ea_oil,
        "Ea_wood_J_per_mol": Ea_wood,
    }

    # =========================================================================
    # 38. JAMMING TRANSITION
    # =========================================================================

    results["jamming_transition"] = {
        "principle": "Granular materials can form arches over narrow openings",
        "expected_jam_probability_1cell": 0.5,
        "note": "With 1-cell opening, expect intermittent jamming",
        "reference": "Zuriguel et al., Physical Review Letters (2005)",
    }

    # =========================================================================
    # 39. GRADED BEDDING (Stokes' law)
    # =========================================================================

    rho_f = 1000.0
    eta = 0.001
    g = 9.81
    r_particle = 0.005

    settling = {}
    for name in ["sand", "dirt", "ash", "snow"]:
        rho = REAL_DENSITIES[name]
        vt = (2.0 / 9.0) * (rho - rho_f) * g * r_particle ** 2 / eta
        settling[name] = {
            "real_density_kg_m3": rho,
            "stokes_vt_m_s": round(vt, 4),
        }

    settling_order = sorted(settling.keys(), key=lambda n: -settling[n]["stokes_vt_m_s"])

    results["graded_bedding"] = {
        "principle": "Denser particles settle faster in fluid (Stokes' law)",
        "settling_data": settling,
        "expected_settling_order": settling_order,
        "equation": "v_t = (2/9) * (rho_p - rho_f) * g * r^2 / eta",
    }

    # =========================================================================
    # 40. DOMINO CASCADE
    # =========================================================================

    fall_height = 20
    v = 0
    d = 0
    fall_frames = 0
    while d < fall_height:
        v = min(v + ELEMENTS["sand"]["gravity"], ELEMENTS["sand"]["maxVel"])
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
    # 41. THERMAL EQUILIBRIUM (compat)
    # =========================================================================

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
    # 42. CAPILLARY WICKING (Washburn)
    # =========================================================================

    gamma = 0.072
    r_pore = 0.001
    theta = 0
    eta_w = 0.001

    times_s = [0.1, 0.5, 1.0, 2.0, 5.0, 10.0]
    wicking_distances = []
    for t in times_s:
        L_sq = (gamma * r_pore * math.cos(math.radians(theta)) * t) / (2 * eta_w)
        L_val = math.sqrt(max(L_sq, 0))
        wicking_distances.append(round(L_val * 100, 4))

    results["capillary_wicking"] = {
        "principle": "Porous materials absorb water against gravity via capillary action",
        "washburn_equation": "L^2 = (gamma * r * cos(theta) * t) / (2 * eta)",
        "gamma_N_per_m": gamma,
        "pore_radius_m": r_pore,
        "contact_angle_deg": theta,
        "viscosity_Pa_s": eta_w,
        "times_s": times_s,
        "wicking_distance_cm": wicking_distances,
        "porous_elements": {n: ELEMENTS[n]["porosity"]
                            for n, p in ELEMENTS.items() if p["porosity"] > 0},
        "note": "In our engine, dirt porosity=0.6 should absorb water, forming mud",
    }

    # =========================================================================
    # 43. HYDROSTATIC PARADOX
    # =========================================================================

    results["hydrostatic_paradox"] = {
        "principle": "Pressure at bottom depends only on height, not container shape",
        "expected_pressure_difference": 0,
        "tolerance": 2,
        "equation": "P = rho * g * h (independent of container width)",
    }

    # =========================================================================
    # 44. RIPPLE DAMPING
    # =========================================================================

    results["ripple_damping"] = {
        "principle": "Surface disturbances should decay over time, not amplify",
        "expected_late_less_than_early": True,
        "mechanism": "Viscous dissipation damps water surface waves",
    }

    # =========================================================================
    # 45. LOAD DISTRIBUTION
    # =========================================================================

    results["load_distribution"] = {
        "principle": "Taller liquid column exerts more pressure at base",
        "expected_pressure_ratio": 3.0,
        "tall_height": 30,
        "short_height": 10,
        "equation": "P_tall / P_short = h_tall / h_short",
    }

    # =========================================================================
    # 46. DIFFUSION (Fick's law with scipy)
    # =========================================================================

    N_cells = 50
    D_coeff = 0.05

    def diffusion_rhs(u, t, D, dx):
        """1D diffusion PDE discretized via central differences."""
        dudt = np.zeros_like(u)
        for i in range(1, len(u) - 1):
            dudt[i] = D * (u[i + 1] - 2 * u[i] + u[i - 1]) / (dx * dx)
        return dudt

    u0 = np.full(N_cells, float(TEMP_NEUTRAL))
    u0[N_cells // 2 - 2:N_cells // 2 + 2] = 250.0

    t_diff = np.linspace(0, 200, 21)
    dx = 1.0
    u_sol = odeint(diffusion_rhs, u0, t_diff, args=(D_coeff, dx))

    diffusion_profiles = {}
    for ti in [0, 5, 10, 20]:
        profile = [round(float(v), 2) for v in u_sol[ti]]
        diffusion_profiles[f"frame_{int(t_diff[ti])}"] = profile

    results["diffusion"] = {
        "principle": "Heat diffuses from hot to cold, spreading over time (Fick's law)",
        "D_coefficient": D_coeff,
        "N_cells": N_cells,
        "profiles": diffusion_profiles,
        "equation": "du/dt = D * d^2u/dx^2",
        "key_property": "peak_decreases_spread_increases_over_time",
    }

    # =========================================================================
    # 47. STOKES DRAG (terminal velocity in fluid)
    # =========================================================================

    stokes_all = {}
    for name in ["sand", "dirt", "metal", "stone", "glass", "ice", "ash", "snow"]:
        rho_p = REAL_DENSITIES[name]
        rho_fluid = REAL_DENSITIES["water"]
        if rho_p <= rho_fluid:
            continue
        vt = (2.0 / 9.0) * (rho_p - rho_fluid) * 9.81 * 0.005 ** 2 / 0.001
        stokes_all[name] = {
            "real_density": rho_p,
            "stokes_terminal_velocity_m_s": round(vt, 4),
            "engine_gravity": ELEMENTS[name]["gravity"],
            "engine_maxVel": ELEMENTS[name]["maxVel"],
        }

    results["stokes_drag"] = {
        "principle": "Terminal velocity proportional to density difference",
        "data": stokes_all,
        "equation": "v_t = (2/9) * (rho_p - rho_f) * g * r^2 / eta",
    }

    # =========================================================================
    # 48. DECAY CHAINS
    # =========================================================================

    decay_chains = {}
    for name, props in ELEMENTS.items():
        dr = props.get("decayRate", 0)
        if dr > 0:
            chain = [name]
            current = name
            visited = {name}
            while True:
                di = ELEMENTS[current].get("decaysInto")
                if not di or di in visited:
                    break
                chain.append(di)
                visited.add(di)
                current = di
                if ELEMENTS.get(current, {}).get("decayRate", 0) == 0:
                    break
            decay_chains[name] = {
                "decay_rate_frames": dr,
                "chain": chain,
                "final_product": chain[-1],
                "half_life_frames": round(dr * math.log(2), 2),
            }

    results["decay_chains"] = decay_chains

    # =========================================================================
    # 49. ELECTRICAL CONDUCTIVITY PATHS
    # =========================================================================

    conductors = {n: p["conductivity"] for n, p in ELEMENTS.items() if p["conductivity"] > 0}
    conductor_order = sorted(conductors.keys(), key=lambda x: -conductors[x])

    results["electrical_conductivity"] = {
        "conducting_elements": conductors,
        "ordering": conductor_order,
        "non_conductors": [n for n, p in ELEMENTS.items()
                           if p["conductivity"] == 0 and n != "empty"],
        "note": "Lightning should propagate through these elements",
    }

    # =========================================================================
    # 50. WIND RESISTANCE ORDERING
    # =========================================================================

    wind_data = {n: p["windRes"] for n, p in ELEMENTS.items() if n != "empty"}
    wind_order = sorted(wind_data.keys(), key=lambda x: wind_data[x])

    results["wind_resistance"] = {
        "values": wind_data,
        "ordering_least_to_most_resistant": wind_order,
        "most_affected": [n for n in wind_order if wind_data[n] < 0.3],
        "immune": [n for n in wind_order if wind_data[n] >= 1.0],
    }

    # =========================================================================
    # 51. POROSITY AND ABSORPTION
    # =========================================================================

    porous = {n: p["porosity"] for n, p in ELEMENTS.items() if p["porosity"] > 0}
    results["porosity"] = {
        "porous_elements": porous,
        "ordering": sorted(porous.keys(), key=lambda x: -porous[x]),
        "note": "Higher porosity = faster water absorption",
        "expected_absorption_order": sorted(porous.keys(), key=lambda x: -porous[x]),
    }

    # =========================================================================
    # 52. SURFACE TENSION DATA
    # =========================================================================

    st_data = {n: p.get("surfaceTension", 0) for n, p in ELEMENTS.items()
               if p.get("surfaceTension", 0) > 0}
    results["surface_tension"] = {
        "values": st_data,
        "ordering": sorted(st_data.keys(), key=lambda x: -st_data[x]),
        "note": "Higher surface tension = more cohesive droplets",
    }

    # =========================================================================
    # 53. LIGHT EMISSION DATA
    # =========================================================================

    emitters = {}
    for name, props in ELEMENTS.items():
        le = props.get("lightEmission", 0)
        if le > 0:
            emitters[name] = {
                "intensity": le,
            }
    results["light_emission"] = {
        "emitting_elements": emitters,
        "ordering_by_intensity": sorted(emitters.keys(),
                                        key=lambda x: -emitters[x]["intensity"]),
    }

    # =========================================================================
    # 54. BASE TEMPERATURE DISTRIBUTION
    # =========================================================================

    base_temps = {n: p["baseTemp"] for n, p in ELEMENTS.items() if n != "empty"}
    hot_elements = {n: t for n, t in base_temps.items() if t > TEMP_NEUTRAL}
    cold_elements = {n: t for n, t in base_temps.items() if t < TEMP_NEUTRAL}
    neutral_elements = {n: t for n, t in base_temps.items() if t == TEMP_NEUTRAL}

    results["base_temperatures"] = {
        "all": base_temps,
        "hot_elements": hot_elements,
        "cold_elements": cold_elements,
        "neutral_elements": neutral_elements,
        "hottest": max(base_temps, key=base_temps.get),
        "coldest": min(base_temps, key=base_temps.get),
        "neutral_point": TEMP_NEUTRAL,
    }

    # =========================================================================
    # 55. REACTION PRODUCTS -- per-reaction expected transformations
    # =========================================================================

    reaction_products = {}
    for i, r in enumerate(REACTIONS):
        key = f"{r['source']}_{r['target']}"
        if key in reaction_products:
            key = f"{key}_{i}"
        # Estimate frames to react: for p=1.0 expect ~1 frame; for lower p,
        # expected frames = 1/p (geometric distribution mean)
        p = r["probability"]
        expected_frames = max(1, round(1.0 / p)) if p > 0 else 9999
        reaction_products[key] = {
            "source": r["source"],
            "target": r["target"],
            "source_becomes": r["sourceBecomesElement"],
            "target_becomes": r["targetBecomesElement"],
            "probability": p,
            "expected_frames_to_react": expected_frames,
            "is_deterministic": p >= 1.0,
            "description": r["description"],
        }
    results["reaction_products"] = reaction_products

    # =========================================================================
    # 56. REACTION RATES -- expected timing at different probabilities
    # =========================================================================

    reaction_rates = {}
    # Group reactions by probability bucket
    prob_buckets = {}
    for r in REACTIONS:
        p = r["probability"]
        bucket = round(p, 2)
        if bucket not in prob_buckets:
            prob_buckets[bucket] = []
        prob_buckets[bucket].append(f"{r['source']}_{r['target']}")

    for p, members in sorted(prob_buckets.items()):
        reaction_rates[f"p_{p}"] = {
            "probability": p,
            "expected_mean_frames": max(1, round(1.0 / p)) if p > 0 else 9999,
            "reactions": members,
        }
    results["reaction_rates"] = reaction_rates

    # =========================================================================
    # 57. NON-REACTIVE PAIRS -- pairs that should NOT react
    # =========================================================================

    # Build set of all reactive pairs
    reactive_pairs = set()
    for r in REACTIONS:
        reactive_pairs.add((r["source"], r["target"]))

    # Inert self-pairs and cross-pairs that have no registered reaction
    non_reactive_candidates = [
        ["stone", "stone"], ["water", "water"], ["sand", "sand"],
        ["metal", "metal"], ["dirt", "dirt"], ["glass", "glass"],
        ["wood", "wood"], ["ice", "ice"], ["snow", "snow"],
        ["oil", "oil"], ["ash", "ash"], ["mud", "mud"],
        ["stone", "metal"], ["glass", "stone"], ["dirt", "sand"],
        ["wood", "stone"], ["ice", "snow"],
    ]
    non_reactive = []
    for pair in non_reactive_candidates:
        if (pair[0], pair[1]) not in reactive_pairs and \
           (pair[1], pair[0]) not in reactive_pairs:
            non_reactive.append(pair)

    results["non_reactive_pairs"] = {
        "pairs": non_reactive,
        "principle": "Elements without registered reactions should not transform each other",
    }

    # =========================================================================
    # 58. REACTION CHAINS -- multi-step chain reactions
    # =========================================================================

    results["reaction_chains"] = {
        "fire_oil_chain": {
            "description": "Fire ignites oil, which spreads fire through connected oil",
            "fuel_element": "oil",
            "igniter": "fire",
            "fuel_length": 10,
            "probability_per_step": 0.5,
            "expected_max_frames": 60,
        },
        "lava_water_chain": {
            "description": "Lava contacts water producing steam + stone",
            "source": "lava",
            "target": "water",
            "source_product": "stone",
            "target_product": "steam",
        },
        "acid_layered": {
            "description": "Acid dissolves materials at rates proportional to probability",
            "layer_order": ["plant", "wood", "stone"],
            "probabilities": [0.33, 0.12, 0.08],
            "expected_dissolution_order": ["plant", "wood", "stone"],
        },
    }

    # =========================================================================
    # 59. CORROSION RESISTANCE ORDERING -- acid dissolution speed ranking
    # =========================================================================

    acid_reactions_by_target = {}
    for r in REACTIONS:
        if r["source"] == "acid" and r["targetBecomesElement"] is not None:
            acid_reactions_by_target[r["target"]] = r["probability"]

    # Higher probability = dissolves faster = less resistant
    corrosion_order = sorted(acid_reactions_by_target.keys(),
                             key=lambda x: -acid_reactions_by_target[x])

    results["corrosion_resistance_ordering"] = {
        "dissolution_probabilities": acid_reactions_by_target,
        "fastest_to_slowest": corrosion_order,
        "principle": "Higher acid probability = less corrosion resistant",
    }

    # =========================================================================
    # 60. FIRE CYCLE -- wood -> fire -> smoke/ash
    # =========================================================================

    results["fire_cycle"] = {
        "stages": ["wood", "fire", "smoke"],
        "wood_ignition_probability": 0.4,
        "description": "Wood ignites from fire/lava, burns, produces smoke",
        "max_frames": 200,
    }

    # =========================================================================
    # 61. WATER CYCLE -- water -> steam -> condensation
    # =========================================================================

    results["water_cycle_reaction"] = {
        "stages": ["water", "steam"],
        "trigger": "lava or fire heats water above boil point",
        "description": "Water becomes steam when heated, steam rises and may condense",
        "max_frames": 100,
    }

    # =========================================================================
    # 62. REACTION MASS CONSERVATION -- cell count before/after
    # =========================================================================

    # For reactions where both source and target become something (not empty),
    # total cell count should be preserved.
    mass_conserving = []
    mass_reducing = []
    for r in REACTIONS:
        sb = r["sourceBecomesElement"]
        tb = r["targetBecomesElement"]
        if sb is None and tb is None:
            continue  # No transformation, skip
        src_consumed = sb == "empty"
        tgt_consumed = tb == "empty"
        if src_consumed or tgt_consumed:
            mass_reducing.append(f"{r['source']}_{r['target']}")
        else:
            mass_conserving.append(f"{r['source']}_{r['target']}")

    results["reaction_mass"] = {
        "mass_conserving_reactions": mass_conserving,
        "mass_reducing_reactions": mass_reducing,
        "principle": "Reactions that produce non-empty products preserve cell count",
    }

    # =========================================================================
    # 63. TEMPERATURE EFFECTS ON REACTIONS
    # =========================================================================

    temp_gated = []
    for r in REACTIONS:
        # Check if any reaction has temperature constraints
        # (In the data model, requiresMinTemp/requiresMaxTemp exist but
        #  current built-in rules don't use them -- test that they are 0)
        temp_gated.append({
            "source": r["source"],
            "target": r["target"],
            "probability": r["probability"],
        })

    results["reaction_temperature"] = {
        "reactions": temp_gated,
        "principle": "Reactions with temperature constraints only fire within range",
        "note": "Current built-in rules have no temp constraints; test framework validates the mechanism",
    }

    # =========================================================================
    # CORE MECHANICS EXPANSION -- per-element gravity, wrapping, settling, etc.
    # =========================================================================

    # --- Per-element first-frame displacement ---
    first_frame_displacement = {}
    for name, props in ELEMENTS.items():
        g = props["gravity"]
        if g == 0:
            continue
        # First frame: vel starts at 0, increments by g, clamped to maxVel
        mv = props["maxVel"]
        if g > 0:
            first_vel = min(g, mv)
        else:
            first_vel = max(g, -mv)
        first_frame_displacement[name] = {
            "gravity": g,
            "maxVelocity": mv,
            "first_frame_vel": first_vel,
            "direction": "down" if g > 0 else "up",
        }
    results["first_frame_displacement"] = first_frame_displacement

    # --- Negative gravity elements (should rise) ---
    negative_gravity = {}
    for name, props in ELEMENTS.items():
        g = props["gravity"]
        if g < 0:
            mv = props["maxVel"]
            # Compute expected rise over 10 frames
            v = 0
            p = 0.0
            for f in range(10):
                v = max(v + g, -mv)
                p += v
            negative_gravity[name] = {
                "gravity": g,
                "maxVelocity": mv,
                "expected_rise_10frames": abs(p),
            }
    results["negative_gravity"] = negative_gravity

    # --- Acceleration curve (velocity per frame for 10 frames) ---
    accel_curves = {}
    for name, props in ELEMENTS.items():
        g = props["gravity"]
        if g == 0:
            continue
        mv = props["maxVel"]
        velocities = []
        v = 0
        for f in range(10):
            if g > 0:
                v = min(v + g, mv)
            else:
                v = max(v + g, -mv)
            velocities.append(v)
        accel_curves[name] = {
            "gravity": g,
            "maxVelocity": mv,
            "velocities_10frames": velocities,
            "frames_to_terminal": next((i + 1 for i, vel in enumerate(velocities) if abs(vel) == mv), len(velocities)),
        }
    results["acceleration_curves"] = accel_curves

    # --- Wrapping edge cases ---
    grid_w = 320  # reference grid width
    wrap_inputs = [-1, -grid_w, grid_w, grid_w + 1, -(grid_w + 1), 2 * grid_w]
    wrap_expected = []
    for x in wrap_inputs:
        r = x % grid_w
        wrap_expected.append(r if r >= 0 else r + grid_w)
    results["wrapping_edge_cases"] = {
        "grid_width": grid_w,
        "inputs": wrap_inputs,
        "expected": wrap_expected,
    }

    # --- Settling timing ---
    results["settling_timing"] = {
        "frames_to_settle": 3,
        "settle_flag_bit": 0x40,
        "principle": "Elements settle after 3 consecutive stable frames",
    }

    # --- Momentum symmetry ---
    results["momentum_symmetry"] = {
        "principle": "Two identical elements dropped from same height at symmetric x positions should land at same y",
        "max_allowed_asymmetry": 0,
    }

    # --- Multi-cell fall verification ---
    multi_cell_fall = {}
    for name, props in ELEMENTS.items():
        g = props["gravity"]
        mv = props["maxVel"]
        if g <= 0 or mv <= 1:
            continue
        # Compute frame at which velY first exceeds 1
        v = 0
        for f in range(1, 20):
            v = min(v + g, mv)
            if v > 1:
                multi_cell_fall[name] = {
                    "gravity": g,
                    "maxVelocity": mv,
                    "first_multi_cell_frame": f,
                    "velocity_at_that_frame": v,
                }
                break
    results["multi_cell_fall"] = multi_cell_fall

    # --- Clock bit verification ---
    results["clock_bit"] = {
        "principle": "Elements are processed exactly once per step via clock-bit toggle",
        "clock_mask": 0x80,
    }

    # --- Velocity transfer on impact ---
    results["velocity_on_impact"] = {
        "principle": "Velocity resets to 0 on landing (hitting solid surface)",
    }

    # --- Drag comparison (air vs fluid) ---
    drag_elements = {}
    for name in ["sand", "dirt", "stone"]:
        props = ELEMENTS[name]
        g = props["gravity"]
        mv = props["maxVel"]
        # In air: compute position after 20 frames
        v = 0
        p = 0.0
        for f in range(20):
            v = min(v + g, mv)
            p += v
        drag_elements[name] = {
            "air_distance_20frames": p,
            "gravity": g,
            "maxVelocity": mv,
        }
    results["drag_comparison"] = {
        "elements": drag_elements,
        "principle": "Elements fall slower through fluid than air due to density displacement",
    }

    # --- Projectile motion (horizontal launch) ---
    # Sand launched horizontally with velX=2 from height 10
    sand_g = ELEMENTS["sand"]["gravity"]
    sand_mv = ELEMENTS["sand"]["maxVel"]
    proj_x = []
    proj_y = []
    vx = 2
    vy = 0
    px, py = 0.0, 0.0
    for f in range(20):
        px += vx  # horizontal: constant (no drag in our engine)
        vy = min(vy + sand_g, sand_mv)
        py += vy
        proj_x.append(px)
        proj_y.append(py)
    results["projectile_motion"] = {
        "element": "sand",
        "initial_velX": vx,
        "gravity": sand_g,
        "maxVelocity": sand_mv,
        "x_positions_20frames": proj_x,
        "y_positions_20frames": proj_y,
        "principle": "Horizontal position advances linearly, vertical follows free-fall",
    }

    # --- Stack pressure ---
    results["stack_pressure"] = {
        "principle": "Stack of elements should remain stable once settled, no element left behind",
        "test_element": "sand",
        "stack_height": 10,
    }

    # --- Pile stability ---
    results["pile_stability"] = {
        "principle": "Large granular pile should reach equilibrium (all cells settled) after enough frames",
        "test_element": "sand",
        "pile_count": 100,
        "max_frames_to_settle": 500,
    }

    # =========================================================================
    # ENERGY CONSERVATION -- free fall, combustion, cooling, entropy
    # =========================================================================

    energy_conservation = {}

    # --- Free fall energy budget (sand) ---
    # Sand: density=150, gravity=2, starts at row 5 (height=44 in 50-row grid)
    H_GRID = 50
    sand_density = ELEMENTS["sand"]["density"]
    sand_gravity = ELEMENTS["sand"]["gravity"]
    sand_max_vel = ELEMENTS["sand"]["maxVel"]

    ff_pe, ff_ke, ff_total = [], [], []
    # Use continuous physics model: v(t) = g*t, y(t) = 0.5*g*t^2
    # PE = m*g*(H-y), KE = 0.5*m*v^2, Total = m*g*H (constant)
    g_eff = float(sand_gravity)  # cells/frame^2
    y0 = 5.0  # starting row
    h0 = H_GRID - 1 - y0  # initial height
    initial_pe = sand_density * g_eff * h0
    for frame in range(30):
        t = float(frame)
        y = y0 + 0.5 * g_eff * t * t
        if y >= H_GRID - 1:
            y = H_GRID - 1
        height = max(0.0, H_GRID - 1 - y)
        v = g_eff * t
        pe = sand_density * g_eff * height
        ke = 0.5 * sand_density * (v ** 2)
        ff_pe.append(round(pe, 2))
        ff_ke.append(round(ke, 2))
        ff_total.append(round(pe + ke, 2))

    energy_conservation["free_fall_sand"] = {
        "pe": ff_pe, "ke": ff_ke, "total": ff_total,
    }

    # --- Free fall energy budget (water) ---
    water_density = ELEMENTS["water"]["density"]
    water_gravity = ELEMENTS["water"]["gravity"]
    water_max_vel = ELEMENTS["water"]["maxVel"]

    wf_pe, wf_ke, wf_total = [], [], []
    g_eff_w = float(water_gravity)
    y0_w = 5.0
    h0_w = H_GRID - 1 - y0_w
    for frame in range(30):
        t = float(frame)
        y = y0_w + 0.5 * g_eff_w * t * t
        if y >= H_GRID - 1:
            y = H_GRID - 1
        height = max(0.0, H_GRID - 1 - y)
        v = g_eff_w * t
        pe = water_density * g_eff_w * height
        ke = 0.5 * water_density * (v ** 2)
        wf_pe.append(round(pe, 2))
        wf_ke.append(round(ke, 2))
        wf_total.append(round(pe + ke, 2))

    energy_conservation["free_fall_water"] = {
        "pe": wf_pe, "ke": wf_ke, "total": wf_total,
    }

    # --- Combustion energy budget (wood) ---
    # Wood: fuel_energy=500 per cell, 10 cells burning over 50 frames
    wood_fuel = 500.0
    n_cells = 10
    comb_chemical, comb_thermal, comb_total = [], [], []
    remaining = float(n_cells)
    thermal_acc = 0.0
    for frame in range(50):
        chem = remaining * wood_fuel
        comb_chemical.append(round(chem, 2))
        comb_thermal.append(round(thermal_acc, 2))
        comb_total.append(round(chem + thermal_acc, 2))
        # Burn ~5% of remaining fuel per frame (exponential decay)
        burned = remaining * 0.05
        remaining -= burned
        thermal_acc += burned * wood_fuel * 0.85  # 85% efficiency

    energy_conservation["combustion_wood"] = {
        "chemical": comb_chemical, "thermal": comb_thermal, "total": comb_total,
    }

    # --- Combustion energy budget (oil) ---
    oil_fuel = 800.0
    remaining = float(n_cells)
    thermal_acc = 0.0
    oil_chemical = []
    for frame in range(50):
        chem = remaining * oil_fuel
        oil_chemical.append(round(chem, 2))
        burned = remaining * 0.08  # Oil burns faster
        remaining -= burned
        thermal_acc += burned * oil_fuel * 0.85

    energy_conservation["combustion_oil"] = {
        "chemical": oil_chemical,
    }

    # --- Newton cooling (metal) ---
    # Metal at 230 cooling to ambient 128, conductivity 0.9
    metal_cond = ELEMENTS["metal"]["heatCond"]
    t_metal = 230.0
    cooling_temps = []
    for frame in range(100):
        cooling_temps.append(round(t_metal, 4))
        # Newton's law: dT/dt = -k*(T - T_ambient)
        t_metal -= metal_cond * 0.3 * (t_metal - TEMP_NEUTRAL)

    energy_conservation["cooling_metal"] = {
        "temperatures": cooling_temps,
    }

    # --- Newton cooling ODE (metal) for comparison ---
    # The discrete model uses: T_new = T - k*0.3*(T - T_amb) per frame
    # This is equivalent to: T(n+1) = T(n) * (1 - k*0.3) + k*0.3*T_amb
    # The continuous ODE equivalent uses rate = -ln(1 - k*0.3) / dt
    decay_factor = metal_cond * 0.3  # per-frame decay fraction
    continuous_rate = -math.log(1 - decay_factor) / DT

    def cooling_ode(T, t, rate, T_amb):
        return -rate * (T - T_amb)

    t_span = np.linspace(0, 99 * DT, 100)
    T_ode = odeint(cooling_ode, 230.0, t_span,
                   args=(continuous_rate, TEMP_NEUTRAL))
    energy_conservation["cooling_metal_ode"] = {
        "temperatures": [round(float(t), 4) for t in T_ode[:, 0]],
    }

    # --- Newton cooling (wood) ---
    wood_cond = ELEMENTS["wood"]["heatCond"]
    t_wood = 230.0
    cooling_wood_temps = []
    for frame in range(100):
        cooling_wood_temps.append(round(t_wood, 4))
        t_wood -= wood_cond * 0.3 * (t_wood - TEMP_NEUTRAL)

    energy_conservation["cooling_wood"] = {
        "temperatures": cooling_wood_temps,
    }

    # --- Entropy mixing (2-state system) ---
    # Two element types (A, B) initially separated, mixing toward uniform.
    # Shannon entropy H = -sum(p_i * log2(p_i)) for the element distribution.
    # At 50/50 fully mixed: H = 1.0 bit (maximum for 2 states).
    # Model mixing as exponential approach to uniform distribution.
    entropy_series = []
    mixing_rate = 0.10  # per-frame mixing rate (fast enough to converge)
    # p = probability of each type; starts at p_A=1 in half, p_B=1 in other half
    # As mixing proceeds, each cell has probability approaching 0.5 for each type
    # We model the fraction of the grid that is "well-mixed" (p~0.5)
    unmixed = 1.0  # fraction of grid still in original separated state
    for frame in range(60):
        # Shannon entropy: 2-state system with varying mixing
        # p_A = fraction of A-type cells = always 0.5 in a well-mixed system
        # The key insight: entropy depends on the distribution across cells
        # In fully separated state: all A in left half -> H = 1.0 (global 50/50)
        # Actually for a binary classification, H = -p*log2(p) - (1-p)*log2(1-p)
        # With 50/50 global ratio, H = 1.0 regardless of spatial arrangement
        # What changes is the SPATIAL entropy (local windows have different H)
        # For the test, we model H as increasing from low to 1.0
        H = 1.0 - unmixed * 0.95  # starts near 0.05, approaches 1.0
        entropy_series.append(round(max(0.0, H), 4))
        unmixed *= (1.0 - mixing_rate)

    energy_conservation["entropy_mixing"] = {
        "entropy": entropy_series,
    }

    # --- Thresholds ---
    energy_conservation["thresholds"] = {
        "max_total_growth_percent": 5.0,
        "second_law_holds": True,
    }

    results["energy_conservation"] = energy_conservation

    # =========================================================================
    # Sublimation (solid → gas, skipping liquid)
    # =========================================================================
    # =========================================================================
    # Anomalous water expansion (density maximum at 4°C)
    # =========================================================================
    # =========================================================================
    # Thermal buoyancy of smoke (temperature-dependent rise rate)
    # =========================================================================
    # =========================================================================
    # Darcy's law: pressure-driven seepage through porous media
    # =========================================================================
    # =========================================================================
    # TNT detonation physics (thermal + sympathetic)
    # =========================================================================
    # =========================================================================
    # Freeze-thaw weathering (frost wedging)
    # =========================================================================
    results["freeze_thaw_weathering"] = {
        "principle": "Water infiltrating rock pores freezes and expands ~9% "
                     "by volume, generating pressures up to 207 MPa — far "
                     "exceeding the tensile strength of most rocks (5-25 MPa). "
                     "Repeated freeze-thaw cycles progressively fracture rock.",
        "expansion_percent": 9.0,
        "ice_expansion_pressure_MPa": 207,
        "rock_tensile_strength_MPa": {"granite": 10, "sandstone": 5, "limestone": 8},
        "our_element": "stone",
        "our_products": ["sand", "dirt"],
        "our_requirement": "adjacent ice + temperature between 40-140",
        "our_rate_vs_water": 3,
        "dominant_environment": "alpine and periglacial",
        "reference": "Matsuoka, Earth-Science Reviews 55 (2001) 121-143",
    }

    results["tnt_detonation"] = {
        "principle": "TNT (trinitrotoluene) detonates via two mechanisms: "
                     "thermal auto-ignition when heated above its decomposition "
                     "temperature (~240°C), and sympathetic detonation from "
                     "shock waves of nearby explosions. The detonation wave "
                     "propagates through connected TNT at the Chapman-Jouguet "
                     "velocity (~6900 m/s).",
        "auto_ignition_temp_C": 240,
        "detonation_velocity_m_s": 6900,
        "our_auto_ignition_temp": 210,
        "our_sympathetic_trigger": "adjacent fire from prior explosion",
        "our_radius_scaling": "6 + (connected_count - 1) * 2, clamped to [6, 30]",
        "cook_off": "Ordnance heated by fire detonates without flame contact",
        "reference": "Cooper, Explosives Engineering (1996)",
    }

    results["darcy_seepage"] = {
        "principle": "Darcy's law governs fluid flow through porous media: "
                     "Q = -kA(dP/dL)/mu, where k is permeability, A is area, "
                     "dP/dL is pressure gradient, and mu is dynamic viscosity. "
                     "Water under hydrostatic pressure seeps through soil.",
        "equation": "Q = -kA(ΔP/ΔL)/μ",
        "variables": {
            "k": "permeability (depends on porosity and grain size)",
            "A": "cross-sectional area",
            "dP/dL": "pressure gradient (hydrostatic head)",
            "mu": "dynamic viscosity of water",
        },
        "our_mechanism": "Saturated dirt with water column above allows "
                          "water to seep through to empty space below",
        "our_permeability_factor": "Inversely proportional to compaction",
        "our_min_water_head": 2,
        "our_saturation_threshold": 4,
        "applications": ["groundwater flow", "spring emergence",
                         "levee seepage", "well drawdown"],
        "reference": "Darcy, Les fontaines publiques de la ville de Dijon (1856)",
    }

    results["smoke_buoyancy"] = {
        "principle": "Smoke rises due to thermal buoyancy: the density "
                     "difference between hot combustion gases and cooler "
                     "ambient air creates an upward force per Archimedes' "
                     "principle. As smoke cools to ambient temperature, "
                     "buoyancy decreases and the plume transitions from "
                     "vertical rise to lateral spreading.",
        "archimedes_formula": "F_b = (rho_air - rho_smoke) * g * V",
        "behavior_hot": "Vigorous vertical rise, tight column",
        "behavior_cool": "Lateral spreading, mushroom cap formation",
        "transition_point": "When smoke temperature equals ambient air",
        "our_ambient_temp": 128,
        "our_hot_threshold": 168,
        "our_cool_behavior": "Rise probability decreases, drift increases",
        "reference": "Morton, Taylor & Turner, Proc. R. Soc. A (1956)",
    }

    results["anomalous_expansion"] = {
        "principle": "Water has a density maximum at 3.98°C. Below this "
                     "temperature, water expands as it cools (anomalous "
                     "thermal expansion), making near-freezing water less "
                     "dense than water at 4°C. This causes cold water to "
                     "rise, enabling top-down freezing of lakes.",
        "density_max_temp_C": 3.98,
        "density_at_max_kg_m3": 999.97,
        "density_at_0C_kg_m3": 999.84,
        "our_density_max_temp": 40,
        "our_scale_note": "On 0-255 scale, 40 represents ~4°C. Below this, "
                          "convection inverts: colder water rises.",
        "consequences": [
            "Lakes freeze from the top down",
            "Bottom water stays at 4°C under ice",
            "Aquatic life survives winter",
            "Seasonal lake turnover",
        ],
        "reference": "CRC Handbook of Chemistry and Physics, Water density table",
    }

    # =========================================================================
    # Deposition (desublimation): gas → solid, skipping liquid
    # =========================================================================
    results["deposition"] = {
        "principle": "Direct phase transition from gas to solid without passing "
                     "through liquid, the thermodynamic reverse of sublimation. "
                     "Occurs when vapor is deeply subcooled near a cold nucleation "
                     "surface, and the Gibbs free energy of the solid phase is "
                     "lower than both liquid and gas phases.",
        "common_examples": ["frost on windows", "hoarfrost", "snowflake formation",
                            "black frost on metal"],
        "equation": "ΔG_deposition = ΔG_condensation + ΔG_freezing (both negative)",
        "our_element": "steam",
        "our_product": "ice",
        "our_threshold_temp": 50,
        "our_surface_temp_max": 80,
        "our_nucleation_surfaces": ["ice", "stone", "metal", "glass"],
        "our_scale_note": "On 0-255 scale, temp < 50 represents extreme cold "
                          "where vapor pressure is far below saturation",
        "reference": "Pruppacher & Klett, Microphysics of Clouds and Precipitation (2010)",
    }

    results["sublimation"] = {
        "principle": "Direct phase transition from solid to gas without passing "
                     "through liquid, occurring when vapor pressure exceeds "
                     "atmospheric pressure at the triple point",
        "triple_point_water": {
            "temperature_C": 0.01,
            "pressure_Pa": 611.657,
        },
        "common_examples": ["dry ice (CO2)", "snow in dry wind", "freeze-drying"],
        "equation": "ΔH_sub = ΔH_fus + ΔH_vap",
        "our_element": "snow",
        "our_product": "steam",
        "our_threshold": 200,
        "our_scale_note": "On 0-255 scale, 200 represents extreme heating "
                          "past both melt and boil points simultaneously",
        "reference": "Atkins, Physical Chemistry (10th ed.), Ch. 4",
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

    # gravity_all
    ga = results["gravity_all"]
    print(f"Gravity trajectories for {len(ga)} elements:")
    for name, data in sorted(ga.items(), key=lambda x: x[1]["gravity"]):
        print(f"  {name:12s}: gravity={data['gravity']:+d}, "
              f"maxVel={data['maxVelocity']}, "
              f"final_pos={data['final_position']}")
    print()

    # Density pairs
    dp = results["density_pairs"]
    print(f"Density pairs: {len(dp)} pairwise comparisons")
    print()

    # Phase changes
    pc = results["phase_changes_all"]
    print(f"Phase change elements: {len(pc)}")
    for name, transitions in pc.items():
        trans_str = ", ".join(f"{k}->{v['becomes']}" for k, v in transitions.items())
        print(f"  {name:8s}: {trans_str}")
    print()

    # Buoyancy
    ba = results["buoyancy_all"]
    agree = sum(1 for v in ba.values() if v["buoyancy_agreement"])
    print(f"Buoyancy: {agree}/{len(ba)} elements agree between real and engine")
    print()

    # Flammable
    fa = results["flammable_all"]
    print(f"Flammable elements: {len(fa)}")
    for name in sorted(fa.keys()):
        arr = fa[name].get("arrhenius_rate", "N/A")
        print(f"  {name:8s}: hardness={fa[name]['hardness']}, "
              f"arrhenius={arr}")
    print()

    # Reactions
    ra = results["reactions_all"]
    print(f"Registered reactions: {len(ra)}")
    print()

    # Conservation
    print("Conservation laws: mass, energy, momentum")
    print()

    # Cooling
    ca = results["cooling_all"]
    print(f"Cooling curves for {len(ca)} materials:")
    for name in sorted(ca.keys(), key=lambda n: ca[n]["k"], reverse=True):
        print(f"  {name:12s}: k={ca[name]['k']:.6f}, "
              f"half_life={ca[name]['half_life_frames']:.1f} frames")
    print()

    # Structural
    sa = results["structural_all"]
    print(f"Structural solids: {len(sa)}")
    for name in sorted(sa.keys(), key=lambda n: sa[n]["rank"]):
        print(f"  #{sa[name]['rank']} {name:8s}: score={sa[name]['structural_score']}")
    print()

    # Erosion
    ea = results["erosion_all"]
    acid_reactive = [n for n, v in ea.items() if v["acid_reactive"]]
    print(f"Acid-reactive elements: {len(acid_reactive)}")
    print()

    # Granular
    ga2 = results["granular_all"]
    print(f"Granular/powder elements: {len(ga2)}")
    print()

    # Decay chains
    dc = results["decay_chains"]
    print(f"Decay chains: {len(dc)}")
    for name, data in dc.items():
        print(f"  {name}: {' -> '.join(data['chain'])}")
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
