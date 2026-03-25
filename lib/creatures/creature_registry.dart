import 'dart:math';

import '../models/game_state.dart';
import '../simulation/simulation_engine.dart';
import 'ant.dart';
import 'ant_colony_ai.dart';
import 'colony.dart';

/// Tracks all living creature colonies and ticks them each frame.
///
/// New colonies are added when the player places a "colony" element in the
/// sandbox. Dead colonies (population == 0 && food == 0 after grace period)
/// are pruned automatically.
///
/// The registry owns the colony list and serves as the main entry point for
/// the creature simulation subsystem.
///
/// ## Performance model
///
/// Each colony caps neural network forward passes at 50 per tick. With
/// 4 colonies that's 200 forward passes per tick, well within the ~0.5ms
/// budget for 1000 ants at 30fps. The registry distributes colony ticks
/// evenly across frames to avoid spikes.
class CreatureRegistry {
  final List<Colony> _colonies = [];
  final Map<int, AntColonyAI> _colonyAIs = {};
  int _nextColonyId = 0;

  /// All currently active colonies.
  List<Colony> get colonies => List.unmodifiable(_colonies);

  /// Total living ants across all colonies.
  int get totalAnts {
    int count = 0;
    for (final colony in _colonies) {
      count += colony.population;
    }
    return count;
  }

  /// Spawn a new colony at the given grid position.
  ///
  /// Grid dimensions are passed through so that pheromone systems are
  /// allocated at the correct size.
  Colony spawn(int x, int y, {
    CreatureSpecies species = CreatureSpecies.ant,
    int? seed,
    int gridW = 320,
    int gridH = 180,
    Random? rng,
  }) {
    final colony = Colony(
      originX: x,
      originY: y,
      id: _nextColonyId++,
      species: species,
      gridW: gridW,
      gridH: gridH,
      seed: seed,
    );
    _colonies.add(colony);
    _colonyAIs[colony.id] = AntColonyAI(colony: colony, rng: rng ?? Random());
    return colony;
  }

  /// Advance all colonies by one tick.
  void tick(SimulationEngine sim) {
    // Pass the full colony list so each colony can detect enemies.
    for (final colony in _colonies) {
      colony.tick(sim, _colonies);
    }

    // Prune dead colonies.
    _colonies.removeWhere((c) {
      if (!c.isAlive) {
        _colonyAIs.remove(c.id);
        return true;
      }
      return false;
    });
  }

  /// Restore colonies from serialized save snapshots.
  void restoreFromSnapshots(
    List<ColonySnapshot> snapshots, {
    required int gridW,
    required int gridH,
  }) {
    clear();

    var maxId = -1;
    for (final snapshot in snapshots) {
      final colony = Colony(
        originX: snapshot.originX,
        originY: snapshot.originY,
        id: snapshot.id,
        species: snapshot.speciesEnum,
        gridW: gridW,
        gridH: gridH,
      );

      if (snapshot.genomes.isNotEmpty) {
        colony.evolution.restorePopulation(snapshot.genomes);
      }

      colony.foodStored = snapshot.foodStored;
      colony.ageTicks = snapshot.ageTicks;
      colony.totalSpawned = snapshot.totalSpawned;
      colony.totalDied = snapshot.totalDied;
      colony.eggsCount = snapshot.eggsCount;
      colony.larvaeCount = snapshot.larvaeCount;
      colony.larvaeFood = snapshot.larvaeFood;
      colony.isOrphaned = snapshot.isOrphaned;
      colony.orphanTicks = snapshot.orphanTicks;
      colony.nestChambers
        ..clear()
        ..addAll(snapshot.nestChambers);

      for (final antSnapshot in snapshot.ants) {
        final int genomeIdx = snapshot.genomes.isEmpty
            ? 0
            : antSnapshot.genomeIndex
                .clamp(0, snapshot.genomes.length - 1)
                .toInt();
        final genome = colony.evolution.population.genomes[genomeIdx];
        final ant = Ant(
          x: antSnapshot.x,
          y: antSnapshot.y,
          colonyId: colony.id,
          nestX: colony.originX,
          nestY: colony.originY,
          genomeIndex: genomeIdx,
          genome: genome,
          species: colony.species,
        );
        ant.energy = antSnapshot.energy;
        ant.age = antSnapshot.age;
        ant.carryingFood = antSnapshot.carryingFood;
        ant.carriedFoodType = antSnapshot.carriedFoodType;
        ant.carryingDirt = antSnapshot.carryingDirt;
        ant.role = antSnapshot.roleEnum;
        ant.phenotype = colony.makePhenotype(genome, role: ant.role);
        if (ant.role == AntRole.queen) {
          colony.queen = ant;
        }
        colony.ants.add(ant);
      }

      _colonies.add(colony);
      _colonyAIs[colony.id] = AntColonyAI(colony: colony, rng: Random(colony.id));
      if (colony.id > maxId) maxId = colony.id;
    }

    _nextColonyId = maxId + 1;
  }

  /// Query neural decision for a cell-based ant at grid position (x, y).
  ///
  /// Finds the nearest colony and asks its AI director for a NEAT-driven
  /// decision. Returns null if no colony is in range.
  Map<String, double>? queryAntDecision(SimulationEngine sim, int x, int y) {
    // Find closest colony to this ant.
    Colony? best;
    int bestDist = 999999;
    for (final colony in _colonies) {
      final dist =
          (x - colony.originX).abs() + (y - colony.originY).abs();
      if (dist < bestDist) {
        bestDist = dist;
        best = colony;
      }
    }
    if (best == null || bestDist > 80) return null;
    final ai = _colonyAIs[best.id];
    if (ai == null) return null;
    return ai.getAntDecision(sim, x, y);
  }

  /// Find all ants from all colonies near a given position.
  /// Useful for rendering and hit-testing.
  List<Ant> antsNear(int x, int y, int radius) {
    final result = <Ant>[];
    for (final colony in _colonies) {
      for (final ant in colony.ants) {
        if (!ant.alive) continue;
        final dx = (ant.x - x).abs();
        final dy = (ant.y - y).abs();
        if (dx <= radius && dy <= radius) {
          result.add(ant);
        }
      }
    }
    return result;
  }

  /// Get the colony at a specific position (if any).
  Colony? colonyAt(int x, int y) {
    for (final colony in _colonies) {
      if (colony.originX == x && colony.originY == y) return colony;
    }
    return null;
  }

  /// Find the colony a specific ant belongs to.
  Colony? colonyForAnt(Ant ant) {
    for (final colony in _colonies) {
      if (colony.id == ant.colonyId) return colony;
    }
    return null;
  }

  /// Remove a colony by ID.
  void removeColony(int colonyId) {
    final colony = _colonies.where((c) => c.id == colonyId).firstOrNull;
    if (colony != null) {
      colony.exterminate();
      _colonies.remove(colony);
      _colonyAIs.remove(colonyId);
    }
  }

  /// Clear all colonies.
  void clear() {
    for (final colony in _colonies) {
      colony.exterminate();
    }
    _colonies.clear();
    _colonyAIs.clear();
  }

  /// Get all living ants across all colonies (for rendering).
  Iterable<Ant> get allAnts sync* {
    for (final colony in _colonies) {
      for (final ant in colony.ants) {
        if (ant.alive) yield ant;
      }
    }
  }
}
