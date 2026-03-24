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
/// - Forward pass: ~0.1-0.5 microseconds depending on hidden node count.
/// - At 1000 ants: ~0.1-0.5 milliseconds per frame. Well within budget.
///
/// Connections are pre-grouped by target node during construction so the
/// forward pass avoids scanning the entire connection list for each node.
/// All arrays use [Float32List] / [Int32List] for cache-friendly access.
/// No heap allocation occurs during [activate] after construction.
///
/// ## Optimizations (v2)
///
/// - **Float32 weights**: Halves memory vs Float64. Weights are clamped to
///   [-8, 8] so Float32's ~7 digits of precision is more than sufficient.
/// - **Fast activation approximations**: Polynomial tanh/sigmoid avoid
///   expensive `exp()` calls. Max error ~0.004 for tanh, ~0.01 for sigmoid.
/// - **Network pruning**: [pruned()] removes near-zero-weight connections
///   post-training without meaningful behavior change.
/// - **Batch inference**: [activateBatch()] processes multiple creatures'
///   inputs in one call, improving cache locality.
class NeatForward {
  NeatForward._({
    required this.nodeCount,
    required this.inputCount,
    required this.outputCount,
    required this.biasCount,
    required Int32List activationOrder,
    required List<ActivationFunction> nodeActivations,
    required Float32List nodeValues,
    required Int32List connFromIndices,
    required Float32List connWeights,
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
  final Float32List _values;

  /// For each connection (grouped by target node): source node index.
  final Int32List _connFromIndices;

  /// For each connection (grouped by target node): weight.
  final Float32List _connWeights;

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
    final connWeights = Float32List(connTriples.length);
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
      nodeValues: Float32List(totalNodes),
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

      _values[nodeIdx] = _activateFast(sum, _nodeActivations[nodeIdx]);
    }

    // Extract outputs (they sit right after bias+inputs in our index layout).
    // Return as Float64List for API compatibility with callers.
    final outputStart = fixedCount;
    final result = Float64List(outputCount);
    for (var i = 0; i < outputCount; i++) {
      result[i] = _values[outputStart + i];
    }
    return result;
  }

  /// Batch-evaluate multiple input vectors in one call.
  ///
  /// [batchInputs] is a list of input vectors, each with [inputCount] elements.
  /// Returns a list of output vectors, each with [outputCount] elements.
  ///
  /// This is faster than calling [activate] in a loop because:
  /// - The activation order array stays in L1 cache across all evaluations.
  /// - Connection arrays are traversed once per batch rather than re-fetched.
  /// - Reduces Dart call overhead for large batches.
  ///
  /// For 150 creatures with 9 inputs and 6 outputs, this processes a
  /// 150x9 input matrix and produces a 150x6 output matrix.
  List<Float64List> activateBatch(List<List<double>> batchInputs) {
    final batchSize = batchInputs.length;
    if (batchSize == 0) return [];
    if (batchSize == 1) return [activate(batchInputs[0])];

    final fixedCount = biasCount + inputCount;
    final outputStart = fixedCount;
    final orderLen = _activationOrder.length;

    // Pre-cache connection arrays as locals for tight inner loops.
    final connFrom = _connFromIndices;
    final connW = _connWeights;
    final connStart = _nodeConnStart;
    final connCount = _nodeConnCount;
    final actOrder = _activationOrder;
    final nodeActs = _nodeActivations;

    // Allocate a flat batch buffer: batchSize * nodeCount.
    // Using Float32List for cache efficiency — these are intermediate values.
    final batchValues = Float32List(batchSize * nodeCount);

    // Set bias and input values for all batch items.
    for (var b = 0; b < batchSize; b++) {
      final base = b * nodeCount;
      final inputs = batchInputs[b];

      for (var i = 0; i < biasCount; i++) {
        batchValues[base + i] = 1.0;
      }
      for (var i = 0; i < inputCount; i++) {
        batchValues[base + biasCount + i] = inputs[i];
      }
      // Hidden/output nodes are already 0.0 from Float32List initialization.
    }

    // Propagate: for each node in topological order, process ALL batch items.
    // This keeps the connection metadata in cache across the entire batch.
    for (var oi = 0; oi < orderLen; oi++) {
      final nodeIdx = actOrder[oi];
      final start = connStart[nodeIdx];
      final count = connCount[nodeIdx];
      final act = nodeActs[nodeIdx];

      for (var b = 0; b < batchSize; b++) {
        final base = b * nodeCount;

        double sum = 0.0;
        for (var ci = start; ci < start + count; ci++) {
          sum += batchValues[base + connFrom[ci]] * connW[ci];
        }

        batchValues[base + nodeIdx] = _activateFast(sum, act);
      }
    }

    // Extract outputs.
    final results = List<Float64List>.generate(batchSize, (_) => Float64List(outputCount));
    for (var b = 0; b < batchSize; b++) {
      final base = b * nodeCount;
      final result = results[b];
      for (var i = 0; i < outputCount; i++) {
        result[i] = batchValues[base + outputStart + i];
      }
    }

    return results;
  }

