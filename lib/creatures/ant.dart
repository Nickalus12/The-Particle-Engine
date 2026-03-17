import 'dart:math';

import '../simulation/element_registry.dart';
import '../simulation/simulation_engine.dart';
import '../utils/math_helpers.dart';
import 'neat/ant_brain.dart';
import 'neat/ant_fitness.dart';
import 'neat/neat_genome.dart';
import 'pheromone_system.dart';

/// Why an ant died — used for fitness reporting and debugging.
enum DeathCause {
  starvation,
  drowned,
  burned,
  dissolved,
  crushed,
  combat,
  oldAge,
  colonyDeath,
}

/// Role an ant is currently fulfilling within the colony.
///
/// Roles are not hard-coded behaviours — the neural brain makes all decisions.
/// The role affects which pheromone channel the ant deposits to and provides
/// a slight bias in sensory input weighting.
enum AntRole {
  explorer,
  forager,
  builder,
  defender,
  nurse,
  idle,
}

/// A single living ant in the simulation.
///
/// Each ant is a discrete entity with position, energy, a NEAT neural brain,
/// and a fitness tracker. Every tick, the ant:
///
/// 1. Perceives its environment (nearby elements, pheromones, colony state).
/// 2. Runs its neural network forward pass to decide an action.
/// 3. Validates the action against physics (can't walk through stone, etc.).
/// 4. Executes the valid action (move, pick up, drop, deposit pheromone).
/// 5. Pays energy costs and checks for death conditions.
///
/// Ants do NOT occupy grid cells in the element simulation — they exist as
/// overlaid entities that read from and interact with the grid. This avoids
/// complex collision logic with the cellular automaton and allows thousands
/// of ants without disrupting element physics.
class Ant {
  Ant({
    required this.x,
    required this.y,
    required this.colonyId,
    required this.nestX,
    required this.nestY,
    required this.genomeIndex,
    required NeatGenome genome,
    int? seed,
  })  : brain = AntBrain(genome: genome),
        fitness = AntFitness(),
        _rng = Random(seed);

  // ---------------------------------------------------------------------------
  // Identity
  // ---------------------------------------------------------------------------

  /// Index into the colony's NEAT population for this ant's genome.
  final int genomeIndex;

  /// Which colony this ant belongs to (index in CreatureRegistry).
  final int colonyId;

  /// The ant's neural brain.
  final AntBrain brain;

  /// Fitness accumulator — reported back to NEAT when the ant dies.
  final AntFitness fitness;

  /// Per-ant RNG for deterministic behaviour within stochastic elements.
  final Random _rng;

  // ---------------------------------------------------------------------------
  // Position and movement
  // ---------------------------------------------------------------------------

  /// Current grid X position.
  int x;

  /// Current grid Y position.
  int y;

  /// Previous X — used for idle detection and movement validation.
  int _prevX = -1;

  /// Previous Y.
  int _prevY = -1;

  /// Grid position of the colony nest entrance (for homing).
  final int nestX;
  final int nestY;

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  /// Current energy level (0.0 = dead, 1.0 = fully fed).
  double energy = 1.0;

  /// Age in simulation ticks.
  int age = 0;

  /// Maximum age in ticks before death from old age (~5 minutes at 60fps).
  static const int maxAge = 18000;

  /// Whether the ant is carrying food.
  bool carryingFood = false;

  /// What type of food is being carried (element ID).
  int carriedFoodType = El.empty;

  /// Current assigned role.
  AntRole role = AntRole.explorer;

  /// Whether this ant is alive.
  bool alive = true;

  /// If dead, what killed it.
  DeathCause? deathCause;

  /// Consecutive ticks spent underwater (for drowning).
  int underwaterTicks = 0;

  /// Ticks spent in dangerous conditions (fire adjacency, etc.).
  int dangerExposureTicks = 0;

  /// Ticks since this ant last moved (for idle detection).
  int _idleTicks = 0;

  // ---------------------------------------------------------------------------
  // Energy costs
  // ---------------------------------------------------------------------------

  /// Base energy cost per tick just for existing.
  static const double baseCost = 0.0003;

  /// Extra energy cost for moving.
  static const double moveCost = 0.0005;

  /// Extra energy cost for carrying food.
  static const double carryCost = 0.0001;

  /// Energy restored when eating food.
  static const double foodEnergy = 0.25;

  /// Ticks underwater before drowning.
  static const int drownThreshold = 30;

  /// Ticks in fire/lava before burning.
  static const int burnThreshold = 3;

