#!/usr/bin/env python3
"""The Particle Engine -- Optuna Parameter Optimizer.

Bayesian-optimized automatic parameter tuning using multi-objective
optimization (Physics vs Visuals). Persists studies in SQLite for
resumable, incremental search.

Usage:
    python research/optimizer.py run --n-trials 50
    python research/optimizer.py run --n-trials 25 --resume
    python research/optimizer.py show --top 10
    python research/optimizer.py viz
    python research/optimizer.py apply
    python research/optimizer.py test --param sand_density 160 --param water_viscosity 2
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import textwrap
import time
from pathlib import Path
from typing import Any

# Ensure research/ is on sys.path so parameter_contract can be found
# regardless of the cwd the user invokes from.
_RESEARCH_DIR = Path(__file__).resolve().parent
if str(_RESEARCH_DIR) not in sys.path:
    sys.path.insert(0, str(_RESEARCH_DIR))

from parameter_contract import write_trial_config as write_manifest_trial_config

# ---------------------------------------------------------------------------
# Windows UTF-8 fix
# ---------------------------------------------------------------------------
if sys.platform == "win32":
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except Exception:
                pass

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
RESEARCH_DIR = Path(__file__).resolve().parent
PROJECT_DIR = RESEARCH_DIR.parent
STUDY_DB = RESEARCH_DIR / "optuna_study.db"
TRIAL_CONFIG = RESEARCH_DIR / "trial_config.json"
PLOTS_DIR = RESEARCH_DIR / "plots"

# ---------------------------------------------------------------------------
# Current defaults (extracted from element_registry.dart)
# ---------------------------------------------------------------------------
DEFAULTS: dict[str, int | float] = {
    # Densities
    "sand_density": 150,
    "water_density": 100,
    "oil_density": 80,
    "stone_density": 255,
    "metal_density": 240,
    "ice_density": 90,
    "wood_density": 85,
    "dirt_density": 145,
    "lava_density": 200,
    # Gravity
    "sand_gravity": 2,
    "water_gravity": 1,
    # Temperature thresholds
    "water_boil_point": 180,
    "water_freeze_point": 30,
    "sand_melt_point": 220,
    "ice_melt_point": 40,
    # Viscosity
    "oil_viscosity": 2,
    "mud_viscosity": 3,
    "lava_viscosity": 4,
    # Behavioral
    "evaporation_rate": 1000,
    "fire_spread_prob": 0.15,
    "erosion_rate": 200,
    # --- SimTuning: Sand ---
    "sandToMudRate": 10,
    "sandToMudSubmergedRate": 80,
    # --- SimTuning: Water ---
    "waterPressurePush": 8,
    "waterDirtErosion": 20,
    "waterSandErosion": 30,
    "waterSedimentDeposit": 40,
    "waterSeepageRate": 12,
    "waterHydraulicRate": 3,
    "waterBubbleRate": 500,
    "waterMomentumReset": 4,
    # --- SimTuning: Fire ---
    "fireOxygenConsume": 3,
    "fireLifetimeBase": 40,
    "fireLifetimeVar": 40,
    "firePlantIgnite": 2,
    "fireOilChainIgnite": 3,
    "fireWoodPyrolysis": 3,
    "fireLateralShimmy": 5,
    # --- SimTuning: Ice ---
    "iceRegelation": 4,
    "iceAmbientMeltDay": 20,
    "iceAmbientMeltNight": 60,
    # --- SimTuning: Dirt ---
    "dirtWaterErosionBase": 10,
    "dirtFlowingErosion": 8,
    "dirtAshAbsorb": 10,
    # --- SimTuning: Plant ---
    "plantAcidDamage": 3,
    "plantDecomposeRate": 10,
    "plantO2Produce": 8,
    "plantSeedRateYoung": 500,
    "plantSeedRateOld": 200,
    "plantGrassSpread": 40,
    "plantTreeRootGrow": 50,
    # --- SimTuning: Lava ---
    "lavaCoolingBase": 200,
    "lavaCoolingVar": 50,
    "lavaSmokeEmit": 80,
    "lavaSteamEmit": 120,
    "lavaEruptionOpen": 60,
    "lavaEruptionPressured": 30,
    "lavaIgniteFlammable": 2,
    "lavaSandToGlass": 40,
    "lavaMeltMetal": 80,
    # --- SimTuning: Snow ---
    "snowMeltRateDay": 20,
    "snowMeltRateNight": 40,
    "snowFreezeWater": 30,
    "snowAvalanche": 3,
    # --- SimTuning: Wood ---
    "woodFireSpread": 12,
    "woodBurnoutBase": 40,
    "woodCharcoalChance": 5,
    "woodAnoxicPyrolysis": 60,
    "woodWaterAbsorb": 30,
    # --- SimTuning: Metal ---
    "metalRustRate": 500,
    "metalSaltRustRate": 100,
    "metalHotIgniteRate": 6,
    # --- SimTuning: Steam ---
    "steamAltitudeRain": 5,
    "steamDeposition": 3,
    "steamTrappedSeep": 40,
    # --- SimTuning: Acid ---
    "acidLifetimeBase": 200,
    "acidLifetimeVar": 60,
    "acidWaterDilute": 8,
    "acidIceMelt": 8,
    # --- SimTuning: Stone ---
    "stoneThinSupport": 60,
    "stoneWeatherWater": 60,
    "stoneWeatherCrumble": 20,
    "stoneFrostWeather": 20,
    # --- SimTuning: Glass ---
    "glassLavaMeltBase": 80,
    "glassThermalShatter": 3,
    # --- SimTuning: Fungus ---
    "fungusWoodRot": 80,
    "fungusDirtSpread": 40,
    "fungusSporulate": 200,
    "fungusMethane": 300,
    # --- SimTuning: Compost ---
    "compostDryToDirt": 100,
    "compostMethane": 400,
    # --- SimTuning: Salt ---
    "saltDissolveRate": 5,
    "saltDeiceRate": 15,
    "saltPlantKill": 30,
    # --- SimTuning: Algae ---
    "algaeGrowRate": 10,
    "algaeO2Rate": 40,
    "algaeBloomDieoff": 50,
    "algaeBloomThreshold": 12,
    # --- SimTuning: Throttles ---
    "throttleWaterPressure": 3,
    "throttleFireSpread": 6,
    "throttlePlantGrow": 6,
    "throttlePlantPhotosynthesis": 15,
    "throttlePlantSeed": 30,
    "throttleLavaCool": 10,
    "throttleFungusGrow": 20,
    "throttleAlgaeGrow": 30,
    # --- SimTuning: Thresholds ---
    "thresholdPressureHigh": 6,
    "thresholdPressureErupt": 16,
    "thresholdPlantWilt": 30,
    "thresholdPlantMature": 8,
    "thresholdTempHot": 200,
    "thresholdTempWarm": 150,
    "thresholdMoistureWet": 50,
    "thresholdStressFailure": 2,
    "thresholdVibrationBreak": 200,
    # --- SimTuning: Distances ---
    "distVibrationSpread": 1,
    # --- SimTuning: Creature rates ---
    "spiderWebRate": 8,
    "beePollinateRate": 12,
    "wormAerateRate": 15,
    "fishEatRate": 8,
    # --- SimTuning: Colony ---
    "queenEggRate": 100,
    "queenFoodPerEgg": 3,
    "eggHatchTicks": 200,
    "larvaGrowTicks": 400,
}


# ---------------------------------------------------------------------------
# Search space definition
# ---------------------------------------------------------------------------
def suggest_params(trial) -> dict[str, Any]:
    """Define the Optuna parameter search space.

    Covers element properties, SimTuning rates/throttles/thresholds,
    periodic table elements, creature rates, and colony dynamics.
    """
    params: dict[str, Any] = {}

    # ===== Element densities (buoyancy, sinking, displacement) =====
    params["sand_density"] = trial.suggest_int("sand_density", 120, 180)
    params["water_density"] = trial.suggest_int("water_density", 80, 120)
    params["oil_density"] = trial.suggest_int("oil_density", 60, 95)
    params["stone_density"] = trial.suggest_int("stone_density", 230, 255)
    params["metal_density"] = trial.suggest_int("metal_density", 235, 255)
    params["ice_density"] = trial.suggest_int("ice_density", 80, 100)
    params["wood_density"] = trial.suggest_int("wood_density", 60, 100)
    params["dirt_density"] = trial.suggest_int("dirt_density", 130, 160)
    params["lava_density"] = trial.suggest_int("lava_density", 180, 220)

    # ===== Gravity =====
    params["sand_gravity"] = trial.suggest_int("sand_gravity", 1, 3)
    params["water_gravity"] = trial.suggest_int("water_gravity", 1, 2)

    # ===== Temperature thresholds =====
    params["water_boil_point"] = trial.suggest_int("water_boil_point", 160, 200)
    params["water_freeze_point"] = trial.suggest_int("water_freeze_point", 20, 50)
    params["sand_melt_point"] = trial.suggest_int("sand_melt_point", 200, 250)
    params["ice_melt_point"] = trial.suggest_int("ice_melt_point", 30, 60)

    # ===== Viscosity =====
    params["oil_viscosity"] = trial.suggest_int("oil_viscosity", 1, 4)
    params["mud_viscosity"] = trial.suggest_int("mud_viscosity", 2, 5)
    params["lava_viscosity"] = trial.suggest_int("lava_viscosity", 3, 6)

    # ===== Legacy behavioral =====
    params["evaporation_rate"] = trial.suggest_int("evaporation_rate", 500, 3000)
    params["fire_spread_prob"] = trial.suggest_float(
        "fire_spread_prob", 0.05, 0.40, step=0.05
    )
    params["erosion_rate"] = trial.suggest_int("erosion_rate", 50, 500)

    # ===== SimTuning: Sand =====
    params["sandToMudRate"] = trial.suggest_int("sandToMudRate", 5, 20)
    params["sandToMudSubmergedRate"] = trial.suggest_int("sandToMudSubmergedRate", 40, 160)

    # ===== SimTuning: Water =====
    params["waterPressurePush"] = trial.suggest_int("waterPressurePush", 4, 16)
    params["waterDirtErosion"] = trial.suggest_int("waterDirtErosion", 10, 40)
    params["waterSandErosion"] = trial.suggest_int("waterSandErosion", 15, 60)
    params["waterSedimentDeposit"] = trial.suggest_int("waterSedimentDeposit", 20, 80)
    params["waterSeepageRate"] = trial.suggest_int("waterSeepageRate", 6, 24)
    params["waterHydraulicRate"] = trial.suggest_int("waterHydraulicRate", 1, 8)
    params["waterBubbleRate"] = trial.suggest_int("waterBubbleRate", 200, 1000)
    params["waterMomentumReset"] = trial.suggest_int("waterMomentumReset", 2, 8)

    # ===== SimTuning: Fire =====
    params["fireOxygenConsume"] = trial.suggest_int("fireOxygenConsume", 1, 8)
    params["fireLifetimeBase"] = trial.suggest_int("fireLifetimeBase", 20, 80)
    params["fireLifetimeVar"] = trial.suggest_int("fireLifetimeVar", 20, 80)
    params["firePlantIgnite"] = trial.suggest_int("firePlantIgnite", 1, 5)
    params["fireOilChainIgnite"] = trial.suggest_int("fireOilChainIgnite", 1, 6)
    params["fireWoodPyrolysis"] = trial.suggest_int("fireWoodPyrolysis", 1, 6)
    params["fireLateralShimmy"] = trial.suggest_int("fireLateralShimmy", 2, 10)

    # ===== SimTuning: Ice =====
    params["iceRegelation"] = trial.suggest_int("iceRegelation", 2, 8)
    params["iceAmbientMeltDay"] = trial.suggest_int("iceAmbientMeltDay", 10, 40)
    params["iceAmbientMeltNight"] = trial.suggest_int("iceAmbientMeltNight", 30, 120)

    # ===== SimTuning: Dirt =====
    params["dirtWaterErosionBase"] = trial.suggest_int("dirtWaterErosionBase", 5, 20)
    params["dirtFlowingErosion"] = trial.suggest_int("dirtFlowingErosion", 4, 16)
    params["dirtAshAbsorb"] = trial.suggest_int("dirtAshAbsorb", 5, 20)

    # ===== SimTuning: Plant =====
    params["plantAcidDamage"] = trial.suggest_int("plantAcidDamage", 1, 8)
    params["plantDecomposeRate"] = trial.suggest_int("plantDecomposeRate", 5, 20)
    params["plantO2Produce"] = trial.suggest_int("plantO2Produce", 4, 16)
    params["plantSeedRateYoung"] = trial.suggest_int("plantSeedRateYoung", 250, 1000)
    params["plantSeedRateOld"] = trial.suggest_int("plantSeedRateOld", 100, 400)
    params["plantGrassSpread"] = trial.suggest_int("plantGrassSpread", 20, 80)
    params["plantTreeRootGrow"] = trial.suggest_int("plantTreeRootGrow", 25, 100)

    # ===== SimTuning: Lava =====
    params["lavaCoolingBase"] = trial.suggest_int("lavaCoolingBase", 100, 400)
    params["lavaCoolingVar"] = trial.suggest_int("lavaCoolingVar", 25, 100)
    params["lavaSmokeEmit"] = trial.suggest_int("lavaSmokeEmit", 40, 160)
    params["lavaSteamEmit"] = trial.suggest_int("lavaSteamEmit", 60, 240)
    params["lavaEruptionOpen"] = trial.suggest_int("lavaEruptionOpen", 30, 120)
    params["lavaEruptionPressured"] = trial.suggest_int("lavaEruptionPressured", 15, 60)
    params["lavaIgniteFlammable"] = trial.suggest_int("lavaIgniteFlammable", 1, 5)
    params["lavaSandToGlass"] = trial.suggest_int("lavaSandToGlass", 20, 80)
    params["lavaMeltMetal"] = trial.suggest_int("lavaMeltMetal", 40, 160)

    # ===== SimTuning: Snow =====
    params["snowMeltRateDay"] = trial.suggest_int("snowMeltRateDay", 10, 40)
    params["snowMeltRateNight"] = trial.suggest_int("snowMeltRateNight", 20, 80)
    params["snowFreezeWater"] = trial.suggest_int("snowFreezeWater", 15, 60)
    params["snowAvalanche"] = trial.suggest_int("snowAvalanche", 2, 6)

    # ===== SimTuning: Wood =====
    params["woodFireSpread"] = trial.suggest_int("woodFireSpread", 6, 24)
    params["woodBurnoutBase"] = trial.suggest_int("woodBurnoutBase", 20, 80)
    params["woodCharcoalChance"] = trial.suggest_int("woodCharcoalChance", 2, 10)
    params["woodAnoxicPyrolysis"] = trial.suggest_int("woodAnoxicPyrolysis", 30, 120)
    params["woodWaterAbsorb"] = trial.suggest_int("woodWaterAbsorb", 15, 60)

    # ===== SimTuning: Metal =====
    params["metalRustRate"] = trial.suggest_int("metalRustRate", 250, 1000)
    params["metalSaltRustRate"] = trial.suggest_int("metalSaltRustRate", 50, 200)
    params["metalHotIgniteRate"] = trial.suggest_int("metalHotIgniteRate", 3, 12)

    # ===== SimTuning: Steam =====
    params["steamAltitudeRain"] = trial.suggest_int("steamAltitudeRain", 2, 10)
    params["steamDeposition"] = trial.suggest_int("steamDeposition", 1, 6)
    params["steamTrappedSeep"] = trial.suggest_int("steamTrappedSeep", 20, 80)

    # ===== SimTuning: Acid =====
    params["acidLifetimeBase"] = trial.suggest_int("acidLifetimeBase", 100, 400)
    params["acidLifetimeVar"] = trial.suggest_int("acidLifetimeVar", 30, 120)
    params["acidWaterDilute"] = trial.suggest_int("acidWaterDilute", 4, 16)
    params["acidIceMelt"] = trial.suggest_int("acidIceMelt", 4, 16)

    # ===== SimTuning: Stone =====
    params["stoneThinSupport"] = trial.suggest_int("stoneThinSupport", 30, 120)
    params["stoneWeatherWater"] = trial.suggest_int("stoneWeatherWater", 30, 120)
    params["stoneWeatherCrumble"] = trial.suggest_int("stoneWeatherCrumble", 10, 40)
    params["stoneFrostWeather"] = trial.suggest_int("stoneFrostWeather", 10, 40)

    # ===== SimTuning: Glass =====
    params["glassLavaMeltBase"] = trial.suggest_int("glassLavaMeltBase", 40, 160)
    params["glassThermalShatter"] = trial.suggest_int("glassThermalShatter", 1, 6)

    # ===== SimTuning: Fungus =====
    params["fungusWoodRot"] = trial.suggest_int("fungusWoodRot", 40, 160)
    params["fungusDirtSpread"] = trial.suggest_int("fungusDirtSpread", 20, 80)
    params["fungusSporulate"] = trial.suggest_int("fungusSporulate", 100, 400)
    params["fungusMethane"] = trial.suggest_int("fungusMethane", 150, 600)

    # ===== SimTuning: Compost =====
    params["compostDryToDirt"] = trial.suggest_int("compostDryToDirt", 50, 200)
    params["compostMethane"] = trial.suggest_int("compostMethane", 200, 800)

    # ===== SimTuning: Salt =====
    params["saltDissolveRate"] = trial.suggest_int("saltDissolveRate", 2, 10)
    params["saltDeiceRate"] = trial.suggest_int("saltDeiceRate", 8, 30)
    params["saltPlantKill"] = trial.suggest_int("saltPlantKill", 15, 60)

    # ===== SimTuning: Algae =====
    params["algaeGrowRate"] = trial.suggest_int("algaeGrowRate", 5, 20)
    params["algaeO2Rate"] = trial.suggest_int("algaeO2Rate", 20, 80)
    params["algaeBloomDieoff"] = trial.suggest_int("algaeBloomDieoff", 25, 100)
    params["algaeBloomThreshold"] = trial.suggest_int("algaeBloomThreshold", 6, 24)

    # ===== SimTuning: Throttles (behavior update frequency) =====
    params["throttleWaterPressure"] = trial.suggest_int("throttleWaterPressure", 1, 6)
    params["throttleFireSpread"] = trial.suggest_int("throttleFireSpread", 3, 12)
    params["throttlePlantGrow"] = trial.suggest_int("throttlePlantGrow", 3, 12)
    params["throttlePlantPhotosynthesis"] = trial.suggest_int("throttlePlantPhotosynthesis", 8, 30)
    params["throttlePlantSeed"] = trial.suggest_int("throttlePlantSeed", 15, 60)
    params["throttleLavaCool"] = trial.suggest_int("throttleLavaCool", 5, 20)
    params["throttleFungusGrow"] = trial.suggest_int("throttleFungusGrow", 10, 40)
    params["throttleAlgaeGrow"] = trial.suggest_int("throttleAlgaeGrow", 15, 60)

    # ===== SimTuning: Thresholds (trigger points) =====
    params["thresholdPressureHigh"] = trial.suggest_int("thresholdPressureHigh", 3, 12)
    params["thresholdPressureErupt"] = trial.suggest_int("thresholdPressureErupt", 8, 32)
    params["thresholdPlantWilt"] = trial.suggest_int("thresholdPlantWilt", 15, 60)
    params["thresholdPlantMature"] = trial.suggest_int("thresholdPlantMature", 4, 16)
    params["thresholdTempHot"] = trial.suggest_int("thresholdTempHot", 160, 240)
    params["thresholdTempWarm"] = trial.suggest_int("thresholdTempWarm", 120, 180)
    params["thresholdMoistureWet"] = trial.suggest_int("thresholdMoistureWet", 25, 100)
    params["thresholdStressFailure"] = trial.suggest_int("thresholdStressFailure", 1, 4)
    params["thresholdVibrationBreak"] = trial.suggest_int("thresholdVibrationBreak", 100, 400)

    # ===== SimTuning: Distances =====
    params["distVibrationSpread"] = trial.suggest_int("distVibrationSpread", 1, 3)

    # ===== SimTuning: Creature species rates =====
    params["spiderWebRate"] = trial.suggest_int("spiderWebRate", 4, 16)
    params["beePollinateRate"] = trial.suggest_int("beePollinateRate", 6, 24)
    params["wormAerateRate"] = trial.suggest_int("wormAerateRate", 8, 30)
    params["fishEatRate"] = trial.suggest_int("fishEatRate", 4, 16)

    # ===== SimTuning: Colony dynamics =====
    params["queenEggRate"] = trial.suggest_int("queenEggRate", 50, 200)
    params["queenFoodPerEgg"] = trial.suggest_int("queenFoodPerEgg", 1, 6)
    params["eggHatchTicks"] = trial.suggest_int("eggHatchTicks", 100, 400)
    params["larvaGrowTicks"] = trial.suggest_int("larvaGrowTicks", 200, 800)

    # ===== Periodic Table: Key element properties =====

    # Alkali metal reactivity
    params["sodium_reactivity"] = trial.suggest_int("sodium_reactivity", 160, 255)
    params["potassium_reactivity"] = trial.suggest_int("potassium_reactivity", 180, 255)

    # Mercury properties
    params["mercury_density"] = trial.suggest_int("mercury_density", 190, 240)
    params["mercury_viscosity"] = trial.suggest_int("mercury_viscosity", 1, 4)

    # Gold properties
    params["gold_density"] = trial.suggest_int("gold_density", 220, 255)
    params["gold_melt_point"] = trial.suggest_int("gold_melt_point", 150, 200)

    # Halogen reactivity
    params["fluorine_reactivity"] = trial.suggest_int("fluorine_reactivity", 200, 255)
    params["chlorine_reactivity"] = trial.suggest_int("chlorine_reactivity", 160, 230)

    # Nuclear properties
    params["uranium_heat_rate"] = trial.suggest_int("uranium_heat_rate", 1, 5)
    params["plutonium_heat_rate"] = trial.suggest_int("plutonium_heat_rate", 2, 8)
    params["thorium_heat_rate"] = trial.suggest_int("thorium_heat_rate", 1, 4)

    # Phosphorus auto-ignition
    params["phosphorus_ignition_chance"] = trial.suggest_int(
        "phosphorus_ignition_chance", 20, 80
    )

    # World generation: ore richness
    params["ore_richness_mult"] = trial.suggest_float(
        "ore_richness_mult", 0.5, 2.0, step=0.1
    )

    return params


# ---------------------------------------------------------------------------
# Config writer
# ---------------------------------------------------------------------------
def write_trial_config(params: dict[str, Any]) -> Path:
    """Write trial parameters to JSON for the benchmark to consume."""
    return write_manifest_trial_config(TRIAL_CONFIG, params)


# ---------------------------------------------------------------------------
# Objective function
# ---------------------------------------------------------------------------
def objective(trial) -> tuple[float, float]:
    """Run benchmark and return (physics_score, visual_score)."""
    params = suggest_params(trial)
    write_trial_config(params)

    try:
        result = subprocess.run(
            [sys.executable, str(RESEARCH_DIR / "benchmark.py"), "--quick", "--json"],
            capture_output=True,
            text=True,
            timeout=300,
            cwd=str(PROJECT_DIR),
            env={**os.environ, "TRIAL_CONFIG": str(TRIAL_CONFIG)},
        )
    except subprocess.TimeoutExpired as exc:
        print(f"  Trial {trial.number}: TIMEOUT (300s)")
        trial.set_user_attr("error", "timeout")
        if exc.stderr:
            stderr_tail = exc.stderr.strip().splitlines()[-5:] if isinstance(exc.stderr, str) else []
            trial.set_user_attr("stderr_tail", "\n".join(stderr_tail))
        return float("nan"), float("nan")
    except Exception as e:
        print(f"  Trial {trial.number}: ERROR ({e})")
        trial.set_user_attr("error", str(e))
        return float("nan"), float("nan")

    # Parse JSON from stdout
    stdout = result.stdout.strip()
    if not stdout:
        print(f"  Trial {trial.number}: No output from benchmark")
        trial.set_user_attr("error", "no_output")
        if result.stderr:
            stderr_tail = result.stderr.strip().splitlines()[-3:]
            trial.set_user_attr("stderr_tail", "\n".join(stderr_tail))
        return 0.0, 0.0

    try:
        data = json.loads(stdout)
    except json.JSONDecodeError as e:
        print(f"  Trial {trial.number}: JSON parse error: {e}")
        # Try to find JSON in output (benchmark may print other text)
        for i, line in enumerate(stdout.splitlines()):
            if line.strip().startswith("{"):
                try:
                    data = json.loads("\n".join(stdout.splitlines()[i:]))
                    break
                except json.JSONDecodeError:
                    continue
        else:
            trial.set_user_attr("error", "json_parse")
            return 0.0, 0.0

    physics = data.get("domain_scores", {}).get("Physics", {}).get("score", 0.0)
    visuals = data.get("domain_scores", {}).get("Visuals", {}).get("score", 0.0)

    # Store extra info
    trial.set_user_attr("overall", data.get("overall_score", 0.0))
    trial.set_user_attr("passed", data.get("total_passed", 0))
    trial.set_user_attr("failed", data.get("total_failed", 0))
    trial.set_user_attr("duration", data.get("duration_seconds", 0))

    infra = data.get("domain_scores", {}).get("Infrastructure", {}).get("score", 0.0)
    trial.set_user_attr("infra", infra)

    # Log to MLflow (optional)
    try:
        from research.mlflow_setup import log_optuna_trial

        overall = data.get("overall_score", 0.0)
        log_optuna_trial(trial.number, params, physics, visuals, overall)
    except ImportError:
        pass
    except Exception:
        pass  # MLflow logging is best-effort

    return physics, visuals


# ---------------------------------------------------------------------------
# Study management
# ---------------------------------------------------------------------------
def create_or_load_study(study_name: str = "particle_engine", load_if_exists: bool = True):
    """Create a new study or load an existing one from SQLite."""
    import optuna

    storage_url = f"sqlite:///{STUDY_DB}"
    return optuna.create_study(
        study_name=study_name,
        storage=storage_url,
        directions=["maximize", "maximize"],
        load_if_exists=load_if_exists,
        sampler=optuna.samplers.TPESampler(seed=42, multivariate=True),
    )


def load_study(study_name: str = "particle_engine"):
    """Load an existing study."""
    import optuna

    storage_url = f"sqlite:///{STUDY_DB}"
    return optuna.load_study(study_name=study_name, storage=storage_url)


# ---------------------------------------------------------------------------
# Run optimization
# ---------------------------------------------------------------------------
def run_optimization(args: argparse.Namespace) -> None:
    """Run optimization trials."""
    import optuna

    optuna.logging.set_verbosity(optuna.logging.WARNING)

    study = create_or_load_study(
        study_name=args.study_name,
        load_if_exists=args.resume or True,
    )

    existing = len(study.trials)
    n_trials = args.n_trials

    print()
    print("=" * 60)
    print("  PARTICLE ENGINE PARAMETER OPTIMIZER")
    print("=" * 60)
    print()
    print(f"  Study:        {args.study_name}")
    print(f"  Storage:      {STUDY_DB.name}")
    print(f"  Existing:     {existing} trials")
    print(f"  New trials:   {n_trials}")
    print(f"  Timeout:      {args.timeout}s")
    print(f"  Objectives:   Physics (maximize), Visuals (maximize)")
    print(f"  Parameters:   {len(DEFAULTS)}")
    print()
    print("-" * 60)
    print()

    start = time.time()

    def trial_callback(study, trial):
        elapsed = time.time() - start
        n_done = trial.number - existing + 1
        phys = trial.values[0] if trial.values else 0
        vis = trial.values[1] if trial.values else 0
        overall = trial.user_attrs.get("overall", 0)
        err = trial.user_attrs.get("error", "")

        if err:
            status = f"ERROR: {err}"
        else:
            status = f"Physics={phys:.1f}%  Visual={vis:.1f}%  Overall={overall:.1f}%"

        print(f"  [{n_done}/{n_trials}] Trial #{trial.number}  {status}  ({elapsed:.0f}s)")

    study.optimize(
        objective,
        n_trials=n_trials,
        timeout=args.timeout,
        callbacks=[trial_callback],
        show_progress_bar=False,
    )

    total_elapsed = time.time() - start
    total_trials = len(study.trials)
    pareto = study.best_trials

    print()
    print("-" * 60)
    print()
    print(f"  Completed in {total_elapsed:.0f}s")
    print(f"  Total trials: {total_trials}")
    print(f"  Pareto-optimal: {len(pareto)}")

    if pareto:
        best = max(pareto, key=lambda t: sum(t.values))
        print()
        print(f"  Best combined trial: #{best.number}")
        print(f"    Physics: {best.values[0]:.1f}%")
        print(f"    Visual:  {best.values[1]:.1f}%")
        print(f"    Overall: {best.user_attrs.get('overall', 0):.1f}%")
        print()
        _print_param_diff(best.params)

    print()


# ---------------------------------------------------------------------------
# Show results
# ---------------------------------------------------------------------------
def show_results(args: argparse.Namespace) -> None:
    """Display optimization results."""
    study = load_study(args.study_name)
    trials = [t for t in study.trials if t.values is not None]

    if not trials:
        print("No completed trials found.")
        return

    pareto = study.best_trials

    print()
    print("=" * 60)
    print("  OPTIMIZATION RESULTS")
    print("=" * 60)
    print()
    print(f"  Study:          {args.study_name}")
    print(f"  Total trials:   {len(study.trials)}")
    print(f"  Completed:      {len(trials)}")
    print(f"  Pareto-optimal: {len(pareto)}")
    print()

    # Top trials by combined score
    sorted_trials = sorted(
        trials,
        key=lambda t: sum(t.values) if t.values else 0,
        reverse=True,
    )

    top_n = min(args.top, len(sorted_trials))
    print(f"  Top {top_n} trials (by combined score):")
    print()
    print(f"  {'#':>5s}  {'Physics':>8s}  {'Visual':>8s}  {'Combined':>10s}  {'Overall':>8s}  {'P/F':>6s}")
    print(f"  {'---':>5s}  {'-------':>8s}  {'------':>8s}  {'--------':>10s}  {'-------':>8s}  {'---':>6s}")

    for trial in sorted_trials[:top_n]:
        phys = trial.values[0]
        vis = trial.values[1]
        combined = phys + vis
        overall = trial.user_attrs.get("overall", 0)
        passed = trial.user_attrs.get("passed", "?")
        failed = trial.user_attrs.get("failed", "?")
        print(
            f"  {trial.number:5d}  {phys:7.1f}%  {vis:7.1f}%  {combined:9.1f}%  {overall:7.1f}%  {passed}/{failed}"
        )

    # Show best trial's params
    if sorted_trials:
        best = sorted_trials[0]
        print()
        print(f"  Best trial #{best.number} parameters vs defaults:")
        print()
        _print_param_diff(best.params)

    print()


# ---------------------------------------------------------------------------
# Visualization
# ---------------------------------------------------------------------------
def generate_all_visualizations(args: argparse.Namespace) -> None:
    """Generate interactive HTML plots from the study."""
    import optuna

    study = load_study(args.study_name)
    completed = [t for t in study.trials if t.values is not None]

    if len(completed) < 2:
        print(f"Need at least 2 completed trials for visualizations (have {len(completed)}).")
        return

    PLOTS_DIR.mkdir(exist_ok=True)

    from optuna.visualization import (
        plot_optimization_history,
        plot_parallel_coordinate,
        plot_param_importances,
        plot_pareto_front,
        plot_slice,
    )

    plots: list[tuple[str, str, Any]] = []

    # Pareto front: physics vs visuals tradeoff
    print("  Generating Pareto front...")
    try:
        fig = plot_pareto_front(study, target_names=["Physics %", "Visual %"])
        path = PLOTS_DIR / "pareto_front.html"
        fig.write_html(str(path))
        plots.append(("Pareto Front", str(path), fig))
    except Exception as e:
        print(f"    Skipped: {e}")

    # Parameter importance for physics
    print("  Generating parameter importance (physics)...")
    try:
        fig = plot_param_importances(study, target=lambda t: t.values[0])
        path = PLOTS_DIR / "param_importance_physics.html"
        fig.write_html(str(path))
        plots.append(("Param Importance (Physics)", str(path), fig))
    except Exception as e:
        print(f"    Skipped: {e}")

    # Parameter importance for visuals
    print("  Generating parameter importance (visuals)...")
    try:
        fig = plot_param_importances(study, target=lambda t: t.values[1])
        path = PLOTS_DIR / "param_importance_visuals.html"
        fig.write_html(str(path))
        plots.append(("Param Importance (Visuals)", str(path), fig))
    except Exception as e:
        print(f"    Skipped: {e}")

    # Optimization history (physics)
    print("  Generating optimization history...")
    try:
        fig = plot_optimization_history(study, target=lambda t: t.values[0])
        path = PLOTS_DIR / "history_physics.html"
        fig.write_html(str(path))
        plots.append(("History (Physics)", str(path), fig))
    except Exception as e:
        print(f"    Skipped: {e}")

    # Parallel coordinate plot
    print("  Generating parallel coordinates...")
    try:
        fig = plot_parallel_coordinate(study, target=lambda t: t.values[0])
        path = PLOTS_DIR / "parallel_coords.html"
        fig.write_html(str(path))
        plots.append(("Parallel Coordinates", str(path), fig))
    except Exception as e:
        print(f"    Skipped: {e}")

    # Slice plot
    print("  Generating slice plots...")
    try:
        fig = plot_slice(study, target=lambda t: t.values[0])
        path = PLOTS_DIR / "slice_physics.html"
        fig.write_html(str(path))
        plots.append(("Slice (Physics)", str(path), fig))
    except Exception as e:
        print(f"    Skipped: {e}")

    print()
    print(f"  Generated {len(plots)} visualizations in {PLOTS_DIR}/")
    for name, path, _ in plots:
        print(f"    {name}: {Path(path).name}")
    print()


# ---------------------------------------------------------------------------
# Apply best parameters
# ---------------------------------------------------------------------------
def apply_best_params(args: argparse.Namespace) -> None:
    """Write the best trial's parameters to trial_config.json."""
    study = load_study(args.study_name)
    completed = [t for t in study.trials if t.values is not None]

    if not completed:
        print("No completed trials found.")
        return

    if args.trial is not None:
        matching = [t for t in study.trials if t.number == args.trial]
        if not matching:
            print(f"Trial #{args.trial} not found.")
            return
        trial = matching[0]
    else:
        best = max(study.best_trials, key=lambda t: sum(t.values))
        trial = best

    print()
    print(f"  Applying trial #{trial.number}")
    print(f"    Physics: {trial.values[0]:.1f}%")
    print(f"    Visual:  {trial.values[1]:.1f}%")
    print(f"    Overall: {trial.user_attrs.get('overall', 0):.1f}%")
    print()

    _print_param_diff(trial.params)

    write_trial_config(trial.params)
    print()
    print(f"  Config written to {TRIAL_CONFIG.name}")
    print("  To apply to Dart code, update element_registry.dart with these values.")
    print()


