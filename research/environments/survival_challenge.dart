/// Survival Challenge -- limited food, must forage efficiently.
///
/// Sparse vegetation with food placed far from the nest. Ants must explore
/// aggressively and manage energy to avoid starvation. Tests foraging
/// efficiency and exploration drive.
///
/// Difficulty: Medium
/// Key challenge: Food is scarce; colony must explore far and deliver reliably.
library;

import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';
import 'package:the_particle_engine/simulation/world_gen/world_config.dart';
import 'environment.dart';

class SurvivalChallenge extends Environment {
  SurvivalChallenge({this.seed = 42});

  final int seed;

  @override
  String get name => 'survival_challenge';

  @override
  Difficulty get difficulty => Difficulty.medium;

  @override
  WorldConfig get worldConfig => WorldConfig(
        seed: seed,
        width: 200,
        height: 120,
        terrainScale: 0.7,
        waterLevel: 0.2,
        caveDensity: 0.1,
        vegetation: 0.1, // Very sparse vegetation.
      );

  @override
  (int, int) get colonyOrigin => (100, 85);

  @override
  int get minimumFoodNearNest => 3;

  @override
  void modifyGrid(SimulationEngine engine) {
    // Clear colony origin area.
    for (int dy = -3; dy <= 3; dy++) {
      for (int dx = -3; dx <= 3; dx++) {
        final x = 100 + dx;
        final y = 85 + dy;
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

    // Place small food clusters far from nest (radius 40-60).
    final rng = engine.rng;
    for (int cluster = 0; cluster < 4; cluster++) {
      final angle = cluster * (3.14159 * 2 / 4) + 0.5;
      final radius = 40.0 + rng.nextDouble() * 20.0;
      final cx = 100 + (radius * _approxCos(angle)).round();
      final cy = 85 + (radius * _approxSin(angle) * 0.4).round();

      // Place a small cluster of 5 seeds.
      for (int i = 0; i < 5; i++) {
        final fx = cx + rng.nextInt(5) - 2;
        final fy = cy + rng.nextInt(3) - 1;
        if (engine.inBounds(fx, fy)) {
          final idx = fy * engine.gridW + fx;
          if (engine.grid[idx] == El.empty) {
            engine.grid[idx] = El.seed;
            engine.markDirty(fx, fy);
          }
        }
      }
    }
  }

  static double _approxCos(double x) {
    x = x % 6.28318;
    double r = 1.0, t = 1.0;
    for (int i = 1; i <= 6; i++) {
      t *= -x * x / ((2 * i - 1) * (2 * i));
      r += t;
    }
    return r;
  }

  static double _approxSin(double x) => _approxCos(x - 1.5708);
}
