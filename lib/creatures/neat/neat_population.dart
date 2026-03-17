import 'dart:math';

import 'neat_config.dart';
import 'neat_genome.dart';
import 'neat_species.dart';

/// Manages the population of NEAT genomes and drives evolution.
///
/// Supports two modes:
///
/// 1. **Generational** — the classic approach. All organisms are evaluated,
///    then an entire new generation is produced via selection, crossover,
///    and mutation. Use [epoch] to advance one generation.
///
/// 2. **rt-NEAT (real-time)** — a steady-state approach where the population
///    is continuously evaluated. The worst organisms are periodically
///    replaced with offspring from the best. Use [rtReplace] to perform
///    one replacement step. This is what The Bibites and NERO use.
///
/// ## Lifecycle
///
/// ```
/// final pop = NeatPopulation(config);
/// pop.initialize();
///
/// // Generational:
/// for (final genome in pop.genomes) { genome.fitness = evaluate(genome); }
/// pop.epoch();
///
/// // rt-NEAT:
/// pop.rtReplace(); // call every N ticks
/// ```
class NeatPopulation {
  NeatPopulation(this.config, {int? seed})
      : _rng = Random(seed),
        _innovations = InnovationCounter(),
        _speciesManager = SpeciesManager();

  /// Configuration hyperparameters.
  final NeatConfig config;

  final Random _rng;
  final InnovationCounter _innovations;
  final SpeciesManager _speciesManager;

  /// Current generation number.
  int generation = 0;

  /// The live population of genomes.
  final List<NeatGenome> genomes = [];

  /// Best genome ever seen across all generations.
  NeatGenome? champion;

  /// Access to species for inspection / debugging.
  SpeciesManager get speciesManager => _speciesManager;

  /// Innovation counter (exposed for genome creation outside the population).
  InnovationCounter get innovations => _innovations;

  // ---------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------

  /// Create the initial population of minimal seed genomes.
  void initialize() {
    genomes.clear();
    for (var i = 0; i < config.populationSize; i++) {
      genomes.add(NeatGenome.seed(config, _innovations, _rng));
    }
    _innovations.resetGenerationCache();

    // Initial speciation.
    _speciesManager.speciate(genomes, config, _rng);
  }

  // ---------------------------------------------------------------------------
  // Generational evolution
  // ---------------------------------------------------------------------------

  /// Advance one generation.
  ///
  /// Assumes all genomes have had their [NeatGenome.fitness] set by the
  /// caller's evaluation function before calling this method.
  void epoch() {
    generation++;
    _innovations.resetGenerationCache();

    // 1. Speciate the current population.
    _speciesManager.speciate(genomes, config, _rng);

    // 2. Rank members within each species and update stagnation tracking.
    for (final sp in _speciesManager.species) {
      sp.rankAndUpdate(generation);
      sp.adjustFitnesses();
    }

    // 3. Remove stagnant species.
    _speciesManager.removeStagnant(config);

    // 4. Allocate offspring to each species.
    _speciesManager.allocateOffspring(config);

    // 5. Track the champion.
    _updateChampion();

    // 6. Produce the next generation.
    final nextGen = <NeatGenome>[];

    for (final sp in _speciesManager.species) {
      sp.cull(config);

      // Elitism: copy the top N organisms directly.
      final eliteCount = min(config.elitismCount, sp.members.length);
      for (var i = 0; i < eliteCount; i++) {
        nextGen.add(sp.members[i].copy());
      }

      // Fill the remaining slots with offspring.
      final remaining = sp.allocatedOffspring - eliteCount;
      for (var i = 0; i < remaining; i++) {
        final child = _reproduce(sp);
        nextGen.add(child);
      }
    }

    // Ensure population size is exact (can drift due to rounding).
    while (nextGen.length < config.populationSize) {
      final sp = _speciesManager.species[_rng.nextInt(_speciesManager.count)];
      nextGen.add(_reproduce(sp));
    }
    while (nextGen.length > config.populationSize) {
      nextGen.removeLast();
    }

    genomes
      ..clear()
      ..addAll(nextGen);
  }

  // ---------------------------------------------------------------------------
  // rt-NEAT (real-time evolution)
  // ---------------------------------------------------------------------------

