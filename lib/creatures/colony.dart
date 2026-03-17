import 'dart:math';

import '../simulation/element_registry.dart';
import '../simulation/simulation_engine.dart';
import '../utils/math_helpers.dart';
import 'ant.dart';
import 'neat/colony_evolution.dart';
import 'neat/neat_config.dart';
import 'pheromone_system.dart';

/// A living ant colony in the simulation.
///
/// Owns the actual [Ant] entities, three pheromone channels, the NEAT
/// evolutionary system, and all colony-level bookkeeping (food stores, nest
/// chambers, queen genome). Each tick, the colony:
///
/// 1. Ticks NEAT evolution (rt-NEAT replacement cycle).
/// 2. Spawns new ants when food allows.
/// 3. Ticks every living ant (staggered across frames for performance).
/// 4. Collects dead ants' fitness and reports back to NEAT.
/// 5. Decays pheromones.
/// 6. Updates colony state (food stored, population, etc.).
///
/// Multiple colonies coexist in the same sandbox and can war with each other.
class Colony {
  Colony({
    required this.originX,
    required this.originY,
    required this.id,
    int gridW = 320,
    int gridH = 180,
    int? seed,
  })  : _rng = Random(seed ?? (originX * 10000 + originY)),
        foodPheromones = PheromoneSystem(width: gridW, height: gridH),
        homePheromones = PheromoneSystem(width: gridW, height: gridH),
        dangerPheromones = PheromoneSystem(width: gridW, height: gridH),
        evolution = ColonyEvolution(
          config: const NeatConfig(),
          seed: seed,
        ) {
    evolution.initialize();
    // Deposit initial strong home pheromone at nest.
    homePheromones.deposit(originX, originY, 1.0);
  }

  // ---------------------------------------------------------------------------
  // Identity
  // ---------------------------------------------------------------------------

  final int id;
  final int originX;
  final int originY;
  final Random _rng;

  // ---------------------------------------------------------------------------
  // Pheromone channels
  // ---------------------------------------------------------------------------

  final PheromoneSystem foodPheromones;
  final PheromoneSystem homePheromones;
  final PheromoneSystem dangerPheromones;

  // ---------------------------------------------------------------------------
  // Evolution
  // ---------------------------------------------------------------------------

  final ColonyEvolution evolution;

  // ---------------------------------------------------------------------------
  // Ants
  // ---------------------------------------------------------------------------

  final List<Ant> ants = [];
  final List<Ant> _deadAntsQueue = [];

  int totalSpawned = 0;
  int totalDied = 0;

  // ---------------------------------------------------------------------------
  // Colony state
  // ---------------------------------------------------------------------------

  int foodStored = 20;
  int ageTicks = 0;

  bool get isAlive => ants.isNotEmpty || foodStored > 0 || ageTicks < 300;
  int get population => ants.length;

  // ---------------------------------------------------------------------------
  // Nest chambers
  // ---------------------------------------------------------------------------

  final Set<int> nestChambers = {};
  static const int nestRadius = 15;

  // ---------------------------------------------------------------------------
  // Staggered thinking
  // ---------------------------------------------------------------------------

  int _thinkOffset = 0;
  static const int _maxThinksPerTick = 50;

  // ---------------------------------------------------------------------------
  // Core tick
  // ---------------------------------------------------------------------------

  void tick(SimulationEngine sim, List<Colony> allColonies) {
    if (!isAlive) return;
    ageTicks++;

    evolution.tick();
    _maybeSpawnAnts(sim);
    _reinforceNestPheromone();
    _tickAnts(sim, allColonies);
    _processDeadAnts(sim);

    foodPheromones.decay();
    homePheromones.decay();
    dangerPheromones.decay();

    _collectNestFood(sim);
  }

  // ---------------------------------------------------------------------------
  // Spawning
  // ---------------------------------------------------------------------------

  void _maybeSpawnAnts(SimulationEngine sim) {
    if (foodStored < 5) return;
    if (ants.length >= 200) return;

    final spawnChance = ants.isEmpty ? 0.3 : (ants.length < 10 ? 0.08 : 0.02);
    if (!MathHelpers.chance(spawnChance)) return;

    final spawnPos = _findSpawnPosition(sim);
    if (spawnPos == null) return;

    final genomeIdx = evolution.selectGenomeForSpawn(_rng);
    final genome = evolution.population.genomes[genomeIdx];

    final (sx, sy) = spawnPos;
    final ant = Ant(
      x: sx,
      y: sy,
      colonyId: id,
      nestX: originX,
      nestY: originY,
      genomeIndex: genomeIdx,
      genome: genome,
      seed: _rng.nextInt(1 << 30),
    );

    ant.role = _selectRole();
    ants.add(ant);
    foodStored -= 5;
    totalSpawned++;
  }

