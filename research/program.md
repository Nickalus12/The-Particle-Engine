# NEAT Autoresearch Protocol

> Instructions for an AI agent tasked with continuously optimizing
> ant colony neural networks in The Particle Engine.

---

## Mission

Optimize NEAT-evolved ant brains to produce **emergent, intelligent, lifelike
colony behavior**. Ants should forage efficiently, explore territory, survive
hazards, cooperate via pheromones, build nest structures, and respond to
threats -- all as emergent properties of a small neural network evolved through
neuroevolution.

You are an automated research agent. Your job is to run experiments that modify
NEAT hyperparameters and fitness weights, benchmark the resulting colonies
against a baseline, keep improvements, and discard regressions. Each iteration
should push the colony closer to lifelike behavior.

---

## Composite Fitness Metric

Colony quality is measured by a weighted composite score computed at the end
of each benchmark run. The six components and their weights:

| # | Component | Weight | How to measure |
|---|-----------|--------|----------------|
| 1 | **Colony Survival** | 0.20 | `colony.population / startingPopCap` at final tick. 1.0 = full pop, 0.0 = extinct. Bonus 0.1 if colony alive at end. |
| 2 | **Food Collection** | 0.25 | `colony.foodStored / startingFood` clamped to [0, 3]. Measures net food gain over the run. |
| 3 | **Territory Exploration** | 0.15 | Union of all ants' `fitness.exploredCells` / total reachable cells. Fraction of world visited. |
| 4 | **Building Complexity** | 0.10 | `colony.nestChambers.length / 20`. Measures nest expansion. Clamped to [0, 1]. |
| 5 | **Threat Response** | 0.15 | Survival rate in hostile environments. `(antsAlive / totalSpawned)` in the presence of hazards. Falls back to 0.5 in safe envs. |
| 6 | **Cooperation Score** | 0.15 | Pheromone effectiveness: `totalFoodDelivered / totalFoodForaged`. 1.0 = every foraged item was delivered. |

**Composite = sum(component_i * weight_i) for i in 1..6**

A perfect colony scores ~1.0. The baseline typically scores 0.15-0.30.
An experiment is an **improvement** if composite > baseline * 1.10 (10% better).

---

## What You CAN Modify

These parameters are your tuning knobs. Vary them to find better configurations:

### NEAT Hyperparameters (`NeatConfig`)

- `populationSize` (default 150) -- number of genomes in the pool
- `compatThreshold` (default 3.0) -- speciation distance threshold
- `compatThresholdDelta` (default 0.3) -- threshold auto-adjustment step
- `targetSpeciesCount` (default 10) -- target species count
- `compatExcessCoeff`, `compatDisjointCoeff`, `compatWeightCoeff` -- distance formula weights
- `weightMutationRate` (default 0.8) -- probability of weight perturbation
- `weightPerturbPower` (default 0.5) -- stddev of weight perturbation
- `addConnectionRate` (default 0.05) -- probability of adding a new connection
- `addNodeRate` (default 0.03) -- probability of adding a new hidden node
- `deleteConnectionRate` (default 0.01) -- probability of pruning a connection
- `enableGeneRate` (default 0.25) -- probability of re-enabling a disabled gene
- `activationMutationRate` (default 0.05) -- probability of changing a node's activation
- `crossoverRate` (default 0.75) -- sexual vs asexual reproduction ratio
- `interspeciesCrossoverRate` (default 0.001) -- cross-species mating
- `elitismCount` (default 2) -- top genomes copied without mutation
- `survivalThreshold` (default 0.2) -- fraction of species that reproduce
- `stagnationLimit` (default 15) -- generations before stagnant species are culled
- `rtReplacementInterval` (default 20) -- ticks between rt-NEAT replacements
- `rtMinLifetime` (default 100) -- minimum ticks before a genome can be replaced
- `maxHiddenNodes` (default 20) -- hard cap on hidden neurons
- `maxConnections` (default 100) -- hard cap on connection genes

### Activation Functions

- `defaultActivation` -- one of: `sigmoid`, `tanh`, `relu`, `linear`, `gaussian`, `step`
- Can also be mutated per-node via `activationMutationRate`

### Fitness Weights (in `AntFitness`)

- Forage reward (default +10)
- Deliver reward (default +25)
- Explore reward (default +1 per unique cell)
- Survive reward (default +0.01 per tick)
- Pheromone reward (default +0.5)
- Defend reward (default +15)
- Death penalty (default -5)
- Idle penalty (default -0.1 per tick)

### Colony Parameters

- Starting food (default 20)
- Spawn cost (default 5 food per ant)
- Max ants per colony (default 200)
- Ant energy costs (base, move, carry)
- Max ant age (default 18,000 ticks)

### I/O Configuration (advanced, changes brain interface)

- `inputCount` (default 8) -- number of sensory inputs
- `outputCount` (default 6) -- number of action outputs
- Sensory preprocessing (normalization ranges, scan radii)

> **Warning:** Changing I/O counts invalidates all existing seed queens and
> requires updating `AntBrain.think()` and the `AntAction` class.

---

## What You CANNOT Modify

These systems are fixed. Do not alter them during research:

- **SimulationEngine** -- The grid physics engine (`simulation_engine.dart`).
  Element behaviors, dirty chunk system, clock-bit double-sim prevention.
- **Grid system** -- Uint8List typed arrays, El.* byte constants, 16x16 chunk
  layout. The cellular automaton mechanics are load-bearing.
