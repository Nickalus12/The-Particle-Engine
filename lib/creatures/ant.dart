import 'dart:math';
import 'dart:typed_data';

import '../simulation/element_registry.dart';
import '../simulation/simulation_engine.dart';
import '../utils/math_helpers.dart';
import 'creature_phenotype.dart';
import 'neat/ant_brain.dart';
import 'neat/ant_fitness.dart';
import 'neat/neat_genome.dart';
import 'pheromone_system.dart';

/// Species of creature — determines behavior, rendering, and environment rules.
enum CreatureSpecies {
  /// Classic ant: colony-based, tunneling, social.
  ant,

  /// Earthworm: burrows through dirt, aerates soil, decomposes organic matter.
  worm,

  /// Beetle: eats dead matter and compost, hard carapace, ground-dweller.
  beetle,

  /// Spider: spins web (El.web), ambush predator, cave-dweller, diagonal movement.
  spider,

  /// Fish: aquatic only, dies out of water, eats algae/seaweed, school behavior.
  fish,

  /// Bee: flies (ignores gravity partially), pollinates flowers, produces honey.
  bee,

  /// Firefly: nocturnal glow, synchronized flashing, attracts mates at night.
  firefly,
}

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
  poisoned,
  asphyxiated,
}

/// Role an ant is currently fulfilling within the colony.
///
/// Mimics real ant biology: queen is the reproductive center, workers handle
/// foraging/building, soldiers defend, nurses tend brood, scouts explore.
/// The neural brain makes all decisions — role provides context and slight
/// sensory bias.
enum AntRole {
  /// The queen: larger, longer-lived, produces eggs. One per colony.
  queen,

  /// Worker (70%): foragers and builders. Dig tunnels, carry food/dirt.
  worker,

  /// Soldier (15%): patrol perimeter, respond to threats, stronger combat.
  soldier,

  /// Nurse (10%): tend brood, carry food to larvae, stay near queen.
  nurse,

  /// Scout (5%): explore far from nest, lay strongest pheromone trails.
  scout,

  /// Idle: temporary state, usually reassigned quickly.
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
    this.species = CreatureSpecies.ant,
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

  /// Species determines behavior, rendering, and environment rules.
  final CreatureSpecies species;

  /// The ant's neural brain.
  final AntBrain brain;

  /// Fitness accumulator — reported back to NEAT when the ant dies.
  final AntFitness fitness;

  /// Per-ant RNG for deterministic behaviour within stochastic elements.
  final Random _rng;

  /// Pre-computed visual traits derived from genome.
  CreaturePhenotype? phenotype;

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
  /// Mutable — colony origin moves as ants migrate.
  int nestX;
  int nestY;

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  /// Current energy level (0.0 = dead, 1.0 = fully fed).
  double energy = 1.0;

  /// Age in simulation ticks.
  int age = 0;

  /// Maximum age in ticks before death from old age (~5 minutes at 60fps).
  /// Queen gets 10x lifespan via SimTuning.queenMaxAge.
  static const int maxAge = 18000;

  /// Whether the ant is carrying food.
  bool carryingFood = false;

  /// What type of food is being carried (element ID).
  int carriedFoodType = El.empty;

  /// Whether the ant is carrying excavated dirt (for nest building).
  bool carryingDirt = false;

  /// Current assigned role.
  AntRole role = AntRole.worker;

  /// Whether this ant is alive.
  bool alive = true;

  /// If dead, what killed it.
  DeathCause? deathCause;

  /// Consecutive ticks spent underwater (for drowning).
  int underwaterTicks = 0;

  /// Ticks spent in dangerous conditions (fire adjacency, etc.).
  int dangerExposureTicks = 0;

  /// Consecutive ticks exposed to toxic gas (chlorine, fluorine, radon).
  int toxicGasTicks = 0;

  /// Consecutive ticks without oxygen (asphyxiation tracking).
  int noOxygenTicks = 0;

  /// Ticks since this ant last moved (for idle detection).
  int _idleTicks = 0;

  /// Timer for neural decision making (thinking every N ticks).
  int _decisionTimer = 0;
  AntAction? _lastAction;

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

  /// Ticks of toxic gas exposure before death.
  static const int toxicGasThreshold = 60;

  /// Ticks without oxygen before asphyxiation death.
  static const int asphyxiationThreshold = 90;

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

    // -- Deposit danger pheromone if exposed to gas/heat hazards ---------------
    if (toxicGasTicks > 0 || dangerExposureTicks > 2) {
      dangerPheromones.deposit(x, y, 0.6);
    }

