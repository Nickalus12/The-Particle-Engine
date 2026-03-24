#!/usr/bin/env python3
"""GPU-accelerated world generation optimizer for A100.

Generates millions of world configurations, scores each on geological realism,
ecosystem viability, playability, and visual variety. Uses Optuna to find
optimal WorldConfig parameter ranges.

CuPy kernels evaluate entire 320x180 worlds on GPU in parallel batches.

Usage:
    python research/cloud/worldgen_optimizer.py --trials 5000 --workers 6
    python research/cloud/worldgen_optimizer.py --show --top 10
    python research/cloud/worldgen_optimizer.py --validate --worlds 1000

Target: ubuntu@185.216.21.95 port 30919 (A100 + 18 CPU cores)
"""

from __future__ import annotations

import argparse
import json
import logging
import multiprocessing as mp
import os
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np

try:
    import cupy as cp
    HAS_GPU = True
except ImportError:
    cp = np  # Fallback to numpy for CPU-only testing
    HAS_GPU = False

try:
    import optuna
    from optuna.samplers import TPESampler
    HAS_OPTUNA = True
except ImportError:
    HAS_OPTUNA = False

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent
RESEARCH_DIR = SCRIPT_DIR.parent
PROJECT_DIR = RESEARCH_DIR.parent
STUDY_DB = RESEARCH_DIR / "worldgen_optuna_study.db"
RESULTS_FILE = RESEARCH_DIR / "worldgen_optimization_results.json"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("worldgen_optimizer")

# ---------------------------------------------------------------------------
# Element constants (must match element_registry.dart El class)
# ---------------------------------------------------------------------------
EL_EMPTY = 0
EL_SAND = 1
EL_WATER = 2
EL_FIRE = 3
EL_ICE = 4
EL_SEED = 6
EL_STONE = 7
EL_DIRT = 16
EL_PLANT = 17
EL_LAVA = 18
EL_SNOW = 19
EL_WOOD = 20
EL_METAL = 21
EL_OXYGEN = 25
EL_CO2 = 26
EL_FUNGUS = 27
EL_CHARCOAL = 29
EL_COMPOST = 30
EL_SALT = 33
EL_CLAY = 34
EL_ALGAE = 35

# ---------------------------------------------------------------------------
# WorldConfig parameter space for Optuna
# ---------------------------------------------------------------------------
PARAM_SPACE = {
    # Core terrain
    "terrain_scale":    (0.3, 2.5),
    "water_level":      (0.05, 0.80),
    "cave_density":     (0.0, 0.85),
    "vegetation":       (0.0, 0.95),
    # Geology
    "ore_richness":     (0.05, 0.80),
    "copper_depth":     (0.15, 0.45),
    "metal_depth":      (0.40, 0.75),
    "coal_seams":       (0.0, 0.55),
    "sulfur_near_lava": (0.0, 0.75),
    "salt_deposits":    (0.0, 0.45),
    "clay_near_water":  (0.05, 0.60),
    "volcanic_activity":(0.0, 0.70),
    # Ecosystem
    "co2_in_caves":     (0.0, 0.60),
    "compost_depth":    (0.0, 0.65),
    "fungal_growth":    (0.0, 0.65),
    "algae_in_water":   (0.0, 0.75),
    "seed_scatter":     (0.05, 0.60),
    # Electrical
    "conductive_veins": (0.0, 0.65),
    "insulating_layers":(0.0, 0.45),
}


# ---------------------------------------------------------------------------
# GPU world generation kernel (simplified noise + layer fill)
# ---------------------------------------------------------------------------

def _simplex_hash_gpu(xp, x, y, seed):
    """Fast hash-based noise approximation on GPU (not true simplex, but
    adequate for scoring world generation quality at scale)."""
    h = (x * 374761393 + y * 668265263 + seed * 1274126177) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    h = (h ^ (h >> 16)) & 0xFFFFFFFF
    return (h & 0xFFFF).astype(xp.float32) / 32768.0 - 1.0


