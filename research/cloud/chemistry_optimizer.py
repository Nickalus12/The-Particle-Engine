#!/usr/bin/env python3
"""Optuna Chemistry Optimizer: tune element properties against real-world data.

Optimizes properties for existing and proposed elements (hydrogen, sulfur,
copper, silicon) so that simulation behavior matches known chemistry:
  - Acid + metal should produce hydrogen at rate X
  - Rusting rate should match known Fe/O2 electrochemistry
  - Density ordering must match real-world sink/float
  - Thermal equilibrium should follow Fourier's law
  - Conductivity should follow Ohm's law

Multi-objective: maximize chemistry_accuracy AND physics_realism.

Usage:
    python3 cloud/chemistry_optimizer.py run --n-trials 200
    python3 cloud/chemistry_optimizer.py show --top 10
"""

from __future__ import annotations

import argparse
import json
import logging
import math
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np

try:
    import optuna
    from optuna.samplers import TPESampler
except ImportError:
    print("Optuna required: pip install optuna", file=sys.stderr)
    sys.exit(1)

try:
    import cupy as cp
    HAS_GPU = True
except ImportError:
    cp = np
    HAS_GPU = False

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("chem_opt")

SCRIPT_DIR = Path(__file__).resolve().parent
RESEARCH_DIR = SCRIPT_DIR.parent
STUDY_DB = RESEARCH_DIR / "chemistry_optuna_study.db"

# ===================================================================
# Real-World Chemistry Targets (ground truth from research)
# ===================================================================

# Target reaction rates at game temperature 128 (room temperature)
# Rate = fraction of interactions that produce a reaction per tick
TARGET_REACTION_RATES = {
    # (source, target): expected_rate
    ("metal", "oxygen"):    0.02,   # slow rusting
    ("metal", "acid"):      0.30,   # vigorous dissolution
    ("charcoal", "oxygen"): 0.00,   # needs temp > 349C to ignite
    ("acid", "stone"):      0.15,   # moderate dissolution
    ("acid", "glass"):      0.01,   # glass resists HCl (real chemistry!)
    ("acid", "wood"):       0.20,   # dissolves organic
    ("acid", "clay"):       0.25,   # vigorous (Al in clay)
    ("fire", "wood"):       0.80,   # spreads fire fast
    ("fire", "ice"):        1.00,   # deterministic melting
    ("lava", "water"):      1.00,   # deterministic quenching
    ("water", "salt"):      0.50,   # salt dissolves in water
}

# Target density ordering — real kg/m3, game density must preserve order
DENSITY_ORDER = [
    ("steam", 0.59), ("methane", 0.66), ("smoke", 1.1), ("oxygen", 1.43),
    ("co2", 1.98), ("snow", 100), ("charcoal", 350), ("wood", 600),
    ("oil", 848), ("ice", 920), ("water", 998), ("acid", 1180),
    ("honey", 1420), ("sand", 1600), ("salt", 2160), ("glass", 2500),
    ("stone", 2600), ("rust", 5240), ("metal", 7800),
]

# Target thermal equilibrium: material pairs at given temps should converge
THERMAL_TARGETS = {
    # (mat_a, mat_b, temp_a, temp_b): expected equilibrium temp
    ("water", "water", 200, 56): 128,     # equal mass => average
    ("metal", "water", 200, 128): 135,    # metal heats water (low Cp metal)
    ("stone", "water", 200, 128): 140,    # stone heats water more (lower Cp)
}

# Proposed new elements — parameter ranges to optimize
NEW_ELEMENTS = {
    "hydrogen": {
        "density": (1, 5),
        "conductivity": (0, 10),
        "heat_capacity": (8, 10),
        "ignition_temp": (50, 100),
        "reduction_potential": (-0.5, 0.5),
        "heat_of_combustion": (200, 255),
    },
    "sulfur": {
        "density": (140, 170),
        "conductivity": (0, 5),
        "heat_capacity": (1, 3),
        "ignition_temp": (25, 50),
        "reduction_potential": (-0.7, -0.1),
        "heat_of_combustion": (100, 180),
    },
    "copper": {
        "density": (240, 255),
        "conductivity": (240, 255),
        "heat_capacity": (1, 2),
        "corrosion_resistance": (150, 250),
        "reduction_potential": (0.1, 0.6),
        "thermal_conductivity": (200, 255),
    },
    "silicon": {
        "density": (180, 200),
        "conductivity": (20, 100),    # semiconductor — variable!
        "heat_capacity": (1, 3),
        "reduction_potential": (-1.2, -0.5),
        "thermal_conductivity": (100, 200),
    },
}

