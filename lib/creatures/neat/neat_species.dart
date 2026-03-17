import 'dart:math';

import 'neat_config.dart';
import 'neat_genome.dart';

/// A species groups genetically similar genomes so that topological
/// innovations are protected from premature elimination.
///
/// Each species maintains a representative genome against which newcomers
/// are compared using the NEAT compatibility distance. Fitness is shared
/// within the species (adjusted fitness = raw fitness / species size) so that
/// large species don't dominate.
class NeatSpecies {
  NeatSpecies({required this.id, required NeatGenome representative})
      : _representative = representative.copy();

  /// Unique species identifier.
  final int id;

  /// The genome used for compatibility comparison. Updated each generation
  /// to a random member of the species.
  NeatGenome _representative;
  NeatGenome get representative => _representative;

  /// Current members of this species.
  final List<NeatGenome> members = [];

  /// Best fitness ever achieved by any member.
  double bestFitnessEver = 0.0;

  /// Generation at which [bestFitnessEver] was last improved.
  int lastImprovedGeneration = 0;

  /// Current generation number (set by the population manager).
  int generationOfRecord = 0;

  /// Number of generations since fitness last improved.
  int get stagnation => generationOfRecord - lastImprovedGeneration;

  /// Number of offspring this species is allocated for the next generation.
  int allocatedOffspring = 0;

  // ---------------------------------------------------------------------------
  // Member management
  // ---------------------------------------------------------------------------

  /// Attempt to add [genome] to this species. Returns true if the genome is
  /// compatible with the representative.
  bool tryAdd(NeatGenome genome, NeatConfig config) {
    final dist = genome.compatibilityDistance(_representative, config);
    if (dist < config.compatThreshold) {
      members.add(genome);
      genome.speciesId = id;
      return true;
    }
    return false;
  }

  /// Force-add a genome without compatibility checking (used when no species
  /// matches and we create a new one).
  void addForced(NeatGenome genome) {
    members.add(genome);
    genome.speciesId = id;
  }

  /// Compute adjusted fitness for every member (fitness sharing).
  ///
  /// Each member's adjusted fitness = raw fitness / species size. This
  /// prevents large species from monopolising the offspring quota.
  void adjustFitnesses() {
    final size = members.length;
    if (size == 0) return;

    for (final genome in members) {
      genome.adjustedFitness = genome.fitness / size;
    }
  }

  /// Sort members by fitness descending and update best-ever tracking.
  void rankAndUpdate(int generation) {
    generationOfRecord = generation;
    members.sort((a, b) => b.fitness.compareTo(a.fitness));

    if (members.isNotEmpty && members.first.fitness > bestFitnessEver) {
      bestFitnessEver = members.first.fitness;
      lastImprovedGeneration = generation;
    }
  }

  /// Cull the bottom fraction, keeping only the top [survivalThreshold].
  void cull(NeatConfig config) {
    final keepCount = max(1, (members.length * config.survivalThreshold).ceil());
    if (members.length > keepCount) {
      members.removeRange(keepCount, members.length);
    }
  }

  /// Prepare for the next generation: clear members and pick a new
  /// representative randomly from the current members.
  void prepareNextGeneration(Random rng) {
    if (members.isNotEmpty) {
      _representative = members[rng.nextInt(members.length)].copy();
    }
    members.clear();
  }

  /// Sum of adjusted fitnesses for offspring allocation.
  double get totalAdjustedFitness =>
      members.fold(0.0, (sum, g) => sum + g.adjustedFitness);
}

/// Manages the collection of all species and handles speciation logic.
///
/// Each generation, existing species are cleared and every genome is
/// reassigned to the first compatible species (by representative distance).
/// Genomes that don't fit any existing species start a new one.
class SpeciesManager {
  SpeciesManager();

  int _nextSpeciesId = 0;
  final List<NeatSpecies> _species = [];

  /// All active species.
  List<NeatSpecies> get species => List.unmodifiable(_species);

  /// Number of active species.
  int get count => _species.length;

  /// Assign every genome in [population] to a species.
  ///
  /// This is the core speciation step called once per generation.
  void speciate(List<NeatGenome> population, NeatConfig config, Random rng) {
    // Prepare existing species: clear members, pick new representatives.
    for (final sp in _species) {
      sp.prepareNextGeneration(rng);
    }

    // Try to place each genome into an existing species.
    for (final genome in population) {
      bool placed = false;
      for (final sp in _species) {
        if (sp.tryAdd(genome, config)) {
          placed = true;
          break;
        }
      }
      if (!placed) {
        // Create a new species with this genome as representative.
        final newSpecies = NeatSpecies(
          id: _nextSpeciesId++,
          representative: genome,
        );
        newSpecies.addForced(genome);
        _species.add(newSpecies);
      }
    }

    // Remove empty species.
    _species.removeWhere((sp) => sp.members.isEmpty);
  }

  /// Adjust the compatibility threshold to steer toward the target species
  /// count. If we have too many species, increase the threshold (merge).
  /// If too few, decrease it (split).
  double adjustThreshold(NeatConfig config, double currentThreshold) {
    if (_species.length < config.targetSpeciesCount) {
      return max(0.5, currentThreshold - config.compatThresholdDelta);
    } else if (_species.length > config.targetSpeciesCount) {
      return currentThreshold + config.compatThresholdDelta;
    }
    return currentThreshold;
  }

  /// Handle stagnation: remove species that haven't improved for
  /// [config.stagnationLimit] generations, keeping at least
  /// [config.stagnationProtectedSpecies] top species.
  void removeStagnant(NeatConfig config) {
    if (_species.length <= config.stagnationProtectedSpecies) return;

    // Sort by best fitness descending — protect the top N.
    final sorted = List<NeatSpecies>.from(_species)
      ..sort((a, b) => b.bestFitnessEver.compareTo(a.bestFitnessEver));

    for (var i = config.stagnationProtectedSpecies; i < sorted.length; i++) {
      if (sorted[i].stagnation >= config.stagnationLimit) {
        _species.remove(sorted[i]);
      }
    }
  }

  /// Compute offspring allocation for each species based on their share of
  /// total adjusted fitness.
  void allocateOffspring(NeatConfig config) {
    final totalFitness = _species.fold(0.0, (sum, sp) => sum + sp.totalAdjustedFitness);

    if (totalFitness <= 0) {
      // Equal distribution if all fitnesses are zero.
      final perSpecies = config.populationSize ~/ _species.length;
      for (final sp in _species) {
        sp.allocatedOffspring = perSpecies;
      }
      return;
    }

    int totalAllocated = 0;
    for (final sp in _species) {
      sp.allocatedOffspring =
          (sp.totalAdjustedFitness / totalFitness * config.populationSize).round();
      sp.allocatedOffspring = max(1, sp.allocatedOffspring);
      totalAllocated += sp.allocatedOffspring;
    }

    // Adjust for rounding errors.
    final diff = config.populationSize - totalAllocated;
    if (diff != 0 && _species.isNotEmpty) {
      _species.first.allocatedOffspring += diff;
    }
  }
}
