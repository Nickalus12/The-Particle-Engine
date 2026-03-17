import 'dart:math';
import 'dart:typed_data';

import 'neat_config.dart';
import 'neat_genome.dart';

/// Builds a runnable feed-forward network from a [NeatGenome] and evaluates
/// inputs to produce outputs via topological-sort-based forward pass.
///
/// This is the "phenotype" — the actual neural network expressed from the
/// genome's genotype. It is rebuilt whenever the genome structure changes
/// (after structural mutation or crossover).
///
/// ## Performance
///
/// For a tiny ant brain (8 inputs, ~0-20 hidden, 6 outputs):
/// - Construction (topo sort): one-time cost, ~2-5 microseconds.
/// - Forward pass: ~0.2-1 microseconds depending on hidden node count.
/// - At 1000 ants: ~0.2-1 milliseconds per frame. Well within budget.
///
/// Connections are pre-grouped by target node during construction so the
/// forward pass avoids scanning the entire connection list for each node.
/// All arrays use [Float64List] / [Int32List] for cache-friendly access.
/// No heap allocation occurs during [activate] after construction.
class NeatForward {
  NeatForward._({
    required this.nodeCount,
    required this.inputCount,
    required this.outputCount,
    required this.biasCount,
    required Int32List activationOrder,
    required List<ActivationFunction> nodeActivations,
    required Float64List nodeValues,
    required Int32List connFromIndices,
    required Float64List connWeights,
    required Int32List nodeConnStart,
    required Int32List nodeConnCount,
  })  : _activationOrder = activationOrder,
        _nodeActivations = nodeActivations,
        _values = nodeValues,
        _connFromIndices = connFromIndices,
        _connWeights = connWeights,
        _nodeConnStart = nodeConnStart,
        _nodeConnCount = nodeConnCount;

  /// Total number of nodes in the network.
  final int nodeCount;

  /// Number of input nodes (excludes bias).
  final int inputCount;

  /// Number of output nodes.
  final int outputCount;

  /// Number of bias nodes (typically 1).
  final int biasCount;

  /// Nodes in topological order for the forward pass (dense indices).
  /// Input/bias nodes are excluded — they are set directly.
  final Int32List _activationOrder;

  /// Activation function per dense node index.
  final List<ActivationFunction> _nodeActivations;

  /// Pre-allocated buffer for node values. Reused across calls to [activate].
  final Float64List _values;

  /// For each connection (grouped by target node): source node index.
  final Int32List _connFromIndices;

  /// For each connection (grouped by target node): weight.
  final Float64List _connWeights;

  /// Per-node: starting offset into [_connFromIndices] / [_connWeights].
  final Int32List _nodeConnStart;

  /// Per-node: number of incoming connections.
  final Int32List _nodeConnCount;

  // ---------------------------------------------------------------------------
  // Factory: build from genome
  // ---------------------------------------------------------------------------

