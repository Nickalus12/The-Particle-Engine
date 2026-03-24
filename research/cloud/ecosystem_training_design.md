# Ecosystem Co-Evolutionary Training Design

## Overview

This document defines the training protocol for evolving 7 creature species (worm, beetle,
spider, bee, fish, firefly, plant) alongside the existing ant colony AI, such that when placed
together they form a balanced, self-regulating ecosystem with emergent food-web dynamics.

The core challenge is NOT training 7 independent neural networks. It is training them so their
behaviors interlock: worms aerate soil helping plants grow, beetles eat plants, spiders eat
beetles, bees pollinate enabling more plants, fish control aquatic algae, and fireflies provide
atmospheric synchronization displays. Remove any species and the ecosystem shifts noticeably.

## Species Definitions

| Species  | Inputs | Outputs | Role in Food Web              | Brain Complexity |
|----------|--------|---------|-------------------------------|-----------------|
| Worm     | 5      | 3       | Decomposer / soil aerator     | Minimal         |
| Beetle   | 8      | 5       | Herbivore / plant consumer    | Low             |
| Spider   | 12     | 8       | Predator / beetle hunter      | Medium          |
| Bee      | 10     | 6       | Pollinator / plant enabler    | Medium          |
| Fish     | 7      | 4       | Aquatic predator / algae ctrl | Low             |
| Firefly  | 6      | 4       | Sync display / atmosphere     | Low             |
| Plant    | 4      | 2       | Producer / passive growth     | Minimal         |
| Ant      | 8      | 6       | Generalist / existing system  | Medium (frozen) |

### Neural I/O Specifications

**Worm** (5 inputs, 3 outputs):
- Inputs: soil_moisture, organic_density, depth, energy, nearby_predator
- Outputs: move_dx, move_dy, burrow_strength

**Beetle** (8 inputs, 5 outputs):
- Inputs: plant_distance, plant_density, energy, nearby_predator_dist, ground_type, light_level, pheromone_gradient, nearby_beetle_count
- Outputs: move_dx, move_dy, eat, flee, deposit_pheromone

**Spider** (12 inputs, 8 outputs):
- Inputs: nearest_prey_dist, prey_direction_x, prey_direction_y, web_tension_n/s/e/w, energy, nest_dist, ground_type, vibration_strength, light_level
- Outputs: move_dx, move_dy, place_web, attack, wait_ambush, reel_in, deposit_pheromone, flee

**Bee** (10 inputs, 6 outputs):
- Inputs: flower_distance, flower_direction, nectar_carried, hive_distance, hive_direction, energy, nearby_bee_count, wind_direction, light_level, danger_sense
- Outputs: move_dx, move_dy, collect_nectar, deposit_nectar, pollinate, waggle_dance

**Fish** (7 inputs, 4 outputs):
- Inputs: food_distance, water_depth, current_strength, energy, nearby_fish, predator_dist, oxygen_level
- Outputs: move_dx, move_dy, eat, school_align

**Firefly** (6 inputs, 4 outputs):
- Inputs: nearby_flash_phase, own_phase, energy, light_level, nearby_firefly_count, ground_brightness
- Outputs: move_dx, move_dy, flash_timing, flash_intensity

**Plant** (4 inputs, 2 outputs):
- Inputs: sunlight, water_proximity, soil_quality, crowding
- Outputs: growth_rate, seed_dispersal_direction

## Research Foundation

### The Arms Race Problem

The fundamental challenge in co-evolutionary training is the Red Queen Effect: predators improve,
prey dies out, predators starve, cycle collapses. Research shows this manifests as:

1. **Fitness cycling**: Mean fitness oscillates without convergence (Diederich & Busoni, 1989)
2. **Loss of gradient**: When one population dominates, the other gets no useful learning signal
3. **Mediocre stable states**: Both populations settle into mutually mediocre strategies

**Our mitigations:**

- **Fitness sharing with environmental baseline**: Each species' fitness includes a large
  component from solo survival tasks (60-70%), with inter-species interaction only 30-40%.
  This prevents total fitness collapse when a partner species is temporarily weak.

