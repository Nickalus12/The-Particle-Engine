import '../../simulation/element_registry.dart';
import '../../simulation/simulation_engine.dart';
import '../../utils/math_helpers.dart';
import '../pheromone_system.dart';

/// Foraging behaviour heuristics for ants with the forager role.
class ForagerBehavior {
  ForagerBehavior._();

  /// Suggest a direction for a forager searching for food.
  static (int, int) suggestSearchMove(
    PheromoneSystem foodPheromones,
    int x,
    int y,
  ) {
    double bestScore = -1.0;
    (int, int) best = (0, 0);

    for (final (dx, dy) in const [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
      final score = foodPheromones.read(x + dx, y + dy);
      final noise = MathHelpers.randomDouble() * 0.02;
      if (score + noise > bestScore) {
        bestScore = score + noise;
        best = (dx, dy);
      }
    }

    if (bestScore < 0.01) return _randomDirection();
    return best;
  }

  /// Suggest a direction for a forager returning to the nest.
  static (int, int) suggestReturnMove(
    PheromoneSystem homePheromones,
    int x,
    int y,
  ) {
    double bestScore = -1.0;
    (int, int) best = (0, 0);

    for (final (dx, dy) in const [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
      final score = homePheromones.read(x + dx, y + dy);
      if (score > bestScore) {
        bestScore = score;
        best = (dx, dy);
      }
    }

    return best;
  }

  /// Check if there is food at or adjacent to (x, y).
  static bool canSeeFood(SimulationEngine sim, int x, int y) {
    if (_isFoodAt(sim, x, y)) return true;
    for (final (dx, dy) in const [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
      if (_isFoodAt(sim, x + dx, y + dy)) return true;
    }
    return false;
  }

  /// Find the nearest food element adjacent to (x, y).
  static (int, int)? findAdjacentFood(SimulationEngine sim, int x, int y) {
    if (_isFoodAt(sim, x, y)) return (x, y);
    for (final (dx, dy) in const [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
      final nx = x + dx;
      final ny = y + dy;
      if (_isFoodAt(sim, nx, ny)) return (nx, ny);
    }
    return null;
  }

  static bool _isFoodAt(SimulationEngine sim, int x, int y) {
    x = sim.wrapX(x);
    if (!sim.inBoundsY(y)) return false;
    final el = sim.grid[y * sim.gridW + x];
    if (el == El.empty || el >= maxElements) return false;
    final cat = elCategory[el];
    return (cat & ElCat.organic != 0) && (cat & ElCat.flammable != 0);
  }

  static (int, int) _randomDirection() {
    const dirs = [(-1, 0), (1, 0), (0, -1), (0, 1)];
    return dirs[MathHelpers.randomInt(dirs.length)];
  }
}
