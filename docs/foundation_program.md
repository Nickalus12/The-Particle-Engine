# Foundation Program

**Status:** Active execution plan  
**Date:** 2026-03-24

## Goal
Build a professional foundation for the game’s material system, simulation tuning, rendering evaluation, and research loop so that:

- element behavior is grounded in explicit properties
- simulation tuning is measurable and reproducible
- SciPy can calibrate and validate physical models
- Optuna can search a stable, canonical parameter surface
- future R&D can extend the system without re-breaking the contract

## Core Principle
The codebase needs three distinct layers, not one blended layer:

1. `Element definition layer`
   Owns intrinsic properties for each material.
   Examples: density, viscosity, conductivity, reactivity, ignition temperature, phase thresholds, corrosion resistance.

2. `Simulation tuning layer`
   Owns gameplay and numerical tunables that govern rates, thresholds, and heuristics in the engine.
   Examples: erosion rates, reaction probabilities, spread throttles, colony thresholds, instability cutoffs.

3. `Research contract layer`
   Owns the schema that external tools use to override, benchmark, and score the runtime.
   Examples: `params`, grouped metadata, bounds, defaults, objective weights, benchmark manifests.

If those layers drift, optimization results stop being trustworthy.

## Canonical Ownership

### Element Properties
- Runtime definition: [`/home/nickalus/code/The-Particle-Engine/lib/simulation/element_registry.dart`](/home/nickalus/code/The-Particle-Engine/lib/simulation/element_registry.dart)
- Hot-loop lookup tables: [`/home/nickalus/code/The-Particle-Engine/lib/simulation/element_registry.dart`](/home/nickalus/code/The-Particle-Engine/lib/simulation/element_registry.dart)
- Behavior consumers: [`/home/nickalus/code/The-Particle-Engine/lib/simulation/element_behaviors.dart`](/home/nickalus/code/The-Particle-Engine/lib/simulation/element_behaviors.dart), [`/home/nickalus/code/The-Particle-Engine/lib/simulation/simulation_engine.dart`](/home/nickalus/code/The-Particle-Engine/lib/simulation/simulation_engine.dart)

### Simulation Tunables
- Runtime definition: [`/home/nickalus/code/The-Particle-Engine/lib/simulation/simulation_engine.dart`](/home/nickalus/code/The-Particle-Engine/lib/simulation/simulation_engine.dart)
  `SimTuning` is the current central surface and must remain callable from external research tooling.

### Research Contract
- Full benchmark spine: [`/home/nickalus/code/The-Particle-Engine/research/benchmark.py`](/home/nickalus/code/The-Particle-Engine/research/benchmark.py)
- Runtime exporter: [`/home/nickalus/code/The-Particle-Engine/research/export_frame.dart`](/home/nickalus/code/The-Particle-Engine/research/export_frame.dart)
- Local optimizer: [`/home/nickalus/code/The-Particle-Engine/research/optimizer.py`](/home/nickalus/code/The-Particle-Engine/research/optimizer.py)
- Cloud entrypoint: [`/home/nickalus/code/The-Particle-Engine/research/cloud/training_system.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/training_system.py)
- Cloud profiles: [`/home/nickalus/code/The-Particle-Engine/research/cloud/training_profiles.json`](/home/nickalus/code/The-Particle-Engine/research/cloud/training_profiles.json)
- Fast cloud benchmark: [`/home/nickalus/code/The-Particle-Engine/research/cloud/fast_benchmark.dart`](/home/nickalus/code/The-Particle-Engine/research/cloud/fast_benchmark.dart)
- Staged cloud search: [`/home/nickalus/code/The-Particle-Engine/research/cloud/staged_optimizer.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/staged_optimizer.py)

## Required Foundation Improvements

### 1. Canonical Schema
Create one canonical parameter schema with:

- stable key
- category
- default
- lower bound
- upper bound
- type
- source of truth file
- benchmark relevance
- calibration method

This schema should drive both the runtime override path and the research tools.

### 2. Scientific Property Coverage
The element system should distinguish:

- intrinsic properties
  density, specific heat, thermal conductivity, viscosity, porosity, hardness, conductivity, dielectric, bond energy
- phase properties
  melting point, boiling point, freezing point, latent-heat proxies, phase products
- chemical properties
  reactivity, reduction potential, ignition threshold, oxidation/reduction products, corrosion behavior
- mechanical properties
  structural integrity, support sensitivity, brittleness, compressibility proxies, vibration response
- biological/ecological interaction properties
  toxicity, moisture affinity, nutrient value, growth support, decay affinity

The current code has many of these, but they are not yet exposed through one clean schema.

### 3. Runtime Override Contract
The runtime exporter and benchmarks must accept:

- a flat canonical `params` surface for optimizers
- optional structured sections for human readability
- explicit reporting of applied overrides
- explicit reporting of ignored overrides

This is necessary so every trial is auditable.

### 4. Benchmark Contract
The runtime benchmark path must score:

- physics fidelity
- material identity and separation
- stability and regression resistance
- render quality
- performance cost

Without multi-axis scoring, optimizers will overfit to easy metrics.

## SciPy Role
SciPy should not be treated as a generic extra tool. It is the scientific calibration and validation layer.

### Recommended Uses
- `scipy.optimize`
  Fit phase thresholds, flow coefficients, corrosion rates, and thermal-response parameters to target behavior.
- `scipy.stats.qmc`
  Use Sobol or Latin Hypercube sampling for broad, high-quality exploration before Optuna refinement.
- `scipy.signal`
  Detect oscillation, ringing, unstable feedback, and periodic artifacts in simulation traces.
- `scipy.ndimage`
  Measure morphology: erosion fronts, clustering, support collapse patterns, plume shapes, cave boundaries, and diffusion envelopes.

### Recommended Process
1. Use SciPy to calibrate a smaller scientifically defensible region.
2. Use Optuna inside that region for multi-objective search.
3. Use the benchmark suite as the regression gate.

## Optuna Role
Optuna should own heavy search once the schema is stable.

### Recommended Objectives
- maximize physical plausibility
- maximize visual identity and clarity
- maximize stability/regression score
- minimize runtime/render cost

### Recommended Search Strategy
1. QMC or random design for broad exploration
2. parameter-importance ranking
3. grouped refinement
4. multi-objective Pareto search
5. full validation on the runtime exporter

## Phases

### Phase 1: Stabilize
- repair parser/structure defects in the engine
- ensure exporter/config handoff reaches the real runtime
- expose callable override surfaces

### Phase 2: Canonicalize
- define the canonical param schema
- separate intrinsic element properties from simulation tunables
- document unsupported or inferred parameters explicitly

### Phase 3: Instrument
- add timings and traces for sim, render, GI, decode, and UI cost
- add per-domain benchmark metadata for each trial

### Phase 4: Calibrate
- use SciPy to fit and validate physical models
- add sensitivity analysis and parameter-priority ranking

### Phase 5: Search
- run Optuna multi-objective studies on the canonical surface
- prune weak parameters and refine promising groups

### Phase 6: Expand
- spread the same foundation into rendering, UI identity, worldgen, and AI systems

## Follow-On R&D
After the above phases are stable, launch a second R&D pass specifically to find new opportunities, not just fix old ones:

- stronger constitutive models for fluids and granular materials
- more physically grounded heat and corrosion systems
- richer material families and periodic interactions
- better render architecture and lighting coherence
- improved UI affordances and scientific visualization tools

## External References
- Optuna docs: https://optuna.readthedocs.io/en/stable/
- SciPy QMC docs: https://docs.scipy.org/doc/scipy-1.13.0/reference/stats.qmc.html
- SciPy differential evolution docs: https://docs.scipy.org/doc/scipy-1.9.2/reference/generated/scipy.optimize.differential_evolution.html
- Flutter performance FAQ: https://docs.flutter.dev/perf/faq
- Flame performance docs: https://docs.flame-engine.org/latest/flame/other/performance.html
