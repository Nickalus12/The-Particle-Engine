# Engine Autoresearch Protocol v4

> Autonomous AI agent improving the physics engine, visual rendering,
> and element behaviors in The Particle Engine using pytest-validated
> experiments against scipy/scikit-image ground truth.

---

## Mission

Make The Particle Engine's simulation physically accurate, visually
stunning, and performant. You THINK DEEPLY, RESEARCH REAL PHYSICS,
IMPLEMENT CAREFULLY, and VALIDATE with pytest.

You must NEVER STOP. After each experiment, immediately begin the next.

---

## Core Philosophy

You are NOT a line-tweaker. Each experiment should be a meaningful,
well-reasoned improvement — not a trivial parameter nudge.

Before changing ANY code:
1. **READ** the relevant source files completely
2. **UNDERSTAND** why the current code works the way it does
3. **RESEARCH** the real physics you're trying to approximate
4. **PLAN** a coherent change (20-200 lines)
5. **IMPLEMENT** the full solution
6. **VALIDATE** invariants hold
7. **TEST** with pytest — the ONLY evaluation tool

---

## Architecture

### Frozen (NEVER MODIFY)
- `research/engine_program.md` — This file
- `research/ground_truth.json` — scipy oracle output
- `research/visual_ground_truth.json` — colour-science oracle output

### Test Suite (ADD tests only, NEVER weaken or remove)
- `research/tests/test_kinematics.py` — Gravity, trajectory, terminal velocity
- `research/tests/test_fluid_dynamics.py` — Torricelli, viscosity, flow
- `research/tests/test_fluid_statics.py` — Pascal, buoyancy, U-tube
- `research/tests/test_thermodynamics.py` — Fourier, Newton cooling
- `research/tests/test_phase_changes.py` — Melt/boil/freeze transitions
- `research/tests/test_granular.py` — Angle of repose, hourglass
- `research/tests/test_combustion.py` — Fire triangle, spread rate
- `research/tests/test_reactions.py` — All 36+ reactions
- `research/tests/test_structural.py` — Cantilever, arch, cascade
- `research/tests/test_conservation.py` — Mass, energy, momentum
- `research/tests/test_erosion.py` — Erosion, weathering
- `research/tests/test_ecosystem.py` — Water cycle, plants
- `research/tests/test_visuals.py` — CIE 2000 Delta E color science
- `research/tests/test_visual_quality.py` — Texture, gradients, edges

### Oracles (regenerate when needed)
- `research/physics_oracle.py` — scipy/numpy ground truth
- `research/visual_oracle.py` — scikit-image/colour-science ground truth

### Mutable Simulation Files (YOUR TARGETS)
- `lib/simulation/element_behaviors.dart` — Element behavior logic
- `lib/simulation/simulation_engine.dart` — Core physics engine
- `lib/simulation/pixel_renderer.dart` — Visual rendering pipeline
- `lib/simulation/element_registry.dart` — Element property VALUES only
- `lib/simulation/world_gen/terrain_generator.dart` — Terrain
- `lib/simulation/world_gen/feature_placer.dart` — Features
- `lib/game/components/background_component.dart` — Sky/atmosphere

### Results
- `research/engine_results.tsv` — Experiment log

---

## Invariant Rules (AUTOMATIC DISCARD if violated)

### 1. Universal Gravity
Every non-gas element MUST have gravity. Solids call `fallSolid()`.
Granulars call `fallGranular()`. Structural integrity via lateral
support — NEVER remove gravity.

### 2. Element Identity
Each element keeps its fundamental nature (granular/liquid/gas/solid).

### 3. Interaction Preservation
Never remove working interactions. Only ADD or IMPROVE.

### 4. Conservation Laws
Mass drift < 5% over 1000 frames in non-reactive systems.

### 5. Performance Floor
Never below 25 fps on 320x180 grid.

### 6. No Hot-Loop Allocations
No List/Map/closure/object creation inside per-cell loops.

