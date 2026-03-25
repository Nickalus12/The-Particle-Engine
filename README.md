# The Particle Engine

The Particle Engine is a sandbox simulation game and research platform built around a shared material system, real-time particle simulation, authored UI, and a cloud calibration pipeline for large-scale tuning.

This repository now serves two purposes:
- the playable game and its runtime systems
- the research/training stack used to calibrate physics, chemistry, world generation, rendering, and performance

## Current Direction

The project is being pushed toward a single professional foundation where:
- element behavior is defined by explicit material properties
- simulation tuning lives on a canonical parameter surface
- SciPy is used for calibration, sensitivity analysis, and scientific validation
- Optuna is used for large-scale multi-objective search
- cloud GPU runs use one orchestration system and one parameter contract
- UI and rendering share a stronger authored visual language instead of isolated one-off widgets

Key planning docs:
- [`docs/foundation_program.md`](/home/nickalus/code/The-Particle-Engine/docs/foundation_program.md)
- [`docs/naming_conventions.md`](/home/nickalus/code/The-Particle-Engine/docs/naming_conventions.md)
- [`docs/execution_worklog.md`](/home/nickalus/code/The-Particle-Engine/docs/execution_worklog.md)

## What Changed In This Program

The recent overhaul established several important foundations:
- unified runtime and research overrides around [`research/parameter_manifest.json`](/home/nickalus/code/The-Particle-Engine/research/parameter_manifest.json) and [`research/parameter_contract.py`](/home/nickalus/code/The-Particle-Engine/research/parameter_contract.py)
- made [`research/cloud/training_system.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/training_system.py) the canonical cloud orchestration entrypoint
- moved cloud profiles into [`research/cloud/training_profiles.json`](/home/nickalus/code/The-Particle-Engine/research/cloud/training_profiles.json)
- repaired Dart/Flutter cloud setup in [`research/cloud/bootstrap.sh`](/home/nickalus/code/The-Particle-Engine/research/cloud/bootstrap.sh) and [`research/cloud/setup.sh`](/home/nickalus/code/The-Particle-Engine/research/cloud/setup.sh)
- improved H100/A100 scheduling with [`research/cloud/system_profile.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/system_profile.py)
- strengthened cloud validation and logging in [`research/cloud/unified_physics_pipeline.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/unified_physics_pipeline.py) and [`research/cloud/training_system.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/training_system.py)
- pushed a more deliberate render/UI language into the game HUD and the Periodic Atlas

## Runtime Architecture

Core runtime ownership:
- simulation engine: [`lib/simulation/simulation_engine.dart`](/home/nickalus/code/The-Particle-Engine/lib/simulation/simulation_engine.dart)
- material registry: [`lib/simulation/element_registry.dart`](/home/nickalus/code/The-Particle-Engine/lib/simulation/element_registry.dart)
- behavior consumers: [`lib/simulation/element_behaviors.dart`](/home/nickalus/code/The-Particle-Engine/lib/simulation/element_behaviors.dart)
- world orchestration: [`lib/game/sandbox_world.dart`](/home/nickalus/code/The-Particle-Engine/lib/game/sandbox_world.dart)
- runtime exporter for research: [`research/export_frame.dart`](/home/nickalus/code/The-Particle-Engine/research/export_frame.dart)

The intended layering is:
1. intrinsic element properties
2. simulation tunables
3. research/benchmark override contract

If those layers drift, cloud optimization becomes untrustworthy.

## Research And Training System

Canonical research ownership:
- benchmark spine: [`research/benchmark.py`](/home/nickalus/code/The-Particle-Engine/research/benchmark.py)
- local optimizer: [`research/optimizer.py`](/home/nickalus/code/The-Particle-Engine/research/optimizer.py)
- cloud training entrypoint: [`research/cloud/training_system.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/training_system.py)
- cloud validation lane: [`research/cloud/unified_physics_pipeline.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/unified_physics_pipeline.py)
- staged search: [`research/cloud/staged_optimizer.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/staged_optimizer.py)
- GPU chemistry lane: [`research/cloud/gpu_chemistry_optimizer.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/gpu_chemistry_optimizer.py)
- GPU worldgen lane: [`research/cloud/worldgen_optimizer.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/worldgen_optimizer.py)

The active contract is:
- one parameter manifest
- one override language
- one cloud scheduler
- one persistent execution worklog

## SciPy And Optuna Roles

SciPy is the calibration and validation layer. It should be used for:
- parameter fitting with `scipy.optimize`
- search-space coverage with `scipy.stats.qmc`
- oscillation and stability analysis with `scipy.signal`
- morphology and diffusion analysis with `scipy.ndimage`

Optuna is the large-scale search layer. It should be used for:
- importance ranking
- grouped refinement
- Pareto search across fidelity, stability, visual clarity, and cost

Recommended sequence:
1. use SciPy to find a defensible region
2. use Optuna to search inside that region
3. validate discoveries against the runtime exporter and benchmark suite

## ThunderCompute VM System

The cloud workflow is built around ThunderCompute for large GPU calibration runs.

Important local files:
- provider env loader: [`research/cloud/env_utils.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/env_utils.py)
- launcher: [`research/cloud/launch.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/launch.py)
- deploy helper: [`research/cloud/deploy_and_run.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/deploy_and_run.py)
- bootstrap/setup: [`research/cloud/bootstrap.sh`](/home/nickalus/code/The-Particle-Engine/research/cloud/bootstrap.sh), [`research/cloud/setup.sh`](/home/nickalus/code/The-Particle-Engine/research/cloud/setup.sh)
- persistent local instance state: `research/cloud/.instance_state.json` (gitignored)