    // -- Age check (queen lives much longer) -----------------------------------
    final effectiveMaxAge = role == AntRole.queen
        ? SimTuning.queenMaxAge
        : maxAge;
    if (age >= effectiveMaxAge) {
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

    // -- Neural decision-making (OPTIMIZED: only think every 4 frames) --------
    AntAction action;
    if (_decisionTimer <= 0 || _lastAction == null) {
      action = brain.think(
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
      _lastAction = action;
      _decisionTimer = 4; // Think once every 4 frames
    } else {
      action = _lastAction!;
      _decisionTimer--;
    }

    // -- Execute action -------------------------------------------------------
    // Xenon/CO2 slowdown: skip movement 50% of ticks when impaired.
    final gasImpaired = noOxygenTicks > 5 || toxicGasTicks > 10;
    final canMove = !gasImpaired || age % 2 == 0;

    // Queen moves very slowly (every N ticks).
    if (canMove) {
      if (role == AntRole.queen) {
        if (age % SimTuning.queenMoveSpeed == 0) {
          _executeMovement(sim, action.dx, action.dy);
        }
      } else {
        _executeMovement(sim, action.dx, action.dy);
      }
    }
    if (species != CreatureSpecies.bee &&
        species != CreatureSpecies.fish &&
        y == _prevY) {
      _applyGravity(sim);
    }
    _executeFoodActions(sim, action);
    _executeDig(sim, action);
    _executeSpeciesAbility(sim, action);
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

  // Pre-allocated neighbor buffers to avoid heap allocation in tick loops.
  // 8-neighbor: dx/dy offsets, filled per call.
  static final Int8List _n8dx = Int8List(8);
  static final Int8List _n8dy = Int8List(8);

  /// Fill [_n8dx]/[_n8dy] with valid 8-connected neighbors. Returns count.
  int _fillNeighbours8(SimulationEngine sim, int gx, int gy) {
    int count = 0;
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final ny = gy + dy;
        if (sim.inBoundsY(ny)) {
          _n8dx[count] = dx;
          _n8dy[count] = dy;
          count++;
        }
      }
    }
    return count;
  }

  // ---------------------------------------------------------------------------
  // Environmental survival
  // ---------------------------------------------------------------------------

  /// Check the element at the ant's current position and handle hazards.
  /// Returns false if the ant dies.
  bool _surviveEnvironment(SimulationEngine sim) {
    final element = _getEl(sim, x, y);

    // -- Water: species-specific handling ----------------------------------------
    if (element == El.water) {
      if (species == CreatureSpecies.fish) {
        // Fish thrive in water — recover energy slowly.
        underwaterTicks = 0;
        energy = (energy + 0.0002).clamp(0.0, 1.0);
      } else {
        underwaterTicks++;
        if (underwaterTicks >= drownThreshold) {
          _die(DeathCause.drowned);
          return false;
        }
        energy -= 0.001;
      }
    } else {
      underwaterTicks = 0;
      // Fish suffocate out of water.
      if (species == CreatureSpecies.fish) {
        dangerExposureTicks++;
        energy -= 0.02;
        if (dangerExposureTicks >= 15) {
          _die(DeathCause.drowned);
          return false;
        }
      }
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

    // -- Toxic gas damage: scan adjacent cells for harmful gases ----------------
    if (!_surviveGasExposure(sim)) return false;

    // -- Crushed: inside a solid somehow (stone/wood fell on ant) ---------------
    if (_isSolid(element)) {
      if (!_tryEscape(sim)) {
        _die(DeathCause.crushed);
        return false;
      }
    }

    return true;
  }

  /// Check adjacent cells for gas hazards. Returns false if the ant dies.
  bool _surviveGasExposure(SimulationEngine sim) {
    // Count gas types in 8-connected neighborhood + current cell.
    int toxicCount = 0; // Chlorine, fluorine
    int radonCount = 0;
    int co2Count = 0;
    int oxygenCount = 0;
    int emptyCount = 0;
    int xenonCount = 0;

    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        final ny = y + dy;
        if (!sim.inBoundsY(ny)) continue;
        final nx = sim.wrapX(x + dx);
        final el = sim.grid[ny * sim.gridW + nx];

        if (el == El.empty) {
          emptyCount++;
        } else if (el == El.chlorine || el == El.fluorine) {
          toxicCount++;
        } else if (el == El.radon) {
          radonCount++;
        } else if (el == El.co2) {
          co2Count++;
        } else if (el == El.oxygen) {
          oxygenCount++;
        } else if (el == El.xenon) {
          xenonCount++;
        }
      }
    }

