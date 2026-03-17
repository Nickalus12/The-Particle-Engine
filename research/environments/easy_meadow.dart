/// Easy Meadow -- gentle terrain with abundant food.
///
/// The baseline evaluation environment. Gentle rolling hills, moderate water,
/// lush vegetation, minimal hazards. Food is plentiful within foraging range.
///
/// Difficulty: Easy
/// Key challenge: Basic foraging loop (find food -> pick up -> deliver).
library;

import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';
import 'package:the_particle_engine/simulation/world_gen/world_config.dart';
import 'environment.dart';

class EasyMeadow extends Environment {
  EasyMeadow({this.seed = 42});

  final int seed;

  @override
  String get name => 'easy_meadow';

  @override
  Difficulty get difficulty => Difficulty.easy;

  @override
  WorldConfig get worldConfig => WorldConfig.meadow(
        seed: seed,
        width: 200,
        height: 120,
      );

  @override
  (int, int) get colonyOrigin => (100, 80);

  @override
  int get minimumFoodNearNest => 10;

  @override
  void modifyGrid(SimulationEngine engine) {
    // Ensure the colony origin is on empty ground.
    _clearArea(engine, 100, 80, 3);

    // Guarantee food near the nest (seeds in a ring at radius 10-20).
    final rng = engine.rng;
    for (int i = 0; i < 20; i++) {
      final angle = i * (3.14159 * 2 / 20);
      final radius = 10.0 + rng.nextDouble() * 10.0;
      final fx = 100 + (radius * _cos(angle)).round();
      final fy = 80 + (radius * _sin(angle) * 0.5).round();
      if (engine.inBounds(fx, fy)) {
        final idx = fy * engine.gridW + fx;
        if (engine.grid[idx] == El.empty || engine.grid[idx] == El.dirt) {
          engine.grid[idx] = El.seed;
          engine.markDirty(fx, fy);
        }
      }
    }
  }

  void _clearArea(SimulationEngine engine, int cx, int cy, int radius) {
    for (int dy = -radius; dy <= radius; dy++) {
      for (int dx = -radius; dx <= radius; dx++) {
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

  // Inline trig to avoid dart:math import for minimal overhead.
  static double _cos(double x) {
    // Taylor series approximation, good enough for placement.
    x = x % (2 * 3.14159265);
    double result = 1.0;
    double term = 1.0;
    for (int i = 1; i <= 6; i++) {
      term *= -x * x / ((2 * i - 1) * (2 * i));
      result += term;
    }
    return result;
  }

  static double _sin(double x) => _cos(x - 3.14159265 / 2);
}
