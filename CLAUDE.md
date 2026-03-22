# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

The Particle Engine is a pixel-based sandbox simulation game built with Flutter and Flame. It combines a cellular automaton physics engine with NEAT-evolved ant colony AI. The core sim runs headless on typed arrays; Flame handles rendering and input.

## Build & Run Commands

```bash
# Run the app
flutter run

# Run on specific device
flutter run -d windows
flutter run -d chrome

# Analyze (lint)
flutter analyze

# Run Flutter tests
flutter test

# Run a single test
flutter test test/widget_test.dart

# Run NEAT colony benchmark (headless Dart, no Flutter)
dart run research/neat_benchmark.dart

# Run engine autoresearch benchmark
dart run research/engine_benchmark.dart

# Run Python physics test suite (requires numpy, scipy, pytest)
cd research && python -m pytest tests/ -v

# Run a single Python test file
python -m pytest research/tests/test_fluid_dynamics.py -v

# Optuna parameter optimizer
python research/optimizer.py run --n-trials 50
python research/optimizer.py show --top 5
```

## Architecture

### Simulation Layer (no Flutter dependency — runs headless)

- **`SimulationEngine`** (`lib/simulation/simulation_engine.dart`) — Core cellular automaton. Flat `Uint8List` grids for element type, life, flags, velocity, temperature, pressure, pheromones. Uses 16x16 dirty chunk system and clock-bit double-simulation prevention. Default grid: 320x180.
- **`El`** constants (`lib/simulation/element_registry.dart`) — 25 element types as byte constants (0-24). Grid cells are raw bytes; never use objects per cell.
- **`simulateElement()`** (`lib/simulation/element_behaviors.dart`) — Dispatch function routing each element byte to its behavior. All 25 element physics methods live here.
- **`PixelRenderer`** (`lib/simulation/pixel_renderer.dart`) — Converts grid state to an RGBA pixel buffer. Integer-only math in hot paths. Handles glow, micro-particles, day/night, stars, ground-level detection.

### Flame Game Layer

- **`ParticleEngineGame`** (`lib/game/particle_engine_game.dart`) — Top-level `FlameGame`. Fixed-resolution camera, overlay management, two-state HUD (observation/creation), pinch zoom, keyboard/mouse pan.
- **`SandboxWorld`** (`lib/game/sandbox_world.dart`) — Flame `World` owning the `SimulationEngine` and all renderable components. Fixed-rate sim stepping at 30fps, decoupled from 60fps render.
- **`SandboxComponent`** (`lib/game/components/sandbox_component.dart`) — Renders the pixel grid as a `ui.Image` each frame. Handles tap/drag for element placement with Bresenham interpolation.

### Creature AI Layer

- **`Ant`** (`lib/creatures/ant.dart`) — Individual entity with position, energy, NEAT neural brain, fitness tracker. Ants are overlaid on the grid, not in it.
- **`Colony`** (`lib/creatures/colony.dart`) — Owns ants, three pheromone channels, NEAT evolution, food/nest state. Ticks staggered across frames.
- **`CreatureRegistry`** (`lib/creatures/creature_registry.dart`) — Manages all colonies, caps neural forward passes at 50/tick/colony.
- **NEAT library** (`lib/creatures/neat/`) — Full NEAT implementation: `NeatGenome`, `NeatForward` (compiled feed-forward), `NeatPopulation`, speciation, `AntBrain`, `AntFitness`, `ColonyEvolution`, `NeatConfig`.

### World Generation

- `lib/simulation/world_gen/` — `WorldGenerator` orchestrates `TerrainGenerator` (heightmaps via noise) and `FeaturePlacer` (caves, water bodies, etc). Configured by `WorldConfig` presets.

### Research Subsystem

- `research/` — Headless benchmarking, Python physics oracle (`physics_oracle.py`), pytest test suite validating physics/visuals against scipy ground truth, NEAT autoresearch protocol, Optuna optimizer.
- Two autoresearch protocols: `research/program.md` (NEAT colony optimization) and `research/engine_program.md` (physics/rendering improvement loop).

## Critical Constraints

- **No allocations in hot loops.** `step()` and `renderPixels()` process 57,600 cells/frame. No List creation, closures, or objects inside per-cell iteration.
- **Integer-only math in renderers.** Use `@pragma('vm:prefer-inline')` for helpers. Replace `sin()`/`cos()` with table lookups or hash approximations.
- **Elements use byte constants, not enums or objects.** The grid is `Uint8List`; element identity is a raw `int` from the `El` class.
- **Deterministic simulation.** Always use `engine.rng` (seeded `Random`), never `Random()` in simulation code.
- **Dirty chunk system is load-bearing.** Any code placing or moving elements must call `engine.markDirty(x, y)` to flag the containing chunk.
- **Clock-bit prevents double simulation.** Bit 7 of `flags[i]` tracks whether a cell was already processed this tick. Check `(flags[i] >> 7) == simClock ? 1 : 0` before processing.
- **Landscape only.** Locked at startup in `main.dart`.

## Isolate Architecture (planned, not yet implemented)

Design doc at `docs/isolate_architecture.md`. The simulation will move to a background isolate using `TransferableTypedData` with double-buffering. Current code runs synchronously on the main thread. The `SimulationBridge` abstraction layer is the first migration step.

## Platform Notes

- Web builds: Dart isolates fall back to Web Workers with different semantics; the synchronous bridge should be used.
- Grid wrapping: X-axis wraps horizontally; Y-axis does not wrap (ground/sky are fixed boundaries).
- Hot reload does not update code in spawned isolates.