  /// Compile a [NeatGenome] into a runnable forward-pass network.
  ///
  /// Steps:
  /// 1. Map node ids to dense indices (0..N-1).
  /// 2. Topologically sort hidden + output nodes (Kahn's algorithm).
  /// 3. Group connections by target node for O(1) lookup during forward pass.
  factory NeatForward.fromGenome(NeatGenome genome) {
    // -- Step 1: assign dense indices ----------------------------------------
    // Order: bias (0), inputs (1..inputCount), outputs, hidden.
    final idToIndex = <int, int>{};
    int idx = 0;

    final biasNodes = genome.nodes.values
        .where((n) => n.type == NodeType.bias)
        .toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    for (final n in biasNodes) {
      idToIndex[n.id] = idx++;
    }

    final inputNodes = genome.nodes.values
        .where((n) => n.type == NodeType.input)
        .toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    for (final n in inputNodes) {
      idToIndex[n.id] = idx++;
    }

    final outputNodes = genome.nodes.values
        .where((n) => n.type == NodeType.output)
        .toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    for (final n in outputNodes) {
      idToIndex[n.id] = idx++;
    }

    final hiddenNodes = genome.nodes.values
        .where((n) => n.type == NodeType.hidden)
        .toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    for (final n in hiddenNodes) {
      idToIndex[n.id] = idx++;
    }

    final totalNodes = idx;
    final biasCount = biasNodes.length;
    final inputCount = inputNodes.length;
    final outputCount = outputNodes.length;
    final fixedCount = biasCount + inputCount;

    // -- Step 2: build adjacency from enabled connections --------------------
    final enabledConns = genome.connections.values
        .where((c) => c.enabled)
        .toList();

    // Build successor lists for Kahn's algorithm.
    final successors = List<List<int>>.generate(totalNodes, (_) => []);
    final inDegree = Int32List(totalNodes);

    // Also collect (fromIdx, toIdx, weight) for later grouping.
    final connTriples = <(int, int, double)>[];

    for (final c in enabledConns) {
      final fromIdx = idToIndex[c.inNode];
      final toIdx = idToIndex[c.outNode];
      if (fromIdx == null || toIdx == null) continue;
      successors[fromIdx].add(toIdx);
      inDegree[toIdx]++;
      connTriples.add((fromIdx, toIdx, c.weight));
    }

    // -- Step 3: topological sort (Kahn's algorithm) -------------------------
    final queue = <int>[];
    for (var i = 0; i < fixedCount; i++) {
      queue.add(i); // Seed with bias + input nodes.
    }

    final order = <int>[];
    final visited = List<bool>.filled(totalNodes, false);
    var head = 0;

    while (head < queue.length) {
      final current = queue[head++];
      visited[current] = true;

      for (final succ in successors[current]) {
        inDegree[succ]--;
        if (inDegree[succ] <= 0 && !visited[succ]) {
          visited[succ] = true;
          if (succ >= fixedCount) {
            order.add(succ);
          }
          queue.add(succ);
        }
      }
    }

    // Ensure all output nodes appear in the order (even if disconnected).
    for (var i = fixedCount; i < fixedCount + outputCount; i++) {
      if (!visited[i]) order.add(i);
    }

    // -- Step 4: group connections by target node ----------------------------
    // Sort connections by target node index so we can do contiguous reads.
    connTriples.sort((a, b) => a.$2.compareTo(b.$2));

    final connFromIndices = Int32List(connTriples.length);
    final connWeights = Float64List(connTriples.length);
    final nodeConnStart = Int32List(totalNodes);
    final nodeConnCount = Int32List(totalNodes);

    for (var i = 0; i < connTriples.length; i++) {
      final (from, to, w) = connTriples[i];
      connFromIndices[i] = from;
      connWeights[i] = w;
      nodeConnCount[to]++;
    }

    // Compute start offsets (prefix sum).
    var offset = 0;
    for (var n = 0; n < totalNodes; n++) {
      nodeConnStart[n] = offset;
      offset += nodeConnCount[n];
    }

    // -- Step 5: build activation function list ------------------------------
    final activations = List<ActivationFunction>.filled(
        totalNodes, ActivationFunction.linear);
    for (final entry in genome.nodes.entries) {
      final i = idToIndex[entry.key];
      if (i != null) activations[i] = entry.value.activation;
    }

    return NeatForward._(
      nodeCount: totalNodes,
      inputCount: inputCount,
      outputCount: outputCount,
      biasCount: biasCount,
      activationOrder: Int32List.fromList(order),
      nodeActivations: activations,
      nodeValues: Float64List(totalNodes),
      connFromIndices: connFromIndices,
      connWeights: connWeights,
      nodeConnStart: nodeConnStart,
      nodeConnCount: nodeConnCount,
    );
  }

  // ---------------------------------------------------------------------------
  // Forward pass
  // ---------------------------------------------------------------------------

  /// Run the network on [inputs] and return the output values.
  ///
  /// [inputs] must have exactly [inputCount] elements. The returned list
  /// has [outputCount] elements.
  ///
  /// **Zero allocation** after construction — all buffers are pre-allocated.
  Float64List activate(List<double> inputs) {
    assert(inputs.length == inputCount);

    final fixedCount = biasCount + inputCount;

    // Set bias node(s).
    for (var i = 0; i < biasCount; i++) {
      _values[i] = 1.0;
    }

    // Set input nodes.
    for (var i = 0; i < inputCount; i++) {
      _values[biasCount + i] = inputs[i];
    }

    // Reset non-input nodes before propagation.
    for (var i = fixedCount; i < nodeCount; i++) {
      _values[i] = 0.0;
    }

    // Propagate in topological order: for each node, sum its weighted
    // inputs from already-computed predecessors, then apply activation.
    final orderLen = _activationOrder.length;
    for (var oi = 0; oi < orderLen; oi++) {
      final nodeIdx = _activationOrder[oi];
      final start = _nodeConnStart[nodeIdx];
      final count = _nodeConnCount[nodeIdx];

      double sum = 0.0;
      for (var ci = start; ci < start + count; ci++) {
        sum += _values[_connFromIndices[ci]] * _connWeights[ci];
      }

      _values[nodeIdx] = _activate(sum, _nodeActivations[nodeIdx]);
    }

    // Extract outputs (they sit right after bias+inputs in our index layout).
    final outputStart = fixedCount;
    return Float64List.sublistView(
        _values, outputStart, outputStart + outputCount);
  }

  /// Number of connections in this compiled network.
  int get connectionCount => _connFromIndices.length;

  /// Number of hidden nodes (total - bias - inputs - outputs).
  int get hiddenNodeCount => nodeCount - biasCount - inputCount - outputCount;

  /// Apply an activation function to a single value.
  static double _activate(double x, ActivationFunction fn) {
    switch (fn) {
      case ActivationFunction.sigmoid:
        return 1.0 / (1.0 + exp(-x));
      case ActivationFunction.tanh:
        final e2x = exp(2.0 * x);
        return (e2x - 1.0) / (e2x + 1.0);
      case ActivationFunction.relu:
        return x > 0 ? x : 0.0;
      case ActivationFunction.linear:
        return x;
      case ActivationFunction.gaussian:
        return exp(-x * x);
      case ActivationFunction.step:
        return x > 0 ? 1.0 : 0.0;
    }
  }
}