    // -- Chlorine/Fluorine: corrosive, -3 energy per tick when adjacent --------
    if (toxicCount > 0) {
      energy -= 0.003 * toxicCount;
      toxicGasTicks += toxicCount;
      if (toxicGasTicks >= toxicGasThreshold) {
        _die(DeathCause.poisoned);
        return false;
      }
    } else if (radonCount > 0) {
      // -- Radon: radiation damage, -1 energy per tick -------------------------
      energy -= 0.001 * radonCount;
      toxicGasTicks += radonCount;
      if (toxicGasTicks >= toxicGasThreshold) {
        _die(DeathCause.poisoned);
        return false;
      }
    } else {
      // Recover toxic exposure when away from toxic gases.
      if (toxicGasTicks > 0) toxicGasTicks--;
    }

    // -- CO2 asphyxiation: 3+ CO2 cells nearby means suffocation risk ----------
    if (co2Count >= 3) {
      energy -= 0.001 * co2Count;
      noOxygenTicks++;
    }
    // -- No oxygen AND no empty cells: sealed environment, suffocating ----------
    else if (oxygenCount == 0 && emptyCount == 0) {
      energy -= 0.002;
      noOxygenTicks++;
    } else {
      // Recover when breathing normally.
      if (noOxygenTicks > 0) noOxygenTicks--;
    }

    if (noOxygenTicks >= asphyxiationThreshold) {
      _die(DeathCause.asphyxiated);
      return false;
    }

    // -- Xenon: anesthetic effect, slows ant by draining extra energy ----------
    if (xenonCount > 0) {
      energy -= 0.001 * xenonCount;
    }

