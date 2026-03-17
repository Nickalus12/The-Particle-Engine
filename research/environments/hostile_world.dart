/// Hostile World -- hazards surround the nest.
///
/// Fire, lava, and acid patches near the colony force ants to evolve
/// hazard avoidance. Food exists but requires navigating danger zones.
/// Tests survival instincts and danger pheromone usage.
///
/// Difficulty: Hard
/// Key challenge: Avoid environmental hazards while still foraging.
library;

import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';
import 'package:the_particle_engine/simulation/world_gen/world_config.dart';
import 'environment.dart';

class HostileWorld extends Environment {
  HostileWorld({this.seed = 42});

  final int seed;

  @override
  String get name => 'hostile_world';

  @override
  Difficulty get difficulty => Difficulty.hard;

  @override
  WorldConfig get worldConfig => WorldConfig(
        seed: seed,
        width: 200,
        height: 120,
        terrainScale: 1.0,
        waterLevel: 0.25,
        caveDensity: 0.2,
        vegetation: 0.4,
      );

  @override
  (int, int) get colonyOrigin => (100, 80);

  @override
  int get minimumFoodNearNest => 5;

  @override
  void modifyGrid(SimulationEngine engine) {
    final w = engine.gridW;

    // Clear nest area.
    for (int dy = -4; dy <= 4; dy++) {
      for (int dx = -4; dx <= 4; dx++) {
        final x = 100 + dx;
        final y = 80 + dy;
        if (engine.inBounds(x, y)) {
          final idx = y * w + x;
          if (engine.grid[idx] != El.stone) {
            engine.grid[idx] = El.empty;
            engine.life[idx] = 0;
            engine.markDirty(x, y);
          }
        }
      }
    }

    // Place lava pools at 4 cardinal directions, radius ~15 from nest.
    _placeHazard(engine, 100, 65, El.lava, 4, 2); // North
    _placeHazard(engine, 100, 95, El.lava, 4, 2); // South
    _placeHazard(engine, 80, 80, El.acid, 3, 3);  // West
    _placeHazard(engine, 120, 80, El.acid, 3, 3); // East

    // Place fire lines between hazards.
    for (int x = 85; x <= 95; x++) {
      _placeIfEmpty(engine, x, 72, El.fire);
    }
    for (int x = 105; x <= 115; x++) {
      _placeIfEmpty(engine, x, 72, El.fire);
    }

    // Guarantee food beyond the hazard ring.
    final rng = engine.rng;
    for (int i = 0; i < 15; i++) {
      final fx = 30 + rng.nextInt(140);
      final fy = 50 + rng.nextInt(60);
      // Only place outside the danger zone.
      final dx = (fx - 100).abs();
      final dy = (fy - 80).abs();
      if (dx + dy > 25 && engine.inBounds(fx, fy)) {
        final idx = fy * w + fx;
        if (engine.grid[idx] == El.empty) {
          engine.grid[idx] = El.seed;
          engine.markDirty(fx, fy);
        }
      }
    }
  }

  void _placeHazard(
      SimulationEngine engine, int cx, int cy, int elType, int w, int h) {
    for (int dy = -h; dy <= h; dy++) {
      for (int dx = -w; dx <= w; dx++) {
        _placeIfEmpty(engine, cx + dx, cy + dy, elType);
      }
    }
  }

  void _placeIfEmpty(SimulationEngine engine, int x, int y, int elType) {
    if (!engine.inBounds(x, y)) return;
    final idx = y * engine.gridW + x;
    if (engine.grid[idx] == El.empty || engine.grid[idx] == El.dirt) {
      engine.grid[idx] = elType;
      engine.life[idx] = 0;
      engine.markDirty(x, y);
    }
  }
}
