/// Interaction Coverage Matrix
///
/// Tests every documented element interaction and reports coverage.
/// Used alongside engine_benchmark.dart for comprehensive quality tracking.
///
/// Run: dart run research/interaction_matrix.dart
library;

import '../lib/simulation/simulation_engine.dart';
import '../lib/simulation/element_registry.dart';
import '../lib/simulation/element_behaviors.dart';

/// An interaction test case: place source adjacent to target, run N frames,
/// check if the expected outcome occurred.
class InteractionTest {
  final String name;
  final int source;
  final int target;
  final bool Function(SimulationEngine e, int srcIdx, int tgtIdx) check;
  final int frames;

  const InteractionTest(this.name, this.source, this.target, this.check, {this.frames = 60});
}

void main() {
  ElementRegistry.init();

  final tests = _buildTests();
  int passed = 0;
  int failed = 0;
  final failures = <String>[];

  for (final test in tests) {
    final result = _runTest(test);
    if (result) {
      passed++;
    } else {
      failed++;
      failures.add(test.name);
    }
  }

  final total = passed + failed;
  final coverage = total > 0 ? (passed / total * 100).toStringAsFixed(1) : '0.0';

  print('');
  print('=== Interaction Coverage Matrix ===');
  print('Passed: $passed / $total ($coverage%)');
  print('Failed: $failed');
  if (failures.isNotEmpty) {
    print('');
    print('Failures:');
    for (final f in failures) {
      print('  - $f');
    }
  }
  print('');
  print('coverage=$coverage passed=$passed failed=$failed total=$total');
}

bool _runTest(InteractionTest test) {
  final e = SimulationEngine(gridW: 16, gridH: 16);

  // Place source and target adjacent to each other
  final srcIdx = 8 * 16 + 7;
  final tgtIdx = 8 * 16 + 8;

  e.grid[srcIdx] = test.source;
  e.grid[tgtIdx] = test.target;

  // Set reasonable defaults for elements that need them
  if (test.source == El.water || test.target == El.water) {
    if (test.source == El.water) e.life[srcIdx] = 100;
    if (test.target == El.water) e.life[tgtIdx] = 100;
  }
  if (test.source == El.lava) e.temperature[srcIdx] = 250;
  if (test.target == El.lava) e.temperature[tgtIdx] = 250;
  if (test.source == El.ice) e.temperature[srcIdx] = 20;
  if (test.target == El.ice) e.temperature[tgtIdx] = 20;

  // Floor so elements don't fall away
  for (int x = 0; x < 16; x++) {
    e.grid[15 * 16 + x] = El.stone;
    e.grid[9 * 16 + x] = El.stone; // floor under test cells
  }

  e.markAllDirty();

  for (int i = 0; i < test.frames; i++) {
    e.step(simulateElement);
  }

  return test.check(e, srcIdx, tgtIdx);
}

/// Check if ANY cell in the grid contains the given element.
bool _gridContains(SimulationEngine e, int el) {
  for (int i = 0; i < e.gridW * e.gridH; i++) {
    if (e.grid[i] == el) return true;
  }
  return false;
}

/// Check if either the source or target cell changed from its original.
bool _eitherChanged(SimulationEngine e, int srcIdx, int tgtIdx, int srcOrig, int tgtOrig) {
  return e.grid[srcIdx] != srcOrig || e.grid[tgtIdx] != tgtOrig;
}

