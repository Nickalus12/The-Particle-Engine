## Requirements
- Implement the Physics + World Generation Deep Improvement Plan.
- Add explicit physics phases and central cadence control.
- Add phase-level telemetry and machine-readable artifacts.
- Add staged world-generation summaries, topology metrics, and validation output.
- Extend performance pipeline, OTLP export, Grafana dashboards/alerts, and quality scoring.
- Add dedicated tests for determinism, contracts, and scoring.

## Research Findings
- `lib/game/components/sandbox_component.dart` appears to be a primary render hotspot: it maintains the pixel renderer output and performs multiple image draws each frame with camera scaling, which is a likely mobile overdraw and fill-rate cost.
- `lib/game/components/creature_renderer.dart` contains many per-creature and per-pixel `drawRect` calls, which is likely expensive on mobile when colonies become visible and numerous.
- There is already a mobile/performance test surface in `test/performance/game_loop` and mobile smoke coverage, so this pass can add targeted render-path metrics and regressions instead of inventing a new test harness from scratch.
- `SandboxRuntimeProfile` was still fairly generous for handhelds and lacked render/detail tuning knobs, so mobile-specific runtime behavior had to be inferred indirectly instead of configured explicitly.
- The sandbox render path always painted three wrapped world copies, even when the viewport only needed one, which meant avoidable overdraw on most frames.
- Post-processing and pixel-image rebuilds are the most obvious high-cost visual features on handhelds, so adaptive cadence and selective shedding are strong early wins before deeper renderer rewrites.
- Creature rendering also benefits from simple viewport-aware culling: most of the cost comes from needless offscreen per-ant draw work, and that can be reduced safely before attempting a more invasive sprite-batching rewrite.
- The new render telemetry emitted by `SandboxComponent` is useful enough to promote into first-class artifacts instead of leaving it buried inside scenario metrics; that keeps downstream quality and Grafana work much simpler.
- The sandbox already had a surprisingly strong enjoyment seam: `SandboxEnjoymentOverlay` in the screen layer plus `ColonyEvents` in the creature model. The highest-value move was to strengthen those seams rather than invent a separate UX system.
- For mobile safety, keeping the enjoyment layer `IgnorePointer`-transparent is preferable to making it interactive immediately; that preserves the recently fixed HUD passthrough behavior while still improving clarity and direction.
- The next biggest enjoyment gap is that the current feed is colony-heavy; world hazards like floods, ignitions, collapses, and chemistry spikes still need a world-level aggregation path to feel like part of the same story.
- Presets still need stronger gameplay identity. The easiest high-value path is preset-specific objective text and challenge framing before deeper simulation tuning.
- Colony-focused UX remains incomplete because the inspector/feed still default to the first colony. Selection will unlock much better player agency than more raw metrics alone.
- Future HUD additions should be designed around explicit reserved hit-test regions, since mobile interaction regressions are a recurring risk whenever new screen-layer UI is introduced.
- The creature/colony layer already contains the right signals for a better player experience: colony health state, spawn success, death causes, population over time, rendered counts, and a dormant `colony_events.dart` UI-facing model.
- A high-impact enjoyment layer can live safely at the Flutter screen level, where it can read game state and remain input-transparent, instead of becoming another expensive Flame overlay or render-system concern.
- `lib/simulation/simulation_engine.dart` already had distinct passes; the safest first improvement was central cadence + additive telemetry around them.
- `lib/simulation/world_gen/world_generator.dart` was already staged logically, which made it feasible to wrap the generator in explicit stage accounting and post-generation validation.
- `tool/performance/pipeline.py` and `tool/performance/run_quality_pipeline.py` already supported additive artifacts/components, so physics/worldgen summaries could be integrated without replacing the existing performance pipeline.
- `tool/performance/export_otlp.py` already had a clean pattern for iterating metric families, making physics/worldgen OTLP export low-risk to extend.
- `research/parameter_manifest.json` already covered a broader Optuna surface than either optimizer was using, so the main opportunity was contract unification rather than inventing brand-new knobs.
- The fast cloud benchmark consumed element overrides but not the full sim-tuning surface, which would have made many Optuna variables appear searchable without affecting runtime behavior.
- Profile-aware search surfaces are most useful when paired with persisted metadata; otherwise later analysis cannot distinguish a "mobile" study from a broad exploratory one.
- Benchmark scoring was still using a single fixed domain weighting, which meant mobile-focused tuning runs were being judged by the same balance as broad exploratory studies.
- The performance and quality pipelines did not yet discover `trial_config.json` or emit Optuna metadata into run artifacts, which left Grafana and downstream comparisons blind to optimization intent.

