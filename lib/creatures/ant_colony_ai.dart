import 'dart:math';

import '../simulation/element_registry.dart';
import '../simulation/simulation_engine.dart';
import 'ant.dart';
import 'colony.dart';
import 'neat/ant_brain.dart';

/// High-level AI director for a single ant colony.
///
/// Handles colony-level strategic decisions above individual ant brains:
/// - Role rebalancing based on colony needs.
/// - Emergency responses (flooding, fire near nest).
class AntColonyAI {
  AntColonyAI({required this.colony});

  final Colony colony;
  final Random _rng = Random();

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

  /// Query neural decision for a cell-based ant at (x, y).
  ///
  /// Returns a map of output signals if the ant is within colony range,
  /// or null if no colony manages this position. Used by the cell-based
  /// simAnt() to get NEAT-driven decisions that override hardcoded behavior.
  Map<String, double>? getAntDecision(SimulationEngine sim, int x, int y) {
    // Only manage ants within reasonable range of colony nest.
    final dist = (x - colony.originX).abs() + (y - colony.originY).abs();
    if (dist > 80) return null;

    // Energy approximation from cell life value (higher = healthier).
    final cellIdx = y * sim.gridW + x;
    final lifeVal = sim.life[cellIdx];
    final energy = lifeVal > 0 ? (lifeVal / 255.0).clamp(0.0, 1.0) : 0.5;

    // Check if carrying (carrier state).
    final carrying = sim.velY[cellIdx] == antCarrierState;

    // Count nearby ants to estimate enemies.
    final nearbyAnts = sim.countNearby(x, y, 5, El.ant);

    // Pick a representative genome to run the brain.
    if (colony.evolution.population.genomes.isEmpty) return null;
    final genomeIdx = colony.evolution.selectGenomeForSpawn(_rng);
    final genome = colony.evolution.population.genomes[genomeIdx];
    final brain = AntBrain(genome: genome);

    final action = brain.think(
      sim: sim,
      antX: x,
      antY: y,
      nestX: colony.originX,
      nestY: colony.originY,
      energy: energy,
      carryingFood: carrying,
      foodPheromones: colony.foodPheromones,
      homePheromones: colony.homePheromones,
      dangerPheromones: colony.dangerPheromones,
      nearbyEnemyCount: nearbyAnts > 3 ? nearbyAnts - 3 : 0,
    );

    return {
      'dx': action.dx.toDouble(),
      'dy': action.dy.toDouble(),
      'pheromone': action.pheromoneStrength,
      'pickup': action.wantsPickUp ? 1.0 : 0.0,
      'drop': action.wantsDrop ? 1.0 : 0.0,
      'attack': action.wantsAttack ? 1.0 : 0.0,
    };
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