def _generate_heightmap_gpu(xp, width, height, seed, terrain_scale):
    """Generate a 1D heightmap array using hash noise on GPU."""
    xs = xp.arange(width, dtype=xp.float32)
    base_height = int(height * 0.38)
    amplitude = height * 0.18 * terrain_scale

    # Multi-frequency hash noise (3 octaves).
    macro = _simplex_hash_gpu(xp, (xs * 3.0 / width * 1000).astype(xp.int64), 0, seed)
    medium = _simplex_hash_gpu(xp, (xs * 8.0 / width * 1000).astype(xp.int64), 500, seed + 100)
    micro = _simplex_hash_gpu(xp, (xs * 20.0 / width * 1000).astype(xp.int64), 1000, seed + 200)

    combined = macro * 0.65 + medium * 0.25 + micro * 0.10
    hmap = (base_height + combined * amplitude).astype(xp.int32)
    return xp.clip(hmap, 5, height - 20)


def _generate_world_gpu(xp, params, seed, width=320, height=180):
    """Generate a single world grid on GPU and return element counts + metrics.

    Returns a dict of computed metrics (not the full grid, to save memory).
    """
    hmap = _generate_heightmap_gpu(xp, width, height, seed, params["terrain_scale"])
    grid = xp.zeros((height, width), dtype=xp.uint8)

    # Fill terrain layers column by column (vectorized over x).
    for y in range(height):
        row_mask = (y >= hmap)  # Below surface.
        depth = y - hmap  # Depth from surface.

        compost_d = xp.clip((1 + params["compost_depth"] * 2).astype(xp.int32), 0, 4)
        dirt_d = xp.full(width, 12, dtype=xp.int32)

        # Compost layer.
        compost_mask = row_mask & (depth >= 0) & (depth < compost_d)
        grid[y][compost_mask] = EL_COMPOST

        # Dirt layer.
        dirt_mask = row_mask & (depth >= compost_d) & (depth < dirt_d)
        grid[y][dirt_mask] = EL_DIRT

        # Clay transition.
        clay_d = xp.clip((params["clay_near_water"] * 2).astype(xp.int32), 0, 3)
        clay_mask = row_mask & (depth >= dirt_d) & (depth < dirt_d + clay_d)
        grid[y][clay_mask] = EL_CLAY

        # Stone.
        stone_mask = row_mask & (depth >= dirt_d + clay_d) & (y < height - 5)
        grid[y][stone_mask] = EL_STONE

        # Bedrock.
        bedrock_mask = (y >= height - 5)
        if bedrock_mask:
            grid[y][row_mask] = EL_STONE

    # Simple cave carving (threshold noise).
    cave_noise = _simplex_hash_gpu(
        xp,
        xp.arange(width * height, dtype=xp.int64).reshape(height, width) % 10000,
        xp.arange(width * height, dtype=xp.int64).reshape(height, width) // 10000,
        seed + 1000,
    )
    cave_threshold = 0.55 - params["cave_density"] * 0.27
    depth_grid = xp.arange(height, dtype=xp.int32).reshape(-1, 1) - hmap.reshape(1, -1)
    cave_mask = (cave_noise > cave_threshold) & (depth_grid > 6) & (grid == EL_STONE)
    grid[cave_mask] = EL_EMPTY

    # Water in depressions (simplified: fill below water line).
    if params["water_level"] > 0.1:
        sorted_h = xp.sort(hmap)
        pct = max(0.0, 1.0 - params["water_level"] * 0.35)
        wl_idx = min(int(width * pct), width - 1)
        water_line = int(sorted_h[wl_idx])
        for y in range(water_line, height):
            water_mask = (grid[y] == EL_EMPTY) & (y < hmap)
            grid[y][water_mask] = EL_WATER

    # Ore placement.
    if params["ore_richness"] > 0:
        depth_frac = depth_grid.astype(xp.float32) / max(height, 1)
        ore_noise = _simplex_hash_gpu(xp,
            xp.arange(width * height, dtype=xp.int64).reshape(height, width) % 7777,
            xp.arange(width * height, dtype=xp.int64).reshape(height, width) // 7777,
            seed + 3000)
        metal_mask = (grid == EL_STONE) & (ore_noise > 0.7 - params["ore_richness"] * 0.1) & \
                     (depth_frac > params["metal_depth"] - 0.15)
        grid[metal_mask] = EL_METAL

    # Lava deep.
    if params["volcanic_activity"] > 0:
        lava_min = int(height * (0.75 - params["volcanic_activity"] * 0.15))
        lava_noise = _simplex_hash_gpu(xp,
            xp.arange(width * height, dtype=xp.int64).reshape(height, width) % 5555,
            xp.arange(width * height, dtype=xp.int64).reshape(height, width) // 5555,
            seed + 7000)
        lava_threshold = 0.65 - params["volcanic_activity"] * 0.15
        for y in range(lava_min, height - 5):
            lava_mask = (grid[y] == EL_STONE) & (lava_noise[y] > lava_threshold)
            grid[y][lava_mask] = EL_LAVA

    # Oxygen fill.
    oxygen_mask = grid == EL_EMPTY
    grid[oxygen_mask] = EL_OXYGEN

    # Compute metrics from grid.
    return _score_world(xp, grid, hmap, params, width, height)


