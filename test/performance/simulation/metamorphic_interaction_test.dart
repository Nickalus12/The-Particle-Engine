@Tags(<String>['performance', 'performance_gate'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/element_behaviors.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/reactions/reaction_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

import '../../helpers/behavior_signature.dart';
import '../../helpers/perf_reporter.dart';
import '../../helpers/scenario_dsl.dart';

SimulationEngine _engine({required int seed}) {
  ElementRegistry.init();
  ReactionRegistry.init();
  return SimulationEngine(gridW: 96, gridH: 64, seed: seed);
}

void _step(SimulationEngine e, int ticks) {
  for (int i = 0; i < ticks; i++) {
    e.step(simulateElement);
  }
}

Future<void> _metric(String scenario, Map<String, num> metrics) {
  return PerfReporter.instance.record(
    suite: 'physics_integrity',
    scenario: scenario,
    metrics: metrics,
  );
}

void main() {
  test('metamorphic invariance under horizontal wrap transform', () async {
    final a = _engine(seed: 1101);
    final b = _engine(seed: 1101);

    ScenarioLibrary.pressureLock().apply(a);

    final shifted = ScenarioSpec(
      width: 96,
      height: 64,
      operations: <ScenarioOperation>[
        ScenarioOperation.fillRect(
          element: El.stone,
          x0: 12,
          y0: 58,
          x1: 95,
          y1: 63,
        ),
        ScenarioOperation.fillRect(
          element: El.stone,
          x0: 22,
          y0: 18,
          x1: 24,
          y1: 57,
        ),
        ScenarioOperation.fillRect(
          element: El.stone,
          x0: 83,
          y0: 18,
          x1: 85,
          y1: 57,
        ),
        ScenarioOperation.fillRect(
          element: El.water,
          x0: 25,
          y0: 8,
          x1: 82,
          y1: 39,
        ),
      ],
    );
    shifted.apply(b);

    _step(a, 240);
    _step(b, 240);

    final sa = captureBehaviorSignature(a);
    final sb = captureBehaviorSignature(b);

    expect((sa.hydroCells - sb.hydroCells).abs(), lessThanOrEqualTo(500));
    expect((sa.cloudCells - sb.cloudCells).abs(), lessThanOrEqualTo(300));
    expect((sa.avgMoisture - sb.avgMoisture).abs(), lessThanOrEqualTo(12.0));

    await _metric('metamorphic_wrap_invariance', <String, num>{
      'hydro_delta_abs': (sa.hydroCells - sb.hydroCells).abs(),
      'cloud_delta_abs': (sa.cloudCells - sb.cloudCells).abs(),
      'avg_moisture_delta': (sa.avgMoisture - sb.avgMoisture).abs(),
    });
  });
}
