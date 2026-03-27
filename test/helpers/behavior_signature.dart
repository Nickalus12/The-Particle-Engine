import 'dart:collection';

import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

class BehaviorSignature {
  const BehaviorSignature({
    required this.hydroCells,
    required this.lavaCells,
    required this.cloudCells,
    required this.maxCloudCluster,
    required this.hydroCenterY,
    required this.avgMoisture,
    required this.avgStress,
    required this.gridHash,
  });

  final int hydroCells;
  final int lavaCells;
  final int cloudCells;
  final int maxCloudCluster;
  final double hydroCenterY;
  final double avgMoisture;
  final double avgStress;
  final int gridHash;

  Map<String, num> toMetrics() {
    return <String, num>{
      'hydro_cells': hydroCells,
      'lava_cells': lavaCells,
      'cloud_cells': cloudCells,
      'max_cloud_cluster': maxCloudCluster,
      'hydro_center_y': hydroCenterY,
      'avg_moisture': avgMoisture,
      'avg_stress': avgStress,
      'grid_hash': gridHash,
    };
  }
}

BehaviorSignature captureBehaviorSignature(SimulationEngine e) {
  const hydro = <int>{
    El.water,
    El.vapor,
    El.cloud,
    El.steam,
    El.ice,
    El.snow,
    El.bubble,
  };
  int hydroCells = 0;
  int lavaCells = 0;
  int cloudCells = 0;
  int hydroYSum = 0;
  int moistSum = 0;
  int stressSum = 0;
  int hash = 0x811C9DC5;

  for (int i = 0; i < e.grid.length; i++) {
    final el = e.grid[i];
    if (hydro.contains(el)) {
      hydroCells++;
      hydroYSum += i ~/ e.gridW;
    }
    if (el == El.lava) lavaCells++;
    if (el == El.cloud) cloudCells++;
    moistSum += e.moisture[i];
    stressSum += e.stress[i];
    hash ^= el;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }

  final hydroCenterY = hydroCells == 0 ? 0.0 : hydroYSum / hydroCells;
  final avgMoisture = moistSum / e.grid.length;
  final avgStress = stressSum / e.grid.length;

  return BehaviorSignature(
    hydroCells: hydroCells,
    lavaCells: lavaCells,
    cloudCells: cloudCells,
    maxCloudCluster: _maxCluster(e, El.cloud),
    hydroCenterY: hydroCenterY,
    avgMoisture: avgMoisture,
    avgStress: avgStress,
    gridHash: hash,
  );
}

int _maxCluster(SimulationEngine e, int el) {
  final visited = List<bool>.filled(e.grid.length, false);
  int maxSize = 0;
  final q = Queue<int>();
  for (int idx = 0; idx < e.grid.length; idx++) {
    if (visited[idx] || e.grid[idx] != el) continue;
    visited[idx] = true;
    q.add(idx);
    int size = 0;
    while (q.isNotEmpty) {
      final cur = q.removeFirst();
      size++;
      final x = cur % e.gridW;
      final y = cur ~/ e.gridW;
      for (final (nx, ny) in <(int, int)>[
        (x - 1, y),
        (x + 1, y),
        (x, y - 1),
        (x, y + 1),
      ]) {
        if (nx < 0 || nx >= e.gridW || ny < 0 || ny >= e.gridH) continue;
        final ni = ny * e.gridW + nx;
        if (visited[ni] || e.grid[ni] != el) continue;
        visited[ni] = true;
        q.add(ni);
      }
    }
    if (size > maxSize) maxSize = size;
  }
  return maxSize;
}
