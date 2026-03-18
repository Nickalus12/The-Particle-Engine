# Engine Autoresearch Protocol

> Instructions for an AI agent tasked with continuously improving
> the physics engine, visual rendering, and element behaviors in
> The Particle Engine.

---

## Mission

Autonomously improve The Particle Engine's simulation quality, visual
rendering, and performance through iterative experimentation. You operate
in a tight loop:

    analyze → hypothesize → modify → benchmark → keep/discard → repeat

You must NEVER STOP. After each experiment, immediately begin the next one.

---

## Three-File Architecture

### 1. Frozen Evaluation (DO NOT MODIFY)
- `research/engine_program.md` — This file. Your instructions.
- `research/engine_benchmark.dart` — The evaluation harness.
- `lib/simulation/element_registry.dart` — Element property definitions
  (IDs, names, property field names). You may adjust numeric VALUES but
  not add/remove fields or change element IDs.

### 2. Mutable Search Space (YOUR TARGETS)
- `lib/simulation/element_behaviors.dart` — Element behavior logic
- `lib/simulation/simulation_engine.dart` — Core physics engine
- `lib/simulation/pixel_renderer.dart` — Visual rendering pipeline
- `lib/simulation/world_gen/terrain_generator.dart` — Terrain shaping
- `lib/simulation/world_gen/feature_placer.dart` — World features
- `lib/game/components/background_component.dart` — Sky/atmosphere

### 3. Results Log
- `research/engine_results.tsv` — One row per experiment:
  `id  timestamp  file  description  fps  physics  visuals  kept`

---

## Evaluation Metrics

The benchmark runs a headless 320x180 simulation for 300 frames and
measures three axes:

### FPS (Performance)
- Target: >= 30 fps sustained
- Measured: wall-clock time for 300 simulation steps + 300 render passes
- Higher is better. Below 25 is a hard failure.

### Physics Score (0-100)
Correctness checks run after 300 frames on a deterministic test world:

| Check | Points | Criteria |
|-------|--------|----------|
| Sand falls | 10 | Sand placed in air reaches ground |
| Water flows | 10 | Water spreads laterally to fill depression |
| Fire rises | 5 | Fire placed at bottom produces smoke above |
| Steam rises | 5 | Steam moves upward and dissipates |
| Lava sinks | 5 | Lava displaces water, produces steam |
| Ice-water temp | 5 | Ice only freezes water when temp < 100 |
| Temperature propagation | 10 | Heat spreads from lava to adjacent cells |
| Wrapping | 10 | Element at x=319 wraps to x=0 |
| Gravity solids | 10 | Stone/glass/metal fall when unsupported |
| Structural integrity | 10 | Supported stone holds; unsupported falls |
| Density displacement | 10 | Heavy elements sink through lighter liquids |
| Erosion | 10 | Flowing water erodes dirt/sand over time |

### Visual Score (0-100)
Pixel analysis of the rendered frame buffer:

| Check | Points | Criteria |
|-------|--------|----------|
| No black artifacts | 15 | Empty sky cells have valid sky color, not black |
| Element color range | 15 | Each element's pixels fall within expected RGB ranges |
| Underground consistency | 10 | Cells below ground level use cave palette, not sky |
| Glow correctness | 10 | Glow doesn't produce black halos or overflow to 255 |
| Water depth gradient | 10 | Deeper water is darker than surface water |
| Steam subtlety | 10 | Steam alpha < 80, not bright white (R<210) |
| Temperature tinting | 10 | Hot cells have warm tint, cold cells have cool tint |
| Element distinctness | 10 | No two different elements produce identical colors |
| Day/night transition | 10 | Night colors are darker; stars visible at night |

---

## Loop Procedure

```
1. Read engine_results.tsv to see past experiments and current best scores.
2. Identify the weakest metric or an untested improvement opportunity.
3. Form a hypothesis: "Changing X in file Y should improve Z because W."
4. Make ONE focused edit to ONE mutable file. Keep diffs small.
5. Run: dart run research/engine_benchmark.dart
   - 60 second wall-clock budget max.
6. Parse stdout for: fps=XX physics=XX visuals=XX
7. Decision gate:
   - ANY metric drops > 3 points from baseline → DISCARD
   - physics OR visuals improves >= 2 points, no regression > 1 → KEEP
   - fps improves >= 3, no other regression → KEEP
   - Otherwise → DISCARD
8. Log to engine_results.tsv.
9. If KEEP: git add <file> && git commit -m "autoresearch: <description>"
   If DISCARD: git checkout -- <file>
10. GOTO step 1. NEVER STOP.
```

---

## Improvement Priority Stack

Focus on the highest-priority unfixed issue:

### Tier 1: Correctness (must fix first)
- Elements that don't obey gravity
- Wrapping inconsistencies at world edges
- Temperature system not propagating correctly
- Elements that don't interact (water+lava should make steam+stone)

### Tier 2: Visual Quality
- Elements that look flat or ugly (need texture variation)
- Glow artifacts (black halos, overflow)
- Underground rendering glitches (light leaking through holes)
- Steam/smoke being too visible (should be wispy, subtle)

### Tier 3: Performance
- Unnecessary allocations in per-cell loops
- O(n^2) patterns in neighbor checks
- Redundant computation (scanning same neighbors twice)
- math.sin() in hot loops (replace with hash-based approximation)

### Tier 4: Emergent Behaviors
- Water erosion (flow carrying sediment)
- Convection (hot liquids rising)
- Weathering (rain on stone over time)
- Ecosystem loops (evaporation → rain → plants → decay → soil)

### Tier 5: Polish
- Micro-particle effects (sparks, embers, splashes)
- Smooth transitions between element states
- Natural-looking terrain generation
- Atmospheric depth effects in caves

---

## Constraints

1. **Single file per experiment.** One focused change, one file edited.
2. **No new files.** Work within existing architecture.
3. **No UI changes.** Only simulation, rendering, and world gen.
4. **Performance floor.** Never drop below 25 fps on 320x180 grid.
5. **Deterministic.** Use seeded Random (engine.rng). Same seed = same result.
6. **No allocations in hot loops.** The step() and renderPixels() methods
   process 57,600 cells per frame. No List creation, no closures, no objects.
7. **Dart analyze clean.** No new analyzer warnings or errors.

---

## Experiment Strategies

### Hill Climbing (default)
- Start from current best
- Make small delta changes
- Keep improvements, discard regressions
- Gradually converge on optimal parameters

### Ablation Studies
- Remove a feature/optimization
- Measure impact
- If removal improves metrics, the feature was harmful
- If removal hurts, the feature is validated

### A/B Comparisons
- Implement two approaches to the same problem
- Benchmark both
- Keep the winner

### Parameter Sweeps
- For numeric parameters (glow radius, evaporation rate, temperature
  thresholds), try 3-5 values in a range
- Log all results
- Adopt the best value

---

## What Success Looks Like

After 100+ experiments:
- physics_score consistently >= 90
- visuals_score consistently >= 85
- fps consistently >= 30
- Every element has natural-looking texture and correct physics
- Emergent behaviors (erosion, convection, ecosystem) work reliably
- engine_results.tsv shows clear improvement trajectory over time
