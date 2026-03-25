import 'dart:math';

import 'neat_config.dart';

// ---------------------------------------------------------------------------
// Innovation tracker
// ---------------------------------------------------------------------------

/// Global counter for innovation numbers.
///
/// Every structural mutation (add connection, add node) receives a unique
/// innovation number. Within a single generation, identical structural
/// mutations receive the *same* innovation number so that crossover can align
/// matching genes. The [_structuralCache] resets each generation.
class InnovationCounter {
  int _counter = 0;

  /// Cache of (inNode, outNode) -> innovation number for the current
  /// generation. Prevents the same structural mutation from consuming
  /// multiple innovation numbers within one generation.
  final Map<(int, int), int> _structuralCache = {};

  /// Get or assign an innovation number for a connection from [inNode] to
  /// [outNode]. If this exact mutation already occurred this generation the
  /// cached number is returned.
  int getInnovation(int inNode, int outNode) {
    final key = (inNode, outNode);
    return _structuralCache.putIfAbsent(key, () => _counter++);
  }

  /// Clear the per-generation cache. Call once at the start of each
  /// generation (or after each rt-NEAT replacement batch).
  void resetGenerationCache() => _structuralCache.clear();

  /// Current counter value (for diagnostics).
  int get current => _counter;
}

// ---------------------------------------------------------------------------
// Node gene
// ---------------------------------------------------------------------------

/// Type of a neuron in the network.
enum NodeType { input, hidden, output, bias }

/// A single neuron in the NEAT genome.
///
/// Nodes are identified by a unique [id] that is stable across crossover.
/// The [type] determines whether the node is part of the fixed input/output
/// layer or an evolved hidden neuron.
class NodeGene {
  const NodeGene({
    required this.id,
    required this.type,
    this.activation = ActivationFunction.tanh,
    this.layer = 0,
  });

  /// Globally unique node identifier.
  final int id;

  /// Whether this node is input, hidden, output, or bias.
  final NodeType type;

  /// Activation function applied to this node's aggregated input.
  final ActivationFunction activation;

  /// Topological layer (0 = input, max = output). Computed lazily during
  /// forward pass setup.
  final int layer;

  /// Create a copy with optional overrides.
  NodeGene copyWith({int? id, NodeType? type, ActivationFunction? activation, int? layer}) {
    return NodeGene(
      id: id ?? this.id,
      type: type ?? this.type,
      activation: activation ?? this.activation,
      layer: layer ?? this.layer,
    );
  }
}

// ---------------------------------------------------------------------------
// Connection gene
// ---------------------------------------------------------------------------

/// A single directed connection between two neurons.
///
/// The [innovation] number serves as a historical marker that allows
/// crossover to align matching genes across differently-structured genomes.
class ConnectionGene {
  ConnectionGene({
    required this.innovation,
    required this.inNode,
    required this.outNode,
    required this.weight,
    this.enabled = true,
  });

  /// Historical marker assigned when this connection first appeared.
  final int innovation;

  /// Source node id.
  final int inNode;

  /// Destination node id.
  final int outNode;

  /// Connection weight.
  double weight;

  /// Whether the connection is expressed in the phenotype. Disabled genes
  /// remain in the genome for crossover alignment but do not participate in
  /// the forward pass.
  bool enabled;

  /// Deep copy.
  ConnectionGene copy() => ConnectionGene(
        innovation: innovation,
        inNode: inNode,
        outNode: outNode,
        weight: weight,
        enabled: enabled,
      );
}

// ---------------------------------------------------------------------------
// Genome
// ---------------------------------------------------------------------------

/// A complete NEAT genome: the genetic encoding of one neural network.
///
/// Contains an ordered list of [NodeGene]s and [ConnectionGene]s. Provides
/// mutation operators (weight perturbation, add node, add connection, delete
/// connection) and a crossover factory method.
///
/// The genome does NOT own its phenotype (the runnable network). Use
/// [NeatForward] to build and evaluate the network from a genome.
class NeatGenome {
  NeatGenome({
    required this.nodes,
    required this.connections,
    this.fitness = 0.0,
    this.adjustedFitness = 0.0,
    this.speciesId = -1,
    this.age = 0,
    this.behaviorVector,
  });

