import 'dart:typed_data';

import '../element_registry.dart';
import '../simulation_engine.dart';
import 'worldgen_summary.dart';

/// Container for all grid arrays the simulation engine needs.
///
/// Uses the same typed-array format as [SimulationEngine]:
/// [Uint8List] for grid/life/flags, [Int8List] for velocities.
class GridData {
  GridData({
    required this.width,
    required this.height,
    required this.grid,
    required this.life,
    required this.flags,
    required this.velX,
    required this.velY,
    required this.temperature,
  });

  /// Create an empty grid with all arrays zeroed (temperature at neutral 128).
  factory GridData.empty(int width, int height) {
    final size = width * height;
    final temp = Uint8List(size);
    temp.fillRange(0, size, 128);
    return GridData(
      width: width,
      height: height,
      grid: Uint8List(size),
      life: Uint8List(size),
      flags: Uint8List(size),
      velX: Int8List(size),
      velY: Int8List(size),
      temperature: temp,
    );
  }

  final int width;
  final int height;

  /// Element type per cell (byte value from [El]).
  final Uint8List grid;

  /// Per-cell lifetime / state counter.
  final Uint8List life;

  /// Per-cell flags.
  final Uint8List flags;

  /// Per-cell horizontal velocity / plant data.
  final Int8List velX;

  /// Per-cell vertical velocity.
  final Int8List velY;

  /// Per-cell temperature (0-255, 128=neutral).
  final Uint8List temperature;

  /// Stage-by-stage metadata captured during world generation.
  WorldGenSummary? worldGenSummary;

  /// Convert (x, y) to flat index.
  int toIndex(int x, int y) => y * width + x;

  /// Whether (x, y) is within bounds.
  bool inBounds(int x, int y) => x >= 0 && x < width && y >= 0 && y < height;

  /// Get element at (x, y). Returns [El.empty] for out-of-bounds.
  int get(int x, int y) {
    if (!inBounds(x, y)) return El.empty;
    return grid[toIndex(x, y)];
  }

  /// Set element at (x, y). Silently ignores out-of-bounds.
  void set(int x, int y, int type) {
    if (!inBounds(x, y)) return;
    grid[toIndex(x, y)] = type;
  }

  /// Set element with life value.
  void setWithLife(int x, int y, int type, int lifeVal) {
    if (!inBounds(x, y)) return;
    final idx = toIndex(x, y);
    grid[idx] = type;
    life[idx] = lifeVal;
  }

  /// Set plant data (type + stage packed into velX).
  void setPlant(int x, int y, int plantType, int plantStage) {
    if (!inBounds(x, y)) return;
    final idx = toIndex(x, y);
    grid[idx] = El.plant;
    velX[idx] = ((plantStage & 0xF) << 4) | (plantType & 0xF);
  }

  /// Set temperature at (x, y).
  void setTemp(int x, int y, int temp) {
    if (!inBounds(x, y)) return;
    temperature[toIndex(x, y)] = temp;
  }

  /// Colony positions placed during generation.
  ///
  /// The first colony (if any) is set as the engine's primary colony.
  final List<(int, int)> colonyPositions = [];

  /// Load this generated world into a [SimulationEngine].
  ///
  /// Copies all typed arrays into the engine, resizing if needed,
  /// marks all chunks dirty, and sets the primary colony position.
  void loadIntoEngine(SimulationEngine engine) {
    engine.init(width, height);
    engine.grid.setAll(0, grid);
    engine.life.setAll(0, life);
    engine.flags.setAll(0, flags);
    engine.velX.setAll(0, velX);
    engine.velY.setAll(0, velY);
    engine.temperature.setAll(0, temperature);

    // Initialize mass for all placed elements
    final g = engine.grid;
    final m = engine.mass;
    for (int i = 0; i < g.length; i++) {
      final el = g[i];
      if (el != El.empty && el < maxElements) {
        m[i] = elementBaseMass[el];
      }
    }

    // Set primary colony position for pheromone system.
    if (colonyPositions.isNotEmpty) {
      final (cx, cy) = colonyPositions.first;
      engine.colonyX = cx;
      engine.colonyY = cy;
    }

    engine.markAllDirty();
  }
}
