# Performance Observability Stack

This project now includes a local-first performance observability pipeline with:

- Canonical local storage in SQLite
- Optional analytics mirror in DuckDB
- Optional shared storage in Postgres
- Optional OTLP export into local LGTM (Grafana/Loki/Tempo/Mimir)
- Profile-based CI tiering (`pr`, `nightly`, `investigative`)

## 1) Run local LGTM (offline)

From project root:

```powershell
.\observability\start_local_stack.ps1
```

- Grafana UI: `http://localhost:3000`
- Default login: `admin` / `admin`
- OTLP HTTP endpoint: `http://localhost:4318`
- Provisioned dashboard UID: `particle-perf-overview`

## 2) Run performance pipeline

```powershell
python tool/performance/run_performance_pipeline.py --profile pr
```

Or:

```powershell
.\tool\performance\run_performance_pipeline.ps1 -Profile pr
```

To run and publish directly to local Grafana/LGTM:

```powershell
.\tool\performance\run_observability_pipeline.ps1 -Profile pr -TargetTimeoutSeconds 180
```

Verify local stack + provisioning + query path:

```powershell
python tool/performance/verify_observability.py
```

Default runtime profile is bounded for fast feedback:

- `pr`: headless game-loop smoke + physics integrity (no soak by default)
- `nightly`: includes fuzz + soak + visual regression + atmospherics quality
- `investigative`: includes fuzz + visual regression + atmospherics diagnostics
- per-target timeout from profile defaults (overridable)

Outputs:

- Run artifact: `reports/performance/runs/<run_id>/run.json`
- Comparison: `reports/performance/runs/<run_id>/comparison.json`
- Canonical DB: `research/telemetry/perf_history.sqlite`
- Append history: `research/telemetry/perf_history.jsonl`
- Visual artifact manifest (JSONL): `reports/performance/runs/<run_id>/visual_artifacts.jsonl`

Visual artifact pipeline options:

- `--emit-visual-artifacts/--no-emit-visual-artifacts`
- `--artifact-root <path>` to control generated visual files root

Run schema includes:

- `summary.total_visual_cases`
- `summary.failed_visual_cases`
- `summary.baseline_gate_active`
- `summary.baseline_warning`
- `visual_artifacts[]` records with:
  - `run_id`, `scenario`, `frame`
  - `image_path`, `diff_path`
  - `ssim`, `psnr`, `diff_ratio`, `pass`

Baseline warn-then-gate controls:

- `--warn-then-gate/--no-warn-then-gate`
- `--baseline-min-samples <int>`
- `--baseline-warning-delta-pct <float>`
- `--baseline-warning-vs-p95-multiplier <float>`
- `--max-failed-visual-cases <int>` hard gate for visual diffs (`-1` disables)

## 3) Optional DuckDB/Postgres mirrors

DuckDB mirror:

```powershell
python tool/performance/run_performance_pipeline.py `
  --profile investigative `
  --duckdb-path research/telemetry/perf_history.duckdb
```

Postgres mirror:

```powershell
python tool/performance/run_performance_pipeline.py `
  --profile investigative `
  --postgres-dsn "postgresql://user:pass@localhost:5432/particle_perf"
```

## 4) OTLP export (Grafana/LGTM)

Install extras:

```powershell
pip install -r tool/performance/requirements.txt
```

Export a run into OTLP manually:

```powershell
python tool/performance/export_otlp.py `
  --run-json reports/performance/runs/<run_id>/run.json
```

Or use automatic export from pipeline:

```powershell
python tool/performance/run_performance_pipeline.py `
  --profile pr `
  --export-otlp
```

The exporter honors standard OTEL environment variables, including:

- `OTEL_EXPORTER_OTLP_ENDPOINT` (default `http://localhost:4318`)
- `OTEL_EXPORTER_OTLP_HEADERS` (for managed endpoints)

## Data model

SQLite tables:

- `perf_runs` (run-level metadata and summary)
- `perf_test_cases` (per-test outcomes/durations)
- `perf_scenarios` (scenario metrics emitted from perf/soak tests)

Run schema contract:

- `schema_version`
- `profile`
- summary fields: `total_tests`, `failed_tests`, `failed_cases`, `failed_targets`, `timed_out_targets`, `telemetry_complete`, `duration_ms`

Telemetry completeness contract:

- `pr` profile requires suites: `game_loop`, `physics_integrity`, `atmospherics`
- `nightly` profile requires suites: `game_loop`, `physics_integrity`, `physics_fuzz`, `engine_soak`, `visual_regression`, `atmospherics`
- `investigative` profile requires suites: `game_loop`, `physics_integrity`, `physics_fuzz`, `visual_regression`, `atmospherics`

## Android investigative lane

For runtime validation on emulator/device (camera input mapping, ant gravity, runtime smoke metrics):

```powershell
.\tool\performance\run_android_investigative_lane.ps1 -TargetTimeoutSeconds 180
```

Artifacts added to run directory:

- `android_integration.log`
- `android_runtime_metrics.jsonl`
- `android_lane_summary.json`

Innovations included:

- Scenario DSL for composable world setup in tests (`test/helpers/scenario_dsl.dart`).
- Property-fuzz scenario sweep (`test/performance/simulation/scenario_property_fuzz_test.dart`).
- Dirty-chunk integrity/decay regression checks (`test/performance/simulation/dirty_chunk_integrity_test.dart`).
- Behavior signature metrics for robust regression comparisons (`test/helpers/behavior_signature.dart`).

This enables commit-to-commit comparison and trend analysis without requiring cloud services.
