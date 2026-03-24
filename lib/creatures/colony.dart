import 'dart:math';

import '../simulation/element_registry.dart';
import '../simulation/simulation_engine.dart';
import '../utils/math_helpers.dart';
import 'ant.dart';
import 'creature_phenotype.dart';
import 'genome_library.dart';
import 'neat/colony_evolution.dart';
import 'neat/neat_config.dart';
import 'pheromone_system.dart';

/// A living ant colony — a superorganism with queen, castes, brood, and nest.
///
/// The colony is not a collection of individuals — it's a single organism with
/// distributed intelligence. The queen is the reproductive organ, workers are
/// the limbs, soldiers are the immune system, the nest is the body.
///
/// Lifecycle:
/// 1. Colony placed → queen spawns as first ant.
/// 2. Queen lays eggs based on food supply.
/// 3. Nurses feed larvae → larvae mature into adults.
/// 4. Workers forage and dig tunnels. Soldiers patrol.
/// 5. If queen dies → orphan mode → colony slowly dies.
class Colony {
  Colony({
    required this.originX,
    required this.originY,
    required this.id,
    this.species = CreatureSpecies.ant,
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
        ),
        colonyHue = ((id * 2654435761) >> 16) & 0xFF {
    evolution.initialize();
    _computeColonyColor();
    _seedFromLibrary();
    homePheromones.deposit(originX, originY, 1.0);
  }

  void _computeColonyColor() {
    final h = ((colonyHue + colonyHueDrift) & 0xFF);
    final (r, g, b) = hsvToRgb(h, colonySaturation, 220);
    colonyBaseR = r;
    colonyBaseG = g;
    colonyBaseB = b;
  }

  static (int, int, int) hsvToRgb(int h256, int s256, int v256) {
    final region = (h256 * 6) >> 8;
    final remainder = (h256 * 6) - (region << 8);
    final p = (v256 * (255 - s256)) >> 8;
    final q = (v256 * (255 - (s256 * remainder >> 8))) >> 8;
    final t = (v256 * (255 - (s256 * (255 - remainder) >> 8))) >> 8;
    switch (region) {
      case 0:
        return (v256, t, p);
      case 1:
        return (q, v256, p);
      case 2:
        return (p, v256, t);
      case 3:
        return (p, q, v256);
      case 4:
        return (t, p, v256);
      default:
        return (v256, p, q);
    }
  }

  void _seedFromLibrary() {
    final lib = GenomeLibrary.instance;
    final speciesName = species.name; // 'ant', 'worm', 'beetle', etc.
    if (!lib.hasGenomes(speciesName)) return;
    final pop = evolution.population.genomes;
    final seedCount = pop.length ~/ 2;
    for (var i = 0; i < seedCount; i++) {
      final trained = lib.pickGenome(speciesName, perturbation: 0.05);
      if (trained != null) {
        pop[i] = trained;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Identity
  // ---------------------------------------------------------------------------

  final int id;
  final CreatureSpecies species;
  int originX;
  int originY;
  final Random _rng;

  // ---------------------------------------------------------------------------
  // Colony visual identity
  // ---------------------------------------------------------------------------

  final int colonyHue;
  int colonySaturation = 200;
  int colonyBaseR = 0;
  int colonyBaseG = 0;
  int colonyBaseB = 0;
  int colonyHueDrift = 0;
  int _driftGenerationCounter = 0;

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
  // Queen state
  // ---------------------------------------------------------------------------

  /// Reference to the colony's queen ant (null if dead or not yet spawned).
  Ant? queen;

  /// Whether the queen has died — colony enters orphan mode.
  bool isOrphaned = false;

  /// Ticks since queen died (orphan timer).
  int orphanTicks = 0;

  // ---------------------------------------------------------------------------
  // Brood system (eggs → larvae → adults)
  // ---------------------------------------------------------------------------

  /// Number of eggs waiting to hatch.
  int eggsCount = 0;

  /// Number of larvae waiting to mature.
  int larvaeCount = 0;

  /// Food delivered to larvae by nurses (accumulates toward maturation).
  int larvaeFood = 0;

  /// Tick counters for egg/larvae maturation.
  int _eggTimer = 0;
  int _larvaTimer = 0;

  // ---------------------------------------------------------------------------
  // Colony state
  // ---------------------------------------------------------------------------

  int foodStored = 20;
  int ageTicks = 0;

  bool get isAlive =>
      ants.isNotEmpty || foodStored > 0 || ageTicks < 300 || eggsCount > 0;
  int get population => ants.length;
  bool get hasQueen => queen != null && queen!.alive;

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
    _driftGenerationCounter++;
    if (_driftGenerationCounter >= 10) {
      _driftGenerationCounter = 0;
      colonyHueDrift += _rng.nextBool() ? 1 : -1;
      _computeColonyColor();
    }

    // Queen management: only ant colonies have queens.
    if (species == CreatureSpecies.ant) {
      if (queen == null && !isOrphaned && ageTicks <= 60) {
        _spawnQueen(sim);
      }
    }

    // Orphan tracking (ant colonies only).
    if (isOrphaned && species == CreatureSpecies.ant) {
      orphanTicks++;
      // Orphan ants slowly die of "despair" — colony deteriorates.
      if (_rng.nextInt(SimTuning.orphanDecayRate) == 0 && ants.isNotEmpty) {
        final victim = ants[_rng.nextInt(ants.length)];
        if (victim.role != AntRole.queen) {
          victim.energy -= 0.1;
        }
      }
    }

    // Queen/brood pipeline for ant colonies; flat spawning for other species.
    if (species == CreatureSpecies.ant) {
      _queenLayEggs();
      _tickBrood(sim);
      _maybeSpawnAnts(sim);
    } else {
      _maybeSpawnCreatures(sim);
    }

    _reinforceNestPheromone();
    _tickAnts(sim, allColonies);
    _processDeadAnts(sim);

    if (ageTicks % SimTuning.colonyMigrationInterval == 0) {
      _updateDynamicOrigin(sim);
    }

    foodPheromones.decay();
    homePheromones.decay();
    dangerPheromones.decay();

    _collectNestFood(sim);
  }

  // ---------------------------------------------------------------------------
  // Queen spawning
  // ---------------------------------------------------------------------------

  void _spawnQueen(SimulationEngine sim) {
    final spawnPos = _findSpawnPosition(sim);
    if (spawnPos == null) return;

    final genomeIdx = evolution.selectGenomeForSpawn(_rng);
    final genome = evolution.population.genomes[genomeIdx];

    final (sx, sy) = spawnPos;
    final queenAnt = Ant(
      x: sx,
      y: sy,
      colonyId: id,
      nestX: originX,
      nestY: originY,
      genomeIndex: genomeIdx,
      genome: genome,
      species: CreatureSpecies.ant,
      seed: _rng.nextInt(1 << 30),
    );

    queenAnt.role = AntRole.queen;
    queenAnt.energy = 1.0;
    // Queen phenotype: larger, distinctive.
    queenAnt.phenotype = CreaturePhenotype.forQueen(
      genome.behaviorVector,
      genome.connections.values.fold(0, (h, c) => h ^ c.weight.hashCode),
    );

    ants.add(queenAnt);
    queen = queenAnt;
    totalSpawned++;
  }

  // ---------------------------------------------------------------------------
  // Brood system
  // ---------------------------------------------------------------------------

  /// Queen lays eggs based on food supply and colony population.
  void _queenLayEggs() {
    if (!hasQueen) return;
    if (foodStored < SimTuning.queenFoodPerEgg) return;
    if (eggsCount + larvaeCount >= 20) return; // Brood cap.

    if (_rng.nextInt(SimTuning.queenEggRate) == 0) {
      eggsCount++;
      foodStored -= SimTuning.queenFoodPerEgg;
    }
  }

  /// Advance brood maturation: eggs → larvae → adults.
  void _tickBrood(SimulationEngine sim) {
    // Eggs hatch into larvae.
    if (eggsCount > 0) {
      _eggTimer++;
      if (_eggTimer >= SimTuning.eggHatchTicks) {
        _eggTimer = 0;
        eggsCount--;
        larvaeCount++;
      }
    }

    // Larvae mature into adults when fed enough.
    if (larvaeCount > 0) {
      _larvaTimer++;
      if (_larvaTimer >= SimTuning.larvaGrowTicks &&
          larvaeFood >= SimTuning.larvaFoodPerGrow) {
        _larvaTimer = 0;
        larvaeCount--;
        larvaeFood -= SimTuning.larvaFoodPerGrow;
        // Spawn a new adult ant from the brood.
        _spawnFromBrood(sim);
      }
    }
  }

  /// Spawn a new adult ant from a matured larva.
  void _spawnFromBrood(SimulationEngine sim) {
    if (ants.length >= 200) return;
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
      species: species,
      seed: _rng.nextInt(1 << 30),
    );

    ant.role = _selectRole();
    ant.phenotype = makePhenotype(genome, role: ant.role);
    ants.add(ant);
    totalSpawned++;
  }

  // ---------------------------------------------------------------------------
  // Legacy spawning (fallback when brood system hasn't kicked in yet)
  // ---------------------------------------------------------------------------

  void _maybeSpawnAnts(SimulationEngine sim) {
    // Once colony has a queen, all spawning goes through brood pipeline.
    if (hasQueen) return;
    if (isOrphaned) return;

    if (foodStored < 5) return;
    if (ants.length >= 200) return;

    final spawnChance = ants.isEmpty ? 0.3 : (ants.length < 10 ? 0.08 : 0.02);
    if (!MathHelpers.chance(spawnChance)) return;

    _spawnCreature(sim);
    foodStored -= 5;
  }

  /// Spawn creatures for non-ant species (flat spawn, no queen/brood).
  void _maybeSpawnCreatures(SimulationEngine sim) {
    if (foodStored < 3) return;
    // Species-specific population caps.
    final maxPop = species == CreatureSpecies.fish ? 30 : 50;
    if (ants.length >= maxPop) return;

    final spawnChance = ants.isEmpty ? 0.5 : (ants.length < 5 ? 0.1 : 0.03);
    if (!MathHelpers.chance(spawnChance)) return;

    _spawnCreature(sim);
    foodStored -= 3;
  }

  /// Spawn a single creature with the colony's species and correct phenotype.
  void _spawnCreature(SimulationEngine sim) {
    final spawnPos = _findSpawnPosition(sim);
    if (spawnPos == null) return;

    final genomeIdx = evolution.selectGenomeForSpawn(_rng);
    final genome = evolution.population.genomes[genomeIdx];

    final (sx, sy) = spawnPos;
    final creature = Ant(
      x: sx,
      y: sy,
      colonyId: id,
      nestX: originX,
      nestY: originY,
      genomeIndex: genomeIdx,
      genome: genome,
      species: species,
      seed: _rng.nextInt(1 << 30),
    );

    if (species == CreatureSpecies.ant) {
      creature.role = _selectRole();
    } else {
      creature.role = AntRole.worker; // Non-ant species use worker role.
    }
    creature.phenotype = makePhenotype(creature.brain.genome, role: creature.role);
    ants.add(creature);
    totalSpawned++;
  }

  /// Create the correct phenotype for this colony's species.
  CreaturePhenotype makePhenotype(dynamic genome, {AntRole? role}) {
    final behavior = genome.behaviorVector as List<double>?;
    final seed = genome.connections.values
        .fold<int>(0, (h, c) => h ^ c.weight.hashCode);
    if (role == AntRole.queen) {
      return CreaturePhenotype.forQueen(behavior, seed);
    }
    switch (species) {
      case CreatureSpecies.ant:
        return CreaturePhenotype.forAnt(behavior, seed);
      case CreatureSpecies.worm:
        return CreaturePhenotype.forWorm(behavior, seed);
      case CreatureSpecies.beetle:
        return CreaturePhenotype.forBeetle(behavior, seed);
      case CreatureSpecies.spider:
        return CreaturePhenotype.forSpider(behavior, seed);
      case CreatureSpecies.fish:
        return CreaturePhenotype.forFish(behavior, seed);
      case CreatureSpecies.bee:
        return CreaturePhenotype.forBee(behavior, seed);
      case CreatureSpecies.firefly:
        return CreaturePhenotype.forFirefly(behavior, seed);
    }
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
    // Fish must spawn in water.
    if (species == CreatureSpecies.fish) {
      return el == El.water;
    }
    return el == El.empty || el == El.smoke || el == El.steam;
  }

  /// Select caste for a new ant based on colony needs.
  /// Ratios: Worker 70%, Soldier 15%, Nurse 10%, Scout 5%.
  AntRole _selectRole() {
    if (ants.isEmpty) return AntRole.scout; // First non-queen ant explores.

    int workers = 0, soldiers = 0, nurses = 0, scouts = 0;
    for (final ant in ants) {
      switch (ant.role) {
        case AntRole.worker:
          workers++;
        case AntRole.soldier:
          soldiers++;
        case AntRole.nurse:
          nurses++;
        case AntRole.scout:
          scouts++;
        case AntRole.queen:
        case AntRole.idle:
          break;
      }
    }

    final total = ants.length;
    final workerNeed =
        SimTuning.casteWorkerRatio / 100.0 - (workers / (total + 1));
    final soldierNeed =
        SimTuning.casteSoldierRatio / 100.0 - (soldiers / (total + 1));
    final nurseNeed =
        SimTuning.casteNurseRatio / 100.0 - (nurses / (total + 1));
    final scoutNeed =
        SimTuning.casteScoutRatio / 100.0 - (scouts / (total + 1));

    final maxNeed = [workerNeed, soldierNeed, nurseNeed, scoutNeed]
        .reduce((a, b) => a > b ? a : b);

    if (maxNeed == workerNeed) return AntRole.worker;
    if (maxNeed == soldierNeed) return AntRole.soldier;
    if (maxNeed == nurseNeed) return AntRole.nurse;
    return AntRole.scout;
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

    _thinkOffset =
        (_thinkOffset + thinksThisTick) % (totalAnts > 0 ? totalAnts : 1);
    ants.removeWhere((a) => !a.alive);

    // Check if queen died this tick.
    if (queen != null && !queen!.alive && !isOrphaned) {
      isOrphaned = true;
      orphanTicks = 0;
      // Desaturate colony color to reflect decline.
      colonySaturation = 100;
      _computeColonyColor();
    }
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

    final effectiveMaxAge = ant.role == AntRole.queen
        ? SimTuning.queenMaxAge
        : Ant.maxAge;
    if (ant.age >= effectiveMaxAge) {
      ant.kill(DeathCause.oldAge);
      _deadAntsQueue.add(ant);
      return;
    }

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

      // Track queen death.
      if (dead.role == AntRole.queen) {
        queen = null;
      }

      if (sim != null) {
        final ax = sim.wrapX(dead.x);
        final ay = dead.y;
        if (sim.inBoundsY(ay)) {
          final di = ay * sim.gridW + ax;
          if (sim.grid[di] == El.empty) {
            sim.grid[di] = El.dirt;
            sim.life[di] = 2;
            sim.markDirty(ax, ay);
          }
        }
      }
    }
    _deadAntsQueue.clear();
  }

  // ---------------------------------------------------------------------------
  // Nurse feeding: nurses near nest deposit food into larvae pool
  // ---------------------------------------------------------------------------

  /// Called from ant tick when a nurse drops food near the nest.
  void nurseFeedLarvae() {
    if (larvaeCount > 0) {
      larvaeFood++;
    } else {
      // No larvae — food goes to colony stores.
      foodStored++;
    }
  }

  // ---------------------------------------------------------------------------
  // Nest management
  // ---------------------------------------------------------------------------

  void _updateDynamicOrigin(SimulationEngine sim) {
    if (ants.isEmpty) return;
    int sumX = 0;
    int sumY = 0;
    int count = 0;
    for (final ant in ants) {
      if (!ant.alive) continue;
      sumX += ant.x;
      sumY += ant.y;
      count++;
    }
    if (count == 0) return;

    final centroidX = sumX ~/ count;
    final centroidY = sumY ~/ count;

    final dx = centroidX - originX;
    final dy = centroidY - originY;

    if (dx.abs() + dy.abs() > SimTuning.colonyMigrationThreshold) {
      originX += dx.sign;
      originY += dy.sign;

      if (sim.inBoundsY(originY)) {
        final idx = originY * sim.gridW + sim.wrapX(originX);
        if (sim.grid[idx] == El.empty) {
          for (var scanY = originY + 1; scanY < sim.gridH; scanY++) {
            final si = scanY * sim.gridW + sim.wrapX(originX);
            if (sim.grid[si] != El.empty &&
                sim.grid[si] != El.oxygen &&
                sim.grid[si] != El.hydrogen) {
              originY = scanY - 1;
              break;
            }
          }
        }
      }

      for (final ant in ants) {
        ant.nestX = originX;
        ant.nestY = originY;
      }
    }
  }

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
        if (el != El.empty &&
            el < maxElements &&
            (elCategory[el] & ElCat.organic != 0) &&
            (elCategory[el] & ElCat.flammable != 0)) {
          sim.grid[idx] = El.empty;
          sim.life[idx] = 0;
          sim.markDirty(nx, ny);
          // If larvae exist, some food goes directly to larvae.
          if (larvaeCount > 0 && larvaeFood < larvaeCount * SimTuning.larvaFoodPerGrow) {
            larvaeFood++;
          } else {
            foodStored++;
          }
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
    queen = null;
    foodStored = 0;
    eggsCount = 0;
    larvaeCount = 0;
    larvaeFood = 0;
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
  int get antsCarryingDirt => ants.where((a) => a.carryingDirt).length;
  int get broodTotal => eggsCount + larvaeCount;

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
