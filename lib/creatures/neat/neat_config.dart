/// Hyperparameters controlling every aspect of the NEAT algorithm.
///
/// Defaults are tuned for the ant-brain use case: tiny networks
/// (9 inputs -> variable hidden -> 6 outputs) that must evolve quickly on
/// mobile hardware. All values can be overridden at construction time.
///
/// References:
///   - Stanley & Miikkulainen, "Evolving Neural Networks through Augmenting
///     Topologies", Evolutionary Computation 10(2), 2002.
///   - SharpNEAT (C#) default configuration.
///   - NEAT-Python default configuration.
class NeatConfig {
  const NeatConfig({
    // -- Network topology --------------------------------------------------
    this.inputCount = 9,
    this.outputCount = 6,

    // -- Population --------------------------------------------------------
    this.populationSize = 150,

    // -- Compatibility / speciation ----------------------------------------
    this.compatExcessCoeff = 1.0,
    this.compatDisjointCoeff = 1.0,
    this.compatWeightCoeff = 0.4,
    this.compatThreshold = 3.0,
    this.compatThresholdDelta = 0.3,
    this.targetSpeciesCount = 10,
    this.normalizeByGenomeSize = true,

    // -- Mutation rates ----------------------------------------------------
    this.weightMutationRate = 0.8,
    this.weightPerturbChance = 0.9,
    this.weightPerturbPower = 0.5,
    this.weightReplaceChance = 0.1,
    this.addConnectionRate = 0.05,
    this.addNodeRate = 0.03,
    this.deleteConnectionRate = 0.01,
    this.enableGeneRate = 0.25,
    this.activationMutationRate = 0.05,

    // -- Crossover ---------------------------------------------------------
    this.crossoverRate = 0.75,
    this.interspeciesCrossoverRate = 0.001,

    // -- Reproduction ------------------------------------------------------
    this.elitismCount = 2,
    this.survivalThreshold = 0.2,

    // -- Stagnation --------------------------------------------------------
    this.stagnationLimit = 15,
    this.stagnationProtectedSpecies = 2,

    // -- rt-NEAT (real-time) -----------------------------------------------
    this.rtNeatEnabled = true,
    this.rtReplacementInterval = 20,
    this.rtMinLifetime = 100,

    // -- Activation --------------------------------------------------------
    this.defaultActivation = ActivationFunction.tanh,

    // -- Performance tuning ------------------------------------------------
    this.maxHiddenNodes = 20,
    this.maxConnections = 100,
  });

  // -- Network topology ----------------------------------------------------

  /// Number of input neurons (sensory layer). Fixed per run.
  final int inputCount;

  /// Number of output neurons (behavior layer). Fixed per run.
  final int outputCount;

  // -- Population ----------------------------------------------------------

  /// Total organisms in the population.
  final int populationSize;

  // -- Compatibility / speciation ------------------------------------------

  /// Weight given to excess genes in the compatibility distance formula.
  /// Formula: delta = (c1 * E / N) + (c2 * D / N) + c3 * W_bar
  final double compatExcessCoeff;

  /// Weight given to disjoint genes.
  final double compatDisjointCoeff;

  /// Weight given to average weight difference of matching genes.
  final double compatWeightCoeff;

  /// Distance threshold below which two genomes belong to the same species.
  final double compatThreshold;

  /// Amount by which [compatThreshold] is adjusted each generation to
  /// maintain [targetSpeciesCount].
  final double compatThresholdDelta;

  /// Target number of species. The threshold drifts toward this.
  final int targetSpeciesCount;

  /// If true, divide excess/disjoint counts by the size of the larger genome
  /// (N). Set false for very small genomes where N is noisy.
  final bool normalizeByGenomeSize;

  // -- Mutation rates ------------------------------------------------------

  /// Probability that each connection weight is mutated during reproduction.
  final double weightMutationRate;

  /// Given a weight mutation occurs, chance it is a perturbation (vs replace).
  final double weightPerturbChance;

  /// Standard deviation of the Gaussian perturbation applied to weights.
  final double weightPerturbPower;

  /// Given a weight mutation occurs, chance the weight is fully replaced with
  /// a new random value.
  final double weightReplaceChance;

  /// Probability of adding a new connection gene per offspring.
  final double addConnectionRate;

  /// Probability of adding a new node (splitting a connection) per offspring.
  final double addNodeRate;

  /// Probability of deleting a random connection per offspring (pruning).
  final double deleteConnectionRate;

  /// Probability that a disabled gene is re-enabled during crossover.
  final double enableGeneRate;

  /// Probability that a hidden node's activation function is changed.
  final double activationMutationRate;

  // -- Crossover -----------------------------------------------------------

  /// Probability that reproduction uses crossover (vs asexual/cloning).
  final double crossoverRate;

  /// Probability of mating with a member of a different species.
  final double interspeciesCrossoverRate;

  // -- Reproduction --------------------------------------------------------

  /// Number of top organisms per species copied directly (no mutation).
  final int elitismCount;

  /// Fraction of each species that survives to reproduce.
  final double survivalThreshold;

  // -- Stagnation ----------------------------------------------------------

  /// Generations without fitness improvement before a species is penalised.
  final int stagnationLimit;

  /// Number of top species protected from stagnation removal.
  final int stagnationProtectedSpecies;

  // -- rt-NEAT (real-time) -------------------------------------------------

  /// Whether to use rt-NEAT (steady-state replacement) instead of
  /// generational evolution.
  final bool rtNeatEnabled;

  /// In rt-NEAT: how many simulation ticks between replacement events.
  final int rtReplacementInterval;

  /// In rt-NEAT: minimum ticks an organism lives before it can be replaced.
  final int rtMinLifetime;

  // -- Activation ----------------------------------------------------------

  /// Default activation function for hidden and output nodes.
  final ActivationFunction defaultActivation;

  // -- Performance tuning --------------------------------------------------

  /// Hard cap on hidden nodes per genome to keep forward pass bounded.
  final int maxHiddenNodes;

  /// Hard cap on total connections per genome.
  final int maxConnections;
}

/// Available activation functions for NEAT neurons.
///
/// Kept minimal to reduce per-node branching cost during forward pass.
enum ActivationFunction {
  /// Standard sigmoid: 1 / (1 + e^(-x)). Output range (0, 1).
  sigmoid,

  /// Hyperbolic tangent. Output range (-1, 1). Preferred for ant outputs.
  tanh,

  /// Rectified linear unit. Output range [0, inf).
  relu,

  /// Identity / linear. Output = input.
  linear,

  /// Gaussian: e^(-x^2). Output range (0, 1]. Bell-curve response.
  gaussian,

  /// Step function: x > 0 ? 1 : 0.
  step,
}
