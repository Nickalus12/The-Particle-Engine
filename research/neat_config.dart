/// Experiment-level configuration for the autoresearch loop.
///
/// Wraps [NeatConfig] with additional parameters specific to experiments:
/// seed, duration, starting food, environment selection, etc.
///
/// This is separate from `lib/creatures/neat/neat_config.dart` which defines
/// the NEAT algorithm hyperparameters. This file defines the experiment
/// harness parameters.
library;

import 'package:the_particle_engine/creatures/neat/neat_config.dart';

/// Configuration for a single experiment run.
class ExperimentConfig {
  const ExperimentConfig({
    required this.name,
    this.neatConfig = const NeatConfig(),
    this.seed = 42,
    this.maxTicks = 18000,
    this.startingFood = 20,
    this.maxAnts = 200,
    this.configDiff = const {},
  });

  /// Human-readable experiment name.
  final String name;

  /// NEAT algorithm hyperparameters.
  final NeatConfig neatConfig;

  /// Random seed for deterministic reproduction.
  final int seed;

  /// Maximum simulation ticks before the experiment ends.
  /// Default: 18,000 (~5 minutes at 60fps).
  final int maxTicks;

  /// Starting food reserves for the colony.
  final int startingFood;

  /// Maximum ants per colony (not enforced here, but recorded for reference).
  final int maxAnts;

  /// Map of parameter names to values that differ from baseline defaults.
  /// Used for logging which knobs were turned in this experiment.
  final Map<String, dynamic> configDiff;

  /// The baseline experiment: default NeatConfig, seed 42, standard duration.
  factory ExperimentConfig.baseline() => const ExperimentConfig(
        name: 'baseline',
      );

  /// Create a variant with a different NEAT config for ablation testing.
  ExperimentConfig withNeatConfig(
    String variantName,
    NeatConfig config,
    Map<String, dynamic> diff,
  ) =>
      ExperimentConfig(
        name: variantName,
        neatConfig: config,
        seed: seed,
        maxTicks: maxTicks,
        startingFood: startingFood,
        maxAnts: maxAnts,
        configDiff: diff,
      );

  /// Create the same experiment with a different seed.
  ExperimentConfig withSeed(int newSeed) => ExperimentConfig(
        name: name,
        neatConfig: neatConfig,
        seed: newSeed,
        maxTicks: maxTicks,
        startingFood: startingFood,
        maxAnts: maxAnts,
        configDiff: configDiff,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'seed': seed,
        'maxTicks': maxTicks,
        'startingFood': startingFood,
        'maxAnts': maxAnts,
        if (configDiff.isNotEmpty) 'configDiff': configDiff,
      };
}
