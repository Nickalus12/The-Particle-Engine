/// Experiment runner for the NEAT autoresearch loop.
///
/// Orchestrates benchmark runs, compares results against baseline, logs to
/// `experiment_log.jsonl`, keeps improvements, discards regressions.
/// Supports single-shot and continuous loop mode.
///
/// Usage (from project root):
/// ```bash
/// dart run research/run_experiment.dart
/// dart run research/run_experiment.dart --seeds 5
/// dart run research/run_experiment.dart --env hostile_world
/// dart run research/run_experiment.dart --loop
/// dart run research/run_experiment.dart --all --seeds 5
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:the_particle_engine/creatures/neat/neat_config.dart';
import 'environments/complex_terrain.dart';
import 'environments/easy_meadow.dart';
import 'environments/environment.dart';
import 'environments/hostile_world.dart';
import 'environments/multi_colony.dart';
import 'environments/survival_challenge.dart';
import 'export_queens.dart';
import 'neat_benchmark.dart';
import 'neat_config.dart';

// ---------------------------------------------------------------------------
// Environment registry
// ---------------------------------------------------------------------------

/// Create an environment by name.
Environment createEnvironment(String name, {int seed = 42}) {
  switch (name) {
    case 'easy_meadow':
      return EasyMeadow(seed: seed);
    case 'survival_challenge':
      return SurvivalChallenge(seed: seed);
    case 'hostile_world':
      return HostileWorld(seed: seed);
    case 'multi_colony':
      return MultiColony(seed: seed);
    case 'complex_terrain':
      return ComplexTerrain(seed: seed);
    default:
      throw ArgumentError('Unknown environment: $name');
  }
}

/// All available environment names.
const allEnvironmentNames = [
  'easy_meadow',
  'survival_challenge',
  'hostile_world',
  'multi_colony',
  'complex_terrain',
];

// ---------------------------------------------------------------------------
// Experiment log (JSONL append-only log)
// ---------------------------------------------------------------------------

final _logFile = File('research/results/experiment_log.jsonl');

/// Append a single experiment result to the JSONL log.
void logExperiment(BenchmarkResult result, {
  double? baselineComposite,
  String? verdict,
}) {
  final dir = Directory('research/results');
  if (!dir.existsSync()) dir.createSync(recursive: true);

  final improvementRatio = baselineComposite != null && baselineComposite > 0
      ? result.compositeScore.composite / baselineComposite
      : 1.0;

  final entry = {
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'experiment': result.experimentName,
    'environment': result.environmentName,
    'seed': result.seed,
    'duration_ticks': result.durationTicks,
    'elapsed_ms': result.elapsedMs,
    if (result.configDiff.isNotEmpty) 'config_diff': result.configDiff,
    'composite_score': CompositeScore.r4(result.compositeScore.composite),
    'components': result.compositeScore.toJson(),
    'checkpoints': result.checkpoints.map((c) => c.toJson()).toList(),
    if (baselineComposite != null)
      'baseline_composite': CompositeScore.r4(baselineComposite),
    if (baselineComposite != null)
      'improvement_ratio': CompositeScore.r4(improvementRatio),
    'verdict': verdict ?? _determineVerdict(improvementRatio),
  };

  _logFile.writeAsStringSync(
    '${jsonEncode(entry)}\n',
    mode: FileMode.append,
  );
  stdout.writeln('  Logged to experiment_log.jsonl');
}

/// Determine keep/neutral/discard verdict from improvement ratio.
String _determineVerdict(double ratio) {
  if (ratio >= 1.10) return 'keep';
  if (ratio >= 0.95) return 'neutral';
  return 'discard';
}

// ---------------------------------------------------------------------------
// Baseline comparison (composite-score based)
// ---------------------------------------------------------------------------