  (int, int)? _findSpawnPosition(SimulationEngine sim) {
    if (_isSpawnable(sim, originX, originY)) return (originX, originY);
    for (var radius = 1; radius <= 5; radius++) {
      for (var dy = -radius; dy <= radius; dy++) {
        for (var dx = -radius; dx <= radius; dx++) {
          if (dx.abs() != radius && dy.abs() != radius) continue;
          final sx = originX + dx;
          final sy = originY + dy;
          if (_isSpawnable(sim, sx, sy)) return (sx, sy);
        }
      }
    }
    return null;
  }

  bool _isSpawnable(SimulationEngine sim, int px, int py) {
    px = sim.wrapX(px);
    if (!sim.inBoundsY(py)) return false;
    final el = sim.grid[py * sim.gridW + px];
    return el == El.empty || el == El.smoke || el == El.steam;
  }

  AntRole _selectRole() {
    if (ants.isEmpty) return AntRole.explorer;

    int explorers = 0, foragers = 0, builders = 0, defenders = 0;
    for (final ant in ants) {
      switch (ant.role) {
        case AntRole.explorer:
          explorers++;
        case AntRole.forager:
          foragers++;
        case AntRole.builder:
          builders++;
        case AntRole.defender:
          defenders++;
        case AntRole.nurse:
        case AntRole.idle:
          break;
      }
    }

    final total = ants.length;
    final explorerNeed = 0.20 - (explorers / (total + 1));
    final foragerNeed = 0.50 - (foragers / (total + 1));
    final builderNeed = 0.15 - (builders / (total + 1));
    final defenderNeed = 0.15 - (defenders / (total + 1));

    final maxNeed = [explorerNeed, foragerNeed, builderNeed, defenderNeed]
        .reduce((a, b) => a > b ? a : b);

    if (maxNeed == explorerNeed) return AntRole.explorer;
    if (maxNeed == foragerNeed) return AntRole.forager;
    if (maxNeed == builderNeed) return AntRole.builder;
    return AntRole.defender;
  }

  // ---------------------------------------------------------------------------
  // Ant ticking (staggered)
  // ---------------------------------------------------------------------------

  void _tickAnts(SimulationEngine sim, List<Colony> allColonies) {
    if (ants.isEmpty) return;

    final enemies = <Ant>[];
    for (final other in allColonies) {
      if (other.id == id) continue;
      enemies.addAll(other.ants.where((a) => a.alive));
    }

    final totalAnts = ants.length;
    final thinksThisTick = totalAnts <= _maxThinksPerTick
        ? totalAnts
        : _maxThinksPerTick;

    for (var i = 0; i < totalAnts; i++) {
      final ant = ants[i];
      if (!ant.alive) continue;

      final shouldThink =
          totalAnts <= _maxThinksPerTick ||
          (i >= _thinkOffset && i < _thinkOffset + thinksThisTick) ||
          (i < (_thinkOffset + thinksThisTick) - totalAnts);

      if (shouldThink) {
        final nearbyEnemies = _findNearbyEnemies(ant, enemies);
        final survived = ant.tick(
          sim: sim,
          foodPheromones: foodPheromones,
          homePheromones: homePheromones,
          dangerPheromones: dangerPheromones,
          nearbyEnemies: nearbyEnemies,
        );
        if (!survived) {
          _deadAntsQueue.add(ant);
        }
      } else {
        _minimalTick(ant, sim);
      }
    }

    _thinkOffset = (_thinkOffset + thinksThisTick) % (totalAnts > 0 ? totalAnts : 1);
    ants.removeWhere((a) => !a.alive);
  }

