# Execution Worklog

Last updated: 2026-03-24

## Purpose
This file is the persistent execution log for the current overhaul program.
It is the handoff source for compaction, agent coordination, and follow-on R&D.

## Completed
- Rebuilt the periodic table into a full-screen `Periodic Atlas` with search, inspector, family legend, reaction/demo staging, and family-specific showcase motion in [`/home/nickalus/code/The-Particle-Engine/lib/ui/widgets/periodic_table_overlay.dart`](/home/nickalus/code/The-Particle-Engine/lib/ui/widgets/periodic_table_overlay.dart).
- Added the shared animated HUD primitive in [`/home/nickalus/code/The-Particle-Engine/lib/ui/widgets/hud_icon_badge.dart`](/home/nickalus/code/The-Particle-Engine/lib/ui/widgets/hud_icon_badge.dart) and rolled it into the main HUD in [`/home/nickalus/code/The-Particle-Engine/lib/ui/widgets/tool_bar.dart`](/home/nickalus/code/The-Particle-Engine/lib/ui/widgets/tool_bar.dart) and [`/home/nickalus/code/The-Particle-Engine/lib/game/particle_engine_game.dart`](/home/nickalus/code/The-Particle-Engine/lib/game/particle_engine_game.dart).
- Fixed persistence flow gaps around save/load, colony restoration, and manual save UI in the earlier execution wave.
- Repaired the malformed duplicate `step(...)` structure in [`/home/nickalus/code/The-Particle-Engine/lib/simulation/simulation_engine.dart`](/home/nickalus/code/The-Particle-Engine/lib/simulation/simulation_engine.dart).
- Replaced the invalid `SimTuning._setParam(...)` switch with a setter map and added `SimTuning.applyOverrides(...)` in [`/home/nickalus/code/The-Particle-Engine/lib/simulation/simulation_engine.dart`](/home/nickalus/code/The-Particle-Engine/lib/simulation/simulation_engine.dart).
- Added `ElementProperties.copyWith(...)` in [`/home/nickalus/code/The-Particle-Engine/lib/simulation/element_registry.dart`](/home/nickalus/code/The-Particle-Engine/lib/simulation/element_registry.dart) so runtime research overrides can update element definitions without rebuilding the whole registry.
- Wired trial-config ingestion into [`/home/nickalus/code/The-Particle-Engine/research/export_frame.dart`](/home/nickalus/code/The-Particle-Engine/research/export_frame.dart), including:
  - explicit config-path resolution
  - active override application before stepping the engine
  - applied/ignored override reporting in `frame_meta.json`