/// Compare an experiment result against a baseline using composite scores.
Map<String, dynamic> compareToBaseline(
    BenchmarkResult experiment, BenchmarkResult baseline) {
  final expComposite = experiment.compositeScore.composite;
  final baseComposite = baseline.compositeScore.composite;

  final ratio = baseComposite > 0
      ? expComposite / baseComposite
      : (expComposite > 0 ? double.infinity : 1.0);

  final verdict = _determineVerdict(ratio);

  return {
    'baseline_composite': CompositeScore.r4(baseComposite),
    'experiment_composite': CompositeScore.r4(expComposite),
    'improvement_ratio': CompositeScore.r4(ratio),
    'verdict': verdict,
  };
}

// ---------------------------------------------------------------------------
// Single run
// ---------------------------------------------------------------------------

/// Run a single experiment (one config, one environment, one seed).
BenchmarkResult runSingle({
  required ExperimentConfig config,
  required String environmentName,
}) {
  final env = createEnvironment(environmentName, seed: config.seed);
  final bench = NeatBenchmark(config: config, environment: env);

  stdout.write('  Running ${config.name} on $environmentName '
      '(seed=${config.seed})... ');
  final result = bench.run();
  stdout.writeln('done (${result.elapsedMs}ms, '
      'composite=${result.compositeScore.composite.toStringAsFixed(4)})');

  return result;
}

/// Run an experiment across multiple seeds and return all results.
List<BenchmarkResult> runMultiSeed({
  required ExperimentConfig config,
  required String environmentName,
  required int seedCount,
}) {
  final results = <BenchmarkResult>[];
  for (int i = 0; i < seedCount; i++) {
    final seedConfig = config.withSeed(42 + i * 1000);
    results.add(
        runSingle(config: seedConfig, environmentName: environmentName));
  }
  return results;
}

/// Save a detailed result JSON to the results directory.
void saveDetailedResult(BenchmarkResult result,
    {Map<String, dynamic>? comparison}) {
  final dir = Directory('research/results');
  if (!dir.existsSync()) dir.createSync(recursive: true);

  final json = result.toJson();
  if (comparison != null) {
    json['baseline_comparison'] = comparison;
  }

  final filename =
      '${result.experimentName}_${result.environmentName}_s${result.seed}.json';
  final file = File('${dir.path}/$filename');
  file.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(json),
  );
  stdout.writeln('  Saved: ${file.path}');
}

// ---------------------------------------------------------------------------
// Predefined experiment variants (ablation studies)
// ---------------------------------------------------------------------------

/// Standard ablation variants that test one NEAT parameter at a time.
List<ExperimentConfig> ablationVariants() => [
      const ExperimentConfig(name: 'baseline'),

      // Higher mutation rate.
      const ExperimentConfig(
        name: 'high_mutation',
        neatConfig: NeatConfig(
          weightMutationRate: 0.95,
          weightPerturbPower: 0.8,
          addConnectionRate: 0.10,
          addNodeRate: 0.06,
        ),
        configDiff: {
          'weightMutationRate': 0.95,
          'weightPerturbPower': 0.8,
          'addConnectionRate': 0.10,
          'addNodeRate': 0.06,
        },
      ),

      // Lower mutation rate (more exploitation).
      const ExperimentConfig(
        name: 'low_mutation',
        neatConfig: NeatConfig(
          weightMutationRate: 0.5,
          weightPerturbPower: 0.3,
          addConnectionRate: 0.02,
          addNodeRate: 0.01,
        ),
        configDiff: {
          'weightMutationRate': 0.5,
          'weightPerturbPower': 0.3,
          'addConnectionRate': 0.02,
          'addNodeRate': 0.01,
        },
      ),

      // Larger population.
      const ExperimentConfig(
        name: 'large_pop',
        neatConfig: NeatConfig(populationSize: 300),
        configDiff: {'populationSize': 300},
      ),

      // Smaller population (faster turnover).
      const ExperimentConfig(
        name: 'small_pop',
        neatConfig: NeatConfig(populationSize: 50),
        configDiff: {'populationSize': 50},
      ),

      // Aggressive rt-NEAT replacement.
      const ExperimentConfig(
        name: 'fast_replace',
        neatConfig: NeatConfig(
          rtReplacementInterval: 10,
          rtMinLifetime: 50,
        ),
        configDiff: {'rtReplacementInterval': 10, 'rtMinLifetime': 50},
      ),

      // Conservative rt-NEAT replacement.
      const ExperimentConfig(
        name: 'slow_replace',
        neatConfig: NeatConfig(
          rtReplacementInterval: 50,
          rtMinLifetime: 200,
        ),
        configDiff: {'rtReplacementInterval': 50, 'rtMinLifetime': 200},
      ),

      // More species diversity.
      const ExperimentConfig(
        name: 'high_speciation',
        neatConfig: NeatConfig(
          compatThreshold: 2.0,
          targetSpeciesCount: 20,
        ),
        configDiff: {'compatThreshold': 2.0, 'targetSpeciesCount': 20},
      ),

      // Sigmoid activation instead of tanh.
      const ExperimentConfig(
        name: 'sigmoid_activation',
        neatConfig: NeatConfig(
          defaultActivation: ActivationFunction.sigmoid,
        ),
        configDiff: {'defaultActivation': 'sigmoid'},
      ),

      // ReLU activation.
      const ExperimentConfig(
        name: 'relu_activation',
        neatConfig: NeatConfig(
          defaultActivation: ActivationFunction.relu,
        ),
        configDiff: {'defaultActivation': 'relu'},
      ),
    ];

