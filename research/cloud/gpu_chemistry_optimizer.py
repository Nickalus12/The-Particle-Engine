#!/usr/bin/env python3
"""GPU-accelerated Optuna optimizer for unified chemistry parameters.

Runs 10,000+ trials on A100 GPU to find optimal values for:
  - reductionPotential, bondEnergy, fuelValue, ignitionTemp, reactivity
  - electronMobility, dielectric
  - oxidizesInto, oxidationByproduct, reducesInto

Each trial evaluates a parameter set by running batched GPU simulations
across multiple scenario types and scoring against behavioral targets.

Usage:
    python research/cloud/gpu_chemistry_optimizer.py run --trials 10000
    python research/cloud/gpu_chemistry_optimizer.py run --trials 50000 --workers 4
    python research/cloud/gpu_chemistry_optimizer.py show --top 10
"""

from __future__ import annotations

import argparse
import json
import multiprocessing as mp
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np

try:
    import cupy as xp
    GPU_AVAILABLE = True
except ImportError:
    import numpy as xp
    GPU_AVAILABLE = False

import optuna

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
GRID_W, GRID_H = 320, 180
TOTAL_CELLS = GRID_W * GRID_H

EL_EMPTY = 0; EL_SAND = 1; EL_WATER = 2; EL_FIRE = 3; EL_ICE = 4
EL_LIGHTNING = 5; EL_STONE = 7; EL_OIL = 13; EL_ACID = 14; EL_GLASS = 15
EL_LAVA = 18; EL_WOOD = 20; EL_METAL = 21; EL_SMOKE = 22; EL_ASH = 24
EL_OXYGEN = 25; EL_CO2 = 26; EL_CHARCOAL = 29; EL_RUST = 31
EL_METHANE = 32; EL_SALT = 33

SCRIPT_DIR = Path(__file__).resolve().parent
STUDY_DB = SCRIPT_DIR.parent / "chemistry_optuna_study.db"
RESULTS_FILE = SCRIPT_DIR / "chemistry_optimization_results.json"

# ---------------------------------------------------------------------------
# Parameter space definition
# ---------------------------------------------------------------------------