  /// All neuron genes, indexed by node id for fast lookup.
  final Map<int, NodeGene> nodes;

  /// All connection genes, keyed by innovation number.
  final Map<int, ConnectionGene> connections;

  /// Raw fitness assigned by the evaluation function.
  double fitness;

  /// Fitness after species-based sharing adjustment.
  double adjustedFitness;

  /// The species this genome belongs to (-1 = unassigned).
  int speciesId;

  /// Number of ticks this organism has been alive (for rt-NEAT).
  int age;

  /// QDax behavioral descriptor vector (typically 4 doubles in [0,1]).
  /// Null for runtime-evolved genomes without behavioral data.
  List<double>? behaviorVector;

  // -------------------------------------------------------------------------
  // Factory: minimal seed genome
  // -------------------------------------------------------------------------

  /// Create the initial minimal genome with direct input-to-output
  /// connections and random weights.
  ///
  /// This is the starting point for all organisms in generation 0. NEAT
  /// begins with minimal structure and complexifies through mutation.
  static NeatGenome seed(NeatConfig config, InnovationCounter innovations, Random rng) {
    final nodes = <int, NodeGene>{};
    final connections = <int, ConnectionGene>{};

    int nodeId = 0;

    // Bias node (always id 0).
    nodes[nodeId] = NodeGene(id: nodeId, type: NodeType.bias, layer: 0);
    nodeId++;

    // Input nodes.
    final inputIds = <int>[];
    for (var i = 0; i < config.inputCount; i++) {
      nodes[nodeId] = NodeGene(id: nodeId, type: NodeType.input, layer: 0);
      inputIds.add(nodeId);
      nodeId++;
    }

    // Output nodes.
    final outputIds = <int>[];
    for (var i = 0; i < config.outputCount; i++) {
      nodes[nodeId] = NodeGene(
        id: nodeId,
        type: NodeType.output,
        activation: config.defaultActivation,
        layer: 1,
      );
      outputIds.add(nodeId);
      nodeId++;
    }

    // Connect every input (+ bias) to every output with random weights.
    for (final inId in [0, ...inputIds]) {
      for (final outId in outputIds) {
        final innov = innovations.getInnovation(inId, outId);
        connections[innov] = ConnectionGene(
          innovation: innov,
          inNode: inId,
          outNode: outId,
          weight: (rng.nextDouble() * 2 - 1) * 2, // range [-2, 2]
        );
      }
    }

    return NeatGenome(nodes: nodes, connections: connections);
  }

  // -------------------------------------------------------------------------
  // Deep copy
  // -------------------------------------------------------------------------

  /// Create an independent deep copy of this genome.
  NeatGenome copy() {
    return NeatGenome(
      nodes: {for (final e in nodes.entries) e.key: e.value.copyWith()},
      connections: {for (final e in connections.entries) e.key: e.value.copy()},
      fitness: fitness,
      adjustedFitness: adjustedFitness,
      speciesId: speciesId,
      age: age,
      behaviorVector: behaviorVector != null ? List<double>.from(behaviorVector!) : null,
    );
  }

  // -------------------------------------------------------------------------
  // Mutation operators
  // -------------------------------------------------------------------------

  /// Perturb or replace connection weights.
  void mutateWeights(NeatConfig config, Random rng) {
    for (final conn in connections.values) {
      if (rng.nextDouble() >= config.weightMutationRate) continue;

      if (rng.nextDouble() < config.weightPerturbChance) {
        // Gaussian perturbation.
        conn.weight += _gaussian(rng) * config.weightPerturbPower;
      } else {
        // Full replacement.
        conn.weight = (rng.nextDouble() * 2 - 1) * 2;
      }

      // Clamp to prevent runaway weights.
      conn.weight = conn.weight.clamp(-8.0, 8.0);
    }
  }