// ---------------------------------------------------------------------------
// Loop mode
// ---------------------------------------------------------------------------

/// Run the continuous research loop.
///
/// Cycles through all variants on the given environment, comparing each to
/// baseline. Keeps running until interrupted (Ctrl+C).
void runLoop({
  required String environmentName,
  required int seedCount,
}) {
  stdout.writeln('=== Entering loop mode (Ctrl+C to stop) ===\n');

  int iteration = 0;
  final variants = ablationVariants();

  while (true) {
    iteration++;
    stdout.writeln('\n--- Loop iteration $iteration ---');

    // Run/refresh baseline.
    final baseline = runSingle(
      config: ExperimentConfig.baseline(),
      environmentName: environmentName,
    );
    logExperiment(baseline, verdict: 'baseline');

    final baselineComposite = baseline.compositeScore.composite;

    // Run each variant.
    for (final variant in variants) {
      if (variant.name == 'baseline') continue;

      stdout.writeln('\n  Variant: ${variant.name}');
      final results = runMultiSeed(
        config: variant,
        environmentName: environmentName,
        seedCount: seedCount,
      );

      // Check if improvement holds across seeds.
      int keepCount = 0;
      for (final result in results) {
        final comparison = compareToBaseline(result, baseline);
        final verdict = comparison['verdict'] as String;

        logExperiment(
          result,
          baselineComposite: baselineComposite,
          verdict: verdict,
        );
        saveDetailedResult(result, comparison: comparison);

        if (verdict == 'keep') keepCount++;

        // Export seed queen for exceptional results.
        if (verdict == 'keep' && result.championGenome != null) {
          final ratio = comparison['improvement_ratio'] as double;
          if (ratio >= 2.0) {
            exportSeedQueen(
              genome: result.championGenome!,
              environment: environmentName,
              seed: result.seed,
              fitness: result.finalMetrics?.maxFitness ?? 0.0,
              complexity: result.finalMetrics?.avgComplexity ?? 0.0,
            );
          }
        }
      }

      final robust = keepCount >= (seedCount * 3 / 5).ceil();
      stdout.writeln('  ${variant.name}: $keepCount/$seedCount seeds kept '
          '(${robust ? "ROBUST" : "not robust"})');
    }

    stdout.writeln('\n--- Iteration $iteration complete ---');
    // In a real continuous loop, you might sleep or wait for a signal here.
    // For now, one full cycle then exit. Use --loop repeatedly for continuous.
    // To make truly infinite, remove this break.
    break;
  }
}

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