def suggest_params(trial: optuna.Trial) -> dict[str, Any]:
    """Define the Optuna search space for unified chemistry parameters."""
    params = {}

    # --- Reduction potentials (signed, -128 to +127) ---
    params["wood_redpot"] = trial.suggest_int("wood_redpot", -60, -10)
    params["metal_redpot"] = trial.suggest_int("metal_redpot", -40, 0)
    params["oil_redpot"] = trial.suggest_int("oil_redpot", -70, -20)
    params["acid_redpot"] = trial.suggest_int("acid_redpot", 30, 90)
    params["oxygen_redpot"] = trial.suggest_int("oxygen_redpot", 20, 70)
    params["fire_redpot"] = trial.suggest_int("fire_redpot", 20, 80)
    params["lava_redpot"] = trial.suggest_int("lava_redpot", 0, 50)
    params["charcoal_redpot"] = trial.suggest_int("charcoal_redpot", -50, -5)
    params["methane_redpot"] = trial.suggest_int("methane_redpot", -80, -20)
    params["salt_redpot"] = trial.suggest_int("salt_redpot", -120, -40)
    params["rust_redpot"] = trial.suggest_int("rust_redpot", -10, 30)

    # --- Bond energies (0-255) ---
    params["wood_bond"] = trial.suggest_int("wood_bond", 30, 100)
    params["metal_bond"] = trial.suggest_int("metal_bond", 120, 220)
    params["oil_bond"] = trial.suggest_int("oil_bond", 20, 80)
    params["acid_bond"] = trial.suggest_int("acid_bond", 10, 60)
    params["stone_bond"] = trial.suggest_int("stone_bond", 150, 240)
    params["glass_bond"] = trial.suggest_int("glass_bond", 170, 250)
    params["sand_bond"] = trial.suggest_int("sand_bond", 120, 210)
    params["charcoal_bond"] = trial.suggest_int("charcoal_bond", 40, 120)
    params["methane_bond"] = trial.suggest_int("methane_bond", 10, 50)
    params["ice_bond"] = trial.suggest_int("ice_bond", 60, 140)

    # --- Fuel values (0-255) ---
    params["wood_fuel"] = trial.suggest_int("wood_fuel", 60, 180)
    params["oil_fuel"] = trial.suggest_int("oil_fuel", 120, 240)
    params["charcoal_fuel"] = trial.suggest_int("charcoal_fuel", 140, 240)
    params["methane_fuel"] = trial.suggest_int("methane_fuel", 160, 255)
    params["tnt_fuel"] = trial.suggest_int("tnt_fuel", 200, 255)

    # --- Ignition temperatures (0-255) ---
    params["wood_ignition"] = trial.suggest_int("wood_ignition", 150, 210)
    params["oil_ignition"] = trial.suggest_int("oil_ignition", 130, 190)
    params["charcoal_ignition"] = trial.suggest_int("charcoal_ignition", 140, 200)
    params["methane_ignition"] = trial.suggest_int("methane_ignition", 110, 170)
    params["tnt_ignition"] = trial.suggest_int("tnt_ignition", 100, 160)

    # --- Reactivity (0-255) ---
    params["acid_reactivity"] = trial.suggest_int("acid_reactivity", 150, 255)
    params["lava_reactivity"] = trial.suggest_int("lava_reactivity", 120, 220)
    params["fire_reactivity"] = trial.suggest_int("fire_reactivity", 140, 240)
    params["water_reactivity"] = trial.suggest_int("water_reactivity", 30, 100)
    params["oxygen_reactivity"] = trial.suggest_int("oxygen_reactivity", 40, 120)

    # --- Electron mobility (0-255) ---
    params["metal_emobility"] = trial.suggest_int("metal_emobility", 200, 255)
    params["water_emobility"] = trial.suggest_int("water_emobility", 40, 120)
    params["acid_emobility"] = trial.suggest_int("acid_emobility", 30, 100)
    params["salt_emobility"] = trial.suggest_int("salt_emobility", 80, 180)
    params["lava_emobility"] = trial.suggest_int("lava_emobility", 20, 80)
    params["charcoal_emobility"] = trial.suggest_int("charcoal_emobility", 30, 100)

    # --- Reaction thresholds (tuning the chemistry step) ---
    params["combustion_ox_delta"] = trial.suggest_int("combustion_ox_delta", 10, 50)
    params["combustion_ox_threshold"] = trial.suggest_int("combustion_ox_threshold", 160, 240)
    params["corrosion_moisture_min"] = trial.suggest_int("corrosion_moisture_min", 10, 80)
    params["corrosion_ox_threshold"] = trial.suggest_int("corrosion_ox_threshold", 200, 250)
    params["dissolution_react_min"] = trial.suggest_int("dissolution_react_min", 100, 200)

    return params


# ---------------------------------------------------------------------------
# GPU simulation for scoring
# ---------------------------------------------------------------------------