- **Element behaviors** -- The `simulateElement` dispatch and all 24 element
  behavior methods in `element_behaviors.dart`.
- **Evaluation harness** -- The `NeatBenchmark` class and `Environment` base.
  Modify configs, not the harness itself.
- **World generation** -- `WorldGenerator`, `TerrainGenerator`, `FeaturePlacer`.
  Use existing `WorldConfig` presets or create new environment subclasses.

---

## Constraints

1. **Brain size:** Max ~50 nodes per brain (`maxHiddenNodes` <= 42, since
   there are 8 input + bias + 6 output = 15 fixed nodes).
2. **Forward pass speed:** Must complete in < 5 microseconds per ant.
   `NeatForward.activate()` is already optimized for this. Don't add
   complexity that breaks the budget.
3. **Deterministic:** Every experiment takes an integer seed. Same seed +
   same config = identical results. Use seeded `Random` everywhere.
4. **Headless:** No Flutter, no Flame, no rendering dependencies. Pure Dart
   computation only.
5. **Real physics:** Always call `engine.step(simulateElement)` with the real
   element dispatch. No simplified physics.
6. **Real colony lifecycle:** Always use `Colony.tick()`. No bypassing
   spawning, pheromone decay, staggered ticking, or rt-NEAT replacement.
7. **Bounded duration:** Default 18,000 ticks (~5 min at 60fps). Safety
   kill at 2x configured limit.

---

## Experiment Format

### What to Log

Each experiment produces a line in `research/results/experiment_log.jsonl`:

```json
{
  "timestamp": "2026-03-17T12:30:00Z",
  "experiment": "high_mutation_v2",
  "environment": "easy_meadow",
  "seed": 42,
  "duration_ticks": 18000,
  "elapsed_ms": 4500,
  "config_diff": {"weightMutationRate": 0.95, "addNodeRate": 0.06},
  "composite_score": 0.38,
  "components": {
    "colony_survival": 0.65,
    "food_collection": 0.40,
    "territory_exploration": 0.22,
    "building_complexity": 0.05,
    "threat_response": 0.50,
    "cooperation_score": 0.30
  },
  "checkpoints": [ ... ],
  "baseline_composite": 0.25,
  "improvement_ratio": 1.52,
  "verdict": "keep"
}
```

### How to Compare

1. Run the experiment with the candidate config.
2. Run (or load cached) baseline with `NeatConfig()` defaults on the same
   environment and seed.
3. Compute composite scores for both.
4. `improvement_ratio = candidate_composite / baseline_composite`.

### Keep / Discard Rules

| Condition | Verdict | Action |
|-----------|---------|--------|
| `improvement_ratio >= 1.10` | **keep** | Save config + champion genome. Export seed queen if ratio >= 2.0. |
| `0.95 <= improvement_ratio < 1.10` | **neutral** | Log but don't adopt. May retry with different seed. |
| `improvement_ratio < 0.95` | **discard** | Log and move on. The change made things worse. |

### Statistical Significance

For any "keep" verdict, re-run with 5 different seeds (42, 1042, 2042, 3042,
4042). The improvement must hold in >= 3 of 5 runs to be considered robust.

---

## Checkpoint Schedule

Metrics are sampled at these tick counts:

```
[300, 600, 1200, 2400, 4800, 9000, 13500, 18000]
```

- **300** (5s): Catches catastrophic failures (colony extinct, zero food).
- **1200** (20s): Early behavior patterns forming.
- **4800** (80s): Mid-run colony health.
- **18000** (5min): Long-run viability and final composite score.

---

## Evaluation Environments

| Name | Difficulty | Key Challenge | Colony Origin |
|------|-----------|---------------|---------------|
| `easy_meadow` | Easy | Baseline -- gentle terrain, abundant food | (100, 80) |
| `survival_challenge` | Medium | Sparse food far from nest | (100, 85) |
| `hostile_world` | Hard | Fire, lava, acid hazards near nest | (100, 80) |
| `multi_colony` | Medium | Two competing colonies | (60, 80) vs (180, 80) |
| `complex_terrain` | Hard | Canyon, caves, water barriers | (100, 90) |

Always run baseline comparison on `easy_meadow` first. Generalization testing
uses all 5 environments.

---

## Seed Queen Export

When an experiment produces a champion with composite score >= 2x baseline:

1. Serialize via `NeatGenome.toJson()`.
2. Save to `assets/seed_queens/{environment}_s{seed}_f{fitness}.json`.
3. Include metadata: environment, seed, tick count, fitness, composite score,
   node count, connection count, activation functions used.

Seed queens bootstrap new colonies with evolved brains instead of random
minimal genomes. This accelerates initial colony viability in the live game.

---

## Research Loop (for the AI agent)

```
1. Load baseline results (or run baseline if not cached).
2. Select a parameter to vary (round-robin or guided by past results).
3. Generate candidate config (small delta from current best).
4. Run benchmark on easy_meadow with seed 42.
5. Compare composite score to baseline.
6. If "keep": re-run with 5 seeds for statistical validation.
7. If validated: adopt as new baseline. Export seed queen if exceptional.
8. Log everything to experiment_log.jsonl.
9. Repeat from step 2.
```

Each iteration should take 5-30 seconds of wall-clock time depending on
colony size and tick count. The loop can run indefinitely.
