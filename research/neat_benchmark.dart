/// Headless NEAT simulation harness for autoresearch.
///
/// Runs a full SimulationEngine + Colony lifecycle without any Flutter/Flame
/// dependencies. Used by [runExperiment] to evaluate NEAT configurations
/// across different environments.
///
/// Usage:
/// ```dart
/// final bench = NeatBenchmark(
///   config: ExperimentConfig.baseline(),
///   environment: EasyMeadow(),
/// );
/// final result = bench.run();
/// print(result.toJson());
/// ```
library;

import 'dart:math';

import 'package:the_particle_engine/creatures/colony.dart';
import 'package:the_particle_engine/creatures/creature_registry.dart';
import 'package:the_particle_engine/creatures/neat/neat_config.dart';
import 'package:the_particle_engine/simulation/element_behaviors.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';
import 'package:the_particle_engine/simulation/world_gen/grid_data.dart';
import 'package:the_particle_engine/simulation/world_gen/world_generator.dart';
import 'neat_config.dart' as research;
import 'environments/environment.dart';

// ---------------------------------------------------------------------------
// Checkpoint schedule (tick numbers where metrics are sampled)
// ---------------------------------------------------------------------------

const List<int> defaultCheckpoints = [
  300, 600, 1200, 2400, 4800, 9000, 13500, 18000,
];

// ---------------------------------------------------------------------------
// Composite fitness score
// ---------------------------------------------------------------------------

/// The six components of the composite colony fitness metric.
class CompositeScore {
  const CompositeScore({
    required this.colonySurvival,
    required this.foodCollection,
    required this.territoryExploration,
    required this.buildingComplexity,
    required this.threatResponse,
    required this.cooperationScore,
  });

  /// Population fraction at end of run (0-1).
  final double colonySurvival;

  /// Food stored / starting food, clamped to [0, 3] then normalised.
  final double foodCollection;

  /// Fraction of reachable cells explored.
  final double territoryExploration;

  /// Nest chambers / 20, clamped to [0, 1].
  final double buildingComplexity;

  /// Survival rate in presence of hazards.
  final double threatResponse;

  /// Food delivered / food foraged ratio.
  final double cooperationScore;

  /// Weighted composite (see program.md for weights).
  double get composite =>
      colonySurvival * 0.20 +
      foodCollection * 0.25 +
      territoryExploration * 0.15 +
      buildingComplexity * 0.10 +
      threatResponse * 0.15 +
      cooperationScore * 0.15;

  Map<String, dynamic> toJson() => {
        'colony_survival': r4(colonySurvival),
        'food_collection': r4(foodCollection),
        'territory_exploration': r4(territoryExploration),
        'building_complexity': r4(buildingComplexity),
        'threat_response': r4(threatResponse),
        'cooperation_score': r4(cooperationScore),
        'composite': r4(composite),
      };

  /// Round to 4 decimal places for JSON output.
  static double r4(double v) => double.parse(v.toStringAsFixed(4));
}

// ---------------------------------------------------------------------------
// Benchmark result types
// ---------------------------------------------------------------------------

/// Metrics captured at a single checkpoint.
class CheckpointMetrics {
  CheckpointMetrics({
    required this.tick,
    required this.avgFitness,
    required this.maxFitness,
    required this.population,
    required this.foodStored,
    required this.speciesCount,
    required this.avgComplexity,
    required this.avgConnections,
    required this.totalSpawned,
    required this.totalDied,
  });

  final int tick;
  final double avgFitness;
  final double maxFitness;
  final int population;
  final int foodStored;
  final int speciesCount;
  final double avgComplexity;
  final double avgConnections;
  final int totalSpawned;
  final int totalDied;

  Map<String, dynamic> toJson() => {
        'tick': tick,
        'avgFitness': double.parse(avgFitness.toStringAsFixed(4)),
        'maxFitness': double.parse(maxFitness.toStringAsFixed(4)),
        'population': population,
        'foodStored': foodStored,
        'speciesCount': speciesCount,
        'avgComplexity': double.parse(avgComplexity.toStringAsFixed(2)),
        'avgConnections': double.parse(avgConnections.toStringAsFixed(1)),
        'totalSpawned': totalSpawned,
        'totalDied': totalDied,
      };
}

/// Full result of a benchmark run.
class BenchmarkResult {
  BenchmarkResult({
    required this.experimentName,
    required this.environmentName,
    required this.seed,
    required this.durationTicks,
    required this.checkpoints,
    required this.championGenome,
    required this.neatConfig,
    required this.elapsedMs,
    required this.compositeScore,
    this.configDiff = const {},
  });

  final String experimentName;
  final String environmentName;
  final int seed;
  final int durationTicks;
  final List<CheckpointMetrics> checkpoints;
  final Map<String, dynamic>? championGenome;
  final Map<String, dynamic> neatConfig;
  final int elapsedMs;
  final CompositeScore compositeScore;
  final Map<String, dynamic> configDiff;