  /// Perform one rt-NEAT replacement step.
  ///
  /// 1. Find the organism with the lowest adjusted fitness that has lived
  ///    at least [config.rtMinLifetime] ticks.
  /// 2. Remove it from the population.
  /// 3. Create an offspring from two high-fitness parents.
  /// 4. Insert the offspring into the population.
  ///
  /// Call this every [config.rtReplacementInterval] simulation ticks.
  void rtReplace() {
    if (genomes.length < 3) return;

    _innovations.resetGenerationCache();

    // Re-speciate periodically to keep species current.
    _speciesManager.speciate(genomes, config, _rng);
    for (final sp in _speciesManager.species) {
      sp.adjustFitnesses();
    }

    // Find the worst organism that's old enough.
    NeatGenome? worst;
    double worstFitness = double.infinity;

    for (final genome in genomes) {
      if (genome.age >= config.rtMinLifetime &&
          genome.adjustedFitness < worstFitness) {
        worstFitness = genome.adjustedFitness;
        worst = genome;
      }
    }

    if (worst == null) return; // All organisms are too young.

    // Select two parents via tournament from different high-fitness organisms.
    final parent1 = _tournamentSelect(genomes, 3);
    final parent2 = _tournamentSelect(genomes, 3);

    // Create offspring.
    NeatGenome child;
    if (_rng.nextDouble() < config.crossoverRate && parent1 != parent2) {
      child = NeatGenome.crossover(parent1, parent2, _rng, config);
    } else {
      child = parent1.copy();
    }

    _mutate(child);
    child.fitness = 0.0;
    child.adjustedFitness = 0.0;
    child.age = 0;

    // Replace worst with child.
    final idx = genomes.indexOf(worst);
    if (idx >= 0) {
      genomes[idx] = child;
    }

    _updateChampion();
  }

  /// Increment age for all organisms. Call once per simulation tick when
  /// using rt-NEAT.
  void ageAll() {
    for (final genome in genomes) {
      genome.age++;
    }
  }

  // ---------------------------------------------------------------------------
  // Reproduction helpers
  // ---------------------------------------------------------------------------

  NeatGenome _reproduce(NeatSpecies species) {
    NeatGenome child;

    if (species.members.length < 2 || _rng.nextDouble() >= config.crossoverRate) {
      // Asexual reproduction (clone + mutate).
      final parent = species.members[_rng.nextInt(species.members.length)];
      child = parent.copy();
    } else {
      // Sexual reproduction (crossover + mutate).
      NeatGenome parent2;

      if (_rng.nextDouble() < config.interspeciesCrossoverRate &&
          _speciesManager.count > 1) {
        // Inter-species crossover.
        final otherSpecies = _speciesManager.species
            .where((sp) => sp.id != species.id)
            .toList();
        final sp2 = otherSpecies[_rng.nextInt(otherSpecies.length)];
        parent2 = sp2.members[_rng.nextInt(sp2.members.length)];
      } else {
        parent2 = species.members[_rng.nextInt(species.members.length)];
      }

      final parent1 = species.members[_rng.nextInt(species.members.length)];
      child = NeatGenome.crossover(parent1, parent2, _rng, config);
    }

    _mutate(child);
    child.fitness = 0.0;
    child.adjustedFitness = 0.0;
    child.age = 0;

    return child;
  }

  void _mutate(NeatGenome genome) {
    genome.mutateWeights(config, _rng);

    if (_rng.nextDouble() < config.addConnectionRate) {
      genome.mutateAddConnection(config, _innovations, _rng);
    }
    if (_rng.nextDouble() < config.addNodeRate) {
      genome.mutateAddNode(config, _innovations, _rng);
    }
    if (_rng.nextDouble() < config.deleteConnectionRate) {
      genome.mutateDeleteConnection(_rng);
    }
    if (_rng.nextDouble() < config.activationMutationRate) {
      genome.mutateActivation(config, _rng);
    }
  }

  NeatGenome _tournamentSelect(List<NeatGenome> pool, int tournamentSize) {
    NeatGenome best = pool[_rng.nextInt(pool.length)];
    for (var i = 1; i < tournamentSize; i++) {
      final contestant = pool[_rng.nextInt(pool.length)];
      if (contestant.fitness > best.fitness) {
        best = contestant;
      }
    }
    return best;
  }

  void _updateChampion() {
    for (final genome in genomes) {
      if (champion == null || genome.fitness > champion!.fitness) {
        champion = genome.copy();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Diagnostics
  // ---------------------------------------------------------------------------

  /// Average fitness across the entire population.
  double get averageFitness {
    if (genomes.isEmpty) return 0.0;
    return genomes.fold(0.0, (sum, g) => sum + g.fitness) / genomes.length;
  }

  /// Average number of hidden nodes per genome.
  double get averageHiddenNodes {
    if (genomes.isEmpty) return 0.0;
    return genomes.fold(0.0, (sum, g) =>
            sum + g.nodes.values.where((n) => n.type == NodeType.hidden).length) /
        genomes.length;
  }

  /// Average number of connections per genome.
  double get averageConnections {
    if (genomes.isEmpty) return 0.0;
    return genomes.fold(0.0, (sum, g) => sum + g.connections.length) /
        genomes.length;
  }

  @override
  String toString() =>
      'NeatPopulation(gen=$generation, pop=${genomes.length}, '
      'species=${_speciesManager.count}, '
      'avgFit=${averageFitness.toStringAsFixed(2)}, '
      'avgHidden=${averageHiddenNodes.toStringAsFixed(1)}, '
      'champion=${champion?.fitness.toStringAsFixed(2) ?? "none"})';
}