  void _minimalTick(Ant ant, SimulationEngine sim) {
    if (!ant.alive) return;
    ant.age++;
    ant.energy -= Ant.baseCost;

    if (ant.energy <= 0.0) {
      ant.kill(DeathCause.starvation);
      _deadAntsQueue.add(ant);
      return;
    }

    if (ant.age >= Ant.maxAge) {
      ant.kill(DeathCause.oldAge);
      _deadAntsQueue.add(ant);
      return;
    }

    // Check environmental hazards at current position.
    if (sim.inBoundsY(ant.y)) {
      ant.x = sim.wrapX(ant.x);
      final element = sim.grid[ant.y * sim.gridW + ant.x];
      if (element == El.acid) {
        ant.kill(DeathCause.dissolved);
        _deadAntsQueue.add(ant);
        return;
      }
      if (element == El.lava) {
        ant.kill(DeathCause.burned);
        _deadAntsQueue.add(ant);
        return;
      }

      // Apply gravity.
      if (ant.y < sim.gridH - 1) {
        final below = sim.grid[(ant.y + 1) * sim.gridW + ant.x];
        if (below == El.empty) {
          ant.y++;
        }
      }
    }

    ant.fitness.tickSurvived();
  }

  List<Ant> _findNearbyEnemies(Ant ant, List<Ant> allEnemies) {
    const detectionRange = 10;
    final nearby = <Ant>[];
    for (final enemy in allEnemies) {
      if (!enemy.alive) continue;
      final dist = MathHelpers.manhattan(ant.x, ant.y, enemy.x, enemy.y);
      if (dist <= detectionRange) {
        nearby.add(enemy);
      }
    }
    return nearby;
  }

  // ---------------------------------------------------------------------------
  // Dead ant processing
  // ---------------------------------------------------------------------------

  void _processDeadAnts([SimulationEngine? sim]) {
    for (final dead in _deadAntsQueue) {
      evolution.reportFitness(dead.genomeIndex, dead.fitness.score);
      totalDied++;

      // Dead ant decomposes into dirt (ecosystem nutrient cycle).
      if (sim != null) {
        final ax = sim.wrapX(dead.x);
        final ay = dead.y;
        if (sim.inBoundsY(ay)) {
          final di = ay * sim.gridW + ax;
          if (sim.grid[di] == El.empty) {
            sim.grid[di] = El.dirt;
            sim.life[di] = 2; // Pre-moistened from decomposition.
            sim.markDirty(ax, ay);
          }
        }
      }
    }
    _deadAntsQueue.clear();
  }

  // ---------------------------------------------------------------------------
  // Nest management
  // ---------------------------------------------------------------------------

  void _reinforceNestPheromone() {
    homePheromones.deposit(originX, originY, 0.5);
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        homePheromones.deposit(originX + dx, originY + dy, 0.2);
      }
    }
  }

  void _collectNestFood(SimulationEngine sim) {
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        final nx = sim.wrapX(originX + dx);
        final ny = originY + dy;
        if (!sim.inBoundsY(ny)) continue;
        final idx = ny * sim.gridW + nx;
        final el = sim.grid[idx];
        if (el != El.empty && el < maxElements &&
            (elCategory[el] & ElCat.organic != 0) &&
            (elCategory[el] & ElCat.flammable != 0)) {
          sim.grid[idx] = El.empty;
          sim.life[idx] = 0;
          sim.markDirty(nx, ny);
          foodStored++;
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Colony death
  // ---------------------------------------------------------------------------

  void exterminate() {
    for (final ant in ants) {
      ant.kill(DeathCause.colonyDeath);
    }
    _processDeadAnts();
    ants.clear();
    foodStored = 0;
  }

  // ---------------------------------------------------------------------------
  // Stats
  // ---------------------------------------------------------------------------

  double get averageAntFitness {
    if (ants.isEmpty) return 0.0;
    double total = 0.0;
    for (final ant in ants) {
      total += ant.fitness.score;
    }
    return total / ants.length;
  }

  double get averageAntAge {
    if (ants.isEmpty) return 0.0;
    int total = 0;
    for (final ant in ants) {
      total += ant.age;
    }
    return total / ants.length;
  }

  int get antsCarryingFood => ants.where((a) => a.carryingFood).length;

  Map<AntRole, int> get roleDistribution {
    final dist = <AntRole, int>{};
    for (final role in AntRole.values) {
      dist[role] = 0;
    }
    for (final ant in ants) {
      dist[ant.role] = (dist[ant.role] ?? 0) + 1;
    }
    return dist;
  }
}