  /// Final checkpoint metrics (or null if no checkpoints).
  CheckpointMetrics? get finalMetrics =>
      checkpoints.isNotEmpty ? checkpoints.last : null;

  Map<String, dynamic> toJson() => {
        'experiment': experimentName,
        'environment': environmentName,
        'seed': seed,
        'duration_ticks': durationTicks,
        'elapsed_ms': elapsedMs,
        'composite_score': compositeScore.composite,
        'components': compositeScore.toJson(),
        'checkpoints': checkpoints.map((c) => c.toJson()).toList(),
        'champion': championGenome,
        'config': neatConfig,
        if (configDiff.isNotEmpty) 'config_diff': configDiff,
      };
}

// ---------------------------------------------------------------------------
// The benchmark harness
// ---------------------------------------------------------------------------

/// Headless NEAT benchmark that runs a full simulation without rendering.
///
/// Creates a SimulationEngine, loads an environment's world, spawns a colony,
/// and ticks both physics and creatures for the configured duration.
class NeatBenchmark {
  NeatBenchmark({
    required this.config,
    required this.environment,
    this.checkpoints = defaultCheckpoints,
  });

  /// Experiment configuration (contains NeatConfig, seed, duration, etc.).
  final research.ExperimentConfig config;

  /// Evaluation environment (world setup + colony placement).
  final Environment environment;

  /// Tick numbers at which to capture metrics.
  final List<int> checkpoints;

  /// Run the full benchmark and return results.
  BenchmarkResult run() {
    final stopwatch = Stopwatch()..start();

    // -- Set up the simulation engine ----------------------------------------
    final engine = SimulationEngine(
      gridW: environment.worldConfig.width,
      gridH: environment.worldConfig.height,
    );

    // -- Generate and load the world -----------------------------------------
    final GridData gridData;
    if (environment.useBlankWorld) {
      gridData = WorldGenerator.generateBlank(
        environment.worldConfig.width,
        environment.worldConfig.height,
      );
    } else {
      gridData = WorldGenerator.generate(environment.worldConfig);
    }
    gridData.loadIntoEngine(engine);

    // -- Apply any environment-specific grid modifications -------------------
    environment.modifyGrid(engine);

    // -- Spawn colony --------------------------------------------------------
    final registry = CreatureRegistry();
    final colonyOrigin = environment.colonyOrigin;
    final colony = registry.spawn(
      colonyOrigin.$1,
      colonyOrigin.$2,
      seed: config.seed,
    );

    // Override colony food if configured.
    colony.foodStored = config.startingFood;

    // Track starting population cap for composite score.
    final popCap = config.maxAnts;

    // -- Spawn additional colonies if the environment defines them -----------
    final extraColonies = environment.extraColonies;
    for (final pos in extraColonies) {
      final rival = registry.spawn(
        pos.$1, pos.$2,
        seed: config.seed + pos.$1 + pos.$2,
      );
      rival.foodStored = config.startingFood;
    }

    // -- Track cumulative foraging stats ------------------------------------
    int cumulativeForaged = 0;
    int cumulativeDelivered = 0;

    // -- Run the simulation -------------------------------------------------
    final results = <CheckpointMetrics>[];
    final sortedCheckpoints = List<int>.from(checkpoints)..sort();
    int nextCheckpointIdx = 0;

    final maxTicks = config.maxTicks;
    final safetyLimit = maxTicks * 2; // Kill runaway experiments.

    for (int tick = 0; tick < safetyLimit; tick++) {
      // Physics step (real element behaviors).
      engine.step(simulateElement);

      // Wind (if configured).
      if (engine.windForce != 0) {
        engine.applyWind();
      }

      // Snapshot pre-tick food stats for delta tracking.
      final preFoodStored = colony.foodStored;

      // Creature step.
      registry.tick(engine);

      // Track food deltas (approximate: food going up means deliveries).
      final foodDelta = colony.foodStored - preFoodStored;
      if (foodDelta > 0) cumulativeDelivered += foodDelta;

      // Check for checkpoint.
      if (nextCheckpointIdx < sortedCheckpoints.length &&
          tick + 1 >= sortedCheckpoints[nextCheckpointIdx]) {
        results.add(_captureMetrics(colony, tick + 1));
        nextCheckpointIdx++;
      }

      // Done if we've hit all checkpoints and reached max ticks.
      if (tick + 1 >= maxTicks &&
          nextCheckpointIdx >= sortedCheckpoints.length) {
        break;
      }

      // Early termination: colony extinct and can't recover.
      if (tick > 600 && !colony.isAlive) {
        while (nextCheckpointIdx < sortedCheckpoints.length) {
          results.add(
              _captureMetrics(colony, sortedCheckpoints[nextCheckpointIdx]));
          nextCheckpointIdx++;
        }
        break;
      }
    }

    stopwatch.stop();

    // -- Compute composite score --------------------------------------------
    // Approximate total foraged from total spawned/died + food trajectory.
    cumulativeForaged = max(cumulativeDelivered, colony.totalSpawned ~/ 2);

    final composite = _computeComposite(
      colony: colony,
      popCap: popCap,
      startingFood: config.startingFood,
      totalReachableCells: engine.gridW * engine.gridH,
      isHostile: environment.difficulty == Difficulty.hard,
      cumulativeForaged: cumulativeForaged,
      cumulativeDelivered: cumulativeDelivered,
    );

    return BenchmarkResult(
      experimentName: config.name,
      environmentName: environment.name,
      seed: config.seed,
      durationTicks: maxTicks,
      checkpoints: results,
      championGenome: colony.evolution.champion?.toJson(),
      neatConfig: _serializeNeatConfig(config.neatConfig),
      elapsedMs: stopwatch.elapsedMilliseconds,
      compositeScore: composite,
      configDiff: config.configDiff,
    );
  }