## Technical Decisions
| Decision | Rationale |
|----------|-----------|
| Add `physics_runtime.dart` for scheduler/sample/snapshot contracts | Keeps engine telemetry typed and reusable instead of embedding loose maps everywhere |
| Add `worldgen_summary.dart` and store summary on `GridData` | Lets tests and future perf harnesses access worldgen artifacts directly |
| Use additive advisory scores for physics/worldgen/chemistry in quality pipeline | Extends scoring without destabilizing the weighted primary gate immediately |
| Add reaction metadata fields on `ReactionRule` now, even before deeper chemistry refactors | Provides an observability/tuning seam we can build on later |
| Move Optuna search-space rules into contract helpers (`step`, `log`, profile selection) | Prevents local/cloud optimizer drift and keeps search behavior reviewable in one place |
| Treat `source_label` and `optuna` metadata as first-class trial-config fields | Lets runtime exports and future dashboards attribute results to the right study profile |
| Use bounded Optuna labels (`profile`, `source_label`, `execution_mode`) in OTLP base attributes | Preserves Grafana usefulness without causing cardinality blowups |
| Make `benchmark.py` ingest Optuna metadata from CLI/env/JSON | Lets manual, local, and automated studies all share one attribution path |
| Add explicit mobile render/detail knobs to the runtime profile and game constructor | Makes mobile perf behavior testable and tunable without platform hacks |
| Prefer adaptive cadence and selective visual degradation over disabling the whole renderer | Keeps gameplay readable while reclaiming frame time on phones |

## Issues Encountered
| Issue | Resolution |
|-------|------------|
| `python` not available in shell | Verified only Dart-side changes directly; Python-side validation remains limited to code inspection in this environment |
| Dart test runner output truncated in this environment | Recorded limitation explicitly and avoided overclaiming detailed pass/fail status |
| Large patch payload exceeded apply_patch/tool limits | Split the implementation into smaller targeted patches |
| Cloud/local optimizer defaults drifted from the active profile surface | Switched defaults to be derived from the selected manifest entries, not a static full set |

## Resources
- `D:\Projects\The_Particle_Engine\lib\simulation\simulation_engine.dart`
- `D:\Projects\The_Particle_Engine\lib\simulation\physics_runtime.dart`
- `D:\Projects\The_Particle_Engine\lib\simulation\world_gen\world_generator.dart`
- `D:\Projects\The_Particle_Engine\lib\simulation\world_gen\worldgen_summary.dart`
- `D:\Projects\The_Particle_Engine\tool\performance\pipeline.py`
- `D:\Projects\The_Particle_Engine\tool\performance\run_quality_pipeline.py`
- `D:\Projects\The_Particle_Engine\tool\performance\export_otlp.py`
- `D:\Projects\The_Particle_Engine\research\optimizer.py`
- `D:\Projects\The_Particle_Engine\research\cloud\run_optimizer.py`
- `D:\Projects\The_Particle_Engine\research\parameter_contract.py`
- `D:\Projects\The_Particle_Engine\research\parameter_manifest.json`
- `D:\Projects\The_Particle_Engine\research\cloud\fast_benchmark.dart`
- `D:\Projects\The_Particle_Engine\research\tests\test_optuna_contract.py`
- `D:\Projects\The_Particle_Engine\research\benchmark.py`
- `D:\Projects\The_Particle_Engine\lib\game\components\sandbox_component.dart`
- `D:\Projects\The_Particle_Engine\lib\game\components\creature_renderer.dart`
- `D:\Projects\The_Particle_Engine\lib\game\runtime\sandbox_runtime_profile.dart`
- `D:\Projects\The_Particle_Engine\test\performance\game_loop\game_loop_performance_test.dart`
- `D:\Projects\The_Particle_Engine\tool\performance\tests\test_pipeline_contract.py`
- `D:\Projects\The_Particle_Engine\tool\performance\tests\test_quality_pipeline_contract.py`
- `D:\Projects\The_Particle_Engine\tool\performance\tests\test_export_otlp_contract.py`

## Visual/Browser Findings
- No browser use in this pass.