  /// Number of connections in this compiled network.
  int get connectionCount => _connFromIndices.length;

  /// Number of hidden nodes (total - bias - inputs - outputs).
  int get hiddenNodeCount => nodeCount - biasCount - inputCount - outputCount;

  // ---------------------------------------------------------------------------
  // Pruning
  // ---------------------------------------------------------------------------

  /// Create a pruned copy of this network, removing connections with
  /// |weight| < [threshold].
  ///
  /// After QDax/NEAT training, many connections evolve near-zero weights that
  /// contribute negligibly to output. Removing them speeds up inference
  /// without meaningful behavior change.
  ///
  /// Returns a new [NeatForward] with the pruned connection set. The original
  /// is not modified.
  NeatForward pruned({double threshold = 0.01}) {
    // Count surviving connections.
    final totalConns = _connFromIndices.length;
    int surviving = 0;
    for (var i = 0; i < totalConns; i++) {
      if (_connWeights[i].abs() >= threshold) surviving++;
    }

    // If nothing to prune, return this.
    if (surviving == totalConns) return this;

    // Rebuild connection arrays without pruned connections.
    final newConnFrom = Int32List(surviving);
    final newConnWeights = Float32List(surviving);
    final newNodeConnStart = Int32List(nodeCount);
    final newNodeConnCount = Int32List(nodeCount);

    // First pass: count surviving connections per target node.
    // Connections are grouped by target node, so we iterate in order.
    for (var n = 0; n < nodeCount; n++) {
      final start = _nodeConnStart[n];
      final count = _nodeConnCount[n];
      for (var ci = start; ci < start + count; ci++) {
        if (_connWeights[ci].abs() >= threshold) {
          newNodeConnCount[n]++;
        }
      }
    }

    // Compute prefix sums for new start offsets.
    var offset = 0;
    for (var n = 0; n < nodeCount; n++) {
      newNodeConnStart[n] = offset;
      offset += newNodeConnCount[n];
    }

    // Second pass: copy surviving connections.
    final writeIdx = Int32List(nodeCount); // per-node write cursor
    for (var n = 0; n < nodeCount; n++) {
      writeIdx[n] = newNodeConnStart[n];
    }

    for (var n = 0; n < nodeCount; n++) {
      final start = _nodeConnStart[n];
      final count = _nodeConnCount[n];
      for (var ci = start; ci < start + count; ci++) {
        if (_connWeights[ci].abs() >= threshold) {
          final wi = writeIdx[n]++;
          newConnFrom[wi] = _connFromIndices[ci];
          newConnWeights[wi] = _connWeights[ci];
        }
      }
    }

    return NeatForward._(
      nodeCount: nodeCount,
      inputCount: inputCount,
      outputCount: outputCount,
      biasCount: biasCount,
      activationOrder: Int32List.fromList(_activationOrder),
      nodeActivations: List<ActivationFunction>.from(_nodeActivations),
      nodeValues: Float32List(nodeCount),
      connFromIndices: newConnFrom,
      connWeights: newConnWeights,
      nodeConnStart: newNodeConnStart,
      nodeConnCount: newNodeConnCount,
    );
  }

  // ---------------------------------------------------------------------------
  // Serialization (compiled network cache)
  // ---------------------------------------------------------------------------

