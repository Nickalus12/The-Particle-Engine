import '../simulation/element_registry.dart';
import '../simulation/simulation_engine.dart';
import 'ant.dart';
import 'colony.dart';

/// High-level AI director for a single ant colony.
///
/// Handles colony-level strategic decisions above individual ant brains:
/// - Role rebalancing based on colony needs.
/// - Emergency responses (flooding, fire near nest).
class AntColonyAI {
  AntColonyAI({required this.colony});

  final Colony colony;

  /// Run one tick of colony-level decision-making.
  void tick(SimulationEngine sim, List<Colony> allColonies) {
    colony.tick(sim, allColonies);

    if (colony.ageTicks % 120 == 0) {
      _rebalanceRoles();
    }

    if (colony.ageTicks % 30 == 0) {
      _detectEmergencies(sim);
    }
  }

  void _rebalanceRoles() {
    if (colony.ants.isEmpty) return;

    final dist = colony.roleDistribution;
    final total = colony.ants.length;
    if (total == 0) return;

    // If food is critically low, convert some explorers to foragers.
    if (colony.foodStored < 10 && total > 3) {
      final foragerRatio = (dist[AntRole.forager] ?? 0) / total;
      if (foragerRatio < 0.6) {
        for (final ant in colony.ants) {
          if (ant.role == AntRole.explorer || ant.role == AntRole.idle) {
            ant.role = AntRole.forager;
            break;
          }
        }
      }
    }

    // If danger detected near nest, boost defenders.
    final dangerAtNest = colony.dangerPheromones.read(
      colony.originX,
      colony.originY,
    );
    if (dangerAtNest > 0.3 && total > 5) {
      final defenderRatio = (dist[AntRole.defender] ?? 0) / total;
      if (defenderRatio < 0.3) {
        for (final ant in colony.ants) {
          if (ant.role == AntRole.explorer) {
            ant.role = AntRole.defender;
            break;
          }
        }
      }
    }
  }

  void _detectEmergencies(SimulationEngine sim) {
    if (!sim.inBoundsY(colony.originY)) return;

    // Use engine's sensing API for danger detection near nest.
    if (sim.senseDanger(colony.originX, colony.originY, 5)) {
      colony.dangerPheromones.deposit(colony.originX, colony.originY, 1.0);
    }

    // Check for flooding using engine's countNearby.
    final waterNearNest = sim.countNearby(
      colony.originX, colony.originY, 3, El.water,
    );
    if (waterNearNest > 5) {
      colony.dangerPheromones.deposit(colony.originX, colony.originY, 0.8);
    }
  }
}