# Existing elements — fine-tune properties
EXISTING_TUNE = {
    "metal_conductivity": (220, 255),
    "metal_corrosion_res": (70, 120),
    "metal_heat_cond": (200, 255),
    "water_conductivity": (50, 120),
    "water_heat_capacity": (8, 10),
    "acid_ph": (0, 10),            # game-scaled pH (0 = pH 0.0)
    "acid_conductivity": (100, 200),
    "glass_corrosion_res": (200, 255),
    "charcoal_conductivity": (150, 230),
    "lava_conductivity": (30, 100),
    "salt_conductivity_in_water": (100, 180),
}


# ===================================================================
# Simulation Functions
# ===================================================================

def simulate_reaction(
    params: dict[str, Any],
    source: str, target: str,
    temperature: int = 128,
    num_trials: int = 500,
) -> float:
    """Simulate reaction rate between two elements at given temperature.

    Returns fraction of trials where a reaction occurred.
    """
    xp = cp if HAS_GPU else np
    rng = np.random.default_rng(42)

    # Get properties
    source_e0 = params.get(f"{source}_reduction_potential",
                            get_default_e0(source))
    target_e0 = params.get(f"{target}_reduction_potential",
                            get_default_e0(target))
    source_ph = params.get(f"{source}_ph", get_default_ph(source))
    target_corr = params.get(f"{target}_corrosion_res",
                              get_default_corrosion(target))
    source_flammable = is_flammable(source)
    target_flammable = is_flammable(target)
    target_ign = params.get(f"{target}_ignition_temp",
                             get_default_ignition(target))

    # Vectorized Monte Carlo
    rand_vals = rng.random(num_trials).astype(np.float32)
    reactions = np.zeros(num_trials, dtype=np.int32)

    # 1. Redox check
    voltage_gap = abs(target_e0 - source_e0)
    if voltage_gap > 0.3:
        prob = min(voltage_gap * 0.2, 1.0) * min(temperature / 128.0, 2.0)
        reactions |= (rand_vals < prob).astype(np.int32)

    # 2. Acid-base check
    if source_ph < 50:  # acid
        ph_strength = (70 - source_ph) / 70.0
        resistance = target_corr / 255.0
        dissolve_prob = max(ph_strength - resistance, 0.0)
        rand_vals2 = rng.random(num_trials).astype(np.float32)
        reactions |= (rand_vals2 < dissolve_prob).astype(np.int32)

    # 3. Combustion check
    if target_flammable and temperature > target_ign and source == "oxygen":
        reactions[:] = 1  # guaranteed if hot enough with O2

    # 4. Fire spread
    if source == "fire" and target_flammable and temperature > target_ign:
        fire_prob = min(temperature / 200.0, 0.95)
        rand_vals3 = rng.random(num_trials).astype(np.float32)
        reactions |= (rand_vals3 < fire_prob).astype(np.int32)

    # 5. Phase change (deterministic)
    if source == "fire" and target in ("ice", "snow"):
        reactions[:] = 1
    if source == "lava" and target == "water":
        reactions[:] = 1

    return float(np.mean(reactions))


def simulate_thermal_equilibrium(
    params: dict,
    mat_a: str, mat_b: str,
    temp_a: int, temp_b: int,
    steps: int = 200,
) -> float:
    """Simulate thermal equilibrium between two materials."""
    k_a = params.get(f"{mat_a}_heat_cond", get_default_k(mat_a))
    k_b = params.get(f"{mat_b}_heat_cond", get_default_k(mat_b))
    cp_a = params.get(f"{mat_a}_heat_capacity", get_default_cp(mat_a))
    cp_b = params.get(f"{mat_b}_heat_capacity", get_default_cp(mat_b))

    t_a = float(temp_a)
    t_b = float(temp_b)
    k_avg = (k_a + k_b) / 2.0 / 255.0  # normalize

    for _ in range(steps):
        dt = k_avg * (t_b - t_a)
        t_a += dt / max(cp_a, 1)
        t_b -= dt / max(cp_b, 1)

    return (t_a + t_b) / 2.0


def check_density_ordering(params: dict) -> float:
    """Score how well game densities preserve real-world ordering."""
    correct = 0
    total = 0
    for i in range(len(DENSITY_ORDER) - 1):
        name_a, real_a = DENSITY_ORDER[i]
        name_b, real_b = DENSITY_ORDER[i + 1]
        game_a = params.get(f"{name_a}_density", get_default_density(name_a))
        game_b = params.get(f"{name_b}_density", get_default_density(name_b))
        total += 1
        if game_a < game_b:
            correct += 1
    return correct / max(total, 1)


