# Naming Conventions

## Goal
Keep the active system professional, legible, and durable.
Names should describe responsibility, not hype, novelty, or experiment status.

## Rules
- Use nouns for stable artifacts.
  Examples: `parameter_manifest.json`, `training_profiles.json`
- Use direct system names for primary entrypoints.
  Examples: `training_system.py`, `benchmark.py`, `parameter_contract.py`
- Use domain-qualified names for specialized workers.
  Examples: `gpu_chemistry_optimizer.py`, `worldgen_optimizer.py`
- Avoid inflated or vague prefixes.
  Avoid names like `ultimate`, `mega`, `max`, `nextgen`, `proper`, `super`, `best`
- Avoid duplicate verb phrases for similar actions.
  Prefer one clear entrypoint over several variants like `start_training`, `begin_training`, `run_training`
- Reserve `legacy` for compatibility wrappers or transitional scripts only.

## Canonical Active Names
- Cloud entrypoint: [`/home/nickalus/code/The-Particle-Engine/research/cloud/training_system.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/training_system.py)
- Cloud profiles: [`/home/nickalus/code/The-Particle-Engine/research/cloud/training_profiles.json`](/home/nickalus/code/The-Particle-Engine/research/cloud/training_profiles.json)
- Parameter manifest: [`/home/nickalus/code/The-Particle-Engine/research/parameter_manifest.json`](/home/nickalus/code/The-Particle-Engine/research/parameter_manifest.json)
- Parameter contract: [`/home/nickalus/code/The-Particle-Engine/research/parameter_contract.py`](/home/nickalus/code/The-Particle-Engine/research/parameter_contract.py)
- Runtime exporter: [`/home/nickalus/code/The-Particle-Engine/research/export_frame.dart`](/home/nickalus/code/The-Particle-Engine/research/export_frame.dart)
- Benchmark spine: [`/home/nickalus/code/The-Particle-Engine/research/benchmark.py`](/home/nickalus/code/The-Particle-Engine/research/benchmark.py)

## Current Legacy / Transitional Names
- [`research/cloud/run_optimizer.py`](../research/cloud/run_optimizer.py)
  DEPRECATED legacy cloud optimizer runner. Superseded by `training_system.py`.
- [`/home/nickalus/code/The-Particle-Engine/research/cloud/unified_physics_pipeline.py`](/home/nickalus/code/The-Particle-Engine/research/cloud/unified_physics_pipeline.py)
  Validation worker/orchestrator for a specific GPU physics lane. It should sit under the main training system, not replace it.
- [`research/cloud/benchmark_optuna.py`](../research/cloud/benchmark_optuna.py)
  Renamed from `proper_benchmark.py` to reflect its role as the Optuna physics benchmark.

## Naming Direction For Future Refactors
- If a script is the main entrypoint, give it the simplest name.
- If a script is experimental or surrogate-only, say so explicitly.
- If two scripts overlap in responsibility, consolidate them behind one canonical name and demote the other to a worker or retire it.
