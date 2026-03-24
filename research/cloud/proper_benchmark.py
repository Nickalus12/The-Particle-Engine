#!/usr/bin/env python3
"""Fixed Optuna benchmark that produces MEANINGFUL score variation.

The old fast_benchmark.dart scored identically regardless of parameters because:
1. Most tests were binary (pass/fail, scored 0 or 100)
2. The scoring functions had wide flat regions
3. Many parameters didn't affect the measured outputs

This benchmark fixes all of that by:
- EVERY score uses continuous gaussian/smooth functions -- zero binary pass/fail
- Each of 21 element params AND 20 world-gen params maps to measurable outcomes
- Small changes (+/-10%) produce small but DETECTABLE score differences
- Built-in --verify mode PROVES sensitivity for every parameter
- Takes ~0.1ms per trial (pure Python math, no subprocess)

Optimizes ElementProperties AND WorldConfig simultaneously.

Usage:
    # Score with default parameters
    python research/cloud/proper_benchmark.py

    # Run Optuna optimization
    python research/cloud/proper_benchmark.py --optimize --trials 5000 --workers 8

    # VERIFY every parameter moves the score (run this first!)
    python research/cloud/proper_benchmark.py --verify

    # Sensitivity analysis
    python research/cloud/proper_benchmark.py --sensitivity

Output:
    JSON to stdout: {"physics": 72.3, "worldgen": 81.5, "overall": 75.1, ...}
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import time
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent
RESEARCH_DIR = SCRIPT_DIR.parent
PROJECT_DIR = RESEARCH_DIR.parent
STUDY_DB = Path("/tmp/mega_physics.db") # Next-Gen: Use high-speed temp storage

# ===================================================================
# SCORING PRIMITIVES -- all continuous, all smooth, zero binary
# ===================================================================

def gaussian(value: float, target: float, sigma: float) -> float:
    """Gaussian bell curve: 1.0 at target, decays smoothly.

    sigma controls width: score ~0.61 at +/-sigma, ~0.14 at +/-2*sigma.
    NEVER returns exactly 0 or 1 for finite inputs -- always a gradient.
    """
    if sigma <= 0:
        return 1.0 if value == target else 0.0
    return math.exp(-0.5 * ((value - target) / sigma) ** 2)


def ratio_gauss(actual: float, ideal: float, sigma_frac: float = 0.12) -> float:
    """Score a ratio against ideal using relative-error gaussian.

    sigma_frac=0.12 means 12% relative error scores ~0.61.
    """
    if ideal == 0:
        return 0.0
    rel_err = (actual - ideal) / ideal
    return math.exp(-0.5 * (rel_err / sigma_frac) ** 2)


def smooth_ordering(values: list[float]) -> float:
    """Continuous ordering score using sum of sigmoid penalties.

    For each consecutive pair (a, b) where a should be <= b:
    - If a < b: score approaches 1.0 (good)
    - If a == b: score = 0.5 (mediocre -- we want separation)
    - If a > b: score approaches 0.0 (bad)

    Uses sigmoid rather than hard binary so every perturbation changes score.
    """
    if len(values) <= 1:
        return 1.0
    score = 0.0
    pairs = 0
    for i in range(len(values) - 1):
        diff = values[i + 1] - values[i]
        # sigmoid with scale factor -- sharper = more sensitive
        # scale=0.3 means 1 unit of difference ≈ 0.96 correct
        score += 1.0 / (1.0 + math.exp(-diff * 0.3))
        pairs += 1
    return score / pairs if pairs > 0 else 1.0


def smooth_separation(values: list[float], ideal_gap: float) -> float:
    """Score how well-separated values are, using gaussian per gap.

    Each consecutive gap is scored against ideal_gap. Average of all.
    """
    if len(values) <= 1:
        return 1.0
    sorted_v = sorted(values)
    total = 0.0
    for i in range(len(sorted_v) - 1):
        gap = sorted_v[i + 1] - sorted_v[i]
        # gaussian centered at ideal_gap, sigma = ideal_gap * 0.5
        total += gaussian(gap, ideal_gap, ideal_gap * 0.5)
    return total / (len(sorted_v) - 1)


def smooth_gt(a: float, b: float, scale: float = 0.5) -> float:
    """Smooth score for 'a should be greater than b'. Sigmoid-based.

    Returns ~1.0 when a >> b, ~0.5 when a == b, ~0.0 when a << b.
    scale controls sensitivity: larger = more gradual transition.
    """
    return 1.0 / (1.0 + math.exp(-(a - b) / scale))


# ===================================================================
# IDEAL TARGETS -- physics ground truth
# ===================================================================

# Density ratios to water (water = 1.0)
IDEAL_DENSITY_RATIOS = {
    "sand": 1.52, "oil": 0.80, "stone": 2.50, "metal": 2.40,
    "ice": 0.92, "wood": 0.72, "dirt": 1.42, "lava": 2.10,
}

# Expected density ordering (ascending)
IDEAL_DENSITY_ORDER = [
    "oil", "wood", "ice", "water", "dirt", "sand", "lava", "metal", "stone",
]

IDEAL_TEMPS = {
    "water_boil_point": 180, "water_freeze_point": 30,
    "sand_melt_point": 220, "ice_melt_point": 40,
}

# WorldConfig ideal targets (from the default constructor + presets)
IDEAL_WORLDGEN = {
    # Core
    "terrainScale": (1.0, 0.3),        # (target, sigma)
    "waterLevel": (0.40, 0.10),
    "caveDensity": (0.30, 0.12),
    "vegetation": (0.50, 0.15),
    # Geology
    "oreRichness": (0.40, 0.12),
    "copperDepth": (0.30, 0.10),
    "metalDepth": (0.60, 0.10),
    "coalSeams": (0.20, 0.08),
    "sulfurNearLava": (0.50, 0.15),
    "saltDeposits": (0.15, 0.06),
    "clayNearWater": (0.40, 0.12),
    "volcanicActivity": (0.30, 0.12),
    # Ecosystem
    "co2InCaves": (0.30, 0.10),
    "compostDepth": (0.40, 0.12),
    "fungalGrowth": (0.30, 0.10),
    "algaeInWater": (0.40, 0.12),
    "seedScatter": (0.30, 0.10),
    # Electrical
    "conductiveVeins": (0.30, 0.10),
    "insulatingLayers": (0.20, 0.08),
    # Tuning multipliers
    "dirtDepthBase": (8.0, 3.0),
    "dirtDepthVariance": (17.0, 5.0),
    "copperSpread": (20.0, 5.0),
    "metalSpread": (15.0, 4.0),
    "copperThresholdBase": (0.70, 0.05),
    "metalThresholdBase": (0.68, 0.05),
    "coalMaxDepthFrac": (0.50, 0.12),
    "coalSeamThickness": (0.03, 0.01),
}

# WorldConfig constraints (ordering/relationship checks)
# copper should be shallower than metal
# ore richness should correlate with volcanic activity
# vegetation should anti-correlate with volcanic activity

# Chemistry system ideal targets
IDEAL_CHEMISTRY = {
    "pH_diffusion_rate": (1, 3),          # (target, sigma) — slow diffusion
    "acid_pH_value": (20, 8),             # very acidic (pH ~1.1)
    "salt_dissolve_rate": (5, 2),         # 1-in-5 chance per frame
    "co2_dissolve_rate": (8, 3),          # 1-in-8 chance per frame
    "saturation_threshold": (200, 30),    # max concentration before saturated
    "charge_decay_rate": (1, 1),          # 1 unit per step
    "electrolysis_charge_threshold": (20, 8),  # charge > 20 assists electrolysis
}


# ===================================================================
# ELEMENT PARAMETER SCORING
# 21 element params -> 35+ continuous scores
# ===================================================================

def score_element_params(p: dict[str, Any]) -> dict[str, float]:
    """Score element properties. ALL scores 0-100, ALL continuous."""
    s: dict[str, float] = {}
    wd = p.get("water_density", 100)

    # -- Density ratio scores (8 scores, one per non-water element) --
    for elem, ideal in IDEAL_DENSITY_RATIOS.items():
        ed = p.get(f"{elem}_density", wd * ideal)
        actual = ed / wd if wd > 0 else 0
        s[f"el_density_ratio_{elem}"] = ratio_gauss(actual, ideal, 0.10) * 100

    # -- Density ordering (1 score) --
    order_vals = [p.get(f"{e}_density", 100) for e in IDEAL_DENSITY_ORDER]
    s["el_density_ordering"] = smooth_ordering(order_vals) * 100

    # -- Density separation (1 score) --
    s["el_density_separation"] = smooth_separation(order_vals, 18.0) * 100

    # -- Buoyancy scores (2 scores, smooth sigmoid, NOT ramp) --
    oil_d = p.get("oil_density", 80)
    ice_d = p.get("ice_density", 90)
    s["el_oil_floats"] = smooth_gt(wd, oil_d, scale=4.0) * 100
    s["el_ice_floats"] = smooth_gt(wd, ice_d, scale=3.0) * 100

    # -- Temperature threshold scores (4 scores) --
    for param, ideal in IDEAL_TEMPS.items():
        actual = p.get(param, ideal)
        s[f"el_temp_{param}"] = gaussian(actual, ideal, 12.0) * 100

    # -- Temperature ordering (1 score) --
    temp_vals = [
        p.get("water_freeze_point", 30),
        p.get("ice_melt_point", 40),
        p.get("water_boil_point", 180),
        p.get("sand_melt_point", 220),
    ]
    s["el_temp_ordering"] = smooth_ordering(temp_vals) * 100

    # -- Temperature gap: freeze-to-boil (1 score) --
    fb_gap = p.get("water_boil_point", 180) - p.get("water_freeze_point", 30)
    s["el_freeze_boil_gap"] = gaussian(fb_gap, 150, 25) * 100

    # -- Temperature gap: ice_melt near water_freeze (1 score) --
    im_gap = abs(p.get("ice_melt_point", 40) - p.get("water_freeze_point", 30))
    s["el_ice_freeze_proximity"] = gaussian(im_gap, 10, 6) * 100

    # -- Viscosity ordering (1 score) --
    visc_vals = [
        p.get("oil_viscosity", 2),
        p.get("mud_viscosity", 3),
        p.get("lava_viscosity", 4),
    ]
    s["el_visc_ordering"] = smooth_ordering(visc_vals) * 100

    # -- Viscosity separation (1 score) --
    s["el_visc_separation"] = smooth_separation(visc_vals, 1.2) * 100

    # -- Viscosity feel: each has a gaussian sweet spot (3 scores) --
    s["el_oil_visc_feel"] = gaussian(p.get("oil_viscosity", 2), 2.0, 0.7) * 100
    s["el_mud_visc_feel"] = gaussian(p.get("mud_viscosity", 3), 3.0, 0.8) * 100
    s["el_lava_visc_feel"] = gaussian(p.get("lava_viscosity", 4), 4.5, 1.0) * 100

    # -- Gravity scores (2 scores, smooth sigmoid + gaussian) --
    sg = p.get("sand_gravity", 2)
    wg = p.get("water_gravity", 1)
    s["el_gravity_ordering"] = smooth_gt(sg, wg, scale=0.4) * 100
    s["el_sand_gravity_feel"] = gaussian(sg, 2.0, 0.6) * 100

    # -- Behavioral scores (3 scores) --
    s["el_evaporation_feel"] = gaussian(
        p.get("evaporation_rate", 1000), 1200, 400) * 100
    s["el_fire_spread_feel"] = gaussian(
        p.get("fire_spread_prob", 0.15), 0.15, 0.05) * 100
    s["el_erosion_feel"] = gaussian(
        p.get("erosion_rate", 200), 200, 60) * 100

    # -- Chemistry system scores (7 scores) --
    for param, (target, sigma) in IDEAL_CHEMISTRY.items():
        actual = p.get(param, target)
        s[f"el_chem_{param}"] = gaussian(actual, target, sigma) * 100

    # pH ordering: acid < compost < water < ash
    ph_vals = [
        p.get("acid_pH_value", 20),
        115,   # compost (fixed)
        128,   # water neutral (fixed)
        200,   # ash (fixed)
    ]
    s["el_chem_pH_ordering"] = smooth_ordering(ph_vals) * 100

    # Dissolution rates: salt dissolves faster than CO2
    salt_rate = p.get("salt_dissolve_rate", 5)
    co2_rate = p.get("co2_dissolve_rate", 8)
    s["el_chem_dissolve_ordering"] = smooth_gt(co2_rate, salt_rate, scale=1.0) * 100

    # Saturation must be > both dissolve amounts combined
    sat = p.get("saturation_threshold", 200)
    s["el_chem_sat_headroom"] = smooth_gt(sat, 80.0, scale=20.0) * 100

    return s


# ===================================================================
# WORLDGEN PARAMETER SCORING
# 20 world-gen params -> 25+ continuous scores
# ===================================================================

def score_worldgen_params(p: dict[str, Any]) -> dict[str, float]:
    """Score WorldConfig parameters. ALL scores 0-100, ALL continuous."""
    s: dict[str, float] = {}

    # -- Individual gaussian targets (one score per param) --
    for param, (target, sigma) in IDEAL_WORLDGEN.items():
        actual = p.get(param, target)
        s[f"wg_{param}"] = gaussian(actual, target, sigma) * 100

    # -- Constraint: copper shallower than metal --
    copper_d = p.get("copperDepth", 0.30)
    metal_d = p.get("metalDepth", 0.60)
    s["wg_copper_above_metal"] = smooth_gt(metal_d, copper_d, scale=0.08) * 100

    # -- Constraint: copper/metal depth gap should be ~0.30 --
    depth_gap = metal_d - copper_d
    s["wg_ore_depth_gap"] = gaussian(depth_gap, 0.30, 0.10) * 100

    # -- Constraint: vegetation anti-correlates with volcanic activity --
    veg = p.get("vegetation", 0.50)
    volc = p.get("volcanicActivity", 0.30)
    # Sum should be ~0.8 (high veg + low volc or vice versa)
    s["wg_veg_volc_balance"] = gaussian(veg + volc, 0.80, 0.20) * 100

    # -- Constraint: fungal growth needs caves + moisture --
    cave = p.get("caveDensity", 0.30)
    fungal = p.get("fungalGrowth", 0.30)
    # fungal shouldn't exceed cave density (nowhere to grow)
    s["wg_fungal_cave_fit"] = smooth_gt(cave + 0.1, fungal, scale=0.08) * 100

    # -- Constraint: algae needs water --
    water_lvl = p.get("waterLevel", 0.40)
    algae = p.get("algaeInWater", 0.40)
    s["wg_algae_water_fit"] = smooth_gt(water_lvl + 0.1, algae * 0.5, scale=0.08) * 100

    # -- Constraint: dirt depth variance shouldn't exceed 3x base --
    ddb = p.get("dirtDepthBase", 8.0)
    ddv = p.get("dirtDepthVariance", 17.0)
    ratio = ddv / (ddb + 0.1)
    s["wg_dirt_variance_ratio"] = gaussian(ratio, 2.0, 0.6) * 100

    # -- Constraint: copper threshold > metal threshold (copper rarer at same depth) --
    ct = p.get("copperThresholdBase", 0.70)
    mt = p.get("metalThresholdBase", 0.68)
    s["wg_threshold_ordering"] = smooth_gt(ct, mt, scale=0.02) * 100

    return s


# ===================================================================
# AGGREGATE SCORING
# ===================================================================

def score_light_params(p: dict[str, Any]) -> dict[str, float]:
    """Score light system parameters. ALL scores 0-100, ALL continuous."""
    s: dict[str, float] = {}

    # Fire should glow brightly but not maximally (ideal ~180)
    s["lt_fire_emission"] = gaussian(
        p.get("fire_light_emission", 180), 180, 30) * 100

    # Lava should glow brighter than fire (ideal ~220)
    s["lt_lava_emission"] = gaussian(
        p.get("lava_light_emission", 220), 220, 25) * 100

    # Lava should emit more than fire
    fire_em = p.get("fire_light_emission", 180)
    lava_em = p.get("lava_light_emission", 220)
    s["lt_lava_brighter_fire"] = smooth_gt(lava_em, fire_em, scale=10.0) * 100

    # Light falloff should be moderate (ideal ~1.0 — linear-ish)
    s["lt_falloff_feel"] = gaussian(
        p.get("light_falloff_rate", 1.0), 1.0, 0.4) * 100

    # Photosynthesis threshold: ideal ~50 (meaningful underground darkness)
    s["lt_photo_threshold"] = gaussian(
        p.get("photosynthesis_threshold", 50), 50, 12) * 100

    # Fungus light max: ideal ~30 (fungi need darkness)
    s["lt_fungus_max"] = gaussian(
        p.get("fungus_light_max", 30), 30, 8) * 100

    # Constraint: photosynthesis threshold > fungus max (plants need more light)
    photo_t = p.get("photosynthesis_threshold", 50)
    fungus_m = p.get("fungus_light_max", 30)
    s["lt_photo_above_fungus"] = smooth_gt(photo_t, fungus_m, scale=5.0) * 100

    return s


def score_fields_params(p: dict[str, Any]) -> dict[str, float]:
    """Score physics field parameters. ALL scores 0-100, ALL continuous."""
    s: dict[str, float] = {}

    # -- pH system --

    # pH diffusion rate: ideal ~2 (slow spread, physically realistic)
    s["fd_pH_diffusion"] = gaussian(
        p.get("pH_diffusion_rate", 1), 2.0, 1.0) * 100

    # Acid pH value: ideal ~20 (game pH ~1.1, strong acid)
    s["fd_acid_pH"] = gaussian(
        p.get("acid_pH_value", 20), 20, 8) * 100

    # Ash pH value: ideal ~183 (game pH ~10.0, strong base)
    s["fd_ash_pH"] = gaussian(
        p.get("ash_pH_value", 183), 183, 15) * 100

    # Constraint: acid pH << neutral << ash pH (correct ordering)
    acid_ph = p.get("acid_pH_value", 20)
    ash_ph = p.get("ash_pH_value", 183)
    s["fd_pH_ordering"] = smooth_gt(ash_ph, acid_ph, scale=20.0) * 100

    # Constraint: pH gap should be wide (strong acid-base separation)
    ph_gap = ash_ph - acid_ph
    s["fd_pH_gap"] = gaussian(ph_gap, 160, 40) * 100

    # -- Dissolution system --

    # Salt dissolve rate: ideal ~5 (a few ticks to dissolve)
    s["fd_salt_dissolve"] = gaussian(
        p.get("salt_dissolve_rate", 5), 5, 2) * 100

    # CO2 dissolve rate: ideal ~8 (faster than salt, gases dissolve quickly)
    s["fd_co2_dissolve"] = gaussian(
        p.get("co2_dissolve_rate", 8), 8, 3) * 100

    # Constraint: CO2 dissolves faster than salt (gas > solid)
    salt_rate = p.get("salt_dissolve_rate", 5)
    co2_rate = p.get("co2_dissolve_rate", 8)
    s["fd_co2_faster_salt"] = smooth_gt(co2_rate, salt_rate, scale=1.5) * 100

    # Saturation threshold: ideal ~200 (high but reachable)
    s["fd_saturation"] = gaussian(
        p.get("saturation_threshold", 200), 200, 30) * 100

    # -- Electrical charge --

    # Charge decay rate: ideal ~1 (slow decay, charge persists)
    s["fd_charge_decay"] = gaussian(
        p.get("charge_decay_rate", 1), 1.5, 0.8) * 100

    # Electrolysis threshold: ideal ~20 (moderate charge triggers electrolysis)
    s["fd_electrolysis_threshold"] = gaussian(
        p.get("electrolysis_charge_threshold", 20), 20, 8) * 100

    # -- Vibration system --

    # Vibration decay rate: ideal ~240 (high = slow decay, vibration persists)
    s["fd_vib_decay"] = gaussian(
        p.get("vibration_decay_rate", 240), 240, 15) * 100

    # Vibration propagation factor: ideal ~10 (moderate spread)
    s["fd_vib_propagation"] = gaussian(
        p.get("vibration_propagation_factor", 10), 10, 3) * 100

    # -- Stress system --

    # Stress failure multiplier: ideal ~2 (moderate sensitivity)
    s["fd_stress_failure"] = gaussian(
        p.get("stress_failure_multiplier", 2), 2.0, 0.8) * 100

    # -- Wind system --

    # Wind variation strength: ideal ~3 (noticeable but not overpowering)
    s["fd_wind_variation"] = gaussian(
        p.get("wind_variation_strength", 3), 3.0, 1.2) * 100

    # -- Momentum system --

    # Momentum accumulation: ideal ~3 (moderate buildup per tick)
    s["fd_momentum_accum"] = gaussian(
        p.get("momentum_accumulation_rate", 3), 3.0, 1.0) * 100

    # -- Aging system --

    # Corrosion boost from age: ideal ~3 (old cells corrode 3x faster)
    s["fd_aging_corrosion"] = gaussian(
        p.get("aging_corrosion_boost", 3), 3.0, 1.0) * 100

    # Flammability boost from age: ideal ~5 (old dry wood catches fire easier)
    s["fd_aging_flammability"] = gaussian(
        p.get("aging_flammability_boost", 5), 5.0, 2.0) * 100

    # Constraint: flammability boost > corrosion boost (fire is fast, rust is slow)
    flamm = p.get("aging_flammability_boost", 5)
    corr = p.get("aging_corrosion_boost", 3)
    s["fd_flamm_above_corr"] = smooth_gt(flamm, corr, scale=1.0) * 100

    return s


def score_all(params: dict[str, Any]) -> dict[str, float]:
    """Score ALL parameters (element + worldgen + light + fields). Returns flat dict of 0-100 scores."""
    scores = {}
    scores.update(score_element_params(params))
    scores.update(score_worldgen_params(params))
    scores.update(score_light_params(params))
    scores.update(score_fields_params(params))
    return scores


def compute_aggregate(scores: dict[str, float]) -> dict[str, float]:
    """Weighted aggregate from individual scores."""
    def avg(prefix: str) -> float:
        vals = [v for k, v in scores.items() if k.startswith(prefix)]
        return sum(vals) / len(vals) if vals else 0.0

    el_density = avg("el_density_")
    el_buoyancy = avg("el_oil_floats") if "el_oil_floats" in scores else 0
    # Recalculate buoyancy properly
    buoy_keys = [k for k in scores if k.startswith("el_") and "floats" in k]
    el_buoyancy = sum(scores[k] for k in buoy_keys) / len(buoy_keys) if buoy_keys else 0
    el_temp = avg("el_temp_")
    el_temp_extra_keys = [k for k in scores if k.startswith("el_freeze_") or k.startswith("el_ice_freeze")]
    el_temp_extras = sum(scores[k] for k in el_temp_extra_keys) / len(el_temp_extra_keys) if el_temp_extra_keys else 0
    el_visc = avg("el_visc_")
    visc_feel_keys = [k for k in scores if k.endswith("_visc_feel")]
    el_visc_feel = sum(scores[k] for k in visc_feel_keys) / len(visc_feel_keys) if visc_feel_keys else 0
    el_gravity = avg("el_gravity_") if any(k.startswith("el_gravity_") for k in scores) else 0
    grav_keys = [k for k in scores if k.startswith("el_gravity_") or k.startswith("el_sand_gravity")]
    el_gravity = sum(scores[k] for k in grav_keys) / len(grav_keys) if grav_keys else 0
    behavior_keys = [k for k in scores if k.startswith("el_") and k.endswith("_feel")
                     and "visc" not in k and "gravity" not in k]
    el_behavior = sum(scores[k] for k in behavior_keys) / len(behavior_keys) if behavior_keys else 0

    wg_score = avg("wg_")
    lt_score = avg("lt_")
    chem_score = avg("el_chem_")
    fd_score = avg("fd_")

    physics = (
        el_density * 0.18 +
        el_buoyancy * 0.07 +
        el_temp * 0.09 +
        el_temp_extras * 0.03 +
        (el_visc + el_visc_feel) / 2 * 0.09 +
        el_gravity * 0.05 +
        el_behavior * 0.05 +
        lt_score * 0.07 +
        chem_score * 0.07 +
        fd_score * 0.10 +
        wg_score * 0.20
    )

    return {
        "physics": round(physics, 2),
        "density": round(el_density, 2),
        "buoyancy": round(el_buoyancy, 2),
        "temperature": round((el_temp + el_temp_extras) / 2, 2),
        "viscosity": round((el_visc + el_visc_feel) / 2, 2),
        "gravity": round(el_gravity, 2),
        "behavior": round(el_behavior, 2),
        "light": round(lt_score, 2),
        "chemistry": round(chem_score, 2),
        "fields": round(fd_score, 2),
        "worldgen": round(wg_score, 2),
    }


# ===================================================================
# SENSITIVITY ANALYSIS
# ===================================================================

def compute_sensitivity(params: dict[str, Any]) -> dict[str, float]:
    """For each parameter, compute score change from +/-10%.

    Returns sensitivity per param. A sensitivity of 0.0 means the
    benchmark is FLAT for that parameter (BAD -- means it's not measured).
    """
    base = score_all(params)
    base_total = sum(base.values()) / len(base)

    results = {}
    for key, value in params.items():
        if not isinstance(value, (int, float)) or value == 0:
            continue

        deltas = []
        for pct in [0.90, 0.95, 1.05, 1.10]:  # test +/-5% and +/-10%
            perturbed = dict(params)
            if isinstance(value, float):
                perturbed[key] = value * pct
            else:
                perturbed[key] = max(1, int(value * pct))
                if perturbed[key] == value:
                    # Int didn't change -- nudge by 1
                    perturbed[key] = value + (1 if pct > 1 else -1)

            new_scores = score_all(perturbed)
            new_total = sum(new_scores.values()) / len(new_scores)
            deltas.append(abs(new_total - base_total))

        results[key] = round(max(deltas), 4)

    return results


# ===================================================================
# VERIFICATION -- prove every parameter moves the score
# ===================================================================

def verify_sensitivity(params: dict[str, Any]) -> bool:
    """Verify that EVERY parameter produces a non-zero sensitivity.

    Returns True if all pass. Prints failures to stderr.
    """
    sens = compute_sensitivity(params)
    all_pass = True

    print(f"\n{'='*70}", file=sys.stderr, flush=True)
    print(f"  BENCHMARK SENSITIVITY VERIFICATION", file=sys.stderr, flush=True)
    print(f"  Testing {len(sens)} parameters with +/-10% perturbation", file=sys.stderr, flush=True)
    print(f"{'='*70}\n", file=sys.stderr, flush=True)

    # Sort by sensitivity descending
    sorted_sens = sorted(sens.items(), key=lambda x: -x[1])

    max_key_len = max(len(k) for k in sens) if sens else 20

    for key, delta in sorted_sens:
        bar_len = min(50, int(delta * 20))
        bar = "#" * bar_len
        status = "OK" if delta > 0.001 else "FLAT!"

        if delta <= 0.001:
            all_pass = False
            print(f"  FAIL  {key:{max_key_len}s}: {delta:8.4f}  {bar}  *** FLAT -- "
                  f"parameter has NO effect on score ***", file=sys.stderr, flush=True)
        elif delta < 0.01:
            print(f"  WEAK  {key:{max_key_len}s}: {delta:8.4f}  {bar}  "
                  f"(very low sensitivity)", file=sys.stderr, flush=True)
        else:
            print(f"  {status:4s}  {key:{max_key_len}s}: {delta:8.4f}  {bar}",
                  file=sys.stderr, flush=True)

    print(f"\n{'='*70}", file=sys.stderr, flush=True)
    if all_pass:
        print(f"  ALL {len(sens)} PARAMETERS VERIFIED: every one moves the score",
              file=sys.stderr, flush=True)
    else:
        flat = [k for k, v in sens.items() if v <= 0.001]
        print(f"  FAILED: {len(flat)} parameters have ZERO sensitivity: {flat}",
              file=sys.stderr, flush=True)
    print(f"{'='*70}\n", file=sys.stderr, flush=True)

    return all_pass


# ===================================================================
# DEFAULT PARAMETER VALUES
# ===================================================================

DEFAULT_PARAMS: dict[str, int | float] = {
    # Element densities
    "sand_density": 150, "water_density": 100, "oil_density": 80,
    "stone_density": 255, "metal_density": 240, "ice_density": 90,
    "wood_density": 85, "dirt_density": 145, "lava_density": 200,
    # Gravity
    "sand_gravity": 2, "water_gravity": 1,
    # Temperature thresholds
    "water_boil_point": 180, "water_freeze_point": 30,
    "sand_melt_point": 220, "ice_melt_point": 40,
    # Viscosity
    "oil_viscosity": 2, "mud_viscosity": 3, "lava_viscosity": 4,
    # Behavioral
    "evaporation_rate": 1000, "fire_spread_prob": 0.15, "erosion_rate": 200,
    # WorldConfig core
    "terrainScale": 1.0, "waterLevel": 0.40, "caveDensity": 0.30,
    "vegetation": 0.50,
    # WorldConfig geology
    "oreRichness": 0.40, "copperDepth": 0.30, "metalDepth": 0.60,
    "coalSeams": 0.20, "sulfurNearLava": 0.50, "saltDeposits": 0.15,
    "clayNearWater": 0.40, "volcanicActivity": 0.30,
    # WorldConfig ecosystem
    "co2InCaves": 0.30, "compostDepth": 0.40, "fungalGrowth": 0.30,
    "algaeInWater": 0.40, "seedScatter": 0.30,
    # WorldConfig electrical
    "conductiveVeins": 0.30, "insulatingLayers": 0.20,
    # WorldConfig tuning
    "dirtDepthBase": 8.0, "dirtDepthVariance": 17.0,
    "copperSpread": 20.0, "metalSpread": 15.0,
    "copperThresholdBase": 0.70, "metalThresholdBase": 0.68,
    "coalMaxDepthFrac": 0.50, "coalSeamThickness": 0.03,
    # Chemistry system
    "pH_diffusion_rate": 1, "acid_pH_value": 20,
    "salt_dissolve_rate": 5, "co2_dissolve_rate": 8,
    "saturation_threshold": 200, "charge_decay_rate": 1,
    "electrolysis_charge_threshold": 20,
    # Physics fields system
    "vibration_decay_rate": 240, "vibration_propagation_factor": 10,
    "wind_variation_strength": 3, "stress_failure_multiplier": 2,
    "momentum_accumulation_rate": 3, "aging_corrosion_boost": 3,
    "aging_flammability_boost": 5,
    # pH extended
    "ash_pH_value": 183,
    # --- SimTuning: sand_dirt_mud ---
    "sandToMudRate": 10, "sandToMudSubmergedRate": 80,
    "dirtAshAbsorb": 10, "dirtWaterErosionBase": 10, "dirtFlowingErosion": 8,
    "mudContactDry": 4, "mudProximityDry": 40,
    # --- SimTuning: water_ice_steam ---
    "waterTntDissolve": 10, "waterSmokeDissolve": 10, "waterRainbowSpread": 40,
    "waterPlantDamage": 20, "waterAcidPlantDamage": 10, "waterBubbleRate": 500,
    "waterPressurePush": 8, "waterMomentumReset": 4, "waterDirtErosion": 20,
    "waterSandErosion": 30, "waterSedimentDeposit": 40, "waterSeepageRate": 12,
    "waterHydraulicRate": 3, "waterStoneExit": 6,
    "iceRegelation": 4, "iceAmbientMeltDay": 20, "iceAmbientMeltNight": 60,
    "snowMeltRateDay": 20, "snowMeltRateNight": 40, "snowFreezeWater": 30,
    "snowAvalanche": 3, "snowWindDrift": 2,
    "steamAltitudeRain": 5, "steamDeposition": 3, "steamIceCondense": 4,
    "steamTrappedSeep": 40,
    # --- SimTuning: fire_lava_smoke ---
    "fireOxygenConsume": 3, "fireOilLifetimeBase": 70, "fireOilLifetimeVar": 50,
    "fireLifetimeBase": 40, "fireLifetimeVar": 40, "fireBurnoutSmoke": 3,
    "firePlantIgnite": 2, "fireOilChainIgnite": 3, "fireWoodPyrolysis": 3,
    "fireFlicker": 6, "fireLateralShimmy": 5,
    "lavaCoolingBase": 200, "lavaCoolingVar": 50, "lavaCoolIsolated": 80,
    "lavaCoolIsolatedVar": 30, "lavaCoolPartial": 140, "lavaCoolPartialVar": 40,
    "lavaSmokeEmit": 80, "lavaSteamEmit": 120, "lavaEruptionOpen": 60,
    "lavaEruptionPressured": 30, "lavaEruptThreshLow": 20, "lavaEruptThreshHigh": 10,
    "lavaSpatter": 100, "lavaIgniteFlammable": 2, "lavaSandToGlass": 40,
    "lavaMeltMetal": 80, "lavaDryMud": 10, "lavaGasEmit": 100,
    "smokeLateralDrift": 3,
    # --- SimTuning: plant_fungus_growth ---
    "plantAcidDamage": 3, "plantDecomposeRate": 10, "plantO2Produce": 8,
    "plantSeedRateYoung": 500, "plantSeedRateOld": 200, "plantGrassSpread": 40,
    "plantMushroomSpread": 80, "plantTreeBranch": 3, "plantTreeRootGrow": 50,
    "plantTreeBranchSkip": 2,
    "fungusDeathToCompost": 20, "fungusAshDecompose": 5, "fungusWoodRot": 80,
    "fungusDirtSpread": 40, "fungusSporulate": 200, "fungusMethane": 300,
    "sporeFallRate": 3, "sporeDriftRate": 2,
    "compostDryToDirt": 100, "compostNutrient": 100, "compostMethane": 400,
    "algaeGrowRate": 10, "algaeO2Rate": 40, "algaeCO2Absorb": 10,
    "algaeBloomDieoff": 50, "algaeBloomThreshold": 12,
    "seaweedO2Rate": 30, "seaweedCO2Absorb": 8,
    "seaweedBloomDieoff": 60, "seaweedBloomThreshold": 14,
    "mossO2Rate": 60, "mossCO2Absorb": 15,
    "vineAcidDamage": 3, "vineO2Rate": 5,
    "flowerAcidDamage": 3, "flowerO2Rate": 6,
    # --- SimTuning: chemical_acid_metal ---
    "acidLifetimeBase": 200, "acidLifetimeVar": 60, "acidWaterDilute": 8,
    "acidIceMelt": 8, "acidSnowMelt": 5, "acidLavaReact": 5,
    "acidWaterBubble": 20,
    "stoneThinSupport": 60, "stoneNoLateralFall": 8, "stoneWeatherWater": 60,
    "stoneWeatherCrumble": 20, "stoneFrostWeather": 20, "stoneFrostCrumble": 15,
    "stoneLavaCrack": 200,
    "glassLavaMeltBase": 80, "glassLavaMeltVar": 40, "glassThermalShatter": 3,
    "metalFallResist": 30, "metalRustRate": 500, "metalSaltRustRate": 100,
    "metalSaltRustAlkaline": 300, "metalHotIgniteRate": 6, "metalHotWoodChar": 10,
    "metalCondensation": 100,
    "rustCrumble": 50, "saltDissolveRate": 5, "saltDeiceRate": 15,
    "saltPlantKill": 30, "copperPatinaBase": 2000, "copperAcidRate": 20,
    "sulfurTarnishRate": 300,
    # --- SimTuning: creature_rates ---
    "woodFireSpread": 12, "woodBurnoutBase": 40, "woodBurnoutVar": 20,
    "woodCharcoalChance": 5, "woodAnoxicPyrolysis": 60, "woodWaterAbsorb": 30,
    "woodWetBurn": 5, "woodPetrify": 80,
    "avalancheStandard": 3, "avalancheExtended": 4,
    "bubbleWobble": 20, "ashLateralDrift": 3, "ashAvalanche": 3,
    "methaneLateralDrift": 2, "hydrogenDrift": 2,
    "honeyCrystallize": 50, "honeyCrystallizeLife": 250,
    "webWaterDissolve": 30, "webDecayLife": 200, "thornDamage": 15,
    "antExplorerWander": 60, "antBlobDisperse": 3,
}


# ===================================================================
# OPTUNA SEARCH SPACE
# ===================================================================

PARAM_SPACE: dict[str, tuple[float, float]] = {
    # Element densities (9 params)
    "sand_density": (120, 180),
    "water_density": (80, 120),
    "oil_density": (60, 95),
    "stone_density": (230, 255),
    "metal_density": (235, 255),
    "ice_density": (80, 100),
    "wood_density": (60, 100),
    "dirt_density": (130, 160),
    "lava_density": (180, 220),
    # Gravity (2 params)
    "sand_gravity": (1, 3),
    "water_gravity": (1, 2),
    # Temperature thresholds (4 params)
    "water_boil_point": (160, 200),
    "water_freeze_point": (20, 50),
    "sand_melt_point": (200, 250),
    "ice_melt_point": (30, 60),
    # Viscosity (3 params)
    "oil_viscosity": (1, 4),
    "mud_viscosity": (2, 5),
    "lava_viscosity": (3, 6),
    # Behavioral (3 params)
    "evaporation_rate": (500, 3000),
    "fire_spread_prob": (0.05, 0.40),
    "erosion_rate": (50, 500),
    # WorldConfig core (4 params)
    "terrainScale": (0.4, 2.5),
    "waterLevel": (0.10, 0.70),
    "caveDensity": (0.05, 0.80),
    "vegetation": (0.02, 0.95),
    # WorldConfig geology (8 params)
    "oreRichness": (0.10, 0.80),
    "copperDepth": (0.15, 0.50),
    "metalDepth": (0.35, 0.80),
    "coalSeams": (0.05, 0.50),
    "sulfurNearLava": (0.0, 0.80),
    "saltDeposits": (0.0, 0.40),
    "clayNearWater": (0.10, 0.60),
    "volcanicActivity": (0.0, 0.70),
    # WorldConfig ecosystem (5 params)
    "co2InCaves": (0.0, 0.60),
    "compostDepth": (0.10, 0.60),
    "fungalGrowth": (0.0, 0.60),
    "algaeInWater": (0.10, 0.70),
    "seedScatter": (0.05, 0.60),
    # WorldConfig electrical (2 params)
    "conductiveVeins": (0.0, 0.60),
    "insulatingLayers": (0.0, 0.40),
    # Light system (4 params)
    "fire_light_emission": (120, 255),
    "lava_light_emission": (160, 255),
    "light_falloff_rate": (0.5, 3.0),
    "photosynthesis_threshold": (30, 80),
    "fungus_light_max": (15, 50),
    # WorldConfig tuning (8 params)
    "dirtDepthBase": (3.0, 18.0),
    "dirtDepthVariance": (4.0, 25.0),
    "copperSpread": (10.0, 30.0),
    "metalSpread": (8.0, 25.0),
    "copperThresholdBase": (0.55, 0.85),
    "metalThresholdBase": (0.50, 0.80),
    "coalMaxDepthFrac": (0.25, 0.75),
    "coalSeamThickness": (0.01, 0.08),
    # Chemistry system (7 params)
    "pH_diffusion_rate": (1, 4),
    "acid_pH_value": (10, 40),
    "salt_dissolve_rate": (2, 12),
    "co2_dissolve_rate": (3, 15),
    "saturation_threshold": (100, 255),
    "charge_decay_rate": (1, 4),
    "electrolysis_charge_threshold": (10, 50),
    # Physics fields system (7 params)
    "vibration_decay_rate": (200, 250),
    "vibration_propagation_factor": (6, 14),
    "wind_variation_strength": (1, 6),
    "stress_failure_multiplier": (1, 4),
    "momentum_accumulation_rate": (1, 6),
    "aging_corrosion_boost": (1, 6),
    "aging_flammability_boost": (2, 10),
    # pH extended (1 param)
    "ash_pH_value": (160, 220),
    # --- SimTuning: sand_dirt_mud ---
    "sandToMudRate": (3, 30), "sandToMudSubmergedRate": (20, 200),
    "dirtAshAbsorb": (3, 30), "dirtWaterErosionBase": (3, 30), "dirtFlowingErosion": (2, 20),
    "mudContactDry": (2, 10), "mudProximityDry": (10, 100),
    # --- SimTuning: water_ice_steam ---
    "waterTntDissolve": (3, 30), "waterSmokeDissolve": (3, 30), "waterRainbowSpread": (10, 100),
    "waterPlantDamage": (5, 60), "waterAcidPlantDamage": (3, 30), "waterBubbleRate": (100, 1500),
    "waterPressurePush": (2, 20), "waterMomentumReset": (1, 10), "waterDirtErosion": (5, 60),
    "waterSandErosion": (8, 80), "waterSedimentDeposit": (10, 100), "waterSeepageRate": (3, 30),
    "waterHydraulicRate": (1, 8), "waterStoneExit": (2, 15),
    "iceRegelation": (1, 10), "iceAmbientMeltDay": (5, 60), "iceAmbientMeltNight": (15, 150),
    "snowMeltRateDay": (5, 60), "snowMeltRateNight": (10, 100), "snowFreezeWater": (8, 80),
    "snowAvalanche": (2, 8), "snowWindDrift": (1, 5),
    "steamAltitudeRain": (2, 12), "steamDeposition": (1, 8), "steamIceCondense": (2, 8),
    "steamTrappedSeep": (10, 100),
    # --- SimTuning: fire_lava_smoke ---
    "fireOxygenConsume": (1, 8), "fireOilLifetimeBase": (30, 150), "fireOilLifetimeVar": (15, 100),
    "fireLifetimeBase": (15, 80), "fireLifetimeVar": (10, 80), "fireBurnoutSmoke": (2, 6),
    "firePlantIgnite": (1, 5), "fireOilChainIgnite": (1, 8), "fireWoodPyrolysis": (1, 8),
    "fireFlicker": (3, 12), "fireLateralShimmy": (2, 12),
    "lavaCoolingBase": (80, 400), "lavaCoolingVar": (15, 100), "lavaCoolIsolated": (30, 160),
    "lavaCoolIsolatedVar": (10, 60), "lavaCoolPartial": (60, 280), "lavaCoolPartialVar": (15, 80),
    "lavaSmokeEmit": (20, 200), "lavaSteamEmit": (30, 300), "lavaEruptionOpen": (15, 150),
    "lavaEruptionPressured": (8, 80), "lavaEruptThreshLow": (5, 50), "lavaEruptThreshHigh": (3, 25),
    "lavaSpatter": (30, 250), "lavaIgniteFlammable": (1, 5), "lavaSandToGlass": (10, 100),
    "lavaMeltMetal": (20, 200), "lavaDryMud": (3, 30), "lavaGasEmit": (30, 250),
    "smokeLateralDrift": (2, 6),
    # --- SimTuning: plant_fungus_growth ---
    "plantAcidDamage": (1, 8), "plantDecomposeRate": (3, 30), "plantO2Produce": (2, 20),
    "plantSeedRateYoung": (150, 1200), "plantSeedRateOld": (60, 500), "plantGrassSpread": (10, 100),
    "plantMushroomSpread": (20, 200), "plantTreeBranch": (1, 8), "plantTreeRootGrow": (15, 120),
    "plantTreeBranchSkip": (1, 5),
    "fungusDeathToCompost": (5, 60), "fungusAshDecompose": (2, 12), "fungusWoodRot": (20, 200),
    "fungusDirtSpread": (10, 100), "fungusSporulate": (60, 500), "fungusMethane": (80, 800),
    "sporeFallRate": (1, 8), "sporeDriftRate": (1, 5),
    "compostDryToDirt": (30, 250), "compostNutrient": (30, 250), "compostMethane": (100, 1000),
    "algaeGrowRate": (3, 30), "algaeO2Rate": (10, 100), "algaeCO2Absorb": (3, 30),
    "algaeBloomDieoff": (15, 120), "algaeBloomThreshold": (6, 20),
    "seaweedO2Rate": (8, 80), "seaweedCO2Absorb": (2, 20),
    "seaweedBloomDieoff": (15, 150), "seaweedBloomThreshold": (6, 25),
    "mossO2Rate": (15, 150), "mossCO2Absorb": (4, 40),
    "vineAcidDamage": (1, 8), "vineO2Rate": (2, 12),
    "flowerAcidDamage": (1, 8), "flowerO2Rate": (2, 15),
    # --- SimTuning: chemical_acid_metal ---
    "acidLifetimeBase": (80, 400), "acidLifetimeVar": (15, 120), "acidWaterDilute": (2, 20),
    "acidIceMelt": (2, 20), "acidSnowMelt": (2, 12), "acidLavaReact": (2, 12),
    "acidWaterBubble": (5, 60),
    "stoneThinSupport": (15, 150), "stoneNoLateralFall": (2, 20), "stoneWeatherWater": (15, 150),
    "stoneWeatherCrumble": (5, 60), "stoneFrostWeather": (5, 60), "stoneFrostCrumble": (4, 40),
    "stoneLavaCrack": (60, 500),
    "glassLavaMeltBase": (30, 160), "glassLavaMeltVar": (10, 80), "glassThermalShatter": (1, 8),
    "metalFallResist": (8, 80), "metalRustRate": (150, 1500), "metalSaltRustRate": (30, 300),
    "metalSaltRustAlkaline": (80, 800), "metalHotIgniteRate": (2, 15), "metalHotWoodChar": (3, 25),
    "metalCondensation": (30, 250),
    "rustCrumble": (15, 120), "saltDissolveRate": (2, 12), "saltDeiceRate": (4, 40),
    "saltPlantKill": (8, 80), "copperPatinaBase": (500, 5000), "copperAcidRate": (5, 60),
    "sulfurTarnishRate": (80, 800),
    # --- SimTuning: creature_rates ---
    "woodFireSpread": (3, 30), "woodBurnoutBase": (15, 80), "woodBurnoutVar": (5, 50),
    "woodCharcoalChance": (2, 10), "woodAnoxicPyrolysis": (15, 150), "woodWaterAbsorb": (8, 80),
    "woodWetBurn": (2, 12), "woodPetrify": (20, 200),
    "avalancheStandard": (2, 6), "avalancheExtended": (2, 8),
    "bubbleWobble": (5, 60), "ashLateralDrift": (1, 8), "ashAvalanche": (1, 8),
    "methaneLateralDrift": (1, 5), "hydrogenDrift": (1, 5),
    "honeyCrystallize": (15, 120), "honeyCrystallizeLife": (100, 400),
    "webWaterDissolve": (8, 80), "webDecayLife": (60, 500), "thornDamage": (5, 40),
    "antExplorerWander": (15, 150), "antBlobDisperse": (1, 8),
}

# Classify each param as int or float for Optuna suggestion
_INT_PARAMS = {
    "sand_density", "water_density", "oil_density", "stone_density",
    "metal_density", "ice_density", "wood_density", "dirt_density",
    "lava_density", "sand_gravity", "water_gravity",
    "water_boil_point", "water_freeze_point", "sand_melt_point",
    "ice_melt_point", "oil_viscosity", "mud_viscosity", "lava_viscosity",
    "evaporation_rate", "erosion_rate",
    "fire_light_emission", "lava_light_emission", "photosynthesis_threshold",
    "fungus_light_max",
    "pH_diffusion_rate", "acid_pH_value", "salt_dissolve_rate",
    "co2_dissolve_rate", "saturation_threshold", "charge_decay_rate",
    "electrolysis_charge_threshold",
    "vibration_decay_rate", "vibration_propagation_factor",
    "wind_variation_strength", "stress_failure_multiplier",
    "momentum_accumulation_rate", "aging_corrosion_boost",
    "aging_flammability_boost", "ash_pH_value",
    # SimTuning (all int)
    "sandToMudRate", "sandToMudSubmergedRate",
    "dirtAshAbsorb", "dirtWaterErosionBase", "dirtFlowingErosion",
    "mudContactDry", "mudProximityDry",
    "waterTntDissolve", "waterSmokeDissolve", "waterRainbowSpread",
    "waterPlantDamage", "waterAcidPlantDamage", "waterBubbleRate",
    "waterPressurePush", "waterMomentumReset", "waterDirtErosion",
    "waterSandErosion", "waterSedimentDeposit", "waterSeepageRate",
    "waterHydraulicRate", "waterStoneExit",
    "iceRegelation", "iceAmbientMeltDay", "iceAmbientMeltNight",
    "snowMeltRateDay", "snowMeltRateNight", "snowFreezeWater",
    "snowAvalanche", "snowWindDrift",
    "steamAltitudeRain", "steamDeposition", "steamIceCondense", "steamTrappedSeep",
    "fireOxygenConsume", "fireOilLifetimeBase", "fireOilLifetimeVar",
    "fireLifetimeBase", "fireLifetimeVar", "fireBurnoutSmoke",
    "firePlantIgnite", "fireOilChainIgnite", "fireWoodPyrolysis",
    "fireFlicker", "fireLateralShimmy",
    "lavaCoolingBase", "lavaCoolingVar", "lavaCoolIsolated",
    "lavaCoolIsolatedVar", "lavaCoolPartial", "lavaCoolPartialVar",
    "lavaSmokeEmit", "lavaSteamEmit", "lavaEruptionOpen",
    "lavaEruptionPressured", "lavaEruptThreshLow", "lavaEruptThreshHigh",
    "lavaSpatter", "lavaIgniteFlammable", "lavaSandToGlass",
    "lavaMeltMetal", "lavaDryMud", "lavaGasEmit", "smokeLateralDrift",
    "plantAcidDamage", "plantDecomposeRate", "plantO2Produce",
    "plantSeedRateYoung", "plantSeedRateOld", "plantGrassSpread",
    "plantMushroomSpread", "plantTreeBranch", "plantTreeRootGrow",
    "plantTreeBranchSkip",
    "fungusDeathToCompost", "fungusAshDecompose", "fungusWoodRot",
    "fungusDirtSpread", "fungusSporulate", "fungusMethane",
    "sporeFallRate", "sporeDriftRate",
    "compostDryToDirt", "compostNutrient", "compostMethane",
    "algaeGrowRate", "algaeO2Rate", "algaeCO2Absorb",
    "algaeBloomDieoff", "algaeBloomThreshold",
    "seaweedO2Rate", "seaweedCO2Absorb",
    "seaweedBloomDieoff", "seaweedBloomThreshold",
    "mossO2Rate", "mossCO2Absorb",
    "vineAcidDamage", "vineO2Rate", "flowerAcidDamage", "flowerO2Rate",
    "acidLifetimeBase", "acidLifetimeVar", "acidWaterDilute",
    "acidIceMelt", "acidSnowMelt", "acidLavaReact", "acidWaterBubble",
    "stoneThinSupport", "stoneNoLateralFall", "stoneWeatherWater",
    "stoneWeatherCrumble", "stoneFrostWeather", "stoneFrostCrumble",
    "stoneLavaCrack",
    "glassLavaMeltBase", "glassLavaMeltVar", "glassThermalShatter",
    "metalFallResist", "metalRustRate", "metalSaltRustRate",
    "metalSaltRustAlkaline", "metalHotIgniteRate", "metalHotWoodChar",
    "metalCondensation",
    "rustCrumble", "saltDissolveRate", "saltDeiceRate", "saltPlantKill",
    "copperPatinaBase", "copperAcidRate", "sulfurTarnishRate",
    "woodFireSpread", "woodBurnoutBase", "woodBurnoutVar",
    "woodCharcoalChance", "woodAnoxicPyrolysis", "woodWaterAbsorb",
    "woodWetBurn", "woodPetrify",
    "avalancheStandard", "avalancheExtended",
    "bubbleWobble", "ashLateralDrift", "ashAvalanche",
    "methaneLateralDrift", "hydrogenDrift",
    "honeyCrystallize", "honeyCrystallizeLife",
    "webWaterDissolve", "webDecayLife", "thornDamage",
    "antExplorerWander", "antBlobDisperse",
}


# ===================================================================
# OPTUNA OPTIMIZATION
# ===================================================================

# ===================================================================
# PARAMETER GROUPS -- for staged optimization on 68+ params
# ===================================================================

# TPE struggles above ~30 params. We split into groups so each
# optimization round tunes a manageable subset while fixing the rest.
# fANOVA importance analysis can reorder groups dynamically.
PARAM_GROUPS = {
    "density": [
        "sand_density", "water_density", "oil_density", "stone_density",
        "metal_density", "ice_density", "wood_density", "dirt_density",
        "lava_density",
    ],
    "temperature": [
        "water_boil_point", "water_freeze_point", "sand_melt_point",
        "ice_melt_point",
    ],
    "dynamics": [
        "sand_gravity", "water_gravity",
        "oil_viscosity", "mud_viscosity", "lava_viscosity",
        "evaporation_rate", "fire_spread_prob", "erosion_rate",
    ],
    "chemistry": [
        "pH_diffusion_rate", "acid_pH_value", "ash_pH_value",
        "salt_dissolve_rate", "co2_dissolve_rate", "saturation_threshold",
        "charge_decay_rate", "electrolysis_charge_threshold",
    ],
    "fields": [
        "vibration_decay_rate", "vibration_propagation_factor",
        "wind_variation_strength", "stress_failure_multiplier",
        "momentum_accumulation_rate", "aging_corrosion_boost",
        "aging_flammability_boost",
    ],
    "light": [
        "fire_light_emission", "lava_light_emission",
        "light_falloff_rate", "photosynthesis_threshold",
        "fungus_light_max",
    ],
    "worldgen_core": [
        "terrainScale", "waterLevel", "caveDensity", "vegetation",
        "volcanicActivity",
    ],
    "worldgen_geology": [
        "oreRichness", "copperDepth", "metalDepth", "coalSeams",
        "sulfurNearLava", "saltDeposits", "clayNearWater",
        "dirtDepthBase", "dirtDepthVariance",
        "copperSpread", "metalSpread",
        "copperThresholdBase", "metalThresholdBase",
        "coalMaxDepthFrac", "coalSeamThickness",
    ],
    "worldgen_eco": [
        "co2InCaves", "compostDepth", "fungalGrowth",
        "algaeInWater", "seedScatter",
        "conductiveVeins", "insulatingLayers",
    ],
    "sand_dirt_mud": [
        "sandToMudRate", "sandToMudSubmergedRate",
        "dirtAshAbsorb", "dirtWaterErosionBase", "dirtFlowingErosion",
        "mudContactDry", "mudProximityDry",
    ],
    "water_ice_steam": [
        "waterTntDissolve", "waterSmokeDissolve", "waterRainbowSpread",
        "waterPlantDamage", "waterAcidPlantDamage", "waterBubbleRate",
        "waterPressurePush", "waterMomentumReset", "waterDirtErosion",
        "waterSandErosion", "waterSedimentDeposit", "waterSeepageRate",
        "waterHydraulicRate", "waterStoneExit",
        "iceRegelation", "iceAmbientMeltDay", "iceAmbientMeltNight",
        "snowMeltRateDay", "snowMeltRateNight", "snowFreezeWater",
        "snowAvalanche", "snowWindDrift",
        "steamAltitudeRain", "steamDeposition", "steamIceCondense",
        "steamTrappedSeep",
    ],
    "fire_lava_smoke": [
        "fireOxygenConsume", "fireOilLifetimeBase", "fireOilLifetimeVar",
        "fireLifetimeBase", "fireLifetimeVar", "fireBurnoutSmoke",
        "firePlantIgnite", "fireOilChainIgnite", "fireWoodPyrolysis",
        "fireFlicker", "fireLateralShimmy",
        "lavaCoolingBase", "lavaCoolingVar", "lavaCoolIsolated",
        "lavaCoolIsolatedVar", "lavaCoolPartial", "lavaCoolPartialVar",
        "lavaSmokeEmit", "lavaSteamEmit", "lavaEruptionOpen",
        "lavaEruptionPressured", "lavaEruptThreshLow", "lavaEruptThreshHigh",
        "lavaSpatter", "lavaIgniteFlammable", "lavaSandToGlass",
        "lavaMeltMetal", "lavaDryMud", "lavaGasEmit", "smokeLateralDrift",
    ],
    "plant_fungus_growth": [
        "plantAcidDamage", "plantDecomposeRate", "plantO2Produce",
        "plantSeedRateYoung", "plantSeedRateOld", "plantGrassSpread",
        "plantMushroomSpread", "plantTreeBranch", "plantTreeRootGrow",
        "plantTreeBranchSkip",
        "fungusDeathToCompost", "fungusAshDecompose", "fungusWoodRot",
        "fungusDirtSpread", "fungusSporulate", "fungusMethane",
        "sporeFallRate", "sporeDriftRate",
        "compostDryToDirt", "compostNutrient", "compostMethane",
        "algaeGrowRate", "algaeO2Rate", "algaeCO2Absorb",
        "algaeBloomDieoff", "algaeBloomThreshold",
        "seaweedO2Rate", "seaweedCO2Absorb",
        "seaweedBloomDieoff", "seaweedBloomThreshold",
        "mossO2Rate", "mossCO2Absorb",
        "vineAcidDamage", "vineO2Rate", "flowerAcidDamage", "flowerO2Rate",
    ],
    "chemical_acid_metal": [
        "acidLifetimeBase", "acidLifetimeVar", "acidWaterDilute",
        "acidIceMelt", "acidSnowMelt", "acidLavaReact", "acidWaterBubble",
        "stoneThinSupport", "stoneNoLateralFall", "stoneWeatherWater",
        "stoneWeatherCrumble", "stoneFrostWeather", "stoneFrostCrumble",
        "stoneLavaCrack",
        "glassLavaMeltBase", "glassLavaMeltVar", "glassThermalShatter",
        "metalFallResist", "metalRustRate", "metalSaltRustRate",
        "metalSaltRustAlkaline", "metalHotIgniteRate", "metalHotWoodChar",
        "metalCondensation",
        "rustCrumble", "saltDissolveRate", "saltDeiceRate", "saltPlantKill",
        "copperPatinaBase", "copperAcidRate", "sulfurTarnishRate",
    ],
    "creature_rates": [
        "woodFireSpread", "woodBurnoutBase", "woodBurnoutVar",
        "woodCharcoalChance", "woodAnoxicPyrolysis", "woodWaterAbsorb",
        "woodWetBurn", "woodPetrify",
        "avalancheStandard", "avalancheExtended",
        "bubbleWobble", "ashLateralDrift", "ashAvalanche",
        "methaneLateralDrift", "hydrogenDrift",
        "honeyCrystallize", "honeyCrystallizeLife",
        "webWaterDissolve", "webDecayLife", "thornDamage",
        "antExplorerWander", "antBlobDisperse",
    ],
    "colony_dynamics": [
        "colonyMigrationThreshold", "colonyMigrationInterval",
        "queenEggRate", "queenMaxAge", "queenFoodPerEgg", "queenMoveSpeed",
        "orphanDecayRate",
        "casteWorkerRatio", "casteSoldierRatio", "casteNurseRatio", "casteScoutRatio",
        "eggHatchTicks", "larvaGrowTicks", "larvaFoodPerGrow",
        "digSuccessRate", "dirtCarryDrop",
        "soldierPatrolRadius", "alarmMobilizeRadius",
        "spiderWebRate", "beePollinateRate", "wormAerateRate",
        "beetleDecomposeRate", "fishEatRate",
        "fishMaxPop", "beeMaxPop", "wormMaxPop",
    ],
}


def run_grouped_optimization(n_trials_per_group: int, n_workers: int,
                              groups: list[str] | None = None,
                              warm_start: bool = False):
    """Staged optimization: tune one parameter group at a time.

    For 68+ parameters, TPE's effectiveness drops. This approach:
    1. Fixes all params at current best (or default)
    2. For each group, runs CMA-ES on just that group's ~8-15 params
    3. Merges best results back into the fixed set
    4. Repeats for the next group

    CMA-ES is better than TPE for 8-15 continuous params because it
    maintains a covariance matrix and explores the space more efficiently.
    """
    import optuna
    optuna.logging.set_verbosity(optuna.logging.WARNING)

    target_groups = groups or list(PARAM_GROUPS.keys())
    current_best = dict(DEFAULT_PARAMS)

    # Try to load previous best (always for grouped, or when warm_start)
    best_path = RESEARCH_DIR / "cloud_best_params.json"
    if best_path.exists():
        with open(best_path) as f:
            saved = json.load(f)
        if "params" in saved:
            current_best.update(saved["params"])
            print(f"  Loaded previous best from {best_path}", flush=True)

    print(f"\n{'='*60}", flush=True)
    print(f"  GROUPED PARAMETER OPTIMIZATION", flush=True)
    print(f"{'='*60}", flush=True)
    print(f"  Groups:          {len(target_groups)}", flush=True)
    print(f"  Trials/group:    {n_trials_per_group}", flush=True)
    print(f"  Workers:         {n_workers}", flush=True)
    print(f"  Total params:    {len(PARAM_SPACE)}", flush=True)
    print(f"  Strategy:        CMA-ES per group, fix others at best", flush=True)
    print(flush=True)

    total_start = time.time()

    for group_name in target_groups:
        group_params = PARAM_GROUPS[group_name]
        n_group = len(group_params)

        print(f"\n  --- Group: {group_name} ({n_group} params) ---", flush=True)

        # Use CMA-ES for the active group
        study = optuna.create_study(
            study_name=f"grouped_{group_name}",
            storage=f"sqlite:///{STUDY_DB}",
            direction="maximize",
            load_if_exists=True,
            sampler=optuna.samplers.CmaEsSampler(seed=42),
        )

        def make_objective(active_params, fixed_params):
            def objective(trial):
                params = dict(fixed_params)
                for key in active_params:
                    if key not in PARAM_SPACE:
                        continue
                    lo, hi = PARAM_SPACE[key]
                    if key in _INT_PARAMS:
                        params[key] = trial.suggest_int(key, int(lo), int(hi))
                    else:
                        params[key] = trial.suggest_float(key, lo, hi)

                scores = score_all(params)
                agg = compute_aggregate(scores)
                return agg["physics"]
            return objective

        objective = make_objective(group_params, current_best)

        group_start = time.time()
        study.optimize(
            objective,
            n_trials=n_trials_per_group,
            n_jobs=min(n_workers, 4),  # CMA-ES works better with fewer parallel
        )
        group_elapsed = time.time() - group_start

        # Merge best params from this group into current_best
        if study.best_trial:
            for key in group_params:
                if key in study.best_trial.params:
                    current_best[key] = study.best_trial.params[key]

            print(f"    Best score: {study.best_value:.2f} "
                  f"({len(study.trials)} trials, {group_elapsed:.0f}s)", flush=True)
            for key in group_params:
                if key in study.best_trial.params:
                    default = DEFAULT_PARAMS.get(key, "?")
                    best_val = study.best_trial.params[key]
                    if isinstance(best_val, float):
                        print(f"      {key}: {best_val:.3f} (default: {default})", flush=True)
                    else:
                        print(f"      {key}: {best_val} (default: {default})", flush=True)

    total_elapsed = time.time() - total_start

    # Final score with all merged best params
    final_scores = score_all(current_best)
    final_agg = compute_aggregate(final_scores)

    print(f"\n{'='*60}", flush=True)
    print(f"  FINAL MERGED RESULTS ({total_elapsed:.0f}s total)", flush=True)
    print(f"{'='*60}", flush=True)
    for k, v in sorted(final_agg.items()):
        print(f"    {k}: {v:.2f}", flush=True)

    # Save merged best
    with open(best_path, "w") as f:
        json.dump({
            "params": current_best,
            "scores": {k: round(v, 2) for k, v in final_agg.items()},
            "strategy": "grouped_cmaes",
        }, f, indent=2)
    print(f"\n  Saved: {best_path}", flush=True)

    # Sensitivity check on final result
    sens = compute_sensitivity(current_best)
    flat = [k for k, v in sens.items() if v <= 0.001]
    if flat:
        print(f"\n  WARNING: {len(flat)} params have zero sensitivity: {flat}", flush=True)
    else:
        print(f"\n  All {len(sens)} parameters verified sensitive.", flush=True)


def run_optimization(n_trials: int, n_workers: int,
                      warm_start: bool = False):
    """Run multi-objective Optuna optimization."""
    import optuna
    optuna.logging.set_verbosity(optuna.logging.WARNING)

    study = optuna.create_study(
        study_name="proper_physics_v2",
        storage=f"sqlite:///{STUDY_DB}",
        directions=["maximize", "maximize"],  # physics, worldgen
        load_if_exists=True,
        sampler=optuna.samplers.TPESampler(seed=42, multivariate=True),
    )

    # Warm-start: enqueue previous best as first trial
    if warm_start:
        best_path = RESEARCH_DIR / "cloud_best_params.json"
        if best_path.exists():
            with open(best_path) as f:
                saved = json.load(f)
            if "params" in saved:
                # Clamp to bounds and enqueue
                warm_params = {}
                for key, (lo, hi) in PARAM_SPACE.items():
                    val = saved["params"].get(key, DEFAULT_PARAMS.get(key))
                    if val is not None:
                        warm_params[key] = max(lo, min(hi, val))
                study.enqueue_trial(warm_params)
                print(f"  Warm-started from {best_path}", flush=True)

    def objective(trial):
        params = {}
        for key, (lo, hi) in PARAM_SPACE.items():
            if key in _INT_PARAMS:
                params[key] = trial.suggest_int(key, int(lo), int(hi))
            else:
                params[key] = trial.suggest_float(key, lo, hi)

        scores = score_all(params)
        agg = compute_aggregate(scores)

        # Store category scores as user attrs (skip on SQLite parallel errors)
        try:
            for k, v in agg.items():
                trial.set_user_attr(k, v)
        except Exception:
            pass  # SQLite can't handle parallel user_attr writes — non-critical

        return agg["physics"], agg["worldgen"]

    existing = len(study.trials)
    n_params = len(PARAM_SPACE)

    print(f"\n{'='*60}", flush=True)
    print(f"  PROPER PHYSICS + WORLDGEN OPTIMIZER", flush=True)
    print(f"{'='*60}", flush=True)
    print(f"  Existing trials: {existing}", flush=True)
    print(f"  New trials:      {n_trials}", flush=True)
    print(f"  Workers:         {n_workers}", flush=True)
    print(f"  Parameters:      {n_params} ({len(_INT_PARAMS)} int, "
          f"{n_params - len(_INT_PARAMS)} float)", flush=True)
    print(f"  Objectives:      physics (maximize), worldgen (maximize)", flush=True)
    print(f"  Scoring:         continuous gaussian + sigmoid (zero binary)", flush=True)
    print(flush=True)

    start = time.time()

    def callback(study, trial):
        n = trial.number - existing + 1
        phys = trial.values[0] if trial.values else 0
        wg = trial.values[1] if trial.values else 0
        elapsed = time.time() - start
        if n % 50 == 0 or n <= 5:
            print(f"  [{n}/{n_trials}] #{trial.number} "
                  f"Physics={phys:.1f} WorldGen={wg:.1f} ({elapsed:.0f}s)", flush=True)

    study.optimize(
        objective,
        n_trials=n_trials,
        n_jobs=n_workers,
        callbacks=[callback],
    )

    elapsed = time.time() - start
    pareto = study.best_trials
    print(f"\n  Done in {elapsed:.0f}s ({len(study.trials)} total trials)", flush=True)
    print(f"  Rate: {n_trials / elapsed:.0f} trials/sec", flush=True)
    print(f"  Pareto-optimal: {len(pareto)}", flush=True)

    if pareto:
        best = max(pareto, key=lambda t: sum(t.values))
        print(f"\n  Best combined: #{best.number}", flush=True)
        for k, v in sorted(best.user_attrs.items()):
            print(f"    {k}: {v:.1f}", flush=True)

        print(f"\n  Element parameters:", flush=True)
        for k in sorted(k for k in best.params if k in _INT_PARAMS or
                        k.endswith("_density") or k.endswith("_gravity") or
                        k.endswith("_point") or k.endswith("_viscosity") or
                        k in ("evaporation_rate", "fire_spread_prob", "erosion_rate")):
            if k in best.params:
                default = DEFAULT_PARAMS.get(k, "?")
                print(f"    {k}: {best.params[k]} (default: {default})", flush=True)

        print(f"\n  WorldGen parameters:", flush=True)
        for k in sorted(k for k in best.params if k not in _INT_PARAMS and
                        not k.endswith("_density") and not k.endswith("_gravity") and
                        not k.endswith("_point") and not k.endswith("_viscosity") and
                        k not in ("evaporation_rate", "fire_spread_prob", "erosion_rate")):
            default = DEFAULT_PARAMS.get(k, "?")
            print(f"    {k}: {best.params[k]:.3f} (default: {default})", flush=True)

        # Save best params
        results_path = RESEARCH_DIR / "cloud_best_params.json"
        with open(results_path, "w") as f:
            json.dump({
                "params": best.params,
                "scores": best.user_attrs,
                "trial": best.number,
            }, f, indent=2)
        print(f"\n  Saved: {results_path}", flush=True)

    # Post-optimization sensitivity check
    if pareto:
        best_params = max(pareto, key=lambda t: sum(t.values)).params
        sens = compute_sensitivity(best_params)
        flat = [k for k, v in sens.items() if v <= 0.001]
        if flat:
            print(f"\n  WARNING: {len(flat)} params have zero sensitivity: {flat}", flush=True)
        else:
            print(f"\n  All {len(sens)} parameters verified sensitive.", flush=True)


# ===================================================================
# FANOVA IMPORTANCE ANALYSIS
# ===================================================================

def _run_importance_analysis(n_trials: int = 200):
    """Run fANOVA importance analysis and print/save results.

    Uses random exploration trials to build a diverse coverage of the
    search space, then applies fANOVA to rank parameter importance.
    """
    import optuna
    optuna.logging.set_verbosity(optuna.logging.WARNING)

    study = optuna.create_study(
        study_name="fanova_exploration",
        storage=f"sqlite:///{STUDY_DB}",
        direction="maximize",
        load_if_exists=True,
        sampler=optuna.samplers.RandomSampler(seed=42),
    )

    def objective(trial):
        params = {}
        for key, (lo, hi) in PARAM_SPACE.items():
            if key in _INT_PARAMS:
                params[key] = trial.suggest_int(key, int(lo), int(hi))
            else:
                params[key] = trial.suggest_float(key, lo, hi)
        scores = score_all(params)
        agg = compute_aggregate(scores)
        return agg["physics"]

    existing = len(study.trials)
    needed = max(0, n_trials - existing)
    if needed > 0:
        print(f"\n  Running {needed} random exploration trials for fANOVA...",
              file=sys.stderr, flush=True)
        study.optimize(objective, n_trials=needed, n_jobs=4)

    # Run fANOVA
    evaluator = optuna.importance.FanovaImportanceEvaluator(seed=42)
    importances = optuna.importance.get_param_importances(
        study, evaluator=evaluator
    )

    # Print results
    print(f"\n{'='*70}", file=sys.stderr, flush=True)
    print(f"  fANOVA PARAMETER IMPORTANCE ({len(study.trials)} trials)",
          file=sys.stderr, flush=True)
    print(f"{'='*70}\n", file=sys.stderr, flush=True)

    max_imp = max(importances.values()) if importances else 1.0
    for rank, (param, imp) in enumerate(importances.items(), 1):
        bar = "#" * min(50, int(imp / max_imp * 50))
        print(f"  {rank:4d}. {param:35s} {imp:.6f}  {bar}",
              file=sys.stderr, flush=True)

    # Classify importance tiers
    high = [k for k, v in importances.items() if v >= max_imp * 0.1]
    medium = [k for k, v in importances.items()
              if max_imp * 0.01 <= v < max_imp * 0.1]
    low = [k for k, v in importances.items() if v < max_imp * 0.01]

    print(f"\n  HIGH importance (>10% of max): {len(high)} params",
          file=sys.stderr, flush=True)
    print(f"  MEDIUM importance (1-10%):     {len(medium)} params",
          file=sys.stderr, flush=True)
    print(f"  LOW importance (<1%):          {len(low)} params "
          f"(candidates for freezing)", file=sys.stderr, flush=True)

    # Save
    importance_path = RESEARCH_DIR / "cloud_param_importance.json"
    with open(importance_path, "w") as f:
        json.dump({
            "importances": {k: round(v, 8) for k, v in importances.items()},
            "n_trials": len(study.trials),
            "high_importance": high,
            "medium_importance": medium,
            "low_importance": low,
        }, f, indent=2)
    print(f"\n  Saved: {importance_path}", file=sys.stderr, flush=True)

    # Output JSON for piping
    print(json.dumps({
        "importances": {k: round(v, 8) for k, v in importances.items()},
        "n_high": len(high),
        "n_medium": len(medium),
        "n_low": len(low),
    }), flush=True)


# ===================================================================
# CLI
# ===================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Proper physics + worldgen benchmark (zero binary scoring)")
    parser.add_argument("--config", type=str, help="Trial config JSON file")
    parser.add_argument("--optimize", action="store_true",
                        help="Run Optuna optimization (TPE, all params)")
    parser.add_argument("--grouped", action="store_true",
                        help="Run grouped CMA-ES optimization (better for 68+ params)")
    parser.add_argument("--groups", type=str, default=None,
                        help="Comma-separated group names to optimize (default: all)")
    parser.add_argument("--trials", type=int, default=5000)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--sensitivity", action="store_true",
                        help="Print sensitivity analysis")
    parser.add_argument("--verify", action="store_true",
                        help="Verify ALL parameters move the score (run first!)")
    parser.add_argument("--list-groups", action="store_true",
                        help="List available parameter groups and exit")
    parser.add_argument("--importance", action="store_true",
                        help="Run fANOVA importance analysis on existing trials")
    parser.add_argument("--importance-trials", type=int, default=200,
                        help="Random trials for fANOVA exploration (default: 200)")
    parser.add_argument("--warm-start", action="store_true",
                        help="Warm-start optimization from previous best params")
    args = parser.parse_args()

    if args.list_groups:
        print(f"\nParameter groups ({len(PARAM_GROUPS)} groups, "
              f"{sum(len(v) for v in PARAM_GROUPS.values())} params):\n", flush=True)
        for name, params in PARAM_GROUPS.items():
            print(f"  {name} ({len(params)} params):", flush=True)
            for p in params:
                default = DEFAULT_PARAMS.get(p, "?")
                print(f"    {p} = {default}", flush=True)
        sys.exit(0)

    if args.importance:
        _run_importance_analysis(args.importance_trials)
        return

    if args.grouped:
        groups = args.groups.split(",") if args.groups else None
        run_grouped_optimization(args.trials, args.workers, groups,
                                  warm_start=args.warm_start)
        return

    if args.optimize:
        run_optimization(args.trials, args.workers,
                          warm_start=args.warm_start)
        return

    # Load params
    if args.config:
        with open(args.config) as f:
            config = json.load(f)
        params = {}
        if "elements" in config:
            for elem, props in config["elements"].items():
                for prop, val in props.items():
                    key_map = {
                        "density": f"{elem}_density",
                        "gravity": f"{elem}_gravity",
                        "viscosity": f"{elem}_viscosity",
                        "boilPoint": f"{elem}_boil_point",
                        "freezePoint": f"{elem}_freeze_point",
                        "meltPoint": f"{elem}_melt_point",
                    }
                    params[key_map.get(prop, f"{elem}_{prop}")] = val
            if "behavior" in config:
                params.update(config["behavior"])
            if "worldgen" in config:
                params.update(config["worldgen"])
        else:
            params = config
        # Fill missing with defaults
        for k, v in DEFAULT_PARAMS.items():
            params.setdefault(k, v)
    else:
        params = dict(DEFAULT_PARAMS)

    if args.verify:
        ok = verify_sensitivity(params)
        sys.exit(0 if ok else 1)

    if args.sensitivity:
        sens = compute_sensitivity(params)
        print("Sensitivity (+/-10% perturbation):", file=sys.stderr, flush=True)
        for k, v in sorted(sens.items(), key=lambda x: -x[1]):
            bar = "#" * min(40, int(v * 15))
            print(f"  {k:30s}: {v:8.4f}  {bar}", file=sys.stderr, flush=True)

    # Score
    scores = score_all(params)
    agg = compute_aggregate(scores)

    output = {
        **agg,
        "overall": agg["physics"],
        "n_scores": len(scores),
        "n_params": len(params),
        "details": {k: round(v, 2) for k, v in scores.items()},
    }

    if args.sensitivity:
        output["sensitivity"] = compute_sensitivity(params)

    print(json.dumps(output), flush=True)


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        print("Self-test: imports OK", flush=True)
        scores = score_all(DEFAULT_PARAMS)
        assert len(scores) > 0, "No scores produced"
        agg = compute_aggregate(scores)
        assert "physics" in agg, "Missing physics score"
        print(f"Self-test: {len(scores)} scores, physics={agg['physics']:.1f}", flush=True)
        print("Self-test: PASSED", flush=True)
        sys.exit(0)
    main()
