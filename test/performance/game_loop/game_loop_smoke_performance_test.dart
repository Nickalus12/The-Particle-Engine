@Tags(<String>['performance', 'performance_gate'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/element_behaviors.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/reactions/reaction_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

import '../../helpers/perf_reporter.dart';

SimulationEngine _makeEngine() {
  ElementRegistry.init();
  ReactionRegistry.init();
  return SimulationEngine(gridW: 96, gridH: 64, seed: 4242);
}

void _seedScenario(SimulationEngine e) {
  for (int x = 0; x < e.gridW; x++) {
    final stoneY = e.gridH - 8;
    final sIdx = stoneY * e.gridW + x;
    e.grid[sIdx] = El.stone;
    e.mass[sIdx] = elementBaseMass[El.stone];
    if (x % 3 == 0) {
      final wIdx = (stoneY - 12) * e.gridW + x;
      e.grid[wIdx] = El.water;
      e.mass[wIdx] = elementBaseMass[El.water];
    }
  }
  e.markAllDirty();
}

void main() {
  test('headless loop stays within broad step budget', () async {
    final e = _makeEngine();
    _seedScenario(e);

    final sw = Stopwatch()..start();
    const frames = 180;
    for (int i = 0; i < frames; i++) {
      e.step(simulateElement);
    }
    sw.stop();

    final totalMs = sw.elapsedMicroseconds / 1000.0;
    final meanStepMs = totalMs / frames;

    expect(meanStepMs, lessThan(14.0));

    await PerfReporter.instance.record(
      suite: 'game_loop',
      scenario: 'headless_step_budget',
      metrics: <String, num>{
        'frames': frames,
        'total_ms': totalMs,
        'mean_step_ms': meanStepMs,
      },
    );
  });
}