- **Population ratio enforcement (Lotka-Volterra caps)**: We enforce carrying capacity ratios
  derived from ecological theory. Predators are always outnumbered by prey ~4:1, matching
  real-world trophic pyramids. This prevents extinction spirals.

- **Frozen-genome partners**: During paired training, one species evolves while the other uses
  frozen best-of-previous-phase genomes. This provides a stable fitness landscape. We alternate
  which species is frozen every 50 generations.

- **Hall of Fame evaluation**: Each generation, organisms are tested against not just current
  opponents but a "hall of fame" of past champion genomes. This prevents cycling by maintaining
  pressure against historical strategies (Rosin & Belew, 1997).

### Fitness Normalization Across Species

A beetle's fitness depends on how good the spiders are. Raw fitness scores are incomparable.

**Solution: Relative fitness with environmental baseline.**

```
normalized_fitness(species_i) =
    0.6 * solo_survival_score(species_i) +
    0.3 * interaction_score(species_i, current_partners) +
    0.1 * hall_of_fame_score(species_i, historical_partners)
```

Solo survival scores are species-specific and independent of partner quality:
- Worm: soil traversal efficiency, energy management
- Beetle: plant foraging without predators
- Spider: web construction quality, ambush positioning
- Bee: flower-finding efficiency, hive return
- Fish: algae consumption, schooling cohesion
- Firefly: synchronization accuracy with fixed-phase neighbors
- Plant: growth rate given fixed environmental conditions

### Population Dynamics and Carrying Capacity

Based on Lotka-Volterra equilibrium analysis and real-world trophic pyramids:

| Species  | Pop/World | Biomass Tier | Trophic Level |
|----------|-----------|-------------|---------------|
| Plant    | 40-60     | Producer    | 1             |
| Worm     | 20-30     | Decomposer  | 1.5           |
| Beetle   | 15-25     | Herbivore   | 2             |
| Bee      | 10-20     | Pollinator  | 2             |
| Fish     | 8-15      | Omnivore    | 2.5           |
| Firefly  | 8-12      | Atmospheric | 2             |
| Spider   | 5-10      | Predator    | 3             |
| Ant      | 10-20     | Generalist  | 2.5           |

**Dynamic population control**: During training, if any species drops below 30% of its target
count for >10 generations, we reduce predation pressure (freeze predator genomes, boost prey
reproduction rate). If any species exceeds 200% of target, we increase predation or reduce
food availability.

### GPU Evaluation Architecture

TensorNEAT tensorizes variable-topology NEAT genomes into fixed-shape tensors for GPU parallel
evaluation. For multi-species, we run **separate NEAT populations per species** (since I/O
counts differ), but evaluate them in a **shared world simulation**.

```
Per evaluation step:
  1. Tensorize all 7 species populations -> 7 batched genome tensors
  2. For each world instance (128 parallel worlds):
     a. Place N organisms from each species
     b. Run K simulation steps with all species interacting
     c. Collect per-organism fitness signals
  3. Each species population evolves independently using its fitness
  4. Repeat
```

This requires 7 separate `jax.vmap` forward passes per step (one per species architecture),
but the world simulation and fitness collection are shared. On A100, the forward passes are
<1% of total time; the simulation dominates.

## Training Protocol

### Phase 1: Individual Species Training (200 generations each)

**Goal**: Each species learns basic survival in isolation.

| Species  | World Size | Population | What's Trained                    | Frozen |
|----------|-----------|------------|-----------------------------------|--------|
| Worm     | 32x32     | 300        | Navigate soil, find organic matter | None   |
| Beetle   | 48x48     | 400        | Find and eat plants               | None   |
| Spider   | 48x48     | 400        | Build webs, detect vibrations     | None   |
| Bee      | 64x64     | 400        | Find flowers, return to hive      | None   |
| Fish     | 48x32     | 300        | Eat algae, navigate currents      | None   |
| Firefly  | 32x32     | 300        | Synchronize flash with neighbors  | None   |
| Plant    | 32x32     | 200        | Grow toward light, spread seeds   | None   |

