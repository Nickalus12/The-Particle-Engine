#!/usr/bin/env python3
"""QDax-powered creature training for The Particle Engine.

Uses MAP-Elites quality-diversity optimization on GPU via JAX to evolve
DIVERSE creature brains. Instead of converging to one optimal strategy,
QDax fills a behavioral archive with the BEST genome for each behavior profile.

Result: hundreds of distinct creature strategies, guaranteed diverse.

IMPROVEMENTS over v1:
  - JAX-native evaluation: entire grid simulation runs on GPU via jax.vmap
  - 4D behavioral descriptors: env_modification, social_interaction, temporal_strategy, resource_management
  - Curriculum learning: progressive environment complexity across generations
  - Archive visualization: HTML heatmap of behavioral archive

Usage:
    python qdax_creature_trainer.py --species worm --iterations 500
    python qdax_creature_trainer.py --species all --iterations 300
    python qdax_creature_trainer.py --species beetle --grid 20 20
    python qdax_creature_trainer.py --species ant --curriculum  # enable curriculum learning

Output:
    trained_genomes/{species}_qdax_archive.json  (full behavioral archive)
    trained_genomes/{species}_qdax_best.json     (single champion)
    trained_genomes/{species}_qdax_diverse20.json (top 20 diverse genomes)
    trained_genomes/{species}_qdax_archive_viz.html (behavioral archive visualization)

Requires: pip install qdax jax[cuda12]
Fallback: pip install ribs numpy (CPU pyribs fallback)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any

# Prevent JAX XLA Autotuner from OOMing on A100 instances during massive vmap/scan compilations
os.environ["XLA_PYTHON_CLIENT_PREALLOCATE"] = "false"
os.environ["XLA_FLAGS"] = "--xla_gpu_autotune_level=0"

import numpy as np

# ---------------------------------------------------------------------------
# Try QDax (GPU JAX) first, fall back to pyribs (CPU)
# ---------------------------------------------------------------------------
HAS_QDAX = False
HAS_PYRIBS = False

try:
    import jax
    import jax.numpy as jnp
    from jax import random as jrandom
    from functools import partial
    HAS_JAX = True
    print(f"JAX backend: {jax.default_backend()}", flush=True)
    try:
        from qdax.core.map_elites import MAPElites
        from qdax.core.containers.mapelites_repertoire import (
            compute_euclidean_centroids,
            MapElitesRepertoire,
        )
        from qdax.core.emitters.mutation_operators import isoline_variation
        from qdax.core.emitters.standard_emitters import MixingEmitter
        from qdax.utils.metrics import default_qd_metrics
        HAS_QDAX = True
        print("QDax loaded successfully", flush=True)
    except ImportError as e:
        print(f"QDax not available: {e}", flush=True)
except ImportError:
    HAS_JAX = False
    print("JAX not available", flush=True)

if not HAS_QDAX:
    try:
        from ribs.archives import GridArchive
        from ribs.emitters import EvolutionStrategyEmitter
        from ribs.schedulers import Scheduler
        HAS_PYRIBS = True
        print("pyribs loaded (CPU fallback)", flush=True)
    except ImportError:
        print("Neither QDax nor pyribs available", flush=True)

# ---------------------------------------------------------------------------
# Species configurations — now with 4D behavior descriptors
# ---------------------------------------------------------------------------
SPECIES = {
    "worm": {
        "description": "Composting, dirt aeration, underground navigation",
        "n_inputs": 10, "n_outputs": 4,
        "behavior_dims": 4,
        "behavior_labels": ["env_modification", "social_interaction", "temporal_strategy", "resource_management"],
        "behavior_bounds": [(0.0, 1.0), (0.0, 1.0), (0.0, 1.0), (0.0, 1.0)],
        "grid_shape": (8, 8, 8, 8),  # 4096 behavioral niches
        "pop_size": 1024,
        "max_steps": 400,
    },
    "ant": {
        "description": "Food foraging, colony support, pheromone navigation",
        "n_inputs": 9, "n_outputs": 6,
        "behavior_dims": 4,
        "behavior_labels": ["env_modification", "social_interaction", "temporal_strategy", "resource_management"],
        "behavior_bounds": [(0.0, 1.0), (0.0, 1.0), (0.0, 1.0), (0.0, 1.0)],
        "grid_shape": (8, 8, 8, 8),
        "pop_size": 1024,
        "max_steps": 500,
    },
    "beetle": {
        "description": "Herbivore foraging, predator evasion",
        "n_inputs": 12, "n_outputs": 6,
        "behavior_dims": 4,
        "behavior_labels": ["env_modification", "social_interaction", "temporal_strategy", "resource_management"],
        "behavior_bounds": [(0.0, 1.0), (0.0, 1.0), (0.0, 1.0), (0.0, 1.0)],
        "grid_shape": (8, 8, 8, 8),
        "pop_size": 1024,
        "max_steps": 400,
    },
    "spider": {
        "description": "Ambush predator, web building, cave dwelling",
        "n_inputs": 14, "n_outputs": 7,
        "behavior_dims": 4,
        "behavior_labels": ["env_modification", "social_interaction", "temporal_strategy", "resource_management"],
        "behavior_bounds": [(0.0, 1.0), (0.0, 1.0), (0.0, 1.0), (0.0, 1.0)],
        "grid_shape": (6, 6, 6, 6),  # 1296 niches
        "pop_size": 1024,
        "max_steps": 500,
    },
    "fish": {
        "description": "Aquatic herbivore, schooling behavior",
        "n_inputs": 12, "n_outputs": 5,
        "behavior_dims": 4,
        "behavior_labels": ["env_modification", "social_interaction", "temporal_strategy", "resource_management"],
        "behavior_bounds": [(0.0, 1.0), (0.0, 1.0), (0.0, 1.0), (0.0, 1.0)],
        "grid_shape": (6, 6, 6, 6),
        "pop_size": 1024,
        "max_steps": 400,
    },
    "bee": {
        "description": "Pollinator, honey production, hive navigation",
        "n_inputs": 14, "n_outputs": 7,
        "behavior_dims": 4,
        "behavior_labels": ["env_modification", "social_interaction", "temporal_strategy", "resource_management"],
        "behavior_bounds": [(0.0, 1.0), (0.0, 1.0), (0.0, 1.0), (0.0, 1.0)],
        "grid_shape": (6, 6, 6, 6),
        "pop_size": 1024,
        "max_steps": 500,
    },
    "firefly": {
        "description": "Nocturnal, synchronization, atmospheric",
        "n_inputs": 10, "n_outputs": 4,
        "behavior_dims": 4,
        "behavior_labels": ["env_modification", "social_interaction", "temporal_strategy", "resource_management"],
        "behavior_bounds": [(0.0, 1.0), (0.0, 1.0), (0.0, 1.0), (0.0, 1.0)],
        "grid_shape": (6, 6, 6, 6),
        "pop_size": 256,
        "max_steps": 300,
    },
    "plant": {
        "description": "Phototropic growth, resource competition, defense evolution",
        "n_inputs": 8, "n_outputs": 6,
        "behavior_dims": 4,
        "behavior_labels": ["env_modification", "social_interaction", "temporal_strategy", "resource_management"],
        "behavior_bounds": [(0.0, 1.0), (0.0, 1.0), (0.0, 1.0), (0.0, 1.0)],
        "grid_shape": (8, 8, 8, 8),
        "pop_size": 1024,
        "max_steps": 600,
    },
    "seaweed": {
        "description": "Aquatic growth, toxin evolution, fish predation pressure",
        "n_inputs": 8, "n_outputs": 6,
        "behavior_dims": 4,
        "behavior_labels": ["env_modification", "social_interaction", "temporal_strategy", "resource_management"],
        "behavior_bounds": [(0.0, 1.0), (0.0, 1.0), (0.0, 1.0), (0.0, 1.0)],
        "grid_shape": (6, 6, 6, 6),
        "pop_size": 256,
        "max_steps": 400,
    },
}

# ---------------------------------------------------------------------------
# Element constants (matching Dart El class)
# ---------------------------------------------------------------------------
EL_EMPTY = 0; EL_SAND = 1; EL_WATER = 2; EL_FIRE = 3
EL_DIRT = 16; EL_PLANT = 17; EL_SEED = 6; EL_COMPOST = 30
EL_STONE = 7; EL_ALGAE = 35; EL_FUNGUS = 27
EL_SEAWEED = 41; EL_MOSS = 42; EL_VINE = 43
EL_FLOWER = 44; EL_ROOT = 45; EL_THORN = 46

# Food element per species (used by JAX evaluator)
FOOD_ELEMENT = {
    "worm": EL_COMPOST, "ant": EL_SEED, "beetle": EL_PLANT,
    "spider": EL_SEED, "fish": EL_ALGAE, "bee": EL_PLANT,
    "firefly": EL_COMPOST,
}


# ===========================================================================
# JAX-NATIVE EVALUATION (runs entirely on GPU)
# ===========================================================================
# The key insight: we represent the grid and creature state as JAX arrays and
# use jax.vmap to evaluate the entire population in parallel. No pure_callback,
# no numpy loops. The simplified physics (gravity for food, movement,
# eating) is enough for training — the real physics runs in Dart at runtime.
# ===========================================================================

def _jax_make_world(key, species_name, size=48):
    """Create a JAX grid for a species. Returns (grid, spawn_x, spawn_y, food_el)."""
    grid = jnp.zeros((size, size), dtype=jnp.int32)
    food_el = FOOD_ELEMENT.get(species_name, EL_SEED)

    # Ground level varies by species
    ground = size * 2 // 3  # default

    if species_name == "worm":
        ground = size // 3
        # Fill below ground with dirt
        grid = grid.at[ground:, :].set(EL_DIRT)
        # Scatter compost using deterministic pattern from key
        k1, k2 = jrandom.split(key)
        compost_mask = jrandom.uniform(k1, (size - ground, size)) < 0.08
        dirt_section = jnp.where(compost_mask, EL_COMPOST, EL_DIRT)
        grid = grid.at[ground:, :].set(dirt_section)
        sy = ground + 2
    elif species_name in ("ant", "beetle"):
        grid = grid.at[ground:, :].set(EL_DIRT)
        # Scatter food
        k1, k2 = jrandom.split(key)
        food_xs = jrandom.randint(k1, (25,), 5, size - 5)
        food_ys = jrandom.randint(k2, (25,), ground - 10, ground)
        for i in range(25):
            grid = grid.at[food_ys[i], food_xs[i]].set(food_el)
        sy = ground - 5
    elif species_name == "spider":
        ground = size // 2
        grid = grid.at[ground:, :].set(EL_STONE)
        # Carve cave
        k1, k2 = jrandom.split(key)
        cave_mask = jrandom.uniform(k1, (size - ground - 8, size - 20)) < 0.7
        for y_off in range(cave_mask.shape[0]):
            for x_off in range(cave_mask.shape[1]):
                grid = jnp.where(
                    cave_mask[y_off, x_off],
                    grid.at[ground + 3 + y_off, 10 + x_off].set(EL_EMPTY),
                    grid
                )
        sy = ground + 5
    elif species_name == "fish":
        grid = grid.at[:, :].set(EL_WATER)
        grid = grid.at[size - 5:, :].set(EL_STONE)
        k1, k2 = jrandom.split(key)
        food_xs = jrandom.randint(k1, (40,), 0, size)
        food_ys = jrandom.randint(k2, (40,), 5, size - 10)
        for i in range(40):
            grid = grid.at[food_ys[i], food_xs[i]].set(EL_ALGAE)
        sy = 10
    elif species_name == "bee":
        ground = size * 3 // 4
        grid = grid.at[ground:, :].set(EL_DIRT)
        k1, k2 = jrandom.split(key)
        food_xs = jrandom.randint(k1, (25,), 0, size)
        food_ys = jrandom.randint(k2, (25,), ground - 3, ground)
        for i in range(25):
            grid = grid.at[food_ys[i], food_xs[i]].set(EL_PLANT)
        sy = ground - 15
    elif species_name == "firefly":
        ground = size * 3 // 4
        grid = grid.at[ground:, :].set(EL_DIRT)
        sy = 10
    else:
        grid = grid.at[ground:, :].set(EL_DIRT)
        sy = ground - 5

    k1, k2 = jrandom.split(key)
    sx = jrandom.randint(k1, (), 5, size - 5)
    return grid, sx, sy, food_el


def _jax_forward(params, inputs, n_in, n_hidden, n_out):
    """Pure JAX feed-forward network: inputs -> hidden(tanh) -> outputs(tanh)."""
    idx = 0
    w1 = jax.lax.dynamic_slice(params, (idx,), (n_in * n_hidden,)).reshape(n_in, n_hidden)
    idx += n_in * n_hidden
    b1 = jax.lax.dynamic_slice(params, (idx,), (n_hidden,))
    idx += n_hidden
    w2 = jax.lax.dynamic_slice(params, (idx,), (n_hidden * n_out,)).reshape(n_hidden, n_out)
    idx += n_hidden * n_out
    b2 = jax.lax.dynamic_slice(params, (idx,), (n_out,))

    h = jnp.tanh(inputs @ w1 + b1)
    return jnp.tanh(h @ w2 + b2)


def _jax_get_el(grid, x, y, size):
    """Get element at (x,y) with boundary check, returning STONE for out-of-bounds."""
    in_bounds = (x >= 0) & (x < size) & (y >= 0) & (y < size)
    safe_x = jnp.clip(x, 0, size - 1)
    safe_y = jnp.clip(y, 0, size - 1)
    return jnp.where(in_bounds, grid[safe_y, safe_x], EL_STONE)


def _jax_count_nearby(grid, cx, cy, radius, el_type, size):
    """Count occurrences of el_type within radius of (cx, cy). Pure JAX."""
    # Build offset grid once (will be traced as constants)
    offsets = jnp.arange(-radius, radius + 1)
    dx_grid, dy_grid = jnp.meshgrid(offsets, offsets)
    dx_flat = dx_grid.flatten()
    dy_flat = dy_grid.flatten()
    nx = jnp.clip(cx + dx_flat, 0, size - 1)
    ny = jnp.clip(cy + dy_flat, 0, size - 1)
    in_bounds = ((cx + dx_flat) >= 0) & ((cx + dx_flat) < size) & \
                ((cy + dy_flat) >= 0) & ((cy + dy_flat) < size)
    vals = grid[ny, nx]
    return jnp.sum(jnp.where(in_bounds & (vals == el_type), 1, 0))


def _jax_evaluate_creature_single(params, key, species_name, n_in, n_out, n_hidden,
                                   max_steps, food_el, grid_size, curriculum_stage):
    """Evaluate a single creature entirely in JAX. Returns (fitness, descriptors[4])."""
    # Build world
    k1, k2 = jrandom.split(key)
    grid, sx, sy, _ = _jax_make_world(k1, species_name, grid_size)

    x = sx.astype(jnp.int32)
    y = sy

    # State: energy, position, counters for 4D behavior descriptors
    energy = 1.0
    total_food = 0.0
    total_moved = 0.0
    total_depth = 0.0
    ticks_survived = 0

    # 4D descriptor accumulators
    env_modifications = 0.0     # how much the creature changed the grid
    social_signals = 0.0        # how often it emitted signals / was near others
    early_food = 0.0            # food collected in first half
    late_food = 0.0             # food collected in second half
    food_stored = 0.0           # food collected but not immediately needed (energy > 0.7)
    food_desperate = 0.0        # food collected when energy < 0.3

    n_unique_cells = 0.0
    # Track visited via position hash set approximation
    visit_hash = jnp.zeros(256, dtype=jnp.int32)  # simple hash table

    def step_fn(carry, tick):
        (x, y, energy, grid, total_food, total_moved, total_depth,
         env_mods, soc_sig, e_food, l_food, f_stored, f_desp, v_hash, alive_f) = carry

        alive = (energy > 0) & (alive_f > 0)

        # Build inputs
        inputs = jnp.zeros(n_in)
        fc = _jax_count_nearby(grid, x, y, 5, food_el, grid_size)
        inputs = inputs.at[0].set(fc / 25.0)
        inputs = inputs.at[1].set(energy)
        inputs = inputs.at[2].set(y / grid_size)
        inputs = inputs.at[3].set(x / grid_size)

        # Local env sensing (up to 6 directions) — fully vectorized
        deltas = jnp.array([[0, -1], [0, 1], [-1, 0], [1, 0], [1, 1], [-1, -1]])
        sense_x = jnp.clip(x + deltas[:, 0], 0, grid_size - 1)
        sense_y = jnp.clip(y + deltas[:, 1], 0, grid_size - 1)
        sense_vals = grid[sense_y, sense_x] / 40.0
        n_sense = min(n_in - 4, 6)  # static at trace time, OK
        inputs = inputs.at[4:4 + n_sense].set(sense_vals[:n_sense] * alive)

        # Forward pass
        outputs = _jax_forward(params, inputs, n_in, n_hidden, n_out)

        # Movement
        dx = jnp.clip(jnp.round(outputs[0] * 1.5), -1, 1).astype(jnp.int32)
        dy = jnp.clip(jnp.round(outputs[1] * 1.5), -1, 1).astype(jnp.int32)
        nx = jnp.clip(x + dx, 0, grid_size - 1)
        ny = jnp.clip(y + dy, 0, grid_size - 1)
        target = _jax_get_el(grid, nx, ny, grid_size)
        can_move = (target == EL_EMPTY) | (target == food_el) | (target == EL_DIRT) | (target == EL_WATER)
        did_move = can_move & ((nx != x) | (ny != y)) & alive
        new_x = jnp.where(did_move, nx, x)
        new_y = jnp.where(did_move, ny, y)
        total_moved = total_moved + jnp.where(did_move, 1.0, 0.0)

        # Visit tracking via hash
        pos_hash = ((new_x * 17 + new_y * 31) % 256).astype(jnp.int32)
        is_new = (v_hash[pos_hash] == 0) & alive
        v_hash = jnp.where(alive, v_hash.at[pos_hash].set(1), v_hash)

        # Eating
        want_eat = (n_out > 2) & (outputs[2] > 0)
        at_food = (_jax_get_el(grid, new_x, new_y, grid_size) == food_el)
        did_eat = want_eat & at_food & alive
        grid = jnp.where(did_eat, grid.at[new_y, new_x].set(EL_EMPTY), grid)
        energy = jnp.where(did_eat, jnp.minimum(1.0, energy + 0.15), energy)
        total_food = total_food + jnp.where(did_eat, 1.0, 0.0)

        # Environment modification: creature digs / places elements
        # Output index 3 if available: dig action
        did_dig = False
        if n_out > 3:
            dig_signal = outputs[3]
            dig_target = _jax_get_el(grid, new_x, new_y + 1, grid_size)
            can_dig = (dig_signal > 0.5) & ((dig_target == EL_DIRT) | (dig_target == EL_SAND)) & alive
            grid = jnp.where(can_dig, grid.at[jnp.clip(new_y + 1, 0, grid_size - 1), new_x].set(EL_EMPTY), grid)
            env_mods = env_mods + jnp.where(can_dig, 1.0, 0.0)
            did_dig = can_dig

        # Social signal: output index 4 if available
        if n_out > 4:
            signal = outputs[4]
            did_signal = (jnp.abs(signal) > 0.7) & alive
            soc_sig = soc_sig + jnp.where(did_signal, 1.0, 0.0)

        # Temporal behavior tracking
        half_step = max_steps // 2
        is_early = tick < half_step
        e_food = e_food + jnp.where(did_eat & is_early, 1.0, 0.0)
        l_food = l_food + jnp.where(did_eat & ~is_early, 1.0, 0.0)

        # Resource management
        f_stored = f_stored + jnp.where(did_eat & (energy > 0.7), 1.0, 0.0)
        f_desp = f_desp + jnp.where(did_eat & (energy < 0.3), 1.0, 0.0)

        total_depth = total_depth + jnp.where(alive, new_y / grid_size, 0.0)
        energy = jnp.where(alive, energy - 0.002, energy)
        alive_f = jnp.where(energy <= 0, 0.0, alive_f)

        carry = (new_x, new_y, energy, grid, total_food, total_moved, total_depth,
                 env_mods, soc_sig, e_food, l_food, f_stored, f_desp, v_hash, alive_f)
        return carry, tick

    init_carry = (x, y, energy, grid, total_food, total_moved, total_depth,
                  env_modifications, social_signals, early_food, late_food,
                  food_stored, food_desperate, visit_hash, 1.0)

    final_carry, _ = jax.lax.scan(step_fn, init_carry, jnp.arange(max_steps))

    (_, _, _, _, total_food, total_moved, total_depth,
     env_mods, soc_sig, e_food, l_food, f_stored, f_desp, v_hash, _) = final_carry

    n_unique = jnp.sum(v_hash > 0).astype(jnp.float32)
    ticks_survived = max_steps  # simplified: use full count for JAX version

    # Fitness: food + exploration + survival
    fitness = (
        total_food * 5.0 +
        n_unique * 0.5 +
        ticks_survived * 0.01 +
        total_moved * 0.1 +
        env_mods * 2.0  # reward environment modification
    )

    # 4D Behavioral descriptors (all normalized 0-1)
    # 1. Environment modification: how much did it change the grid?
    desc_env_mod = jnp.clip(env_mods / 20.0, 0.0, 1.0)

    # 2. Social interaction: signal emission frequency
    desc_social = jnp.clip(soc_sig / (max_steps * 0.3), 0.0, 1.0)

    # 3. Temporal strategy: did behavior change over lifetime?
    #    0 = front-loaded (all early), 1 = back-loaded (all late), 0.5 = uniform
    total_f = e_food + l_food + 1e-6
    desc_temporal = jnp.clip(l_food / total_f, 0.0, 1.0)

    # 4. Resource management: stored (ate when full) vs desperate (ate when starving)
    #    0 = pure desperation eater, 1 = stores resources when full
    total_rm = f_stored + f_desp + 1e-6
    desc_resource = jnp.clip(f_stored / total_rm, 0.0, 1.0)

    descriptors = jnp.array([desc_env_mod, desc_social, desc_temporal, desc_resource])
    return fitness, descriptors


def _jax_evaluate_plant_single(params, key, species_name, n_in, n_out, n_hidden,
                                max_steps, grid_size, curriculum_stage):
    """Evaluate a plant genome entirely in JAX. Plants grow, not move."""
    k1, k2 = jrandom.split(key)
    grid, sx, sy, _ = _jax_make_world(k1, species_name, grid_size)

    is_seaweed = species_name == "seaweed"
    plant_el = jnp.where(is_seaweed, EL_SEAWEED, EL_PLANT)

    x = sx.astype(jnp.int32)
    y = sy

    # Place initial cell
    grid = grid.at[y, x].set(plant_el)

    # Track plant as a fixed-size array of positions (max 200 cells)
    max_cells = 200
    cell_xs = jnp.full(max_cells, -1, dtype=jnp.int32)
    cell_ys = jnp.full(max_cells, -1, dtype=jnp.int32)
    cell_xs = cell_xs.at[0].set(x)
    cell_ys = cell_ys.at[0].set(y)
    n_cells = 1

    total_biomass = 0.0
    seeds_produced = 0.0
    oxygen_produced = 0.0
    max_height = 0.0
    toxin_level = 0.0
    cells_eaten = 0.0
    herbivore_damages = 0.0
    env_modifications = 0.0
    temporal_growth_early = 0.0
    temporal_growth_late = 0.0

    luminance = jnp.linspace(255, 50, grid_size) / 255.0

    def step_fn(carry, tick):
        (grid, cell_xs, cell_ys, n_cells, biomass, seeds, oxygen,
         m_height, toxin, eaten, herb_dmg, env_mods,
         tg_early, tg_late) = carry

        half_step = max_steps // 2

        # Process first active cell (simplified for JAX — process one growth point per tick)
        cell_idx = (tick % jnp.maximum(n_cells, 1)).astype(jnp.int32)
        cx = cell_xs[cell_idx]
        cy = cell_ys[cell_idx]
        valid = (cx >= 0) & (cy >= 0) & (n_cells > 0)

        # Neural inputs
        lum = jnp.where(valid, luminance[jnp.clip(cy, 0, grid_size - 1)], 0.0)
        nearby_water = _jax_count_nearby(grid, cx, cy, 2, EL_WATER, grid_size)
        moist = jnp.minimum(1.0, nearby_water / 8.0)
        crowding = _jax_count_nearby(grid, cx, cy, 1, plant_el, grid_size) / 8.0
        age = tick / max_steps
        inputs = jnp.zeros(n_in)
        inputs = inputs.at[0].set(lum)
        inputs = inputs.at[1].set(0.0)  # lum gradient
        inputs = inputs.at[2].set(moist)
        inputs = inputs.at[3].set(0.0)  # moist gradient
        inputs = inputs.at[4].set(0.5)  # pH
        inputs = inputs.at[5].set(0.5)  # temp
        inputs = inputs.at[6].set(crowding)
        inputs = inputs.at[7].set(age)

        out = _jax_forward(params, inputs, n_in, n_hidden, n_out)

        grow_up = out[0]
        grow_lateral = out[1]
        branch_prob = (out[2] + 1.0) * 0.05
        seed_prod = (out[3] + 1.0) * 0.003
        toxin_prod = (out[5] + 1.0) * 0.5 if n_out > 5 else 0.0

        toxin = jnp.where(is_seaweed, toxin * 0.99 + toxin_prod * 0.01, toxin)

        # Growth
        can_grow_tick = (tick % 3 == 0) & (n_cells < max_cells) & valid
        gy = jnp.where(grow_up > 0, cy - 1, cy + 1)
        gx_shift = jnp.where(grow_lateral > 0.3, 1, jnp.where(grow_lateral < -0.3, -1, 0))
        gx = jnp.clip(cx + gx_shift, 0, grid_size - 1)
        gy = jnp.clip(gy, 0, grid_size - 1)

        target_el = grid[gy, gx]
        can_grow_space = jnp.where(is_seaweed, target_el == EL_WATER, target_el == EL_EMPTY)
        did_grow = can_grow_tick & can_grow_space

        grid = jnp.where(did_grow, grid.at[gy, gx].set(plant_el), grid)
        cell_xs = jnp.where(did_grow, cell_xs.at[n_cells].set(gx), cell_xs)
        cell_ys = jnp.where(did_grow, cell_ys.at[n_cells].set(gy), cell_ys)
        n_cells = jnp.where(did_grow, n_cells + 1, n_cells)
        biomass = biomass + jnp.where(did_grow, 1.0, 0.0)
        height = jnp.abs(sy - gy)
        m_height = jnp.where(did_grow, jnp.maximum(m_height, height.astype(jnp.float32)), m_height)
        env_mods = env_mods + jnp.where(did_grow, 1.0, 0.0)

        # Temporal tracking
        is_early = tick < half_step
        tg_early = tg_early + jnp.where(did_grow & is_early, 1.0, 0.0)
        tg_late = tg_late + jnp.where(did_grow & ~is_early, 1.0, 0.0)

        # Seeding
        k = jrandom.fold_in(key, tick)
        did_seed = (jrandom.uniform(k) < seed_prod) & (n_cells > 5) & valid
        seeds = seeds + jnp.where(did_seed, 1.0, 0.0)

        # Oxygen
        did_oxy = (tick % 10 == 0) & (lum > 0.3) & valid
        oxygen = oxygen + jnp.where(did_oxy, 1.0, 0.0)

        # Fish predation for seaweed
        k2 = jrandom.fold_in(key, tick + 10000)
        fish_tick = is_seaweed & (tick % 20 == 0) & (n_cells > 5)
        fish_avoided = jrandom.uniform(k2) < toxin
        eaten = eaten + jnp.where(fish_tick & ~fish_avoided, 1.0, 0.0)
        herb_dmg = herb_dmg + jnp.where(fish_tick & fish_avoided, 1.0, 0.0)

        carry = (grid, cell_xs, cell_ys, n_cells, biomass, seeds, oxygen,
                 m_height, toxin, eaten, herb_dmg, env_mods, tg_early, tg_late)
        return carry, tick

    init_carry = (grid, cell_xs, cell_ys, n_cells, total_biomass, seeds_produced,
                  oxygen_produced, max_height, toxin_level, cells_eaten,
                  herbivore_damages, env_modifications, temporal_growth_early, temporal_growth_late)

    final_carry, _ = jax.lax.scan(step_fn, init_carry, jnp.arange(max_steps))

    (_, _, _, n_cells_final, biomass, seeds, oxygen,
     m_height, toxin, eaten, herb_dmg, env_mods, tg_early, tg_late) = final_carry

    # Fitness
    fitness = jnp.where(
        is_seaweed,
        biomass * 2.0 + max_steps * 0.1 + herb_dmg * 5.0 + oxygen * 1.0 + seeds * 3.0 - eaten * 2.0,
        biomass * 2.0 + seeds * 5.0 + oxygen * 1.0 + max_steps * 0.5 - eaten * 1.0
    )

    # 4D descriptors
    desc_env_mod = jnp.clip(env_mods / 50.0, 0.0, 1.0)
    desc_social = jnp.clip(toxin / 1.0, 0.0, 1.0)  # toxin as "social" defense
    total_growth = tg_early + tg_late + 1e-6
    desc_temporal = jnp.clip(tg_late / total_growth, 0.0, 1.0)
    desc_resource = jnp.clip(seeds / (biomass + 1e-6) * 10.0, 0.0, 1.0)  # reproduction investment

    descriptors = jnp.array([desc_env_mod, desc_social, desc_temporal, desc_resource])
    return fitness, descriptors


# ---------------------------------------------------------------------------
# Curriculum Learning: progressive environment complexity
# ---------------------------------------------------------------------------

CURRICULUM_STAGES = {
    0: {"grid_size": 32, "food_density": 1.5, "label": "Simple flat, dense food"},
    1: {"grid_size": 40, "food_density": 1.0, "label": "Medium terrain, normal food"},
    2: {"grid_size": 48, "food_density": 0.7, "label": "Full terrain, sparse food"},
    3: {"grid_size": 56, "food_density": 0.5, "label": "Large world, scarce food"},
}

def get_curriculum_stage(iteration, total_iterations):
    """Determine curriculum stage based on training progress."""
    progress = iteration / max(total_iterations, 1)
    if progress < 0.15:
        return 0
    elif progress < 0.40:
        return 1
    elif progress < 0.70:
        return 2
    else:
        return 3


# ---------------------------------------------------------------------------
# Numpy-based evaluation (fallback for pyribs / non-JAX)
# ---------------------------------------------------------------------------

def _clamp(v, lo, hi):
    return max(lo, min(hi, v))

def _get_el(grid, x, y):
    h, w = grid.shape
    if x < 0 or x >= w or y < 0 or y >= h:
        return EL_STONE
    return grid[y, x]

def _count_nearby(grid, cx, cy, radius, el_type):
    h, w = grid.shape
    count = 0
    for dy in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            nx, ny = cx + dx, cy + dy
            if 0 <= nx < w and 0 <= ny < h and grid[ny, nx] == el_type:
                count += 1
    return count


# ---------------------------------------------------------------------------
# Environment builders (numpy, for pyribs fallback)
# ---------------------------------------------------------------------------

def make_worm_world(rng, size=64):
    grid = np.zeros((size, size), dtype=np.int32)
    surface = size // 3
    grid[surface:, :] = EL_DIRT
    compost_mask = rng.random((size - surface, size)) < 0.08
    grid[surface:, :][compost_mask] = EL_COMPOST
    return grid, (surface + 2, 2, size - 2, size - 2)

def make_ant_world(rng, size=64):
    grid = np.zeros((size, size), dtype=np.int32)
    ground = size * 2 // 3
    grid[ground:, :] = EL_DIRT
    for _ in range(20):
        fx, fy = rng.integers(5, size - 5), rng.integers(ground - 10, ground)
        grid[fy, fx] = EL_SEED
    return grid, (ground - 5, 5, size - 5, ground)

def make_beetle_world(rng, size=64):
    grid = np.zeros((size, size), dtype=np.int32)
    ground = size * 2 // 3
    grid[ground:, :] = EL_DIRT
    for _ in range(30):
        px, py = rng.integers(0, size), rng.integers(ground - 15, ground)
        grid[py, px] = EL_PLANT
    return grid, (ground - 3, 2, size - 2, ground)

def make_spider_world(rng, size=64):
    grid = np.zeros((size, size), dtype=np.int32)
    grid[size//2:, :] = EL_STONE
    for y in range(size//2 + 3, size - 5):
        for x in range(10, size - 10):
            if rng.random() < 0.7:
                grid[y, x] = EL_EMPTY
    return grid, (size//2 + 5, 12, size - 12, size - 8)

def make_fish_world(rng, size=64):
    grid = np.zeros((size, size), dtype=np.int32)
    grid[:, :] = EL_WATER
    grid[size-5:, :] = EL_STONE
    for _ in range(40):
        ax, ay = rng.integers(0, size), rng.integers(5, size - 10)
        grid[ay, ax] = EL_ALGAE
    return grid, (5, 5, size - 5, size - 10)

def make_bee_world(rng, size=64):
    grid = np.zeros((size, size), dtype=np.int32)
    ground = size * 3 // 4
    grid[ground:, :] = EL_DIRT
    for _ in range(25):
        px, py = rng.integers(0, size), rng.integers(ground - 3, ground)
        grid[py, px] = EL_PLANT
    return grid, (ground - 20, 5, size - 5, ground - 5)

def make_firefly_world(rng, size=64):
    grid = np.zeros((size, size), dtype=np.int32)
    ground = size * 3 // 4
    grid[ground:, :] = EL_DIRT
    for _ in range(15):
        fx, fy = rng.integers(0, size), rng.integers(ground - 2, ground)
        grid[fy, fx] = EL_COMPOST
    return grid, (10, 5, size - 5, ground - 5)

def make_plant_world(rng, size=64):
    grid = np.zeros((size, size), dtype=np.int32)
    ground = size * 2 // 3
    grid[ground:, :] = EL_DIRT
    for _ in range(3):
        wx = rng.integers(5, size - 5)
        for dy in range(3):
            for dx in range(-2, 3):
                nx, ny = wx + dx, ground - 1 - dy
                if 0 <= nx < size and 0 <= ny < size:
                    grid[ny, nx] = EL_WATER
    compost_mask = rng.random((size - ground, size)) < 0.05
    grid[ground:, :][compost_mask] = EL_COMPOST
    return grid, (ground - 1, 5, size - 5, ground)

def make_seaweed_world(rng, size=64):
    grid = np.zeros((size, size), dtype=np.int32)
    grid[:, :] = EL_WATER
    grid[size-8:, :] = EL_STONE
    for _ in range(10):
        sx = rng.integers(3, size - 3)
        for dx in range(-2, 3):
            nx = sx + dx
            if 0 <= nx < size:
                grid[size-9, nx] = EL_DIRT
    return grid, (size - 12, 5, size - 5, size - 9)

ENV_BUILDERS = {
    "worm": make_worm_world, "ant": make_ant_world,
    "beetle": make_beetle_world, "spider": make_spider_world,
    "fish": make_fish_world, "bee": make_bee_world,
    "firefly": make_firefly_world,
    "plant": make_plant_world, "seaweed": make_seaweed_world,
}


# ---------------------------------------------------------------------------
# Numpy creature evaluation (pyribs fallback, with 4D descriptors)
# ---------------------------------------------------------------------------

def evaluate_plant(params, species_name, rng_seed=42):
    """Evaluate a plant genome with numpy. Returns (fitness, descriptors[4])."""
    cfg = SPECIES[species_name]
    n_in, n_out = cfg["n_inputs"], cfg["n_outputs"]
    max_steps = cfg["max_steps"]
    rng = np.random.default_rng(rng_seed)

    n_hidden = 4
    expected_params = n_in * n_hidden + n_hidden + n_hidden * n_out + n_out
    w = np.zeros(expected_params)
    w[:min(len(params), expected_params)] = params[:expected_params] if len(params) >= expected_params else np.pad(params, (0, expected_params - len(params)))

    idx = 0
    w1 = w[idx:idx + n_in * n_hidden].reshape(n_in, n_hidden); idx += n_in * n_hidden
    b1 = w[idx:idx + n_hidden]; idx += n_hidden
    w2 = w[idx:idx + n_hidden * n_out].reshape(n_hidden, n_out); idx += n_hidden * n_out
    b2 = w[idx:idx + n_out]; idx += n_out

    def forward(inputs):
        h = np.tanh(np.array(inputs) @ w1 + b1)
        return np.tanh(h @ w2 + b2)

    builder = ENV_BUILDERS[species_name]
    grid, (sy0, sx0, sx1, sy1) = builder(rng, size=48)
    h, w_grid = grid.shape

    x = rng.integers(sx0, sx1)
    y = sy0

    is_seaweed = species_name == "seaweed"
    plant_el = EL_SEAWEED if is_seaweed else EL_PLANT

    grid[y, x] = plant_el
    plant_cells = {(x, y)}
    total_biomass = 0
    seeds_produced = 0
    oxygen_produced = 0
    max_height = 0
    toxin_level = 0.0
    cells_eaten = 0
    ticks_survived = 0
    herbivore_damages = 0
    early_growth = 0
    late_growth = 0
    env_modifications = 0

    luminance = np.linspace(255, 50, h).astype(int)

    for tick in range(max_steps):
        ticks_survived = tick
        if not plant_cells:
            break

        new_cells = set()
        dead_cells = set()
        half_step = max_steps // 2

        for (cx, cy) in list(plant_cells):
            if grid[cy, cx] != plant_el:
                dead_cells.add((cx, cy))
                continue

            lum = luminance[cy] / 255.0
            nearby_water = _count_nearby(grid, cx, cy, 2, EL_WATER)
            moist = min(1.0, nearby_water / 8.0)
            crowding = min(1.0, _count_nearby(grid, cx, cy, 1, plant_el) / 8.0)
            age = min(1.0, tick / max_steps)

            inputs = [lum, 0.0, moist, 0.0, 0.5, 0.5, crowding, age]
            out = forward(inputs)

            grow_up = out[0]
            grow_lateral = out[1]
            branch_prob = (out[2] + 1.0) * 0.05
            seed_prod = (out[3] + 1.0) * 0.003
            toxin_prod = (out[5] + 1.0) * 0.5 if n_out > 5 else 0.0

            if is_seaweed:
                toxin_level = toxin_level * 0.99 + toxin_prod * 0.01

            if tick % 3 == 0 and len(plant_cells) < 200:
                gy = cy - 1 if grow_up > 0 else cy + 1
                gx = cx + (1 if grow_lateral > 0.3 else -1 if grow_lateral < -0.3 else 0)
                gx = _clamp(gx, 0, w_grid - 1)
                gy = _clamp(gy, 0, h - 1)

                target = grid[gy, gx]
                can_grow = (target == EL_WATER) if is_seaweed else (target == EL_EMPTY)
                if can_grow and (gx, gy) not in plant_cells:
                    grid[gy, gx] = plant_el
                    new_cells.add((gx, gy))
                    total_biomass += 1
                    env_modifications += 1
                    height = sy0 - gy if not is_seaweed else sy1 - gy
                    max_height = max(max_height, abs(height))
                    if tick < half_step:
                        early_growth += 1
                    else:
                        late_growth += 1

                if rng.random() < branch_prob and len(plant_cells) > 3:
                    bx = cx + rng.choice([-1, 1])
                    bx = _clamp(bx, 0, w_grid - 1)
                    target = grid[cy, bx]
                    can_branch = (target == EL_WATER) if is_seaweed else (target == EL_EMPTY)
                    if can_branch and (bx, cy) not in plant_cells:
                        grid[cy, bx] = plant_el
                        new_cells.add((bx, cy))
                        total_biomass += 1
                        env_modifications += 1

            if rng.random() < seed_prod and len(plant_cells) > 5:
                seeds_produced += 1

            if tick % 10 == 0 and lum > 0.3:
                oxygen_produced += 1

        plant_cells -= dead_cells
        plant_cells |= new_cells

        if is_seaweed and tick % 20 == 0 and len(plant_cells) > 5:
            if rng.random() > toxin_level:
                target = rng.choice(list(plant_cells))
                grid[target[1], target[0]] = EL_WATER
                plant_cells.discard(target)
                cells_eaten += 1
            else:
                herbivore_damages += 1

    if is_seaweed:
        fitness = (
            total_biomass * 2.0 +
            ticks_survived * 0.1 * (1.0 if cells_eaten > 0 else 0.5) +
            herbivore_damages * 5.0 +
            oxygen_produced * 1.0 +
            seeds_produced * 3.0 -
            cells_eaten * 2.0
        )
    else:
        fitness = (
            total_biomass * 2.0 +
            seeds_produced * 5.0 +
            oxygen_produced * 1.0 +
            ticks_survived * 0.5 -
            cells_eaten * 1.0
        )

    # 4D descriptors
    desc_env_mod = _clamp(env_modifications / 50.0, 0.0, 1.0)
    desc_social = _clamp(toxin_level, 0.0, 1.0)
    total_growth = early_growth + late_growth + 1e-6
    desc_temporal = _clamp(late_growth / total_growth, 0.0, 1.0)
    desc_resource = _clamp(seeds_produced / (total_biomass + 1e-6) * 10.0, 0.0, 1.0)

    return float(fitness), [float(desc_env_mod), float(desc_social), float(desc_temporal), float(desc_resource)]


def evaluate_creature(params, species_name, rng_seed=42):
    """Evaluate a creature genome (flat param vector). Returns (fitness, descriptors[4])."""
    if species_name in ("plant", "seaweed"):
        return evaluate_plant(params, species_name, rng_seed)

    cfg = SPECIES[species_name]
    n_in, n_out = cfg["n_inputs"], cfg["n_outputs"]
    max_steps = cfg["max_steps"]
    rng = np.random.default_rng(rng_seed)

    n_hidden = 8
    expected_params = n_in * n_hidden + n_hidden + n_hidden * n_out + n_out
    w = np.zeros(expected_params)
    w[:len(params)] = params[:expected_params] if len(params) >= expected_params else np.pad(params, (0, expected_params - len(params)))

    idx = 0
    w1 = w[idx:idx + n_in * n_hidden].reshape(n_in, n_hidden); idx += n_in * n_hidden
    b1 = w[idx:idx + n_hidden]; idx += n_hidden
    w2 = w[idx:idx + n_hidden * n_out].reshape(n_hidden, n_out); idx += n_hidden * n_out
    b2 = w[idx:idx + n_out]; idx += n_out

    def forward(inputs):
        h = np.tanh(np.array(inputs) @ w1 + b1)
        return np.tanh(h @ w2 + b2)

    builder = ENV_BUILDERS[species_name]
    grid, (sy0, sx0, sx1, sy1) = builder(rng, size=48)
    x = rng.integers(sx0, sx1)
    y = rng.integers(sy0, sy1)

    energy = 1.0
    alive = True
    total_food = 0
    total_moved = 0
    total_depth = 0
    positions_visited = set()
    ticks_survived = 0

    # 4D descriptor accumulators
    env_modifications = 0
    social_signals = 0
    early_food = 0
    late_food = 0
    food_when_full = 0
    food_when_starving = 0

    food_el = FOOD_ELEMENT.get(species_name, EL_SEED)
    half_step = max_steps // 2

    for tick in range(max_steps):
        if not alive or energy <= 0:
            break
        ticks_survived = tick

        h, w_grid = grid.shape
        inputs = np.zeros(n_in)
        food_count = _count_nearby(grid, x, y, 5, food_el)
        inputs[0] = food_count / 25.0
        inputs[1] = energy
        inputs[2] = y / h
        inputs[3] = x / w_grid

        for i in range(4, min(n_in, 10)):
            dx, dy = [(0,-1),(0,1),(-1,0),(1,0),(1,1),(-1,-1)][i-4] if i-4 < 6 else (0,0)
            inputs[i] = _get_el(grid, x+dx, y+dy) / 40.0

        outputs = forward(inputs.tolist())

        # Move
        dx = int(round(_clamp(outputs[0] * 1.5, -1, 1)))
        dy = int(round(_clamp(outputs[1] * 1.5, -1, 1)))
        nx, ny = _clamp(x + dx, 0, w_grid - 1), _clamp(y + dy, 0, h - 1)

        target = _get_el(grid, nx, ny)
        if target == EL_EMPTY or target == food_el or target == EL_DIRT or target == EL_WATER:
            if (nx, ny) != (x, y):
                total_moved += 1
            x, y = nx, ny
            positions_visited.add((x, y))

        # Eat
        did_eat = False
        if len(outputs) > 2 and outputs[2] > 0:
            if _get_el(grid, x, y) == food_el:
                grid[y, x] = EL_EMPTY
                energy = min(1.0, energy + 0.15)
                total_food += 1
                did_eat = True
                env_modifications += 1

                if tick < half_step:
                    early_food += 1
                else:
                    late_food += 1

                if energy > 0.7:
                    food_when_full += 1
                if energy < 0.3:
                    food_when_starving += 1

        # Dig (output 3)
        if len(outputs) > 3 and outputs[3] > 0.5:
            dig_y = _clamp(y + 1, 0, h - 1)
            dig_el = _get_el(grid, x, dig_y)
            if dig_el == EL_DIRT or dig_el == EL_SAND:
                grid[dig_y, x] = EL_EMPTY
                env_modifications += 1

        # Social signal (output 4)
        if len(outputs) > 4 and abs(outputs[4]) > 0.7:
            social_signals += 1

        total_depth += y / h
        energy -= 0.002

        if energy <= 0:
            alive = False

    fitness = (
        total_food * 5.0 +
        len(positions_visited) * 0.5 +
        ticks_survived * 0.01 +
        total_moved * 0.1 +
        env_modifications * 2.0
    )

    # 4D descriptors
    desc_env_mod = _clamp(env_modifications / 20.0, 0.0, 1.0)
    desc_social = _clamp(social_signals / (max_steps * 0.3), 0.0, 1.0)
    total_f = early_food + late_food + 1e-6
    desc_temporal = _clamp(late_food / total_f, 0.0, 1.0)
    total_rm = food_when_full + food_when_starving + 1e-6
    desc_resource = _clamp(food_when_full / total_rm, 0.0, 1.0)

    return float(fitness), [float(desc_env_mod), float(desc_social), float(desc_temporal), float(desc_resource)]


# ---------------------------------------------------------------------------
# QDax training (GPU) — now with JAX-native eval + curriculum
# ---------------------------------------------------------------------------

def train_qdax(species_name, iterations=500, grid_shape=None, seed=42, use_curriculum=False):
    """Train using QDax MAP-Elites on GPU with JAX-native evaluation."""
    import functools

    cfg = SPECIES[species_name]
    n_in, n_out = cfg["n_inputs"], cfg["n_outputs"]
    n_hidden = 8 if species_name not in ("plant", "seaweed") else 4
    n_params = n_in * n_hidden + n_hidden + n_hidden * n_out + n_out
    gs = grid_shape or cfg["grid_shape"]
    pop_size = cfg["pop_size"]

    print(f"\n{'='*60}", flush=True)
    print(f"  QDax MAP-Elites: {species_name}", flush=True)
    print(f"  {cfg['description']}", flush=True)
    print(f"  Network: {n_in} -> {n_hidden} -> {n_out} ({n_params} params)", flush=True)
    print(f"  Grid: {'x'.join(map(str, gs))} = {int(np.prod(gs))} behavioral niches (4D)", flush=True)
    print(f"  Batch: {pop_size}, Iterations: {iterations}", flush=True)
    print(f"  Curriculum: {'ENABLED' if use_curriculum else 'disabled'}", flush=True)
    print(f"  Eval: JAX-native (GPU-accelerated)", flush=True)
    print(f"{'='*60}\n", flush=True)

    key = jrandom.PRNGKey(seed)

    is_plant = species_name in ("plant", "seaweed")

    # Build the JAX-native scoring function
    def _eval_single(params, eval_key, curriculum_stage):
        if is_plant:
            return _jax_evaluate_plant_single(
                params, eval_key, species_name, n_in, n_out, n_hidden,
                cfg["max_steps"], 48, curriculum_stage)
        else:
            food_el = FOOD_ELEMENT.get(species_name, EL_SEED)
            return _jax_evaluate_creature_single(
                params, eval_key, species_name, n_in, n_out, n_hidden,
                cfg["max_steps"], food_el, 48, curriculum_stage)

    # Try to use JAX-native vmap evaluation (100% GPU)
    # Fall back to pure_callback if jax.lax.scan compilation fails
    use_jax_native = True

    if use_jax_native:
        print("  Attempting JAX-native vectorized evaluation...", flush=True)
        try:
            # Test compile with a single genome
            test_key = jrandom.PRNGKey(0)
            test_params = jnp.zeros(n_params)
            test_result = jax.jit(lambda p, k: _eval_single(p, k, 0))(test_params, test_key)
            jax.block_until_ready(test_result)
            print(f"  JAX-native eval compiled! Test fitness: {float(test_result[0]):.2f}", flush=True)
            print("  ** Full population will be vmapped across GPU **", flush=True)

            # Vectorized scoring: vmap over batch dimension
            def scoring_fn(genotypes, random_key):
                batch = genotypes.shape[0]
                keys = jrandom.split(random_key, batch)
                curriculum_stage = 0  # updated per iteration below
                fit, desc = jax.vmap(
                    lambda p, k: _eval_single(p, k, curriculum_stage)
                )(genotypes, keys)
                return fit, desc, {}

            # With curriculum: rebuild scoring_fn per stage
            def make_scoring_fn(stage):
                def scoring_fn(genotypes, random_key):
                    batch = genotypes.shape[0]
                    keys = jrandom.split(random_key, batch)
                    fit, desc = jax.vmap(
                        lambda p, k: _eval_single(p, k, stage)
                    )(genotypes, keys)
                    return fit, desc, {}
                return scoring_fn

        except Exception as e:
            print(f"  JAX-native compilation failed: {e}", flush=True)
            print("  Falling back to pure_callback (CPU eval)...", flush=True)
            use_jax_native = False

    if not use_jax_native:
        # Fallback: numpy eval via pure_callback (original approach)
        def _eval_batch_np(genotypes_np):
            batch = genotypes_np.shape[0]
            fitnesses = np.zeros(batch, dtype=np.float32)
            descriptors = np.zeros((batch, 4), dtype=np.float32)
            for i in range(batch):
                f, d = evaluate_creature(genotypes_np[i], species_name, rng_seed=seed + i)
                fitnesses[i] = f
                descriptors[i] = d
            return fitnesses, descriptors

        def scoring_fn(genotypes, random_key):
            fit, desc = jax.pure_callback(
                lambda g: _eval_batch_np(np.asarray(g)),
                (jnp.zeros(genotypes.shape[0]), jnp.zeros((genotypes.shape[0], 4))),
                genotypes,
            )
            return fit, desc, {}

        def make_scoring_fn(stage):
            return scoring_fn

    # Emitter: isoline variation (Next-Gen: Higher sigma for better exploration)
    variation_fn = functools.partial(
        isoline_variation,
        iso_sigma=0.08,
        line_sigma=0.2,
    )

    emitter = MixingEmitter(
        mutation_fn=lambda x, y: (x, y),
        variation_fn=variation_fn,
        variation_percentage=1.0,
        batch_size=pop_size,
    )

    metrics_fn = functools.partial(default_qd_metrics, qd_offset=0.0)

    # Build initial MAP-Elites with stage 0 scoring
    initial_scoring = make_scoring_fn(0) if use_curriculum else scoring_fn

    map_elites = MAPElites(
        scoring_function=initial_scoring,
        emitter=emitter,
        metrics_function=metrics_fn,
    )

    # Centroids for 4D behavior grid
    centroids = compute_euclidean_centroids(
        grid_shape=gs,
        minval=jnp.array([b[0] for b in cfg["behavior_bounds"]]),
        maxval=jnp.array([b[1] for b in cfg["behavior_bounds"]]),
    )

    # Initialize
    key, subkey = jrandom.split(key)
    init_genotypes = jrandom.normal(subkey, shape=(pop_size, n_params)) * 0.5

    key, subkey = jrandom.split(key)
    repertoire, emitter_state, metrics = map_elites.init(
        init_genotypes, centroids, subkey
    )

    # Run
    start = time.time()
    current_stage = 0
    update_fn = jax.jit(map_elites.update)

    for i in range(iterations):
        # Curriculum: check if we need to advance stage
        if use_curriculum:
            new_stage = get_curriculum_stage(i, iterations)
            if new_stage != current_stage:
                current_stage = new_stage
                stage_info = CURRICULUM_STAGES[current_stage]
                print(f"\n  >> CURRICULUM STAGE {current_stage}: {stage_info['label']}", flush=True)
                # Rebuild MAP-Elites with new scoring function
                new_scoring = make_scoring_fn(current_stage)
                map_elites = MAPElites(
                    scoring_function=new_scoring,
                    emitter=emitter,
                    metrics_function=metrics_fn,
                )
                update_fn = jax.jit(map_elites.update)

        key, subkey = jrandom.split(key)
        repertoire, emitter_state, metrics = update_fn(
            repertoire, emitter_state, subkey
        )

        if i % 25 == 0 or i == iterations - 1:
            if i % 50 == 0 or i == iterations - 1:
                ckpt_dir = Path(__file__).parent / "trained_genomes"
                ckpt_dir.mkdir(parents=True, exist_ok=True)
                np.savez_compressed(
                    ckpt_dir / f"{species_name}_qdax_checkpoint.npz",
                    genotypes=np.array(repertoire.genotypes),
                    fitnesses=np.array(repertoire.fitnesses),
                    descriptors=np.array(repertoire.descriptors),
                )

            filled = int(jnp.sum(repertoire.fitnesses > -jnp.inf))
            max_fit = float(jnp.max(jnp.where(
                repertoire.fitnesses > -jnp.inf,
                repertoire.fitnesses,
                -jnp.inf
            )))
            mean_fit = float(jnp.mean(jnp.where(
                repertoire.fitnesses > -jnp.inf,
                repertoire.fitnesses,
                0.0
            )))
            elapsed = time.time() - start
            total_niches = int(np.prod(gs))
            coverage = filled / total_niches * 100
            stage_str = f"  stg={current_stage}" if use_curriculum else ""
            print(f"  Iter {i:4d}/{iterations}  "
                  f"filled={filled}/{total_niches} ({coverage:.0f}%)  "
                  f"best={max_fit:.1f}  avg={mean_fit:.1f}  "
                  f"({elapsed:.0f}s){stage_str}", flush=True)

    total_time = time.time() - start
    filled = int(jnp.sum(repertoire.fitnesses > -jnp.inf))
    total_niches = int(np.prod(gs))

    print(f"\n  Completed in {total_time:.1f}s", flush=True)
    print(f"  Archive: {filled}/{total_niches} niches filled ({filled/total_niches*100:.0f}%)", flush=True)

    return repertoire, n_params


# ---------------------------------------------------------------------------
# pyribs fallback (CPU)
# ---------------------------------------------------------------------------

def train_pyribs(species_name, iterations=500, grid_shape=None, seed=42, use_curriculum=False):
    """Train using pyribs MAP-Elites on CPU."""
    cfg = SPECIES[species_name]
    n_in, n_out = cfg["n_inputs"], cfg["n_outputs"]
    n_hidden = 8
    n_params = n_in * n_hidden + n_hidden + n_hidden * n_out + n_out
    gs = grid_shape or cfg["grid_shape"]

    print(f"\n{'='*60}", flush=True)
    print(f"  pyribs MAP-Elites (CPU): {species_name}", flush=True)
    print(f"  Network: {n_in} -> {n_hidden} -> {n_out} ({n_params} params)", flush=True)
    print(f"  Grid: {'x'.join(map(str, gs))} = {int(np.prod(gs))} niches (4D)", flush=True)
    print(f"{'='*60}\n", flush=True)

    archive = GridArchive(
        solution_dim=n_params,
        dims=gs,
        ranges=cfg["behavior_bounds"],
        seed=seed,
    )

    emitter = EvolutionStrategyEmitter(
        archive=archive,
        x0=np.zeros(n_params),
        sigma0=0.5,
        batch_size=64,
        seed=seed,
    )

    scheduler = Scheduler(archive, [emitter])

    start = time.time()
    for i in range(iterations):
        solutions = scheduler.ask()

        fitnesses = []
        descriptors = []
        for sol in solutions:
            f, d = evaluate_creature(sol, species_name, rng_seed=seed + i)
            fitnesses.append(f)
            descriptors.append(d)

        scheduler.tell(fitnesses, descriptors)

        if i % 25 == 0 or i == iterations - 1:
            elapsed = time.time() - start
            stats = archive.stats
            print(f"  Iter {i:4d}/{iterations}  "
                  f"filled={stats.num_elites}  "
                  f"best={stats.obj_max:.1f}  "
                  f"avg={stats.obj_mean:.1f}  "
                  f"({elapsed:.0f}s)", flush=True)

    total_time = time.time() - start
    print(f"\n  Completed in {total_time:.1f}s", flush=True)
    print(f"  Archive: {archive.stats.num_elites} niches filled", flush=True)

    return archive, n_params


# ---------------------------------------------------------------------------
# Export to Dart-compatible genome format
# ---------------------------------------------------------------------------

def params_to_dart_genome(params, n_inputs, n_outputs, fitness=0.0):
    """Convert flat parameter vector to Dart NeatGenome-compatible JSON."""
    params = np.asarray(params).flatten()
    fitness = float(np.asarray(fitness).item()) if not isinstance(fitness, (int, float)) else float(fitness)
    n_hidden = 8
    nodes = []
    connections = []

    nodes.append({"id": 0, "type": 0, "activation": 1, "layer": 0})  # bias

    for i in range(n_inputs):
        nodes.append({"id": i + 1, "type": 1, "activation": 1, "layer": 0})

    for i in range(n_hidden):
        nodes.append({"id": n_inputs + 1 + i, "type": 3, "activation": 1, "layer": 1})

    for i in range(n_outputs):
        nodes.append({"id": n_inputs + 1 + n_hidden + i, "type": 2, "activation": 1, "layer": 2})

    innov = 0
    idx = 0
    for i in range(n_inputs):
        for h in range(n_hidden):
            w = float(params[idx]) if idx < len(params) else 0.0
            connections.append({
                "innovation": innov,
                "inNode": i + 1,
                "outNode": n_inputs + 1 + h,
                "weight": w,
                "enabled": True,
            })
            innov += 1
            idx += 1

    for h in range(n_hidden):
        w = float(params[idx]) if idx < len(params) else 0.0
        connections.append({
            "innovation": innov,
            "inNode": 0,
            "outNode": n_inputs + 1 + h,
            "weight": w,
            "enabled": True,
        })
        innov += 1
        idx += 1

    for h in range(n_hidden):
        for o in range(n_outputs):
            w = float(params[idx]) if idx < len(params) else 0.0
            connections.append({
                "innovation": innov,
                "inNode": n_inputs + 1 + h,
                "outNode": n_inputs + 1 + n_hidden + o,
                "weight": w,
                "enabled": True,
            })
            innov += 1
            idx += 1

    for o in range(n_outputs):
        w = float(params[idx]) if idx < len(params) else 0.0
        connections.append({
            "innovation": innov,
            "inNode": 0,
            "outNode": n_inputs + 1 + n_hidden + o,
            "weight": w,
            "enabled": True,
        })
        innov += 1
        idx += 1

    return {
        "nodes": nodes,
        "connections": connections,
        "fitness": float(fitness),
        "speciesId": -1,
    }


# ---------------------------------------------------------------------------
# Archive visualization (HTML heatmap)
# ---------------------------------------------------------------------------

def generate_archive_visualization(species_name, fitnesses, descriptors, labels, bounds):
    """Generate an HTML visualization of the 4D behavioral archive.

    Projects the 4D archive into 6 pairwise 2D heatmaps.
    """
    out_dir = Path(__file__).parent / "trained_genomes"
    out_dir.mkdir(parents=True, exist_ok=True)

    try:
        fitnesses = np.asarray(fitnesses).flatten()
        descriptors = np.asarray(descriptors)
        if descriptors.ndim > 2:
            descriptors = descriptors.reshape(-1, descriptors.shape[-1])
        valid_mask = fitnesses > -np.inf
        valid_fit = fitnesses[valid_mask]
        valid_desc = descriptors[valid_mask]
    except Exception as e:
        print(f"  Viz data reshape failed: {e}", flush=True)
        return

    if len(valid_fit) == 0:
        print("  No valid entries for visualization", flush=True)
        return

    # Generate 6 pairwise projections of the 4D space
    pairs = [(0,1), (0,2), (0,3), (1,2), (1,3), (2,3)]
    n_bins = 20

    html = f"""<!DOCTYPE html>
