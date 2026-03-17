import '../../simulation/simulation_engine.dart';
import '../../utils/math_helpers.dart';
import '../ant.dart';
import '../pheromone_system.dart';

/// Defender behaviour heuristics for ants with the defender role.
///
/// Defenders protect the colony from threats:
/// - Follow danger pheromone gradients toward enemies.
/// - Patrol a perimeter around the nest entrance.
/// - Engage enemy ants in combat.
class DefenderBehavior {
  DefenderBehavior._();

  /// Suggest a movement direction for a defender.
  static (int, int) suggestMove(
    SimulationEngine sim,
    PheromoneSystem dangerPheromones,
    int nestX,
    int nestY,
    int x,
    int y,
    List<Ant> nearbyEnemies,
  ) {
    if (nearbyEnemies.isNotEmpty) {
      return _moveTowardClosestEnemy(x, y, nearbyEnemies);
    }

    final dangerDir = _followDangerGradient(dangerPheromones, x, y);
    if (dangerDir != null) return dangerDir;

    return _patrol(nestX, nestY, x, y);
  }

  static (int, int) _moveTowardClosestEnemy(int x, int y, List<Ant> enemies) {
    Ant? closest;
    int bestDist = 999999;

    for (final enemy in enemies) {
      if (!enemy.alive) continue;
      final dist = MathHelpers.manhattan(x, y, enemy.x, enemy.y);
      if (dist < bestDist) {
        bestDist = dist;
        closest = enemy;
      }
    }

    if (closest == null) return (0, 0);
    return ((closest.x - x).sign, (closest.y - y).sign);
  }

  static (int, int)? _followDangerGradient(
    PheromoneSystem dangerPheromones,
    int x,
    int y,
  ) {
    double bestDanger = 0.1;
    (int, int)? best;

    for (final (dx, dy) in const [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
      final score = dangerPheromones.read(x + dx, y + dy);
      if (score > bestDanger) {
        bestDanger = score;
        best = (dx, dy);
      }
    }

    return best;
  }

  static (int, int) _patrol(int nestX, int nestY, int x, int y) {
    final dx = x - nestX;
    final dy = y - nestY;
    final dist = dx.abs() + dy.abs();

    if (dist > 10) return ((nestX - x).sign, (nestY - y).sign);
    if (dist < 4) return (dx.sign, dy.sign);

    if (dx.abs() >= dy.abs()) {
      return (0, dx > 0 ? 1 : -1);
    } else {
      return (dy > 0 ? -1 : 1, 0);
    }
  }

  /// Calculate a threat level at a position.
  static double threatLevel(
    PheromoneSystem dangerPheromones,
    int x,
    int y,
    List<Ant> nearbyEnemies,
  ) {
    final pheromone = dangerPheromones.read(x, y);
    final enemyCount = nearbyEnemies.where((e) => e.alive).length;
    return (pheromone + enemyCount * 0.2).clamp(0.0, 1.0);
  }
}