  /// Compute the 6-component composite fitness score.
  CompositeScore _computeComposite({
    required Colony colony,
    required int popCap,
    required int startingFood,
    required int totalReachableCells,
    required bool isHostile,
    required int cumulativeForaged,
    required int cumulativeDelivered,
  }) {
    // 1. Colony Survival: population fraction + alive bonus.
    final survivalBase = popCap > 0
        ? (colony.population / popCap).clamp(0.0, 1.0)
        : 0.0;
    final colonySurvival =
        (survivalBase + (colony.isAlive ? 0.1 : 0.0)).clamp(0.0, 1.0);

    // 2. Food Collection: food stored / starting food, clamped and normalised.
    final foodRaw = startingFood > 0
        ? colony.foodStored / startingFood
        : 0.0;
    final foodCollection = (foodRaw / 3.0).clamp(0.0, 1.0);

    // 3. Territory Exploration: explored cells / total cells.
    // Sum explored cells across all living ants.
    int totalExplored = 0;
    for (final ant in colony.ants) {
      totalExplored += ant.fitness.exploredCells;
    }
    final territoryExploration = totalReachableCells > 0
        ? (totalExplored / totalReachableCells).clamp(0.0, 1.0)
        : 0.0;

    // 4. Building Complexity: nest chambers / 20.
    final buildingComplexity =
        (colony.nestChambers.length / 20.0).clamp(0.0, 1.0);

    // 5. Threat Response: survival rate in hostile environments.
    final double threatResponse;
    if (isHostile) {
      threatResponse = colony.totalSpawned > 0
          ? ((colony.totalSpawned - colony.totalDied) / colony.totalSpawned)
              .clamp(0.0, 1.0)
          : 0.0;
    } else {
      threatResponse = 0.5; // Neutral in safe environments.
    }

    // 6. Cooperation Score: delivered / foraged ratio.
    final cooperationScore = cumulativeForaged > 0
        ? (cumulativeDelivered / cumulativeForaged).clamp(0.0, 1.0)
        : 0.0;

    return CompositeScore(
      colonySurvival: colonySurvival,
      foodCollection: foodCollection,
      territoryExploration: territoryExploration,
      buildingComplexity: buildingComplexity,
      threatResponse: threatResponse,
      cooperationScore: cooperationScore,
    );
  }

  /// Capture colony metrics at the current tick.
  CheckpointMetrics _captureMetrics(Colony colony, int tick) {
    final evo = colony.evolution;
    final pop = evo.population;

    return CheckpointMetrics(
      tick: tick,
      avgFitness: colony.averageAntFitness,
      maxFitness: evo.champion?.fitness ?? 0.0,
      population: colony.population,
      foodStored: colony.foodStored,
      speciesCount: evo.speciesCount,
      avgComplexity: evo.averageComplexity,
      avgConnections: pop.averageConnections,
      totalSpawned: colony.totalSpawned,
      totalDied: colony.totalDied,
    );
  }

  /// Serialize NeatConfig to a JSON map for results recording.
  Map<String, dynamic> _serializeNeatConfig(NeatConfig config) => {
        'populationSize': config.populationSize,
        'compatThreshold': config.compatThreshold,
        'compatThresholdDelta': config.compatThresholdDelta,
        'targetSpeciesCount': config.targetSpeciesCount,
        'weightMutationRate': config.weightMutationRate,
        'weightPerturbPower': config.weightPerturbPower,
        'addConnectionRate': config.addConnectionRate,
        'addNodeRate': config.addNodeRate,
        'deleteConnectionRate': config.deleteConnectionRate,
        'activationMutationRate': config.activationMutationRate,
        'crossoverRate': config.crossoverRate,
        'interspeciesCrossoverRate': config.interspeciesCrossoverRate,
        'elitismCount': config.elitismCount,
        'survivalThreshold': config.survivalThreshold,
        'stagnationLimit': config.stagnationLimit,
        'rtReplacementInterval': config.rtReplacementInterval,
        'rtMinLifetime': config.rtMinLifetime,
        'maxHiddenNodes': config.maxHiddenNodes,
        'maxConnections': config.maxConnections,
        'defaultActivation': config.defaultActivation.name,
      };
}