  // ---------------------------------------------------------------------------
  // Core tick
  // ---------------------------------------------------------------------------

  /// Run one tick of this ant's life.
  ///
  /// Returns `true` if the ant is still alive after this tick.
  bool tick({
    required SimulationEngine sim,
    required PheromoneSystem foodPheromones,
    required PheromoneSystem homePheromones,
    required PheromoneSystem dangerPheromones,
    required List<Ant> nearbyEnemies,
  }) {
    if (!alive) return false;

    age++;
    _prevX = x;
    _prevY = y;

    // -- Check environmental hazards first ------------------------------------
    if (!_surviveEnvironment(sim)) return false;

    // -- Age check ------------------------------------------------------------
    if (age >= maxAge) {
      _die(DeathCause.oldAge);
      return false;
    }

    // -- Energy depletion check -----------------------------------------------
    energy -= baseCost;
    if (carryingFood) energy -= carryCost;
    if (energy <= 0.0) {
      _die(DeathCause.starvation);
      return false;
    }

    // -- Neural decision-making -----------------------------------------------
    final action = brain.think(
      sim: sim,
      antX: x,
      antY: y,
      nestX: nestX,
      nestY: nestY,
      energy: energy,
      carryingFood: carryingFood,
      foodPheromones: foodPheromones,
      homePheromones: homePheromones,
      dangerPheromones: dangerPheromones,
      nearbyEnemyCount: nearbyEnemies.length,
    );

    // -- Execute action -------------------------------------------------------
    _executeMovement(sim, action.dx, action.dy);
    _executeFoodActions(sim, action);
    _executePheromoneDeposit(
      action,
      foodPheromones,
      homePheromones,
      dangerPheromones,
      nearbyEnemies,
    );
    _executeCombat(sim, action, nearbyEnemies);

    // -- Idle tracking --------------------------------------------------------
    if (x == _prevX && y == _prevY) {
      _idleTicks++;
      fitness.idled();
    } else {
      _idleTicks = 0;
      fitness.moved(x, y);
    }

    // -- Survival fitness reward ------------------------------------------------
    fitness.tickSurvived();

    return true;
  }

  // ---------------------------------------------------------------------------
  // Grid helpers
  // ---------------------------------------------------------------------------

  /// Read element at (gx, gy) safely.
  int _getEl(SimulationEngine sim, int gx, int gy) {
    if (!sim.inBoundsY(gy)) return El.stone; // Treat OOB as impassable.
    gx = sim.wrapX(gx);
    return sim.grid[gy * sim.gridW + gx];
  }

  /// Set element at (gx, gy) safely.
  void _setEl(SimulationEngine sim, int gx, int gy, int elType) {
    if (!sim.inBoundsY(gy)) return;
    gx = sim.wrapX(gx);
    final idx = gy * sim.gridW + gx;
    sim.grid[idx] = elType;
    sim.life[idx] = 0;
    sim.markDirty(gx, gy);
  }

  /// 4-connected neighbours that are in bounds.
  List<(int, int)> _neighbours4(SimulationEngine sim, int gx, int gy) {
    final result = <(int, int)>[];
    if (gy > 0) result.add((gx, gy - 1));
    if (gy < sim.gridH - 1) result.add((gx, gy + 1));
    result.add((sim.wrapX(gx - 1), gy));
    result.add((sim.wrapX(gx + 1), gy));
    return result;
  }

  /// 8-connected neighbours that are in bounds.
  List<(int, int)> _neighbours8(SimulationEngine sim, int gx, int gy) {
    final result = <(int, int)>[];
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = sim.wrapX(gx + dx);
        final ny = gy + dy;
        if (sim.inBoundsY(ny)) result.add((nx, ny));
      }
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Environmental survival
  // ---------------------------------------------------------------------------