  /// Structural mutation: add a new connection between two previously
  /// unconnected nodes.
  ///
  /// Attempts up to 20 random pairs before giving up (to avoid infinite
  /// loops in highly-connected genomes).
  void mutateAddConnection(NeatConfig config, InnovationCounter innovations, Random rng) {
    if (connections.length >= config.maxConnections) return;

    // Build a Set of existing (inNode, outNode) pairs for O(1) lookup.
    final existingConns = <(int, int)>{
      for (final c in connections.values) (c.inNode, c.outNode),
    };

    final nodeList = nodes.values.toList();
    for (var attempt = 0; attempt < 20; attempt++) {
      final from = nodeList[rng.nextInt(nodeList.length)];
      final to = nodeList[rng.nextInt(nodeList.length)];

      // Disallow: self-connections, connections into input/bias,
      // connections from output, and existing connections.
      if (from.id == to.id) continue;
      if (to.type == NodeType.input || to.type == NodeType.bias) continue;
      if (from.type == NodeType.output) continue;
      if (existingConns.contains((from.id, to.id))) continue;

      // Prevent recurrent connections by ensuring layer ordering.
      if (from.layer >= to.layer && to.type != NodeType.output) continue;

      final innov = innovations.getInnovation(from.id, to.id);
      connections[innov] = ConnectionGene(
        innovation: innov,
        inNode: from.id,
        outNode: to.id,
        weight: (rng.nextDouble() * 2 - 1) * 2,
      );
      return;
    }
  }

  /// Structural mutation: split an existing connection by inserting a new
  /// hidden node.
  ///
  /// The original connection is disabled. Two new connections are created:
  /// one from the original source to the new node (weight 1.0) and one from
  /// the new node to the original target (original weight). This preserves
  /// the network's behaviour at the moment of mutation.
  void mutateAddNode(NeatConfig config, InnovationCounter innovations, Random rng) {
    final hiddenCount = nodes.values.where((n) => n.type == NodeType.hidden).length;
    if (hiddenCount >= config.maxHiddenNodes) return;

    final enabled = connections.values.where((c) => c.enabled).toList();
    if (enabled.isEmpty) return;

    final conn = enabled[rng.nextInt(enabled.length)];
    conn.enabled = false;

    // New hidden node gets the next available node id.
    if (nodes.isEmpty) return;
    final newNodeId = (nodes.keys.reduce(max)) + 1;

    // Layer of new node is between source and target.
    final fromLayer = nodes[conn.inNode]!.layer;
    final toLayer = nodes[conn.outNode]!.layer;
    final newLayer = ((fromLayer + toLayer) / 2).round();

    nodes[newNodeId] = NodeGene(
      id: newNodeId,
      type: NodeType.hidden,
      activation: config.defaultActivation,
      layer: newLayer,
    );

    // Source -> new node (weight 1.0 to preserve signal).
    final innov1 = innovations.getInnovation(conn.inNode, newNodeId);
    connections[innov1] = ConnectionGene(
      innovation: innov1,
      inNode: conn.inNode,
      outNode: newNodeId,
      weight: 1.0,
    );

    // New node -> original target (original weight to preserve behaviour).
    final innov2 = innovations.getInnovation(newNodeId, conn.outNode);
    connections[innov2] = ConnectionGene(
      innovation: innov2,
      inNode: newNodeId,
      outNode: conn.outNode,
      weight: conn.weight,
    );
  }

  /// Structural mutation: randomise the activation function of a hidden node.
  void mutateActivation(NeatConfig config, Random rng) {
    final hidden = nodes.values.where((n) => n.type == NodeType.hidden).toList();
    if (hidden.isEmpty) return;

    final target = hidden[rng.nextInt(hidden.length)];
    final functions = ActivationFunction.values;
    final newFn = functions[rng.nextInt(functions.length)];
    nodes[target.id] = target.copyWith(activation: newFn);
  }