def build_property_arrays(params: dict) -> dict[str, Any]:
    """Build element property lookup tables from trial parameters."""
    redpot = xp.zeros(64, dtype=xp.int8)
    bond = xp.zeros(64, dtype=xp.uint8)
    fuel = xp.zeros(64, dtype=xp.uint8)
    ignition = xp.zeros(64, dtype=xp.uint8)
    reactivity = xp.zeros(64, dtype=xp.uint8)
    emobility = xp.zeros(64, dtype=xp.uint8)

    # Set values from params
    redpot[EL_WOOD] = params["wood_redpot"]
    redpot[EL_METAL] = params["metal_redpot"]
    redpot[EL_OIL] = params["oil_redpot"]
    redpot[EL_ACID] = params["acid_redpot"]
    redpot[EL_OXYGEN] = params["oxygen_redpot"]
    redpot[EL_FIRE] = params["fire_redpot"]
    redpot[EL_LAVA] = params["lava_redpot"]
    redpot[EL_CHARCOAL] = params["charcoal_redpot"]
    redpot[EL_METHANE] = params["methane_redpot"]
    redpot[EL_SALT] = params["salt_redpot"]
    redpot[EL_RUST] = params["rust_redpot"]

    bond[EL_WOOD] = params["wood_bond"]
    bond[EL_METAL] = params["metal_bond"]
    bond[EL_OIL] = params["oil_bond"]
    bond[EL_ACID] = params["acid_bond"]
    bond[EL_STONE] = params["stone_bond"]
    bond[EL_GLASS] = params["glass_bond"]
    bond[EL_SAND] = params["sand_bond"]
    bond[EL_CHARCOAL] = params["charcoal_bond"]
    bond[EL_METHANE] = params["methane_bond"]
    bond[EL_ICE] = params["ice_bond"]

    fuel[EL_WOOD] = params["wood_fuel"]
    fuel[EL_OIL] = params["oil_fuel"]
    fuel[EL_CHARCOAL] = params["charcoal_fuel"]
    fuel[EL_METHANE] = params["methane_fuel"]
    # TNT has a fixed element ID of 8
    fuel[8] = params["tnt_fuel"]

    ignition[EL_WOOD] = params["wood_ignition"]
    ignition[EL_OIL] = params["oil_ignition"]
    ignition[EL_CHARCOAL] = params["charcoal_ignition"]
    ignition[EL_METHANE] = params["methane_ignition"]
    ignition[8] = params["tnt_ignition"]

    reactivity[EL_ACID] = params["acid_reactivity"]
    reactivity[EL_LAVA] = params["lava_reactivity"]
    reactivity[EL_FIRE] = params["fire_reactivity"]
    reactivity[EL_WATER] = params["water_reactivity"]
    reactivity[EL_OXYGEN] = params["oxygen_reactivity"]

    emobility[EL_METAL] = params["metal_emobility"]
    emobility[EL_WATER] = params["water_emobility"]
    emobility[EL_ACID] = params["acid_emobility"]
    emobility[EL_SALT] = params["salt_emobility"]
    emobility[EL_LAVA] = params["lava_emobility"]
    emobility[EL_CHARCOAL] = params["charcoal_emobility"]

    return {
        "redpot": redpot, "bond": bond, "fuel": fuel,
        "ignition": ignition, "reactivity": reactivity, "emobility": emobility,
        "combustion_ox_delta": params["combustion_ox_delta"],
        "combustion_ox_threshold": params["combustion_ox_threshold"],
        "corrosion_moisture_min": params["corrosion_moisture_min"],
        "corrosion_ox_threshold": params["corrosion_ox_threshold"],
        "dissolution_react_min": params["dissolution_react_min"],
    }