**Fitness functions (solo)**:
- Worm: energy_efficiency * 0.4 + exploration * 0.3 + organic_consumed * 0.3
- Beetle: plants_eaten * 0.5 + survival_time * 0.3 + exploration * 0.2
- Spider: web_quality * 0.3 + prey_caught (simulated) * 0.4 + energy_efficiency * 0.3
- Bee: flowers_visited * 0.4 + nectar_delivered * 0.4 + exploration * 0.2
- Fish: algae_eaten * 0.4 + survival * 0.3 + schooling_score * 0.3
- Firefly: sync_accuracy * 0.6 + energy * 0.2 + group_cohesion * 0.2
- Plant: biomass_grown * 0.5 + seeds_dispersed * 0.3 + survival * 0.2

**Expected A100 time**: ~15 minutes total (all 7 species in parallel batches)

### Phase 2: Paired Co-Evolution (200 generations per pair)

**Goal**: Predator-prey pairs learn to interact. One evolves while partner is frozen, alternating every 50 gens.

| Pair              | World Size | Interaction Type       |
|-------------------|-----------|------------------------|
| Worm + Plant      | 48x48     | Mutualism: worm aerates, plant feeds |
| Beetle + Plant    | 64x64     | Herbivory: beetle eats, plant defends |
| Spider + Beetle   | 64x64     | Predation: spider hunts, beetle flees |
| Bee + Plant       | 64x64     | Mutualism: bee pollinates, plant rewards |
| Fish + Plant      | 48x32     | Aquatic: fish eats algae/aquatic plants |
| Firefly + Firefly | 48x48     | Social: synchronization pressure |

**Fitness adjustments**:
- Add inter-species interaction terms (30% weight)
- Beetle gains +5 for each plant eaten, -10 for being caught by spider
- Spider gains +15 for each beetle caught, -5 for empty web
- Bee gains +10 for successful pollination, plant gains +5 for being pollinated
- Worm gains +5 for soil near healthy plant, plant gains +3 for aerated soil nearby

**Alternating freeze protocol**:
- Gens 0-49: Species A evolves, Species B frozen (best from Phase 1)
- Gens 50-99: Species B evolves, Species A frozen (best from gens 0-49)
- Gens 100-149: Species A evolves, Species B frozen (best from gens 50-99)
- Gens 150-199: Species B evolves, Species A frozen (best from gens 100-149)

**Expected A100 time**: ~25 minutes total

### Phase 3: Trio/Quad Sub-ecosystem Training (200 generations per group)

**Goal**: Multi-species chains learn stable dynamics.

| Group                    | World Size | Food Chain                           |
|--------------------------|-----------|--------------------------------------|
| Worm + Beetle + Plant    | 80x80     | Plant grows -> beetle eats -> worm decomposes |
| Spider + Beetle + Plant  | 80x80     | Plant -> beetle -> spider predation chain |
| Bee + Plant + Beetle     | 80x80     | Bee pollinates -> more plants -> beetle pressure |
| Fish + Plant + Worm      | 64x48     | Aquatic sub-ecosystem                |

**Key addition: Population dynamics enforcement.**

Each group has target population ratios. Fitness includes a **population health bonus**:
if your species is near its target count, +5 bonus. If your species is over-consuming
and crashing partner populations, -10 penalty (applied via population monitoring).

**Rotating evolution**: In groups of 3+, we cycle which species evolves:
- Every 30 generations, the evolving species rotates
- The other two use frozen champions from the most recent rotation

**Expected A100 time**: ~30 minutes total

### Phase 4: Full Ecosystem (500 generations)

**Goal**: All 7 species + frozen ant genomes coexist in a full-sized world.

| Parameter           | Value                    |
|---------------------|--------------------------|
| World size          | 128x128                  |
| Plants              | 40 initial               |
| Worms               | 20 initial               |
| Beetles             | 15 initial               |
| Spiders             | 5 initial                |
| Bees                | 10 initial               |
| Fish                | 8 initial (in water)     |
| Fireflies           | 8 initial                |
| Ants                | 10 (frozen best genome)  |
| Evaluation steps    | 2000 per generation      |
| Parallel worlds     | 64                       |

**Training schedule (500 gens)**:
- Gens 0-99: All species evolve simultaneously, high mutation rate (0.1)
- Gens 100-249: Reduce mutation to 0.05, enable hall-of-fame evaluation
- Gens 250-399: Reduce mutation to 0.03, enable population dynamics penalties
- Gens 400-499: Fine-tuning, mutation 0.02, full fitness function

