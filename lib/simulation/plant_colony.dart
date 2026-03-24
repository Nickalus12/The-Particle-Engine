import 'dart:math';
import 'dart:typed_data';

import 'simulation_engine.dart';

// ---------------------------------------------------------------------------
// Neural plant colony system — each colony shares a compact genome that
// drives growth decisions via a tiny feed-forward network.
//
// Architecture: 8 inputs -> 4 hidden (tanh) -> 6 outputs (tanh)
//   Weights: 8*4 + 4 bias + 4*6 + 6 bias = 32 + 4 + 24 + 6 = 66 params
// ---------------------------------------------------------------------------

/// Number of neural network inputs.
const int kPlantInputs = 8;

/// Number of hidden neurons.
const int kPlantHidden = 4;

/// Number of neural network outputs.
const int kPlantOutputs = 6;

/// Total genome size (weights + biases).
const int kPlantGenomeSize = kPlantInputs * kPlantHidden + kPlantHidden +
    kPlantHidden * kPlantOutputs + kPlantOutputs; // = 66

/// Neural output indices.
const int kOutGrowUp = 0;
const int kOutGrowLateral = 1;
const int kOutBranch = 2;
const int kOutSeedProduction = 3;
const int kOutResourceAlloc = 4;
const int kOutToxin = 5;

/// A single plant colony with a shared neural genome.
class PlantColony {
  final int id;

  /// Neural network weights (66 doubles).
  final Float64List genome;

  /// Grid indices belonging to this colony.
  final Set<int> cells = {};

  /// Total biomass (number of living cells).
  int get totalBiomass => cells.length;

  /// Colony age in ticks.
  int age = 0;

  /// Cumulative fitness metrics.
  double fitnessScore = 0.0;
  int seedsProduced = 0;
  int oxygenProduced = 0;
  int herbivoresDamaged = 0;
  int cellsEaten = 0;

  /// Toxin level evolved by this colony (0.0-1.0). Persistent per colony.
  double toxinLevel = 0.0;

  /// Reusable buffers for neural forward pass (avoid allocation).
  final Float64List _hidden = Float64List(kPlantHidden);
  final Float64List _outputs = Float64List(kPlantOutputs);
  final Float64List _inputs = Float64List(kPlantInputs);

  PlantColony({required this.id, Float64List? genome})
      : genome = genome ?? _randomGenome(Random());

  /// Create with a specific random seed.
  PlantColony.seeded({required this.id, required int seed})
      : genome = _randomGenome(Random(seed));

  /// Create a mutated offspring colony from a parent.
  PlantColony.mutated({required this.id, required PlantColony parent, Random? rng})
      : genome = _mutateGenome(parent.genome, rng ?? Random()) {
    toxinLevel = parent.toxinLevel;
  }

  /// Run the neural forward pass for a cell's growth decision.
  ///
  /// Inputs are gathered from the local cell environment.
  /// Returns the output buffer (reused — do not store).
  Float64List decide(
    double luminance,
    double luminanceGrad,
    double moisture,
    double moistureGrad,
    double ph,
    double temperature,
    double crowding,
    double normalizedAge,
  ) {
    _inputs[0] = luminance;
    _inputs[1] = luminanceGrad;
    _inputs[2] = moisture;
    _inputs[3] = moistureGrad;
    _inputs[4] = ph;
    _inputs[5] = temperature;
    _inputs[6] = crowding;
    _inputs[7] = normalizedAge;

    // Hidden layer: tanh(W_ih * inputs + b_h)
    int wi = 0;
    for (int h = 0; h < kPlantHidden; h++) {
      double sum = 0.0;
      for (int i = 0; i < kPlantInputs; i++) {
        sum += genome[wi++] * _inputs[i];
      }
      sum += genome[kPlantInputs * kPlantHidden + h]; // bias
      // Fast tanh approximation
      _hidden[h] = sum / (1.0 + sum.abs());
    }

    // Output layer: tanh(W_ho * hidden + b_o)
    final oWeightStart = kPlantInputs * kPlantHidden + kPlantHidden;
    for (int o = 0; o < kPlantOutputs; o++) {
      double sum = 0.0;
      for (int h = 0; h < kPlantHidden; h++) {
        sum += genome[oWeightStart + o * kPlantHidden + h] * _hidden[h];
      }
      sum += genome[oWeightStart + kPlantHidden * kPlantOutputs + o]; // bias
      _outputs[o] = sum / (1.0 + sum.abs());
    }

    return _outputs;
  }

  /// Generate random initial genome weights in [-1, 1].
  static Float64List _randomGenome(Random rng) {
    final g = Float64List(kPlantGenomeSize);
    for (int i = 0; i < kPlantGenomeSize; i++) {
      g[i] = rng.nextDouble() * 2.0 - 1.0;
    }
    return g;
  }

  /// Mutate a genome with small gaussian-like perturbations.
  static Float64List _mutateGenome(Float64List parent, Random rng) {
    final g = Float64List(kPlantGenomeSize);
    for (int i = 0; i < kPlantGenomeSize; i++) {
      if (rng.nextInt(5) == 0) {
        // 20% chance of mutation per weight
        g[i] = parent[i] + (rng.nextDouble() - 0.5) * 0.4;
        g[i] = g[i].clamp(-2.0, 2.0);
      } else {
        g[i] = parent[i];
      }
    }
    return g;
  }
}