# ---------------------------------------------------------------------------
# Test specific parameters
# ---------------------------------------------------------------------------
def test_params(args: argparse.Namespace) -> None:
    """Run benchmark with specific parameter overrides."""
    params = dict(DEFAULTS)

    if args.param:
        for key, value in args.param:
            if key not in DEFAULTS:
                print(f"  Warning: unknown parameter '{key}', using anyway")
            try:
                if "." in value:
                    params[key] = float(value)
                else:
                    params[key] = int(value)
            except ValueError:
                print(f"  Error: cannot parse value '{value}' for '{key}'")
                return

    print()
    print("  Testing parameters:")
    for key, value in sorted(params.items()):
        default = DEFAULTS.get(key)
        marker = " *" if default is not None and value != default else ""
        print(f"    {key}: {value}{marker}")
    print()

    write_trial_config(params)

    print("  Running benchmark (--quick --json)...")
    print()

    result = subprocess.run(
        [sys.executable, str(RESEARCH_DIR / "benchmark.py"), "--quick"],
        cwd=str(PROJECT_DIR),
        env={**os.environ, "TRIAL_CONFIG": str(TRIAL_CONFIG)},
    )

    print()
    if result.returncode == 0:
        print("  Benchmark completed successfully.")
    else:
        print(f"  Benchmark exited with code {result.returncode}.")
    print()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _print_param_diff(params: dict[str, Any]) -> None:
    """Print parameter values highlighting differences from defaults."""
    changed = []
    unchanged = []

    for key in sorted(DEFAULTS.keys()):
        default = DEFAULTS[key]
        current = params.get(key, default)

        if isinstance(default, float):
            diff = abs(current - default) > 0.001
        else:
            diff = current != default

        if diff:
            if isinstance(default, float):
                changed.append(f"    {key}: {default} -> {current:.3f}")
            else:
                changed.append(f"    {key}: {default} -> {current}")
        else:
            unchanged.append(key)

    if changed:
        print(f"  Changed ({len(changed)}):")
        for line in changed:
            print(line)
    else:
        print("  No changes from defaults.")

    if unchanged:
        print(f"  Unchanged ({len(unchanged)}): {', '.join(unchanged)}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Particle Engine Parameter Optimizer",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent("""\
            examples:
              %(prog)s run --n-trials 50          Run 50 optimization trials
              %(prog)s run --n-trials 25 --resume  Resume and add 25 more trials
              %(prog)s show --top 10               Show top 10 results
              %(prog)s viz                         Generate interactive HTML plots
              %(prog)s apply                       Apply best Pareto-front params
              %(prog)s apply --trial 42            Apply specific trial's params
              %(prog)s test --param sand_density 160 --param oil_viscosity 3
        """),
    )

    subparsers = parser.add_subparsers(dest="command")

    # -- run --
    run_parser = subparsers.add_parser("run", help="Run optimization trials")
    run_parser.add_argument(
        "--n-trials", type=int, default=50, help="Number of trials (default: 50)"
    )
    run_parser.add_argument(
        "--timeout", type=int, default=3600, help="Max total seconds (default: 3600)"
    )
    run_parser.add_argument(
        "--study-name", default="particle_engine", help="Study name (default: particle_engine)"
    )
    run_parser.add_argument(
        "--resume", action="store_true", help="Resume existing study"
    )

    # -- show --
    show_parser = subparsers.add_parser("show", help="Show optimization results")
    show_parser.add_argument(
        "--study-name", default="particle_engine", help="Study name"
    )
    show_parser.add_argument(
        "--top", type=int, default=10, help="Number of top results (default: 10)"
    )

    # -- viz --
    viz_parser = subparsers.add_parser("viz", help="Generate visualization plots")
    viz_parser.add_argument(
        "--study-name", default="particle_engine", help="Study name"
    )

    # -- apply --
    apply_parser = subparsers.add_parser("apply", help="Apply best parameters")
    apply_parser.add_argument(
        "--study-name", default="particle_engine", help="Study name"
    )
    apply_parser.add_argument(
        "--trial", type=int, default=None, help="Specific trial number to apply"
    )

    # -- test --
    test_parser = subparsers.add_parser("test", help="Test specific parameter values")
    test_parser.add_argument(
        "--param",
        nargs=2,
        action="append",
        metavar=("KEY", "VALUE"),
        help="Parameter key-value pair (repeatable)",
    )

    args = parser.parse_args()

    if args.command == "run":
        run_optimization(args)
    elif args.command == "show":
        show_results(args)
    elif args.command == "viz":
        generate_all_visualizations(args)
    elif args.command == "apply":
        apply_best_params(args)
    elif args.command == "test":
        test_params(args)
    else:
        parser.print_help()
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
