@Tags(<String>['performance', 'performance_gate'])
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/element_behaviors.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/reactions/reaction_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

import '../../helpers/behavior_signature.dart';
import '../../helpers/perf_reporter.dart';

SimulationEngine _engine({int w = 96, int h = 64, int seed = 1}) {
  ElementRegistry.init();
  ReactionRegistry.init();
  return SimulationEngine(gridW: w, gridH: h, seed: seed);
}

void _place(SimulationEngine e, int x, int y, int el) {
  final idx = y * e.gridW + x;
  e.clearCell(idx);
  e.grid[idx] = el;
  e.mass[idx] = elementBaseMass[el];
  e.flags[idx] = e.simClock ? 0 : 0x80;
  e.markDirty(x, y);
  e.unsettleNeighbors(x, y);
}

void _step(SimulationEngine e, int frames) {
  for (int i = 0; i < frames; i++) {
    e.step(simulateElement);
  }
}

int _count(SimulationEngine e, Set<int> elements) {
  int c = 0;
  for (int i = 0; i < e.grid.length; i++) {
    if (elements.contains(e.grid[i])) c++;
  }
  return c;
}

int _signature(SimulationEngine e) {
  int h = 0x811C9DC5;
  for (int i = 0; i < e.grid.length; i++) {
    h ^= e.grid[i];
    h = (h * 0x01000193) & 0x7fffffff;
    h ^= e.moisture[i];
    h = (h * 0x01000193) & 0x7fffffff;
    h ^= e.stress[i];
    h = (h * 0x01000193) & 0x7fffffff;
  }
  h ^= e.frameCount;
  return h & 0x7fffffff;
}

void _seedMixedField(SimulationEngine e, int seed) {
  final r = Random(seed);
  final palette = <int>[
    El.water,
    El.vapor,
    El.cloud,
    El.ice,
    El.snow,
    El.lava,
    El.stone,
    El.dirt,
    El.sand,
  ];
  for (int y = 5; y < e.gridH - 5; y++) {
    for (int x = 0; x < e.gridW; x++) {
      if (r.nextInt(100) < 10) {
        _place(e, x, y, palette[r.nextInt(palette.length)]);
      }
    }
  }
  e.markAllDirty();
}

Future<void> _metric(
  String scenario,
  Map<String, num> metrics, {
  Map<String, Object?> tags = const <String, Object?>{},
}) {
  return PerfReporter.instance.record(
    suite: 'physics_integrity',
    scenario: scenario,
    metrics: metrics,
    tags: tags,
  );
}

void main() {
  group('Physics Integrity', () {
    test(
      'hydrologic and lava totals stay bounded across deterministic seeds',
      () async {
        final hydro = <int>{
          El.water,
          El.vapor,
          El.cloud,
          El.steam,
          El.ice,
          El.snow,
          El.bubble,
        };
        int totalHydroDelta = 0;
        int maxLava = 0;
        const seeds = <int>[101, 102, 103, 104];
        for (final seed in seeds) {
          final e = _engine(seed: seed);
          _seedMixedField(e, seed * 17);
          final initialHydro = _count(e, hydro);
          _step(e, 360);
          final finalHydro = _count(e, hydro);
          totalHydroDelta += (finalHydro - initialHydro).abs();

          final lava = _count(e, <int>{El.lava});
          if (lava > maxLava) maxLava = lava;
          expect(lava, lessThanOrEqualTo((e.gridW * e.gridH) ~/ 4));
        }

        expect(totalHydroDelta, lessThan(2400));
        await _metric('mass_conservation_bounds', <String, num>{
          'hydro_abs_delta_total': totalHydroDelta,
          'max_lava_cells': maxLava,
        });
      },
    );

    test(
      'phase transitions and cloud condensation remain visually bounded',
      () async {
        final e = _engine(seed: 222);
        for (int x = 12; x < 84; x++) {
          _place(e, x, 12, El.cloud);
          if (x % 2 == 0) _place(e, x, 10, El.vapor);
        }
        for (int x = 10; x < 86; x++) {
          _place(e, x, 50, El.water);
        }
        e.markAllDirty();

        _step(e, 420);

        final cloudCells = _count(e, <int>{El.cloud});
        final vaporCells = _count(e, <int>{El.vapor, El.steam});
        final waterCells = _count(e, <int>{El.water});

        expect(cloudCells, inInclusiveRange(20, 1600));
        expect(vaporCells, lessThanOrEqualTo(1800));
        expect(waterCells, lessThanOrEqualTo((e.gridW * e.gridH) ~/ 2));

        await _metric('phase_and_condensation_bounds', <String, num>{
          'cloud_cells': cloudCells,
          'vapor_cells': vaporCells,
          'water_cells': waterCells,
        });
      },
    );

    test(
      'pressure moisture wind stress fields remain valid and deterministic',
      () async {
        final a = _engine(seed: 303);
        final b = _engine(seed: 303);
        _seedMixedField(a, 999);
        _seedMixedField(b, 999);

        a.windForce = 2;
        b.windForce = 2;
        _step(a, 260);
        _step(b, 260);

        expect(_signature(a), _signature(b));

        int maxMoisture = 0;
        int maxStress = 0;
        int nonZeroWind = 0;
        for (int i = 0; i < a.grid.length; i++) {
          if (a.moisture[i] > maxMoisture) maxMoisture = a.moisture[i];
          if (a.stress[i] > maxStress) maxStress = a.stress[i];
          if (a.windX2[i] != 0 || a.windY2[i] != 0) nonZeroWind++;
          expect(a.grid[i], inInclusiveRange(0, El.count - 1));
        }

        await _metric('field_integrity_determinism', <String, num>{
          'max_moisture': maxMoisture,
          'max_stress': maxStress,
          'non_zero_wind_cells': nonZeroWind,
          'signature': _signature(a),
        });

        final sig = captureBehaviorSignature(a);
        await _metric('behavior_signature_baseline', sig.toMetrics());
      },
    );
  });
}
