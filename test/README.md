# Test Suite Layout

This project uses a layered, production-style test hierarchy.

- `test/unit/`
  - Fast deterministic tests for isolated subsystems.
  - `simulation/`: engine behavior, invariants, helper APIs, update passes, structural systems.
  - `rendering/`: pixel pipeline and visual invariants.
  - `services/`: persistence and settings logic.
- `test/performance/`
  - Repeatable budget and stress checks.
  - `game_loop/`: Level 2 loop/per-frame budgets in Flutter/Flame runtime.
  - `simulation/`: long-run soak, stability, and physics-integrity gates.
  - Includes deterministic replay parity, metamorphic invariance, and visual regression suites.
  - Emits scenario metrics via `test/helpers/perf_reporter.dart` to JSONL.
  - Emits visual artifact manifests via `test/helpers/visual_regression.dart` to JSONL.
- `test/smoke/`
  - Minimal boot/integration smoke tests.
- `test/helpers/`
  - Shared harness and fixtures for test setup.
  - Includes scenario DSL and behavior-signature helpers for regression tests.

Naming conventions:
- Use `<domain>_<scope>_test.dart`.
- Keep one domain focus per file.
- Prefer deterministic seeds and explicit budget assertions.

Performance telemetry:
- Set `PERF_REPORT_PATH` to control JSONL output location.
- Default output path is `build/perf/perf_metrics.jsonl`.