---

## Experiment Workflow

### Phase 1: ANALYZE
Run pytest to find failing tests:
```bash
python -m pytest research/tests/ -v --tb=short 2>&1 | tail -30
```
Identify the weakest category. Read the relevant simulation code.

### Phase 2: RESEARCH
Look up the real physics for the weakness. Consult ground_truth.json
for scipy-computed expected values.

### Phase 3: IMPLEMENT
Write 20-200 lines of coherent improvement in ONE simulation file.

### Phase 4: VALIDATE
```bash
# Gravity check
grep -c "fallSolid" lib/simulation/element_behaviors.dart

# Dart analyze
dart analyze --no-fatal-infos lib/
```
If ANY invariant fails → DISCARD immediately.

### Phase 5: TEST (pytest is the ONLY evaluation)
```bash
# Run full test suite
python -m pytest research/tests/ -v --tb=short

# Or specific category
python -m pytest research/tests/test_phase_changes.py -v
```

Parse output: count passed/failed/skipped.

### Phase 6: DECIDE

**AUTOMATIC DISCARD:**
- Any invariant violation
- More tests fail than before the change
- Any previously-passing test now fails
- dart analyze has new errors

**KEEP (requires ALL):**
- All invariants pass
- At least ONE previously-failing test now passes
- No previously-passing test regressed to failing
- Net test pass count increased

**NEUTRAL:** Same pass count, no regressions → log as "neutral"

### Phase 7: LOG & COMMIT

Append to `research/engine_results.tsv`:
```
id  timestamp  file  description  passed  failed  skipped  total  kept
```

If KEEP: `git add <file> && git commit -m "autoresearch: <description>"`
If DISCARD: `git checkout -- <file>`

GOTO Phase 1. NEVER STOP.

---

## Targeting Strategy

Run pytest and sort failures by category:
```bash
python -m pytest research/tests/ -v --tb=line 2>&1 | grep FAILED
```

Priority order:
1. Tests with 0% pass rate (complete failures)
2. Categories with lowest pass rate
3. Tests closest to passing (small deviation from expected)

---

## What Makes a GOOD Experiment

**Example: Fixing phase change tests**

Phase 1: `pytest test_phase_changes.py` shows sand doesn't melt near lava.
Phase 2: Research — sand melts at ~1700°C, our meltPoint=248 on 0-255 scale.
Phase 3: Check if temperature near lava actually reaches 248. Find that
radiant heat only warms to ~200. Either lower sand meltPoint or increase
lava radiant heat output.
Phase 4: Validate gravity still present, dart analyze clean.
Phase 5: Run pytest — sand melting test now passes. No regressions.
Phase 6: Net +1 passing test → KEEP.

---

## What Makes a BAD Experiment

- Changing 1 number without understanding why
- Removing gravity to pass a structural test
- Modifying test expectations to match broken simulation
- Making changes that break previously-passing tests

---

## Real Physics Reference

| Simulation | Real World |
|-----------|-----------|
| 1 cell | ~1 cm |
| 1 frame | ~33ms (30fps) |
| temperature 0-255 | ~-50°C to 2000°C |
| density 0-255 | ~0-8000 kg/m³ |

| Material | Real Density | Engine Density |
|----------|-------------|----------------|
| Metal | 7800 kg/m³ | 240 (should be highest) |
| Stone | 2700 kg/m³ | 255 |
| Water | 1000 kg/m³ | 100 |
| Wood | 600 kg/m³ | 85 |
| Ice | 917 kg/m³ | 90 |

---

## Success Milestones

| Phase | Passed | Target |
|-------|--------|--------|
| Start | ~550/600 | Baseline |
| 10 experiments | +20 passes | Fix 0% failures |
| 25 experiments | +40 passes | All categories > 70% |
| 50 experiments | +50 passes | All categories > 85% |
| 100 experiments | 595+/600 | Near-perfect physics |
