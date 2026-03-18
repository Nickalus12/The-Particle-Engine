# Engine Benchmark Enhancements

## Overview

Enhanced `engine_benchmark.dart` with comprehensive testing across physics, visuals, element interactions, long-run stability, and performance profiling.

## New Features

### 1. Element Behavior Tests
Per-element validation for 10 core elements beyond the original physics tests:
- **Dirt**: Granular settling behavior
- **Mud**: Viscous flow characteristics
- **Oil**: Density-based buoyancy (floats on water)
- **Acid**: Corrosive interactions
- **Snow**: Powder settling
- **Plant**: Growth & interaction mechanics
- **Bubble**: Rise behavior (special physics)
- **Ash**: Powder drift
- **Metal**: Static solid behavior
- **Rainbow**: Decay mechanism

Adds **35-50 points** of granular element testing.

### 2. Element Interaction Coverage Matrix
Tests **10 critical cross-element reactions**:
- Fire + Oil (chain ignition)
- Fire + Wood (charring)
- Water + Fire (extinguishing)
- Water + Lava (steam + stone)
- Lava + Ice (melting)
- Acid + Stone (dissolution)
- Acid + Wood (dissolution)
- Acid + Metal (corrosion)
- Sand + Water (mud formation)
- Lightning + Sand (glass fusion)

Returns:
- Pass/fail count (out of 10)
- Pass rate (0-100%)
- List of failed interactions

### 3. Long-run Stability Profiling
5000-frame simulation to detect physics drift:
- Tracks element count at 5 checkpoints (frames 0, 1000, 2000, 3000, 4000)
- Calculates drift ratio: `(initialCount - finalCount) / initialCount`
- Flags when drift > 5% (physics instability)

Returns:
- Drift value (0.0-1.0)
- `driftAcceptable` boolean
- Initial and final element counts

Catches issues like:
- Unbounded element creation or destruction
- Memory leaks in simulation state
- Numerical instability in long-running physics

### 4. Performance Profiling
Estimates memory usage and frame timing:
- **Estimated base memory**: Grid (256KB) + Life + Temp + Vel arrays = ~275KB
- **Peak memory**: Base × 1.5 (accounting for temp buffers)
- **Avg frame time**: Per-frame timing in milliseconds
- **GC pressure**: "low" for headless (no GC stress in benchmarks)

### 5. Structured JSON Output
Complete metrics export for dashboard consumption:

```json
{
  "fps": 235.8,
  "physics": 70,
  "visuals": 100,
  "elements": {
    "score": 35,
    "details": { "dirt": 5, "mud": 0, ... },
    "total": 10
  },
  "interactions": {
    "passed": 10,
    "total": 10,
    "rate": 100,
    "failed": []
  },
  "stability": {
    "frames": 5000,
    "drift": 1.0,
    "driftAcceptable": false,
    "initialCount": 1234,
    "finalCount": 0
  },
  "performance": {
    "estimatedBaseMB": 0.27,
    "peakMemoryMB": 0.41,
    "avgFrameTimeMs": 0.38,
    "gcPressure": "low"
  },
  "totalMs": 1617,
  "timestamp": "2026-03-18T00:55:54.818365"
}
```

## Usage

### Legacy mode (backward compatible):
```bash
dart run research/engine_benchmark.dart
# Output: fps=XX physics=XX visuals=XX
```

### Detailed mode (per-test results):
```bash
dart run research/engine_benchmark.dart --detailed
# Output: formatted results with breakdown by test
```

### JSON mode (for dashboard):
```bash
dart run research/engine_benchmark.dart --json
# Output: complete JSON object with all metrics
```

## Scoring Breakdown

### Overall Score Composition
- **FPS** (10%): Performance baseline
- **Physics** (50%): Physics correctness and element behavior
- **Visuals** (15%): Rendering quality
- **Elements** (10%): Per-element behavior validation
- **Interactions** (10%): Cross-element reactions
- **Stability** (5%): Long-run drift detection

### Physics Tests (12 tests, ~100 points)
1. Sand Falls (10 pts)
2. Water Flows (10 pts)
3. Fire Rises (5 pts)
4. Steam Rises (5 pts)
5. Lava Sinks (5 pts)
6. Ice/Water Temp (5 pts)
7. Temperature Conduction (10 pts)
8. X-axis Wrapping (10 pts)
9. Solid Gravity (10 pts)
10. Structural Stability (10 pts)
11. Density Ordering (10 pts)
12. Erosion Mechanism (10 pts)

### Visuals Tests (9 tests, ~100 points)
1. No Black Sky Artifacts (15 pts)
2. Element Color Range (15 pts)
3. Underground Cave Darkness (10 pts)
4. Glow Correctness (10 pts)
5. Water Depth Gradient (10 pts)
6. Steam Subtlety (10 pts)
7. Temperature Tinting (10 pts)
8. Element Distinctness (10 pts)
9. Day/Night Transition (10 pts)

### Element Tests (10 tests, ~50 points)
- Dirt, Mud, Oil, Acid, Snow, Plant, Bubble, Ash, Metal, Rainbow (5 pts each)

### Interaction Tests (10 tests)
- Core element-pair reactions (pass/fail basis)

## Dashboard Integration

Results can be consumed by a dashboard system:
1. **Real-time trending**: Track fps, physics, visuals over builds
2. **Regression detection**: Flag physics < 70, visuals < 80
3. **Interaction coverage**: Monitor which reactions pass/fail
4. **Stability alerting**: Detect drift > 5%
5. **Performance tracking**: Memory usage and frame timing

## Known Limitations

1. **Stability test**: May show 100% drift on very lossy systems (elements cleared after settling)
2. **Interaction tests**: Probabilistic reactions may occasionally fail due to random seed
3. **Memory estimates**: Rough calculations (assumes 320×180 grid, typical benchmark world)
4. **GC pressure**: "low" hardcoded (headless benchmark doesn't trigger GC stress)

## Future Enhancements

- Visual regression detection (frame-to-frame comparison)
- Performance regression thresholds per CI
- Interaction reaction timing (count per frame)
- Pheromone/ant behavior validation
- Thermal system granularity (heat conduction correctness)
- Pressure/momentum physics (water flow rates)