# ===================================================================
# Default value lookups
# ===================================================================

_DEFAULT_E0 = {
    "metal": -0.44, "oxygen": 1.229, "acid": 1.396, "charcoal": -0.106,
    "sand": -0.909, "glass": -0.909, "salt": -2.713, "clay": -1.676,
    "rust": 0.771, "lava": -0.909, "co2": -0.106,
}

_DEFAULT_PH = {"acid": 0, "co2": 36, "honey": 40, "water": 70, "ash": 100}
_DEFAULT_CORR = {"metal": 90, "stone": 60, "glass": 250, "ice": 40, "wood": 30, "clay": 35}
_DEFAULT_IGN = {"oil": 31, "wood": 45, "charcoal": 52, "methane": 87, "plant": 45}
_DEFAULT_K = {"metal": 240, "stone": 30, "water": 8, "wood": 2, "ice": 28, "glass": 14}
_DEFAULT_CP = {"water": 10, "metal": 1, "stone": 2, "wood": 4, "ice": 5}
_DEFAULT_DENSITY = {
    "steam": 1, "methane": 2, "smoke": 2, "oxygen": 3, "co2": 5,
    "snow": 35, "charcoal": 120, "wood": 175, "oil": 58, "ice": 170,
    "water": 65, "acid": 72, "honey": 82, "sand": 150, "salt": 155,
    "glass": 195, "stone": 200, "rust": 220, "metal": 240,
}
_FLAMMABLE = {"wood", "oil", "plant", "seed", "methane", "charcoal", "fungus", "spore", "compost", "honey", "tnt"}


def get_default_e0(elem): return _DEFAULT_E0.get(elem, 0.0)
def get_default_ph(elem): return _DEFAULT_PH.get(elem, 255)
def get_default_corrosion(elem): return _DEFAULT_CORR.get(elem, 0)
def get_default_ignition(elem): return _DEFAULT_IGN.get(elem, 0)
def get_default_k(elem): return _DEFAULT_K.get(elem, 1)
def get_default_cp(elem): return _DEFAULT_CP.get(elem, 2)
def get_default_density(elem): return _DEFAULT_DENSITY.get(elem, 128)
def is_flammable(elem): return elem in _FLAMMABLE


# ===================================================================
# Optuna Objective
# ===================================================================

def objective(trial: optuna.Trial) -> tuple[float, float]:
    """Multi-objective: (chemistry_accuracy, physics_realism).

    chemistry_accuracy: how closely reaction rates match real-world targets
    physics_realism: density ordering + thermal + electrical correctness
    """
    params: dict[str, Any] = {}

    # 1. Tune existing element properties
    for name, (lo, hi) in EXISTING_TUNE.items():
        if isinstance(lo, float):
            params[name] = trial.suggest_float(name, lo, hi)
        else:
            params[name] = trial.suggest_int(name, lo, hi)

    # 2. Tune new element properties
    for elem, props in NEW_ELEMENTS.items():
        for prop, (lo, hi) in props.items():
            key = f"{elem}_{prop}"
            if isinstance(lo, float):
                params[key] = trial.suggest_float(key, lo, hi)
            else:
                params[key] = trial.suggest_int(key, lo, hi)

    # === Score 1: Chemistry Accuracy ===
    chem_errors = []
    for (source, target), expected_rate in TARGET_REACTION_RATES.items():
        actual_rate = simulate_reaction(params, source, target, temperature=128)
        error = abs(actual_rate - expected_rate)
        chem_errors.append(error)

    # Test high-temp combustion reactions
    for fuel in ["wood", "oil", "charcoal", "methane"]:
        rate = simulate_reaction(params, "oxygen", fuel, temperature=200)
        if rate < 0.5:  # should be high at elevated temps
            chem_errors.append(0.5 - rate)

    # Test that non-reactive pairs don't react
    for pair in [("glass", "water"), ("stone", "stone"), ("sand", "sand")]:
        rate = simulate_reaction(params, pair[0], pair[1])
        chem_errors.append(rate)  # should be ~0

    chemistry_accuracy = 1.0 - min(np.mean(chem_errors), 1.0)

    # === Score 2: Physics Realism ===
    physics_scores = []

    # Density ordering
    density_score = check_density_ordering(params)
    physics_scores.append(density_score)

    # Thermal equilibrium
    for (ma, mb, ta, tb), expected_eq in THERMAL_TARGETS.items():
        actual_eq = simulate_thermal_equilibrium(params, ma, mb, ta, tb)
        error = abs(actual_eq - expected_eq) / 255.0
        physics_scores.append(1.0 - min(error, 1.0))

    # Conductivity: metal > charcoal > acid > water > glass
    cond_metal = params.get("metal_conductivity", 250)
    cond_charcoal = params.get("charcoal_conductivity", 200)
    cond_acid = params.get("acid_conductivity", 150)
    cond_water = params.get("water_conductivity", 80)
    order_correct = (
        (cond_metal > cond_charcoal) +
        (cond_charcoal > cond_acid) +
        (cond_acid > cond_water)
    ) / 3.0
    physics_scores.append(order_correct)

    # Copper should conduct better than metal (iron)
    cond_copper = params.get("copper_conductivity", 255)
    if cond_copper > cond_metal:
        physics_scores.append(1.0)
    else:
        physics_scores.append(0.5)

    # Hydrogen should be lightest gas
    h_density = params.get("hydrogen_density", 1)
    if h_density <= 2:
        physics_scores.append(1.0)
    else:
        physics_scores.append(0.0)

    physics_realism = float(np.mean(physics_scores))

    return chemistry_accuracy, physics_realism