- Added the shared parameter contract at [`/home/nickalus/code/The-Particle-Engine/research/parameter_contract.py`](/home/nickalus/code/The-Particle-Engine/research/parameter_contract.py) and the starter canonical manifest at [`/home/nickalus/code/The-Particle-Engine/research/parameter_manifest.json`](/home/nickalus/code/The-Particle-Engine/research/parameter_manifest.json).
- Moved local and cloud optimizer config writing onto the same manifest-backed contract in [`/home/nickalus/code/The-Particle-Engine/research/optimizer.py`](/home/nickalus/code/The-Particle-Engine/research/optimizer.py) and [`/home/nickalus/code/The-Particle-Engine/research/cloud/run_optimizer.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/run_optimizer.py).
- Added the single cloud orchestration entrypoint at [`/home/nickalus/code/The-Particle-Engine/research/cloud/training_system.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/training_system.py) with profiles at [`/home/nickalus/code/The-Particle-Engine/research/cloud/training_profiles.json`](/home/nickalus/code/The-Particle-Engine/research/cloud/training_profiles.json).
- Removed hardcoded ThunderCompute tokens from source and moved provider secret loading into [`/home/nickalus/code/The-Particle-Engine/research/cloud/env_utils.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/env_utils.py) plus the local gitignored env file `research/cloud/.thundercompute.env`.
- Added config normalization back from canonical payloads in [`/home/nickalus/code/The-Particle-Engine/research/parameter_contract.py`](/home/nickalus/code/The-Particle-Engine/research/parameter_contract.py) and moved [`/home/nickalus/code/The-Particle-Engine/research/cloud/proper_benchmark.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/proper_benchmark.py) onto that shared loader.
- Updated [`/home/nickalus/code/The-Particle-Engine/research/cloud/fast_benchmark.dart`](/home/nickalus/code/The-Particle-Engine/research/cloud/fast_benchmark.dart) so it can read both flat `params` and nested `elements.*` fields from the manifest-backed trial config.
- Added a richer shared panel shell to [`/home/nickalus/code/The-Particle-Engine/lib/ui/theme/particle_theme.dart`](/home/nickalus/code/The-Particle-Engine/lib/ui/theme/particle_theme.dart) and applied it to [`/home/nickalus/code/The-Particle-Engine/lib/ui/screens/settings_screen.dart`](/home/nickalus/code/The-Particle-Engine/lib/ui/screens/settings_screen.dart) and [`/home/nickalus/code/The-Particle-Engine/lib/ui/widgets/element_bottom_bar.dart`](/home/nickalus/code/The-Particle-Engine/lib/ui/widgets/element_bottom_bar.dart).
- Expanded [`/home/nickalus/code/The-Particle-Engine/research/parameter_manifest.json`](/home/nickalus/code/The-Particle-Engine/research/parameter_manifest.json) to cover the main world-generation surface plus a first canonical chemistry/electrical calibration surface.
- Updated [`/home/nickalus/code/The-Particle-Engine/research/export_frame.dart`](/home/nickalus/code/The-Particle-Engine/research/export_frame.dart) to apply a broader chemistry property set and emit a stricter benchmark ABI with contract version, manifest, scenario, source label, seed, and effective config snapshot.
- Moved [`/home/nickalus/code/The-Particle-Engine/research/cloud/gpu_chemistry_optimizer.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/gpu_chemistry_optimizer.py) and [`/home/nickalus/code/The-Particle-Engine/research/cloud/worldgen_optimizer.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/worldgen_optimizer.py) closer to the shared contract by exporting canonical manifest-backed trial configs and canonical override payloads.
- Extended [`/home/nickalus/code/The-Particle-Engine/research/cloud/training_system.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/training_system.py) and [`/home/nickalus/code/The-Particle-Engine/research/cloud/training_profiles.json`](/home/nickalus/code/The-Particle-Engine/research/cloud/training_profiles.json) so world generation is now a first-class lane in the single cloud training system rather than a sidecar-only optimizer.
- Rolled the shared HUD/panel language further into [`/home/nickalus/code/The-Particle-Engine/lib/ui/widgets/colony_inspector.dart`](/home/nickalus/code/The-Particle-Engine/lib/ui/widgets/colony_inspector.dart) and [`/home/nickalus/code/The-Particle-Engine/lib/ui/widgets/mini_map.dart`](/home/nickalus/code/The-Particle-Engine/lib/ui/widgets/mini_map.dart).

## In Progress
- Converging on a canonical element/setter/tuning foundation that can support SciPy calibration and Optuna multi-objective search without schema drift.
- Folding the remaining surrogate cloud scripts into the same naming and manifest contract so the A100 path stops splitting across private parameter dialects.
- Standardizing research/cloud naming so the active system uses professional canonical entrypoints rather than experimental-sounding script names.
- Tightening chemistry and worldgen worker outputs so surrogate GPU studies produce traceable canonical artifacts instead of isolated local parameter payloads.

## Immediate Next
- Extend the manifest contract into the remaining surrogate and GPU-specific calibration scripts that still maintain private parameter dialects, especially `gpu_electrical_benchmark.py`, `gpu_conservation_validator.py`, and the longer-tail cloud workers.
- Teach the fast benchmark path and runtime exporter to consume a wider set of canonical chemistry and world parameters so A100 discoveries transfer more directly into Dart-side validation.
- Push the shared UI shell and icon/render language into `home_screen.dart`, `tool_bar.dart`, and additional in-game inspection surfaces.
- Start the next SciPy-oriented calibration lane around search-space reduction, Sobol/QMC coverage, and sensitivity analysis against the manifest-backed parameter groups.

## Agent Findings In Use
- Physics audit: `simulation_engine.dart` had a real structural defect and the simulation state/tuning surface was not cleanly exposed to research tooling.
- Rendering audit: hot path is dominated by CPU pixel generation, image churn, GI overhead, and readback cadence.
- Optimization audit: local optimizer/config handoff was not reaching the Dart exporter; cloud path relied on a different contract.
- Cloud/A100 audit: one manifest, one runtime boundary, and one orchestrator should replace the current mix of private parameter dialects and script-specific contracts.
- UI audit: the new HUD badge/render language should become the canonical control primitive and spread to remaining UI surfaces.

## Research Backbone
- Optuna official docs: https://optuna.readthedocs.io/en/stable/
- SciPy QMC docs: https://docs.scipy.org/doc/scipy-1.13.0/reference/stats.qmc.html
- SciPy differential evolution docs: https://docs.scipy.org/doc/scipy-1.9.2/reference/generated/scipy.optimize.differential_evolution.html
- Flutter performance FAQ: https://docs.flutter.dev/perf/faq
- Flame performance docs: https://docs.flame-engine.org/latest/flame/other/performance.html

## Benchmark Status
- Full verification is blocked locally because the installed Flutter/Dart wrapper at `/mnt/c/Users/Nicka/flutter/bin/internal/shared.sh` has CRLF line endings and fails before launching the toolchain.
- Because of that, `flutter analyze`, `dart analyze`, and end-to-end benchmark/test verification are still pending.
- Once the wrapper is fixed, first verification pass should be:
  1. `dart run research/export_frame.dart 100`
  2. `python research/benchmark.py --quick --json`
  3. smoke launch save/load flow
  4. periodic atlas/HUD visual smoke pass

## Planned Follow-On R&D
- After the foundation pass is stable, launch a second R&D lane focused on new improvement vectors:
  - richer material-property realism
  - improved constitutive models for fluids, heat, corrosion, and structural failure
  - render architecture upgrades and measurement-guided visual improvements
  - broader SciPy calibration and sensitivity tooling
  - next-generation UI interaction and icon/render systems
  - better surrogate-to-runtime transfer scoring so A100 searches optimize for what survives contact with the real engine