/// Registry managing all plant colonies. Provides O(1) cell-to-colony lookup.
class PlantColonyRegistry {
  final List<PlantColony> _colonies = [];
  int _nextId = 0;

  /// Map from grid index to colony ID for O(1) lookup.
  /// Sized lazily to match the simulation grid.
  Int32List _cellToColony = Int32List(0);

  /// Sentinel value meaning "no colony".
  static const int noColony = -1;

  /// All active colonies.
  List<PlantColony> get colonies => _colonies;

  /// Initialize or resize the cell-to-colony map.
  void ensureSize(int totalCells) {
    if (_cellToColony.length != totalCells) {
      _cellToColony = Int32List(totalCells);
      _cellToColony.fillRange(0, totalCells, noColony);
      // Rebuild from existing colonies
      for (final colony in _colonies) {
        for (final idx in colony.cells) {
          if (idx >= 0 && idx < totalCells) {
            _cellToColony[idx] = colony.id;
          }
        }
      }
    }
  }

  /// Find the colony owning a given cell, or null.
  PlantColony? colonyForCell(int idx) {
    if (idx < 0 || idx >= _cellToColony.length) return null;
    final cid = _cellToColony[idx];
    if (cid == noColony) return null;
    for (final c in _colonies) {
      if (c.id == cid) return c;
    }
    return null;
  }

  /// Spawn a new colony at a grid cell with optional parent for mutation.
  PlantColony spawn(int cellIdx, {PlantColony? parent}) {
    final id = _nextId++;
    final colony = parent != null
        ? PlantColony.mutated(id: id, parent: parent)
        : PlantColony(id: id);
    _colonies.add(colony);
    addCell(colony, cellIdx);
    return colony;
  }

  /// Register a cell as belonging to a colony.
  void addCell(PlantColony colony, int idx) {
    if (idx < 0 || idx >= _cellToColony.length) return;
    colony.cells.add(idx);
    _cellToColony[idx] = colony.id;
  }

  /// Remove a cell from its colony.
  void removeCell(int idx) {
    if (idx < 0 || idx >= _cellToColony.length) return;
    final cid = _cellToColony[idx];
    if (cid == noColony) return;
    _cellToColony[idx] = noColony;
    for (final c in _colonies) {
      if (c.id == cid) {
        c.cells.remove(idx);
        break;
      }
    }
  }

  /// Tick all colonies: age them, prune dead ones.
  void tick() {
    for (final colony in _colonies) {
      colony.age++;
      // Update toxin level from neural decisions (slow drift)
      colony.fitnessScore += colony.totalBiomass * 0.01;
    }
    // Prune colonies with no living cells and age > 100
    _colonies.removeWhere((c) {
      if (c.cells.isEmpty && c.age > 100) return true;
      return false;
    });
  }

  /// Gather 8 neural inputs for a plant cell at grid index.
  Float64List gatherInputs(SimulationEngine engine, int x, int y, int idx) {
    final w = engine.gridW;
    final inputs = Float64List(kPlantInputs);

    // 0: luminance (normalized 0-1)
    inputs[0] = engine.luminance[idx] / 255.0;

    // 1: luminance gradient (left-right difference)
    final lx = x > 0 ? engine.luminance[idx - 1] : 0;
    final rx = x < w - 1 ? engine.luminance[idx + 1] : 0;
    inputs[1] = (rx - lx) / 255.0;

    // 2: moisture (nearby water/wet dirt)
    inputs[2] = engine.moisture[idx] / 255.0;

    // 3: moisture gradient (up-down difference)
    final uy = y > 0 ? engine.moisture[(y - 1) * w + x] : 0;
    final dy = y < engine.gridH - 1 ? engine.moisture[(y + 1) * w + x] : 0;
    inputs[3] = (dy - uy) / 255.0;

    // 4: pH (normalized)
    inputs[4] = engine.pH[idx] / 255.0;

    // 5: temperature (normalized)
    inputs[5] = engine.temperature[idx] / 255.0;

    // 6: crowding (count nearby same-element cells / 8)
    int crowdCount = 0;
    final el = engine.grid[idx];
    for (int dy2 = -1; dy2 <= 1; dy2++) {
      for (int dx2 = -1; dx2 <= 1; dx2++) {
        if (dx2 == 0 && dy2 == 0) continue;
        final nx = engine.wrapX(x + dx2);
        final ny = y + dy2;
        if (!engine.inBoundsY(ny)) continue;
        if (engine.grid[ny * w + nx] == el) crowdCount++;
      }
    }
    inputs[6] = crowdCount / 8.0;

    // 7: normalized cell age
    inputs[7] = engine.cellAge[idx] / 255.0;

    return inputs;
  }

  /// Clear all colonies (e.g., on world reset).
  void clear() {
    _colonies.clear();
    _cellToColony.fillRange(0, _cellToColony.length, noColony);
    _nextId = 0;
  }
}