def run_combustion_scenario(props: dict, batch_size: int = 200, steps: int = 40) -> dict:
    """Score combustion behavior: fire spread rate, heat production, product formation."""
    grid = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.uint8)
    temp = xp.full((batch_size, GRID_H, GRID_W), 128, dtype=xp.uint8)
    oxid = xp.full((batch_size, GRID_H, GRID_W), 128, dtype=xp.uint8)

    # Wood block with oxygen atmosphere
    grid[:, 60:120, 100:220] = EL_WOOD
    grid[:, 55:125, 95:225] = xp.where(
        grid[:, 55:125, 95:225] == 0, EL_OXYGEN, grid[:, 55:125, 95:225]
    )
    # Ignition
    grid[:, 90, 160] = EL_FIRE
    temp[:, 90, 160] = 240

    grid_flat = grid.reshape(batch_size, -1)
    temp_flat = temp.reshape(batch_size, -1)
    oxid_flat = oxid.reshape(batch_size, -1)

    wood_counts = []
    heat_history = []

    for step in range(steps):
        # Vectorized combustion check
        cell_fuel = props["fuel"][grid_flat.ravel().astype(xp.int64)].reshape(grid_flat.shape)
        cell_ign = props["ignition"][grid_flat.ravel().astype(xp.int64)].reshape(grid_flat.shape)
        cell_redpot = props["redpot"][grid_flat.ravel().astype(xp.int64)].reshape(grid_flat.shape)
        cell_react = props["reactivity"][grid_flat.ravel().astype(xp.int64)].reshape(grid_flat.shape)

        g2d = grid_flat.reshape(batch_size, GRID_H, GRID_W)
        t2d = temp_flat.reshape(batch_size, GRID_H, GRID_W)
        o2d = oxid_flat.reshape(batch_size, GRID_H, GRID_W)
        rp2d = cell_redpot.reshape(batch_size, GRID_H, GRID_W)
        fuel2d = cell_fuel.reshape(batch_size, GRID_H, GRID_W)
        ign2d = cell_ign.reshape(batch_size, GRID_H, GRID_W)
        react2d = cell_react.reshape(batch_size, GRID_H, GRID_W)

        # Max neighbor reduction potential
        padded_rp = xp.pad(rp2d.astype(xp.int16), ((0, 0), (1, 1), (1, 1)),
                           mode='constant', constant_values=-128)
        max_nrp = xp.maximum(
            xp.maximum(padded_rp[:, :-2, 1:-1], padded_rp[:, 2:, 1:-1]),
            xp.maximum(padded_rp[:, 1:-1, :-2], padded_rp[:, 1:-1, 2:])
        )

        burn_mask = (fuel2d > 0) & (t2d > ign2d) & (
            max_nrp > rp2d.astype(xp.int16) + props["combustion_ox_delta"]
        )

        # Advance oxidation
        ox_inc = react2d[burn_mask].astype(xp.int16) >> 4
        o2d[burn_mask] = xp.minimum(
            255, o2d[burn_mask].astype(xp.int16) + xp.maximum(1, ox_inc)
        ).astype(xp.uint8)

        # Heat release
        heat = fuel2d[burn_mask].astype(xp.int16) >> 2
        t2d[burn_mask] = xp.minimum(255, t2d[burn_mask].astype(xp.int16) + heat).astype(xp.uint8)

        # Transform
        transform = burn_mask & (o2d > props["combustion_ox_threshold"])
        g2d[transform] = EL_ASH  # simplified: wood -> ash
        o2d[transform] = 128

        # Simple heat diffusion (average with neighbors)
        padded_t = xp.pad(t2d.astype(xp.int16), ((0, 0), (1, 1), (1, 1)),
                          mode='edge')
        avg_t = (padded_t[:, :-2, 1:-1] + padded_t[:, 2:, 1:-1] +
                 padded_t[:, 1:-1, :-2] + padded_t[:, 1:-1, 2:] +
                 4 * t2d.astype(xp.int16)) // 8
        t2d[:] = avg_t.astype(xp.uint8)

        grid_flat = g2d.reshape(batch_size, -1)
        temp_flat = t2d.reshape(batch_size, -1)
        oxid_flat = o2d.reshape(batch_size, -1)

        wood_counts.append(float(xp.mean(xp.sum(grid_flat == EL_WOOD, axis=1))))
        heat_history.append(float(xp.mean(xp.sum(temp_flat.astype(xp.int32), axis=1))))

    initial_wood = 60 * 120  # approximate wood block size
    final_wood = wood_counts[-1]
    wood_consumed_pct = (initial_wood - final_wood) / max(1, initial_wood)
    peak_heat = max(heat_history) - heat_history[0]

    return {
        "wood_consumed_pct": wood_consumed_pct,
        "peak_heat": peak_heat,
        "wood_counts": wood_counts,
    }