# ===================================================================
# CLI
# ===================================================================

def run_optimization(n_trials: int, n_jobs: int = 1):
    """Run Optuna multi-objective optimization."""
    storage_url = f"sqlite:///{STUDY_DB}"
    study = optuna.create_study(
        study_name="chemistry_v1",
        storage=storage_url,
        directions=["maximize", "maximize"],
        load_if_exists=True,
        sampler=TPESampler(seed=42, multivariate=True),
    )

    log.info(f"Starting {n_trials} trials ({n_jobs} workers)")
    log.info(f"Study DB: {STUDY_DB}")

    study.optimize(objective, n_trials=n_trials, n_jobs=n_jobs, show_progress_bar=True)

    # Report best trials
    best_trials = study.best_trials
    log.info(f"\nPareto-optimal trials: {len(best_trials)}")
    for i, t in enumerate(best_trials[:5]):
        log.info(f"  Trial {t.number}: chemistry={t.values[0]:.3f}, "
                 f"physics={t.values[1]:.3f}")

    return study


def show_results(top: int = 10):
    """Display top results from study."""
    storage_url = f"sqlite:///{STUDY_DB}"
    study = optuna.load_study(
        study_name="chemistry_v1",
        storage=storage_url,
    )

    log.info(f"Total trials: {len(study.trials)}")
    log.info(f"Pareto-optimal: {len(study.best_trials)}")

    # Sort by sum of objectives
    trials = sorted(
        study.best_trials,
        key=lambda t: sum(t.values),
        reverse=True,
    )

    for i, t in enumerate(trials[:top]):
        log.info(f"\n--- Trial {t.number} ---")
        log.info(f"  Chemistry accuracy: {t.values[0]:.4f}")
        log.info(f"  Physics realism:    {t.values[1]:.4f}")
        log.info(f"  Combined:           {sum(t.values):.4f}")

        # New element params
        for elem in NEW_ELEMENTS:
            elem_params = {k: v for k, v in t.params.items() if k.startswith(elem)}
            if elem_params:
                log.info(f"  {elem}: {elem_params}")

    # Export best params
    if trials:
        best = trials[0]
        output = {
            "trial": best.number,
            "chemistry_accuracy": best.values[0],
            "physics_realism": best.values[1],
            "params": best.params,
        }
        out_path = RESEARCH_DIR / "chemistry_best_params.json"
        with open(out_path, "w") as f:
            json.dump(output, f, indent=2)
        log.info(f"\nBest params exported to {out_path}")


def main():
    parser = argparse.ArgumentParser(description="Chemistry Optimizer")
    sub = parser.add_subparsers(dest="command")

    run_p = sub.add_parser("run", help="Run optimization trials")
    run_p.add_argument("--n-trials", type=int, default=200)
    run_p.add_argument("--n-jobs", type=int, default=1)

    show_p = sub.add_parser("show", help="Show results")
    show_p.add_argument("--top", type=int, default=10)

    args = parser.parse_args()
    if args.command == "run":
        run_optimization(args.n_trials, args.n_jobs)
    elif args.command == "show":
        show_results(args.top)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