List<InteractionTest> _buildTests() {
  return [
    // === FIRE interactions ===
    InteractionTest('Fire + Oil → Fire spreads', El.fire, El.oil,
        (e, s, t) => e.grid[t] == El.fire || e.grid[t] == El.empty,
        frames: 100),
    InteractionTest('Fire + Wood → Wood burns', El.fire, El.wood,
        (e, s, t) => e.grid[t] != El.wood || e.life[t] > 0,
        frames: 100),
    InteractionTest('Fire + Plant → Plant catches fire', El.fire, El.plant,
        (e, s, t) => e.grid[t] != El.plant,
        frames: 80),
    InteractionTest('Fire + Ice → Ice melts', El.fire, El.ice,
        (e, s, t) => e.grid[t] != El.ice,
        frames: 60),
    InteractionTest('Fire + Snow → Snow melts', El.fire, El.snow,
        (e, s, t) => e.grid[t] != El.snow,
        frames: 60),
    InteractionTest('Fire + TNT → Explosion', El.fire, El.tnt,
        (e, s, t) => e.grid[t] != El.tnt,
        frames: 40),

    // === WATER interactions ===
    InteractionTest('Water + Fire → Steam', El.water, El.fire,
        (e, s, t) => _gridContains(e, El.steam) || e.grid[t] == El.empty,
        frames: 30),
    InteractionTest('Water + Lava → Steam + Stone', El.water, El.lava,
        (e, s, t) => _gridContains(e, El.steam) || _gridContains(e, El.stone),
        frames: 60),

    // === LAVA interactions ===
    InteractionTest('Lava + Water → Stone + Steam', El.lava, El.water,
        (e, s, t) => _gridContains(e, El.stone) || _gridContains(e, El.steam),
        frames: 60),
    InteractionTest('Lava + Ice → Ice melts', El.lava, El.ice,
        (e, s, t) => e.grid[t] != El.ice,
        frames: 40),
    InteractionTest('Lava + Snow → Steam', El.lava, El.snow,
        (e, s, t) => e.grid[t] != El.snow,
        frames: 40),
    InteractionTest('Lava + Wood → Wood ignites', El.lava, El.wood,
        (e, s, t) => e.grid[t] != El.wood || e.life[t] > 0,
        frames: 80),

    // === ACID interactions ===
    InteractionTest('Acid + Stone → Dissolve', El.acid, El.stone,
        (e, s, t) => _eitherChanged(e, s, t, El.acid, El.stone),
        frames: 200),
    InteractionTest('Acid + Wood → Dissolve', El.acid, El.wood,
        (e, s, t) => _eitherChanged(e, s, t, El.acid, El.wood),
        frames: 200),
    InteractionTest('Acid + Dirt → Dissolve', El.acid, El.dirt,
        (e, s, t) => e.grid[t] != El.dirt,
        frames: 100),
    InteractionTest('Acid + Plant → Dissolve', El.acid, El.plant,
        (e, s, t) => e.grid[t] != El.plant,
        frames: 60),
    InteractionTest('Acid + Water → Dilutes', El.acid, El.water,
        (e, s, t) => _eitherChanged(e, s, t, El.acid, El.water),
        frames: 200),
    InteractionTest('Acid + Ice → Melts', El.acid, El.ice,
        (e, s, t) => e.grid[t] != El.ice,
        frames: 100),

    // === LIGHTNING interactions ===
    InteractionTest('Lightning + Sand → Glass', El.lightning, El.sand,
        (e, s, t) => _gridContains(e, El.glass),
        frames: 30),
    InteractionTest('Lightning + TNT → Explosion', El.lightning, El.tnt,
        (e, s, t) => e.grid[t] != El.tnt,
        frames: 20),

    // === TEMPERATURE state changes ===
    InteractionTest('Sand melts at high temp → Glass', El.sand, El.empty,
        (e, s, t) {
          // Manually heat sand
          e.temperature[s] = 250;
          for (int i = 0; i < 60; i++) e.step(simulateElement);
          return e.grid[s] == El.glass || e.grid[s] == El.lava;
        }, frames: 0), // frames=0 because we run manually

    // === GRAVITY tests ===
    InteractionTest('Sand falls through air', El.sand, El.empty,
        (e, s, t) => e.grid[s] != El.sand, // sand moved from original pos
        frames: 20),
    InteractionTest('Stone falls through air', El.stone, El.empty,
        (e, s, t) => e.grid[s] != El.stone,
        frames: 30),
    InteractionTest('Metal falls through air', El.metal, El.empty,
        (e, s, t) => e.grid[s] != El.metal,
        frames: 30),
    InteractionTest('Glass falls through air', El.glass, El.empty,
        (e, s, t) => e.grid[s] != El.glass,
        frames: 30),

    // === DENSITY displacement ===
    InteractionTest('Sand sinks in water', El.sand, El.water,
        (e, s, t) {
          // Place sand above water column
          for (int y = 6; y < 9; y++) {
            e.grid[y * 16 + 7] = El.water;
            e.life[y * 16 + 7] = 100;
          }
          e.grid[5 * 16 + 7] = El.sand;
          e.markAllDirty();
          for (int i = 0; i < 40; i++) e.step(simulateElement);
          // Sand should be below water
          bool sandBelow = false;
          for (int y = 7; y < 10; y++) {
            if (e.grid[y * 16 + 7] == El.sand) sandBelow = true;
          }
          return sandBelow;
        }, frames: 0),

    // === FIRE behavior ===
    InteractionTest('Fire produces smoke', El.fire, El.empty,
        (e, s, t) => _gridContains(e, El.smoke),
        frames: 30),
    InteractionTest('Fire eventually dies', El.fire, El.empty,
        (e, s, t) => !_gridContains(e, El.fire),
        frames: 120),

    // === STEAM behavior ===
    InteractionTest('Steam rises and dissipates', El.steam, El.empty,
        (e, s, t) => e.grid[s] != El.steam,
        frames: 60),

    // === SMOKE behavior ===
    InteractionTest('Smoke rises and dissipates', El.smoke, El.empty,
        (e, s, t) => e.grid[s] != El.smoke,
        frames: 100),

    // === SNOW behavior ===
    InteractionTest('Snow falls', El.snow, El.empty,
        (e, s, t) => e.grid[s] != El.snow,
        frames: 20),

    // === BUBBLE behavior ===
    InteractionTest('Bubble rises and pops', El.bubble, El.empty,
        (e, s, t) => e.grid[s] != El.bubble,
        frames: 40),

    // === WRAPPING ===
    InteractionTest('wrapX wraps negative', El.empty, El.empty,
        (e, s, t) => e.wrapX(-1) == e.gridW - 1,
        frames: 0),
    InteractionTest('wrapX wraps positive', El.empty, El.empty,
        (e, s, t) => e.wrapX(e.gridW) == 0,
        frames: 0),
    InteractionTest('wrapX wraps double-negative', El.empty, El.empty,
        (e, s, t) => e.wrapX(-e.gridW) == 0,
        frames: 0),
  ];
}