def run_corrosion_scenario(props: dict, batch_size: int = 100, steps: int = 100) -> dict:
    """Score corrosion behavior: rust formation rate should be slow and steady."""
    grid = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.uint8)
    oxid = xp.full((batch_size, GRID_H, GRID_W), 128, dtype=xp.uint8)
    moisture = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.uint8)

    # Metal in wet environment with oxygen
    grid[:, 80:100, 120:200] = EL_METAL
    grid[:, 75:105, 115:205] = xp.where(
        grid[:, 75:105, 115:205] == 0, EL_OXYGEN, grid[:, 75:105, 115:205]
    )
    moisture[:, 75:105, 115:205] = 150  # wet environment

    grid_flat = grid.reshape(batch_size, -1)
    oxid_flat = oxid.reshape(batch_size, -1)
    moist_flat = moisture.reshape(batch_size, -1)

    rust_counts = []

    for step in range(steps):
        cell_rp = props["redpot"][grid_flat.ravel().astype(xp.int64)].reshape(grid_flat.shape)

        g2d = grid_flat.reshape(batch_size, GRID_H, GRID_W)
        o2d = oxid_flat.reshape(batch_size, GRID_H, GRID_W)
        m2d = moist_flat.reshape(batch_size, GRID_H, GRID_W)
        rp2d = cell_rp.reshape(batch_size, GRID_H, GRID_W)

        padded_rp = xp.pad(rp2d.astype(xp.int16), ((0, 0), (1, 1), (1, 1)),
                           mode='constant', constant_values=-128)
        max_nrp = xp.maximum(
            xp.maximum(padded_rp[:, :-2, 1:-1], padded_rp[:, 2:, 1:-1]),
            xp.maximum(padded_rp[:, 1:-1, :-2], padded_rp[:, 1:-1, 2:])
        )

        corr_mask = (
            (rp2d.astype(xp.int16) < 0) &
            (m2d > props["corrosion_moisture_min"]) &
            (max_nrp > 20)
        )

        corr_rate = ((max_nrp[corr_mask].astype(xp.int32) -
                       rp2d[corr_mask].astype(xp.int32)) *
                      m2d[corr_mask].astype(xp.int32)) // (255 * 60)
        corr_rate = xp.maximum(1, corr_rate)
        o2d[corr_mask] = xp.minimum(
            255, o2d[corr_mask].astype(xp.int16) + corr_rate
        ).astype(xp.uint8)

        rust_transform = corr_mask & (o2d > props["corrosion_ox_threshold"])
        g2d[rust_transform] = EL_RUST
        o2d[rust_transform] = 128

        grid_flat = g2d.reshape(batch_size, -1)
        oxid_flat = o2d.reshape(batch_size, -1)

        rust_counts.append(float(xp.mean(xp.sum(grid_flat == EL_RUST, axis=1))))

    return {
        "final_rust_pct": rust_counts[-1] / max(1, 20 * 80),  # metal block size
        "rust_progression": rust_counts,
    }


def run_acid_scenario(props: dict, batch_size: int = 100, steps: int = 30) -> dict:
    """Score acid dissolution: should dissolve weak materials, not strong ones."""
    grid = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.uint8)
    oxid = xp.full((batch_size, GRID_H, GRID_W), 128, dtype=xp.uint8)

    # Acid pool
    grid[:, 90:120, 100:220] = EL_ACID
    # Wood (weak)
    grid[:, 85:90, 110:140] = EL_WOOD
    # Glass (strong)
    grid[:, 85:90, 150:180] = EL_GLASS
    # Stone (medium)
    grid[:, 85:90, 190:220] = EL_STONE

    grid_flat = grid.reshape(batch_size, -1)
    oxid_flat = oxid.reshape(batch_size, -1)

    initial_wood = float(xp.mean(xp.sum(grid_flat == EL_WOOD, axis=1)))
    initial_glass = float(xp.mean(xp.sum(grid_flat == EL_GLASS, axis=1)))
    initial_stone = float(xp.mean(xp.sum(grid_flat == EL_STONE, axis=1)))

    for step in range(steps):
        cell_react = props["reactivity"][grid_flat.ravel().astype(xp.int64)].reshape(grid_flat.shape)
        cell_bond = props["bond"][grid_flat.ravel().astype(xp.int64)].reshape(grid_flat.shape)

        g2d = grid_flat.reshape(batch_size, GRID_H, GRID_W)
        o2d = oxid_flat.reshape(batch_size, GRID_H, GRID_W)
        react2d = cell_react.reshape(batch_size, GRID_H, GRID_W)
        bond2d = cell_bond.reshape(batch_size, GRID_H, GRID_W)

        # Min neighbor bond energy
        padded_bond = xp.pad(bond2d.astype(xp.int16), ((0, 0), (1, 1), (1, 1)),
                             mode='constant', constant_values=255)
        min_nbond = xp.minimum(
            xp.minimum(padded_bond[:, :-2, 1:-1], padded_bond[:, 2:, 1:-1]),
            xp.minimum(padded_bond[:, 1:-1, :-2], padded_bond[:, 1:-1, 2:])
        )

        acid_mask = (
            (react2d > props["dissolution_react_min"]) &
            (min_nbond > 0) &
            (min_nbond < react2d.astype(xp.int16))
        )

        diss_rate = (react2d[acid_mask].astype(xp.int16) - min_nbond[acid_mask]) >> 3
        o2d[acid_mask] = xp.minimum(
            255, o2d[acid_mask].astype(xp.int16) + diss_rate
        ).astype(xp.uint8)

        dissolved = acid_mask & (o2d > 220)
        g2d[dissolved] = EL_EMPTY
        o2d[dissolved] = 128

        grid_flat = g2d.reshape(batch_size, -1)
        oxid_flat = o2d.reshape(batch_size, -1)

    final_wood = float(xp.mean(xp.sum(grid_flat == EL_WOOD, axis=1)))
    final_glass = float(xp.mean(xp.sum(grid_flat == EL_GLASS, axis=1)))
    final_stone = float(xp.mean(xp.sum(grid_flat == EL_STONE, axis=1)))

    return {
        "wood_dissolved_pct": (initial_wood - final_wood) / max(1, initial_wood),
        "glass_dissolved_pct": (initial_glass - final_glass) / max(1, initial_glass),
        "stone_dissolved_pct": (initial_stone - final_stone) / max(1, initial_stone),
    }


