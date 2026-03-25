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
/// - Nurse task assignment for brood feeding.
class AntColonyAI {
  AntColonyAI({required this.colony, required this.rng});

  final Colony colony;
  final Random rng;

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

    // If food is critically low, convert some scouts to workers.
    if (colony.foodStored < 10 && total > 3) {
      final workerRatio = (dist[AntRole.worker] ?? 0) / total;
      if (workerRatio < 0.6) {
        for (final ant in colony.ants) {
          if (ant.role == AntRole.scout || ant.role == AntRole.idle) {
            ant.role = AntRole.worker;
            break;
          }
        }
      }
    }

    // If danger detected near nest, boost soldiers.
    final dangerAtNest = colony.dangerPheromones.read(
      colony.originX,
      colony.originY,
    );
    if (dangerAtNest > 0.3 && total > 5) {
      final soldierRatio = (dist[AntRole.soldier] ?? 0) / total;
      if (soldierRatio < 0.3) {
        for (final ant in colony.ants) {
          if (ant.role == AntRole.scout) {
            ant.role = AntRole.soldier;
            break;
          }
        }
      }
    }

    // If larvae need feeding and no nurses, reassign a worker.
    if (colony.larvaeCount > 0 && (dist[AntRole.nurse] ?? 0) == 0 && total > 3) {
      for (final ant in colony.ants) {
        if (ant.role == AntRole.worker) {
          ant.role = AntRole.nurse;
          break;
        }
      }
    }
  }

  Map<String, double>? getAntDecision(SimulationEngine sim, int x, int y) {
    final dist = (x - colony.originX).abs() + (y - colony.originY).abs();
    if (dist > 80) return null;

    final cellIdx = y * sim.gridW + x;
    final lifeVal = sim.life[cellIdx];
    final energy = lifeVal > 0 ? (lifeVal / 255.0).clamp(0.0, 1.0) : 0.5;

    final carrying = sim.velY[cellIdx] == antCarrierState;

    final nearbyAnts = sim.countNearby(x, y, 5, El.ant);

    if (colony.evolution.population.genomes.isEmpty) return null;
    final genomeIdx = colony.evolution.selectGenomeForSpawn(rng);
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

    if (sim.senseDanger(colony.originX, colony.originY, 5)) {
      colony.dangerPheromones.deposit(colony.originX, colony.originY, 1.0);
    }

    final waterNearNest = sim.countNearby(
      colony.originX,
      colony.originY,
      3,
      El.water,
    );
    if (waterNearNest > 5) {
      colony.dangerPheromones.deposit(colony.originX, colony.originY, 0.8);
    }
  }
}
