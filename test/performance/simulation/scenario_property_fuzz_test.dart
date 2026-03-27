@Tags(<String>['performance', 'soak'])
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/element_behaviors.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/reactions/reaction_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

import '../../helpers/behavior_signature.dart';
import '../../helpers/perf_reporter.dart';
import '../../helpers/scenario_dsl.dart';

SimulationEngine _engine(int w, int h, int seed) {
  ElementRegistry.init();
  ReactionRegistry.init();
  return SimulationEngine(gridW: w, gridH: h, seed: seed);
}

void _step(SimulationEngine e, int frames) {
  for (int i = 0; i < frames; i++) {
    e.step(simulateElement);
  }
}

ScenarioSpec _scenarioForSeed(int seed) {
  final r = Random(seed);
  final waterTop = 26 + r.nextInt(8);
  final cloudBand = 8 + r.nextInt(6);
  final lavaX = 30 + r.nextInt(30);
  return ScenarioSpec.fromMap(<String, Object?>{
    'width': 96,
    'height': 64,
    'wind_force': r.nextInt(5) - 2,
    'gravity_dir': r.nextBool() ? 1 : -1,
    'ops': <Object?>[
      <String, Object?>{
        'type': 'fill_rect',
        'el': El.stone,
        'x0': 0,
        'y0': 56,
        'x1': 95,
        'y1': 63,
      },
      <String, Object?>{
        'type': 'fill_rect',
        'el': El.water,
        'x0': 4,
        'y0': waterTop,
        'x1': 92,
        'y1': 54,
      },
      <String, Object?>{
        'type': 'fill_rect',
        'el': El.cloud,
        'x0': 12,
        'y0': cloudBand,
        'x1': 84,
        'y1': cloudBand + 3,
      },
      <String, Object?>{
        'type': 'fill_rect',
        'el': El.lava,
        'x0': lavaX,
        'y0': 52,
        'x1': lavaX + 8,
        'y1': 54,
      },
      <String, Object?>{
        'type': 'sprinkle',
        'el': El.vapor,
        'x0': 6,
        'y0': 6,
        'x1': 90,
        'y1': 22,
        'chance': 18,
      },
    ],
  });
}

Future<void> _record(String scenario, Map<String, num> metrics) {
  return PerfReporter.instance.record(
    suite: 'physics_fuzz',
    scenario: scenario,
    metrics: metrics,
  );
}

int _countAny(SimulationEngine e, Set<int> els) {
  int c = 0;
  for (int i = 0; i < e.grid.length; i++) {
    if (els.contains(e.grid[i])) c++;
  }
  return c;
}

void main() {
  group('Scenario Property Fuzz', () {
    test('fuzzed scenarios preserve invariants and bounded signatures', () async {
      const hydro = <int>{
        El.water,
        El.vapor,
        El.cloud,
        El.steam,
        El.ice,
        El.snow,
        El.bubble,
      };
      const seeds = <int>[410, 411, 412, 413, 414];
      int violations = 0;
      int hydroDrift = 0;
      int maxCloudCluster = 0;
      int signatureXor = 0;

      for (final seed in seeds) {
        final scenario = _scenarioForSeed(seed);
        final e = _engine(scenario.width, scenario.height, seed);
        scenario.apply(e, random: Random(seed));
        final initialHydro = _countAny(e, hydro);
        _step(e, 320);
        final finalHydro = _countAny(e, hydro);
        hydroDrift += (finalHydro - initialHydro).abs();

        final sig = captureBehaviorSignature(e);
        if (sig.maxCloudCluster > maxCloudCluster) {
          maxCloudCluster = sig.maxCloudCluster;
        }
        signatureXor ^= sig.gridHash;

        if (sig.lavaCells > (e.gridW * e.gridH) ~/ 4) violations++;
        if (sig.cloudCells > 2200) violations++;
        if (sig.hydroCells > (e.gridW * e.gridH * 3) ~/ 4) violations++;
      }

      expect(violations, equals(0));
      expect(hydroDrift, lessThan(3000));

      await _record('fuzz_invariant_sweep', <String, num>{
        'seed_count': seeds.length,
        'violations': violations,
        'hydro_abs_drift_total': hydroDrift,
        'max_cloud_cluster': maxCloudCluster,
        'signature_xor': signatureXor,
      });
    });
  });
}