def run_electrical_scenario(props: dict, batch_size: int = 100, steps: int = 50) -> dict:
    """Score electricity: current should flow through metal, attenuate in water."""
    grid = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.uint8)
    voltage = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.int8)

    # Metal wire
    grid[:, 90, 50:270] = EL_METAL
    # Water bridge in middle
    grid[:, 90, 140:180] = EL_WATER
    # Voltage source
    voltage[:, 90, 50] = 127

    grid_flat = grid.reshape(batch_size, -1)
    v_flat = voltage.reshape(batch_size, -1).astype(xp.int16)

    for step in range(steps):
        cell_emob = props["emobility"][grid_flat.ravel().astype(xp.int64)].reshape(grid_flat.shape)
        emob2d = cell_emob.reshape(batch_size, GRID_H, GRID_W)
        v2d = v_flat.reshape(batch_size, GRID_H, GRID_W)

        padded_v = xp.pad(v2d, ((0, 0), (1, 1), (1, 1)), mode='constant', constant_values=0)
        max_nv = xp.maximum(
            xp.maximum(padded_v[:, :-2, 1:-1], padded_v[:, 2:, 1:-1]),
            xp.maximum(padded_v[:, 1:-1, :-2], padded_v[:, 1:-1, 2:])
        )

        conduct_mask = (emob2d > 0) & ((max_nv - v2d) > 5)
        resistance = 255 - emob2d[conduct_mask].astype(xp.int16)
        attenuation = resistance >> 3
        new_v = max_nv[conduct_mask] - attenuation
        v2d[conduct_mask] = xp.clip(new_v, -128, 127)

        v_flat = v2d.reshape(batch_size, -1)

    # Measure voltage at key points
    v_at_metal_start = float(xp.mean(v_flat.reshape(batch_size, GRID_H, GRID_W)[:, 90, 60]))
    v_at_water_start = float(xp.mean(v_flat.reshape(batch_size, GRID_H, GRID_W)[:, 90, 140]))
    v_at_water_end = float(xp.mean(v_flat.reshape(batch_size, GRID_H, GRID_W)[:, 90, 179]))
    v_at_metal_end = float(xp.mean(v_flat.reshape(batch_size, GRID_H, GRID_W)[:, 90, 260]))

    return {
        "metal_start_v": v_at_metal_start,
        "water_start_v": v_at_water_start,
        "water_end_v": v_at_water_end,
        "metal_end_v": v_at_metal_end,
        "metal_drop": abs(127 - v_at_metal_start),
        "water_drop": abs(v_at_water_start - v_at_water_end),
    }


# ---------------------------------------------------------------------------
# Objective function
# ---------------------------------------------------------------------------

