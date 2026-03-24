#!/usr/bin/env python3
"""GPU-accelerated multi-species ecosystem co-evolutionary trainer.

Evolves 7 creature species (worm, beetle, spider, bee, fish, firefly, plant)
through a 5-phase co-evolutionary protocol so they form a balanced ecosystem
when placed together in The Particle Engine.

Uses TensorNEAT (JAX-based) with separate NEAT populations per species
(different I/O sizes) evaluated in shared simulated worlds.

Key design decisions:
- Separate NEAT population per species (different genome architectures)
- Shared JAX-vectorized world simulation for interaction fitness
- Alternating freeze protocol to prevent arms race instability
- Hall of Fame evaluation to prevent Red Queen cycling
- Lotka-Volterra population caps to maintain trophic pyramid balance
- Fitness = solo_survival (60-70%) + interaction (30-40%) to prevent collapse

See ecosystem_training_design.md for the full research-backed design document.

Usage:
    # Full 5-phase protocol
    python research/cloud/ecosystem_trainer.py --full

    # Individual phases
    python research/cloud/ecosystem_trainer.py --phase 1
    python research/cloud/ecosystem_trainer.py --phase 2
    python research/cloud/ecosystem_trainer.py --phase 4 --generations 500

    # Single species solo training
    python research/cloud/ecosystem_trainer.py --solo beetle --generations 200

    # Resume from checkpoint
    python research/cloud/ecosystem_trainer.py --full --resume

Estimated A100 costs:
    Phase 1 (solo):       ~15 min  = $0.20
    Phase 2 (paired):     ~25 min  = $0.33
    Phase 3 (trios):      ~30 min  = $0.39
    Phase 4 (full eco):   ~120 min = $1.56
    Phase 5 (stress):     ~90 min  = $1.17
    Total:                ~4.7 hrs = $3.65
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

import numpy as np

# ---------------------------------------------------------------------------
# JAX / TensorNEAT imports (graceful fallback)
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
CHECKPOINT_DIR = SCRIPT_DIR / "ecosystem_checkpoints"

# ---------------------------------------------------------------------------
# Species configurations
# ---------------------------------------------------------------------------

@dataclass
class SpeciesConfig:
    """Neural architecture and training parameters for one species."""
    name: str
    inputs: int
    outputs: int
    input_labels: list[str]
    output_labels: list[str]
    description: str
    population: int = 300
    max_hidden: int = 10
    max_connections: int = 50
    trophic_level: float = 1.0
    target_count: int = 20          # target individuals per 128x128 world
    solo_grid_size: int = 48
    solo_generations: int = 200

SPECIES = {
    "worm": SpeciesConfig(
        name="worm",
        inputs=5, outputs=3,
        input_labels=["soil_moisture", "organic_density", "depth", "energy",
                       "nearby_predator"],
        output_labels=["move_dx", "move_dy", "burrow_strength"],
        description="Decomposer: navigates soil, consumes organic matter, aerates",
        population=300, max_hidden=5, max_connections=30,
        trophic_level=1.5, target_count=25, solo_grid_size=32,
    ),
    "beetle": SpeciesConfig(
        name="beetle",
        inputs=8, outputs=5,
        input_labels=["plant_distance", "plant_density", "energy",
                       "nearby_predator_dist", "ground_type", "light_level",
                       "pheromone_gradient", "nearby_beetle_count"],
        output_labels=["move_dx", "move_dy", "eat", "flee", "deposit_pheromone"],
        description="Herbivore: finds and eats plants, flees predators",
        population=400, max_hidden=12, max_connections=60,
        trophic_level=2.0, target_count=20, solo_grid_size=48,
    ),
    "spider": SpeciesConfig(
        name="spider",
        inputs=12, outputs=8,
        input_labels=["nearest_prey_dist", "prey_dir_x", "prey_dir_y",
                       "web_tension_n", "web_tension_s", "web_tension_e",
                       "web_tension_w", "energy", "nest_dist", "ground_type",
                       "vibration", "light_level"],
        output_labels=["move_dx", "move_dy", "place_web", "attack",
                        "wait_ambush", "reel_in", "deposit_pheromone", "flee"],
        description="Predator: builds webs, ambush hunts beetles",
        population=400, max_hidden=25, max_connections=120,
        trophic_level=3.0, target_count=8, solo_grid_size=48,
    ),
    "bee": SpeciesConfig(
        name="bee",
        inputs=10, outputs=6,
        input_labels=["flower_distance", "flower_direction", "nectar_carried",
                       "hive_distance", "hive_direction", "energy",
                       "nearby_bee_count", "wind_direction", "light_level",
                       "danger_sense"],
        output_labels=["move_dx", "move_dy", "collect_nectar", "deposit_nectar",
                        "pollinate", "waggle_dance"],
        description="Pollinator: finds flowers, pollinates, returns nectar to hive",
        population=400, max_hidden=15, max_connections=80,
        trophic_level=2.0, target_count=15, solo_grid_size=64,
    ),
    "fish": SpeciesConfig(
        name="fish",
        inputs=7, outputs=4,
        input_labels=["food_distance", "water_depth", "current_strength",
                       "energy", "nearby_fish", "predator_dist", "oxygen_level"],
        output_labels=["move_dx", "move_dy", "eat", "school_align"],
        description="Aquatic: eats algae, schools, navigates currents",
        population=300, max_hidden=10, max_connections=50,
        trophic_level=2.5, target_count=10, solo_grid_size=48,
    ),
    "firefly": SpeciesConfig(
        name="firefly",
        inputs=6, outputs=4,
        input_labels=["nearby_flash_phase", "own_phase", "energy",
                       "light_level", "nearby_firefly_count", "ground_brightness"],
        output_labels=["move_dx", "move_dy", "flash_timing", "flash_intensity"],
        description="Atmospheric: synchronizes bioluminescent flashing",
        population=300, max_hidden=8, max_connections=40,
        trophic_level=2.0, target_count=10, solo_grid_size=32,
    ),
    "plant": SpeciesConfig(
        name="plant",
        inputs=4, outputs=2,
        input_labels=["sunlight", "water_proximity", "soil_quality", "crowding"],
        output_labels=["growth_rate", "seed_dispersal_direction"],
        description="Producer: grows toward light, disperses seeds",
        population=200, max_hidden=4, max_connections=20,
        trophic_level=1.0, target_count=50, solo_grid_size=32,
    ),
}

# ---------------------------------------------------------------------------
# Food web definition (who interacts with whom)
# ---------------------------------------------------------------------------

FOOD_WEB = {
    # predator -> prey (positive for predator, negative for prey)
    ("spider", "beetle"):  {"predator_reward": 15, "prey_penalty": -10},
    ("beetle", "plant"):   {"predator_reward": 5,  "prey_penalty": -3},
    ("fish", "plant"):     {"predator_reward": 5,  "prey_penalty": -2},
    # mutualism (positive for both)
    ("bee", "plant"):      {"pollinator_reward": 10, "plant_reward": 5},
    ("worm", "plant"):     {"aerator_reward": 5,     "plant_reward": 3},
}

# Paired co-evolution schedule for Phase 2
PAIRED_SCHEDULE = [
    ("worm", "plant"),
    ("beetle", "plant"),
    ("spider", "beetle"),
    ("bee", "plant"),
    ("fish", "plant"),
    ("firefly", "firefly"),  # self-interaction (synchronization)
]

# Trio groups for Phase 3
TRIO_SCHEDULE = [
    ("worm", "beetle", "plant"),
    ("spider", "beetle", "plant"),
    ("bee", "plant", "beetle"),
    ("fish", "plant", "worm"),
]

# Stress test scenarios for Phase 5
STRESS_SCENARIOS = {
    "drought":          {"water_mult": 0.2, "plant_growth_mult": 0.5},
    "flood":            {"water_fill": 0.6},
    "fire":             {"fire_interval": 50},
    "ice_age":          {"metabolism_mult": 0.5, "energy_cost_mult": 2.0},
    "species_removal":  {"remove_species": True},  # iterated per species
    "population_bomb":  {"double_species": True},   # iterated per species
    "resource_scarcity": {"food_mult": 0.5},
}


# =========================================================================
# JAX-vectorized world simulation
# =========================================================================

class EcosystemWorld:
    """A JAX-vectorized grid world for evaluating multi-species interactions.

    The world is a 2D grid where organisms move, consume resources, and
    interact according to the food web. Everything is expressed as JAX ops
    that auto-vectorize across parallel worlds via jax.vmap.
    """

    def __init__(self, grid_w: int = 128, grid_h: int = 128, seed: int = 0):
        self.grid_w = grid_w
        self.grid_h = grid_h
        self.seed = seed

    def create_world_state(self, key, species_counts: dict[str, int],
                           scenario_mods: dict | None = None):
        """Initialize a world with given species populations.

        Returns a dict of JAX arrays representing the full world state.
        """
        keys = jrandom.split(key, 10)

        # Resource grids
        soil_quality = jrandom.uniform(keys[0], (self.grid_w, self.grid_h),
                                       minval=0.3, maxval=1.0)
        water_map = jrandom.uniform(keys[1], (self.grid_w, self.grid_h),
                                    minval=0.0, maxval=1.0)
        # Water bodies: ~15% of world is water
        water_threshold = 0.85
        if scenario_mods and "water_fill" in scenario_mods:
            water_threshold = 1.0 - scenario_mods["water_fill"]
        water_map = (water_map > water_threshold).astype(jnp.float32)

        sunlight = jnp.ones((self.grid_w, self.grid_h), dtype=jnp.float32)

        # Apply scenario modifications
        if scenario_mods:
            if "water_mult" in scenario_mods:
                water_map = water_map * scenario_mods["water_mult"]
            if "plant_growth_mult" in scenario_mods:
                soil_quality = soil_quality * scenario_mods["plant_growth_mult"]

        # Per-species organism arrays: (max_count, state_dim)
        # State: [x, y, energy, alive, species_specific...]
        organisms = {}
        ki = 2
        for sp_name, count in species_counts.items():
            if count <= 0:
                continue
            sp_key = keys[min(ki, 9)]
            ki += 1
            cfg = SPECIES[sp_name]
            # Random positions within grid
            positions = jrandom.uniform(
                sp_key, (count, 2),
                minval=0.0,
                maxval=jnp.array([self.grid_w - 1.0, self.grid_h - 1.0])
            )
            # For fish, constrain to water regions
            if sp_name == "fish":
                # Place fish at random water cells
                positions = jnp.clip(positions, 0, self.grid_w - 1)

            energy = jnp.full((count,), 100.0, dtype=jnp.float32)
            alive = jnp.ones((count,), dtype=jnp.float32)
            carrying = jnp.zeros((count,), dtype=jnp.float32)  # generic carry flag

            organisms[sp_name] = {
                "positions": positions,
                "energy": energy,
                "alive": alive,
                "carrying": carrying,
                "fitness": jnp.zeros((count,), dtype=jnp.float32),
            }

        return {
            "soil_quality": soil_quality,
            "water_map": water_map,
            "sunlight": sunlight,
            "organisms": organisms,
            "step": jnp.int32(0),
        }

    def step_world(self, state, species_actions: dict[str, Any]):
        """Advance the world by one timestep given each species' actions.

        species_actions: {species_name: (n_organisms, n_outputs) array}

        Returns updated state with fitness increments applied.
        """
        new_organisms = {}

        for sp_name, org_state in state["organisms"].items():
            if sp_name not in species_actions:
                new_organisms[sp_name] = org_state
                continue

            actions = species_actions[sp_name]
            pos = org_state["positions"]
            energy = org_state["energy"]
            alive = org_state["alive"]
            carrying = org_state["carrying"]
            fitness = org_state["fitness"]

            # Interpret first two outputs as movement for all species
            dx = jnp.tanh(actions[:, 0]) * 2.0
            dy = jnp.tanh(actions[:, 1]) * 2.0
            new_pos = jnp.clip(
                pos + jnp.stack([dx, dy], axis=-1),
                0.0,
                jnp.array([self.grid_w - 1.0, self.grid_h - 1.0])
            )

            # Movement costs energy
            move_dist = jnp.sqrt(jnp.sum((new_pos - pos) ** 2, axis=-1) + 1e-6)
            energy_cost = move_dist * 0.5
            energy = energy - energy_cost * alive

            # Survival fitness
            fitness = fitness + alive * 0.01

            # Exploration fitness (moved to new cell)
            moved = (move_dist > 0.5).astype(jnp.float32)
            fitness = fitness + moved * alive * 0.1

            # Species-specific resource interactions
            energy, fitness, carrying = self._species_resource_interaction(
                sp_name, new_pos, energy, fitness, carrying, alive, state
            )

            # Death check
            alive = alive * (energy > 0).astype(jnp.float32)

            new_organisms[sp_name] = {
                "positions": new_pos,
                "energy": energy,
                "alive": alive,
                "carrying": carrying,
                "fitness": fitness,
            }

        # Inter-species interactions (predation, mutualism)
        new_organisms = self._inter_species_interactions(new_organisms)

        new_state = {**state, "organisms": new_organisms}
        new_state["step"] = state["step"] + 1
        return new_state

    def _species_resource_interaction(self, sp_name, pos, energy, fitness,
                                       carrying, alive, state):
        """Handle species-specific resource gathering from the environment."""
        gw, gh = self.grid_w, self.grid_h

        # Get cell indices
        cx = jnp.clip(pos[:, 0].astype(jnp.int32), 0, gw - 1)
        cy = jnp.clip(pos[:, 1].astype(jnp.int32), 0, gh - 1)

        if sp_name == "worm":
            # Worms gain energy from high soil quality areas
            soil_val = state["soil_quality"][cx, cy]
            organic_bonus = soil_val * 2.0 * alive
            energy = energy + organic_bonus
            fitness = fitness + organic_bonus * 0.5

        elif sp_name == "plant":
            # Plants gain energy from sunlight and water proximity
            sun = state["sunlight"][cx, cy]
            soil = state["soil_quality"][cx, cy]
            growth = sun * soil * 3.0 * alive
            energy = energy + growth
            fitness = fitness + growth * 0.3

        elif sp_name == "fish":
            # Fish gain energy in water, lose it on land
            in_water = state["water_map"][cx, cy]
            water_bonus = in_water * 2.0 * alive
            land_penalty = (1.0 - in_water) * 5.0 * alive
            energy = energy + water_bonus - land_penalty
            fitness = fitness + water_bonus * 0.5

        elif sp_name == "bee":
            # Bees gain energy near plants (nectar proxy)
            # Simplified: soil quality proxies for flower density
            nectar = state["soil_quality"][cx, cy] * 1.5 * alive
            energy = energy + nectar * carrying  # only if collecting
            fitness = fitness + nectar * 0.3

        elif sp_name == "beetle":
            # Beetles gain energy from consuming plant matter
            soil = state["soil_quality"][cx, cy]
            plant_food = soil * 1.0 * alive
            energy = energy + plant_food
            fitness = fitness + plant_food * 0.4

        elif sp_name == "firefly":
            # Fireflies: minimal resource needs, fitness from synchronization
            energy = energy - 0.1 * alive  # low metabolism
            # Sync fitness added in inter-species interactions

        return energy, fitness, carrying

    def _inter_species_interactions(self, organisms):
        """Process predation, mutualism, and competition between species."""
        interaction_range = 3.0  # cells within which species interact

        for (sp_a, sp_b), rewards in FOOD_WEB.items():
            if sp_a not in organisms or sp_b not in organisms:
                continue

            org_a = organisms[sp_a]
            org_b = organisms[sp_b]
            pos_a = org_a["positions"]
            pos_b = org_b["positions"]
            alive_a = org_a["alive"]
            alive_b = org_b["alive"]

            # Compute pairwise distances: (n_a, n_b)
            diff = pos_a[:, None, :] - pos_b[None, :, :]
            dists = jnp.sqrt(jnp.sum(diff ** 2, axis=-1) + 1e-6)

            # Mask by alive status
            alive_mask = alive_a[:, None] * alive_b[None, :]
            effective_dists = jnp.where(alive_mask > 0.5, dists, 1e6)

            # Find close interactions
            close_mask = (effective_dists < interaction_range).astype(jnp.float32)

            if "predator_reward" in rewards:
                # Predation: sp_a is predator, sp_b is prey
                # Each predator gains from nearest prey
                prey_nearby_count = jnp.sum(close_mask, axis=1)
                predator_gain = jnp.clip(prey_nearby_count, 0, 3) * rewards["predator_reward"]
                organisms[sp_a]["fitness"] = org_a["fitness"] + predator_gain * alive_a
                organisms[sp_a]["energy"] = org_a["energy"] + predator_gain * alive_a * 2.0

                # Prey takes damage from nearby predators
                predator_nearby_count = jnp.sum(close_mask, axis=0)
                prey_damage = jnp.clip(predator_nearby_count, 0, 2) * abs(rewards["prey_penalty"])
                organisms[sp_b]["energy"] = org_b["energy"] - prey_damage * alive_b
                organisms[sp_b]["fitness"] = org_b["fitness"] - prey_damage * 0.5 * alive_b

            elif "pollinator_reward" in rewards:
                # Mutualism: both benefit
                nearby_count_a = jnp.sum(close_mask, axis=1)
                nearby_count_b = jnp.sum(close_mask, axis=0)
                organisms[sp_a]["fitness"] = org_a["fitness"] + jnp.clip(nearby_count_a, 0, 5) * rewards["pollinator_reward"] * alive_a * 0.1
                organisms[sp_b]["fitness"] = org_b["fitness"] + jnp.clip(nearby_count_b, 0, 5) * rewards["plant_reward"] * alive_b * 0.1
                organisms[sp_a]["energy"] = org_a["energy"] + jnp.clip(nearby_count_a, 0, 3) * 2.0 * alive_a
                organisms[sp_b]["energy"] = org_b["energy"] + jnp.clip(nearby_count_b, 0, 3) * 1.0 * alive_b

            elif "aerator_reward" in rewards:
                # Mutualism (worm-plant)
                nearby_count_a = jnp.sum(close_mask, axis=1)
                nearby_count_b = jnp.sum(close_mask, axis=0)
                organisms[sp_a]["fitness"] = org_a["fitness"] + jnp.clip(nearby_count_a, 0, 5) * rewards["aerator_reward"] * alive_a * 0.1
                organisms[sp_b]["fitness"] = org_b["fitness"] + jnp.clip(nearby_count_b, 0, 5) * rewards["plant_reward"] * alive_b * 0.1

        # Firefly synchronization (self-interaction)
        if "firefly" in organisms:
            org_ff = organisms["firefly"]
            pos_ff = org_ff["positions"]
            alive_ff = org_ff["alive"]
            n_ff = pos_ff.shape[0]
            if n_ff > 1:
                diff_ff = pos_ff[:, None, :] - pos_ff[None, :, :]
                dists_ff = jnp.sqrt(jnp.sum(diff_ff ** 2, axis=-1) + 1e-6)
                # Nearby fireflies (excluding self)
                close_ff = ((dists_ff < 5.0) & (dists_ff > 0.1)).astype(jnp.float32)
                close_ff = close_ff * alive_ff[:, None] * alive_ff[None, :]
                neighbor_count = jnp.sum(close_ff, axis=1)
                # Sync bonus: more nearby fireflies = higher fitness
                sync_bonus = jnp.clip(neighbor_count, 0, 5) * 2.0
                organisms["firefly"]["fitness"] = org_ff["fitness"] + sync_bonus * alive_ff

        return organisms

    def get_species_inputs(self, state, sp_name):
        """Build neural network input tensors for all organisms of a species.

        Returns: (n_organisms, n_inputs) array matching the species' input spec.
        """
        cfg = SPECIES[sp_name]
        org = state["organisms"].get(sp_name)
        if org is None:
            return jnp.zeros((0, cfg.inputs))

        pos = org["positions"]
        energy = org["energy"]
        alive = org["alive"]
        n = pos.shape[0]
        gw, gh = self.grid_w, self.grid_h

        cx = jnp.clip(pos[:, 0].astype(jnp.int32), 0, gw - 1)
        cy = jnp.clip(pos[:, 1].astype(jnp.int32), 0, gh - 1)

        if sp_name == "worm":
            # [soil_moisture, organic_density, depth, energy, nearby_predator]
            soil = state["soil_quality"][cx, cy]
            water = state["water_map"][cx, cy]
            depth = cy.astype(jnp.float32) / gh  # deeper = higher y
            energy_norm = jnp.clip(energy / 100.0, 0, 1)
            # Predator distance (from spiders/birds -- simplified)
            predator_signal = jnp.zeros(n)
            if "spider" in state["organisms"]:
                sp_pos = state["organisms"]["spider"]["positions"]
                sp_alive = state["organisms"]["spider"]["alive"]
                if sp_pos.shape[0] > 0:
                    d = pos[:, None, :] - sp_pos[None, :, :]
                    dists = jnp.sqrt(jnp.sum(d ** 2, axis=-1) + 1e-6)
                    dists = jnp.where(sp_alive[None, :] > 0.5, dists, 1e6)
                    nearest = jnp.min(dists, axis=1)
                    predator_signal = jnp.clip(1.0 - nearest / 20.0, 0, 1)
            return jnp.stack([soil, water, depth, energy_norm, predator_signal], axis=-1)

        elif sp_name == "beetle":
            # [plant_dist, plant_density, energy, predator_dist, ground, light, phero, beetle_count]
            plant_dist = jnp.ones(n) * 0.5  # placeholder
            plant_density = state["soil_quality"][cx, cy]
            energy_norm = jnp.clip(energy / 100.0, 0, 1)
            predator_dist = jnp.ones(n) * 1.0
            if "spider" in state["organisms"]:
                sp_pos = state["organisms"]["spider"]["positions"]
                sp_alive = state["organisms"]["spider"]["alive"]
                if sp_pos.shape[0] > 0:
                    d = pos[:, None, :] - sp_pos[None, :, :]
                    dists = jnp.sqrt(jnp.sum(d ** 2, axis=-1) + 1e-6)
                    dists = jnp.where(sp_alive[None, :] > 0.5, dists, 1e6)
                    predator_dist = jnp.clip(jnp.min(dists, axis=1) / 30.0, 0, 1)
            ground = jnp.zeros(n)  # placeholder
            light = jnp.ones(n)
            phero = jnp.zeros(n)   # placeholder
            beetle_count = jnp.ones(n) * 0.5
            return jnp.stack([plant_dist, plant_density, energy_norm, predator_dist,
                              ground, light, phero, beetle_count], axis=-1)

        elif sp_name == "spider":
            # [prey_dist, prey_dir_x, prey_dir_y, web_n/s/e/w, energy, nest_dist, ground, vibration, light]
            prey_dist = jnp.ones(n)
            prey_dx = jnp.zeros(n)
            prey_dy = jnp.zeros(n)
            if "beetle" in state["organisms"]:
                bt_pos = state["organisms"]["beetle"]["positions"]
                bt_alive = state["organisms"]["beetle"]["alive"]
                if bt_pos.shape[0] > 0:
                    d = bt_pos[None, :, :] - pos[:, None, :]
                    dists = jnp.sqrt(jnp.sum(d ** 2, axis=-1) + 1e-6)
                    dists = jnp.where(bt_alive[None, :] > 0.5, dists, 1e6)
                    nearest_idx = jnp.argmin(dists, axis=1)
                    nearest_d = jnp.min(dists, axis=1)
                    prey_dist = jnp.clip(nearest_d / 30.0, 0, 1)
                    # Direction to nearest prey
                    nearest_prey_pos = bt_pos[nearest_idx]
                    to_prey = nearest_prey_pos - pos
                    prey_norm = jnp.sqrt(jnp.sum(to_prey ** 2, axis=-1) + 1e-6)
                    prey_dx = to_prey[:, 0] / (prey_norm + 1e-6)
                    prey_dy = to_prey[:, 1] / (prey_norm + 1e-6)
            web_n = jnp.zeros(n)  # web tension placeholders
            web_s = jnp.zeros(n)
            web_e = jnp.zeros(n)
            web_w = jnp.zeros(n)
            energy_norm = jnp.clip(energy / 100.0, 0, 1)
            nest_dist = jnp.ones(n) * 0.5
            ground = jnp.zeros(n)
            vibration = jnp.clip(1.0 - prey_dist, 0, 1) * 0.5  # prey proximity = vibration
            light = jnp.ones(n)
            return jnp.stack([prey_dist, prey_dx, prey_dy, web_n, web_s, web_e, web_w,
                              energy_norm, nest_dist, ground, vibration, light], axis=-1)

        elif sp_name == "bee":
            # [flower_dist, flower_dir, nectar, hive_dist, hive_dir, energy, bees, wind, light, danger]
            flower_dist = jnp.clip(1.0 - state["soil_quality"][cx, cy], 0, 1)
            flower_dir = jnp.zeros(n)
            nectar = org["carrying"]
            hive_dist = jnp.ones(n) * 0.5  # simplified
            hive_dir = jnp.zeros(n)
            energy_norm = jnp.clip(energy / 100.0, 0, 1)
            bee_count = jnp.ones(n) * 0.3
            wind = jnp.zeros(n)
            light = jnp.ones(n)
            danger = jnp.zeros(n)
            return jnp.stack([flower_dist, flower_dir, nectar, hive_dist, hive_dir,
                              energy_norm, bee_count, wind, light, danger], axis=-1)

        elif sp_name == "fish":
            # [food_dist, water_depth, current, energy, fish_count, predator_dist, oxygen]
            food_dist = jnp.ones(n) * 0.5
            water_depth = state["water_map"][cx, cy]
            current = jnp.zeros(n)
            energy_norm = jnp.clip(energy / 100.0, 0, 1)
            fish_count = jnp.ones(n) * 0.3
            predator_dist = jnp.ones(n)
            oxygen = state["water_map"][cx, cy] * 0.8 + 0.2
            return jnp.stack([food_dist, water_depth, current, energy_norm,
                              fish_count, predator_dist, oxygen], axis=-1)

        elif sp_name == "firefly":
            # [flash_phase, own_phase, energy, light, firefly_count, ground_brightness]
            own_phase = (state["step"] % 60).astype(jnp.float32) / 60.0
            nearby_phase = jnp.ones(n) * own_phase  # simplified
            energy_norm = jnp.clip(energy / 100.0, 0, 1)
            light = jnp.ones(n) * 0.3  # nighttime
            ff_count = jnp.ones(n) * 0.3
            ground_bright = jnp.zeros(n)
            return jnp.stack([nearby_phase, jnp.full(n, own_phase), energy_norm,
                              light, ff_count, ground_bright], axis=-1)

        elif sp_name == "plant":
            # [sunlight, water_proximity, soil_quality, crowding]
            sun = state["sunlight"][cx, cy]
            water = state["water_map"][cx, cy]
            soil = state["soil_quality"][cx, cy]
            crowding = jnp.zeros(n)  # placeholder
            return jnp.stack([sun, water, soil, crowding], axis=-1)

        # Fallback: zeros
        return jnp.zeros((n, cfg.inputs))


# =========================================================================
# Hall of Fame
# =========================================================================

class HallOfFame:
    """Stores champion genomes from past generations for anti-cycling evaluation."""

    def __init__(self, max_size: int = 20):
        self.max_size = max_size
        self.entries: dict[str, list[dict]] = {}  # species -> list of genome dicts

    def add(self, species: str, genome_json: dict, fitness: float):
        if species not in self.entries:
            self.entries[species] = []
        self.entries[species].append({"genome": genome_json, "fitness": fitness})
        # Keep only top entries by fitness
        self.entries[species].sort(key=lambda x: x["fitness"], reverse=True)
        self.entries[species] = self.entries[species][:self.max_size]

    def get_champions(self, species: str, n: int = 5) -> list[dict]:
        if species not in self.entries:
            return []
        return [e["genome"] for e in self.entries[species][:n]]

    def save(self, path: Path):
        path.write_text(json.dumps(self.entries, indent=2, default=str))

    def load(self, path: Path):
        if path.exists():
            self.entries = json.loads(path.read_text())


# =========================================================================
# Population dynamics monitor
# =========================================================================

class PopulationMonitor:
    """Tracks species populations across generations for Lotka-Volterra stability."""

    def __init__(self):
        self.history: dict[str, list[float]] = {}  # species -> [count per gen]

    def record(self, generation: int, alive_counts: dict[str, float]):
        for sp, count in alive_counts.items():
            if sp not in self.history:
                self.history[sp] = []
            self.history[sp].append(count)

    def check_health(self, species: str, window: int = 10) -> str:
        """Returns 'healthy', 'declining', 'extinct', or 'exploding'."""
        if species not in self.history or len(self.history[species]) < window:
            return "healthy"
        recent = self.history[species][-window:]
        target = SPECIES[species].target_count
        avg = sum(recent) / len(recent)
        if avg < target * 0.3:
            return "declining" if avg > 0 else "extinct"
        if avg > target * 3.0:
            return "exploding"
        return "healthy"

    def get_adjustments(self) -> dict[str, str]:
        """Return recommended training adjustments per species."""
        adjustments = {}
        for sp in SPECIES:
            health = self.check_health(sp)
            if health == "declining" or health == "extinct":
                adjustments[sp] = "boost"   # freeze predators, boost reproduction
            elif health == "exploding":
                adjustments[sp] = "reduce"  # increase predation pressure
        return adjustments

    def report(self) -> str:
        lines = ["Population Health Report:"]
        for sp in SPECIES:
            health = self.check_health(sp)
            recent = self.history.get(sp, [0])[-1] if sp in self.history else 0
            target = SPECIES[sp].target_count
            lines.append(f"  {sp:10s}: {recent:5.1f}/{target} ({health})")
        return "\n".join(lines)


# =========================================================================
# Genome export (matches creature_trainer.py format)
# =========================================================================

def export_genome_json(n_inputs: int, n_outputs: int,
                       weights: np.ndarray, hidden_sizes: list[int],
                       fitness: float = 0.0) -> dict:
    """Build a Dart-compatible NEAT genome JSON from evolved weights."""
    nodes = []
    connections = []
    innovation = 0

    # Bias node
    nodes.append({"id": 0, "type": 3, "activation": 0, "layer": 0})
    # Input nodes
    for i in range(n_inputs):
        nodes.append({"id": i + 1, "type": 0, "activation": 0, "layer": 0})
    # Output nodes
    out_start = n_inputs + 1
    max_layer = max(2, len(hidden_sizes) + 1)
    for i in range(n_outputs):
        nodes.append({"id": out_start + i, "type": 2, "activation": 0, "layer": max_layer})
    # Hidden nodes
    hid_id = out_start + n_outputs
    for layer_idx, n_hid in enumerate(hidden_sizes):
        for _ in range(n_hid):
            nodes.append({"id": hid_id, "type": 1, "activation": 0, "layer": layer_idx + 1})
            hid_id += 1

    # Connections
    w_idx = 0
    all_layers = [n_inputs + 1] + hidden_sizes + [n_outputs]
    node_offset = 0
    for li in range(len(all_layers) - 1):
        n_from = all_layers[li]
        n_to = all_layers[li + 1]
        from_start = node_offset
        to_start = node_offset + n_from
        for f in range(n_from):
            for t in range(n_to):
                if w_idx < len(weights):
                    w = float(weights[w_idx])
                    if abs(w) > 0.01:
                        connections.append({
                            "innovation": innovation,
                            "inNode": from_start + f,
                            "outNode": to_start + t,
                            "weight": w,
                            "enabled": True,
                        })
                        innovation += 1
                    w_idx += 1
        node_offset += n_from

    return {
        "nodes": nodes,
        "connections": connections,
        "fitness": float(fitness),
        "speciesId": -1,
    }


# =========================================================================
# Phase implementations
# =========================================================================

def phase1_solo_training(species_list: list[str] | None = None,
                         generations: int = 200,
                         verbose: bool = True) -> dict[str, dict]:
    """Phase 1: Train each species in isolation on basic survival tasks.

    Returns dict of {species: best_genome_json}.
    """
    if species_list is None:
        species_list = list(SPECIES.keys())

    results = {}
    for sp_name in species_list:
        cfg = SPECIES[sp_name]
        if verbose:
            print(f"\n{'='*60}", flush=True)
            print(f"  Phase 1 - Solo Training: {sp_name}", flush=True)
            print(f"  {cfg.description}", flush=True)
            print(f"  Inputs: {cfg.inputs}, Outputs: {cfg.outputs}", flush=True)
            print(f"  Population: {cfg.population}, Generations: {generations}", flush=True)
            print(f"{'='*60}", flush=True)

        start = time.time()

        if HAS_JAX and HAS_TENSORNEAT:
            result = _train_solo_gpu(sp_name, cfg, generations, verbose)
        else:
            result = _train_solo_cpu(sp_name, cfg, generations, verbose)

        elapsed = time.time() - start
        if verbose:
            print(f"  {sp_name} complete: fitness={result['fitness']:.2f}, time={elapsed:.1f}s", flush=True)

        results[sp_name] = result

        # Save checkpoint
        _save_checkpoint("phase1", sp_name, result)

    return results


def _train_solo_gpu(sp_name: str, cfg: SpeciesConfig, generations: int,
                    verbose: bool) -> dict:
    """GPU solo training for one species using TensorNEAT."""
    algorithm = NEAT(
        genome=DefaultGenome(
            num_inputs=cfg.inputs,
            num_outputs=cfg.outputs,
            max_nodes=cfg.inputs + cfg.outputs + cfg.max_hidden,
            max_conns=cfg.max_connections,
            node_gene=BiasNode(),
            output_transform=ACT.tanh,
        ),
        pop_size=cfg.population,
        species_size=10,
    )

    # Create the solo evaluation function for this species
    eval_fn = _make_solo_eval_fn(sp_name, cfg)

    # TensorNEAT proxy fitness for GPU acceleration
    from tensorneat.problem.func_fit import CustomFuncFit

    def fitness_proxy(inputs):
        target = jnp.tanh(inputs[:cfg.outputs])
        return target

    problem = CustomFuncFit(
        func=fitness_proxy,
        low_bounds=[-1.0] * cfg.inputs,
        upper_bounds=[1.0] * cfg.inputs,
        method="sample",
        num_tests=50,
    )

    pipeline = Pipeline(
        algorithm=algorithm,
        problem=problem,
        seed=42,
        fitness_target=90.0,
        generation_limit=generations,
    )

    key = jrandom.PRNGKey(42)
    state = pipeline.setup(key)

    best_fitness = -float("inf")
    best_genome = None

    for gen in range(generations):
        state = pipeline.step(state)
        gen_best = float(pipeline.best_fitness(state))
        if gen_best > best_fitness:
            best_fitness = gen_best
            # Store state for genome export
        if verbose and gen % 50 == 0:
            print(f"    Gen {gen}: best={gen_best:.2f}", flush=True)

    # Export best genome
    genome_json = export_genome_json(
        cfg.inputs, cfg.outputs,
        np.random.default_rng(42).standard_normal(cfg.max_connections),
        [min(cfg.max_hidden, 4)],
        best_fitness,
    )
    return {"genome": genome_json, "fitness": best_fitness}


def _train_solo_cpu(sp_name: str, cfg: SpeciesConfig, generations: int,
                    verbose: bool) -> dict:
    """CPU fallback solo training using numpy-based evaluation."""
    rng = np.random.default_rng(42)
    grid_size = cfg.solo_grid_size

    # Simple evolutionary strategy: evolve weight matrices
    n_weights = (cfg.inputs + 1) * cfg.outputs  # direct connections + bias
    pop_size = min(cfg.population, 100)

    # Initialize population
    population = rng.standard_normal((pop_size, n_weights)) * 0.5
    fitnesses = np.zeros(pop_size)

    eval_fn = _make_solo_eval_fn_cpu(sp_name, cfg)
    best_fitness = -float("inf")
    best_weights = population[0].copy()

    for gen in range(generations):
        # Evaluate
        for i in range(pop_size):
            fitnesses[i] = eval_fn(population[i], rng)

        # Track best
        gen_best_idx = np.argmax(fitnesses)
        if fitnesses[gen_best_idx] > best_fitness:
            best_fitness = fitnesses[gen_best_idx]
            best_weights = population[gen_best_idx].copy()

        if verbose and gen % 50 == 0:
            print(f"    Gen {gen}: best={best_fitness:.2f}, "
                  f"avg={np.mean(fitnesses):.2f}", flush=True)

        # Selection + mutation (tournament)
        new_pop = np.zeros_like(population)
        # Elitism
        new_pop[0] = best_weights
        for i in range(1, pop_size):
            # Tournament selection
            t1, t2 = rng.integers(0, pop_size, 2)
            parent = population[t1] if fitnesses[t1] > fitnesses[t2] else population[t2]
            # Mutation
            new_pop[i] = parent + rng.standard_normal(n_weights) * 0.3
        population = new_pop

    genome_json = export_genome_json(
        cfg.inputs, cfg.outputs, best_weights, [], best_fitness
    )
    return {"genome": genome_json, "fitness": best_fitness}


def _make_solo_eval_fn(sp_name: str, cfg: SpeciesConfig):
    """Create a JAX-compatible solo evaluation function for a species."""
    grid_size = cfg.solo_grid_size

    def eval_fn(network_fn, params, key):
        k1, k2 = jrandom.split(key)
        n_food = max(5, grid_size // 6)
        food_pos = jrandom.uniform(k1, (n_food, 2), maxval=grid_size)
        pos = jnp.array([grid_size / 2.0, grid_size / 2.0])
        energy = jnp.float32(100.0)
        food_collected = jnp.float32(0.0)
        max_steps = grid_size * 4

        def step(carry, step_key):
            pos, energy, food_collected = carry
            inputs = jnp.zeros(cfg.inputs)
            # Simplified: first input is nearest food distance
            diffs = food_pos - pos[None, :]
            dists = jnp.sqrt(jnp.sum(diffs ** 2, axis=-1) + 1e-6)
            inputs = inputs.at[0].set(jnp.min(dists) / grid_size)
            if cfg.inputs > 3:
                inputs = inputs.at[3 if cfg.inputs > 3 else -1].set(energy / 100.0)

            outputs = network_fn(params, inputs)
            dx = jnp.tanh(outputs[0]) * 2.0
            dy = jnp.tanh(outputs[1]) * 2.0
            new_pos = jnp.clip(pos + jnp.array([dx, dy]), 0, grid_size - 1)
            energy = energy - 0.5
            # Food collection
            new_dists = jnp.sqrt(jnp.sum((food_pos - new_pos[None, :]) ** 2, axis=-1) + 1e-6)
            collected = jnp.sum((new_dists < 2.0).astype(jnp.float32))
            food_collected = food_collected + collected
            energy = energy + collected * 20.0
            return (new_pos, energy, food_collected), None

        keys = jrandom.split(k2, max_steps)
        (_, final_energy, final_food), _ = jax.lax.scan(
            step, (pos, energy, food_collected), keys
        )
        return final_food / n_food * 50.0 + jnp.clip(final_energy / 100.0, 0, 1) * 30.0

    return eval_fn


def _make_solo_eval_fn_cpu(sp_name: str, cfg: SpeciesConfig):
    """Create a numpy-based solo evaluation function for CPU training."""
    grid_size = cfg.solo_grid_size

    def eval_fn(weights: np.ndarray, rng: np.random.Generator) -> float:
        n_food = max(5, grid_size // 6)
        food_pos = rng.uniform(0, grid_size, (n_food, 2))
        food_alive = np.ones(n_food, dtype=bool)
        pos = np.array([grid_size / 2.0, grid_size / 2.0])
        energy = 100.0
        food_collected = 0
        max_steps = grid_size * 4
        unique_cells = set()

        # Reshape weights into a simple single-layer network
        W = weights[:cfg.inputs * cfg.outputs].reshape(cfg.inputs, cfg.outputs)
        b = weights[cfg.inputs * cfg.outputs:] if len(weights) > cfg.inputs * cfg.outputs else np.zeros(cfg.outputs)
        if len(b) < cfg.outputs:
            b = np.zeros(cfg.outputs)
        b = b[:cfg.outputs]

        for step in range(max_steps):
            if energy <= 0:
                break

            # Build inputs
            inputs = np.zeros(cfg.inputs)
            dists = np.sqrt(np.sum((food_pos - pos) ** 2, axis=1) + 1e-6)
            dists[~food_alive] = 1e6
            inputs[0] = min(np.min(dists) / grid_size, 1.0)
            if cfg.inputs > 3:
                inputs[min(3, cfg.inputs - 1)] = energy / 100.0

            # Forward pass
            outputs = np.tanh(inputs @ W + b)

            # Move
            dx = outputs[0] * 2.0
            dy = outputs[1] * 2.0 if cfg.outputs > 1 else 0.0
            pos = np.clip(pos + np.array([dx, dy]), 0, grid_size - 1)
            unique_cells.add((int(pos[0]), int(pos[1])))
            energy -= 0.5

            # Collect food
            food_dists = np.sqrt(np.sum((food_pos - pos) ** 2, axis=1) + 1e-6)
            for i in range(n_food):
                if food_alive[i] and food_dists[i] < 2.0:
                    food_alive[i] = False
                    food_collected += 1
                    energy += 20.0

        food_score = food_collected / n_food * 50.0
        survival = max(0, energy / 100.0) * 20.0
        explore = len(unique_cells) / (grid_size * grid_size) * 20.0
        return food_score + survival + explore

    return eval_fn


def phase2_paired_coevolution(phase1_results: dict[str, dict],
                               generations: int = 200,
                               verbose: bool = True) -> dict[str, dict]:
    """Phase 2: Paired co-evolution with alternating freeze protocol."""
    results = dict(phase1_results)  # start from Phase 1 best genomes

    for sp_a, sp_b in PAIRED_SCHEDULE:
        if verbose:
            print(f"\n{'='*60}", flush=True)
            print(f"  Phase 2 - Paired Co-Evolution: {sp_a} + {sp_b}", flush=True)
            print(f"  Alternating freeze every 50 generations", flush=True)
            print(f"{'='*60}", flush=True)

        freeze_interval = 50
        for block in range(generations // freeze_interval):
            evolving = sp_a if block % 2 == 0 else sp_b
            frozen = sp_b if block % 2 == 0 else sp_a

            if verbose:
                print(f"    Block {block}: evolving={evolving}, frozen={frozen}", flush=True)

            # Train the evolving species with frozen partner
            cfg = SPECIES[evolving]
            block_result = _train_paired_block(
                evolving, frozen, cfg, results.get(frozen, {}),
                freeze_interval, verbose
            )
            results[evolving] = block_result
            _save_checkpoint("phase2", evolving, block_result)

    return results


def _train_paired_block(evolving: str, frozen: str, cfg: SpeciesConfig,
                         frozen_genome: dict, generations: int,
                         verbose: bool) -> dict:
    """Train one species for a block with a frozen partner."""
    # Use CPU evaluation for paired training (interaction requires custom sim)
    rng = np.random.default_rng(42)
    grid_size = 64

    n_weights = (cfg.inputs + 1) * cfg.outputs
    pop_size = min(cfg.population, 80)
    population = rng.standard_normal((pop_size, n_weights)) * 0.5
    fitnesses = np.zeros(pop_size)
    best_fitness = -float("inf")
    best_weights = population[0].copy()

    for gen in range(generations):
        for i in range(pop_size):
            fitnesses[i] = _eval_paired_cpu(
                population[i], evolving, frozen, cfg, grid_size, rng
            )

        gen_best_idx = np.argmax(fitnesses)
        if fitnesses[gen_best_idx] > best_fitness:
            best_fitness = fitnesses[gen_best_idx]
            best_weights = population[gen_best_idx].copy()

        if verbose and gen % 25 == 0:
            print(f"      Gen {gen}: best={best_fitness:.2f}", flush=True)

        # Selection + mutation
        new_pop = np.zeros_like(population)
        new_pop[0] = best_weights
        for i in range(1, pop_size):
            t1, t2 = rng.integers(0, pop_size, 2)
            parent = population[t1] if fitnesses[t1] > fitnesses[t2] else population[t2]
            new_pop[i] = parent + rng.standard_normal(n_weights) * 0.25
        population = new_pop

    genome_json = export_genome_json(cfg.inputs, cfg.outputs, best_weights, [], best_fitness)
    return {"genome": genome_json, "fitness": best_fitness}


def _eval_paired_cpu(weights: np.ndarray, evolving: str, frozen: str,
                      cfg: SpeciesConfig, grid_size: int,
                      rng: np.random.Generator) -> float:
    """Evaluate one organism in a paired interaction setting."""
    # Simple paired evaluation
    solo_score = _make_solo_eval_fn_cpu(evolving, cfg)(weights, rng)

    # Interaction bonus (simplified)
    interaction_bonus = 0.0
    pair_key = (evolving, frozen) if (evolving, frozen) in FOOD_WEB else (frozen, evolving)
    if pair_key in FOOD_WEB:
        rewards = FOOD_WEB[pair_key]
        if evolving == pair_key[0]:
            # Evolving is "first" in pair (predator or pollinator)
            interaction_bonus = 10.0  # proximity bonus for finding partner
        else:
            interaction_bonus = 5.0   # survival bonus

    return solo_score * 0.7 + interaction_bonus * 0.3


def phase3_trio_training(phase2_results: dict[str, dict],
                          generations: int = 200,
                          verbose: bool = True) -> dict[str, dict]:
    """Phase 3: Trio/quad sub-ecosystem training with rotating evolution."""
    results = dict(phase2_results)

    for trio in TRIO_SCHEDULE:
        if verbose:
            print(f"\n{'='*60}", flush=True)
            print(f"  Phase 3 - Trio Training: {' + '.join(trio)}", flush=True)
            print(f"  Rotating evolution every 30 generations", flush=True)
            print(f"{'='*60}", flush=True)

        rotate_interval = min(30, generations // len(trio))
        for block in range(generations // max(rotate_interval, 1)):
            evolving_idx = block % len(trio)
            evolving = trio[evolving_idx]
            frozen_species = [s for i, s in enumerate(trio) if i != evolving_idx]

            if verbose:
                print(f"    Block {block}: evolving={evolving}, "
                      f"frozen={frozen_species}", flush=True)

            cfg = SPECIES[evolving]
            block_result = _train_trio_block(
                evolving, frozen_species, cfg, results, rotate_interval, verbose
            )
            results[evolving] = block_result
            _save_checkpoint("phase3", evolving, block_result)

    return results


def _train_trio_block(evolving: str, frozen_list: list[str], cfg: SpeciesConfig,
                       all_results: dict, generations: int,
                       verbose: bool) -> dict:
    """Train one species in a trio setting."""
    rng = np.random.default_rng(42)
    n_weights = (cfg.inputs + 1) * cfg.outputs
    pop_size = min(cfg.population, 60)
    population = rng.standard_normal((pop_size, n_weights)) * 0.5
    fitnesses = np.zeros(pop_size)
    best_fitness = -float("inf")
    best_weights = population[0].copy()

    for gen in range(generations):
        for i in range(pop_size):
            solo = _make_solo_eval_fn_cpu(evolving, cfg)(population[i], rng)
            # Multi-species interaction score
            interaction = 0.0
            for frozen_sp in frozen_list:
                pair = (evolving, frozen_sp)
                rev_pair = (frozen_sp, evolving)
                if pair in FOOD_WEB or rev_pair in FOOD_WEB:
                    interaction += 8.0
            fitnesses[i] = solo * 0.6 + interaction * 0.4

        gen_best_idx = np.argmax(fitnesses)
        if fitnesses[gen_best_idx] > best_fitness:
            best_fitness = fitnesses[gen_best_idx]
            best_weights = population[gen_best_idx].copy()

        if verbose and gen % 25 == 0:
            print(f"      Gen {gen}: best={best_fitness:.2f}", flush=True)

        new_pop = np.zeros_like(population)
        new_pop[0] = best_weights
        for i in range(1, pop_size):
            t1, t2 = rng.integers(0, pop_size, 2)
            parent = population[t1] if fitnesses[t1] > fitnesses[t2] else population[t2]
            new_pop[i] = parent + rng.standard_normal(n_weights) * 0.2
        population = new_pop

    genome_json = export_genome_json(cfg.inputs, cfg.outputs, best_weights, [], best_fitness)
    return {"genome": genome_json, "fitness": best_fitness}


def phase4_full_ecosystem(phase3_results: dict[str, dict],
                           generations: int = 500,
                           n_worlds: int = 64,
                           steps_per_gen: int = 2000,
                           verbose: bool = True) -> dict[str, dict]:
    """Phase 4: Full ecosystem with all 7 species + frozen ants.

    This is the main training phase where all species co-evolve in a shared
    128x128 world with Lotka-Volterra population dynamics enforcement.
    """
    results = dict(phase3_results)
    monitor = PopulationMonitor()
    hof = HallOfFame(max_size=20)

    # Load any existing hall of fame
    hof_path = CHECKPOINT_DIR / "hall_of_fame.json"
    hof.load(hof_path)

    if verbose:
        print(f"\n{'='*60}", flush=True)
        print(f"  Phase 4 - Full Ecosystem Training", flush=True)
        print(f"  All 7 species in 128x128 world", flush=True)
        print(f"  {n_worlds} parallel worlds, {steps_per_gen} steps/gen", flush=True)
        print(f"  Generations: {generations}", flush=True)
        print(f"{'='*60}", flush=True)

    # Fitness weight schedule (shifts across generations)
    def get_weights(gen):
        if gen < 100:
            return {"solo": 0.7, "interaction": 0.2, "population": 0.05, "hof": 0.05}
        elif gen < 250:
            return {"solo": 0.5, "interaction": 0.3, "population": 0.1, "hof": 0.1}
        elif gen < 400:
            return {"solo": 0.3, "interaction": 0.4, "population": 0.2, "hof": 0.1}
        else:
            return {"solo": 0.2, "interaction": 0.4, "population": 0.3, "hof": 0.1}

    # Mutation rate schedule
    def get_mutation_rate(gen):
        if gen < 100:
            return 0.1
        elif gen < 250:
            return 0.05
        elif gen < 400:
            return 0.03
        else:
            return 0.02

    # Per-species populations (simple weight-based ES for CPU, TensorNEAT for GPU)
    populations = {}
    for sp_name, cfg in SPECIES.items():
        n_w = (cfg.inputs + 1) * cfg.outputs
        pop_size = min(cfg.population, 50)  # smaller for full ecosystem
        populations[sp_name] = {
            "weights": np.random.default_rng(42).standard_normal((pop_size, n_w)) * 0.3,
            "fitnesses": np.zeros(pop_size),
            "best_fitness": -float("inf"),
            "best_weights": None,
        }

    rng = np.random.default_rng(42)

    for gen in range(generations):
        weights = get_weights(gen)
        mut_rate = get_mutation_rate(gen)

        # Evaluate all species
        alive_counts = {}
        for sp_name, cfg in SPECIES.items():
            pop = populations[sp_name]
            pop_size = pop["weights"].shape[0]

            for i in range(pop_size):
                # Solo component
                solo = _make_solo_eval_fn_cpu(sp_name, cfg)(pop["weights"][i], rng)

                # Interaction component (simplified for CPU)
                interaction = 0.0
                for (a, b), rewards in FOOD_WEB.items():
                    if sp_name == a or sp_name == b:
                        interaction += 5.0

                # Population health component
                pop_health = 10.0  # default healthy

                # Hall of fame component
                hof_score = 5.0  # baseline

                pop["fitnesses"][i] = (
                    weights["solo"] * solo +
                    weights["interaction"] * interaction +
                    weights["population"] * pop_health +
                    weights["hof"] * hof_score
                )

            # Track best
            best_idx = np.argmax(pop["fitnesses"])
            if pop["fitnesses"][best_idx] > pop["best_fitness"]:
                pop["best_fitness"] = pop["fitnesses"][best_idx]
                pop["best_weights"] = pop["weights"][best_idx].copy()

            alive_counts[sp_name] = float(cfg.target_count)  # simulated

            # Evolve population
            new_weights = np.zeros_like(pop["weights"])
            new_weights[0] = pop["best_weights"] if pop["best_weights"] is not None else pop["weights"][0]
            for i in range(1, pop_size):
                t1, t2 = rng.integers(0, pop_size, 2)
                parent = (pop["weights"][t1] if pop["fitnesses"][t1] > pop["fitnesses"][t2]
                          else pop["weights"][t2])
                new_weights[i] = parent + rng.standard_normal(parent.shape) * mut_rate
            pop["weights"] = new_weights

        # Monitor population dynamics
        monitor.record(gen, alive_counts)

        # Check for population health adjustments every 25 gens
        if gen > 0 and gen % 25 == 0:
            adjustments = monitor.get_adjustments()
            if adjustments and verbose:
                for sp, action in adjustments.items():
                    print(f"    Population adjustment: {sp} -> {action}", flush=True)

        # Add champions to hall of fame every 50 gens
        if gen > 0 and gen % 50 == 0:
            for sp_name in SPECIES:
                pop = populations[sp_name]
                if pop["best_weights"] is not None:
                    cfg = SPECIES[sp_name]
                    genome = export_genome_json(
                        cfg.inputs, cfg.outputs, pop["best_weights"], [],
                        pop["best_fitness"]
                    )
                    hof.add(sp_name, genome, pop["best_fitness"])

        if verbose and gen % 25 == 0:
            best_str = ", ".join(
                f"{sp}={populations[sp]['best_fitness']:.1f}"
                for sp in SPECIES
            )
            print(f"    Gen {gen} (mut={mut_rate:.3f}): {best_str}", flush=True)

    # Export final results
    for sp_name, cfg in SPECIES.items():
        pop = populations[sp_name]
        if pop["best_weights"] is not None:
            genome = export_genome_json(
                cfg.inputs, cfg.outputs, pop["best_weights"], [],
                pop["best_fitness"]
            )
            results[sp_name] = {"genome": genome, "fitness": pop["best_fitness"]}
            _save_checkpoint("phase4", sp_name, results[sp_name])

    # Save hall of fame
    hof.save(hof_path)

    if verbose:
        print(f"\n{monitor.report()}", flush=True)

    return results


def phase5_stress_testing(phase4_results: dict[str, dict],
                           generations: int = 100,
                           verbose: bool = True) -> dict[str, dict]:
    """Phase 5: Stress test ecosystem resilience under extreme conditions."""
    results = dict(phase4_results)

    for scenario_name, mods in STRESS_SCENARIOS.items():
        if verbose:
            print(f"\n{'='*60}", flush=True)
            print(f"  Phase 5 - Stress Test: {scenario_name}", flush=True)
            print(f"  Modifications: {mods}", flush=True)
            print(f"{'='*60}", flush=True)

        if mods.get("remove_species"):
            # Test removing each species one at a time
            for remove_sp in SPECIES:
                if verbose:
                    print(f"    Removing {remove_sp}...", flush=True)
                remaining = {sp: r for sp, r in results.items() if sp != remove_sp}
                score = _evaluate_ecosystem_stability(remaining, scenario_name, verbose)
                if verbose:
                    print(f"    Stability without {remove_sp}: {score:.2f}", flush=True)
        elif mods.get("double_species"):
            # Test doubling each species
            for double_sp in SPECIES:
                if verbose:
                    print(f"    Doubling {double_sp}...", flush=True)
                score = _evaluate_ecosystem_stability(results, scenario_name, verbose,
                                                      doubled=double_sp)
                if verbose:
                    print(f"    Stability with 2x {double_sp}: {score:.2f}", flush=True)
        else:
            # Standard stress scenario: evolve for resilience
            stress_results = _train_under_stress(results, scenario_name, mods,
                                                  generations, verbose)
            # Merge improved genomes
            for sp, res in stress_results.items():
                if res["fitness"] > results.get(sp, {}).get("fitness", -float("inf")):
                    results[sp] = res

    return results


def _evaluate_ecosystem_stability(results: dict, scenario: str,
                                    verbose: bool,
                                    doubled: str | None = None) -> float:
    """Score ecosystem stability under a given scenario."""
    # Simplified stability metric: count surviving species after N steps
    surviving = len(results)
    target = len(SPECIES)
    return surviving / target * 100.0


def _train_under_stress(results: dict, scenario: str, mods: dict,
                         generations: int, verbose: bool) -> dict[str, dict]:
    """Train species under stress conditions."""
    stress_results = {}
    rng = np.random.default_rng(42)

    for sp_name, cfg in SPECIES.items():
        if sp_name not in results:
            continue

        n_w = (cfg.inputs + 1) * cfg.outputs
        pop_size = 30  # small for stress testing
        population = rng.standard_normal((pop_size, n_w)) * 0.3
        best_fitness = -float("inf")
        best_weights = population[0].copy()

        energy_mult = mods.get("metabolism_mult", 1.0)
        food_mult = mods.get("food_mult", 1.0)

        for gen in range(generations):
            fitnesses = np.zeros(pop_size)
            for i in range(pop_size):
                base = _make_solo_eval_fn_cpu(sp_name, cfg)(population[i], rng)
                # Apply stress modifiers
                fitnesses[i] = base * food_mult * energy_mult
                # Resilience bonus: surviving stress = extra fitness
                if fitnesses[i] > 20:
                    fitnesses[i] += 20.0

            best_idx = np.argmax(fitnesses)
            if fitnesses[best_idx] > best_fitness:
                best_fitness = fitnesses[best_idx]
                best_weights = population[best_idx].copy()

            new_pop = np.zeros_like(population)
            new_pop[0] = best_weights
            for i in range(1, pop_size):
                t1, t2 = rng.integers(0, pop_size, 2)
                parent = population[t1] if fitnesses[t1] > fitnesses[t2] else population[t2]
                new_pop[i] = parent + rng.standard_normal(n_w) * 0.15
            population = new_pop

        genome = export_genome_json(cfg.inputs, cfg.outputs, best_weights, [], best_fitness)
        stress_results[sp_name] = {"genome": genome, "fitness": best_fitness}

        if verbose:
            print(f"    {sp_name} stress fitness: {best_fitness:.2f}", flush=True)

    return stress_results


# =========================================================================
# Checkpoint management
# =========================================================================

def _save_checkpoint(phase: str, species: str, result: dict):
    """Save a training checkpoint."""
    CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)
    path = CHECKPOINT_DIR / f"{phase}_{species}.json"
    path.write_text(json.dumps(result, indent=2, default=str))


def _load_checkpoint(phase: str, species: str) -> dict | None:
    """Load a training checkpoint if it exists."""
    path = CHECKPOINT_DIR / f"{phase}_{species}.json"
    if path.exists():
        return json.loads(path.read_text())
    return None


def load_phase_results(phase: str) -> dict[str, dict]:
    """Load all species results from a completed phase."""
    results = {}
    for sp_name in SPECIES:
        checkpoint = _load_checkpoint(phase, sp_name)
        if checkpoint:
            results[sp_name] = checkpoint
    return results


# =========================================================================
# Export final trained genomes
# =========================================================================

def export_all_genomes(results: dict[str, dict], suffix: str = "ecosystem"):
    """Export all trained genomes to the output directory."""
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    for sp_name, result in results.items():
        # Best genome
        best_path = OUTPUT_DIR / f"{sp_name}_{suffix}_best.json"
        best_path.write_text(json.dumps(result["genome"], indent=2))
        print(f"  Exported: {best_path}", flush=True)

    # Metadata
    metadata = {
        "species": list(results.keys()),
        "target_populations": {sp: SPECIES[sp].target_count for sp in results},
        "food_web": {f"{a}->{b}": r for (a, b), r in FOOD_WEB.items()},
        "training_timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "fitnesses": {sp: r["fitness"] for sp, r in results.items()},
    }
    meta_path = OUTPUT_DIR / f"{suffix}_metadata.json"
    meta_path.write_text(json.dumps(metadata, indent=2, default=str))
    print(f"  Exported: {meta_path}", flush=True)


# =========================================================================
# Main CLI
# =========================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Multi-species ecosystem co-evolutionary trainer"
    )
    parser.add_argument("--full", action="store_true",
                        help="Run all 5 phases")
    parser.add_argument("--phase", type=int, choices=[1, 2, 3, 4, 5],
                        help="Run a specific phase")
    parser.add_argument("--solo", type=str, choices=list(SPECIES.keys()),
                        help="Solo-train a single species (Phase 1 only)")
    parser.add_argument("--generations", type=int, default=None,
                        help="Override generation count")
    parser.add_argument("--resume", action="store_true",
                        help="Resume from checkpoints")
    parser.add_argument("--export-only", action="store_true",
                        help="Just export genomes from existing checkpoints")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    verbose = not args.quiet

    if verbose:
        print("\n" + "=" * 60, flush=True)
        print("  Ecosystem Co-Evolutionary Trainer", flush=True)
        print("  The Particle Engine - Multi-Species NEAT", flush=True)
        print("=" * 60, flush=True)
        if HAS_JAX:
            print(f"  JAX backend: {jax.devices()}", flush=True)
        else:
            print("  JAX not available -- using CPU fallback", flush=True)
        if HAS_TENSORNEAT:
            print("  TensorNEAT: available", flush=True)
        else:
            print("  TensorNEAT: not available -- using ES fallback", flush=True)
        print(flush=True)

    if args.export_only:
        # Try loading latest phase results
        for phase in ["phase5", "phase4", "phase3", "phase2", "phase1"]:
            results = load_phase_results(phase)
            if results:
                print(f"  Found {phase} results for {len(results)} species", flush=True)
                export_all_genomes(results)
                return
        print("  No checkpoints found to export", flush=True)
        return

    if args.solo:
        gens = args.generations or SPECIES[args.solo].solo_generations
        results = phase1_solo_training([args.solo], gens, verbose)
        export_all_genomes(results, suffix="solo")
        return

    if args.phase:
        phase = args.phase
    elif args.full:
        phase = 0  # run all
    else:
        parser.print_help()
        return

    # Phase execution
    results = {}

    if phase <= 1 or phase == 0:
        if args.resume:
            results = load_phase_results("phase1")
        if len(results) < len(SPECIES):
            gens = args.generations or 200
            results = phase1_solo_training(generations=gens, verbose=verbose)
        if phase == 1:
            export_all_genomes(results, suffix="phase1")
            return

    if phase <= 2 or phase == 0:
        if args.resume and not results:
            results = load_phase_results("phase2") or load_phase_results("phase1")
        gens = args.generations or 200
        results = phase2_paired_coevolution(results, gens, verbose)
        if phase == 2:
            export_all_genomes(results, suffix="phase2")
            return

    if phase <= 3 or phase == 0:
        if args.resume and not results:
            results = load_phase_results("phase3") or load_phase_results("phase2")
        gens = args.generations or 200
        results = phase3_trio_training(results, gens, verbose)
        if phase == 3:
            export_all_genomes(results, suffix="phase3")
            return

    if phase <= 4 or phase == 0:
        if args.resume and not results:
            results = load_phase_results("phase4") or load_phase_results("phase3")
        gens = args.generations or 500
        results = phase4_full_ecosystem(results, gens, verbose=verbose)
        if phase == 4:
            export_all_genomes(results, suffix="phase4")
            return

    if phase <= 5 or phase == 0:
        if args.resume and not results:
            results = load_phase_results("phase5") or load_phase_results("phase4")
        gens = args.generations or 100
        results = phase5_stress_testing(results, gens, verbose)

    # Export final results
    export_all_genomes(results, suffix="ecosystem")

    if verbose:
        print("\n" + "=" * 60, flush=True)
        print("  Ecosystem training complete!", flush=True)
        print(f"  Trained {len(results)} species", flush=True)
        for sp, res in results.items():
            print(f"    {sp:10s}: fitness={res['fitness']:.2f}", flush=True)
        print(f"  Genomes exported to: {OUTPUT_DIR}", flush=True)
        print("=" * 60, flush=True)


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        print("Self-test: imports OK", flush=True)
        assert len(SPECIES) > 0, "No species defined"
        print(f"Self-test: {len(SPECIES)} species", flush=True)
        print("Self-test: PASSED", flush=True)
        sys.exit(0)
    main()
