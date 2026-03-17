import '../../utils/math_helpers.dart';
import '../ant.dart';

/// Nurse behaviour heuristics for ants with the nurse role.
///
/// Nurses stay inside or near the nest and focus on colony maintenance:
/// - Feed low-energy ants by sharing carried food.
/// - Stay near the queen (nest entrance) to maintain colony cohesion.
/// - Distribute food from the colony stores to hungry workers.
///
/// Nurses are critical for colony survival — without them, foragers
/// and explorers die of starvation before returning to the nest.
class NurseBehavior {
  NurseBehavior._();

  /// Find the weakest ally ant nearby that needs food.
  ///
  /// Returns the ant with the lowest energy within the given radius,
  /// or null if all nearby ants are healthy.
  static Ant? findHungriestAlly(
    List<Ant> colonyAnts,
    int x,
    int y,
    int radius,
  ) {
    Ant? weakest;
    double lowestEnergy = 0.5; // Only feed ants below 50% energy.

    for (final ant in colonyAnts) {
      if (!ant.alive) continue;
      final dist = MathHelpers.manhattan(x, y, ant.x, ant.y);
      if (dist > radius) continue;
      if (ant.energy < lowestEnergy) {
        lowestEnergy = ant.energy;
        weakest = ant;
      }
    }

    return weakest;
  }

  /// Suggest a movement direction for a nurse.
  ///
  /// Nurses orbit close to the nest entrance, occasionally moving toward
  /// hungry ants to feed them.
  static (int, int) suggestMove(
    int x,
    int y,
    int nestX,
    int nestY,
    Ant? targetAnt,
  ) {
    // If there's a hungry ant to feed, move toward it.
    if (targetAnt != null) {
      return ((targetAnt.x - x).sign, (targetAnt.y - y).sign);
    }

    // Otherwise, stay near the nest.
    final dist = MathHelpers.manhattan(x, y, nestX, nestY);
    if (dist > 5) {
      // Move back toward nest.
      return ((nestX - x).sign, (nestY - y).sign);
    }

    // Wander within nest area.
    if (MathHelpers.chance(0.3)) {
      return (MathHelpers.randomInt(3) - 1, MathHelpers.randomInt(3) - 1);
    }

    return (0, 0);
  }

  /// Transfer energy from a nurse (or colony food stores) to a hungry ant.
  ///
  /// The nurse doesn't actually carry food — it acts as a conduit from
  /// the colony's food stores to the hungry ant.
  static bool feedAnt(Ant target, {required int foodStored}) {
    if (foodStored <= 0) return false;
    if (!target.alive) return false;
    if (target.energy >= 0.8) return false; // Already well-fed.

    target.energy = (target.energy + 0.15).clamp(0.0, 1.0);
    return true; // Colony should decrement foodStored by 1.
  }
}