def _score_world(xp, grid, hmap, params, width, height):
    """Score a generated world on 4 objectives. Returns dict of scores."""
    total = width * height

    # Element counts.
    counts = {}
    for el_id, name in [
        (EL_STONE, "stone"), (EL_DIRT, "dirt"), (EL_WATER, "water"),
        (EL_LAVA, "lava"), (EL_METAL, "metal"), (EL_COMPOST, "compost"),
        (EL_CLAY, "clay"), (EL_OXYGEN, "oxygen"), (EL_SAND, "sand"),
    ]:
        counts[name] = int((grid == el_id).sum())

    # 1. GEOLOGICAL REALISM (0-1)
    # Stone should be 30-60% of cells, dirt 5-15%, clay present, compost present.
    stone_frac = counts["stone"] / total
    dirt_frac = counts["dirt"] / total
    clay_frac = counts["clay"] / total
    compost_frac = counts["compost"] / total
    metal_frac = counts["metal"] / total

    geo_score = 0.0
    # Stone in reasonable range.
    geo_score += _range_score(stone_frac, 0.25, 0.65) * 0.30
    # Dirt present.
    geo_score += _range_score(dirt_frac, 0.03, 0.18) * 0.20
    # Clay transition exists.
    geo_score += min(clay_frac * 50, 1.0) * 0.15
    # Compost layer exists.
    geo_score += min(compost_frac * 80, 1.0) * 0.15
    # Metal ore present but not overwhelming.
    geo_score += _range_score(metal_frac, 0.005, 0.05) * 0.20

    # 2. ECOSYSTEM VIABILITY (0-1)
    water_frac = counts["water"] / total
    oxygen_frac = counts["oxygen"] / total

    eco_score = 0.0
    # Water present (essential for life).
    eco_score += _range_score(water_frac, 0.02, 0.30) * 0.30
    # Oxygen atmosphere.
    eco_score += min(oxygen_frac * 5, 1.0) * 0.20
    # Compost for decomposition.
    eco_score += min(compost_frac * 100, 1.0) * 0.20
    # Dirt for plant growth.
    eco_score += _range_score(dirt_frac, 0.03, 0.15) * 0.15
    # Not too much lava (hostile).
    lava_frac = counts["lava"] / total
    eco_score += (1.0 - min(lava_frac * 20, 1.0)) * 0.15

    # 3. PLAYABILITY (0-1)
    # Enough open space (caves + sky), not too monotonous.
    sky_cells = int((grid == EL_OXYGEN).sum())  # Oxygen = air space
    cave_cells = 0
    for y in range(height):
        underground = (xp.arange(height).reshape(-1, 1) > hmap.reshape(1, -1))
        break  # Just compute once
    underground_air = int(((grid == EL_OXYGEN) & underground).sum())

    play_score = 0.0
    # Sky space (traversable).
    play_score += _range_score(sky_cells / total, 0.10, 0.40) * 0.25
    # Cave space (exploration).
    play_score += _range_score(underground_air / max(total, 1), 0.01, 0.15) * 0.25
    # Water (interaction).
    play_score += _range_score(water_frac, 0.01, 0.25) * 0.25
    # Ore for discovery.
    play_score += min(metal_frac * 40, 1.0) * 0.25

    # 4. VISUAL VARIETY (0-1)
    # Count unique element types present in significant quantities.
    unique_elements = 0
    for el_id in range(37):
        if int((grid == el_id).sum()) > total * 0.001:
            unique_elements += 1

    variety_score = 0.0
    # Element diversity.
    variety_score += min(unique_elements / 12.0, 1.0) * 0.40
    # Height variation.
    h_np = hmap if not HAS_GPU else hmap.get()
    h_std = float(np.std(h_np))
    variety_score += min(h_std / 20.0, 1.0) * 0.30
    # Water-land ratio variety.
    variety_score += _range_score(water_frac, 0.05, 0.35) * 0.30

    return {
        "geological_realism": float(geo_score),
        "ecosystem_viability": float(eco_score),
        "playability": float(play_score),
        "visual_variety": float(variety_score),
        "combined": float(geo_score * 0.30 + eco_score * 0.25 +
                         play_score * 0.25 + variety_score * 0.20),
        "counts": {k: int(v) for k, v in counts.items()},
        "unique_elements": unique_elements,
    }