def objective(trial: optuna.Trial) -> tuple[float, float]:
    """Multi-objective: maximize physics_realism and gameplay_feel.

    Returns (physics_score, gameplay_score) both in [0, 1].
    """
    params = suggest_params(trial)
    props = build_property_arrays(params)

    scores = {}

    # --- Combustion scoring ---
    comb = run_combustion_scenario(props)
    # TARGET: wood should be 40-80% consumed in 40 steps (not instant, not too slow)
    wood_score = 1.0 - abs(comb["wood_consumed_pct"] - 0.6) * 2.5
    wood_score = max(0, min(1, wood_score))
    # TARGET: significant heat production
    heat_score = min(1.0, comb["peak_heat"] / 500000)
    scores["combustion"] = (wood_score * 0.6 + heat_score * 0.4)

    # --- Corrosion scoring ---
    corr = run_corrosion_scenario(props)
    # TARGET: rust should form slowly: 5-30% in 100 steps
    rust_pct = corr["final_rust_pct"]
    rust_score = 1.0 - abs(rust_pct - 0.15) * 5
    rust_score = max(0, min(1, rust_score))
    # Bonus for gradual progression (not all-at-once)
    progression = corr["rust_progression"]
    if len(progression) > 10:
        mid = progression[len(progression) // 2]
        final = progression[-1]
        gradual_score = 1.0 if (mid > 0 and mid < final * 0.8) else 0.5
    else:
        gradual_score = 0.5
    scores["corrosion"] = rust_score * 0.7 + gradual_score * 0.3

    # --- Acid selectivity scoring ---
    acid = run_acid_scenario(props)
    # TARGET: wood dissolves a lot, stone dissolves a little, glass doesn't dissolve
    wood_acid_score = min(1.0, acid["wood_dissolved_pct"] * 2)  # want >50%
    glass_acid_score = 1.0 - acid["glass_dissolved_pct"] * 5  # want ~0%
    stone_acid_score = 1.0 - abs(acid["stone_dissolved_pct"] - 0.2) * 3  # want ~20%
    selectivity = max(0, min(1,
        wood_acid_score * 0.4 + glass_acid_score * 0.3 + stone_acid_score * 0.3
    ))
    scores["acid"] = selectivity

    # --- Electrical scoring ---
    elec = run_electrical_scenario(props)
    # TARGET: metal conducts well (small drop), water has noticeable drop
    metal_score = max(0, 1.0 - elec["metal_drop"] / 50)  # want <10 drop
    water_drop_score = 1.0 - abs(elec["water_drop"] - 30) / 60  # want ~30 drop
    water_drop_score = max(0, min(1, water_drop_score))
    scores["electrical"] = metal_score * 0.5 + water_drop_score * 0.5

    # --- Conservation bonus ---
    # Penalize parameter sets that violate physical intuition
    conservation_penalty = 0
    # Acid must have higher redPot than metals it dissolves
    if params["acid_redpot"] <= params["metal_redpot"]:
        conservation_penalty += 0.3
    # Oxygen must be an oxidizer (positive redPot)
    if params["oxygen_redpot"] <= 0:
        conservation_penalty += 0.2
    # Metal must conduct better than water
    if params["metal_emobility"] <= params["water_emobility"]:
        conservation_penalty += 0.2
    # Oil should burn hotter than wood (higher fuel value)
    if params["oil_fuel"] <= params["wood_fuel"]:
        conservation_penalty += 0.1

    # --- Aggregate ---
    physics_score = (
        scores["combustion"] * 0.3 +
        scores["corrosion"] * 0.2 +
        scores["acid"] * 0.25 +
        scores["electrical"] * 0.25 -
        conservation_penalty
    )
    physics_score = max(0, min(1, physics_score))

    # Gameplay feel: combustion should be dramatic, corrosion subtle
    gameplay_score = (
        min(1, comb["wood_consumed_pct"] * 1.5) * 0.4 +  # fire should burn visibly
        (1.0 - min(1, rust_pct * 3)) * 0.2 +  # rust shouldn't dominate
        selectivity * 0.2 +  # acid should feel powerful but selective
        metal_score * 0.2  # electricity should work reliably
    )
    gameplay_score = max(0, min(1, gameplay_score))

    trial.set_user_attr("scores", scores)
    trial.set_user_attr("overall", physics_score * 0.6 + gameplay_score * 0.4)

    return physics_score, gameplay_score


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

def run_optimization(n_trials: int, n_workers: int = 1):
    """Run Optuna optimization with given number of trials."""
    storage_url = f"sqlite:///{STUDY_DB}"
    study_name = "unified_chemistry_v1"

    study = optuna.create_study(
        study_name=study_name,
        storage=storage_url,
        directions=["maximize", "maximize"],
        load_if_exists=True,
        sampler=optuna.samplers.TPESampler(multivariate=True),
    )

    print(f"Starting optimization: {n_trials} trials, {n_workers} workers")
    print(f"GPU available: {GPU_AVAILABLE}")
    print(f"Study DB: {STUDY_DB}")

    if n_workers > 1:
        # Multi-process optimization
        processes = []
        trials_per_worker = n_trials // n_workers

        def worker_fn(worker_id):
            worker_study = optuna.load_study(
                study_name=study_name,
                storage=storage_url,
                sampler=optuna.samplers.TPESampler(
                    seed=42 + worker_id, multivariate=True
                ),
            )
            worker_study.optimize(objective, n_trials=trials_per_worker, n_jobs=1)

        for i in range(n_workers):
            p = mp.Process(target=worker_fn, args=(i,))
            p.start()
            processes.append(p)
            time.sleep(0.5)

        for p in processes:
            p.join()
    else:
        study.optimize(objective, n_trials=n_trials, n_jobs=1, show_progress_bar=True)

    # Report results
    print(f"\nCompleted {len(study.trials)} trials")
    show_results(study)


def show_results(study=None):
    """Show top results from the study."""
    if study is None:
        storage_url = f"sqlite:///{STUDY_DB}"
        study = optuna.load_study(
            study_name="unified_chemistry_v1",
            storage=storage_url,
        )

    # Get Pareto front
    best_trials = study.best_trials
    print(f"\nPareto front: {len(best_trials)} trials")
    print(f"{'Trial':>6} {'Physics':>8} {'Gameplay':>8} {'Overall':>8}")
    print("-" * 36)

    results = []
    for t in sorted(best_trials, key=lambda x: x.user_attrs.get("overall", 0), reverse=True)[:20]:
        overall = t.user_attrs.get("overall", 0)
        scores = t.user_attrs.get("scores", {})
        print(f"{t.number:>6} {t.values[0]:>8.3f} {t.values[1]:>8.3f} {overall:>8.3f}")
        results.append({
            "trial": t.number,
            "physics": t.values[0],
            "gameplay": t.values[1],
            "overall": overall,
            "scores": scores,
            "params": t.params,
        })

    # Save best params to file
    if results:
        best = results[0]
        output = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "total_trials": len(study.trials),
            "best_overall": best["overall"],
            "best_params": best["params"],
            "best_scores": best["scores"],
            "pareto_front": results,
        }
        with open(RESULTS_FILE, "w") as f:
            json.dump(output, f, indent=2)
        print(f"\nBest params saved to {RESULTS_FILE}")

        # Also output Dart-ready format
        print("\n--- Dart-ready property values ---")
        p = best["params"]
        print(f"  wood:     redPot={p.get('wood_redpot')}, bond={p.get('wood_bond')}, "
              f"fuel={p.get('wood_fuel')}, ignition={p.get('wood_ignition')}")
        print(f"  metal:    redPot={p.get('metal_redpot')}, bond={p.get('metal_bond')}, "
              f"eMobility={p.get('metal_emobility')}")
        print(f"  acid:     redPot={p.get('acid_redpot')}, bond={p.get('acid_bond')}, "
              f"reactivity={p.get('acid_reactivity')}, eMobility={p.get('acid_emobility')}")
        print(f"  oxygen:   redPot={p.get('oxygen_redpot')}, reactivity={p.get('oxygen_reactivity')}")
        print(f"  oil:      redPot={p.get('oil_redpot')}, fuel={p.get('oil_fuel')}, "
              f"ignition={p.get('oil_ignition')}")
        print(f"  thresholds: combOxDelta={p.get('combustion_ox_delta')}, "
              f"combOxThresh={p.get('combustion_ox_threshold')}, "
              f"corrMoistMin={p.get('corrosion_moisture_min')}")


def main():
    parser = argparse.ArgumentParser(description="GPU Chemistry Parameter Optimizer")
    sub = parser.add_subparsers(dest="command")

    run_p = sub.add_parser("run", help="Run optimization")
    run_p.add_argument("--trials", type=int, default=10000)
    run_p.add_argument("--workers", type=int, default=1)

    show_p = sub.add_parser("show", help="Show results")
    show_p.add_argument("--top", type=int, default=10)

    args = parser.parse_args()

    if args.command == "run":
        run_optimization(args.trials, args.workers)
    elif args.command == "show":
        show_results()
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