**Full fitness function** (per species):
```
fitness =
    solo_weight * solo_survival_score +
    interaction_weight * interaction_score +
    population_weight * population_health_score +
    hof_weight * hall_of_fame_score

Where weights shift across phases:
  Gens 0-99:    solo=0.7, interaction=0.2, population=0.05, hof=0.05
  Gens 100-249: solo=0.5, interaction=0.3, population=0.1,  hof=0.1
  Gens 250-399: solo=0.3, interaction=0.4, population=0.2,  hof=0.1
  Gens 400-499: solo=0.2, interaction=0.4, population=0.3,  hof=0.1
```

**Population dynamics monitoring**:
Every 25 generations, check population counts across all 64 parallel worlds:
- If any species extinct in >50% of worlds: freeze its predators, boost reproduction
- If any species >3x target in >50% of worlds: increase predation pressure
- Log population trajectories for Lotka-Volterra stability analysis

**Expected A100 time**: ~2 hours

### Phase 5: Stress Testing (100 generations per scenario)

**Goal**: Verify ecosystem resilience under extreme conditions.

| Scenario       | Modification                                      |
|----------------|---------------------------------------------------|
| Drought        | Remove 80% of water, reduce plant growth 50%      |
| Flood          | Fill 60% of world with water                      |
| Fire           | Random fire events every 50 steps                 |
| Ice age        | Reduce all metabolism rates 50%, increase energy costs |
| Species removal| Remove each species one at a time, verify cascade |
| Population bomb| Double one species' population, verify correction  |
| Resource scarcity | Halve all food sources                         |

**Fitness during stress tests**: Same as Phase 4 but with environmental modifiers.
Species that maintain >50% population through stress events get a +20 resilience bonus.

**Expected A100 time**: ~1.5 hours (7 scenarios x ~13 min each)

## Total Estimated Training Time

| Phase   | A100 Time  | A100 Cost ($0.78/hr) |
|---------|-----------|---------------------|
| Phase 1 | 15 min    | $0.20               |
| Phase 2 | 25 min    | $0.33               |
| Phase 3 | 30 min    | $0.39               |
| Phase 4 | 120 min   | $1.56               |
| Phase 5 | 90 min    | $1.17               |
| **Total** | **~4.7 hrs** | **~$3.65**       |

## Genome Compatibility with Dart

All trained genomes export to the same JSON format used by `creature_trainer.py`:
```json
{
  "nodes": [{"id": int, "type": int, "activation": int, "layer": int}],
  "connections": [{"innovation": int, "inNode": int, "outNode": int,
                   "weight": float, "enabled": bool}],
  "fitness": float,
  "speciesId": int
}
```

Each species gets its own genome file:
- `research/cloud/trained_genomes/{species}_ecosystem_best.json`
- `research/cloud/trained_genomes/{species}_ecosystem_population.json`
- `research/cloud/trained_genomes/ecosystem_metadata.json` (population ratios, phase results)

## Validation Criteria

The ecosystem is considered successfully trained when:
1. All 7 species survive for 5000+ steps in >80% of test worlds
2. Removing any single species causes measurable population shifts in at least 2 others
3. Population counts oscillate within 50-200% of target (Lotka-Volterra stability)
4. No species permanently dominates (>300% target for >200 steps)
5. Predator-prey cycles show characteristic 90-degree phase lag (predator peaks after prey)
6. Stress test survival: >60% of species survive drought/flood/fire scenarios

## References

- Stanley & Miikkulainen, "Competitive Coevolution through Evolutionary Complexification", 2004
- OpenAI, "Emergent Tool Use From Multi-Agent Autocurricula", ICLR 2020
- Lotka-Volterra equations for population dynamics equilibrium
- TensorNEAT: GPU-accelerated NEAT with tensorized genomes (EMI-Group, 2024)
- EvoJAX: Hardware-accelerated neuroevolution (Google, 2022)
- Rosin & Belew, "New Methods for Competitive Coevolution", 1997 (Hall of Fame)
- Ficici & Pollack, "Challenges in Coevolutionary Learning", 1998 (fitness relativity)
