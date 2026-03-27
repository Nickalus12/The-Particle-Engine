@Tags(<String>['performance', 'performance_gate'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/element_behaviors.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/reactions/reaction_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

import '../../helpers/perf_reporter.dart';
import '../../helpers/scenario_dsl.dart';

SimulationEngine _engine(int seed) {
  ElementRegistry.init();
  ReactionRegistry.init();
  return SimulationEngine(gridW: 96, gridH: 64, seed: seed);
}

void _step(SimulationEngine e, int ticks) {
  for (int i = 0; i < ticks; i++) {
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

int _countIsolatedSingletons(SimulationEngine e, int el) {
  int isolated = 0;
  for (int y = 1; y < e.gridH - 1; y++) {
    for (int x = 0; x < e.gridW; x++) {
      final idx = y * e.gridW + x;
      if (e.grid[idx] != el) continue;
      int neighbors = 0;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = e.wrapX(x + dx);
          final ny = y + dy;
          if (!e.inBoundsY(ny)) continue;
          if (e.grid[ny * e.gridW + nx] == el) neighbors++;
        }
      }
      if (neighbors == 0) isolated++;
    }
  }
  return isolated;
}

int _largestCluster(SimulationEngine e, int el) {
  final visited = List<bool>.filled(e.grid.length, false);
  int best = 0;
  final queue = <int>[];
  for (int i = 0; i < e.grid.length; i++) {
    if (visited[i] || e.grid[i] != el) continue;
    visited[i] = true;
    queue.add(i);
    int size = 0;
    while (queue.isNotEmpty) {
      final idx = queue.removeLast();
      size++;
      final x = idx % e.gridW;
      final y = idx ~/ e.gridW;
      for (final (dx, dy) in const <(int, int)>[
        (-1, 0),
        (1, 0),
        (0, -1),
        (0, 1),
      ]) {
        final nx = e.wrapX(x + dx);
        final ny = y + dy;
        if (!e.inBoundsY(ny)) continue;
        final ni = ny * e.gridW + nx;
        if (visited[ni] || e.grid[ni] != el) continue;
        visited[ni] = true;
        queue.add(ni);
      }
    }
    if (size > best) best = size;
  }
  return best;
}

Future<void> _metric(String scenario, Map<String, num> metrics) {
  return PerfReporter.instance.record(
    suite: 'atmospherics',
    scenario: scenario,
    metrics: metrics,
  );
}

void main() {
  test('condensation artifacts and cloud morphology remain bounded', () async {
    final e = _engine(1717);
    ScenarioLibrary.condensationStress().apply(e);
    final cloudSeries = <int>[];
    for (int i = 0; i < 13; i++) {
      _step(e, 20);
      cloudSeries.add(_count(e, El.cloud));
    }

    final cloudCount = _count(e, El.cloud);
    final vaporCount = _count(e, El.vapor) + _count(e, El.steam);
    final isolatedWaterDots = _countIsolatedSingletons(e, El.water);
    final isolatedCloudDots = _countIsolatedSingletons(e, El.cloud);
    final largestCloudCluster = _largestCluster(e, El.cloud);
    final clusterCoherence = cloudCount == 0
        ? 0.0
        : largestCloudCluster / cloudCount;
    double temporalDrift = 0.0;
    for (int i = 1; i < cloudSeries.length; i++) {
      temporalDrift += (cloudSeries[i] - cloudSeries[i - 1]).abs().toDouble();
    }
    final meanCloud = cloudSeries.isEmpty
        ? 1.0
        : (cloudSeries.reduce((a, b) => a + b) / cloudSeries.length).toDouble();
    final temporalSmoothness = (1.0 - (temporalDrift / (meanCloud * 8.0)))
        .clamp(0.0, 1.0);

    expect(cloudCount, inInclusiveRange(10, 2200));
    expect(vaporCount, lessThanOrEqualTo(2800));
    expect(isolatedWaterDots, lessThanOrEqualTo(60));
    expect(isolatedCloudDots, lessThanOrEqualTo(120));
    expect(clusterCoherence, greaterThan(0.10));
    expect(temporalSmoothness, greaterThan(0.10));

    await _metric('condensation_cloud_morphology', <String, num>{
      'cloud_count': cloudCount,
      'vapor_count': vaporCount,
      'isolated_water_dots': isolatedWaterDots,
      'isolated_cloud_dots': isolatedCloudDots,
      'cloud_cluster_coherence': clusterCoherence,
      'cloud_temporal_smoothness': temporalSmoothness,
    });
  });
}
