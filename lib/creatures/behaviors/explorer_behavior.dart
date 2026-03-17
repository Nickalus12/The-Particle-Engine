import '../../simulation/simulation_engine.dart';
import '../../utils/math_helpers.dart';
import '../pheromone_system.dart';

/// Exploration behaviour heuristics for ants with the explorer role.
///
/// Explorers expand the colony's known territory by moving toward unexplored
/// areas (low pheromone concentration).
class ExplorerBehavior {
  ExplorerBehavior._();

  /// Pick the best exploration direction from ([x],[y]).
  static (int, int) suggestMove(
    SimulationEngine sim,
    PheromoneSystem homePheromones,
    int x,
    int y,
  ) {
    double bestScore = double.infinity;
    (int, int) best = (0, 0);

    for (final (dx, dy) in const [(-1, 0), (1, 0), (0, -1), (0, 1),
        (-1, -1), (1, -1), (-1, 1), (1, 1)]) {
      final nx = sim.wrapX(x + dx);
      final ny = y + dy;
      if (!sim.inBoundsY(ny)) continue;

      final pheromone = homePheromones.read(nx, ny);
      final noise = MathHelpers.randomDouble() * 0.05;
      final score = pheromone + noise;

      if (score < bestScore) {
        bestScore = score;
        best = (dx, dy);
      }
    }

    return best;
  }

  /// Calculate an exploration bonus for an ant at a given position.
  static double explorationValue(
    PheromoneSystem homePheromones,
    int x,
    int y,
  ) {
    double total = 0;
    int count = 0;
    for (var dy = -3; dy <= 3; dy++) {
      for (var dx = -3; dx <= 3; dx++) {
        total += homePheromones.read(x + dx, y + dy);
        count++;
      }
    }
    final avg = count > 0 ? total / count : 0.0;
    return (1.0 - avg).clamp(0.0, 1.0);
  }
}