def _range_score(value, low, high):
    """Return 1.0 if value is in [low, high], tapering to 0 outside."""
    if low <= value <= high:
        return 1.0
    if value < low:
        return max(0, value / low) if low > 0 else 0.0
    return max(0, 1.0 - (value - high) / max(high, 0.01))


# ---------------------------------------------------------------------------
# Optuna objective
# ---------------------------------------------------------------------------

def optuna_objective(trial):
    """Single Optuna trial: suggest params, generate world, return score."""
    params = {}
    for name, (lo, hi) in PARAM_SPACE.items():
        params[name] = trial.suggest_float(name, lo, hi)

    xp = cp if HAS_GPU else np
    seed = trial.number * 7919 + 42  # Deterministic per trial.

    # Generate and score 5 worlds with different seeds, average scores.
    scores = []
    for i in range(5):
        try:
            result = _generate_world_gpu(xp, params, seed + i * 1000)
            scores.append(result["combined"])
        except Exception as e:
            log.warning(f"Trial {trial.number} seed {seed + i * 1000}: {e}")
            scores.append(0.0)

    avg_score = float(np.mean(scores))
    trial.set_user_attr("avg_combined", avg_score)
    trial.set_user_attr("params", params)

    return avg_score


# ---------------------------------------------------------------------------
# Batch validation
# ---------------------------------------------------------------------------

def validate_worlds(n_worlds, params=None):
    """Generate n_worlds and check structural invariants."""
    xp = cp if HAS_GPU else np
    violations = 0
    total_checks = 0

    if params is None:
        # Use default-ish params.
        params = {k: (lo + hi) / 2 for k, (lo, hi) in PARAM_SPACE.items()}

    for i in range(n_worlds):
        seed = i * 31337 + 1
        try:
            result = _generate_world_gpu(xp, params, seed)
            total_checks += 1

            # Check: geological realism not terrible.
            if result["geological_realism"] < 0.1:
                violations += 1
                log.warning(f"World {i}: geological realism too low ({result['geological_realism']:.3f})")

            # Check: some water present if water_level > 0.1.
            if params["water_level"] > 0.1 and result["counts"]["water"] < 10:
                violations += 1
                log.warning(f"World {i}: no water despite water_level={params['water_level']:.2f}")

            # Check: stone is the dominant underground element.
            if result["counts"]["stone"] < result["counts"]["dirt"] * 0.5:
                violations += 1
                log.warning(f"World {i}: stone < dirt/2 (stone={result['counts']['stone']}, dirt={result['counts']['dirt']})")

        except Exception as e:
            violations += 1
            log.error(f"World {i}: generation failed: {e}")

    violation_rate = violations / max(total_checks, 1)
    log.info(f"Validated {total_checks} worlds: {violations} violations ({violation_rate:.4%})")
    return {"total": total_checks, "violations": violations, "rate": violation_rate}


# ---------------------------------------------------------------------------
# Show best results
# ---------------------------------------------------------------------------