  /// Structural mutation: remove a random connection (pruning).
  ///
  /// Only removes connections to/from hidden nodes to avoid disconnecting
  /// inputs from outputs entirely.
  void mutateDeleteConnection(Random rng) {
    final candidates = connections.values.where((c) {
      final inType = nodes[c.inNode]?.type;
      final outType = nodes[c.outNode]?.type;
      // Only delete if at least one end is hidden.
      return inType == NodeType.hidden || outType == NodeType.hidden;
    }).toList();

    if (candidates.isEmpty) return;
    final victim = candidates[rng.nextInt(candidates.length)];
    connections.remove(victim.innovation);

    // Remove orphaned hidden nodes (no remaining connections).
    _pruneOrphanNodes();
  }

  // -------------------------------------------------------------------------
  // Crossover
  // -------------------------------------------------------------------------

  /// Produce an offspring genome by crossing two parents.
  ///
  /// Matching genes (same innovation number) are inherited randomly from
  /// either parent. Disjoint and excess genes are inherited from the
  /// more-fit parent. If fitness is equal, genes are inherited from both
  /// parents randomly.
  static NeatGenome crossover(NeatGenome parent1, NeatGenome parent2, Random rng, NeatConfig config) {
    // Ensure parent1 is the fitter (or equal) parent.
    final NeatGenome fitter;
    final NeatGenome other;
    if (parent1.fitness >= parent2.fitness) {
      fitter = parent1;
      other = parent2;
    } else {
      fitter = parent2;
      other = parent1;
    }

    final childNodes = <int, NodeGene>{};
    final childConns = <int, ConnectionGene>{};

    // Inherit nodes from both parents (union).
    for (final node in fitter.nodes.values) {
      childNodes[node.id] = node.copyWith();
    }
    // Also include hidden nodes from other parent that we might inherit
    // connections for.
    for (final node in other.nodes.values) {
      childNodes.putIfAbsent(node.id, () => node.copyWith());
    }

    // Align connections by innovation number.
    final allInnovations = <int>{...fitter.connections.keys, ...other.connections.keys};

    for (final innov in allInnovations) {
      final gene1 = fitter.connections[innov];
      final gene2 = other.connections[innov];

      if (gene1 != null && gene2 != null) {
        // Matching gene — inherit randomly.
        final chosen = rng.nextBool() ? gene1.copy() : gene2.copy();

        // Chance to re-enable a disabled gene.
        if ((!gene1.enabled || !gene2.enabled) &&
            rng.nextDouble() < config.enableGeneRate) {
          chosen.enabled = true;
        }

        childConns[innov] = chosen;
      } else if (gene1 != null) {
        // Disjoint/excess from fitter parent — always inherit.
        childConns[innov] = gene1.copy();
      } else if (gene2 != null && parent1.fitness == parent2.fitness) {
        // Equal fitness: inherit disjoint/excess from either.
        if (rng.nextBool()) {
          childConns[innov] = gene2.copy();
        }
      }
      // If gene2 != null but fitter != other, skip (disjoint from weaker).
    }

    // Remove nodes that have no connections referencing them (except
    // input/output/bias which are always kept).
    final referencedNodes = <int>{};
    for (final c in childConns.values) {
      referencedNodes.add(c.inNode);
      referencedNodes.add(c.outNode);
    }
    childNodes.removeWhere((id, node) =>
        node.type == NodeType.hidden && !referencedNodes.contains(id));

    return NeatGenome(nodes: childNodes, connections: childConns);
  }

  // -------------------------------------------------------------------------
  // Compatibility distance
  // -------------------------------------------------------------------------

