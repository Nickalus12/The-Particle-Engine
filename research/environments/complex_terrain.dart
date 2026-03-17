/// Complex Terrain -- canyon terrain with caves and water barriers.
///
/// Dramatic elevation changes, cave systems, and water bodies that
/// ants must navigate around. Tests pathfinding emergence and the ability
/// to handle obstacles without explicit path planning.
///
/// Difficulty: Hard
/// Key challenge: Navigate complex terrain with elevation, caves, and water.
library;

import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';
import 'package:the_particle_engine/simulation/world_gen/world_config.dart';
import 'environment.dart';

class ComplexTerrain extends Environment {
  ComplexTerrain({this.seed = 42});

  final int seed;

  @override
  String get name => 'complex_terrain';

  @override
  Difficulty get difficulty => Difficulty.hard;

  @override
  WorldConfig get worldConfig => WorldConfig.canyon(
        seed: seed,
        width: 200,
        height: 140,
      );

  @override
  (int, int) get colonyOrigin => (100, 90);

  @override
  int get minimumFoodNearNest => 5;

  @override
  void modifyGrid(SimulationEngine engine) {
    final w = engine.gridW;

    // Carve out a safe chamber for the colony nest.
    for (int dy = -5; dy <= 5; dy++) {
      for (int dx = -5; dx <= 5; dx++) {
        final x = 100 + dx;
        final y = 90 + dy;
        if (engine.inBounds(x, y)) {
          final idx = y * w + x;
          engine.grid[idx] = El.empty;
          engine.life[idx] = 0;
          engine.markDirty(x, y);
        }
      }
    }

    // Ensure solid floor under nest.
    for (int dx = -6; dx <= 6; dx++) {
      final x = 100 + dx;
      final y = 96;
      if (engine.inBounds(x, y)) {
        final idx = y * w + x;
        engine.grid[idx] = El.dirt;
        engine.markDirty(x, y);
      }
    }

    // Place food in scattered elevated positions and cave pockets.
    final rng = engine.rng;
    final foodPositions = [
      (40, 50), (160, 50), (100, 40), (60, 100), (140, 100),
    ];
    for (final (fx, fy) in foodPositions) {
      for (int i = 0; i < 6; i++) {
        final px = fx + rng.nextInt(7) - 3;
        final py = fy + rng.nextInt(5) - 2;
        if (engine.inBounds(px, py)) {
          final idx = py * w + px;
          if (engine.grid[idx] == El.empty) {
            engine.grid[idx] = El.seed;
            engine.markDirty(px, py);
          }
        }
      }
    }

    // Add a water barrier between the nest and the northern food.
    for (int x = 80; x <= 120; x++) {
      for (int y = 70; y <= 72; y++) {
        if (engine.inBounds(x, y)) {
          final idx = y * w + x;
          if (engine.grid[idx] == El.empty) {
            engine.grid[idx] = El.water;
            engine.life[idx] = 100;
            engine.markDirty(x, y);
          }
        }
      }
    }
  }
}
