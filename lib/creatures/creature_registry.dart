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
  final Map<int, _ColonyRuntimeTracker> _runtimeTrackers = {};
  final Map<int, int> _lastRenderedCounts = {};
  final List<Map<String, Object?>> _visibilityDiagnostics =
      <Map<String, Object?>>[];
  int _nextColonyId = 0;
  int _tickCount = 0;
  int _visibilityFailureCount = 0;
  static const int _visibilityFailureThresholdTicks = 45;

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
  Colony spawn(
    int x,
    int y, {
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
    _runtimeTrackers[colony.id] = _ColonyRuntimeTracker();
    return colony;
  }

  /// Advance all colonies by one tick.
  void tick(SimulationEngine sim) {
    _tickCount++;
    // Pass the full colony list so each colony can detect enemies.
    for (final colony in _colonies) {
      colony.tick(sim, _colonies);
      final tracker = _runtimeTrackers.putIfAbsent(
        colony.id,
        _ColonyRuntimeTracker.new,
      );
      final rendered = _lastRenderedCounts[colony.id] ?? 0;
      tracker.observe(colony: colony, renderedCount: rendered);
      if (tracker.zeroVisibleTicks == _visibilityFailureThresholdTicks) {
        _visibilityFailureCount++;
        _visibilityDiagnostics.add(<String, Object?>{
          'tick': _tickCount,
          'severity': 'high',
          'reason': 'visible_ants_zero_with_colony_present',
          'colony_id': colony.id,
          'species': colony.species.name,
          'population': colony.population,
          'rendered_count': rendered,
          'spawn_attempted': colony.spawnAttempts,
          'spawn_succeeded': colony.spawnSucceeded,
          'health_state': colony.healthState.name,
        });
      }
    }

    // Prune dead colonies.
    _colonies.removeWhere((c) {
      if (!c.isAlive) {
        _colonyAIs.remove(c.id);
        _runtimeTrackers.remove(c.id);
        _lastRenderedCounts.remove(c.id);
        return true;
      }
      return false;
    });
  }

  void reportRenderedCounts(Map<int, int> renderedByColony) {
    _lastRenderedCounts
      ..clear()
      ..addAll(renderedByColony);
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
      _colonyAIs[colony.id] = AntColonyAI(
        colony: colony,
        rng: Random(colony.id),
      );
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
      final dist = (x - colony.originX).abs() + (y - colony.originY).abs();
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
      _runtimeTrackers.remove(colonyId);
      _lastRenderedCounts.remove(colonyId);
    }
  }

  /// Clear all colonies.
  void clear() {
    for (final colony in _colonies) {
      colony.exterminate();
    }
    _colonies.clear();
    _colonyAIs.clear();
    _runtimeTrackers.clear();
    _lastRenderedCounts.clear();
    _visibilityDiagnostics.clear();
    _tickCount = 0;
    _visibilityFailureCount = 0;
  }

  /// Get all living ants across all colonies (for rendering).
  Iterable<Ant> get allAnts sync* {
    for (final colony in _colonies) {
      for (final ant in colony.ants) {
        if (ant.alive) yield ant;
      }
    }
  }

  CreatureRuntimeSnapshot runtimeSnapshot() {
    final colonies = <Map<String, Object?>>[];
    int totalAlive = 0;
    int totalRendered = 0;
    int totalSpawnAttempts = 0;
    int totalSpawnSuccess = 0;
    int totalThinkTicks = 0;
    int totalMinimalTicks = 0;
    int totalQueenAliveTicks = 0;
    int totalQueenDeadTicks = 0;
    final deathCauseTotals = <String, int>{};

    for (final colony in _colonies) {
      totalAlive += colony.population;
      totalRendered += _lastRenderedCounts[colony.id] ?? 0;
      totalSpawnAttempts += colony.spawnAttempts;
      totalSpawnSuccess += colony.spawnSucceeded;
      totalThinkTicks += colony.thinkTicks;
      totalMinimalTicks += colony.minimalTicks;
      totalQueenAliveTicks += colony.queenAliveTicks;
      totalQueenDeadTicks += colony.queenDeadTicks;
      for (final entry in colony.deathCauseCounts.entries) {
        deathCauseTotals[entry.key.name] =
            (deathCauseTotals[entry.key.name] ?? 0) + entry.value;
      }
      final tracker = _runtimeTrackers[colony.id];
      final counters = colony.runtimeCounters();
      counters['colony_id'] = colony.id;
      counters['species'] = colony.species.name;
      counters['population_alive'] = colony.population;
      counters['rendered_count'] = _lastRenderedCounts[colony.id] ?? 0;
      counters['zero_visible_ticks'] = tracker?.zeroVisibleTicks ?? 0;
      counters['visibility_failures'] = tracker?.visibilityFailures ?? 0;
      colonies.add(counters);
    }

    final spawnSuccessRate = totalSpawnAttempts == 0
        ? 1.0
        : totalSpawnSuccess / totalSpawnAttempts;
    final queenAliveRatio = (totalQueenAliveTicks + totalQueenDeadTicks) == 0
        ? 1.0
        : totalQueenAliveTicks / (totalQueenAliveTicks + totalQueenDeadTicks);

    final healthTimeline = <String, int>{};
    for (final colony in _colonies) {
      final key = colony.healthState.name;
      healthTimeline[key] = (healthTimeline[key] ?? 0) + 1;
    }

    return CreatureRuntimeSnapshot(
      tick: _tickCount,
      colonyCount: _colonies.length,
      populationAlive: totalAlive,
      populationRendered: totalRendered,
      spawnAttempted: totalSpawnAttempts,
      spawnSucceeded: totalSpawnSuccess,
      spawnSuccessRate: spawnSuccessRate,
      thinkTicks: totalThinkTicks,
      minimalTicks: totalMinimalTicks,
      queenAliveRatio: queenAliveRatio,
      visibilityFailures: _visibilityFailureCount,
      deathCauses: deathCauseTotals,
      healthStateCounts: healthTimeline,
      diagnostics: List<Map<String, Object?>>.from(_visibilityDiagnostics),
      colonies: colonies,
    );
  }
}