Current VM system characteristics:
- target provider: ThunderCompute
- preferred GPU: A100
- fallback observed in live use: H100 PCIe when A100 capacity is unavailable
- current orchestration profile family: `cloud_*`
- current main profile: `cloud_foundation`

### Current Known Live Instance

The active overhaul used:
- instance id: `bhk7cmo9`
- provider: ThunderCompute
- GPU: H100 PCIe
- CPU cores: `18`
- system RAM: about `90 GiB`

The user also created a provider snapshot after the run was stabilized.

### Cloud Run Flow

1. Create VM.
2. Bootstrap Dart, Flutter, Python, CuPy, and dependencies.
3. Clone the repo to the VM.
4. Launch the canonical training entrypoint:

```bash
python3 research/cloud/training_system.py --profile cloud_foundation
```

5. Inspect per-step logs instead of relying only on one wrapper log:
- `gpu_validation.log`
- `staged_optimizer.log`
- `gpu_chemistry_optimizer.log`
- `worldgen_optimizer.log`

### What We Learned About The VM System

- The original scripts were not using the H100 efficiently enough.
- Blindly increasing worker counts was not enough; GPU ownership and phase scheduling mattered more.
- Multiple GPU-heavy subprocesses on one device caused contention and operational noise.
- Validation needed to be safer and more informative, not just larger.
- Live per-step logs and a run lock were necessary to stop overlapping orphan runs from corrupting results.

## H100 / Cloud Findings So Far

Useful outcomes already gained:
- the cloud stack now launches cleanly with box-aware worker sizing
- Dart and Flutter were repaired on the VM and verified there
- validation now completes far enough to let the pipeline move into staged optimization
- staged optimization produced fresh importance rankings in `cloud_param_importance.json`
- the system now has cleaner observability and fewer run-collision failure modes

Important problems still open:
- electrical validation is still weak in several scenarios
- chemistry GPU workers currently fail under CUDA multiprocessing initialization
- worldgen-only history proved infrastructure but produced weak objective signal
- local Dart/Flutter verification is still blocked by the host wrapper at `/mnt/c/Users/Nicka/flutter/bin/internal/shared.sh`

### Latest Validation Picture

After the validator fixes, the cloud validation lane improved materially.

Conservation now passes:
- mass conservation without reactions
- charge conservation
- closed-system energy conservation
- oxidation stoichiometry

Still failing:
- voltage/Kirchhoff consistency
- combustion energy proportionality
- acid selectivity

Electrical validation still fails several important scenarios:
- straight wire conduction
- water bridge attenuation
- parallel path splitting
- ohmic heating
- wet wood conductivity

This means the infrastructure is healthier, but parts of the physics oracle still need work before cloud search is fully trustworthy.

## UI And Rendering Direction

The game UI is moving toward a more authored exhibit-style language.

Recent work includes:
- the full-screen Periodic Atlas in [`lib/ui/widgets/periodic_table_overlay.dart`](/home/nickalus/code/The-Particle-Engine/lib/ui/widgets/periodic_table_overlay.dart)
- the shared HUD badge primitive in [`lib/ui/widgets/hud_icon_badge.dart`](/home/nickalus/code/The-Particle-Engine/lib/ui/widgets/hud_icon_badge.dart)
- stronger panel shells in [`lib/ui/theme/particle_theme.dart`](/home/nickalus/code/The-Particle-Engine/lib/ui/theme/particle_theme.dart)

The current visual direction is:
- layered materials instead of plain utility widgets
- motion that communicates category and behavior
- consistent HUD primitives across multiple surfaces
- richer inspection and demonstration flows for elements and systems

## How To Work With The System

### Local planning and calibration

```bash
python research/cloud/training_system.py --plan-only --profile cloud_foundation
```

### Runtime export smoke test

```bash
dart run research/export_frame.dart 100
```

### Fast cloud benchmark smoke test

```bash
dart run research/cloud/fast_benchmark.dart
```

### Python validation smoke test

```bash
python research/cloud/unified_physics_pipeline.py --validate --scenarios 1000 --circuits 200
```

## Known Constraints

- Local Flutter/Dart analysis is currently blocked by a broken host wrapper with CRLF line endings.
- Some older cloud scripts still need deeper contract cleanup even though the main orchestration path is unified.
- The chemistry GPU worker model is not yet correct for a single H100 owner process.

## Near-Term Priorities

1. Fix the chemistry CUDA initialization model so the GPU lane can run reliably.
2. Improve electrical and chemistry validator realism so Optuna is optimizing against a stronger oracle.
3. Push the manifest contract through the remaining long-tail cloud workers.
4. Continue propagating the stronger UI/render language through the app shell.
5. Restore local analyzer/test execution once the host Flutter/Dart wrapper is fixed.

## External References

- Optuna docs: https://optuna.readthedocs.io/en/stable/
- SciPy QMC docs: https://docs.scipy.org/doc/scipy-1.13.0/reference/stats.qmc.html
- SciPy differential evolution docs: https://docs.scipy.org/doc/scipy-1.9.2/reference/generated/scipy.optimize.differential_evolution.html
- Flutter performance FAQ: https://docs.flutter.dev/perf/faq
- Flame performance docs: https://docs.flame-engine.org/latest/flame/other/performance.html
