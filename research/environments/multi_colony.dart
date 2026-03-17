/// Multi Colony -- two competing colonies on the same map.
///
/// Tests inter-colony competition, combat evolution, and resource contention.
/// Both colonies start with equal resources on opposite sides of the map.
/// Success means outcompeting the rival for food and territory.
///
/// Difficulty: Medium
/// Key challenge: Compete with another colony for limited resources.
library;

import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';
import 'package:the_particle_engine/simulation/world_gen/world_config.dart';
import 'environment.dart';

class MultiColony extends Environment {
  MultiColony({this.seed = 42});

  final int seed;

  @override
  String get name => 'multi_colony';

  @override
  Difficulty get difficulty => Difficulty.medium;

  @override
  WorldConfig get worldConfig => WorldConfig.meadow(
        seed: seed,
        width: 240,
        height: 120,
      );

  @override
  (int, int) get colonyOrigin => (60, 80);

  @override
  List<(int, int)> get extraColonies => const [(180, 80)];

  @override
  int get minimumFoodNearNest => 8;

  @override
  void modifyGrid(SimulationEngine engine) {
    final w = engine.gridW;

    // Clear areas around both nests.
    _clearNest(engine, 60, 80);
    _clearNest(engine, 180, 80);

    // Place shared food zone in the center.
    final rng = engine.rng;
    for (int i = 0; i < 30; i++) {
      final fx = 110 + rng.nextInt(20);
      final fy = 60 + rng.nextInt(40);
      if (engine.inBounds(fx, fy)) {
        final idx = fy * w + fx;
        if (engine.grid[idx] == El.empty) {
          engine.grid[idx] = El.seed;
          engine.markDirty(fx, fy);
        }
      }
    }

    // Place some food near each nest so they can bootstrap.
    for (int i = 0; i < 8; i++) {
      _placeNearby(engine, 60, 80, 8, 15, El.seed);
      _placeNearby(engine, 180, 80, 8, 15, El.seed);
    }
  }

  void _clearNest(SimulationEngine engine, int cx, int cy) {
    for (int dy = -3; dy <= 3; dy++) {
      for (int dx = -3; dx <= 3; dx++) {
        final x = cx + dx;
        final y = cy + dy;
        if (engine.inBounds(x, y)) {
          final idx = y * engine.gridW + x;
          if (engine.grid[idx] != El.stone) {
            engine.grid[idx] = El.empty;
            engine.life[idx] = 0;
            engine.markDirty(x, y);
          }
        }
      }
    }
  }

  void _placeNearby(
      SimulationEngine engine, int cx, int cy, int minR, int maxR, int el) {
    final rng = engine.rng;
    for (int attempt = 0; attempt < 20; attempt++) {
      final dx = rng.nextInt(maxR * 2 + 1) - maxR;
      final dy = rng.nextInt(maxR * 2 + 1) - maxR;
      if (dx.abs() + dy.abs() < minR) continue;
      final x = cx + dx;
      final y = cy + dy;
      if (engine.inBounds(x, y)) {
        final idx = y * engine.gridW + x;
        if (engine.grid[idx] == El.empty) {
          engine.grid[idx] = el;
          engine.markDirty(x, y);
          return;
        }
      }
    }
  }
}