    return true;
  }

  /// Try to move to a nearby empty or passable cell when trapped inside solid.
  bool _tryEscape(SimulationEngine sim) {
    final count = _fillNeighbours8(sim, x, y);
    // Fisher-Yates shuffle on the pre-allocated buffer (zero allocation)
    for (var i = count - 1; i > 0; i--) {
      final j = _rng.nextInt(i + 1);
      final tmpDx = _n8dx[i]; _n8dx[i] = _n8dx[j]; _n8dx[j] = tmpDx;
      final tmpDy = _n8dy[i]; _n8dy[i] = _n8dy[j]; _n8dy[j] = tmpDy;
    }
    for (var i = 0; i < count; i++) {
      final nx = sim.wrapX(x + _n8dx[i].toInt());
      final ny = y + _n8dy[i].toInt();
      if (_isPassable(_getEl(sim, nx, ny))) {
        x = nx.toInt();
        y = ny.toInt();
        return true;
      }
    }
    return false;
  }

  /// Whether an element type can be walked through by this creature.
  ///
  /// Species-specific: worms can move through dirt/sand, fish require water.
  bool _isPassableForMe(int elType) {
    if (elType == El.empty) return true;
    if (elType >= maxElements) return false;
    final cat = elCategory[elType];
    if (cat & ElCat.gas != 0) return true;
    if (cat & ElCat.liquid != 0) return true;
    // Worms burrow through soil.
    if (species == CreatureSpecies.worm) {
      if (elType == El.dirt || elType == El.mud || elType == El.compost) {
        return true;
      }
    }
    return false;
  }

  /// Static version for cases where species context isn't available.
  static bool _isPassable(int elType) {
    if (elType == El.empty) return true;
    if (elType >= maxElements) return false;
    final cat = elCategory[elType];
    if (cat & ElCat.gas != 0) return true;
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

  /// Whether an element is food for this creature.
  ///
  /// Species-specific: beetles eat compost/ash, fish eat algae, etc.
  bool _isFoodForMe(int elType) {
    if (elType == El.empty || elType >= maxElements) return false;
    switch (species) {
      case CreatureSpecies.beetle:
        return elType == El.compost || elType == El.ash || elType == El.charcoal;
      case CreatureSpecies.fish:
        return elType == El.algae || elType == El.seaweed || elType == El.plant;
      case CreatureSpecies.bee:
        return elType == El.flower || elType == El.honey;
      default:
        final cat = elCategory[elType];
        return (cat & ElCat.organic != 0) && (cat & ElCat.flammable != 0);
    }
  }


  // ---------------------------------------------------------------------------
  // Movement
  // ---------------------------------------------------------------------------

  /// Validate and execute a movement action.
  void _executeMovement(SimulationEngine sim, int dx, int dy) {
    if (dx == 0 && dy == 0) {
      // Even when the brain chooses to idle, grounded creatures must still
      // obey gravity in unsupported air pockets.
      if (species != CreatureSpecies.bee && species != CreatureSpecies.fish) {
        _applyGravity(sim);
      }
      return;
    }

    final targetX = sim.wrapX(x + dx);
    final targetY = y + dy;

    if (!sim.inBoundsY(targetY)) return;

    final targetElement = _getEl(sim, targetX, targetY);

    // Can the creature walk there?
    if (!_isPassableForMe(targetElement)) {
      // Try to walk on top of solid elements (climbing). Fish don't climb.
      if (species != CreatureSpecies.fish && _tryClimb(sim, dx, dy)) return;
      if (species != CreatureSpecies.bee && species != CreatureSpecies.fish) {
        _applyGravity(sim);
      }
      return;
    }

    // Bees partially ignore gravity (they fly).
    if (species == CreatureSpecies.bee) {
      x = targetX;
      y = targetY;
      energy -= moveCost;
      return;
    }

    // Fish must stay in water.
    if (species == CreatureSpecies.fish) {
      if (targetElement == El.water || targetElement == El.empty) {
        x = targetX;
        y = targetY;
        energy -= moveCost * 0.5; // Fish are efficient in water.
      }
      return;
    }

    // Apply gravity: if the cell below the target is empty, the creature falls.
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
        // Inline 4-neighbor check (zero allocation)
        for (final (dx, dy) in const [(0, -1), (0, 1), (-1, 0), (1, 0)]) {
          final nx = sim.wrapX(x + dx);
          final ny = y + dy;
          if (sim.inBoundsY(ny) && _getEl(sim, nx, ny) == El.empty) {
            _setEl(sim, nx, ny, dropType);
            carryingFood = false;
            carriedFoodType = El.empty;
            break;
          }
        }
      }
    }
  }

  /// Search current cell and 4 neighbours for food elements (zero allocation).
  (int, int)? _findAdjacentFood(SimulationEngine sim) {
    if (_isFoodForMe(_getEl(sim, x, y))) return (x, y);
    for (final (dx, dy) in const [(0, -1), (0, 1), (-1, 0), (1, 0)]) {
      final nx = sim.wrapX(x + dx);
      final ny = y + dy;
      if (sim.inBoundsY(ny) && _isFoodForMe(_getEl(sim, nx, ny))) {
        return (nx, ny);
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Nest building (dig + dirt carry)
  // ---------------------------------------------------------------------------

  /// Workers/scouts near the nest dig adjacent dirt/sand cells.
  /// The ant picks up dirt and carries it to the surface (mound formation).
  void _executeDig(SimulationEngine sim, AntAction action) {
    // Only workers and scouts dig. Queen/nurse/soldier don't.
    if (role != AntRole.worker && role != AntRole.scout) return;
    // Don't dig if already carrying something.
    if (carryingFood || carryingDirt) {
      // If carrying dirt, try to drop it above ground (mound building).
      if (carryingDirt) {
        _tryDropDirt(sim);
      }
      return;
    }
    // Only dig near nest (within nest radius).
    final distToNest = MathHelpers.manhattan(x, y, nestX, nestY);
    if (distToNest > 15) return; // Colony nest radius
    // Use movement direction as dig direction. If not moving, skip.
    if (action.dx == 0 && action.dy == 0) return;
    // Stochastic dig: 1/N chance per tick.
    if (_rng.nextInt(SimTuning.digSuccessRate) != 0) return;

    final digX = sim.wrapX(x + action.dx);
    final digY = y + action.dy;
    if (!sim.inBoundsY(digY)) return;

    final targetEl = _getEl(sim, digX, digY);
    // Can only dig dirt, sand, mud.
    if (targetEl != El.dirt && targetEl != El.sand && targetEl != El.mud) return;

    // Remove the cell and pick up dirt.
    _setEl(sim, digX, digY, El.empty);
    carryingDirt = true;
    energy -= moveCost; // Digging costs energy.
    fitness.built(); // Reward nest building.
  }

  /// Try to deposit carried dirt on the surface (above ground level).
  void _tryDropDirt(SimulationEngine sim) {
    if (!carryingDirt) return;
    if (_rng.nextInt(SimTuning.dirtCarryDrop) != 0) return;

    // Drop dirt if we're near the surface (above nest Y or at ground level).
    // Find an empty cell adjacent to drop dirt into.
    for (final (dx, dy) in const [(0, -1), (-1, 0), (1, 0), (0, 1)]) {
      final nx = sim.wrapX(x + dx);
      final ny = y + dy;
      if (!sim.inBoundsY(ny)) continue;
      if (_getEl(sim, nx, ny) != El.empty) continue;
      // Only drop above or at nest level (mound formation).
      if (ny <= nestY) {
        _setEl(sim, nx, ny, El.dirt);
        carryingDirt = false;
        return;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Species-specific abilities
  // ---------------------------------------------------------------------------

  void _executeSpeciesAbility(SimulationEngine sim, AntAction action) {
    switch (species) {
      case CreatureSpecies.spider:
        _spiderSpinWeb(sim);
      case CreatureSpecies.bee:
        _beePollinate(sim);
      case CreatureSpecies.worm:
        _wormAerate(sim);
      case CreatureSpecies.beetle:
        _beetleDecompose(sim);
      case CreatureSpecies.fish:
        _fishEatAlgae(sim);
      case CreatureSpecies.firefly:
      case CreatureSpecies.ant:
        break; // Handled by existing ant systems.
    }
  }

  /// Spider: spin web at current position (1/N chance per tick).
  void _spiderSpinWeb(SimulationEngine sim) {
    if (_rng.nextInt(SimTuning.spiderWebRate) != 0) return;
    // Place web at previous position (trail behind spider).
    if (_prevX >= 0 && _prevY >= 0 && sim.inBoundsY(_prevY)) {
      final prevEl = _getEl(sim, _prevX, _prevY);
      if (prevEl == El.empty) {
        _setEl(sim, _prevX, _prevY, El.web);
        fitness.built();
      }
    }
  }

  /// Bee: pollinate adjacent flowers (creates seeds nearby).
  void _beePollinate(SimulationEngine sim) {
    if (_rng.nextInt(SimTuning.beePollinateRate) != 0) return;
    // Check for adjacent flower.
    for (final (dx, dy) in const [(0, -1), (0, 1), (-1, 0), (1, 0)]) {
      final nx = sim.wrapX(x + dx);
      final ny = y + dy;
      if (!sim.inBoundsY(ny)) continue;
      if (_getEl(sim, nx, ny) == El.flower) {
        // Find empty cell nearby to create a seed.
        for (final (dx2, dy2) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
          final sx = sim.wrapX(nx + dx2);
          final sy = ny + dy2;
          if (sim.inBoundsY(sy) && _getEl(sim, sx, sy) == El.empty) {
            _setEl(sim, sx, sy, El.seed);
            energy = (energy + 0.05).clamp(0.0, 1.0); // Nectar energy.
            fitness.foraged();
            return;
          }
        }
      }
    }
  }

  /// Worm: aerate soil — convert adjacent dirt to compost occasionally.
  void _wormAerate(SimulationEngine sim) {
    if (_rng.nextInt(SimTuning.wormAerateRate) != 0) return;
    for (final (dx, dy) in const [(0, -1), (0, 1), (-1, 0), (1, 0)]) {
      final nx = sim.wrapX(x + dx);
      final ny = y + dy;
      if (!sim.inBoundsY(ny)) continue;
      if (_getEl(sim, nx, ny) == El.dirt) {
        _setEl(sim, nx, ny, El.compost);
        fitness.built();
        return;
      }
    }
  }

  /// Beetle: eat adjacent compost/ash (decomposer).
  void _beetleDecompose(SimulationEngine sim) {
    if (_rng.nextInt(SimTuning.beetleDecomposeRate) != 0) return;
    for (final (dx, dy) in const [(0, -1), (0, 1), (-1, 0), (1, 0)]) {
      final nx = sim.wrapX(x + dx);
      final ny = y + dy;
      if (!sim.inBoundsY(ny)) continue;
      final el = _getEl(sim, nx, ny);
      if (el == El.compost || el == El.ash || el == El.charcoal) {
        _setEl(sim, nx, ny, El.empty);
        energy = (energy + 0.15).clamp(0.0, 1.0);
        fitness.foraged();
        return;
      }
    }
  }

  /// Fish: eat adjacent algae/seaweed.
  void _fishEatAlgae(SimulationEngine sim) {
    if (_rng.nextInt(SimTuning.fishEatRate) != 0) return;
    for (final (dx, dy) in const [(0, -1), (0, 1), (-1, 0), (1, 0)]) {
      final nx = sim.wrapX(x + dx);
      final ny = y + dy;
      if (!sim.inBoundsY(ny)) continue;
      final el = _getEl(sim, nx, ny);
      if (el == El.algae || el == El.seaweed || el == El.plant) {
        _setEl(sim, nx, ny, El.empty);
        energy = (energy + 0.2).clamp(0.0, 1.0);
        fitness.foraged();
        return;
      }
    }
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
    carryingDirt = false;
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
