import 'dart:typed_data';

import '../../simulation/element_registry.dart';
import '../../simulation/simulation_engine.dart';
import '../../utils/math_helpers.dart';
import '../pheromone_system.dart';
import 'neat_forward.dart';
import 'neat_genome.dart';

/// Wraps a NEAT genome + compiled network into a usable ant brain.
///
/// Responsible for:
/// 1. Gathering sensory inputs from the simulation state.
/// 2. Running the neural network forward pass.
/// 3. Interpreting outputs as ant actions.
///
/// Each ant owns one [AntBrain]. The brain is cheap to run (~0.3-1
/// microsecond per forward pass) and holds no mutable state beyond the
/// network's pre-allocated value buffer.
///
/// ## Inputs (8 neurons)
///
/// | Index | Signal | Range |
/// |-------|--------|-------|
/// | 0 | Distance to nearest food (normalised) | 0-1 |
/// | 1 | Distance to nest (normalised) | 0-1 |
/// | 2 | Food pheromone gradient direction (encoded) | -1 to 1 |
/// | 3 | Home pheromone gradient direction (encoded) | -1 to 1 |
/// | 4 | Danger pheromone intensity nearby | 0-1 |
/// | 5 | Own energy level | 0-1 |
/// | 6 | Carrying food | 0 or 1 |
/// | 7 | Nearby enemy count (normalised) | 0-1 |
///
/// ## Outputs (6 neurons)
///
/// | Index | Action | Interpretation |
/// |-------|--------|----------------|
/// | 0 | Move dx | tanh -> -1 to 1, discretised to {-1, 0, 1} |
/// | 1 | Move dy | tanh -> -1 to 1, discretised to {-1, 0, 1} |
/// | 2 | Deposit pheromone strength | 0-1 |
/// | 3 | Pick up food | > 0 = yes |
/// | 4 | Drop food | > 0 = yes |
/// | 5 | Attack | > 0 = yes |
class AntBrain {
  AntBrain({required this.genome})
      : network = NeatForward.fromGenome(genome);

  /// The genetic blueprint.
  final NeatGenome genome;

  /// Compiled neural network for fast inference.
  final NeatForward network;

  /// Reusable input buffer to avoid allocation every tick.
  final Float64List _inputs = Float64List(8);

  /// Run one tick of neural decision-making.
  ///
  /// Returns an [AntAction] describing what the ant wants to do.
  AntAction think({
    required SimulationEngine sim,
    required int antX,
    required int antY,
    required int nestX,
    required int nestY,
    required double energy,
    required bool carryingFood,
    required PheromoneSystem foodPheromones,
    required PheromoneSystem homePheromones,
    required PheromoneSystem dangerPheromones,
    int nearbyEnemyCount = 0,
  }) {
    // -- Gather inputs using SimulationEngine sensing API --------------------

    // [0] Distance to nearest food (uses engine's findNearestDirection).
    _inputs[0] = _nearestFoodDistance(sim, antX, antY);

    // [1] Distance to nest (normalised by grid diagonal).
    final maxDist = sim.gridW + sim.gridH;
    _inputs[1] = MathHelpers.manhattan(antX, antY, nestX, nestY) / maxDist;

    // [2] Food pheromone gradient (which direction has strongest signal).
    _inputs[2] = _pheromoneGradient(foodPheromones, antX, antY);

    // [3] Home pheromone gradient.
    _inputs[3] = _pheromoneGradient(homePheromones, antX, antY);

    // [4] Danger sense: combines pheromone + engine's senseDanger API.
    final dangerPheromone = dangerPheromones.read(antX, antY);
    final dangerNearby = sim.senseDanger(antX, antY, 3) ? 1.0 : 0.0;
    _inputs[4] = (dangerPheromone * 0.5 + dangerNearby * 0.5).clamp(0.0, 1.0);

    // [5] Energy level (0-1).
    _inputs[5] = energy.clamp(0.0, 1.0);

    // [6] Carrying food flag.
    _inputs[6] = carryingFood ? 1.0 : 0.0;

    // [7] Nearby enemy count (normalised: 5+ enemies = 1.0).
    _inputs[7] = (nearbyEnemyCount / 5.0).clamp(0.0, 1.0);

    // -- Forward pass --------------------------------------------------------
    final outputs = network.activate(_inputs);

    // -- Interpret outputs ---------------------------------------------------
    return AntAction(
      dx: _discretise(outputs[0]),
      dy: _discretise(outputs[1]),
      pheromoneStrength: outputs[2].clamp(0.0, 1.0),
      wantsPickUp: outputs[3] > 0.0,
      wantsDrop: outputs[4] > 0.0,
      wantsAttack: outputs[5] > 0.0,
    );
  }

  /// Rebuild the network from the genome (after mutation/crossover).
  AntBrain recompile() => AntBrain(genome: genome);

  // ---------------------------------------------------------------------------
  // Sensory helpers
  // ---------------------------------------------------------------------------

  /// Use SimulationEngine's sensing API to find nearest food and return
  /// normalised distance. Returns 1.0 if no food is found within scan radius.
  double _nearestFoodDistance(SimulationEngine sim, int x, int y) {
    const scanRadius = 16;

    // Use engine's findNearestDirection for organic elements (food).
    // ElCat.organic includes seeds and plants.
    final foodDir = sim.findNearestDirection(x, y, scanRadius, ElCat.organic);
    if (foodDir < 0) return 1.0;

    // Found food -- count nearby to estimate proximity.
    final foodCount = sim.countNearbyByCategory(x, y, 5, ElCat.organic);
    if (foodCount > 0) return 0.1; // Very close food.

    final midCount = sim.countNearbyByCategory(x, y, 10, ElCat.organic);
    if (midCount > 0) return 0.4; // Medium distance food.

    return 0.7; // Far food (found within 16 but not within 10).
  }

  /// Compute a gradient signal from pheromone concentrations in the
  /// 4 cardinal directions.
  double _pheromoneGradient(PheromoneSystem pheromones, int x, int y) {
    final left = pheromones.read(x - 1, y);
    final right = pheromones.read(x + 1, y);
    final up = pheromones.read(x, y - 1);
    final down = pheromones.read(x, y + 1);

    final horizontal = right - left;
    final vertical = down - up;

    final magnitude = horizontal.abs() + vertical.abs();
    if (magnitude < 0.001) return 0.0;
    return (horizontal + vertical) / (2.0 * magnitude);
  }

  /// Convert a continuous [-1, 1] output to a discrete {-1, 0, 1} movement.
  int _discretise(double value) {
    if (value > 0.33) return 1;
    if (value < -0.33) return -1;
    return 0;
  }
}

/// The action an ant's neural network has decided to take this tick.
class AntAction {
  const AntAction({
    required this.dx,
    required this.dy,
    required this.pheromoneStrength,
    required this.wantsPickUp,
    required this.wantsDrop,
    required this.wantsAttack,
  });

  final int dx;
  final int dy;
  final double pheromoneStrength;
  final bool wantsPickUp;
  final bool wantsDrop;
  final bool wantsAttack;
}