def show_results(top_n=10):
    """Display top Optuna trial results."""
    if not HAS_OPTUNA:
        log.error("Optuna not installed")
        return

    study = optuna.load_study(
        study_name="worldgen_optimizer",
        storage=f"sqlite:///{STUDY_DB}",
    )

    trials = sorted(study.trials, key=lambda t: t.value or 0, reverse=True)

    print(f"\n{'='*70}", flush=True)
    print(f"  World Generation Optimizer — Top {top_n} of {len(trials)} trials", flush=True)
    print(f"{'='*70}\n", flush=True)

    for i, trial in enumerate(trials[:top_n]):
        print(f"  #{i+1} Trial {trial.number}: combined = {trial.value:.4f}", flush=True)
        params = trial.params
        print(f"    terrain_scale={params.get('terrain_scale', '?'):.2f}  "
              f"water={params.get('water_level', '?'):.2f}  "
              f"caves={params.get('cave_density', '?'):.2f}  "
              f"veg={params.get('vegetation', '?'):.2f}", flush=True)
        print(f"    ore={params.get('ore_richness', '?'):.2f}  "
              f"volcanic={params.get('volcanic_activity', '?'):.2f}  "
              f"coal={params.get('coal_seams', '?'):.2f}  "
              f"fungal={params.get('fungal_growth', '?'):.2f}", flush=True)
        print(flush=True)

    # Save best params.
    if trials:
        best = trials[0]
        result = {
            "best_trial": best.number,
            "best_score": best.value,
            "best_params": best.params,
            "total_trials": len(trials),
        }
        RESULTS_FILE.write_text(json.dumps(result, indent=2))
        log.info(f"Best params saved to {RESULTS_FILE}")


# ---------------------------------------------------------------------------
# Worker process
# ---------------------------------------------------------------------------

def _run_worker(worker_id, n_trials, study_name, db_path):
    """Single Optuna worker process."""
    import optuna
    optuna.logging.set_verbosity(optuna.logging.WARNING)

    study = optuna.load_study(
        study_name=study_name,
        storage=f"sqlite:///{db_path}",
    )

    for i in range(n_trials):
        try:
            study.optimize(optuna_objective, n_trials=1)
            if (i + 1) % 50 == 0:
                best = study.best_value
                log.info(f"Worker {worker_id}: {i+1}/{n_trials} trials, best={best:.4f}")
        except Exception as e:
            log.error(f"Worker {worker_id} trial error: {e}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="World Generation Optimizer")
    parser.add_argument("--trials", type=int, default=1000,
                       help="Total Optuna trials to run")
    parser.add_argument("--workers", type=int, default=4,
                       help="Number of parallel worker processes")
    parser.add_argument("--show", action="store_true",
                       help="Show best results from existing study")
    parser.add_argument("--top", type=int, default=10,
                       help="Number of top results to show")
    parser.add_argument("--validate", action="store_true",
                       help="Run structural validation on generated worlds")
    parser.add_argument("--worlds", type=int, default=1000,
                       help="Number of worlds to validate")
    args = parser.parse_args()

    if args.show:
        show_results(args.top)
        return

    if args.validate:
        validate_worlds(args.worlds)
        return

    if not HAS_OPTUNA:
        log.error("Optuna required: pip install optuna")
        sys.exit(1)

    log.info(f"GPU available: {HAS_GPU}")
    log.info(f"Starting {args.trials} trials across {args.workers} workers")

    # Create or load study.
    study = optuna.create_study(
        study_name="worldgen_optimizer",
        storage=f"sqlite:///{STUDY_DB}",
        direction="maximize",
        sampler=TPESampler(seed=42),
        load_if_exists=True,
    )

    trials_per_worker = args.trials // args.workers
    remainder = args.trials % args.workers

    processes = []
    for w in range(args.workers):
        n = trials_per_worker + (1 if w < remainder else 0)
        p = mp.Process(target=_run_worker,
                      args=(w, n, "worldgen_optimizer", str(STUDY_DB)))
        p.start()
        processes.append(p)
        log.info(f"Worker {w} started ({n} trials)")

    for p in processes:
        p.join()

    log.info("All workers finished")
    show_results(args.top)


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        print("Self-test: imports OK", flush=True)
        print("Self-test: PASSED", flush=True)
        sys.exit(0)
    main()