  /// Compute the NEAT compatibility distance between this genome and [other].
  ///
  /// delta = (c1 * E / N) + (c2 * D / N) + c3 * W_bar
  ///
  /// Where E = excess genes, D = disjoint genes, W_bar = average weight
  /// difference of matching genes, and N = size of the larger genome
  /// (set to 1 for small genomes if [config.normalizeByGenomeSize] is true).
  double compatibilityDistance(NeatGenome other, NeatConfig config) {
    if (connections.isEmpty && other.connections.isEmpty) return 0.0;

    final maxInnovThis = connections.isEmpty
        ? 0
        : connections.keys.reduce(max);
    final maxInnovOther = other.connections.isEmpty
        ? 0
        : other.connections.keys.reduce(max);
    final boundary = min(maxInnovThis, maxInnovOther);

    int excess = 0;
    int disjoint = 0;
    double weightDiffSum = 0.0;
    int matchingCount = 0;

    final allInnovations = <int>{...connections.keys, ...other.connections.keys};

    for (final innov in allInnovations) {
      final g1 = connections[innov];
      final g2 = other.connections[innov];

      if (g1 != null && g2 != null) {
        // Matching.
        weightDiffSum += (g1.weight - g2.weight).abs();
        matchingCount++;
      } else if (innov > boundary) {
        excess++;
      } else {
        disjoint++;
      }
    }

    final wBar = matchingCount > 0 ? weightDiffSum / matchingCount : 0.0;

    double n = 1.0;
    if (config.normalizeByGenomeSize) {
      final larger = max(connections.length, other.connections.length);
      n = larger < 20 ? 1.0 : larger.toDouble();
    }

    return (config.compatExcessCoeff * excess / n) +
        (config.compatDisjointCoeff * disjoint / n) +
        (config.compatWeightCoeff * wBar);
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------


  // -------------------------------------------------------------------------
  // Serialization
  // -------------------------------------------------------------------------

  /// Encode this genome to a JSON-compatible map for save/load.
  Map<String, dynamic> toJson() {
    return {
      'nodes': [
        for (final n in nodes.values)
          {
            'id': n.id,
            'type': n.type.index,
            'activation': n.activation.index,
            'layer': n.layer,
          },
      ],
      'connections': [
        for (final c in connections.values)
          {
            'innovation': c.innovation,
            'inNode': c.inNode,
            'outNode': c.outNode,
            'weight': c.weight,
            'enabled': c.enabled,
          },
      ],
      'fitness': fitness,
      'speciesId': speciesId,
      if (behaviorVector != null) 'behavior': behaviorVector,
    };
  }

  /// Decode a genome from a JSON-compatible map.
  factory NeatGenome.fromJson(Map<String, dynamic> json) {
    final nodes = <int, NodeGene>{};
    for (final n in json['nodes'] as List) {
      final map = n as Map<String, dynamic>;
      final id = map['id'] as int;
      nodes[id] = NodeGene(
        id: id,
        type: NodeType.values[map['type'] as int],
        activation: ActivationFunction.values[map['activation'] as int],
        layer: map['layer'] as int,
      );
    }

    final connections = <int, ConnectionGene>{};
    for (final c in json['connections'] as List) {
      final map = c as Map<String, dynamic>;
      final innov = map['innovation'] as int;
      connections[innov] = ConnectionGene(
        innovation: innov,
        inNode: map['inNode'] as int,
        outNode: map['outNode'] as int,
        weight: (map['weight'] as num).toDouble(),
        enabled: map['enabled'] as bool,
      );
    }

    final behaviorVector = (json['behavior'] as List?)
        ?.map((e) => (e as num).toDouble())
        .toList();

    return NeatGenome(
      nodes: nodes,
      connections: connections,
      fitness: (json['fitness'] as num?)?.toDouble() ?? 0.0,
      speciesId: json['speciesId'] as int? ?? -1,
      behaviorVector: behaviorVector,
    );
  }

  void _pruneOrphanNodes() {
    final referenced = <int>{};
    for (final c in connections.values) {
      referenced.add(c.inNode);
      referenced.add(c.outNode);
    }
    nodes.removeWhere(
        (id, node) => node.type == NodeType.hidden && !referenced.contains(id));
  }

  /// Simple Gaussian random via Box-Muller transform.
  static double _gaussian(Random rng) {
    double u1 = rng.nextDouble();
    if (u1 < 1e-10) u1 = 1e-10;
    final u2 = rng.nextDouble();
    return sqrt(-2.0 * log(u1)) * cos(2.0 * pi * u2);
  }

  @override
  String toString() =>
      'NeatGenome(nodes=${nodes.length}, conns=${connections.length}, '
      'fitness=$fitness, species=$speciesId)';
}
