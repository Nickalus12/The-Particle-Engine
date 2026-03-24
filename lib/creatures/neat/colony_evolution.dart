import 'dart:math';

import 'ant_brain.dart';
import 'neat_config.dart';
import 'neat_forward.dart';
import 'neat_genome.dart';
import 'neat_population.dart';

/// Manages the evolutionary lifecycle of one ant colony's neural population.
///
/// Each colony owns a [NeatPopulation] that evolves in real-time (rt-NEAT).
/// Individual ants are spawned from genomes in the population. When an ant
/// dies, its fitness is recorded and the worst-performing genome may be
/// replaced with offspring from successful ants.
///
/// This creates the emergent colony personality: colonies under attack evolve
/// aggressive ants, colonies near food evolve efficient foragers, etc.
///
/// ## Lifecycle
///
/// ```dart
/// final evo = ColonyEvolution(config: antConfig);
/// evo.initialize();
///
/// // Each tick:
/// evo.tick();
///
/// // Spawn a new ant:
/// final ant = evo.spawnAnt();
///
/// // When ant dies:
/// evo.reportDeath(ant.genomeIndex, ant.fitness);
/// ```
class ColonyEvolution {
  ColonyEvolution({
    NeatConfig? config,
    int? seed,
  }) : _config = config ?? const NeatConfig(),
       _seed = seed;

  final NeatConfig _config;
  final int? _seed;
  late final NeatPopulation _population;
  int _tickCount = 0;

  /// Whether the population has been initialized.
  bool _initialized = false;

  /// Cache of compiled networks, keyed by genome index in the population.
  /// Rebuilt when a genome is replaced.
  final Map<int, NeatForward> _networkCache = {};

  /// Initialize the evolutionary population.
  void initialize() {
    _population = NeatPopulation(_config, seed: _seed);
    _population.initialize();
    _initialized = true;
    _rebuildAllNetworks();
  }

  /// Advance the evolutionary clock by one simulation tick.
  ///
  /// Ages all organisms. Every [rtReplacementInterval] ticks, performs
  /// one rt-NEAT replacement step (removes worst, spawns offspring).
  void tick() {
    if (!_initialized) return;

    _tickCount++;
    _population.ageAll();

    if (_tickCount % _config.rtReplacementInterval == 0) {
      _population.rtReplace();

      // Surgical cache invalidation
      final changedIdx = _population.lastReplacedIndex;
      if (changedIdx >= 0 && changedIdx < _population.genomes.length) {
         _networkCache[changedIdx] = NeatForward.fromGenome(_population.genomes[changedIdx]);
      }
    }
  }

  /// Create an [AntBrain] for the genome at [index] in the population.
  ///
  /// The compiled network is cached so repeated calls for the same genome
  /// don't re-compile.
  AntBrain brainForGenome(int index) {
    if (index < 0 || index >= _population.genomes.length) {
      throw RangeError('Genome index $index out of range');
    }
    return AntBrain(genome: _population.genomes[index]);
  }

  /// Report fitness for a genome (e.g., when an ant dies or periodically).
  void reportFitness(int genomeIndex, double fitness) {
    if (genomeIndex >= 0 && genomeIndex < _population.genomes.length) {
      _population.genomes[genomeIndex].fitness = fitness;
    }
  }

  /// Get a random genome index for spawning a new ant.
  ///
  /// Biased toward higher-fitness genomes via tournament selection.
  int selectGenomeForSpawn(Random rng) {
    if (_population.genomes.isEmpty) return 0;

    // Simple tournament: pick 3 random, return the fittest.
    int bestIdx = rng.nextInt(_population.genomes.length);
    double bestFit = _population.genomes[bestIdx].fitness;

    for (var i = 0; i < 2; i++) {
      final idx = rng.nextInt(_population.genomes.length);
      if (_population.genomes[idx].fitness > bestFit) {
        bestIdx = idx;
        bestFit = _population.genomes[idx].fitness;
      }
    }
    return bestIdx;
  }

  /// Number of genomes in the population.
  int get populationSize => _population.genomes.length;

  /// The champion genome (highest fitness ever seen).
  NeatGenome? get champion => _population.champion;

  /// Average fitness across the population.
  double get averageFitness => _population.averageFitness;

  /// Average hidden node count (indicator of network complexity).
  double get averageComplexity => _population.averageHiddenNodes;

  /// Number of species.
  int get speciesCount => _population.speciesManager.count;

  /// Current tick count.
  int get tickCount => _tickCount;

  /// Direct access to the population for serialization / debugging.
  NeatPopulation get population => _population;

  /// Replace the live population with restored genomes and rebuild caches.
  void restorePopulation(List<NeatGenome> genomes) {
    if (!_initialized) {
      initialize();
    }
    _population.genomes
      ..clear()
      ..addAll(genomes.map((genome) => genome.copy()));
    _rebuildAllNetworks();
  }

  void _rebuildAllNetworks() {
    _networkCache.clear();
    for (var i = 0; i < _population.genomes.length; i++) {
      _networkCache[i] = NeatForward.fromGenome(_population.genomes[i]);
    }
  }
}