class _ColonyRuntimeTracker {
  int zeroVisibleTicks = 0;
  int visibilityFailures = 0;

  void observe({required Colony colony, required int renderedCount}) {
    if (colony.population > 0 && renderedCount <= 0) {
      zeroVisibleTicks++;
      if (zeroVisibleTicks >
          CreatureRegistry._visibilityFailureThresholdTicks) {
        visibilityFailures++;
      }
    } else {
      zeroVisibleTicks = 0;
    }
  }
}

class CreatureRuntimeSnapshot {
  const CreatureRuntimeSnapshot({
    required this.tick,
    required this.colonyCount,
    required this.populationAlive,
    required this.populationRendered,
    required this.spawnAttempted,
    required this.spawnSucceeded,
    required this.spawnSuccessRate,
    required this.thinkTicks,
    required this.minimalTicks,
    required this.queenAliveRatio,
    required this.visibilityFailures,
    required this.deathCauses,
    required this.healthStateCounts,
    required this.diagnostics,
    required this.colonies,
  });

  final int tick;
  final int colonyCount;
  final int populationAlive;
  final int populationRendered;
  final int spawnAttempted;
  final int spawnSucceeded;
  final double spawnSuccessRate;
  final int thinkTicks;
  final int minimalTicks;
  final double queenAliveRatio;
  final int visibilityFailures;
  final Map<String, int> deathCauses;
  final Map<String, int> healthStateCounts;
  final List<Map<String, Object?>> diagnostics;
  final List<Map<String, Object?>> colonies;

  Map<String, Object?> toJson() => <String, Object?>{
    'tick': tick,
    'colony_count': colonyCount,
    'creature_population_alive': populationAlive,
    'creature_population_rendered': populationRendered,
    'creature_spawn_attempted': spawnAttempted,
    'creature_spawn_succeeded': spawnSucceeded,
    'creature_spawn_success_rate': spawnSuccessRate,
    'creature_tick_think_count': thinkTicks,
    'creature_tick_minimal_count': minimalTicks,
    'creature_queen_alive_ratio': queenAliveRatio,
    'creature_visibility_failures': visibilityFailures,
    'death_causes': deathCauses,
    'health_state_counts': healthStateCounts,
    'diagnostics': diagnostics,
    'colonies': colonies,
  };
}