  /// Check the element at the ant's current position and handle hazards.
  /// Returns false if the ant dies.
  bool _surviveEnvironment(SimulationEngine sim) {
    final element = _getEl(sim, x, y);

    // -- Water: ants can swim briefly but drown after threshold ----------------
    if (element == El.water) {
      underwaterTicks++;
      if (underwaterTicks >= drownThreshold) {
        _die(DeathCause.drowned);
        return false;
      }
      energy -= 0.001;
    } else {
      underwaterTicks = 0;
    }

    // -- Fire/Lava: immediate danger ------------------------------------------
    if (element == El.fire || element == El.lava) {
      dangerExposureTicks++;
      if (dangerExposureTicks >= burnThreshold) {
        _die(DeathCause.burned);
        return false;
      }
      energy -= 0.05;
    } else {
      // Use engine's senseDanger API for efficient adjacent danger check.
      if (sim.senseDanger(x, y, 1)) {
        dangerExposureTicks++;
        energy -= 0.01;
      } else {
        dangerExposureTicks = 0;
      }
    }

    // -- Acid: dissolves ant on contact ---------------------------------------
    if (element == El.acid) {
      _die(DeathCause.dissolved);
      return false;
    }

    // -- Crushed: inside a solid somehow (stone/wood fell on ant) ---------------
    if (_isSolid(element)) {
      if (!_tryEscape(sim)) {
        _die(DeathCause.crushed);
        return false;
      }
    }

    return true;
  }

  /// Try to move to a nearby empty or passable cell when trapped inside solid.
  bool _tryEscape(SimulationEngine sim) {
    final neighbors = _neighbours8(sim, x, y);
    neighbors.shuffle(_rng);
    for (final (nx, ny) in neighbors) {
      if (_isPassable(_getEl(sim, nx, ny))) {
        x = nx;
        y = ny;
        return true;
      }
    }
    return false;
  }

  /// Whether an element type can be walked through by an ant.
  ///
  /// Uses the [elCategory] bitmask: empty is always passable, as are gases.
  /// Liquids are passable (ants can swim). Custom elements with gas category
  /// are automatically passable.
  static bool _isPassable(int elType) {
    if (elType == El.empty) return true;
    if (elType >= maxElements) return false;
    final cat = elCategory[elType];
    // Gases are passable (smoke, steam, bubble, custom gas elements).
    if (cat & ElCat.gas != 0) return true;
    // Liquids are passable (water, oil, acid — ant handles hazards separately).
    if (cat & ElCat.liquid != 0) return true;
    return false;
  }

  /// Whether an element is a solid that blocks movement.
  ///
  /// Uses [staticElements] set from the registry — any element registered
  /// as static (stone, wood, metal, glass, ice, or custom statics) blocks ants.
  static bool _isSolid(int elType) {
    return staticElements.contains(elType);
  }

  /// Whether an element is food for ants.
  ///
  /// Uses [elCategory] bitmask: organic + flammable elements are food
  /// (seeds, plants). Custom elements with both flags are automatically food.
  static bool _isFood(int elType) {
    if (elType == El.empty || elType >= maxElements) return false;
    final cat = elCategory[elType];
    return (cat & ElCat.organic != 0) && (cat & ElCat.flammable != 0);
  }

  // ---------------------------------------------------------------------------
  // Movement
  // ---------------------------------------------------------------------------

  /// Validate and execute a movement action.
  void _executeMovement(SimulationEngine sim, int dx, int dy) {
    if (dx == 0 && dy == 0) return;

    final targetX = sim.wrapX(x + dx);
    final targetY = y + dy;

    if (!sim.inBoundsY(targetY)) return;

    final targetElement = _getEl(sim, targetX, targetY);

    // Can the ant walk there?
    if (!_isPassable(targetElement)) {
      // Try to walk on top of solid elements (climbing).
      if (_tryClimb(sim, dx, dy)) return;
      return;
    }

    // Apply gravity: if the cell below the target is empty, the ant falls.
    if (_hasSurface(sim, targetX, targetY) || targetElement == El.water) {
      x = targetX;
      y = targetY;
      energy -= moveCost;
    } else {
      _applyGravity(sim);
    }
  }

  /// Whether there is a solid surface below or at a position.
  bool _hasSurface(SimulationEngine sim, int px, int py) {
    if (py >= sim.gridH - 1) return true;
    final below = _getEl(sim, px, py + 1);
    return !_isPassable(below);
  }

  /// Try climbing over a 1-cell obstacle.
  bool _tryClimb(SimulationEngine sim, int dx, int dy) {
    if (dx == 0) return false;
    final climbX = sim.wrapX(x + dx);
    final climbY = y - 1;
    if (!sim.inBoundsY(climbY)) return false;

    final aboveObstacle = _getEl(sim, climbX, climbY);
    if (_isPassable(aboveObstacle) && _hasSurface(sim, climbX, climbY)) {
      x = climbX;
      y = climbY;
      energy -= moveCost * 2;
      return true;
    }
    return false;
  }

