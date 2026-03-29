@Tags(<String>['performance', 'performance_gate'])
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/creatures/creature_registry.dart';
import 'package:the_particle_engine/simulation/element_behaviors.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/reactions/reaction_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

import '../../helpers/perf_reporter.dart';

SimulationEngine _makeEngine() {
  ElementRegistry.init();
  ReactionRegistry.init();
  return SimulationEngine(gridW: 128, gridH: 72, seed: 1337);
}

void _seedGround(SimulationEngine sim) {
  final y = sim.gridH - 12;
  for (int x = 0; x < sim.gridW; x++) {
    final idx = y * sim.gridW + x;
    sim.grid[idx] = El.stone;
    sim.mass[idx] = elementBaseMass[El.stone];
  }
  sim.markAllDirty();
}

double _percentile(List<double> values, double p) {
  if (values.isEmpty) return 0.0;
  final sorted = List<double>.from(values)..sort();
  final rank = (sorted.length - 1) * p;
  final lo = rank.floor();
  final hi = rank.ceil();
  if (lo == hi) return sorted[lo];
  final frac = rank - lo;
  return (sorted[lo] * (1.0 - frac)) + (sorted[hi] * frac);
}

void main() {
  test(
    'creature colony remains measurable and within baseline tick costs',
    () async {
      final sim = _makeEngine();
      _seedGround(sim);
      final registry = CreatureRegistry();
      final colony = registry.spawn(
        sim.gridW ~/ 2,
        sim.gridH - 13,
        gridW: sim.gridW,
        gridH: sim.gridH,
        seed: 99,
        rng: Random(99),
      );

      const frames = 300;
      final tickMs = <double>[];
      final renderMs = <double>[];
      int maxAlive = 0;
      int finalAlive = 0;
      int visibilityFailures = 0;

      for (int i = 0; i < frames; i++) {
        sim.step(simulateElement);

        final tickWatch = Stopwatch()..start();
        registry.tick(sim);
        tickWatch.stop();
        tickMs.add(tickWatch.elapsedMicroseconds / 1000.0);

        final runtime = registry.runtimeSnapshot();
        finalAlive = runtime.populationAlive;
        maxAlive = max(maxAlive, runtime.populationAlive);
        visibilityFailures = runtime.visibilityFailures;
        registry.reportRenderedCounts(<int, int>{
          colony.id: runtime.populationAlive,
        });

        final renderWatch = Stopwatch()..start();
        int renderProbe = 0;
        for (final ant in colony.ants) {
          if (ant.alive) {
            renderProbe += ant.x + ant.y;
          }
        }
        renderWatch.stop();
        renderMs.add(renderWatch.elapsedMicroseconds / 1000.0);
        expect(renderProbe, greaterThanOrEqualTo(0));
      }

      final runtime = registry.runtimeSnapshot();
      final spawnSuccessRate = runtime.spawnSuccessRate;
      final tickP50 = _percentile(tickMs, 0.50);
      final tickP95 = _percentile(tickMs, 0.95);
      final renderP50 = _percentile(renderMs, 0.50);
      final renderP95 = _percentile(renderMs, 0.95);

      expect(finalAlive, greaterThan(0));
      expect(maxAlive, greaterThan(0));
      expect(spawnSuccessRate, greaterThan(0.0));
      expect(tickP95, lessThan(10.0));

      await PerfReporter.instance.record(
        suite: 'creature_performance',
        scenario: 'ant_colony_soak',
        metrics: <String, num>{
          'frames': frames,
          'creature_population_alive': finalAlive,
          'creature_population_peak': maxAlive,
          'creature_spawn_success_rate': spawnSuccessRate,
          'creature_tick_ms_p50': tickP50,
          'creature_tick_ms_p95': tickP95,
          'creature_render_ms_p50': renderP50,
          'creature_render_ms_p95': renderP95,
          'creature_queen_alive_ratio': runtime.queenAliveRatio,
          'creature_visibility_failures': visibilityFailures,
        },
        tags: const <String, Object?>{
          'species': 'ant',
          'device_class': 'desktop',
        },
      );
    },
  );

  test('multi-colony creature stress stays bounded', () async {
    final sim = _makeEngine();
    _seedGround(sim);
    final registry = CreatureRegistry();
    final colonies = [
      registry.spawn(
        sim.gridW ~/ 4,
        sim.gridH - 13,
        gridW: sim.gridW,
        gridH: sim.gridH,
        seed: 21,
        rng: Random(21),
      ),
      registry.spawn(
        sim.gridW ~/ 2,
        sim.gridH - 13,
        gridW: sim.gridW,
        gridH: sim.gridH,
        seed: 22,
        rng: Random(22),
      ),
      registry.spawn(
        (sim.gridW * 3) ~/ 4,
        sim.gridH - 13,
        gridW: sim.gridW,
        gridH: sim.gridH,
        seed: 23,
        rng: Random(23),
      ),
    ];

    const frames = 360;
    final tickMs = <double>[];
    int peakPopulation = 0;
    for (int i = 0; i < frames; i++) {
      sim.step(simulateElement);
      final sw = Stopwatch()..start();
      registry.tick(sim);
      sw.stop();
      tickMs.add(sw.elapsedMicroseconds / 1000.0);
      final snapshot = registry.runtimeSnapshot();
      peakPopulation = max(peakPopulation, snapshot.populationAlive);
      final rendered = <int, int>{};
      for (final c in colonies) {
        rendered[c.id] = c.population;
      }
      registry.reportRenderedCounts(rendered);
    }

    final snapshot = registry.runtimeSnapshot();
    final tickP95 = _percentile(tickMs, 0.95);
    expect(snapshot.populationAlive, greaterThan(0));
    expect(snapshot.visibilityFailures, equals(0));
    expect(tickP95, lessThan(14.0));

    await PerfReporter.instance.record(
      suite: 'creature_performance',
      scenario: 'multi_colony_stress',
      metrics: <String, num>{
        'frames': frames,
        'creature_population_alive': snapshot.populationAlive,
        'creature_population_peak': peakPopulation,
        'creature_spawn_success_rate': snapshot.spawnSuccessRate,
        'creature_tick_ms_p95': tickP95,
        'creature_queen_alive_ratio': snapshot.queenAliveRatio,
        'creature_visibility_failures': snapshot.visibilityFailures,
      },
      tags: const <String, Object?>{
        'species': 'ant',
        'device_class': 'desktop',
      },
    );
  });
}
