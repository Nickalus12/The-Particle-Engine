@Tags(<String>['performance', 'soak'])
library;

import 'dart:math';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/element_behaviors.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/reactions/reaction_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';
import 'package:the_particle_engine/simulation/world_gen/world_config.dart';
import 'package:the_particle_engine/simulation/world_gen/world_generator.dart';

import '../../helpers/perf_reporter.dart';

SimulationEngine _makeEngine({int w = 96, int h = 64, required int seed}) {
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

int _count(SimulationEngine e, int el) {
  int c = 0;
  for (int i = 0; i < e.grid.length; i++) {
    if (e.grid[i] == el) c++;
  }
  return c;
}

int _countAny(SimulationEngine e, List<int> elements) {
  int c = 0;
  for (int i = 0; i < e.grid.length; i++) {
    if (elements.contains(e.grid[i])) c++;
  }
  return c;
}

void _paintSeededField(SimulationEngine e, int seed) {
  final r = Random(seed);
  final palette = <int>[
    El.sand,
    El.water,
    El.dirt,
    El.stone,
    El.oil,
    El.ice,
    El.vapor,
    El.cloud,
    El.steam,
    El.lava,
  ];
  for (int y = 4; y < e.gridH - 4; y++) {
    for (int x = 0; x < e.gridW; x++) {
      // Keep fill sparse to avoid extreme full-grid states.
      if (r.nextInt(100) < 12) {
        final el = palette[r.nextInt(palette.length)];
        _place(e, x, y, el);
      }
    }
  }
}

int _signature(SimulationEngine e) {
  int h = 0x811C9DC5; // FNV offset basis
  for (int i = 0; i < e.grid.length; i++) {
    h ^= e.grid[i];
    h = (h * 0x01000193) & 0x7fffffff;
    h ^= e.life[i];
    h = (h * 0x01000193) & 0x7fffffff;
    h ^= e.temperature[i];
    h = (h * 0x01000193) & 0x7fffffff;
  }
  h ^= e.frameCount;
  h = (h * 0x01000193) & 0x7fffffff;
  return h;
}

final bool _nightlySoak = Platform.environment['SOAK_LEVEL'] == 'nightly';

int _modeSteps(int quick, int nightly) => _nightlySoak ? nightly : quick;

int _modeSeeds(int quick, int nightly) => _nightlySoak ? nightly : quick;

Future<void> _recordSoak(
  String scenario, {
  required int steps,
  required int seeds,
  required int worldW,
  required int worldH,
  required int elapsedMs,
  Map<String, num> extra = const <String, num>{},
}) async {
  await PerfReporter.instance.record(
    suite: 'engine_soak',
    scenario: scenario,
    metrics: <String, num>{
      'steps': steps,
      'seeds': seeds,
      'grid_w': worldW,
      'grid_h': worldH,
      'elapsed_ms': elapsedMs,
      ...extra,
    },
    tags: <String, Object?>{'mode': _nightlySoak ? 'nightly' : 'quick'},
  );
}

void main() {
  group('Soak Determinism', () {
    test('snapshot replay is deterministic for identical continuations', () {
      final sw = Stopwatch()..start();
      final e = _makeEngine(seed: 77);
      _paintSeededField(e, 9001);
      _step(e, 120);

      final snap = e.captureSnapshot();
      final a = _makeEngine(seed: 4444);
      final b = _makeEngine(seed: 4444);
      a.restoreSnapshot(snap);
      b.restoreSnapshot(snap);

      _step(a, _modeSteps(180, 500));
      _step(b, _modeSteps(180, 500));

      expect(_signature(a), _signature(b));
      expect(_count(a, El.water), _count(b, El.water));
      expect(_count(a, El.lava), _count(b, El.lava));
      expect(_count(a, El.cloud), _count(b, El.cloud));
      sw.stop();
      return _recordSoak(
        'deterministic_snapshot_replay',
        steps: _modeSteps(180, 500) + 120,
        seeds: 1,
        worldW: e.gridW,
        worldH: e.gridH,
        elapsedMs: sw.elapsedMilliseconds,
      );
    });
  });

  group('Soak Multi-Seed', () {
    test('randomized seeded fields keep valid element IDs over long runs', () {
      final sw = Stopwatch()..start();
      final nSeeds = _modeSeeds(6, 18);
      for (int i = 0; i < nSeeds; i++) {
        final seed = 10 + i;
        final e = _makeEngine(seed: seed);
        _paintSeededField(e, seed * 37);
        _step(e, _modeSteps(260, 700));

        for (int i = 0; i < e.grid.length; i++) {
          expect(
            e.grid[i],
            inInclusiveRange(0, El.count - 1),
            reason: 'Invalid element at seed=$seed idx=$i',
          );
        }
      }
      sw.stop();
      return _recordSoak(
        'valid_ids_multiseed',
        steps: _modeSteps(260, 700),
        seeds: nSeeds,
        worldW: 96,
        worldH: 64,
        elapsedMs: sw.elapsedMilliseconds,
      );
    });

    test('hydrologic totals stay within bounded envelope across seeds', () {
      final sw = Stopwatch()..start();
      final hydroEls = <int>[
        El.water,
        El.steam,
        El.vapor,
        El.cloud,
        El.ice,
        El.snow,
        El.bubble,
      ];
      final nSeeds = _modeSeeds(5, 14);
      for (int i = 0; i < nSeeds; i++) {
        final seed = 21 + i;
        final e = _makeEngine(seed: seed);
        _paintSeededField(e, seed * 53);
        final initialHydro = _countAny(e, hydroEls);
        _step(e, _modeSteps(420, 1100));
        final finalHydro = _countAny(e, hydroEls);

        final total = e.gridW * e.gridH;
        expect(
          finalHydro,
          lessThanOrEqualTo(initialHydro + total ~/ 5),
          reason: 'Hydrologic runaway at seed=$seed',
        );
      }
      sw.stop();
      return _recordSoak(
        'hydrologic_bounded_multiseed',
        steps: _modeSteps(420, 1100),
        seeds: nSeeds,
        worldW: 96,
        worldH: 64,
        elapsedMs: sw.elapsedMilliseconds,
      );
    });

    test('lava remains bounded in mixed random worlds', () {
      final sw = Stopwatch()..start();
      final nSeeds = _modeSeeds(5, 14);
      for (int i = 0; i < nSeeds; i++) {
        final seed = 31 + i;
        final e = _makeEngine(seed: seed);
        _paintSeededField(e, seed * 11);
        _step(e, _modeSteps(420, 1100));
        final lava = _count(e, El.lava);
        final total = e.gridW * e.gridH;
        expect(
          lava,
          lessThanOrEqualTo(total ~/ 4),
          reason: 'Lava runaway in random world seed=$seed',
        );
      }
      sw.stop();
      return _recordSoak(
        'lava_bounded_multiseed',
        steps: _modeSteps(420, 1100),
        seeds: nSeeds,
        worldW: 96,
        worldH: 64,
        elapsedMs: sw.elapsedMilliseconds,
      );
    });
  });

  group('Soak Worldgen', () {
    test('preset worlds run stably for 300 frames', () {
      final sw = Stopwatch()..start();
      final presets = <WorldConfig>[
        WorldConfig.meadow(seed: 101, width: 96, height: 64),
        WorldConfig.canyon(seed: 102, width: 96, height: 64),
        WorldConfig.island(seed: 103, width: 96, height: 64),
        WorldConfig.underground(seed: 104, width: 96, height: 64),
      ];

      for (final config in presets) {
        final e = _makeEngine(
          w: config.width,
          h: config.height,
          seed: config.seed,
        );
        final gridData = WorldGenerator.generate(config);
        gridData.loadIntoEngine(e);
        _step(e, _modeSteps(300, 900));

        int nonEmpty = 0;
        for (int i = 0; i < e.grid.length; i++) {
          final el = e.grid[i];
          expect(el, inInclusiveRange(0, El.count - 1));
          if (el != El.empty) nonEmpty++;
        }
        expect(nonEmpty, greaterThan(e.grid.length ~/ 12));
      }
      sw.stop();
      return _recordSoak(
        'worldgen_presets_stable',
        steps: _modeSteps(300, 900),
        seeds: presets.length,
        worldW: 96,
        worldH: 64,
        elapsedMs: sw.elapsedMilliseconds,
      );
    });

    test('random world configs are deterministic by seed', () {
      final sw = Stopwatch()..start();
      final configA = WorldConfig.random(seed: 555, width: 96, height: 64);
      final configB = WorldConfig.random(seed: 555, width: 96, height: 64);
      final a = WorldGenerator.generate(configA);
      final b = WorldGenerator.generate(configB);

      expect(a.grid.length, b.grid.length);
      for (int i = 0; i < a.grid.length; i++) {
        expect(a.grid[i], b.grid[i], reason: 'Mismatch at cell $i');
      }
      sw.stop();
      return _recordSoak(
        'worldgen_seed_determinism',
        steps: 0,
        seeds: 1,
        worldW: 96,
        worldH: 64,
        elapsedMs: sw.elapsedMilliseconds,
      );
    });
  });

  group('Soak Gravity Modes', () {
    test('inverted gravity drives water upward over time', () {
      final sw = Stopwatch()..start();
      final e = _makeEngine(seed: 808);
      e.gravityDir = -1;
      for (int x = 30; x < 66; x++) {
        for (int y = 46; y < 58; y++) {
          _place(e, x, y, El.water);
        }
      }

      _step(e, _modeSteps(120, 420));

      int topHalfWater = 0;
      for (int y = 0; y < e.gridH ~/ 2; y++) {
        for (int x = 0; x < e.gridW; x++) {
          if (e.grid[y * e.gridW + x] == El.water) topHalfWater++;
        }
      }
      expect(topHalfWater, greaterThan(0));
      sw.stop();
      return _recordSoak(
        'gravity_inversion_upward_water',
        steps: _modeSteps(120, 420),
        seeds: 1,
        worldW: e.gridW,
        worldH: e.gridH,
        elapsedMs: sw.elapsedMilliseconds,
        extra: <String, num>{'top_half_water_cells': topHalfWater},
      );
    });

    test('step preserves valid IDs during gravity flips', () {
      final sw = Stopwatch()..start();
      final e = _makeEngine(seed: 909);
      _paintSeededField(e, 4242);

      final iters = _modeSteps(200, 800);
      for (int i = 0; i < iters; i++) {
        if (i % 25 == 0) {
          e.gravityDir = -e.gravityDir;
        }
        _step(e, 1);
      }

      for (int i = 0; i < e.grid.length; i++) {
        expect(e.grid[i], inInclusiveRange(0, El.count - 1));
      }
      sw.stop();
      return _recordSoak(
        'gravity_flip_valid_ids',
        steps: iters,
        seeds: 1,
        worldW: e.gridW,
        worldH: e.gridH,
        elapsedMs: sw.elapsedMilliseconds,
      );
    });
  });
}