  /// Apply gravity — ant falls if there's no surface beneath.
  void _applyGravity(SimulationEngine sim) {
    if (y >= sim.gridH - 1) return;
    if (_isPassable(_getEl(sim, x, y + 1))) {
      y += 1;
    }
  }

  // ---------------------------------------------------------------------------
  // Food actions
  // ---------------------------------------------------------------------------

  /// Handle food pick-up and drop-off actions.
  void _executeFoodActions(SimulationEngine sim, AntAction action) {
    // -- Pick up food --------------------------------------------------------
    if (action.wantsPickUp && !carryingFood) {
      final foodPos = _findAdjacentFood(sim);
      if (foodPos != null) {
        final (fx, fy) = foodPos;
        carriedFoodType = _getEl(sim, fx, fy);
        _setEl(sim, fx, fy, El.empty);
        carryingFood = true;
        energy = (energy + foodEnergy * 0.2).clamp(0.0, 1.0);
        fitness.foraged();
      }
    }

    // -- Drop food at nest ---------------------------------------------------
    if (action.wantsDrop && carryingFood) {
      final distToNest = MathHelpers.manhattan(x, y, nestX, nestY);
      if (distToNest <= 3) {
        carryingFood = false;
        carriedFoodType = El.empty;
        fitness.deliveredFood();
      } else {
        final dropType = carriedFoodType != El.empty ? carriedFoodType : El.seed;
        for (final (nx, ny) in _neighbours4(sim, x, y)) {
          if (_getEl(sim, nx, ny) == El.empty) {
            _setEl(sim, nx, ny, dropType);
            carryingFood = false;
            carriedFoodType = El.empty;
            break;
          }
        }
      }
    }
  }

  /// Search current cell and 4 neighbours for food elements.
  (int, int)? _findAdjacentFood(SimulationEngine sim) {
    if (_isFood(_getEl(sim, x, y))) return (x, y);
    for (final (nx, ny) in _neighbours4(sim, x, y)) {
      if (_isFood(_getEl(sim, nx, ny))) return (nx, ny);
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Pheromone deposit
  // ---------------------------------------------------------------------------

  void _executePheromoneDeposit(
    AntAction action,
    PheromoneSystem foodPheromones,
    PheromoneSystem homePheromones,
    PheromoneSystem dangerPheromones,
    List<Ant> nearbyEnemies,
  ) {
    final strength = action.pheromoneStrength;
    if (strength < 0.01) return;

    if (carryingFood) {
      foodPheromones.deposit(x, y, strength * 0.8);
    }

    final distToNest = MathHelpers.manhattan(x, y, nestX, nestY);
    final maxDist = 500; // Approximate max distance.
    final homeStrength = strength * (1.0 - distToNest / maxDist);
    homePheromones.deposit(x, y, homeStrength.clamp(0.0, 1.0));

    if (nearbyEnemies.isNotEmpty) {
      dangerPheromones.deposit(x, y, strength);
    }
  }

  // ---------------------------------------------------------------------------
  // Combat
  // ---------------------------------------------------------------------------

  void _executeCombat(
    SimulationEngine sim,
    AntAction action,
    List<Ant> nearbyEnemies,
  ) {
    if (!action.wantsAttack || nearbyEnemies.isEmpty) return;

    Ant? closest;
    int closestDist = 999999;
    for (final enemy in nearbyEnemies) {
      if (!enemy.alive) continue;
      final dist = MathHelpers.manhattan(x, y, enemy.x, enemy.y);
      if (dist <= 2 && dist < closestDist) {
        closest = enemy;
        closestDist = dist;
      }
    }

    if (closest == null) return;

    final attackPower = energy * 0.15;
    final defensePower = closest.energy * 0.1;

    closest.energy -= attackPower;
    energy -= defensePower;

    if (closest.energy <= 0.0) {
      closest._die(DeathCause.combat);
      fitness.defended();
    }
    if (energy <= 0.0) {
      _die(DeathCause.combat);
    }
  }

  // ---------------------------------------------------------------------------
  // Death
  // ---------------------------------------------------------------------------

  void _die(DeathCause cause) {
    if (!alive) return;
    alive = false;
    deathCause = cause;
    fitness.died();
    carryingFood = false;
    carriedFoodType = El.empty;
  }

  /// Kill this ant externally (e.g., colony death).
  void kill(DeathCause cause) => _die(cause);

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  int get distanceToNest => MathHelpers.manhattan(x, y, nestX, nestY);
  bool get isNearNest => distanceToNest <= 5;
  bool get isIdle => _idleTicks > 10;
  int get lifetime => age;
}