<html>
<head>
<title>{species_name} Behavioral Archive</title>
<style>
body {{ font-family: monospace; background: #1a1a2e; color: #eee; padding: 20px; }}
h1 {{ color: #e94560; }}
h2 {{ color: #16213e; background: #e94560; padding: 8px; display: inline-block; }}
.grid-container {{ display: flex; flex-wrap: wrap; gap: 30px; }}
.heatmap {{ position: relative; }}
.heatmap canvas {{ border: 1px solid #333; }}
.stats {{ background: #16213e; padding: 15px; border-radius: 8px; margin: 15px 0; }}
.stats span {{ margin-right: 30px; }}
</style>
</head>
<body>
<h1>{species_name.upper()} - Behavioral Archive</h1>
<div class="stats">
    <span>Filled niches: {len(valid_fit)}</span>
    <span>Best fitness: {float(np.max(valid_fit)):.1f}</span>
    <span>Mean fitness: {float(np.mean(valid_fit)):.1f}</span>
    <span>Descriptors: {', '.join(labels)}</span>
</div>
<div class="grid-container">
"""

    for pair_idx, (d1, d2) in enumerate(pairs):
        # Bin the data
        bins = np.zeros((n_bins, n_bins))
        counts = np.zeros((n_bins, n_bins))
        for i in range(len(valid_fit)):
            bx = min(int(valid_desc[i, d1] * n_bins), n_bins - 1)
            by = min(int(valid_desc[i, d2] * n_bins), n_bins - 1)
            if valid_fit[i] > bins[by, bx]:
                bins[by, bx] = valid_fit[i]
            counts[by, bx] += 1

        # Normalize bins for color
        max_val = np.max(bins) if np.max(bins) > 0 else 1.0

        html += f"""
<div class="heatmap">
    <h2>{labels[d1]} vs {labels[d2]}</h2><br>
    <canvas id="canvas_{pair_idx}" width="300" height="300"></canvas>
    <script>
    (function() {{
        var c = document.getElementById('canvas_{pair_idx}');
        var ctx = c.getContext('2d');
        var data = {json.dumps(bins.tolist())};
        var maxVal = {max_val};
        var cellW = 300 / {n_bins};
        var cellH = 300 / {n_bins};
        for (var y = 0; y < {n_bins}; y++) {{
            for (var x = 0; x < {n_bins}; x++) {{
                var v = data[y][x] / maxVal;
                if (v > 0) {{
                    var r = Math.floor(233 * v);
                    var g = Math.floor(69 * (1-v) + 96 * v);
                    var b = Math.floor(96 * (1-v));
                    ctx.fillStyle = 'rgb(' + r + ',' + g + ',' + b + ')';
                }} else {{
                    ctx.fillStyle = '#0f3460';
                }}
                ctx.fillRect(x * cellW, ({n_bins} - 1 - y) * cellH, cellW, cellH);
            }}
        }}
        // Axis labels
        ctx.fillStyle = '#eee';
        ctx.font = '11px monospace';
        ctx.fillText('{labels[d1]}', 5, 295);
        ctx.save();
        ctx.translate(12, 150);
        ctx.rotate(-Math.PI/2);
        ctx.fillText('{labels[d2]}', 0, 0);
        ctx.restore();
    }})();
    </script>
</div>
"""

    html += """
</div>
<p style="margin-top: 30px; color: #666;">
    Generated by qdax_creature_trainer.py | Color: dark blue = empty, red = high fitness
</p>
</body>
</html>"""

    viz_path = out_dir / f"{species_name}_qdax_archive_viz.html"
    with open(viz_path, "w") as f:
        f.write(html)
    print(f"  Archive visualization -> {viz_path.name}", flush=True)


def export_archive(repertoire_or_archive, species_name, n_params, backend="qdax"):
    """Export diverse genomes from the archive to Dart-compatible JSON."""
    cfg = SPECIES[species_name]
    out_dir = Path(__file__).parent / "trained_genomes"
    out_dir.mkdir(parents=True, exist_ok=True)

    if backend == "qdax":
        fitnesses = np.array(repertoire_or_archive.fitnesses)
        genotypes = np.array(repertoire_or_archive.genotypes)
        descriptors = np.array(repertoire_or_archive.descriptors)

        valid_mask = fitnesses > -np.inf
        valid_indices = np.where(valid_mask)[0]
        valid_fitnesses = fitnesses[valid_indices]
        valid_genotypes = genotypes[valid_indices]
        valid_descriptors = descriptors[valid_indices]
    else:
        archive = repertoire_or_archive
        df = archive.as_pandas()
        valid_fitnesses = df["objective"].values
        valid_genotypes = df[[f"solution_{i}" for i in range(n_params)]].values
        bd_cols = [c for c in df.columns if c.startswith("measure_")]
        valid_descriptors = df[bd_cols].values if bd_cols else np.zeros((len(df), 4))
        valid_indices = np.arange(len(df))

    n_valid = len(valid_indices)
    print(f"\n  Exporting {n_valid} genomes from archive...", flush=True)

    # 1. Champion
    best_idx = np.argmax(valid_fitnesses)
    best_fit = float(np.asarray(valid_fitnesses[best_idx]).item())
    champion = params_to_dart_genome(
        valid_genotypes[best_idx], cfg["n_inputs"], cfg["n_outputs"],
        best_fit
    )
    best_path = out_dir / f"{species_name}_qdax_best.json"
    with open(best_path, "w") as f:
        json.dump(champion, f, indent=2)
    print(f"  Champion: fitness={best_fit:.1f} -> {best_path.name}", flush=True)

    # 2. Diverse top 20
    diverse_count = min(20, n_valid)
    if n_valid <= diverse_count:
        diverse_indices = list(range(n_valid))
    else:
        selected = [best_idx]
        for _ in range(diverse_count - 1):
            max_dist = -1
            max_idx = 0
            for i in range(n_valid):
                if i in selected:
                    continue
                min_dist = min(
                    np.sum((valid_descriptors[i] - valid_descriptors[s]) ** 2)
                    for s in selected
                )
                if min_dist > max_dist:
                    max_dist = min_dist
                    max_idx = i
            selected.append(max_idx)
        diverse_indices = selected

    diverse_genomes = []
    for i in diverse_indices:
        genome = params_to_dart_genome(
            valid_genotypes[i], cfg["n_inputs"], cfg["n_outputs"],
            float(np.asarray(valid_fitnesses[i]).item())
        )
        genome["behavior"] = [float(np.asarray(v).item()) for v in valid_descriptors[i]]
        genome["behavior_labels"] = cfg["behavior_labels"]
        diverse_genomes.append(genome)

    diverse_path = out_dir / f"{species_name}_qdax_diverse20.json"
    with open(diverse_path, "w") as f:
        json.dump(diverse_genomes, f)
    fit_range = [float(np.asarray(valid_fitnesses[i]).item()) for i in diverse_indices]
    print(f"  Diverse 20: fitness {min(fit_range):.1f}-{max(fit_range):.1f} -> {diverse_path.name}", flush=True)

    # 3. Full archive
    all_genomes = []
    for i in range(n_valid):
        genome = params_to_dart_genome(
            valid_genotypes[i], cfg["n_inputs"], cfg["n_outputs"],
            float(np.asarray(valid_fitnesses[i]).item())
        )
        genome["behavior"] = [float(np.asarray(d).item()) for d in valid_descriptors[i]]
        genome["behavior_labels"] = cfg["behavior_labels"]
        genome["niche_id"] = int(valid_indices[i])
        all_genomes.append(genome)

    full_path = out_dir / f"{species_name}_qdax_full_archive.json"
    with open(full_path, "w") as f:
        json.dump(all_genomes, f)
    print(f"  Full archive: {len(all_genomes)} genomes -> {full_path.name}", flush=True)

    # 4. Archive metadata
    archive_meta = {
        "species": species_name,
        "total_niches": int(np.prod(cfg["grid_shape"])),
        "filled_niches": n_valid,
        "coverage": n_valid / np.prod(cfg["grid_shape"]),
        "best_fitness": float(np.asarray(np.max(valid_fitnesses)).item()),
        "mean_fitness": float(np.asarray(np.mean(valid_fitnesses)).item()),
        "behavior_labels": cfg["behavior_labels"],
        "behavior_bounds": cfg["behavior_bounds"],
        "behavior_dims": 4,
        "n_params": n_params,
    }
    meta_path = out_dir / f"{species_name}_qdax_archive.json"
    with open(meta_path, "w") as f:
        json.dump(archive_meta, f, indent=2)
    print(f"  Archive meta -> {meta_path.name}", flush=True)

    # 5. Archive visualization
    generate_archive_visualization(
        species_name, fitnesses if backend == "qdax" else valid_fitnesses,
        descriptors if backend == "qdax" else valid_descriptors,
        cfg["behavior_labels"], cfg["behavior_bounds"]
    )

    return n_valid


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="QDax quality-diversity creature training"
    )
    parser.add_argument("--species", default="worm",
                        help="Species to train (or 'all')")
    parser.add_argument("--iterations", type=int, default=300,
                        help="MAP-Elites iterations")
    parser.add_argument("--grid", nargs='+', type=int, default=None,
                        help="Behavior grid shape (e.g., --grid 8 8 8 8)")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--curriculum", action="store_true",
                        help="Enable curriculum learning (progressive difficulty)")
    args = parser.parse_args()

    grid_shape = tuple(args.grid) if args.grid else None

    if args.species == "all":
        species_list = list(SPECIES.keys())
    elif args.species in SPECIES:
        species_list = [args.species]
    else:
        print(f"Unknown species: {args.species}")
        print(f"Available: {', '.join(SPECIES.keys())}")
        sys.exit(1)

    print(f"\n{'='*60}", flush=True)
    print(f"  QDax QUALITY-DIVERSITY CREATURE TRAINING v2", flush=True)
    print(f"  Backend: {'QDax (GPU)' if HAS_QDAX else 'pyribs (CPU)' if HAS_PYRIBS else 'NONE'}", flush=True)
    print(f"  Species: {', '.join(species_list)}", flush=True)
    print(f"  Iterations: {args.iterations}", flush=True)
    print(f"  Curriculum: {'ENABLED' if args.curriculum else 'disabled'}", flush=True)
    print(f"  Descriptors: 4D (env_mod, social, temporal, resource)", flush=True)
    print(f"{'='*60}", flush=True)

    total_start = time.time()
    results = {}

    for sp in species_list:
        if HAS_QDAX:
            repertoire, n_params = train_qdax(sp, args.iterations, grid_shape, args.seed, args.curriculum)
            n_exported = export_archive(repertoire, sp, n_params, "qdax")
        elif HAS_PYRIBS:
            archive, n_params = train_pyribs(sp, args.iterations, grid_shape, args.seed, args.curriculum)
            n_exported = export_archive(archive, sp, n_params, "pyribs")
        else:
            print(f"  SKIP {sp}: no QD library available", flush=True)
            continue

        results[sp] = n_exported

    total = time.time() - total_start
    print(f"\n{'='*60}", flush=True)
    print(f"  TRAINING COMPLETE in {total:.0f}s ({total/60:.1f} min)", flush=True)
    print(f"{'='*60}", flush=True)
    for sp, n in results.items():
        print(f"  {sp:12s}: {n} diverse genomes exported", flush=True)
    print(flush=True)


if __name__ == "__main__":
    main()