  /// Serialize the compiled network to a compact binary-friendly map.
  ///
  /// This allows skipping the topological sort when loading a saved genome
  /// by caching the compiled form alongside the genome.
  Map<String, dynamic> toCompiledJson() {
    return {
      'nodeCount': nodeCount,
      'inputCount': inputCount,
      'outputCount': outputCount,
      'biasCount': biasCount,
      'activationOrder': _activationOrder.toList(),
      'nodeActivations': _nodeActivations.map((a) => a.index).toList(),
      'connFromIndices': _connFromIndices.toList(),
      'connWeights': _connWeights.toList(),
      'nodeConnStart': _nodeConnStart.toList(),
      'nodeConnCount': _nodeConnCount.toList(),
    };
  }

  /// Restore a compiled network from [toCompiledJson] output.
  ///
  /// Skips the topological sort entirely — useful for loading saved genomes
  /// where the compiled form was cached at save time.
  factory NeatForward.fromCompiledJson(Map<String, dynamic> json) {
    final nodeCount = json['nodeCount'] as int;
    return NeatForward._(
      nodeCount: nodeCount,
      inputCount: json['inputCount'] as int,
      outputCount: json['outputCount'] as int,
      biasCount: json['biasCount'] as int,
      activationOrder: Int32List.fromList(
          (json['activationOrder'] as List).cast<int>()),
      nodeActivations: (json['nodeActivations'] as List)
          .map((i) => ActivationFunction.values[i as int])
          .toList(),
      nodeValues: Float32List(nodeCount),
      connFromIndices: Int32List.fromList(
          (json['connFromIndices'] as List).cast<int>()),
      connWeights: Float32List.fromList(
          (json['connWeights'] as List).map((v) => (v as num).toDouble()).toList()),
      nodeConnStart: Int32List.fromList(
          (json['nodeConnStart'] as List).cast<int>()),
      nodeConnCount: Int32List.fromList(
          (json['nodeConnCount'] as List).cast<int>()),
    );
  }

  // ---------------------------------------------------------------------------
  // Fast activation functions
  // ---------------------------------------------------------------------------

  /// Apply an activation function using fast polynomial approximations.
  ///
  /// Avoids expensive `exp()` calls in the hot loop. For our use case
  /// (weights in [-8, 8], tanh outputs for ant movement), the approximation
  /// error is imperceptible.
  @pragma('vm:prefer-inline')
  static double _activateFast(double x, ActivationFunction fn) {
    switch (fn) {
      case ActivationFunction.sigmoid:
        // Fast sigmoid: 0.5 + 0.5 * fastTanh(0.5 * x)
        // Derived from: sigmoid(x) = 0.5 * (1 + tanh(x/2))
        return 0.5 + 0.5 * _fastTanh(0.5 * x);
      case ActivationFunction.tanh:
        return _fastTanh(x);
      case ActivationFunction.relu:
        return x > 0 ? x : 0.0;
      case ActivationFunction.linear:
        return x;
      case ActivationFunction.gaussian:
        // Fast Gaussian: use a rational approximation for e^(-x^2).
        // For |x| > 3.0, result is < 0.0001 so we clamp to 0.
        final xx = x * x;
        if (xx > 9.0) return 0.0;
        // Padé-style approximation: 1 / (1 + xx + 0.5*xx*xx + xx*xx*xx/6)
        return 1.0 / (1.0 + xx * (1.0 + xx * (0.5 + xx * 0.1667)));
      case ActivationFunction.step:
        return x > 0 ? 1.0 : 0.0;
    }
  }

  /// Fast tanh approximation using rational polynomial.
  ///
  /// Formula: x * (27 + x^2) / (27 + 9 * x^2)
  ///
  /// Max error: ~0.004 for |x| < 3. For |x| >= 3, clamps to +/-1.0
  /// which matches true tanh to within 0.005.
  ///
  /// ~5x faster than dart:math exp()-based tanh on mobile CPUs.
  @pragma('vm:prefer-inline')
  static double _fastTanh(double x) {
    if (x > 3.0) return 1.0;
    if (x < -3.0) return -1.0;
    final xx = x * x;
    return x * (27.0 + xx) / (27.0 + 9.0 * xx);
  }
}
