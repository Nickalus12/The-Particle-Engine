/// NEAT (NeuroEvolution of Augmenting Topologies) implementation for
/// evolving ant neural networks.
///
/// This library provides:
/// - [NeatGenome] — genetic encoding of a neural network with mutation
///   and crossover operators.
/// - [NeatForward] — compiled feed-forward network for fast inference.
/// - [NeatPopulation] — population management with generational and
///   rt-NEAT (real-time) evolution modes.
/// - [NeatSpecies] / [SpeciesManager] — speciation via compatibility
///   distance to protect topological innovations.
/// - [AntBrain] — integration layer mapping sensory inputs to ant actions.
/// - [AntFitness] — fitness accumulator driving selection pressure.
/// - [ColonyEvolution] — per-colony evolutionary lifecycle manager.
/// - [NeatConfig] — all hyperparameters in one place.
library;

export 'ant_brain.dart';
export 'ant_fitness.dart';
export 'colony_evolution.dart';
export 'neat_config.dart';
export 'neat_forward.dart';
export 'neat_genome.dart';
export 'neat_population.dart';
export 'neat_species.dart';