void main(List<String> args) {
  // Parse arguments.
  int seedCount = 1;
  String? envFilter;
  String? variantFilter;
  bool runAll = false;
  bool loopMode = false;

  for (int i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--seeds':
        seedCount = int.parse(args[++i]);
      case '--env':
        envFilter = args[++i];
      case '--variant':
        variantFilter = args[++i];
      case '--all':
        runAll = true;
      case '--loop':
        loopMode = true;
      case '--help':
        _printUsage();
        return;
    }
  }

  stdout.writeln('=== NEAT Autoresearch Loop ===\n');

  final environmentName = envFilter ?? 'easy_meadow';

  // Loop mode: run all variants continuously.
  if (loopMode) {
    runLoop(environmentName: environmentName, seedCount: seedCount);
    stdout.writeln('\n=== Loop complete ===');
    return;
  }

  // Single-shot mode.
  final environments = envFilter != null ? [envFilter] : ['easy_meadow'];

  // Determine which variants to run.
  final variants = runAll
      ? ablationVariants()
      : variantFilter != null
          ? ablationVariants().where((v) => v.name == variantFilter).toList()
          : [ExperimentConfig.baseline()];

  if (variants.isEmpty) {
    stderr.writeln('No matching variants found.');
    exit(1);
  }

  // Run baseline first for comparison.
  stdout.writeln('--- Running baseline ---');
  final baselineResults = <String, BenchmarkResult>{};
  for (final envName in environments) {
    final baseline = runSingle(
      config: ExperimentConfig.baseline(),
      environmentName: envName,
    );
    baselineResults[envName] = baseline;
    logExperiment(baseline, verdict: 'baseline');
    saveDetailedResult(baseline);
  }

  // Run each variant.
  for (final variant in variants) {
    if (variant.name == 'baseline') continue;

    stdout.writeln('\n--- Running variant: ${variant.name} ---');
    for (final envName in environments) {
      final results = runMultiSeed(
        config: variant,
        environmentName: envName,
        seedCount: seedCount,
      );

      for (final result in results) {
        final comparison = compareToBaseline(result, baselineResults[envName]!);
        final verdict = comparison['verdict'] as String;
        final baselineComposite =
            baselineResults[envName]!.compositeScore.composite;

        logExperiment(
          result,
          baselineComposite: baselineComposite,
          verdict: verdict,
        );
        saveDetailedResult(result, comparison: comparison);

        // Export seed queen if significantly better than baseline.
        if (verdict == 'keep' && result.championGenome != null) {
          final ratio = comparison['improvement_ratio'] as double;
          if (ratio >= 2.0) {
            exportSeedQueen(
              genome: result.championGenome!,
              environment: envName,
              seed: result.seed,
              fitness: result.finalMetrics?.maxFitness ?? 0.0,
              complexity: result.finalMetrics?.avgComplexity ?? 0.0,
            );
          }
        }
      }
    }
  }

  stdout.writeln('\n=== Research complete ===');
}

void _printUsage() {
  stdout.writeln('''
NEAT Autoresearch Experiment Runner

Usage: dart run research/run_experiment.dart [options]

Options:
  --seeds N        Run each variant with N different seeds (default: 1)
  --env NAME       Run only on this environment (default: easy_meadow)
  --variant NAME   Run only this variant (default: baseline only)
  --all            Run all ablation variants
  --loop           Run continuous loop mode (all variants, compare to baseline)
  --help           Show this help

Environments:
  easy_meadow, survival_challenge, hostile_world, multi_colony, complex_terrain

Variants:
  baseline, high_mutation, low_mutation, large_pop, small_pop,
  fast_replace, slow_replace, high_speciation, sigmoid_activation, relu_activation

Output:
  research/results/experiment_log.jsonl  -- append-only JSONL log of all runs
  research/results/<name>_<env>_s<seed>.json -- detailed per-run results
  assets/seed_queens/<env>_s<seed>_f<fitness>.json -- exported champion genomes
''');
}
