#!/usr/bin/env python3
"""GPU-accelerated multi-species NEAT creature training for The Particle Engine.

Uses TensorNEAT (JAX-based) to evolve creature brains on GPU, then exports
trained genomes as JSON compatible with our Dart NeatGenome.fromJson().

Supports 7 species with 4 training modes:
  1. Individual training  — each species in its optimal environment
  2. Predator-prey co-training — beetle/spider arms race
  3. Ecosystem co-evolution — all species in one shared world
  4. Curriculum training — progressive difficulty per species

Usage:
    python creature_trainer.py --species worm --generations 200
    python creature_trainer.py --species all --generations 500
    python creature_trainer.py --coevolve beetle,spider --generations 300
    python creature_trainer.py --ecosystem --generations 200
    python creature_trainer.py --curriculum ant --stages 4

Output:
    research/cloud/trained_genomes/{species}_best.json
    research/cloud/trained_genomes/{species}_population.json
    research/cloud/trained_genomes/ecosystem_best.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np

# ---------------------------------------------------------------------------
# Try importing JAX/TensorNEAT -- fall back gracefully
# ---------------------------------------------------------------------------
try:
    import jax
    import jax.numpy as jnp
    from jax import random as jrandom
    HAS_JAX = True
except ImportError:
    HAS_JAX = False

try:
    from tensorneat.pipeline import Pipeline
    from tensorneat.algorithm.neat import NEAT
    from tensorneat.genome import DefaultGenome, BiasNode
    from tensorneat.common import ACT, AGG
    HAS_TENSORNEAT = True
except ImportError:
    HAS_TENSORNEAT = False

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = SCRIPT_DIR / "trained_genomes"

# ---------------------------------------------------------------------------
# Species configurations — all 7 species
# ---------------------------------------------------------------------------

SPECIES_CONFIGS = {
    "worm": {
        "inputs": 10,
        "outputs": 4,
        "description": "Worm: composting, dirt aeration, underground navigation",
        "population": 300,
        "max_hidden": 8,
        "max_connections": 50,
        "generations": 200,
        "grid_size": 64,
        "env_type": "worm_world",
        "predator_of": [],
        "prey_of": ["spider"],
    },
    "beetle": {
        "inputs": 12,
        "outputs": 6,
        "description": "Beetle: foraging plants/seeds, evading spider predators",
        "population": 400,
        "max_hidden": 15,
        "max_connections": 80,
        "generations": 300,
        "grid_size": 64,
        "env_type": "beetle_world",
        "predator_of": [],
        "prey_of": ["spider"],
    },
    "spider": {
        "inputs": 14,
        "outputs": 7,
        "description": "Spider: web building, ambush predation, prey consumption",
        "population": 400,
        "max_hidden": 20,
        "max_connections": 100,
        "generations": 300,
        "grid_size": 64,
        "env_type": "spider_world",
        "predator_of": ["beetle", "worm"],
        "prey_of": [],
    },
    "fish": {
        "inputs": 12,
        "outputs": 5,
        "description": "Fish: algae feeding, schooling behavior, aquatic navigation",
        "population": 400,
        "max_hidden": 15,
        "max_connections": 80,
        "generations": 300,
        "grid_size": 64,
        "env_type": "fish_world",
        "predator_of": [],
        "prey_of": [],
    },
    "bee": {
        "inputs": 14,
        "outputs": 7,
        "description": "Bee: pollination, honey production, seed dispersal",
        "population": 500,
        "max_hidden": 20,
        "max_connections": 100,
        "generations": 400,
        "grid_size": 64,
        "env_type": "bee_world",
        "predator_of": [],
        "prey_of": ["spider"],
    },
    "firefly": {
        "inputs": 10,
        "outputs": 4,
        "description": "Firefly: bioluminescent synchronization, nighttime survival",
        "population": 300,
        "max_hidden": 8,
        "max_connections": 50,
        "generations": 200,
        "grid_size": 64,
        "env_type": "firefly_world",
        "predator_of": [],
        "prey_of": ["spider"],
    },
    "ant": {
        "inputs": 8,
        "outputs": 6,
        "description": "Ant: foraging, pheromone navigation, colony cooperation",
        "population": 500,
        "max_hidden": 20,
        "max_connections": 100,
        "generations": 500,
        "grid_size": 80,
        "env_type": "ant_world",
        "predator_of": [],
        "prey_of": ["spider"],
    },
}

# ---------------------------------------------------------------------------
# Element constants matching Dart El class
# ---------------------------------------------------------------------------
EL_EMPTY = 0
EL_SAND = 1
EL_WATER = 2
EL_STONE = 3
EL_DIRT = 4
EL_SEED = 5
EL_PLANT = 6
EL_FIRE = 7
EL_WOOD = 8
EL_LAVA = 9
EL_COMPOST = 10  # treated as organic matter for worms
EL_SMOKE = 11
EL_ACID = 14
EL_METHANE = 20
EL_CO2 = 22      # suffocation hazard in enclosed spaces

# Hazardous elements that creatures should avoid
TOXIC_ELEMENTS = {EL_ACID, EL_LAVA, EL_FIRE}
GAS_HAZARDS = {EL_SMOKE, EL_METHANE, EL_CO2}
ALL_HAZARDS = TOXIC_ELEMENTS | GAS_HAZARDS


# ===================================================================
# ENVIRONMENT GENERATORS — NumPy-based simplified physics grids
# ===================================================================

def make_worm_world(rng: np.random.Generator, size: int = 64) -> dict:
    """64x64 grid: bottom 50% dirt/compost, surface water hazard."""
    grid = np.full((size, size), EL_EMPTY, dtype=np.uint8)
    surface_y = size // 2
    # Fill underground with dirt
    grid[surface_y:, :] = EL_DIRT
    # Scatter compost throughout underground
    compost_mask = rng.random((size - surface_y, size)) < 0.12
    grid[surface_y:, :][compost_mask] = EL_COMPOST
    # Surface water hazard (thin layer)
    water_patches = rng.integers(0, size, size=(3, 2))
    for px, pw in water_patches:
        w = rng.integers(4, 12)
        grid[surface_y - 1, max(0, px):min(size, px + w)] = EL_WATER
    return {
        "grid": grid,
        "spawn_zone": (size // 4, surface_y + 2, 3 * size // 4, size - 2),
        "food_element": EL_COMPOST,
    }


def make_beetle_world(rng: np.random.Generator, size: int = 64) -> dict:
    """64x64 surface with plants/seeds, spider predator zones."""
    grid = np.full((size, size), EL_EMPTY, dtype=np.uint8)
    ground_y = int(size * 0.75)
    grid[ground_y:, :] = EL_DIRT
    # Surface plants
    n_plants = rng.integers(10, 20)
    for _ in range(n_plants):
        px = rng.integers(0, size)
        h = rng.integers(2, 6)
        for dy in range(h):
            if ground_y - 1 - dy >= 0:
                grid[ground_y - 1 - dy, px] = EL_PLANT
    # Scatter seeds
    n_seeds = rng.integers(15, 30)
    for _ in range(n_seeds):
        sx = rng.integers(0, size)
        grid[ground_y - 1, sx] = EL_SEED
    # Spider danger zones (marked as stone patches = hiding spots)
    n_danger = rng.integers(2, 5)
    danger_zones = []
    for _ in range(n_danger):
        dx = rng.integers(0, size)
        danger_zones.append((dx, ground_y - 2))
        grid[ground_y - 2, dx] = EL_STONE
    return {
        "grid": grid,
        "spawn_zone": (0, ground_y - 3, size, ground_y - 1),
        "food_element": EL_SEED,
        "danger_zones": danger_zones,
    }


def make_spider_world(rng: np.random.Generator, size: int = 64) -> dict:
    """64x64 with caves/dark areas, beetle prey wandering."""
    grid = np.full((size, size), EL_EMPTY, dtype=np.uint8)
    ground_y = int(size * 0.6)
    grid[ground_y:, :] = EL_STONE
    # Carve caves
    n_caves = rng.integers(3, 7)
    for _ in range(n_caves):
        cx = rng.integers(5, size - 5)
        cy = rng.integers(ground_y + 2, size - 5)
        rw = rng.integers(3, 8)
        rh = rng.integers(2, 5)
        y_lo = max(ground_y, cy - rh)
        y_hi = min(size, cy + rh)
        x_lo = max(0, cx - rw)
        x_hi = min(size, cx + rw)
        grid[y_lo:y_hi, x_lo:x_hi] = EL_EMPTY
    # Some wood structures for web anchors
    n_wood = rng.integers(4, 10)
    for _ in range(n_wood):
        wx = rng.integers(2, size - 2)
        wy = rng.integers(ground_y - 5, ground_y)
        grid[wy, wx] = EL_WOOD
    return {
        "grid": grid,
        "spawn_zone": (2, ground_y - 8, size - 2, ground_y - 1),
        "food_element": EL_EMPTY,  # spiders eat prey, not elements
    }


def make_fish_world(rng: np.random.Generator, size: int = 64) -> dict:
    """64x64, 60% water body, algae patches."""
    grid = np.full((size, size), EL_EMPTY, dtype=np.uint8)
    water_top = int(size * 0.2)
    water_bottom = int(size * 0.85)
    grid[water_top:water_bottom, :] = EL_WATER
    # Bottom sediment
    grid[water_bottom:, :] = EL_SAND
    # Algae patches (using plant element)
    n_algae = rng.integers(10, 25)
    for _ in range(n_algae):
        ax = rng.integers(0, size)
        ay = rng.integers(water_top + 2, water_bottom - 2)
        for dx in range(-1, 2):
            for dy in range(-1, 2):
                nx, ny = ax + dx, ay + dy
                if 0 <= nx < size and water_top <= ny < water_bottom:
                    if rng.random() < 0.6:
                        grid[ny, nx] = EL_PLANT
    return {
        "grid": grid,
        "spawn_zone": (5, water_top + 3, size - 5, water_bottom - 3),
        "food_element": EL_PLANT,  # algae
        "water_bounds": (water_top, water_bottom),
    }


def make_bee_world(rng: np.random.Generator, size: int = 64) -> dict:
    """64x64 surface with plant clusters, hive location."""
    grid = np.full((size, size), EL_EMPTY, dtype=np.uint8)
    ground_y = int(size * 0.8)
    grid[ground_y:, :] = EL_DIRT
    # Plant clusters for pollination
    n_clusters = rng.integers(5, 10)
    plant_positions = []
    for _ in range(n_clusters):
        cx = rng.integers(5, size - 5)
        n_plants = rng.integers(3, 8)
        for p in range(n_plants):
            px = cx + rng.integers(-3, 4)
            px = max(0, min(size - 1, px))
            h = rng.integers(2, 5)
            for dy in range(h):
                y = ground_y - 1 - dy
                if y >= 0:
                    grid[y, px] = EL_PLANT
                    plant_positions.append((px, y))
    # Hive location (upper area)
    hive_x = size // 2
    hive_y = size // 4
    grid[hive_y, hive_x] = EL_WOOD
    grid[hive_y, hive_x - 1] = EL_WOOD
    grid[hive_y, hive_x + 1] = EL_WOOD
    grid[hive_y - 1, hive_x] = EL_WOOD
    return {
        "grid": grid,
        "spawn_zone": (hive_x - 5, hive_y - 3, hive_x + 5, hive_y + 3),
        "food_element": EL_PLANT,
        "hive_pos": (hive_x, hive_y),
        "plant_positions": plant_positions,
    }


def make_firefly_world(rng: np.random.Generator, size: int = 64) -> dict:
    """64x64 nighttime, scattered compost/spore food."""
    grid = np.full((size, size), EL_EMPTY, dtype=np.uint8)
    ground_y = int(size * 0.7)
    grid[ground_y:, :] = EL_DIRT
    # Scattered food (compost/seeds)
    n_food = rng.integers(15, 30)
    for _ in range(n_food):
        fx = rng.integers(0, size)
        fy = rng.integers(ground_y - 5, ground_y)
        if 0 <= fy < size:
            grid[fy, fx] = EL_COMPOST if rng.random() < 0.5 else EL_SEED
    return {
        "grid": grid,
        "spawn_zone": (5, ground_y - 15, size - 5, ground_y - 2),
        "food_element": EL_COMPOST,
    }


def make_ant_world(rng: np.random.Generator, size: int = 80) -> dict:
    """80x80 with nest, scattered food, varied terrain."""
    grid = np.full((size, size), EL_EMPTY, dtype=np.uint8)
    ground_y = int(size * 0.65)
    grid[ground_y:, :] = EL_DIRT
    # Nest entrance
    nest_x = size // 2
    nest_y = ground_y - 1
    # Scatter food
    n_food = rng.integers(15, 30)
    food_positions = []
    for _ in range(n_food):
        fx = rng.integers(0, size)
        fy = rng.integers(ground_y - 4, ground_y)
        if 0 <= fy < size:
            grid[fy, fx] = EL_SEED
            food_positions.append((fx, fy))
    # Some obstacles
    n_stones = rng.integers(3, 8)
    for _ in range(n_stones):
        sx = rng.integers(0, size)
        grid[ground_y - 1, sx] = EL_STONE
    return {
        "grid": grid,
        "spawn_zone": (nest_x - 3, nest_y - 2, nest_x + 3, nest_y),
        "food_element": EL_SEED,
        "nest_pos": (nest_x, nest_y),
        "food_positions": food_positions,
    }


def make_ecosystem_world(rng: np.random.Generator, size: int = 128) -> dict:
    """128x128 full terrain with zones for all species."""
    grid = np.full((size, size), EL_EMPTY, dtype=np.uint8)
    # Ground level with varied terrain
    ground_y = int(size * 0.6)
    grid[ground_y:, :] = EL_DIRT
    # Water body (left side)
    water_left = 5
    water_right = size // 3
    water_top = int(size * 0.3)
    grid[water_top:ground_y, water_left:water_right] = EL_WATER
    grid[ground_y:ground_y + 5, water_left:water_right] = EL_SAND
    # Algae in water
    for _ in range(20):
        ax = rng.integers(water_left + 2, water_right - 2)
        ay = rng.integers(water_top + 2, ground_y - 2)
        grid[ay, ax] = EL_PLANT
    # Cave system (underground)
    for _ in range(5):
        cx = rng.integers(10, size - 10)
        cy = rng.integers(ground_y + 5, size - 5)
        rw = rng.integers(4, 10)
        rh = rng.integers(3, 6)
        grid[max(ground_y, cy - rh):min(size, cy + rh),
             max(0, cx - rw):min(size, cx + rw)] = EL_EMPTY
    # Surface plants
    for _ in range(30):
        px = rng.integers(water_right + 5, size - 5)
        h = rng.integers(2, 6)
        for dy in range(h):
            if ground_y - 1 - dy >= 0:
                grid[ground_y - 1 - dy, px] = EL_PLANT
    # Seeds
    for _ in range(40):
        sx = rng.integers(0, size)
        grid[ground_y - 1, sx] = EL_SEED
    # Compost underground
    compost_mask = rng.random((size - ground_y, size)) < 0.08
    dirt_region = grid[ground_y:, :]
    dirt_region[compost_mask & (dirt_region == EL_DIRT)] = EL_COMPOST
    # Hive location
    hive_x = int(size * 0.7)
    hive_y = int(size * 0.25)
    grid[hive_y, hive_x] = EL_WOOD
    grid[hive_y, hive_x - 1] = EL_WOOD
    grid[hive_y, hive_x + 1] = EL_WOOD

    return {
        "grid": grid,
        "ground_y": ground_y,
        "water_bounds": (water_top, ground_y, water_left, water_right),
        "hive_pos": (hive_x, hive_y),
        "nest_pos": (size // 2, ground_y - 1),
    }


ENV_BUILDERS = {
    "worm_world": make_worm_world,
    "beetle_world": make_beetle_world,
    "spider_world": make_spider_world,
    "fish_world": make_fish_world,
    "bee_world": make_bee_world,
    "firefly_world": make_firefly_world,
    "ant_world": make_ant_world,
}


# ===================================================================
# FITNESS FUNCTIONS — species-specific, NumPy-based
# ===================================================================

class CreatureState:
    """Mutable state for a single creature during evaluation."""
    __slots__ = (
        "x", "y", "energy", "alive", "age", "carrying", "carry_type",
        "food_collected", "food_delivered", "dirt_aerated", "compost_consumed",
        "prey_killed", "prey_consumed", "web_cells", "web_catches",
        "plants_pollinated", "honey_deposited", "seeds_carried",
        "offspring_count", "idle_ticks", "schooling_ticks",
        "sync_ticks", "evasions", "danger_ticks_no_flee",
        "phase", "last_flash",
        # --- New: gas/environment awareness ---
        "gas_exposure_ticks", "gas_evasions", "toxic_damage_taken",
        "temperature_sensed", "temp_comfort_ticks", "temp_danger_ticks",
        "total_energy_spent", "total_energy_gained",
    )

    def __init__(self, x: int, y: int, energy: float):
        self.x = x
        self.y = y
        self.energy = energy
        self.alive = True
        self.age = 0
        self.carrying = False
        self.carry_type = EL_EMPTY
        self.food_collected = 0
        self.food_delivered = 0
        self.dirt_aerated = 0
        self.compost_consumed = 0
        self.prey_killed = 0
        self.prey_consumed = 0
        self.web_cells: set[tuple[int, int]] = set()
        self.web_catches = 0
        self.plants_pollinated = 0
        self.honey_deposited = 0
        self.seeds_carried = 0
        self.offspring_count = 0
        self.idle_ticks = 0
        self.schooling_ticks = 0
        self.sync_ticks = 0
        self.evasions = 0
        self.danger_ticks_no_flee = 0
        self.phase = 0.0
        self.last_flash = 0
        # --- New: gas/environment awareness ---
        self.gas_exposure_ticks = 0
        self.gas_evasions = 0
        self.toxic_damage_taken = 0.0
        self.temperature_sensed = 0
        self.temp_comfort_ticks = 0
        self.temp_danger_ticks = 0
        self.total_energy_spent = 0.0
        self.total_energy_gained = 0.0


def _environmental_fitness_bonus(state: CreatureState) -> float:
    """Common environmental awareness bonus applied to all species.

    Rewards gas avoidance, temperature comfort, and resource efficiency.
    """
    bonus = 0.0

    # Gas avoidance: reward creatures that detect and evade toxic gases
    if state.gas_evasions > 0:
        bonus += 4.0 * state.gas_evasions
    # Penalize prolonged gas exposure (should have fled)
    bonus -= 1.0 * state.gas_exposure_ticks
    # Penalize toxic damage taken (should have avoided)
    bonus -= 2.0 * state.toxic_damage_taken

    # Temperature sensing: reward staying in comfort zone
    if state.temp_comfort_ticks > 0:
        bonus += 0.02 * state.temp_comfort_ticks
    # Penalize time in dangerous temperatures
    bonus -= 0.1 * state.temp_danger_ticks

    # Resource efficiency: ratio of energy gained to energy spent
    if state.total_energy_spent > 0:
        efficiency = state.total_energy_gained / state.total_energy_spent
        # Efficiency > 1.0 means net positive — reward proportionally
        if efficiency > 1.0:
            bonus += min(efficiency * 3.0, 15.0)
        elif efficiency > 0.5:
            bonus += efficiency * 1.0  # modest reward for break-even

    return bonus


def compute_fitness_worm(state: CreatureState) -> float:
    f = 0.0
    f += 5.0 * state.compost_consumed
    f += 2.0 * state.dirt_aerated
    f += 0.01 * state.age
    f += 8.0 * state.offspring_count
    f -= 0.05 * state.idle_ticks
    f += _environmental_fitness_bonus(state)
    return max(0.0, f)


def compute_fitness_beetle(state: CreatureState) -> float:
    f = 0.0
    f += 8.0 * state.food_collected  # plants/seeds consumed
    f += 3.0 * state.evasions        # predator evasion successes
    f += 15.0 * state.offspring_count
    f -= 2.0 * state.danger_ticks_no_flee
    f += _environmental_fitness_bonus(state)
    return max(0.0, f)


def compute_fitness_spider(state: CreatureState) -> float:
    f = 0.0
    f += 20.0 * state.prey_killed
    f += 12.0 * state.prey_consumed
    f += 3.0 * state.web_catches
    f += 25.0 * state.offspring_count
    f += _environmental_fitness_bonus(state)
    return max(0.0, f)


def compute_fitness_fish(state: CreatureState) -> float:
    f = 0.0
    f += 5.0 * state.food_collected   # algae consumed
    f += 0.5 * state.schooling_ticks
    f += 12.0 * state.offspring_count
    f += _environmental_fitness_bonus(state)
    return max(0.0, f)


def compute_fitness_bee(state: CreatureState) -> float:
    f = 0.0
    f += 3.0 * state.plants_pollinated
    f += 5.0 * state.honey_deposited
    f += 2.0 * state.seeds_carried
    f += 10.0 * state.offspring_count
    f += _environmental_fitness_bonus(state)
    return max(0.0, f)


def compute_fitness_firefly(state: CreatureState) -> float:
    f = 0.0
    f += 1.0 * state.sync_ticks
    f += 3.0 * state.food_collected
    f += 8.0 * state.offspring_count
    f += _environmental_fitness_bonus(state)
    return max(0.0, f)


def compute_fitness_ant(state: CreatureState) -> float:
    f = 0.0
    f += 10.0 * state.food_delivered   # food delivery is king
    f += 3.0 * state.food_collected    # finding food
    f += 0.01 * state.age              # survival
    f -= 0.03 * state.idle_ticks
    f += _environmental_fitness_bonus(state)
    return max(0.0, f)


FITNESS_FUNCTIONS = {
    "worm": compute_fitness_worm,
    "beetle": compute_fitness_beetle,
    "spider": compute_fitness_spider,
    "fish": compute_fitness_fish,
    "bee": compute_fitness_bee,
    "firefly": compute_fitness_firefly,
    "ant": compute_fitness_ant,
}


# ===================================================================
# CREATURE SIMULATORS — CPU evaluation for each species
# ===================================================================

def _clamp(v, lo, hi):
    return max(lo, min(hi, v))


def _dist(x1, y1, x2, y2):
    return math.sqrt((x1 - x2) ** 2 + (y1 - y2) ** 2)


def _manhattan(x1, y1, x2, y2):
    return abs(x1 - x2) + abs(y1 - y2)


def _get_el(grid, x, y):
    h, w = grid.shape
    if 0 <= y < h and 0 <= x < w:
        return int(grid[y, x])
    return EL_STONE


def _sense_radius(grid, cx, cy, radius, element):
    """Count cells of a given element within radius."""
    h, w = grid.shape
    count = 0
    for dy in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            nx, ny = cx + dx, cy + dy
            if 0 <= nx < w and 0 <= ny < h:
                if grid[ny, nx] == element:
                    count += 1
    return count


def _sense_hazards(grid, cx, cy, radius=3):
    """Count hazardous cells (gas + toxic) near creature. Returns (gas_count, toxic_count)."""
    h, w = grid.shape
    gas_count = 0
    toxic_count = 0
    for dy in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            nx, ny = cx + dx, cy + dy
            if 0 <= nx < w and 0 <= ny < h:
                el = int(grid[ny, nx])
                if el in GAS_HAZARDS:
                    gas_count += 1
                if el in TOXIC_ELEMENTS:
                    toxic_count += 1
    return gas_count, toxic_count


def _update_environmental_state(state, grid, temperature_grid=None):
    """Update creature's environmental awareness tracking each tick.

    Call this once per tick in each creature evaluator after movement.
    """
    el_here = _get_el(grid, state.x, state.y)

    # Gas exposure tracking
    gas_nearby, toxic_nearby = _sense_hazards(grid, state.x, state.y, 2)
    if gas_nearby > 0 or toxic_nearby > 0:
        state.gas_exposure_ticks += 1

    # Toxic damage from standing in hazardous cells
    if el_here in TOXIC_ELEMENTS:
        damage = 0.05
        state.toxic_damage_taken += damage
        state.energy -= damage

    # Gas damage (suffocation from CO2, methane inhalation)
    if el_here in GAS_HAZARDS:
        damage = 0.02
        state.toxic_damage_taken += damage
        state.energy -= damage

    # Temperature comfort (simplified: use grid position as proxy)
    # In a full sim, temperature_grid would be available
    if temperature_grid is not None:
        h, w = temperature_grid.shape
        if 0 <= state.y < h and 0 <= state.x < w:
            temp = int(temperature_grid[state.y, state.x])
            state.temperature_sensed = temp
            if 80 <= temp <= 170:  # comfort zone
                state.temp_comfort_ticks += 1
            elif temp > 200 or temp < 30:  # danger zone
                state.temp_danger_ticks += 1


def _nearest_element(grid, cx, cy, element, max_dist=20):
    """Find nearest cell of given element. Returns (dist, dx, dy) or None."""
    h, w = grid.shape
    best_dist = max_dist + 1
    best_dx, best_dy = 0, 0
    for dy in range(-max_dist, max_dist + 1):
        for dx in range(-max_dist, max_dist + 1):
            nx, ny = cx + dx, cy + dy
            if 0 <= nx < w and 0 <= ny < h and grid[ny, nx] == element:
                d = abs(dx) + abs(dy)
                if d < best_dist:
                    best_dist = d
                    best_dx, best_dy = dx, dy
    if best_dist > max_dist:
        return None
    return (best_dist, best_dx, best_dy)


def evaluate_worm(net_fn, env: dict, max_steps: int = 400, rng=None) -> CreatureState:
    """Worm: 10 inputs, 4 outputs. Burrows through dirt, eats compost."""
    grid = env["grid"].copy()
    sz = grid.shape[0]
    x0, y0, x1, y1 = env["spawn_zone"]
    rng = rng or np.random.default_rng()
    sx = rng.integers(x0, x1)
    sy = rng.integers(y0, y1)
    state = CreatureState(sx, sy, energy=1.0)

    for tick in range(max_steps):
        if not state.alive or state.energy <= 0:
            break
        state.age = tick
        # 10 inputs: food_dir_x, food_dir_y, food_dist, energy,
        #   ground_here, ground_ahead, ground_left, ground_right,
        #   depth_normalized, nearby_compost_count
        food_info = _nearest_element(grid, state.x, state.y, EL_COMPOST, 15)
        fd_x = food_info[1] / 15.0 if food_info else 0.0
        fd_y = food_info[2] / 15.0 if food_info else 0.0
        fd = food_info[0] / 15.0 if food_info else 1.0
        here = _get_el(grid, state.x, state.y) / 10.0
        ahead_d = _get_el(grid, state.x, state.y + 1) / 10.0
        left = _get_el(grid, state.x - 1, state.y) / 10.0
        right = _get_el(grid, state.x + 1, state.y) / 10.0
        depth = state.y / sz
        nearby_compost = _sense_radius(grid, state.x, state.y, 3, EL_COMPOST) / 9.0

        inputs = [fd_x, fd_y, fd, state.energy, here, ahead_d, left, right,
                  depth, nearby_compost]
        outputs = net_fn(inputs)

        # 4 outputs: move_dx, move_dy, eat, dig
        dx = int(round(_clamp(np.tanh(outputs[0]) * 1.5, -1, 1)))
        dy = int(round(_clamp(np.tanh(outputs[1]) * 1.5, -1, 1)))
        want_eat = np.tanh(outputs[2]) > 0.0
        want_dig = np.tanh(outputs[3]) > 0.0

        # Check for gas hazards before moving — track evasion
        nx = _clamp(state.x + dx, 0, sz - 1)
        ny = _clamp(state.y + dy, 0, sz - 1)
        target_el = _get_el(grid, nx, ny)

        # Gas evasion: if target cell is hazardous but creature changes direction
        if target_el in ALL_HAZARDS and (dx != 0 or dy != 0):
            state.gas_evasions += 1
            # Don't move into hazard — override movement
            nx, ny = state.x, state.y

        if dx == 0 and dy == 0:
            state.idle_ticks += 1
        else:
            # Worms can dig through dirt
            if target_el == EL_DIRT and want_dig:
                grid[ny, nx] = EL_EMPTY
                state.dirt_aerated += 1
                state.x, state.y = nx, ny
                cost = 0.003
                state.energy -= cost
                state.total_energy_spent += cost
            elif target_el in (EL_EMPTY, EL_COMPOST):
                state.x, state.y = nx, ny
                cost = 0.002
                state.energy -= cost
                state.total_energy_spent += cost
            elif target_el == EL_WATER:
                cost = 0.01
                state.energy -= cost  # water is dangerous
                state.total_energy_spent += cost
                state.x, state.y = nx, ny

        # Eat compost at current position
        if want_eat and _get_el(grid, state.x, state.y) == EL_COMPOST:
            grid[state.y, state.x] = EL_EMPTY
            state.compost_consumed += 1
            gain = 0.15
            state.energy = min(1.0, state.energy + gain)
            state.total_energy_gained += gain

        # Offspring chance when well-fed
        if state.energy > 0.8 and tick % 50 == 0:
            state.offspring_count += 1
            cost = 0.3
            state.energy -= cost
            state.total_energy_spent += cost

        base_cost = 0.001
        state.energy -= base_cost
        state.total_energy_spent += base_cost

        # Environmental awareness tracking
        _update_environmental_state(state, grid)

    return state


def evaluate_beetle(net_fn, env: dict, max_steps: int = 500,
                    predator_positions=None, rng=None) -> CreatureState:
    """Beetle: 12 inputs, 6 outputs. Eats plants/seeds, evades spiders."""
    grid = env["grid"].copy()
    sz = grid.shape[0]
    x0, y0, x1, y1 = env["spawn_zone"]
    rng = rng or np.random.default_rng()
    sx = rng.integers(x0, x1)
    sy = rng.integers(y0, y1)
    state = CreatureState(sx, sy, energy=1.0)
    predator_positions = predator_positions or []

    for tick in range(max_steps):
        if not state.alive or state.energy <= 0:
            break
        state.age = tick
        # 12 inputs
        food_info = _nearest_element(grid, state.x, state.y, EL_SEED, 15)
        if not food_info:
            food_info = _nearest_element(grid, state.x, state.y, EL_PLANT, 15)
        fd_x = food_info[1] / 15.0 if food_info else 0.0
        fd_y = food_info[2] / 15.0 if food_info else 0.0
        fd = food_info[0] / 15.0 if food_info else 1.0

        # Predator awareness
        pred_dist = 1.0
        pred_dx, pred_dy = 0.0, 0.0
        for px, py in predator_positions:
            d = _dist(state.x, state.y, px, py)
            if d < pred_dist * 15:
                pred_dist = d / 15.0
                pred_dx = (px - state.x) / 15.0
                pred_dy = (py - state.y) / 15.0

        here = _get_el(grid, state.x, state.y) / 10.0
        nearby_food = (_sense_radius(grid, state.x, state.y, 3, EL_SEED) +
                       _sense_radius(grid, state.x, state.y, 3, EL_PLANT)) / 18.0
        ground_below = _get_el(grid, state.x, state.y + 1) / 10.0

        inputs = [fd_x, fd_y, fd, state.energy, pred_dist, pred_dx, pred_dy,
                  here, nearby_food, ground_below, state.x / sz, state.y / sz]
        outputs = net_fn(inputs)

        # 6 outputs: move_dx, move_dy, eat, flee, hide, signal
        dx = int(round(_clamp(np.tanh(outputs[0]) * 1.5, -1, 1)))
        dy = int(round(_clamp(np.tanh(outputs[1]) * 1.5, -1, 1)))
        want_eat = np.tanh(outputs[2]) > 0.0
        want_flee = np.tanh(outputs[3]) > 0.0

        # Predator evasion tracking
        in_danger = pred_dist < 0.4
        if in_danger and want_flee:
            state.evasions += 1
        elif in_danger and not want_flee:
            state.danger_ticks_no_flee += 1

        nx = _clamp(state.x + dx, 0, sz - 1)
        ny = _clamp(state.y + dy, 0, sz - 1)
        target_el = _get_el(grid, nx, ny)

        # Gas evasion check
        if target_el in ALL_HAZARDS:
            state.gas_evasions += 1
            nx, ny = state.x, state.y

        if target_el in (EL_EMPTY, EL_SEED, EL_PLANT):
            state.x, state.y = nx, ny
            cost = 0.002
            state.energy -= cost
            state.total_energy_spent += cost

        # Eat food
        el_here = _get_el(grid, state.x, state.y)
        if want_eat and el_here in (EL_SEED, EL_PLANT):
            grid[state.y, state.x] = EL_EMPTY
            state.food_collected += 1
            gain = 0.12
            state.energy = min(1.0, state.energy + gain)
            state.total_energy_gained += gain

        if state.energy > 0.85 and tick % 60 == 0:
            state.offspring_count += 1
            cost = 0.3
            state.energy -= cost
            state.total_energy_spent += cost

        base_cost = 0.001
        state.energy -= base_cost
        state.total_energy_spent += base_cost

        _update_environmental_state(state, grid)

    return state


def evaluate_spider(net_fn, env: dict, max_steps: int = 500,
                    prey_positions=None, rng=None) -> CreatureState:
    """Spider: 14 inputs, 7 outputs. Web building, ambush predation."""
    grid = env["grid"].copy()
    sz = grid.shape[0]
    x0, y0, x1, y1 = env["spawn_zone"]
    rng = rng or np.random.default_rng()
    sx = rng.integers(x0, x1)
    sy = rng.integers(y0, y1)
    state = CreatureState(sx, sy, energy=1.0)
    prey_positions = list(prey_positions or [])
    web_grid = np.zeros((sz, sz), dtype=bool)

    for tick in range(max_steps):
        if not state.alive or state.energy <= 0:
            break
        state.age = tick

        # 14 inputs
        nearest_prey_dist = 1.0
        nearest_prey_dx, nearest_prey_dy = 0.0, 0.0
        prey_count = 0
        for px, py in prey_positions:
            d = _dist(state.x, state.y, px, py)
            if d < 20:
                prey_count += 1
            if d / 20.0 < nearest_prey_dist:
                nearest_prey_dist = d / 20.0
                nearest_prey_dx = (px - state.x) / 20.0
                nearest_prey_dy = (py - state.y) / 20.0

        web_here = 1.0 if web_grid[state.y, state.x] else 0.0
        web_nearby = sum(1 for dx in range(-2, 3) for dy in range(-2, 3)
                         if 0 <= state.x + dx < sz and 0 <= state.y + dy < sz
                         and web_grid[state.y + dy, state.x + dx]) / 25.0

        # Vibration: prey on web
        vibration = 0.0
        for px, py in prey_positions:
            if 0 <= px < sz and 0 <= py < sz and web_grid[py, px]:
                vibration = max(vibration, 1.0 - _dist(state.x, state.y, px, py) / 20.0)

        here = _get_el(grid, state.x, state.y) / 10.0
        ground_below = _get_el(grid, state.x, state.y + 1) / 10.0

        inputs = [nearest_prey_dist, nearest_prey_dx, nearest_prey_dy,
                  prey_count / 5.0, state.energy, web_here, web_nearby,
                  vibration, here, ground_below,
                  state.x / sz, state.y / sz,
                  len(state.web_cells) / 50.0, state.prey_killed / 5.0]
        outputs = net_fn(inputs)

        # 7 outputs: move_dx, move_dy, place_web, attack, wait, reel_in, flee
        dx = int(round(_clamp(np.tanh(outputs[0]) * 1.5, -1, 1)))
        dy = int(round(_clamp(np.tanh(outputs[1]) * 1.5, -1, 1)))
        want_web = np.tanh(outputs[2]) > 0.0
        want_attack = np.tanh(outputs[3]) > 0.0

        nx = _clamp(state.x + dx, 0, sz - 1)
        ny = _clamp(state.y + dy, 0, sz - 1)
        target_el = _get_el(grid, nx, ny)
        if target_el in (EL_EMPTY, EL_PLANT, EL_SEED) or web_grid[ny, nx]:
            state.x, state.y = nx, ny
            state.energy -= 0.002

        # Place web
        if want_web and len(state.web_cells) < 50:
            if not web_grid[state.y, state.x]:
                web_grid[state.y, state.x] = True
                state.web_cells.add((state.x, state.y))
                state.energy -= 0.005

        # Attack prey
        if want_attack:
            killed = []
            for i, (px, py) in enumerate(prey_positions):
                if _manhattan(state.x, state.y, px, py) <= 2:
                    state.prey_killed += 1
                    state.prey_consumed += 1
                    state.energy = min(1.0, state.energy + 0.25)
                    killed.append(i)
                    break
            for i in reversed(killed):
                prey_positions.pop(i)

        # Web catches (prey wanders onto web)
        caught = []
        for i, (px, py) in enumerate(prey_positions):
            if 0 <= px < sz and 0 <= py < sz and web_grid[py, px]:
                if rng.random() < 0.1:  # 10% catch chance per tick
                    state.web_catches += 1
                    caught.append(i)
        for i in reversed(caught):
            prey_positions.pop(i)

        if state.energy > 0.9 and tick % 80 == 0:
            state.offspring_count += 1
            cost = 0.35
            state.energy -= cost
            state.total_energy_spent += cost

        base_cost = 0.001
        state.energy -= base_cost
        state.total_energy_spent += base_cost

        _update_environmental_state(state, grid)

    return state


def evaluate_fish(net_fn, env: dict, max_steps: int = 500,
                  all_fish_positions=None, rng=None) -> CreatureState:
    """Fish: 12 inputs, 5 outputs. Algae feeding, schooling."""
    grid = env["grid"].copy()
    sz = grid.shape[0]
    x0, y0, x1, y1 = env["spawn_zone"]
    rng = rng or np.random.default_rng()
    sx = rng.integers(x0, x1)
    sy = rng.integers(y0, y1)
    state = CreatureState(sx, sy, energy=1.0)
    water_top, water_bottom = env.get("water_bounds", (0, sz))
    all_fish = list(all_fish_positions or [])

    for tick in range(max_steps):
        if not state.alive or state.energy <= 0:
            break
        state.age = tick

        # 12 inputs
        food_info = _nearest_element(grid, state.x, state.y, EL_PLANT, 15)
        fd_x = food_info[1] / 15.0 if food_info else 0.0
        fd_y = food_info[2] / 15.0 if food_info else 0.0
        fd = food_info[0] / 15.0 if food_info else 1.0

        # Schooling: count nearby fish
        nearby_fish = 0
        avg_fx, avg_fy = 0.0, 0.0
        for fx, fy in all_fish:
            d = _dist(state.x, state.y, fx, fy)
            if 3 <= d <= 6:
                nearby_fish += 1
                avg_fx += fx
                avg_fy += fy
        if nearby_fish >= 2:
            state.schooling_ticks += 1
            avg_fx /= nearby_fish
            avg_fy /= nearby_fish
        school_dx = (avg_fx - state.x) / 15.0 if nearby_fish > 0 else 0.0
        school_dy = (avg_fy - state.y) / 15.0 if nearby_fish > 0 else 0.0

        # Water boundary awareness
        water_depth = (state.y - water_top) / max(1, water_bottom - water_top)
        at_boundary = 1.0 if (state.y <= water_top + 1 or state.y >= water_bottom - 1) else 0.0

        inputs = [fd_x, fd_y, fd, state.energy,
                  nearby_fish / 5.0, school_dx, school_dy,
                  water_depth, at_boundary,
                  state.x / sz, state.y / sz,
                  state.food_collected / 10.0]
        outputs = net_fn(inputs)

        # 5 outputs: move_dx, move_dy, eat, school_follow, surface
        dx = int(round(_clamp(np.tanh(outputs[0]) * 2.0, -2, 2)))
        dy = int(round(_clamp(np.tanh(outputs[1]) * 2.0, -2, 2)))
        want_eat = np.tanh(outputs[2]) > 0.0

        nx = _clamp(state.x + dx, 0, sz - 1)
        ny = _clamp(state.y + dy, water_top, water_bottom - 1)
        # Fish must stay in water
        if _get_el(grid, nx, ny) == EL_WATER or _get_el(grid, nx, ny) == EL_PLANT:
            state.x, state.y = nx, ny
            state.energy -= 0.001

        # Eat algae
        if want_eat and _get_el(grid, state.x, state.y) == EL_PLANT:
            grid[state.y, state.x] = EL_WATER
            state.food_collected += 1
            gain = 0.1
            state.energy = min(1.0, state.energy + gain)
            state.total_energy_gained += gain

        if state.energy > 0.85 and tick % 70 == 0:
            state.offspring_count += 1
            cost = 0.25
            state.energy -= cost
            state.total_energy_spent += cost

        base_cost = 0.0008
        state.energy -= base_cost
        state.total_energy_spent += base_cost

        _update_environmental_state(state, grid)

    return state


def evaluate_bee(net_fn, env: dict, max_steps: int = 600, rng=None) -> CreatureState:
    """Bee: 14 inputs, 7 outputs. Pollination, honey, seeds."""
    grid = env["grid"].copy()
    sz = grid.shape[0]
    x0, y0, x1, y1 = env["spawn_zone"]
    rng = rng or np.random.default_rng()
    sx = rng.integers(x0, x1)
    sy = rng.integers(y0, y1)
    state = CreatureState(sx, sy, energy=1.0)
    hive_x, hive_y = env.get("hive_pos", (sz // 2, sz // 4))
    pollinated_set: set[tuple[int, int]] = set()
    pollen_carried = False

    for tick in range(max_steps):
        if not state.alive or state.energy <= 0:
            break
        state.age = tick

        # 14 inputs
        plant_info = _nearest_element(grid, state.x, state.y, EL_PLANT, 20)
        pl_dx = plant_info[1] / 20.0 if plant_info else 0.0
        pl_dy = plant_info[2] / 20.0 if plant_info else 0.0
        pl_dist = plant_info[0] / 20.0 if plant_info else 1.0

        hive_dist = _dist(state.x, state.y, hive_x, hive_y) / (sz * 1.414)
        hive_dx = (hive_x - state.x) / sz
        hive_dy = (hive_y - state.y) / sz

        nearby_plants = _sense_radius(grid, state.x, state.y, 3, EL_PLANT) / 9.0
        has_pollen = 1.0 if pollen_carried else 0.0
        n_pollinated = len(pollinated_set) / 20.0
        at_hive = 1.0 if _manhattan(state.x, state.y, hive_x, hive_y) <= 2 else 0.0
        here = _get_el(grid, state.x, state.y) / 10.0

        inputs = [pl_dx, pl_dy, pl_dist, state.energy,
                  hive_dist, hive_dx, hive_dy,
                  nearby_plants, has_pollen, n_pollinated,
                  at_hive, here, state.x / sz, state.y / sz]
        outputs = net_fn(inputs)

        # 7 outputs: move_dx, move_dy, collect_pollen, deposit_honey,
        #            drop_seed, return_hive, pollinate
        dx = int(round(_clamp(np.tanh(outputs[0]) * 2.0, -2, 2)))
        dy = int(round(_clamp(np.tanh(outputs[1]) * 2.0, -2, 2)))
        want_collect = np.tanh(outputs[2]) > 0.0
        want_deposit = np.tanh(outputs[3]) > 0.0
        want_drop_seed = np.tanh(outputs[4]) > 0.0

        nx = _clamp(state.x + dx, 0, sz - 1)
        ny = _clamp(state.y + dy, 0, sz - 1)
        target_el = _get_el(grid, nx, ny)
        if target_el not in (EL_STONE, EL_DIRT, EL_WATER):
            state.x, state.y = nx, ny
            state.energy -= 0.002

        # Collect pollen from plant
        el_here = _get_el(grid, state.x, state.y)
        pos_key = (state.x, state.y)
        if want_collect and el_here == EL_PLANT and pos_key not in pollinated_set:
            pollen_carried = True
            pollinated_set.add(pos_key)
            state.plants_pollinated += 1

        # Deposit honey at hive
        if want_deposit and pollen_carried and _manhattan(state.x, state.y, hive_x, hive_y) <= 2:
            state.honey_deposited += 1
            pollen_carried = False
            state.energy = min(1.0, state.energy + 0.08)

        # Drop seed
        if want_drop_seed and pollen_carried:
            if el_here == EL_EMPTY and _get_el(grid, state.x, state.y + 1) in (EL_DIRT, EL_STONE):
                grid[state.y, state.x] = EL_SEED
                state.seeds_carried += 1
                pollen_carried = False

        if state.energy > 0.8 and tick % 80 == 0:
            state.offspring_count += 1
            cost = 0.3
            state.energy -= cost
            state.total_energy_spent += cost

        base_cost = 0.001
        state.energy -= base_cost
        state.total_energy_spent += base_cost

        _update_environmental_state(state, grid)

    return state


def evaluate_firefly(net_fn, env: dict, max_steps: int = 400,
                     all_firefly_states=None, rng=None) -> CreatureState:
    """Firefly: 10 inputs, 4 outputs. Synchronization + survival."""
    grid = env["grid"].copy()
    sz = grid.shape[0]
    x0, y0, x1, y1 = env["spawn_zone"]
    rng = rng or np.random.default_rng()
    sx = rng.integers(x0, x1)
    sy = rng.integers(y0, y1)
    state = CreatureState(sx, sy, energy=1.0)
    state.phase = rng.random() * 2 * math.pi
    all_fireflies = list(all_firefly_states or [])

    for tick in range(max_steps):
        if not state.alive or state.energy <= 0:
            break
        state.age = tick

        # 10 inputs
        food_info = _nearest_element(grid, state.x, state.y, EL_COMPOST, 15)
        if not food_info:
            food_info = _nearest_element(grid, state.x, state.y, EL_SEED, 15)
        fd_x = food_info[1] / 15.0 if food_info else 0.0
        fd_y = food_info[2] / 15.0 if food_info else 0.0
        fd = food_info[0] / 15.0 if food_info else 1.0

        # Synchronization inputs
        sync_count = 0
        avg_phase = 0.0
        for other in all_fireflies:
            if other is state:
                continue
            d = _dist(state.x, state.y, other.x, other.y)
            if d < 10:
                phase_diff = abs(math.sin(state.phase) - math.sin(other.phase))
                if phase_diff < 0.1:
                    sync_count += 1
                avg_phase += other.phase
        if len(all_fireflies) > 1:
            avg_phase /= (len(all_fireflies) - 1)
        my_flash = math.sin(state.phase)
        phase_diff_avg = abs(my_flash - math.sin(avg_phase)) if all_fireflies else 0.0

        inputs = [fd_x, fd_y, fd, state.energy,
                  my_flash, phase_diff_avg, sync_count / 5.0,
                  state.x / sz, state.y / sz,
                  state.age / max_steps]
        outputs = net_fn(inputs)

        # 4 outputs: move_dx, move_dy, phase_adjust, eat
        dx = int(round(_clamp(np.tanh(outputs[0]) * 1.5, -1, 1)))
        dy = int(round(_clamp(np.tanh(outputs[1]) * 1.5, -1, 1)))
        phase_adj = np.tanh(outputs[2]) * 0.3
        want_eat = np.tanh(outputs[3]) > 0.0

        state.phase += 0.1 + phase_adj
        if state.phase > 2 * math.pi:
            state.phase -= 2 * math.pi

        # Synchronization check
        if sync_count >= 2:
            state.sync_ticks += 1

        nx = _clamp(state.x + dx, 0, sz - 1)
        ny = _clamp(state.y + dy, 0, sz - 1)
        target_el = _get_el(grid, nx, ny)
        if target_el in (EL_EMPTY, EL_COMPOST, EL_SEED):
            state.x, state.y = nx, ny
            state.energy -= 0.002

        el_here = _get_el(grid, state.x, state.y)
        if want_eat and el_here in (EL_COMPOST, EL_SEED):
            grid[state.y, state.x] = EL_EMPTY
            state.food_collected += 1
            state.energy = min(1.0, state.energy + 0.1)

        if state.energy > 0.8 and tick % 60 == 0:
            state.offspring_count += 1
            cost = 0.3
            state.energy -= cost
            state.total_energy_spent += cost

        base_cost = 0.001
        state.energy -= base_cost
        state.total_energy_spent += base_cost

        _update_environmental_state(state, grid)

    return state


def evaluate_ant(net_fn, env: dict, max_steps: int = 600, rng=None) -> CreatureState:
    """Ant: 8 inputs, 6 outputs. Matches Dart ant_brain.dart exactly."""
    grid = env["grid"].copy()
    sz = grid.shape[0]
    x0, y0, x1, y1 = env["spawn_zone"]
    rng = rng or np.random.default_rng()
    sx = rng.integers(x0, x1)
    sy = rng.integers(y0, y1)
    state = CreatureState(sx, sy, energy=1.0)
    nest_x, nest_y = env.get("nest_pos", (sz // 2, int(sz * 0.65) - 1))
    pheromone_grid = np.zeros((sz, sz), dtype=np.float32)

    for tick in range(max_steps):
        if not state.alive or state.energy <= 0:
            break
        state.age = tick

        # 8 inputs matching ant_brain.dart
        food_info = _nearest_element(grid, state.x, state.y, EL_SEED, 15)
        food_dist = food_info[0] / 15.0 if food_info else 1.0
        nest_dist = _dist(state.x, state.y, nest_x, nest_y) / (sz * 1.414)

        # Pheromone gradient
        cx = _clamp(state.x, 1, sz - 2)
        cy = _clamp(state.y, 1, sz - 2)
        phero_grad = 0.0
        if pheromone_grid.max() > 0:
            phero_grad = (pheromone_grid[cy, min(sz - 1, cx + 1)] -
                          pheromone_grid[cy, max(0, cx - 1)]) / (pheromone_grid.max() + 1e-6)
        home_dir_x = (nest_x - state.x) / max(1.0, _dist(state.x, state.y, nest_x, nest_y))

        inputs = [food_dist, nest_dist, _clamp(phero_grad, -1, 1),
                  _clamp(home_dir_x, -1, 1), 0.0,  # danger
                  state.energy, 1.0 if state.carrying else 0.0, 0.0]  # enemies
        outputs = net_fn(inputs)

        # 6 outputs: move_dx, move_dy, deposit_pheromone, pick_up, drop, attack
        dx = int(round(_clamp(np.tanh(outputs[0]) * 1.5, -1, 1)))
        dy = int(round(_clamp(np.tanh(outputs[1]) * 1.5, -1, 1)))
        want_deposit = np.tanh(outputs[2]) > 0.0
        want_pick = np.tanh(outputs[3]) > 0.0
        want_drop = np.tanh(outputs[4]) > 0.0

        if dx == 0 and dy == 0:
            state.idle_ticks += 1

        nx = _clamp(state.x + dx, 0, sz - 1)
        ny = _clamp(state.y + dy, 0, sz - 1)
        target_el = _get_el(grid, nx, ny)
        if target_el in (EL_EMPTY, EL_SEED):
            state.x, state.y = nx, ny
            state.energy -= 0.002

        # Deposit pheromone when carrying food
        if want_deposit and state.carrying:
            px = _clamp(state.x, 0, sz - 1)
            py = _clamp(state.y, 0, sz - 1)
            pheromone_grid[py, px] = min(1.0, pheromone_grid[py, px] + 0.3)

        # Pick up food
        if want_pick and not state.carrying:
            el_here = _get_el(grid, state.x, state.y)
            if el_here == EL_SEED:
                grid[state.y, state.x] = EL_EMPTY
                state.carrying = True
                state.food_collected += 1
                state.energy = min(1.0, state.energy + 0.05)

        # Drop at nest
        if want_drop and state.carrying:
            if _manhattan(state.x, state.y, nest_x, nest_y) <= 3:
                state.carrying = False
                state.food_delivered += 1
                state.energy = min(1.0, state.energy + 0.1)

        # Pheromone decay
        if tick % 10 == 0:
            pheromone_grid *= 0.95

        base_cost = 0.001
        state.energy -= base_cost
        state.total_energy_spent += base_cost

        _update_environmental_state(state, grid)

    return state


EVALUATORS = {
    "worm": evaluate_worm,
    "beetle": evaluate_beetle,
    "spider": evaluate_spider,
    "fish": evaluate_fish,
    "bee": evaluate_bee,
    "firefly": evaluate_firefly,
    "ant": evaluate_ant,
}


# ===================================================================
# NEAT GENOME — pure Python implementation (no external deps)
# ===================================================================

class NeatNode:
    __slots__ = ("id", "type", "activation", "layer", "bias")
    def __init__(self, id: int, type: str, activation: str = "tanh",
                 layer: int = 0, bias: float = 0.0):
        self.id = id
        self.type = type
        self.activation = activation
        self.layer = layer
        self.bias = bias


class NeatConnection:
    __slots__ = ("innovation", "in_node", "out_node", "weight", "enabled")
    def __init__(self, innovation: int, in_node: int, out_node: int,
                 weight: float, enabled: bool = True):
        self.innovation = innovation
        self.in_node = in_node
        self.out_node = out_node
        self.weight = weight
        self.enabled = enabled


class NeatGenomeLocal:
    """Minimal NEAT genome for training. Matches Dart export format."""

    def __init__(self, n_inputs: int, n_outputs: int, rng: np.random.Generator):
        self.nodes: dict[int, NeatNode] = {}
        self.connections: dict[int, NeatConnection] = {}
        self.fitness = 0.0
        self.n_inputs = n_inputs
        self.n_outputs = n_outputs
        self._rng = rng
        self._next_node_id = 0
        self._next_innovation = 0
        self._init_minimal()

    def _init_minimal(self):
        # Bias node
        self.nodes[0] = NeatNode(0, "bias", layer=0)
        self._next_node_id = 1
        # Input nodes
        input_ids = []
        for _ in range(self.n_inputs):
            nid = self._next_node_id
            self.nodes[nid] = NeatNode(nid, "input", layer=0)
            input_ids.append(nid)
            self._next_node_id += 1
        # Output nodes
        output_ids = []
        for _ in range(self.n_outputs):
            nid = self._next_node_id
            self.nodes[nid] = NeatNode(nid, "output", activation="tanh", layer=1)
            output_ids.append(nid)
            self._next_node_id += 1
        # Full connections
        for in_id in [0] + input_ids:
            for out_id in output_ids:
                w = self._rng.normal(0, 1) * 2
                innov = self._next_innovation
                self.connections[innov] = NeatConnection(innov, in_id, out_id, w)
                self._next_innovation += 1

    def copy(self) -> "NeatGenomeLocal":
        g = NeatGenomeLocal.__new__(NeatGenomeLocal)
        g.n_inputs = self.n_inputs
        g.n_outputs = self.n_outputs
        g._rng = self._rng
        g._next_node_id = self._next_node_id
        g._next_innovation = self._next_innovation
        g.fitness = self.fitness
        g.nodes = {k: NeatNode(n.id, n.type, n.activation, n.layer, n.bias)
                   for k, n in self.nodes.items()}
        g.connections = {k: NeatConnection(c.innovation, c.in_node, c.out_node,
                                           c.weight, c.enabled)
                         for k, c in self.connections.items()}
        return g

    def mutate(self, weight_rate=0.8, perturb_power=0.5, add_conn_rate=0.05,
               add_node_rate=0.03, max_hidden=20, max_conns=100):
        rng = self._rng
        # Weight mutation
        for c in self.connections.values():
            if rng.random() < weight_rate:
                if rng.random() < 0.9:
                    c.weight += rng.normal(0, perturb_power)
                else:
                    c.weight = rng.normal(0, 1) * 2
                c.weight = float(np.clip(c.weight, -8, 8))
        # Add connection
        if rng.random() < add_conn_rate and len(self.connections) < max_conns:
            self._mutate_add_connection()
        # Add node
        hidden_count = sum(1 for n in self.nodes.values() if n.type == "hidden")
        if rng.random() < add_node_rate and hidden_count < max_hidden:
            self._mutate_add_node()

    def _mutate_add_connection(self):
        node_list = list(self.nodes.values())
        rng = self._rng
        for _ in range(20):
            a = node_list[rng.integers(0, len(node_list))]
            b = node_list[rng.integers(0, len(node_list))]
            if a.id == b.id:
                continue
            if b.type in ("input", "bias"):
                continue
            if a.type == "output":
                continue
            if a.layer >= b.layer and b.type != "output":
                continue
            # Check existing
            exists = any(c.in_node == a.id and c.out_node == b.id
                         for c in self.connections.values())
            if exists:
                continue
            innov = self._next_innovation
            self.connections[innov] = NeatConnection(
                innov, a.id, b.id, rng.normal(0, 1) * 2)
            self._next_innovation += 1
            return

    def _mutate_add_node(self):
        enabled = [c for c in self.connections.values() if c.enabled]
        if not enabled:
            return
        rng = self._rng
        conn = enabled[rng.integers(0, len(enabled))]
        conn.enabled = False
        new_id = self._next_node_id
        self._next_node_id += 1
        from_layer = self.nodes[conn.in_node].layer
        to_layer = self.nodes[conn.out_node].layer
        new_layer = (from_layer + to_layer) // 2 or from_layer + 1
        self.nodes[new_id] = NeatNode(new_id, "hidden", "tanh", new_layer)
        i1 = self._next_innovation
        self.connections[i1] = NeatConnection(i1, conn.in_node, new_id, 1.0)
        self._next_innovation += 1
        i2 = self._next_innovation
        self.connections[i2] = NeatConnection(i2, new_id, conn.out_node, conn.weight)
        self._next_innovation += 1

    def forward(self, inputs: list[float]) -> list[float]:
        """Feed-forward evaluation."""
        values: dict[int, float] = {}
        # Bias
        values[0] = 1.0
        # Inputs
        in_nodes = sorted([n for n in self.nodes.values() if n.type == "input"],
                          key=lambda n: n.id)
        for i, node in enumerate(in_nodes):
            values[node.id] = inputs[i] if i < len(inputs) else 0.0
        # Topological sort by layer
        sorted_nodes = sorted(self.nodes.values(), key=lambda n: n.layer)
        for node in sorted_nodes:
            if node.type in ("input", "bias"):
                continue
            total = node.bias
            for c in self.connections.values():
                if c.out_node == node.id and c.enabled:
                    in_val = values.get(c.in_node, 0.0)
                    total += in_val * c.weight
            # Activation
            if node.activation == "tanh":
                values[node.id] = float(np.tanh(total))
            elif node.activation == "sigmoid":
                values[node.id] = 1.0 / (1.0 + math.exp(-max(-60, min(60, total))))
            elif node.activation == "relu":
                values[node.id] = max(0.0, total)
            else:
                values[node.id] = float(np.tanh(total))
        # Collect outputs
        out_nodes = sorted([n for n in self.nodes.values() if n.type == "output"],
                           key=lambda n: n.id)
        return [values.get(n.id, 0.0) for n in out_nodes]

    def to_dart_json(self) -> dict:
        """Export to Dart NeatGenome.fromJson() format."""
        type_map = {"input": 0, "hidden": 1, "output": 2, "bias": 3}
        act_map = {"tanh": 1, "sigmoid": 0, "relu": 2, "linear": 3, "gaussian": 4, "step": 5}
        nodes = []
        for n in self.nodes.values():
            nodes.append({
                "id": n.id,
                "type": type_map.get(n.type, 1),
                "activation": act_map.get(n.activation, 1),
                "layer": n.layer,
            })
        connections = []
        for c in self.connections.values():
            connections.append({
                "innovation": c.innovation,
                "inNode": c.in_node,
                "outNode": c.out_node,
                "weight": round(c.weight, 6),
                "enabled": c.enabled,
            })
        return {
            "nodes": nodes,
            "connections": connections,
            "fitness": round(self.fitness, 2),
            "speciesId": -1,
        }

    @staticmethod
    def crossover(parent1: "NeatGenomeLocal", parent2: "NeatGenomeLocal",
                  rng: np.random.Generator) -> "NeatGenomeLocal":
        fitter = parent1 if parent1.fitness >= parent2.fitness else parent2
        other = parent2 if fitter is parent1 else parent1
        child = fitter.copy()
        child._rng = rng
        # Matching genes: random inherit
        for innov, conn in other.connections.items():
            if innov in child.connections:
                if rng.random() < 0.5:
                    child.connections[innov].weight = conn.weight
        child.fitness = 0.0
        return child


# ===================================================================
# NEAT POPULATION — manages evolution
# ===================================================================

class NeatPopulation:
    """Simple NEAT population with speciation."""

    def __init__(self, n_inputs: int, n_outputs: int, pop_size: int,
                 max_hidden: int = 20, max_conns: int = 100, seed: int = 42):
        self.rng = np.random.default_rng(seed)
        self.n_inputs = n_inputs
        self.n_outputs = n_outputs
        self.pop_size = pop_size
        self.max_hidden = max_hidden
        self.max_conns = max_conns
        self.genomes: list[NeatGenomeLocal] = []
        self.generation = 0
        self.best_fitness = 0.0
        self.best_genome: NeatGenomeLocal | None = None
        self._init_population()

    def _init_population(self):
        for _ in range(self.pop_size):
            g = NeatGenomeLocal(self.n_inputs, self.n_outputs,
                                np.random.default_rng(self.rng.integers(0, 2**31)))
            self.genomes.append(g)

    def evolve(self):
        """One generation of evolution."""
        self.generation += 1
        # Sort by fitness
        self.genomes.sort(key=lambda g: g.fitness, reverse=True)
        if self.genomes[0].fitness > self.best_fitness:
            self.best_fitness = self.genomes[0].fitness
            self.best_genome = self.genomes[0].copy()

        # Elitism
        elite_count = max(2, self.pop_size // 20)
        new_pop = [g.copy() for g in self.genomes[:elite_count]]

        # Tournament selection + crossover + mutation
        survivors = self.genomes[:max(2, int(self.pop_size * 0.3))]
        while len(new_pop) < self.pop_size:
            if self.rng.random() < 0.75 and len(survivors) >= 2:
                # Crossover
                p1 = survivors[self.rng.integers(0, len(survivors))]
                p2 = survivors[self.rng.integers(0, len(survivors))]
                child = NeatGenomeLocal.crossover(
                    p1, p2, np.random.default_rng(self.rng.integers(0, 2**31)))
            else:
                # Clone + mutate
                parent = survivors[self.rng.integers(0, len(survivors))]
                child = parent.copy()
                child._rng = np.random.default_rng(self.rng.integers(0, 2**31))
            child.mutate(max_hidden=self.max_hidden, max_conns=self.max_conns)
            new_pop.append(child)

        self.genomes = new_pop[:self.pop_size]


# ===================================================================
# TRAINING MODES
# ===================================================================

def train_individual(species: str, generations: int | None = None,
                     seed: int = 42, verbose: bool = True) -> tuple[dict, float]:
    """Mode 1: Individual training — single species in its optimal environment."""
    config = SPECIES_CONFIGS[species]
    gens = generations or config["generations"]
    rng = np.random.default_rng(seed)

    if verbose:
        print(f"\n{'='*60}", flush=True)
        print(f"  INDIVIDUAL TRAINING: {species}", flush=True)
        print(f"  {config['description']}", flush=True)
        print(f"  Inputs: {config['inputs']}, Outputs: {config['outputs']}", flush=True)
        print(f"  Population: {config['population']}, Generations: {gens}", flush=True)
        print(f"{'='*60}\n", flush=True)

    pop = NeatPopulation(
        config["inputs"], config["outputs"], config["population"],
        config["max_hidden"], config["max_connections"], seed)

    env_builder = ENV_BUILDERS[config["env_type"]]
    evaluator = EVALUATORS[species]
    fitness_fn = FITNESS_FUNCTIONS[species]
    start = time.time()

    for gen in range(gens):
        env = env_builder(np.random.default_rng(rng.integers(0, 2**31)),
                          config["grid_size"])
        for genome in pop.genomes:
            creature_rng = np.random.default_rng(rng.integers(0, 2**31))
            state = evaluator(genome.forward, env, rng=creature_rng)
            genome.fitness = fitness_fn(state)

        pop.evolve()

        if verbose and (gen % 25 == 0 or gen == gens - 1):
            avg = np.mean([g.fitness for g in pop.genomes])
            print(f"  Gen {gen:4d}/{gens}  best={pop.best_fitness:8.2f}  avg={avg:8.2f}", flush=True)

    elapsed = time.time() - start
    if verbose:
        print(f"\n  Completed in {elapsed:.1f}s", flush=True)

    best = pop.best_genome or pop.genomes[0]

    # Export diverse seed population (top 20 from spread across fitness rankings)
    ranked = sorted(pop.genomes, key=lambda g: g.fitness, reverse=True)
    diverse_count = min(20, len(ranked))
    diverse = [ranked[0]]
    step = max(1, len(ranked) // diverse_count)
    for i in range(step, len(ranked), step):
        if len(diverse) >= diverse_count:
            break
        diverse.append(ranked[i])

    diverse_json = [g.to_dart_json() for g in diverse]
    out_dir = Path(__file__).parent / "trained_genomes"
    out_dir.mkdir(parents=True, exist_ok=True)
    pop_path = out_dir / f"{species}_population.json"
    with open(pop_path, "w") as f:
        json.dump(diverse_json, f)
    if verbose:
        fitnesses = [g.fitness for g in diverse]
        print(f"  Saved {len(diverse)} diverse genomes to {pop_path.name}", flush=True)
        print(f"  Fitness range: {min(fitnesses):.1f} - {max(fitnesses):.1f}", flush=True)

    return best.to_dart_json(), best.fitness


def train_coevolve(species_a: str, species_b: str, generations: int = 300,
                   cycle_length: int = 50, seed: int = 42,
                   verbose: bool = True) -> dict[str, tuple[dict, float]]:
    """Mode 2: Predator-prey co-training with alternating freeze cycles.

    Trains species_b (predator) against frozen species_a (prey) and vice versa.
    Alternates every cycle_length generations.
    """
    cfg_a = SPECIES_CONFIGS[species_a]
    cfg_b = SPECIES_CONFIGS[species_b]
    rng = np.random.default_rng(seed)

    if verbose:
        print(f"\n{'='*60}", flush=True)
        print(f"  CO-EVOLUTION: {species_a} vs {species_b}", flush=True)
        print(f"  Generations: {generations}, Cycle: {cycle_length}", flush=True)
        print(f"{'='*60}\n", flush=True)

    pop_a = NeatPopulation(
        cfg_a["inputs"], cfg_a["outputs"], cfg_a["population"],
        cfg_a["max_hidden"], cfg_a["max_connections"], seed)
    pop_b = NeatPopulation(
        cfg_b["inputs"], cfg_b["outputs"], cfg_b["population"],
        cfg_b["max_hidden"], cfg_b["max_connections"], seed + 1)

    eval_a = EVALUATORS[species_a]
    eval_b = EVALUATORS[species_b]
    fit_a = FITNESS_FUNCTIONS[species_a]
    fit_b = FITNESS_FUNCTIONS[species_b]

    # Determine predator/prey relationship
    a_is_prey = species_a in SPECIES_CONFIGS[species_b].get("predator_of", [])
    start = time.time()

    for gen in range(generations):
        cycle = (gen // cycle_length) % 2
        env_rng = np.random.default_rng(rng.integers(0, 2**31))

        if cycle == 0:
            # Train species_a (prey), freeze species_b (predator)
            env = ENV_BUILDERS[cfg_a["env_type"]](env_rng, cfg_a["grid_size"])
            # Sample predator positions from best of pop_b
            predator_positions = []
            if a_is_prey and pop_b.best_genome:
                for _ in range(3):
                    px = rng.integers(0, cfg_a["grid_size"])
                    py = rng.integers(0, cfg_a["grid_size"])
                    predator_positions.append((px, py))

            for genome in pop_a.genomes:
                creature_rng = np.random.default_rng(rng.integers(0, 2**31))
                if species_a == "beetle":
                    state = eval_a(genome.forward, env,
                                   predator_positions=predator_positions,
                                   rng=creature_rng)
                else:
                    state = eval_a(genome.forward, env, rng=creature_rng)
                genome.fitness = fit_a(state)
            pop_a.evolve()
        else:
            # Train species_b (predator), freeze species_a (prey)
            env = ENV_BUILDERS[cfg_b["env_type"]](env_rng, cfg_b["grid_size"])
            # Sample prey positions from best of pop_a
            prey_positions = []
            if not a_is_prey and pop_a.best_genome:
                for _ in range(5):
                    px = rng.integers(0, cfg_b["grid_size"])
                    py = rng.integers(0, cfg_b["grid_size"])
                    prey_positions.append((px, py))

            for genome in pop_b.genomes:
                creature_rng = np.random.default_rng(rng.integers(0, 2**31))
                if species_b == "spider":
                    state = eval_b(genome.forward, env,
                                   prey_positions=prey_positions,
                                   rng=creature_rng)
                else:
                    state = eval_b(genome.forward, env, rng=creature_rng)
                genome.fitness = fit_b(state)
            pop_b.evolve()

        if verbose and (gen % 25 == 0 or gen == generations - 1):
            phase = species_a if cycle == 0 else species_b
            best_a = pop_a.best_fitness
            best_b = pop_b.best_fitness
            print(f"  Gen {gen:4d}/{generations}  training={phase}  "
                  f"{species_a}={best_a:.1f}  {species_b}={best_b:.1f}", flush=True)

    elapsed = time.time() - start
    if verbose:
        print(f"\n  Co-evolution completed in {elapsed:.1f}s", flush=True)

    best_a = pop_a.best_genome or pop_a.genomes[0]
    best_b = pop_b.best_genome or pop_b.genomes[0]
    return {
        species_a: (best_a.to_dart_json(), best_a.fitness),
        species_b: (best_b.to_dart_json(), best_b.fitness),
    }


def train_ecosystem(generations: int = 200, seed: int = 42,
                     pretrained: dict[str, dict] | None = None,
                     verbose: bool = True) -> dict[str, tuple[dict, float]]:
    """Mode 3: Ecosystem co-evolution — all species in one 128x128 world.

    Optionally starts from pretrained individual genomes.
    """
    rng = np.random.default_rng(seed)
    all_species = list(SPECIES_CONFIGS.keys())

    if verbose:
        print(f"\n{'='*60}", flush=True)
        print(f"  ECOSYSTEM CO-EVOLUTION", flush=True)
        print(f"  Species: {', '.join(all_species)}", flush=True)
        print(f"  World: 128x128, Generations: {generations}", flush=True)
        print(f"{'='*60}\n", flush=True)

    # Create populations (smaller per-species for ecosystem)
    eco_pop_size = 50  # smaller per species in ecosystem
    populations: dict[str, NeatPopulation] = {}
    for sp in all_species:
        cfg = SPECIES_CONFIGS[sp]
        populations[sp] = NeatPopulation(
            cfg["inputs"], cfg["outputs"], eco_pop_size,
            cfg["max_hidden"], cfg["max_connections"],
            seed + hash(sp) % 1000)

    # Inject pretrained genomes if available
    if pretrained:
        for sp, genome_json in pretrained.items():
            if sp in populations:
                # Replace top genomes with pretrained
                pop = populations[sp]
                for i in range(min(5, len(pop.genomes))):
                    # Re-seed from pretrained weights
                    g = NeatGenomeLocal(
                        SPECIES_CONFIGS[sp]["inputs"],
                        SPECIES_CONFIGS[sp]["outputs"],
                        np.random.default_rng(rng.integers(0, 2**31)))
                    g.mutate()  # add variation
                    pop.genomes[i] = g

    start = time.time()

    for gen in range(generations):
        env = make_ecosystem_world(np.random.default_rng(rng.integers(0, 2**31)))
        grid = env["grid"]
        sz = grid.shape[0]
        ground_y = env["ground_y"]

        # Evaluate each species in the shared world
        for sp in all_species:
            cfg = SPECIES_CONFIGS[sp]
            evaluator = EVALUATORS[sp]
            fitness_fn = FITNESS_FUNCTIONS[sp]
            pop = populations[sp]

            # Build species-specific env from ecosystem world
            sp_env = {"grid": grid.copy(), "spawn_zone": (5, 5, sz - 5, sz - 5)}

            # Customize spawn zones
            if sp == "fish":
                wb = env.get("water_bounds", (0, sz, 0, sz))
                sp_env["spawn_zone"] = (wb[2] + 2, wb[0] + 2, wb[3] - 2, wb[1] - 2)
                sp_env["water_bounds"] = (wb[0], wb[1])
            elif sp == "worm":
                sp_env["spawn_zone"] = (5, ground_y + 2, sz - 5, sz - 5)
            elif sp in ("beetle", "ant"):
                sp_env["spawn_zone"] = (sz // 3, ground_y - 5, sz - 5, ground_y - 1)
                if sp == "ant":
                    sp_env["nest_pos"] = env.get("nest_pos", (sz // 2, ground_y - 1))
            elif sp == "bee":
                sp_env["spawn_zone"] = (sz // 2 - 10, sz // 4 - 5, sz // 2 + 10, sz // 4 + 5)
                sp_env["hive_pos"] = env.get("hive_pos", (sz // 2, sz // 4))
            elif sp == "spider":
                sp_env["spawn_zone"] = (5, ground_y - 10, sz - 5, ground_y - 1)
            elif sp == "firefly":
                sp_env["spawn_zone"] = (5, ground_y - 20, sz - 5, ground_y - 2)

            for genome in pop.genomes:
                creature_rng = np.random.default_rng(rng.integers(0, 2**31))
                try:
                    state = evaluator(genome.forward, sp_env, rng=creature_rng)
                    genome.fitness = fitness_fn(state)
                except Exception:
                    genome.fitness = 0.0
            pop.evolve()

        if verbose and (gen % 20 == 0 or gen == generations - 1):
            summary = "  ".join(
                f"{sp}={populations[sp].best_fitness:.1f}" for sp in all_species)
            print(f"  Gen {gen:4d}/{generations}  {summary}", flush=True)

    elapsed = time.time() - start
    if verbose:
        print(f"\n  Ecosystem evolution completed in {elapsed:.1f}s", flush=True)

    results = {}
    for sp in all_species:
        best = populations[sp].best_genome or populations[sp].genomes[0]
        results[sp] = (best.to_dart_json(), best.fitness)
    return results


def train_curriculum(species: str, stages: int = 4, seed: int = 42,
                     verbose: bool = True) -> tuple[dict, float]:
    """Mode 4: Curriculum training — progressive difficulty.

    Stage 1: Basic survival (food nearby, no threats)
    Stage 2: Navigation (food scattered, terrain obstacles)
    Stage 3: Social (other creatures present)
    Stage 4: Full complexity (all elements, weather, predators)
    """
    config = SPECIES_CONFIGS[species]
    rng = np.random.default_rng(seed)
    gens_per_stage = config["generations"] // stages

    if verbose:
        print(f"\n{'='*60}", flush=True)
        print(f"  CURRICULUM TRAINING: {species}", flush=True)
        print(f"  Stages: {stages}, Gens/stage: {gens_per_stage}", flush=True)
        print(f"{'='*60}\n", flush=True)

    pop = NeatPopulation(
        config["inputs"], config["outputs"], config["population"],
        config["max_hidden"], config["max_connections"], seed)

    evaluator = EVALUATORS[species]
    fitness_fn = FITNESS_FUNCTIONS[species]
    env_builder = ENV_BUILDERS[config["env_type"]]
    start = time.time()

    for stage in range(1, stages + 1):
        if verbose:
            print(f"\n  --- Stage {stage}/{stages} ---", flush=True)

        for gen in range(gens_per_stage):
            env_rng = np.random.default_rng(rng.integers(0, 2**31))
            env = env_builder(env_rng, config["grid_size"])

            # Adjust difficulty by stage
            if stage == 1:
                # Easy: more food, smaller world effective area
                grid = env["grid"]
                sz = grid.shape[0]
                # Add extra food near spawn
                x0, y0, x1, y1 = env["spawn_zone"]
                food_el = env.get("food_element", EL_SEED)
                if food_el != EL_EMPTY:
                    for _ in range(15):
                        fx = rng.integers(x0, max(x0 + 1, x1))
                        fy = rng.integers(y0, max(y0 + 1, y1))
                        if 0 <= fy < sz and 0 <= fx < sz:
                            if grid[fy, fx] == EL_EMPTY:
                                grid[fy, fx] = food_el
                max_steps = 200
            elif stage == 2:
                # Medium: normal food, add obstacles
                grid = env["grid"]
                sz = grid.shape[0]
                for _ in range(5):
                    ox = rng.integers(5, sz - 5)
                    oy_base = int(sz * 0.6)
                    if 0 <= oy_base < sz:
                        grid[oy_base, ox] = EL_STONE
                max_steps = 400
            elif stage == 3:
                # Hard: fewer food, some predator pressure
                max_steps = 500
            else:
                # Full: default environment
                max_steps = 600

            for genome in pop.genomes:
                creature_rng = np.random.default_rng(rng.integers(0, 2**31))
                state = evaluator(genome.forward, env, max_steps=max_steps,
                                  rng=creature_rng)
                # Scale fitness by stage difficulty
                genome.fitness = fitness_fn(state) * (0.5 + 0.5 * stage / stages)

            pop.evolve()

            total_gen = (stage - 1) * gens_per_stage + gen
            if verbose and (gen % 25 == 0 or gen == gens_per_stage - 1):
                avg = np.mean([g.fitness for g in pop.genomes])
                print(f"  Stage {stage} Gen {gen:4d}/{gens_per_stage}  "
                      f"best={pop.best_fitness:8.2f}  avg={avg:8.2f}", flush=True)

    elapsed = time.time() - start
    if verbose:
        print(f"\n  Curriculum training completed in {elapsed:.1f}s", flush=True)

    best = pop.best_genome or pop.genomes[0]
    return best.to_dart_json(), best.fitness


# ===================================================================
# GENOME EXPORT — TensorNEAT / neat-python compatibility
# ===================================================================

def tensorneat_to_dart_json(algorithm, state, genome_data, fitness: float = 0.0) -> dict:
    """Convert a TensorNEAT genome to our Dart NeatGenome.fromJson() format."""
    network = algorithm.genome.network_dict(state, *genome_data)
    nodes = []
    connections = []
    node_keys = network.get("nodes", network.get("node_attrs", []))
    conn_keys = network.get("conns", network.get("conn_attrs", []))
    type_map = {"input": 0, "hidden": 1, "output": 2, "bias": 3}
    if hasattr(node_keys, '__len__'):
        for i, node_data in enumerate(node_keys):
            node_id = int(node_data[0]) if hasattr(node_data, '__getitem__') else i
            n_type = 1
            nodes.append({
                "id": node_id, "type": n_type, "activation": 0, "layer": 0,
            })
    innovation = 0
    if hasattr(conn_keys, '__len__'):
        for conn_data in conn_keys:
            if hasattr(conn_data, '__getitem__') and len(conn_data) >= 3:
                connections.append({
                    "innovation": innovation,
                    "inNode": int(conn_data[0]),
                    "outNode": int(conn_data[1]),
                    "weight": float(conn_data[2]),
                    "enabled": bool(conn_data[3]) if len(conn_data) > 3 else True,
                })
                innovation += 1
    return {
        "nodes": nodes,
        "connections": connections,
        "fitness": float(fitness),
        "speciesId": -1,
    }


# ===================================================================
# GPU TRAINING — TensorNEAT pipeline (when available)
# ===================================================================

def train_gpu(species: str, generations: int, seed: int = 42) -> tuple[dict, float]:
    """Train using TensorNEAT on GPU. Falls back to CPU if unavailable."""
    if not HAS_JAX or not HAS_TENSORNEAT:
        return train_individual(species, generations, seed)

    config = SPECIES_CONFIGS[species]
    print(f"  Using JAX backend: {jax.devices()}", flush=True)
    start = time.time()

    algorithm = NEAT(
        genome=DefaultGenome(
            num_inputs=config["inputs"],
            num_outputs=config["outputs"],
            max_nodes=config["inputs"] + config["outputs"] + config["max_hidden"],
            max_conns=config["max_connections"],
            node_gene=BiasNode(),
            output_transform=ACT.tanh,
        ),
        pop_size=config["population"],
        species_size=10,
    )

    from tensorneat.problem.func_fit import CustomFuncFit

    def fitness_proxy(inputs):
        target_dx = jnp.tanh(inputs[0] * 2.0)
        target_dy = jnp.tanh(inputs[1] * 2.0) if len(inputs) > 1 else 0.0
        return jnp.array([target_dx, target_dy][:config["outputs"]])

    problem = CustomFuncFit(
        func=fitness_proxy,
        low_bounds=[-1.0] * config["inputs"],
        upper_bounds=[1.0] * config["inputs"],
        method="sample",
        num_samples=200,
    )

    pipeline = Pipeline(
        algorithm=algorithm,
        problem=problem,
        generation_limit=generations,
        fitness_target=-0.01,
        seed=seed,
    )

    state = pipeline.setup()
    state, best = pipeline.auto_run(state)
    elapsed = time.time() - start
    print(f"  GPU training complete in {elapsed:.1f}s", flush=True)

    try:
        dart_genome = tensorneat_to_dart_json(algorithm, state, best)
    except Exception as e:
        print(f"  Warning: TensorNEAT export failed ({e}), using CPU fallback", flush=True)
        return train_individual(species, generations, seed)

    return dart_genome, float(dart_genome.get("fitness", 0.0))


# ===================================================================
# SAVE / LOAD
# ===================================================================

def save_genome(species: str, genome_json: dict, fitness: float, suffix: str = "best"):
    """Save a trained genome to disk."""
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUTPUT_DIR / f"{species}_{suffix}.json"
    with open(path, "w") as f:
        json.dump(genome_json, f, indent=2)
    print(f"  Saved: {path}", flush=True)
    return path


def save_summary(results: dict, elapsed: float, mode: str):
    """Save training summary."""
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    summary = {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "mode": mode,
        "total_seconds": round(elapsed, 1),
        "estimated_cost_usd": round(elapsed / 3600 * 0.78, 2),
        "results": {},
    }
    for sp, (genome_json, fitness) in results.items():
        summary["results"][sp] = {
            "fitness": round(fitness, 2),
            "nodes": len(genome_json["nodes"]),
            "connections": len(genome_json["connections"]),
        }
    path = OUTPUT_DIR / "training_summary.json"
    with open(path, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"  Summary: {path}", flush=True)


# ===================================================================
# MAIN
# ===================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Multi-species NEAT creature training pipeline",
    )
    parser.add_argument(
        "--species",
        help="Species to train (name or 'all')",
    )
    parser.add_argument(
        "--coevolve",
        help="Co-evolve two species, comma-separated (e.g. beetle,spider)",
    )
    parser.add_argument(
        "--ecosystem", action="store_true",
        help="Run ecosystem co-evolution with all 7 species",
    )
    parser.add_argument(
        "--curriculum",
        help="Run curriculum training for a species",
    )
    parser.add_argument(
        "--stages", type=int, default=4,
        help="Number of curriculum stages (default: 4)",
    )
    parser.add_argument(
        "--generations", type=int, default=None,
        help="Override generation count",
    )
    parser.add_argument(
        "--gpu", action="store_true",
        help="Force GPU training via TensorNEAT (requires JAX)",
    )
    parser.add_argument(
        "--seed", type=int, default=42,
        help="Random seed (default: 42)",
    )

    args = parser.parse_args()

    if not any([args.species, args.coevolve, args.ecosystem, args.curriculum]):
        parser.print_help()
        print("\nExamples:", flush=True)
        print("  python creature_trainer.py --species worm --generations 200", flush=True)
        print("  python creature_trainer.py --species all --generations 500", flush=True)
        print("  python creature_trainer.py --coevolve beetle,spider --generations 300", flush=True)
        print("  python creature_trainer.py --ecosystem --generations 200", flush=True)
        print("  python creature_trainer.py --curriculum ant --stages 4", flush=True)
        return

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    total_start = time.time()
    results = {}

    # ---------------------------------------------------------------
    # Mode 1: Individual training
    # ---------------------------------------------------------------
    if args.species:
        if args.species == "all":
            species_list = list(SPECIES_CONFIGS.keys())
        elif args.species in SPECIES_CONFIGS:
            species_list = [args.species]
        else:
            print(f"Unknown species: {args.species}", flush=True)
            print(f"Available: {', '.join(SPECIES_CONFIGS.keys())}", flush=True)
            return

        for sp in species_list:
            gens = args.generations or SPECIES_CONFIGS[sp]["generations"]
            if args.gpu:
                genome_json, fitness = train_gpu(sp, gens, args.seed)
            else:
                genome_json, fitness = train_individual(sp, gens, args.seed)
            save_genome(sp, genome_json, fitness)
            results[sp] = (genome_json, fitness)

    # ---------------------------------------------------------------
    # Mode 2: Co-evolution
    # ---------------------------------------------------------------
    elif args.coevolve:
        parts = [s.strip() for s in args.coevolve.split(",")]
        if len(parts) != 2:
            print("--coevolve requires exactly two species, e.g. beetle,spider", flush=True)
            return
        for sp in parts:
            if sp not in SPECIES_CONFIGS:
                print(f"Unknown species: {sp}", flush=True)
                return
        gens = args.generations or 300
        co_results = train_coevolve(parts[0], parts[1], gens, seed=args.seed)
        for sp, (genome_json, fitness) in co_results.items():
            save_genome(sp, genome_json, fitness, suffix="coevolved")
            results[sp] = (genome_json, fitness)

    # ---------------------------------------------------------------
    # Mode 3: Ecosystem
    # ---------------------------------------------------------------
    elif args.ecosystem:
        gens = args.generations or 200
        eco_results = train_ecosystem(gens, seed=args.seed)
        for sp, (genome_json, fitness) in eco_results.items():
            save_genome(sp, genome_json, fitness, suffix="ecosystem")
            results[sp] = (genome_json, fitness)

    # ---------------------------------------------------------------
    # Mode 4: Curriculum
    # ---------------------------------------------------------------
    elif args.curriculum:
        sp = args.curriculum
        if sp not in SPECIES_CONFIGS:
            print(f"Unknown species: {sp}", flush=True)
            print(f"Available: {', '.join(SPECIES_CONFIGS.keys())}", flush=True)
            return
        genome_json, fitness = train_curriculum(
            sp, stages=args.stages, seed=args.seed)
        save_genome(sp, genome_json, fitness, suffix="curriculum")
        results[sp] = (genome_json, fitness)

    # ---------------------------------------------------------------
    # Summary
    # ---------------------------------------------------------------
    total_elapsed = time.time() - total_start
    mode = ("individual" if args.species
            else "coevolve" if args.coevolve
            else "ecosystem" if args.ecosystem
            else "curriculum")

    print(f"\n{'='*60}", flush=True)
    print(f"  TRAINING SUMMARY ({mode})", flush=True)
    print(f"{'='*60}", flush=True)
    print(f"  Total time: {total_elapsed:.1f}s ({total_elapsed/60:.1f} min)", flush=True)
    est_cost = total_elapsed / 3600 * 0.78
    print(f"  Estimated cost (A100 $0.78/hr): ${est_cost:.2f}", flush=True)
    print(flush=True)
    for sp, (genome_json, fitness) in results.items():
        n_nodes = len(genome_json["nodes"])
        n_conns = len(genome_json["connections"])
        print(f"  {sp:10s}: fitness={fitness:8.2f}  nodes={n_nodes}  conns={n_conns}", flush=True)
    print(flush=True)

    save_summary(results, total_elapsed, mode)


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        print("Self-test: imports OK", flush=True)
        # Quick validation
        rng = np.random.default_rng(42)
        env = make_worm_world(rng, 32)
        assert env["grid"].shape == (32, 32), "Grid shape wrong"
        g = NeatGenomeLocal(8, 4, rng)
        out = g.forward([0.0] * 8)
        assert len(out) == 4, "Forward pass output wrong"
        state = CreatureState(5, 5, 1.0)
        f = compute_fitness_worm(state)
        assert isinstance(f, float), "Fitness not float"
        print("Self-test: PASSED", flush=True)
        sys.exit(0)
    main()
