import 'dart:math';
import 'dart:typed_data';

import '../utils/fast_rng.dart';
import 'element_registry.dart';
import 'plant_colony.dart';

// ---------------------------------------------------------------------------
// SimulationEngine -- Core grid data, helpers, and main simulation loop
// ---------------------------------------------------------------------------

/// Integer sine: phase [0..255] → [-128, 128] (signed, centered at 0).
@pragma('vm:prefer-inline')
int _sinI256(int phase) {
  final ix = phase & 0xFF;
  if (ix < 64) return ix << 1; // 0 to 128
  if (ix < 128) return (128 - ix) << 1; // 128 to 0
  if (ix < 192) return -((ix - 128) << 1); // 0 to -128
  return -((256 - ix) << 1); // -128 to 0
}

/// Data class for explosion events.
class Explosion {
  final int x;
  final int y;
  final int radius;
  const Explosion(this.x, this.y, this.radius);
}

/// Standalone cellular-automaton simulation engine.
///
/// Operates on a flat grid of byte-sized element types with typed arrays for
/// per-cell state (life, velocity, flags).  Designed to run headless -- no
/// Flutter or rendering dependency.
///
/// Key optimizations:
/// - **Dirty chunk system**: 16x16 chunks skip processing when unchanged.
/// - **Clock-bit double-simulation prevention**: a toggling bit in [flags]
///   prevents an element from being processed twice in one tick.
/// - **Stable-cell settling**: cells that haven't moved for 3 frames are
///   skipped until a neighbor changes.
class SimulationEngine {
  // -- Grid dimensions -------------------------------------------------------

  /// Horizontal cell count.
  int gridW;

  /// Vertical cell count.
  int gridH;

  // -- Grid data (typed arrays for cache-friendly access) --------------------

  /// Element type per cell (byte value from [El]).
  late Uint8List grid;

  /// Per-cell lifetime / state counter.
  late Uint8List life;

  /// Per-cell flags: bit 7 = clock, bits 4-6 = stable counter, bits 0-3 = misc.
  late Uint8List flags;

  /// Per-cell horizontal velocity (ants, water momentum, plant data).
  late Int8List velX;

  /// Per-cell vertical velocity.
  late Int8List velY;

  // -- Dirty chunk system (16x16 chunks) ------------------------------------

  int chunkCols = 0;
  int chunkRows = 0;
  late Uint8List dirtyChunks;
  late Uint8List nextDirtyChunks;

  // -- Clock bit for double-simulation prevention ---------------------------

  bool simClock = false;

  // -- Temperature / heat grid -----------------------------------------------

  /// Per-cell temperature (0-255). 128 = neutral, >128 = hot, <128 = cold.
  late Uint8List temperature;

  // -- Pressure grid (for liquid physics) ------------------------------------

  /// Per-cell pressure (0-255). Computed from liquid column height above.
  late Uint8List pressure;

  // -- Pheromone grids (dual pheromone system for ant AI) --------------------

  late Uint8List pheroFood;
  late Uint8List pheroHome;

  // -- Chemistry fields (unified physics model) ------------------------------

  /// Electrical charge per cell (-128 to +127). 0 = neutral.
  late Int8List charge;

  /// Oxidation state per cell (0-255, centered at 128). >128 = oxidized.
  late Uint8List oxidation;

  /// Water content per cell (0-255). Enables dissolution, conductivity, etc.
  late Uint8List moisture;

  /// Structural support (0-255). Propagates from anchors. 0 = falling/broken.
  late Uint8List support;

  // -- Electricity fields ----------------------------------------------------

  /// Electrical potential per cell (-128 to +127). Current flows high→low.
  late Int8List voltage;

  /// Frames since last spark (Wireworld-inspired refractory period).
  late Uint8List sparkTimer;

  // -- Light emission fields (CPU-side, feeds GPU Radiance Cascades) ---------

  /// Red light intensity per cell (0-255).
  late Uint8List lightR;

  /// Green light intensity per cell (0-255).
  late Uint8List lightG;

  /// Blue light intensity per cell (0-255).
  late Uint8List lightB;

  // -- Advanced physics fields -----------------------------------------------

  /// Acidity per cell (0-255 mapped to pH 0.0-14.0). 128 = neutral (pH 7).
  late Uint8List pH;

  /// Element type dissolved in this liquid cell (0 = nothing dissolved).
  late Uint8List dissolvedType;

  /// Concentration of dissolved substance (0-255). 0 = pure, 255 = saturated.
  late Uint8List concentration;

  /// Per-cell wind X velocity (-128 to +127).
  late Int8List windX2;

  /// Per-cell wind Y velocity (-128 to +127).
  late Int8List windY2;

  /// Structural stress per cell (0-255). Accumulates from weight above.
  late Uint8List stress;

  /// Mechanical vibration intensity (0-255). Propagates through solids, decays.
  late Uint8List vibration;

  /// Vibration frequency band (0-255). Low = rumble, high = crackle/tinkle.
  /// Sound synthesis reads (vibration, frequency) to generate audio.
  late Uint8List vibrationFreq;

  /// Per-cell mass (0-255). Affects gravity acceleration, momentum, impact.
  /// Derived from element density but modified by dissolved substances,
  /// moisture content, etc. Heavier cells fall faster, hit harder.
  late Uint8List mass;

  /// Light level received by this cell (0-255). Read back from GPU
  /// Radiance Cascades every N frames. Drives photosynthesis, creature
  /// vision, fungus avoidance. 0 = total darkness, 255 = full sunlight.
  late Uint8List luminance;

  /// Accumulated downward momentum (0-255). mass × velocity over time.
  /// Determines impact force on landing: vibration, structural damage,
  /// crater depth. Resets to 0 when cell stops moving.
  late Uint8List momentum;

  /// Ticks since this cell last changed element type (0-255, saturates).
  /// Enables: patina, weathering, soil compaction, fossilization.
  /// Incremented each frame if cell is unchanged, reset on change.
  late Uint8List cellAge;

  // -- Colony tracking -------------------------------------------------------

  int colonyX = -1;
  int colonyY = -1;

  // -- Random instance -------------------------------------------------------

  late final FastRng rng;

  // -- Frame counter ---------------------------------------------------------

  int frameCount = 0;

  /// If true, the simulation uses vertical grid slicing to parallelize processing.
  bool parallelUpdate = true;

  /// Number of vertical slices to divide the grid into for parallel processing.
  int numSlices = 4;

  /// The size of each vertical slice in pixels.
  int sliceWidth = 0;

  // -- Physics manipulation --------------------------------------------------

  /// Gravity direction: 1 = down, -1 = up.
  int gravityDir = 1;

  /// Wind force: -3..+3.
  int windForce = 0;

  // -- Explosion queue -------------------------------------------------------

  final List<Explosion> pendingExplosions = [];

  /// Recent explosions consumed by the renderer for particle effects.
  final List<Explosion> recentExplosions = [];

  // -- Reaction flash queue --------------------------------------------------
  // Each entry: [x, y, r, g, b, count]
  final List<Int32List> reactionFlashes = [];

  // -- Rainbow color cycling -------------------------------------------------

  int rainbowHue = 0;

  // -- Lightning flash -------------------------------------------------------

  int lightningFlashFrames = 0;

  // -- Day / Night -----------------------------------------------------------

  bool isNight = false;

  // -- Creature callback (for NEAT ant AI integration) ----------------------

  /// Optional callback for element behaviors to query creature AI decisions.
  /// Signature: (int x, int y) -> map of neural outputs, or null if no colony.
  /// Used by simAnt() to get neural-driven decisions from the NEAT system.
  Map<String, double> Function(int x, int y)? creatureCallback;

  /// Plant colony registry for neural plant growth decisions.
  /// Set by the game layer; behaviors query this for colony-driven growth.
  PlantColonyRegistry? plantColonies;

  // =========================================================================
  // Construction / initialization
  // =========================================================================

  /// Create an engine with the given grid dimensions.
  ///
  /// Pass landscape-oriented values (e.g. 320x180) for widescreen layouts.
  SimulationEngine({this.gridW = 320, this.gridH = 180, int? seed}) {
    rng = FastRng(seed ?? DateTime.now().millisecondsSinceEpoch);
    _allocate();
  }

  void _allocate() {
    final totalCells = gridW * gridH;
    grid = Uint8List(totalCells);
    life = Uint8List(totalCells);
    flags = Uint8List(totalCells);
    velX = Int8List(totalCells);
    velY = Int8List(totalCells);

    temperature = Uint8List(totalCells);
    temperature.fillRange(0, totalCells, 128); // neutral

    pressure = Uint8List(totalCells);

    chunkCols = (gridW + 15) ~/ 16;
    chunkRows = (gridH + 15) ~/ 16;
    final totalChunks = chunkCols * chunkRows;
    dirtyChunks = Uint8List(totalChunks);
    nextDirtyChunks = Uint8List(totalChunks);
    dirtyChunks.fillRange(0, totalChunks, 1);

    pheroFood = Uint8List(totalCells);
    pheroHome = Uint8List(totalCells);

    // Chemistry fields
    charge = Int8List(totalCells);
    oxidation = Uint8List(totalCells);
    oxidation.fillRange(0, totalCells, 128); // neutral oxidation state
    moisture = Uint8List(totalCells);
    support = Uint8List(totalCells);

    // Electricity fields
    voltage = Int8List(totalCells);
    sparkTimer = Uint8List(totalCells);

    // Light emission fields
    lightR = Uint8List(totalCells);
    lightG = Uint8List(totalCells);
    lightB = Uint8List(totalCells);

    // Advanced physics fields
    pH = Uint8List(totalCells);
    pH.fillRange(0, totalCells, 128); // neutral pH 7
    dissolvedType = Uint8List(totalCells);
    concentration = Uint8List(totalCells);
    windX2 = Int8List(totalCells);
    windY2 = Int8List(totalCells);
    stress = Uint8List(totalCells);
    vibration = Uint8List(totalCells);
    vibrationFreq = Uint8List(totalCells);
    mass = Uint8List(totalCells);
    luminance = Uint8List(totalCells);
    momentum = Uint8List(totalCells);
    cellAge = Uint8List(totalCells);

    colonyX = -1;
    colonyY = -1;
  }

  /// Re-initialize the grid with new dimensions.
  void init(int w, int h) {
    gridW = w;
    gridH = h;
    _allocate();
  }

  /// Clear the entire grid and reset all state.
  void clear() {
    grid.fillRange(0, grid.length, El.empty);
    life.fillRange(0, life.length, 0);
    flags.fillRange(0, flags.length, 0);
    velX.fillRange(0, velX.length, 0);
    velY.fillRange(0, velY.length, 0);
    temperature.fillRange(0, temperature.length, 128);
    pressure.fillRange(0, pressure.length, 0);
    pheroFood.fillRange(0, pheroFood.length, 0);
    pheroHome.fillRange(0, pheroHome.length, 0);
    charge.fillRange(0, charge.length, 0);
    oxidation.fillRange(0, oxidation.length, 128);
    moisture.fillRange(0, moisture.length, 0);
    support.fillRange(0, support.length, 0);
    voltage.fillRange(0, voltage.length, 0);
    sparkTimer.fillRange(0, sparkTimer.length, 0);
    lightR.fillRange(0, lightR.length, 0);
    lightG.fillRange(0, lightG.length, 0);
    lightB.fillRange(0, lightB.length, 0);
    pH.fillRange(0, pH.length, 128);
    dissolvedType.fillRange(0, dissolvedType.length, 0);
    concentration.fillRange(0, concentration.length, 0);
    windX2.fillRange(0, windX2.length, 0);
    windY2.fillRange(0, windY2.length, 0);
    stress.fillRange(0, stress.length, 0);
    vibration.fillRange(0, vibration.length, 0);
    vibrationFreq.fillRange(0, vibrationFreq.length, 0);
    mass.fillRange(0, mass.length, 0);
    luminance.fillRange(0, luminance.length, 0);
    momentum.fillRange(0, momentum.length, 0);
    cellAge.fillRange(0, cellAge.length, 0);
    colonyX = -1;
    colonyY = -1;
    markAllDirty();
  }

  // =========================================================================
  // Serialization (save / load)
  // =========================================================================

  /// Capture a full snapshot of the simulation state.
  Map<String, dynamic> captureSnapshot() {
    return {
      'gridW': gridW,
      'gridH': gridH,
      'grid': Uint8List.fromList(grid),
      'life': Uint8List.fromList(life),
      'velX': Int8List.fromList(velX),
      'velY': Int8List.fromList(velY),
      'flags': Uint8List.fromList(flags),
      'temperature': Uint8List.fromList(temperature),
      'pressure': Uint8List.fromList(pressure),
      'pheroFood': Uint8List.fromList(pheroFood),
      'pheroHome': Uint8List.fromList(pheroHome),
      'charge': Int8List.fromList(charge),
      'oxidation': Uint8List.fromList(oxidation),
      'moisture': Uint8List.fromList(moisture),
      'support': Uint8List.fromList(support),
      'voltage': Int8List.fromList(voltage),
      'sparkTimer': Uint8List.fromList(sparkTimer),
      'lightR': Uint8List.fromList(lightR),
      'lightG': Uint8List.fromList(lightG),
      'lightB': Uint8List.fromList(lightB),
      'pH': Uint8List.fromList(pH),
      'dissolvedType': Uint8List.fromList(dissolvedType),
      'concentration': Uint8List.fromList(concentration),
      'windX2': Int8List.fromList(windX2),
      'windY2': Int8List.fromList(windY2),
      'stress': Uint8List.fromList(stress),
      'vibration': Uint8List.fromList(vibration),
      'vibrationFreq': Uint8List.fromList(vibrationFreq),
      'mass': Uint8List.fromList(mass),
      'luminance': Uint8List.fromList(luminance),
      'momentum': Uint8List.fromList(momentum),
      'cellAge': Uint8List.fromList(cellAge),
      'frameCount': frameCount,
      'gravityDir': gravityDir,
      'windForce': windForce,
      'isNight': isNight,
    };
  }

  /// Restore from a snapshot.
  void restoreSnapshot(Map<String, dynamic> snapshot) {
    final sw = snapshot['gridW'] as int?;
    final sh = snapshot['gridH'] as int?;
    if (sw != null && sh != null && (sw != gridW || sh != gridH)) {
      init(sw, sh);
    }
    grid.setAll(0, snapshot['grid'] as Uint8List);
    life.setAll(0, snapshot['life'] as Uint8List);
    _restoreTyped<Int8List>(velX, snapshot['velX'], 0);
    _restoreTyped<Int8List>(velY, snapshot['velY'], 0);
    _restoreTyped<Uint8List>(flags, snapshot['flags'], 0);
    _restoreTyped<Uint8List>(temperature, snapshot['temperature'], 128);
    _restoreTyped<Uint8List>(pressure, snapshot['pressure'], 0);
    _restoreTyped<Uint8List>(pheroFood, snapshot['pheroFood'], 0);
    _restoreTyped<Uint8List>(pheroHome, snapshot['pheroHome'], 0);
    _restoreTyped<Int8List>(charge, snapshot['charge'], 0);
    _restoreTyped<Uint8List>(oxidation, snapshot['oxidation'], 128);
    _restoreTyped<Uint8List>(moisture, snapshot['moisture'], 0);
    _restoreTyped<Uint8List>(support, snapshot['support'], 0);
    _restoreTyped<Int8List>(voltage, snapshot['voltage'], 0);
    _restoreTyped<Uint8List>(sparkTimer, snapshot['sparkTimer'], 0);
    _restoreTyped<Uint8List>(lightR, snapshot['lightR'], 0);
    _restoreTyped<Uint8List>(lightG, snapshot['lightG'], 0);
    _restoreTyped<Uint8List>(lightB, snapshot['lightB'], 0);
    _restoreTyped<Uint8List>(pH, snapshot['pH'], 128);
    _restoreTyped<Uint8List>(dissolvedType, snapshot['dissolvedType'], 0);
    _restoreTyped<Uint8List>(concentration, snapshot['concentration'], 0);
    _restoreTyped<Int8List>(windX2, snapshot['windX2'], 0);
    _restoreTyped<Int8List>(windY2, snapshot['windY2'], 0);
    _restoreTyped<Uint8List>(stress, snapshot['stress'], 0);
    _restoreTyped<Uint8List>(vibration, snapshot['vibration'], 0);
    _restoreTyped<Uint8List>(vibrationFreq, snapshot['vibrationFreq'], 0);
    _restoreTyped<Uint8List>(mass, snapshot['mass'], 0);
    _restoreTyped<Uint8List>(luminance, snapshot['luminance'], 0);
    _restoreTyped<Uint8List>(momentum, snapshot['momentum'], 0);
    _restoreTyped<Uint8List>(cellAge, snapshot['cellAge'], 0);
    frameCount = (snapshot['frameCount'] as int?) ?? 0;
    gravityDir = (snapshot['gravityDir'] as int?) ?? 1;
    windForce = (snapshot['windForce'] as int?) ?? 0;
    isNight = (snapshot['isNight'] as bool?) ?? false;
    colonyX = -1;
    colonyY = -1;
    markAllDirty();
  }

  /// Restore a typed list field from snapshot data, falling back to [fallback].
  static void _restoreTyped<T extends List<int>>(T target, dynamic saved, int fallback) {
    if (saved != null && saved is T) {
      target.setAll(0, saved);
    } else {
      target.fillRange(0, target.length, fallback);
    }
  }

  // =========================================================================
  // Reaction flash queue
  // =========================================================================

  /// Queue a reaction flash for the renderer to spawn particles.
  @pragma('vm:prefer-inline')
  void queueReactionFlash(int x, int y, int r, int g, int b, int count) {
    if (reactionFlashes.length < 20) {
      final f = Int32List(6);
      f[0] = x; f[1] = y; f[2] = r; f[3] = g; f[4] = b; f[5] = count;
      reactionFlashes.add(f);
    }
  }

  // =========================================================================
  // Core helpers
  // =========================================================================

  /// Swap two cells by flat index, updating clock bits and dirty chunks.
  @pragma('vm:prefer-inline')
  void swap(int a, int b) {
    final tmpEl = grid[a];
    final tmpLife = life[a];
    final tmpVx = velX[a];
    final tmpVy = velY[a];
    final tmpTemp = temperature[a];
    final tmpCharge = charge[a];
    final tmpOx = oxidation[a];
    final tmpMoist = moisture[a];
    final tmpVolt = voltage[a];
    final tmpPH = pH[a];
    final tmpDissolved = dissolvedType[a];
    final tmpConc = concentration[a];
    final tmpMass = mass[a];
    final tmpMomentum = momentum[a];
    final tmpCellAge = cellAge[a];

    grid[a] = grid[b];
    life[a] = life[b];
    velX[a] = velX[b];
    velY[a] = velY[b];
    temperature[a] = temperature[b];
    charge[a] = charge[b];
    oxidation[a] = oxidation[b];
    moisture[a] = moisture[b];
    voltage[a] = voltage[b];
    pH[a] = pH[b];
    dissolvedType[a] = dissolvedType[b];
    concentration[a] = concentration[b];
    mass[a] = mass[b];
    momentum[a] = momentum[b];
    cellAge[a] = cellAge[b];

    grid[b] = tmpEl;
    life[b] = tmpLife;
    velX[b] = tmpVx;
    velY[b] = tmpVy;
    temperature[b] = tmpTemp;
    charge[b] = tmpCharge;
    oxidation[b] = tmpOx;
    moisture[b] = tmpMoist;
    voltage[b] = tmpVolt;
    pH[b] = tmpPH;
    dissolvedType[b] = tmpDissolved;
    concentration[b] = tmpConc;
    mass[b] = tmpMass;
    momentum[b] = tmpMomentum;
    cellAge[b] = tmpCellAge;

    final clockBit = simClock ? 0x80 : 0;
    flags[a] = clockBit;
    flags[b] = clockBit;

    final w = gridW;
    markDirty(a % w, a ~/ w);
    markDirty(b % w, b ~/ w);
  }

  /// Wrap an x coordinate for horizontal cylinder topology.
  @pragma('vm:prefer-inline')
  int wrapX(int x) {
    final r = x % gridW;
    return r < 0 ? r + gridW : r;
  }

  @pragma('vm:prefer-inline')
  bool inBounds(int x, int y) =>
      x >= 0 && x < gridW && y >= 0 && y < gridH;

  /// Vertical-only bounds check (x always wraps, so only y matters).
  @pragma('vm:prefer-inline')
  bool inBoundsY(int y) => y >= 0 && y < gridH;

  /// Mark the 16x16 chunk containing (x,y) as dirty for the next frame.
  /// Also marks adjacent chunks if the cell is on a chunk boundary.
  /// x is expected to be already wrapped (0..gridW-1).
  @pragma('vm:prefer-inline')
  void markDirty(int x, int y) {
    final cx = x >> 4;
    final cy = y >> 4;
    final cols = chunkCols;
    final nd = nextDirtyChunks;
    nd[cy * cols + cx] = 1;
    final lx = x & 15;
    final ly = y & 15;
    // Horizontal wrapping for chunk boundaries
    if (lx == 0) nd[cy * cols + ((cx - 1 + cols) % cols)] = 1;
    if (lx == 15) nd[cy * cols + ((cx + 1) % cols)] = 1;
    final rows = chunkRows;
    if (ly == 0 && cy > 0) nd[(cy - 1) * cols + cx] = 1;
    if (ly == 15 && cy < rows - 1) nd[(cy + 1) * cols + cx] = 1;
    if (lx == 0 && ly == 0 && cy > 0) nd[(cy - 1) * cols + ((cx - 1 + cols) % cols)] = 1;
    if (lx == 15 && ly == 0 && cy > 0) nd[(cy - 1) * cols + ((cx + 1) % cols)] = 1;
    if (lx == 0 && ly == 15 && cy < rows - 1) nd[(cy + 1) * cols + ((cx - 1 + cols) % cols)] = 1;
    if (lx == 15 && ly == 15 && cy < rows - 1) nd[(cy + 1) * cols + ((cx + 1) % cols)] = 1;
  }

  /// Mark all chunks dirty (used on reset, clear, undo, etc.)
  void markAllDirty() {
    dirtyChunks.fillRange(0, dirtyChunks.length, 1);
    nextDirtyChunks.fillRange(0, nextDirtyChunks.length, 1);
  }

  /// Mark a cell as processed this frame.
  @pragma('vm:prefer-inline')
  void markProcessed(int idx) {
    flags[idx] = simClock ? 0x80 : 0;
    final w = gridW;
    markDirty(idx % w, idx ~/ w);
  }

  /// Clear settled flag on all 8 neighbors (wraps horizontally).
  @pragma('vm:prefer-inline')
  void unsettleNeighbors(int x, int y) {
    final w = gridW;
    final maxY = gridH - 1;
    final xl = (x - 1 + w) % w;
    final xr = (x + 1) % w;
    // Unsettle immediate 8 neighbors
    if (y > 0) {
      final rowAbove = (y - 1) * w;
      flags[rowAbove + xl] &= 0x80;
      flags[rowAbove + x] &= 0x80;
      flags[rowAbove + xr] &= 0x80;
    }
    flags[y * w + xl] &= 0x80;
    flags[y * w + xr] &= 0x80;
    if (y < maxY) {
      final rowBelow = (y + 1) * w;
      flags[rowBelow + xl] &= 0x80;
      flags[rowBelow + x] &= 0x80;
      flags[rowBelow + xr] &= 0x80;
    }
    // CASCADE UPWARD: when support is removed, everything above must
    // re-evaluate gravity. Scan the column upward and unsettle non-empty
    // cells until we hit the surface or an already-unsettled cell.
    // This is what makes terrain collapse when you dig under it.
    final upDir = gravityDir == 1 ? -1 : 1; // opposite of gravity
    for (int scanY = y + upDir; scanY >= 0 && scanY < gridH; scanY += upDir) {
      final si = scanY * w + x;
      if (grid[si] == El.empty) break; // hit air, stop
      if ((flags[si] & 0x40) == 0) break; // already unsettled, stop
      flags[si] &= 0x80; // clear stable bits
      markDirty(x, scanY);
      // Also unsettle the cells to left/right of this column cell
      final sxl = wrapX(x - 1);
      final sxr = wrapX(x + 1);
      flags[scanY * w + sxl] &= 0x80;
      flags[scanY * w + sxr] &= 0x80;
      markDirty(sxl, scanY);
      markDirty(sxr, scanY);
    }
  }

  /// Reset ALL per-cell fields at [idx] to empty/neutral defaults.
  /// Use this whenever removing an element to avoid stale physics state.
  @pragma('vm:prefer-inline')
  void clearCell(int idx) {
    grid[idx] = El.empty;
    life[idx] = 0;
    velX[idx] = 0;
    velY[idx] = 0;
    temperature[idx] = 128;
    charge[idx] = 0;
    oxidation[idx] = 128;
    moisture[idx] = 0;
    voltage[idx] = 0;
    sparkTimer[idx] = 0;
    pH[idx] = 128;
    dissolvedType[idx] = 0;
    concentration[idx] = 0;
    mass[idx] = 0;
    momentum[idx] = 0;
    stress[idx] = 0;
    vibration[idx] = 0;
    vibrationFreq[idx] = 0;
    cellAge[idx] = 0;
    // Light, wind, luminance are computed fields — cleared during their update passes
    final cx = idx % gridW;
    final cy = idx ~/ gridW;
    markDirty(cx, cy);
  }

  /// Check if any of the 8 neighbors matches [elType]. Wraps horizontally.
  @pragma('vm:prefer-inline')
  bool checkAdjacent(int x, int y, int elType) {
    final w = gridW;
    final g = grid;
    final maxY = gridH - 1;
    final xl = (x - 1 + w) % w;
    final xr = (x + 1) % w;
    if (y > 0) {
      final rowAbove = (y - 1) * w;
      if (g[rowAbove + xl] == elType) return true;
      if (g[rowAbove + x] == elType) return true;
      if (g[rowAbove + xr] == elType) return true;
    }
    if (g[y * w + xl] == elType) return true;
    if (g[y * w + xr] == elType) return true;
    if (y < maxY) {
      final rowBelow = (y + 1) * w;
      if (g[rowBelow + xl] == elType) return true;
      if (g[rowBelow + x] == elType) return true;
      if (g[rowBelow + xr] == elType) return true;
    }
    return false;
  }

  /// Check if any of the 8 neighbors matches [a] or [b]. Wraps horizontally.
  /// Reads neighbors once instead of calling checkAdjacent twice.
  @pragma('vm:prefer-inline')
  bool checkAdjacentAny2(int x, int y, int a, int b) {
    final w = gridW;
    final g = grid;
    final maxY = gridH - 1;
    final xl = (x - 1 + w) % w;
    final xr = (x + 1) % w;
    if (y > 0) {
      final ra = (y - 1) * w;
      int n = g[ra + xl]; if (n == a || n == b) return true;
      n = g[ra + x]; if (n == a || n == b) return true;
      n = g[ra + xr]; if (n == a || n == b) return true;
    }
    int n = g[y * w + xl]; if (n == a || n == b) return true;
    n = g[y * w + xr]; if (n == a || n == b) return true;
    if (y < maxY) {
      final rb = (y + 1) * w;
      n = g[rb + xl]; if (n == a || n == b) return true;
      n = g[rb + x]; if (n == a || n == b) return true;
      n = g[rb + xr]; if (n == a || n == b) return true;
    }
    return false;
  }

  /// Check if any of the 8 neighbors matches [a], [b], or [c]. Wraps horizontally.
  @pragma('vm:prefer-inline')
  bool checkAdjacentAny3(int x, int y, int a, int b, int c) {
    final w = gridW;
    final g = grid;
    final maxY = gridH - 1;
    final xl = (x - 1 + w) % w;
    final xr = (x + 1) % w;
    if (y > 0) {
      final ra = (y - 1) * w;
      int n = g[ra + xl]; if (n == a || n == b || n == c) return true;
      n = g[ra + x]; if (n == a || n == b || n == c) return true;
      n = g[ra + xr]; if (n == a || n == b || n == c) return true;
    }
    int n = g[y * w + xl]; if (n == a || n == b || n == c) return true;
    n = g[y * w + xr]; if (n == a || n == b || n == c) return true;
    if (y < maxY) {
      final rb = (y + 1) * w;
      n = g[rb + xl]; if (n == a || n == b || n == c) return true;
      n = g[rb + x]; if (n == a || n == b || n == c) return true;
      n = g[rb + xr]; if (n == a || n == b || n == c) return true;
    }
    return false;
  }

  /// Read all 8 neighbor element types into [out] (length >= 8).
  /// Order: NW, N, NE, W, E, SW, S, SE. Out-of-bounds Y => El.empty.
  /// Wraps horizontally. Reads the grid once; callers test the buffer.
  @pragma('vm:prefer-inline')
  void readNeighbors(int x, int y, Uint8List out) {
    final w = gridW;
    final g = grid;
    final xl = (x - 1 + w) % w;
    final xr = (x + 1) % w;
    if (y > 0) {
      final ra = (y - 1) * w;
      out[0] = g[ra + xl];
      out[1] = g[ra + x];
      out[2] = g[ra + xr];
    } else {
      out[0] = El.empty;
      out[1] = El.empty;
      out[2] = El.empty;
    }
    final row = y * w;
    out[3] = g[row + xl];
    out[4] = g[row + xr];
    if (y < gridH - 1) {
      final rb = (y + 1) * w;
      out[5] = g[rb + xl];
      out[6] = g[rb + x];
      out[7] = g[rb + xr];
    } else {
      out[5] = El.empty;
      out[6] = El.empty;
      out[7] = El.empty;
    }
  }

  /// Scratch buffer for [readNeighbors]. Allocated once, reused every call.
  final Uint8List _neighborBuf = Uint8List(8);

  /// Check if any neighbor matches any element type in the given set.
  /// [types] is a lookup table sized to [maxElements]; nonzero = match.
  /// Reads neighbors once and checks all 8 against the table.
  @pragma('vm:prefer-inline')
  bool checkAdjacentAnyOf(int x, int y, Uint8List types) {
    readNeighbors(x, y, _neighborBuf);
    for (int i = 0; i < 8; i++) {
      final n = _neighborBuf[i];
      if (n < types.length && types[n] != 0) return true;
    }
    return false;
  }

  /// Remove one adjacent cell of the given type. Wraps horizontally.
  /// Fully resets all per-cell physics state via [clearCell].
  @pragma('vm:prefer-inline')
  void removeOneAdjacent(int x, int y, int elType) {
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = wrapX(x + dx);
        final ny = y + dy;
        if (inBoundsY(ny)) {
          final ni = ny * gridW + nx;
          if (grid[ni] == elType) {
            clearCell(ni);
            markProcessed(ni);
            return;
          }
        }
      }
    }
  }

  /// Check if any of the 8 neighbors matches a [categoryMask] bitmask.
  /// Wraps horizontally. Use for chemistry: "any oxidizer nearby?"
  @pragma('vm:prefer-inline')
  bool checkAdjacentCategory(int x, int y, int categoryMask) {
    final w = gridW;
    final g = grid;
    final cat = elCategory;
    final maxY = gridH - 1;
    final xl = (x - 1 + w) % w;
    final xr = (x + 1) % w;
    if (y > 0) {
      final rowAbove = (y - 1) * w;
      final e1 = g[rowAbove + xl]; if (e1 < maxElements && (cat[e1] & categoryMask) != 0) return true;
      final e2 = g[rowAbove + x];  if (e2 < maxElements && (cat[e2] & categoryMask) != 0) return true;
      final e3 = g[rowAbove + xr]; if (e3 < maxElements && (cat[e3] & categoryMask) != 0) return true;
    }
    final e4 = g[y * w + xl]; if (e4 < maxElements && (cat[e4] & categoryMask) != 0) return true;
    final e5 = g[y * w + xr]; if (e5 < maxElements && (cat[e5] & categoryMask) != 0) return true;
    if (y < maxY) {
      final rowBelow = (y + 1) * w;
      final e6 = g[rowBelow + xl]; if (e6 < maxElements && (cat[e6] & categoryMask) != 0) return true;
      final e7 = g[rowBelow + x];  if (e7 < maxElements && (cat[e7] & categoryMask) != 0) return true;
      final e8 = g[rowBelow + xr]; if (e8 < maxElements && (cat[e8] & categoryMask) != 0) return true;
    }
    return false;
  }

  /// Get the grid index of the first adjacent cell matching [elType], or -1.
  /// Wraps horizontally. Useful for targeted operations on a specific neighbor.
  @pragma('vm:prefer-inline')
  int findAdjacentIndex(int x, int y, int elType) {
    final w = gridW;
    final g = grid;
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = wrapX(x + dx);
        final ny = y + dy;
        if (inBoundsY(ny)) {
          final ni = ny * w + nx;
          if (g[ni] == elType) return ni;
        }
      }
    }
    return -1;
  }

  /// Count how many of the 8 immediate neighbors are of [elType].
  /// Faster than countNearby for radius=1 since it's hand-unrolled.
  @pragma('vm:prefer-inline')
  int countAdjacent(int x, int y, int elType) {
    int count = 0;
    final w = gridW;
    final g = grid;
    final maxY = gridH - 1;
    final xl = (x - 1 + w) % w;
    final xr = (x + 1) % w;
    if (y > 0) {
      final rowAbove = (y - 1) * w;
      if (g[rowAbove + xl] == elType) count++;
      if (g[rowAbove + x] == elType) count++;
      if (g[rowAbove + xr] == elType) count++;
    }
    if (g[y * w + xl] == elType) count++;
    if (g[y * w + xr] == elType) count++;
    if (y < maxY) {
      final rowBelow = (y + 1) * w;
      if (g[rowBelow + xl] == elType) count++;
      if (g[rowBelow + x] == elType) count++;
      if (g[rowBelow + xr] == elType) count++;
    }
    return count;
  }

  // =========================================================================
  // Explosion processing
  // =========================================================================

  void processExplosions() {
    if (pendingExplosions.isEmpty) return;
    recentExplosions.clear();

    final debris = <int>[];

    for (final exp in pendingExplosions) {
      recentExplosions.add(exp);
      final r = exp.radius;
      for (int dy = -r; dy <= r; dy++) {
        for (int dx = -r; dx <= r; dx++) {
          final dist2 = dx * dx + dy * dy;
          if (dist2 > r * r) continue;
          final nx = wrapX(exp.x + dx);
          final ny = exp.y + dy;
          if (!inBoundsY(ny)) continue;
          final ni = ny * gridW + nx;
          final el = grid[ni];
          // Hardness-based explosion resistance: only destroy cells where hardness < explosionForce
          final cellHardness = el < maxElements ? elementHardness[el] : 0;
          // Integer explosion force: (1 - dist2/r2) * 255 = (r2 - dist2) * 255 / r2
          final r2 = r * r;
          final explosionForce = ((r2 - dist2) * 255) ~/ r2;
          if (cellHardness >= explosionForce) continue;

          if (el != El.empty && el != El.tnt && dist2 > (r2 * 77) >> 8) { // ~0.3 * r²
            final flingDist = r + 2 + rng.nextInt(r);
            final normDx = dx == 0 ? 0 : (dx > 0 ? 1 : -1);
            final normDy = dy == 0 ? 0 : (dy > 0 ? 1 : -1);
            final targetX = nx + normDx * (flingDist ~/ 2 + rng.nextInt(3));
            final targetY = ny + normDy * (flingDist ~/ 2 + rng.nextInt(3));
            final debrisEl = (el == El.oil || el == El.plant || el == El.seed || el == El.wood)
                ? El.fire
                : (el == El.sand || el == El.dirt || el == El.snow) ? el : El.ash;
            if (debris.length < 60) {
              debris.addAll([debrisEl, targetX, targetY]);
            }
          }

          grid[ni] = El.empty;
          life[ni] = 0;
          markDirty(nx, ny);
        }
      }
      for (int i = 0; i < r * 4; i++) {
        // Integer trig: random angle as phase256 [0..255], distance as fixed-point
        final phase256 = rng.nextInt(256);
        final dist = (r * 154 + rng.nextInt(r * 128)) >> 8; // ~0.6*r + rand*0.5*r
        // sin/cos via lookup: _sinI256 returns [-128, 128]
        final sinV = _sinI256(phase256);
        final cosV = _sinI256(phase256 + 64);
        final fx = wrapX(exp.x + (dist * cosV) ~/ 128);
        final fy = exp.y + (dist * sinV) ~/ 128;
        if (inBoundsY(fy)) {
          final fi = fy * gridW + fx;
          if (grid[fi] == El.empty) {
            grid[fi] = El.fire;
            life[fi] = 0;
            markDirty(fx, fy);
          }
        }
      }
    }

    for (int i = 0; i < debris.length; i += 3) {
      final el = debris[i];
      final tx = wrapX(debris[i + 1]);
      final ty = debris[i + 2];
      if (inBoundsY(ty)) {
        final ti = ty * gridW + tx;
        if (grid[ti] == El.empty) {
          grid[ti] = el;
          life[ti] = 0;
          markDirty(tx, ty);
        }
      }
    }

    pendingExplosions.clear();
  }

  // =========================================================================
  // Granular / liquid fall helpers
  // =========================================================================

  /// Standard granular fall (sand, TNT). Wraps horizontally.
  void fallGranular(int x, int y, int idx, int elType) {
    final g = gravityDir;
    final maxVel = elementMaxVelocity[elType];

    // Persistent jamming: if this grain is jammed (velX == 127),
    // check if the jam conditions still hold. If not, unjam.
    // Jammed grains don't fall — they form a stable arch.
    if (velX[idx] == 127) {
      final by2 = y + g;
      if (!inBoundsY(by2)) return;
      // Arch requires: empty below, solid walls on both sides of
      // the opening, and lateral pressure from neighbors
      final belowEl2 = grid[by2 * gridW + x];
      final leftEl2 = grid[y * gridW + wrapX(x - 1)];
      final rightEl2 = grid[y * gridW + wrapX(x + 1)];
      final leftBelowEl2 = grid[by2 * gridW + wrapX(x - 1)];
      final rightBelowEl2 = grid[by2 * gridW + wrapX(x + 1)];
      // Arch holds if: below is still empty or same-type,
      // walls still exist, and neighbors still press
      final wallsIntact = (elementPhysicsState[leftBelowEl2] == 0 && leftBelowEl2 != El.empty) &&
                          (elementPhysicsState[rightBelowEl2] == 0 && rightBelowEl2 != El.empty);
      final hasLateralPressure = leftEl2 != El.empty && rightEl2 != El.empty;
      if (belowEl2 == El.empty && wallsIntact && hasLateralPressure) {
        // Arch still holds — small chance of spontaneous collapse
        // (thermal vibration / random perturbation)
        if (rng.nextInt(200) > 0) return; // 0.5% chance per frame to break
      }
      // Arch broken — unjam
      velX[idx] = 0;
    }

    final by = y + g;
    if (inBoundsY(by)) {
      final below = by * gridW + x;
      final belowEl = grid[below];
      if (belowEl == El.empty) {
        // Orifice jamming: when falling straight into a narrow opening
        // (both sides are solid walls), lateral grain pressure creates
        // a force chain that bridges the gap (Beverloo dead zone).
        if (velY[idx] <= 1) {
          final leftBelowEl = grid[by * gridW + wrapX(x - 1)];
          final rightBelowEl = grid[by * gridW + wrapX(x + 1)];
          if (elementPhysicsState[leftBelowEl] == 0 && leftBelowEl != El.empty &&
              elementPhysicsState[rightBelowEl] == 0 && rightBelowEl != El.empty) {
            final leftEl = grid[y * gridW + wrapX(x - 1)];
            final rightEl = grid[y * gridW + wrapX(x + 1)];
            if (leftEl != El.empty && rightEl != El.empty) {
              // Grains pressing from both sides — form persistent arch
              if (rng.nextInt(2) == 0) {
                velX[idx] = 127; // Mark as jammed
                velY[idx] = 0;
                return;
              }
            }
          }
        }

        // Accelerate: increment velY
        // Stokes drag: submerged grains have reduced terminal velocity
        // v_t = 2r²(ρ_p - ρ_f)g / (9η) — in a liquid medium, cap at 1
        final curVel = velY[idx];
        final aboveEl = y > 0 ? grid[(y - g) * gridW + x] : El.empty;
        final submerged = aboveEl == El.water || aboveEl == El.oil ||
                          aboveEl == El.acid || aboveEl == El.mud;
        final effectiveMax = submerged ? 1 : maxVel;
        final newVel = (curVel + 1).clamp(0, effectiveMax);
        velY[idx] = newVel;

        // Accumulate momentum during fall: momentum += mass >> 3
        {
          final mAdd = mass[idx] >> 3;
          final curMom = momentum[idx] + mAdd;
          momentum[idx] = curMom < 255 ? curMom : 255;
        }

        // Multi-cell fall: when velY > 1, try to skip intermediate empty cells
        if (newVel > 1) {
          int finalY = by;
          for (int d = 2; d <= newVel; d++) {
            final testY = y + g * d;
            if (!inBoundsY(testY)) break;
            final testEl = grid[testY * gridW + x];
            if (testEl != El.empty) break;
            finalY = testY;
          }
          swap(idx, finalY * gridW + x);
        } else {
          swap(idx, below);
        }
        return;
      }
      if ((elType == El.sand || elType == El.dirt || elType == El.seed) && belowEl == El.water) {
        // Impact splash: sand hitting water from height
        final impactVel = velY[idx];
        if (impactVel > 2) {
          // Splash effect: spawn water droplets upward
          for (int i = 0; i < (impactVel ~/ 2).clamp(1, 3); i++) {
            final sx = wrapX(x + (rng.nextBool() ? 1 : -1) * (1 + rng.nextInt(2)));
            final sy = y - g * (1 + rng.nextInt(2));
            if (inBoundsY(sy) && grid[sy * gridW + sx] == El.empty) {
              grid[sy * gridW + sx] = El.water;
              life[sy * gridW + sx] = 80;
              markProcessed(sy * gridW + sx);
            }
          }
          queueReactionFlash(x, y, 100, 180, 255, (impactVel ~/ 2).clamp(2, 4));
        }
        // Water splash generates vibration with mid frequency
        final mom = momentum[idx];
        if (mom > 10) {
          vibration[below] = mom;
          vibrationFreq[below] = 140; // liquid splash = mid freq
        }
        velY[idx] = 0;
        momentum[idx] = 0;
        final sinkWaterMass = life[below];
        grid[idx] = El.water;
        life[idx] = sinkWaterMass < 20 ? 100 : sinkWaterMass;
        grid[below] = elType;
        markProcessed(idx);
        markProcessed(below);
        return;
      }

      // Impact on solid: reset velocity, generate vibration, flash on high impact
      {
        final mom = momentum[idx];
        if (mom > 10) {
          // Generate vibration from impact
          vibration[idx] = mom;
          // Frequency based on element hardness: hard = high, soft = low
          final h = elType < maxElements ? elementHardness[elType] : 50;
          vibrationFreq[idx] = h > 50 ? 200 + (h >> 2) : 80 + (h >> 1); // soft: 80-105, hard: 200-263 clamped
        }
        momentum[idx] = 0;
      }
      if (velY[idx] > 2) {
        queueReactionFlash(x, y, 200, 200, 180, 2);
      }
      velY[idx] = 0;

      // Granular arch formation (jamming).
      // Real physics: grains near narrow openings form arches through
      // intergranular friction. Force chains transmit stress laterally,
      // allowing grains to bridge gaps. The Beverloo equation predicts
      // flow rate Q ∝ (D - k·d)^2.5 where k ≈ 1.4 accounts for the
      // "dead zone" at the orifice edge where arches form.
      //
      // We model this by checking whether this grain is squeezed between
      // a solid surface below and grains pressing from the side. If so,
      // friction can prevent the diagonal slide, forming an arch.
      final goLeft = rng.nextBool();
      final wx1 = wrapX(goLeft ? x - 1 : x + 1);
      final wx2 = wrapX(goLeft ? x + 1 : x - 1);

      // Check arch formation: if trying to slide toward wx1 (which is
      // empty below-diag), check if grains from the opposite side (wx2)
      // are pressing against us, creating lateral friction.
      if (grid[by * gridW + wx1] == El.empty) {
        // Granular arch formation at orifice constrictions.
        // Real physics: grains converging on a narrow opening form arches
        // when lateral friction from neighboring grains and nearby walls
        // creates a force chain bridging the gap. The Beverloo equation
        // accounts for this with the k·d "dead zone" term.
        //
        // Check: (1) the cell below us is solid (we're on an orifice edge),
        // (2) grains or solids press from the opposite side,
        // (3) the below-opposite is also a wall (confirming narrow orifice).
        final belowEl = grid[by * gridW + x]; // cell directly below us
        if (elementPhysicsState[belowEl] == 0 && belowEl != El.empty) {
          // We're sitting on a solid surface (wall/floor edge)
          final oppositeEl = grid[y * gridW + wx2];
          if (oppositeEl != El.empty) {
            // Something pressing from opposite side (grain or wall)
            final belowOppEl = grid[by * gridW + wx2];
            if (elementPhysicsState[belowOppEl] == 0 && belowOppEl != El.empty) {
              // Wall on both sides below — narrow orifice
              // ~40% arch formation probability
              if (rng.nextInt(10) < 7) return;
            }
          }
        }
        swap(idx, by * gridW + wx1);
        return;
      }
      if (grid[by * gridW + wx2] == El.empty) {
        final belowEl = grid[by * gridW + x];
        if (elementPhysicsState[belowEl] == 0 && belowEl != El.empty) {
          final oppositeEl = grid[y * gridW + wx1];
          if (oppositeEl != El.empty) {
            final belowOppEl = grid[by * gridW + wx1];
            if (elementPhysicsState[belowOppEl] == 0 && belowOppEl != El.empty) {
              if (rng.nextInt(10) < 7) return;
            }
          }
        }
        swap(idx, by * gridW + wx2);
        return;
      }
    }
  }

  // =========================================================================
  // Solid fall helper (stone, glass, ice, metal)
  // =========================================================================

  /// Solid block fall — straight down and diagonal sliding.
  /// Uses velY for momentum with lower terminal velocity than granular.
  /// [sinkThroughLiquids]: if true, displaces lighter liquids via density.
  /// Returns true if the element moved.
  bool fallSolid(int x, int y, int idx, int elType, {bool sinkThroughLiquids = true}) {
    final g = gravityDir;
    final by = y + g;
    if (!inBoundsY(by)) {
      velY[idx] = 0;
      return false;
    }

    final below = by * gridW + x;
    final belowEl = grid[below];

    // Check for structural support before moving
    // Solids hold together better than granulars, so check side neighbors
    if (belowEl != El.empty) {
      final lx = wrapX(x - 1);
      final rx = wrapX(x + 1);
      final leftEl = grid[y * gridW + lx];
      final rightEl = grid[y * gridW + rx];
      
      // If sandwiched between solids, don't fall (arch support)
      if (leftEl != El.empty && rightEl != El.empty && 
          elementHardness[leftEl] > 20 && elementHardness[rightEl] > 20) {
         velY[idx] = 0;
         return false;
      }
      
      // Try diagonal slide if straight down is blocked
      final dl = by * gridW + lx;
      final dr = by * gridW + rx;
      final dlEl = grid[dl];
      final drEl = grid[dr];
      
      // Only slide if there is NO lateral support holding it in place
      if (leftEl == El.empty && dlEl == El.empty) {
        if (rng.nextInt(2) == 0) {
           swap(idx, dl);
           return true;
        }
      } else if (rightEl == El.empty && drEl == El.empty) {
        if (rng.nextInt(2) == 0) {
           swap(idx, dr);
           return true;
        }
      }
    }

    // Fall through empty space with momentum
    if (belowEl == El.empty) {
      final curVel = velY[idx];
      final newVel = (curVel + 1).clamp(0, 2); // lower terminal vel than granular
      velY[idx] = newVel;

      // Accumulate momentum during fall
      {
        final mAdd = mass[idx] >> 3;
        final curMom = momentum[idx] + mAdd;
        momentum[idx] = curMom < 255 ? curMom : 255;
      }

      // Multi-cell fall when velocity > 1
      if (newVel > 1) {
        int finalY = by;
        for (int d = 2; d <= newVel; d++) {
          final testY = y + g * d;
          if (!inBoundsY(testY)) break;
          if (grid[testY * gridW + x] != El.empty) break;
          finalY = testY;
        }
        swap(idx, finalY * gridW + x);
      } else {
        swap(idx, below);
      }
      return true;
    }

    // Density-based sinking through lighter liquids
    if (sinkThroughLiquids) {
      final myDensity = elementDensity[elType];
      final belowDensity = elementDensity[belowEl];
      final belowState = elementPhysicsState[belowEl];

      if (belowDensity < myDensity &&
          (belowState == PhysicsState.liquid.index ||
           belowState == PhysicsState.gas.index)) {
        // Check clock bit to avoid double-processing
        final clockBit = simClock ? 0x80 : 0;
        if ((flags[below] & 0x80) != clockBit) {
          swap(idx, below);
          velY[idx] = 0; // reset velocity on liquid entry
          return true;
        }
      }
    }

    // Landing: generate vibration from momentum, reset velocity
    final landingVel = velY[idx];
    if (landingVel > 0) {
      velY[idx] = 0;
      // Generate vibration from accumulated momentum
      final mom = momentum[idx];
      if (mom > 10) {
        vibration[idx] = mom;
        // Hard elements (stone, metal) = high freq (200+), soft = low (80-120)
        final h = elType < maxElements ? elementHardness[elType] : 50;
        vibrationFreq[idx] = h > 50 ? 200 + (h >> 2) : 80 + (h >> 1);
      }
      momentum[idx] = 0;
      if (landingVel > 2) {
        queueReactionFlash(x, y, 180, 180, 160, 2);
      }
    }
    return false;
  }

  /// Check if a water cell is trapped (surrounded, 0-1 water neighbors, no empty).
  @pragma('vm:prefer-inline')
  bool isTrappedWater(int wx, int wy) {
    int waterN = 0, emptyN = 0;
    for (int dy2 = -1; dy2 <= 1; dy2++) {
      for (int dx2 = -1; dx2 <= 1; dx2++) {
        if (dx2 == 0 && dy2 == 0) continue;
        final nx = wrapX(wx + dx2);
        final ny = wy + dy2;
        if (!inBoundsY(ny)) continue;
        final n = grid[ny * gridW + nx];
        if (n == El.water) waterN++;
        if (n == El.empty) emptyN++;
      }
    }
    return emptyN == 0 && waterN <= 1;
  }

  /// Push a water cell to the nearest empty cell above or beside. Wraps horizontally.
  void displaceWater(int wx, int wy) {
    final wi = wy * gridW + wx;
    final preservedMass = life[wi];
    for (int r = 1; r <= 10; r++) {
      final uy = wy - gravityDir * r;
      if (inBoundsY(uy) && grid[uy * gridW + wx] == El.empty) {
        grid[uy * gridW + wx] = El.water;
        life[uy * gridW + wx] = preservedMass;
        markProcessed(uy * gridW + wx);
        grid[wi] = El.empty;
        life[wi] = 0;
        markProcessed(wi);
        return;
      }
      for (final dx in [r, -r]) {
        final nx = wrapX(wx + dx);
        if (grid[wy * gridW + nx] == El.empty) {
          grid[wy * gridW + nx] = El.water;
          life[wy * gridW + nx] = preservedMass;
          markProcessed(wy * gridW + nx);
          grid[wi] = El.empty;
          life[wi] = 0;
          markProcessed(wi);
          return;
        }
        final uy2 = wy - gravityDir * r;
        if (inBoundsY(uy2) && grid[uy2 * gridW + nx] == El.empty) {
          grid[uy2 * gridW + nx] = El.water;
          life[uy2 * gridW + nx] = preservedMass;
          markProcessed(uy2 * gridW + nx);
          grid[wi] = El.empty;
          life[wi] = 0;
          markProcessed(wi);
          return;
        }
      }
    }
  }

  /// Granular fall with water displacement (dirt pushes water up). Wraps horizontally.
  void fallGranularDisplace(int x, int y, int idx, int elType) {
    final by = y + gravityDir;
    if (inBoundsY(by)) {
      final below = by * gridW + x;
      final belowEl = grid[below];
      if (belowEl == El.empty) {
        swap(idx, below);
        return;
      }
      if (belowEl == El.water) {
        if (isTrappedWater(x, by)) {
          grid[below] = elType;
          life[below] = (life[idx] + 1).clamp(0, 5);
          velY[below] = velY[idx];
          grid[idx] = El.empty;
          life[idx] = 0;
          velY[idx] = 0;
          markProcessed(idx);
          markProcessed(below);
        } else {
          displaceWater(x, by);
          if (grid[below] == El.empty) {
            grid[below] = elType;
            life[below] = life[idx];
            velY[below] = velY[idx];
            grid[idx] = El.empty;
            life[idx] = 0;
            velY[idx] = 0;
            markProcessed(idx);
            markProcessed(below);
          } else {
            grid[idx] = El.water;
            grid[below] = elType;
            life[below] = life[idx];
            life[idx] = 100;
            markProcessed(idx);
            markProcessed(below);
          }
        }
        return;
      }

      final goLeft = rng.nextBool();
      final wx1 = wrapX(goLeft ? x - 1 : x + 1);
      final wx2 = wrapX(goLeft ? x + 1 : x - 1);
      if (grid[by * gridW + wx1] == El.empty) {
        swap(idx, by * gridW + wx1);
        return;
      }
      if (grid[by * gridW + wx2] == El.empty) {
        swap(idx, by * gridW + wx2);
        return;
      }
    }
  }

  // =========================================================================
  // Wind
  // =========================================================================

  void applyWind() {
    if (windForce == 0) return;
    final absWind = windForce.abs();
    final dir = windForce > 0 ? 1 : -1;
    final w = gridW;
    final g = grid;

    for (int y = 0; y < gridH; y++) {
      final startX = dir > 0 ? w - 1 : 0;
      final endX = dir > 0 ? -1 : w;
      final step = dir > 0 ? -1 : 1;
      final rowOff = y * w;
      for (int x = startX; x != endX; x += step) {
        final el = g[rowOff + x];
        if (el == El.empty) continue;
        final resistance = el < maxElements ? elementWindResistance[el] : 255;
        if (resistance >= 255) continue; // immovable

        // windEffect = windForce * (1.0 - windResistance)
        final effect = (absWind * (255 - resistance)) ~/ 255;
        if (effect <= 0) continue;

        // Higher effect = more likely to move, can move multiple cells
        final thresh = (effect * 8).clamp(0, 100);
        if (rng.nextInt(100) < thresh) {
          // Try to move 1-2 cells based on effect strength
          final maxMove = effect >= 6 ? 2 : 1;
          int cx = x;
          for (int m = 0; m < maxMove; m++) {
            final nx = wrapX(cx + dir);
            if (g[rowOff + nx] == El.empty) {
              swap(rowOff + cx, rowOff + nx);
              cx = nx;
            } else {
              break;
            }
          }
        }
      }
    }
  }

  // =========================================================================
  // Shake
  // =========================================================================

  void doShake() {
    markAllDirty();
    for (int y = gridH - 1; y >= 0; y--) {
      for (int x = 0; x < gridW; x++) {
        final idx = y * gridW + x;
        final el = grid[idx];
        if (el == El.empty || staticElements.contains(el)) continue;
        if (rng.nextInt(100) < 30) {
          final dx = rng.nextInt(3) - 1;
          final dy = rng.nextInt(3) - 1;
          final nx = x + dx;
          final ny = y + dy;
          final wnx = wrapX(nx);
          if (inBoundsY(ny) && grid[ny * gridW + wnx] == El.empty) {
            swap(idx, ny * gridW + wnx);
          }
        }
      }
    }
  }

  // =========================================================================
  // Plant data encoding (packed into velX)
  // =========================================================================

  @pragma('vm:prefer-inline')
  int plantType(int idx) => velX[idx] & 0x0F;

  @pragma('vm:prefer-inline')
  int plantStage(int idx) => (velX[idx] >> 4) & 0x0F;

  @pragma('vm:prefer-inline')
  void setPlantData(int idx, int t, int s) => velX[idx] = ((s & 0xF) << 4) | (t & 0xF);

  // =========================================================================
  // TNT radius calculation
  // =========================================================================

  int calculateTNTRadius(int cx, int cy) {
    int count = 0;
    final visited = <int>{};
    final queue = <int>[cy * gridW + cx];
    while (queue.isNotEmpty && count < 50) {
      final curIdx = queue.removeLast();
      if (visited.contains(curIdx)) continue;
      visited.add(curIdx);
      if (grid[curIdx] != El.tnt) continue;
      count++;
      final qx = curIdx % gridW;
      final qy = curIdx ~/ gridW;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(qx + dx);
          final ny = qy + dy;
          if (inBoundsY(ny)) queue.add(ny * gridW + nx);
        }
      }
    }
    return (6 + (count - 1) * 2).clamp(6, 30);
  }

  // =========================================================================
  // Electrical conduction
  // =========================================================================

  /// Generic conductivity-based electrical propagation.
  /// Lightning hits any cell -> if conductivity > 0, propagate to neighbors.
  /// Propagation strength decays by (1 - conductivity) per hop.
  void conductElectricity(int startX, int startY) {
    final visited = <int>{};
    // Use index pointer instead of removeAt(0) for O(1) dequeue
    final queue = <int>[startY * gridW + startX];
    final strengths = <int, int>{startY * gridW + startX: 255};
    int head = 0;
    int count = 0;
    while (head < queue.length && count < 300) {
      final curIdx = queue[head++];
      if (!visited.add(curIdx)) continue;
      final el = grid[curIdx];
      final cond = el < maxElements ? elementConductivity[el] : 0;
      if (cond == 0) continue;

      // Mark as electrified
      life[curIdx] = 200;
      markProcessed(curIdx);
      count++;

      final cx = curIdx % gridW;
      final cy = curIdx ~/ gridW;
      final strength = strengths[curIdx] ?? 255;

      // Visual sparks
      if (count % 10 == 0) {
        queueReactionFlash(cx, cy, 255, 255, 120, 3);
      }

      // Propagation strength decays by (1 - conductivity) per hop
      final newStrength = (strength * cond) ~/ 255;
      if (newStrength < 20) continue; // too weak to propagate

      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(cx + dx);
          final ny = cy + dy;
          if (!inBoundsY(ny)) continue;
          final ni = ny * gridW + nx;
          if (visited.contains(ni)) continue;
          final neighborEl = grid[ni];
          final neighborCond = neighborEl < maxElements ? elementConductivity[neighborEl] : 0;

          if (neighborCond > 0) {
            // Conductive neighbor: propagate
            if (!strengths.containsKey(ni) || strengths[ni]! < newStrength) {
              strengths[ni] = newStrength;
              // visited check is sufficient; no need for queue.contains
              queue.add(ni);
            }
          } else if (neighborEl == El.tnt) {
            pendingExplosions.add(Explosion(nx, ny, calculateTNTRadius(nx, ny)));
          } else if (rng.nextInt(100) < 30) {
            // Non-conductive neighbor reactions
            if (neighborEl == El.sand) {
              grid[ni] = El.glass;
              life[ni] = 0;
              markProcessed(ni);
            } else if (neighborEl == El.ice) {
              grid[ni] = El.water;
              life[ni] = 0;
              markProcessed(ni);
            } else if (neighborEl == El.plant || neighborEl == El.seed ||
                neighborEl == El.oil || neighborEl == El.wood) {
              grid[ni] = El.fire;
              life[ni] = 0;
              markProcessed(ni);
            } else if (neighborEl == El.ant) {
              grid[ni] = El.empty;
              life[ni] = 0;
              markProcessed(ni);
            }
          }
        }
      }
    }
    lightningFlashFrames = 8;
  }

  // =========================================================================
  // AI Sensing API
  // =========================================================================

  /// Returns OR'd category bitmask of all elements within [radius] of (x,y).
  /// Wraps horizontally for cylinder topology.
  @pragma('vm:prefer-inline')
  int senseCategories(int x, int y, int radius) {
    int result = 0;
    final g = grid;
    final w = gridW;
    final h = gridH;
    final cat = elCategory;
    const maxEl = maxElements;
    final y0 = (y - radius).clamp(0, h - 1);
    final y1 = (y + radius).clamp(0, h - 1);
    final r2 = radius * radius;
    for (int sy = y0; sy <= y1; sy++) {
      final dy = sy - y;
      final dy2 = dy * dy;
      final rowOff = sy * w;
      for (int dx = -radius; dx <= radius; dx++) {
        if (dx * dx + dy2 > r2) continue;
        final sx = wrapX(x + dx);
        final el = g[rowOff + sx];
        if (el > 0 && el < maxEl) {
          result |= cat[el];
        }
      }
    }
    return result;
  }

  /// Fast danger check: returns true if any element with [ElCat.danger] is
  /// within [radius] of (x,y). Short-circuits on first hit.
  /// Wraps horizontally for cylinder topology.
  @pragma('vm:prefer-inline')
  bool senseDanger(int x, int y, int radius) {
    final g = grid;
    final w = gridW;
    final h = gridH;
    final cat = elCategory;
    const maxEl = maxElements;
    final y0 = (y - radius).clamp(0, h - 1);
    final y1 = (y + radius).clamp(0, h - 1);
    final r2 = radius * radius;
    for (int sy = y0; sy <= y1; sy++) {
      final dy = sy - y;
      final dy2 = dy * dy;
      final rowOff = sy * w;
      for (int dx = -radius; dx <= radius; dx++) {
        if (dx * dx + dy2 > r2) continue;
        final sx = wrapX(x + dx);
        final el = g[rowOff + sx];
        if (el > 0 && el < maxEl && (cat[el] & ElCat.danger) != 0) {
          return true;
        }
      }
    }
    return false;
  }

  /// Count occurrences of [elementType] within [radius] of (x,y).
  /// Wraps horizontally for cylinder topology.
  @pragma('vm:prefer-inline')
  int countNearby(int x, int y, int radius, int elementType) {
    int count = 0;
    final g = grid;
    final w = gridW;
    final h = gridH;
    final y0 = (y - radius).clamp(0, h - 1);
    final y1 = (y + radius).clamp(0, h - 1);
    final r2 = radius * radius;
    for (int sy = y0; sy <= y1; sy++) {
      final dy = sy - y;
      final dy2 = dy * dy;
      final rowOff = sy * w;
      for (int dx = -radius; dx <= radius; dx++) {
        if (dx * dx + dy2 > r2) continue;
        final sx = wrapX(x + dx);
        if (g[rowOff + sx] == elementType) count++;
      }
    }
    return count;
  }

  /// Count elements matching [categoryMask] within [radius] of (x,y).
  /// Wraps horizontally for cylinder topology.
  @pragma('vm:prefer-inline')
  int countNearbyByCategory(int x, int y, int radius, int categoryMask) {
    int count = 0;
    final g = grid;
    final w = gridW;
    final h = gridH;
    final cat = elCategory;
    const maxEl = maxElements;
    final y0 = (y - radius).clamp(0, h - 1);
    final y1 = (y + radius).clamp(0, h - 1);
    final r2 = radius * radius;
    for (int sy = y0; sy <= y1; sy++) {
      final dy = sy - y;
      final dy2 = dy * dy;
      final rowOff = sy * w;
      for (int dx = -radius; dx <= radius; dx++) {
        if (dx * dx + dy2 > r2) continue;
        final sx = wrapX(x + dx);
        final el = g[rowOff + sx];
        if (el > 0 && el < maxEl && (cat[el] & categoryMask) != 0) {
          count++;
        }
      }
    }
    return count;
  }

  /// Find direction toward nearest element matching [categoryMask].
  /// Returns encoded value: (dx + 1) * 3 + (dy + 1), or -1 if not found.
  /// Wraps horizontally for cylinder topology.
  int findNearestDirection(int x, int y, int radius, int categoryMask) {
    final g = grid;
    final w = gridW;
    final h = gridH;
    final cat = elCategory;
    const maxEl = maxElements;
    int bestDist = radius * radius + 1;
    int bestDx = 0;
    int bestDy = 0;
    bool found = false;
    final y0 = (y - radius).clamp(0, h - 1);
    final y1 = (y + radius).clamp(0, h - 1);
    final r2 = radius * radius;
    for (int sy = y0; sy <= y1; sy++) {
      final dy = sy - y;
      final dy2 = dy * dy;
      final rowOff = sy * w;
      for (int dx = -radius; dx <= radius; dx++) {
        final d2 = dx * dx + dy2;
        if (d2 > r2 || d2 == 0) continue;
        if (d2 >= bestDist) continue;
        final sx = wrapX(x + dx);
        final el = g[rowOff + sx];
        if (el > 0 && el < maxEl && (cat[el] & categoryMask) != 0) {
          bestDist = d2;
          bestDx = dx;
          bestDy = dy;
          found = true;
        }
      }
    }
    if (!found) return -1;
    final ndx = bestDx == 0 ? 0 : (bestDx > 0 ? 1 : -1);
    final ndy = bestDy == 0 ? 0 : (bestDy > 0 ? 1 : -1);
    return (ndx + 1) * 3 + (ndy + 1);
  }

  /// Scan along direction (dx,dy) from (x,y) for [distance] steps.
  /// Wraps horizontally for cylinder topology; stops at vertical bounds.
  List<int> scanLine(int x, int y, int dx, int dy, int distance) {
    final result = <int>[];
    final g = grid;
    final w = gridW;
    final h = gridH;
    int cx = x + dx;
    int cy = y + dy;
    for (int i = 0; i < distance; i++) {
      if (cy < 0 || cy >= h) break;
      cx = wrapX(cx);
      result.add(g[cy * w + cx]);
      cx += dx;
      cy += dy;
    }
    return result;
  }

  // =========================================================================
  // Temperature / Heat system
  // =========================================================================

  /// Update the temperature grid. Heat sources emit their base temperature,
  /// then heat diffuses to neighbors based on conductivity.
  /// Called every [heatInterval] frames for performance (2-4 frames).
  void updateTemperature() {
    final w = gridW;
    final h = gridH;
    final g = grid;
    final temp = temperature;
    final baseT = elementBaseTemp;
    final cond = elementHeatCond;
    final cap = elementHeatCapacity;
    final dc = dirtyChunks;
    final cols = chunkCols;

    for (int y = 1; y < h - 1; y++) {
      final chunkY = y >> 4;
      for (int x = 0; x < w; x++) {
        final chunkIdx = chunkY * cols + (x >> 4);
        if (dc[chunkIdx] == 0) continue;

        final idx = y * w + x;
        final el = g[idx];

        // Heat sources / sinks push temperature toward their base
        final bt = baseT[el];
        if (bt != 128) {
          final current = temp[idx];
          final diff = bt - current;
          if (diff.abs() > 2) {
            // Heat sources are aggressive — push hard
            final push = ((diff * 77) >> 8).clamp(-20, 20); // ~0.3 * diff
            temp[idx] = (current + push).clamp(0, 255);
          }
        }

        // Diffuse heat to cardinal neighbors
        final myCond = cond[el];
        if (myCond == 0) continue;
        final myCap = cap[el];
        int myTemp = temp[idx];
        if ((myTemp - 128).abs() < 3) continue; // near neutral, skip

        final xl = (x - 1 + w) % w;
        final xr = (x + 1) % w;

        // Transfer heat to 4 cardinal neighbors (unrolled, no allocation)
        // Q = mcΔT: energy divided by heat capacity gives temperature change
        final ni0 = idx - w; // up
        final ni1 = idx + w; // down
        final ni2 = y * w + xl; // left
        final ni3 = y * w + xr; // right

        // Neighbor 0 (up)
        if (ni0 >= 0) {
          final nEl = g[ni0];
          final nCond = cond[nEl];
          if (nCond > 0) {
            final tDiff = myTemp - temp[ni0];
            if (tDiff.abs() >= 3) {
              final rate = myCond < nCond ? myCond : nCond;
              final energy = (tDiff * rate) >> 9;
              if (energy != 0) {
                final myDelta = energy ~/ myCap;
                final nDelta = energy ~/ cap[nEl];
                // Ensure at least 1 unit transfer in the correct direction
                myTemp = (myTemp - (myDelta != 0 ? myDelta : (energy > 0 ? 1 : -1))).clamp(0, 255);
                temp[idx] = myTemp;
                temp[ni0] = (temp[ni0] + (nDelta != 0 ? nDelta : (energy > 0 ? 1 : -1))).clamp(0, 255);
              }
            }
          }
        }
        // Neighbor 1 (down)
        if (ni1 < g.length) {
          final nEl = g[ni1];
          final nCond = cond[nEl];
          if (nCond > 0) {
            final tDiff = myTemp - temp[ni1];
            if (tDiff.abs() >= 3) {
              final rate = myCond < nCond ? myCond : nCond;
              final energy = (tDiff * rate) >> 9;
              if (energy != 0) {
                final myDelta = energy ~/ myCap;
                final nDelta = energy ~/ cap[nEl];
                myTemp = (myTemp - (myDelta != 0 ? myDelta : (energy > 0 ? 1 : -1))).clamp(0, 255);
                temp[idx] = myTemp;
                temp[ni1] = (temp[ni1] + (nDelta != 0 ? nDelta : (energy > 0 ? 1 : -1))).clamp(0, 255);
              }
            }
          }
        }
        // Neighbor 2 (left)
        {
          final nEl = g[ni2];
          final nCond = cond[nEl];
          if (nCond > 0) {
            final tDiff = myTemp - temp[ni2];
            if (tDiff.abs() >= 3) {
              final rate = myCond < nCond ? myCond : nCond;
              final energy = (tDiff * rate) >> 9;
              if (energy != 0) {
                final myDelta = energy ~/ myCap;
                final nDelta = energy ~/ cap[nEl];
                myTemp = (myTemp - (myDelta != 0 ? myDelta : (energy > 0 ? 1 : -1))).clamp(0, 255);
                temp[idx] = myTemp;
                temp[ni2] = (temp[ni2] + (nDelta != 0 ? nDelta : (energy > 0 ? 1 : -1))).clamp(0, 255);
              }
            }
          }
        }
        // Neighbor 3 (right)
        {
          final nEl = g[ni3];
          final nCond = cond[nEl];
          if (nCond > 0) {
            final tDiff = myTemp - temp[ni3];
            if (tDiff.abs() >= 3) {
              final rate = myCond < nCond ? myCond : nCond;
              final energy = (tDiff * rate) >> 9;
              if (energy != 0) {
                final myDelta = energy ~/ myCap;
                final nDelta = energy ~/ cap[nEl];
                myTemp = (myTemp - (myDelta != 0 ? myDelta : (energy > 0 ? 1 : -1))).clamp(0, 255);
                temp[idx] = myTemp;
                temp[ni3] = (temp[ni3] + (nDelta != 0 ? nDelta : (energy > 0 ? 1 : -1))).clamp(0, 255);
              }
            }
          }
        }
      }
    }
  }

  // =========================================================================
  // Pressure system
  // =========================================================================

  /// Update pressure grid for liquid cells.
  /// Uses a 2-pass approach:
  /// 1. Vertical scan: accumulates depth gravity.
  /// 2. Horizontal diffusion: equalizes pressure laterally for siphons/U-bends.
  void updatePressure() {
    final w = gridW;
    final h = gridH;
    final g = grid;
    final p = pressure;
    final dc = dirtyChunks;
    final cols = chunkCols;
    final gDir = gravityDir;

    // Pass 1: Vertical Hydrostatic Accumulation
    for (int cx = 0; cx < cols; cx++) {
      bool colGroupDirty = false;
      for (int cy = 0; cy < chunkRows; cy++) {
        if (dc[cy * cols + cx] != 0) {
          colGroupDirty = true;
          break;
        }
      }
      if (!colGroupDirty) continue;

      final startX = cx << 4;
      final endX = startX + 16 < w ? startX + 16 : w;

      for (int x = startX; x < endX; x++) {
        int liquidDepth = 0;
        final yStart = gDir == 1 ? 0 : h - 1;
        final yEnd = gDir == 1 ? h : -1;
        final yStep = gDir == 1 ? 1 : -1;

        for (int y = yStart; y != yEnd; y += yStep) {
          final idx = y * w + x;
          final el = g[idx];
          final state = el < maxElements ? elementPhysicsState[el] : 0;
          if (state == PhysicsState.liquid.index) {
            liquidDepth++;
            p[idx] = liquidDepth < 255 ? liquidDepth : 255;
          } else if (state == PhysicsState.gas.index) {
            p[idx] = (liquidDepth >> 1); // Gases carry half pressure
          } else {
            liquidDepth = 0;
            p[idx] = 0;
          }
        }
      }
    }

    // Pass 2: Horizontal Pressure Diffusion (Pascal's Principle)
    for (int y = 0; y < h; y++) {
      final chunkY = y >> 4;
      for (int x = 0; x < w; x++) {
        final chunkIdx = chunkY * cols + (x >> 4);
        if (dc[chunkIdx] == 0) continue;
        
        final idx = y * w + x;
        final el = g[idx];
        final state = el < maxElements ? elementPhysicsState[el] : 0;
        
        if (state == PhysicsState.liquid.index) {
           final left = p[y * w + wrapX(x - 1)];
           final right = p[y * w + wrapX(x + 1)];
           final myP = p[idx];
           
           int maxP = myP;
           if (left > maxP) maxP = left;
           if (right > maxP) maxP = right;

           // Equalize laterally, losing a bit of energy to friction
           if (maxP > myP + 1) {
              p[idx] = maxP - 1;
           }
        }
      }
    }
  }

  /// Update moisture grid for porous cells.
  /// Simulates capillary wicking where water spreads from wet to dry areas.
  void updateMoisture() {
    final w = gridW;
    final h = gridH;
    final g = grid;
    final m = moisture;
    final dc = dirtyChunks;
    final cols = chunkCols;

    for (int cy = 0; cy < chunkRows; cy++) {
      for (int cx = 0; cx < cols; cx++) {
        if (dc[cy * cols + cx] == 0) continue;

        final startX = cx << 4;
        final startY = cy << 4;
        final endX = (startX + 16).clamp(0, w);
        final endY = (startY + 16).clamp(0, h);

        for (int y = startY; y < endY; y++) {
          for (int x = startX; x < endX; x++) {
            final idx = y * w + x;
            final el = g[idx];
            
            // Source: liquids provide maximum moisture
            if (el == El.water || el == El.mud) {
              m[idx] = 255;
              continue;
            }

            // Porous elements can absorb and diffuse moisture
            final porosity = elementPorosity[el];
            if (porosity > 0) {
              // Sample neighbors to find average moisture
              int total = 0;
              int count = 0;
              for (int dy = -1; dy <= 1; dy++) {
                for (int dx = -1; dx <= 1; dx++) {
                  if (dx == 0 && dy == 0) continue;
                  final nx = wrapX(x + dx);
                  final ny = y + dy;
                  if (!inBoundsY(ny)) continue;
                  final ni = ny * w + nx;
                  total += m[ni];
                  count++;
                }
              }
              final avg = total ~/ count;
              final current = m[idx];
              
              if (avg > current) {
                // Wicking: moisture increases towards neighbor average
                // Scaled by porosity (more porous = faster wicking)
                final diff = avg - current;
                final step = (diff * porosity) >> 8;
                m[idx] = (current + (step > 0 ? step : 1)).clamp(0, 255);
              } else if (current > 0) {
                // Evaporation/Drainage: moisture slowly decays
                m[idx] = (current - 1).clamp(0, 255);
              }
            } else {
              // Non-porous: moisture is zero or rapidly resets
              m[idx] = 0;
            }
          }
        }
      }
    }
  }

  /// Get pressure-based lateral search radius for liquid flow.
  @pragma('vm:prefer-inline')
  int pressureFlowRadius(int idx) {
    final p = pressure[idx];
    if (p >= 16) return 6;
    if (p >= 6) return 3;
    return 1;
  }

  /// Map of grid index to Chunk ID. 0 = no chunk.
  late Int32List chunkMap;
  
  /// Active chunks currently in the simulation.
  final List<Set<int>> activeChunks = [];

  /// Update rigid-body chunks. Periodically identifies connected solids.
  void updateChunks() {
    final w = gridW;
    final h = gridH;
    final g = grid;
    
    // Clear old chunk data
    chunkMap.fillRange(0, chunkMap.length, 0);
    activeChunks.clear();

    // Simplified Scan-line Seed Fill for connected structural elements
    for (int i = 0; i < g.length; i++) {
      final el = g[i];
      if (chunkMap[i] != 0) continue;
      
      // Only wood, stone, metal, and glass form rigid chunks
      if (el == El.wood || el == El.stone || el == El.metal || el == El.glass) {
        final currentChunk = <int>{};
        final queue = <int>[i];
        chunkMap[i] = activeChunks.length + 1;
        
        bool isAnchored = false;

        while (queue.isNotEmpty) {
          final idx = queue.removeLast();
          currentChunk.add(idx);
          final cx = idx % w;
          final cy = idx ~/ w;

          // Check 4-way neighbors for connectivity
          for (int di = 0; di < 4; di++) {
            final nx = di == 0 ? wrapX(cx - 1) : (di == 1 ? wrapX(cx + 1) : cx);
            final ny = di == 2 ? cy - 1 : (di == 3 ? cy + 1 : cy);
            
            if (inBoundsY(ny)) {
              final ni = ny * w + nx;
              final nEl = g[ni];
              
              // Anchor check: if we touch bedrock or fixed ground
              if (nEl == El.bedrock || (nEl == El.dirt && (flags[ni] & 0x70) == 0x70)) {
                isAnchored = true;
              }

              if (chunkMap[ni] == 0 && nEl == el) {
                chunkMap[ni] = activeChunks.length + 1;
                queue.add(ni);
              }
            }
          }
        }

        // If the entire chunk is unsupported, mark it for falling
        if (!isAnchored && currentChunk.length > 1) {
          activeChunks.add(currentChunk);
          // Apply gravity to the whole chunk
          final gDir = gravityDir;
          for (final cIdx in currentChunk) {
            // Give all pixels in the chunk unified velocity
            velY[cIdx] = (velY[cIdx] + 1).clamp(0, 127).toInt();
          }
        }
      }
    }
  }

  /// Check temperature-driven state changes for a cell.
  /// Returns true if the element was transformed.
  @pragma('vm:prefer-inline')
  bool checkTemperatureReaction(int x, int y, int idx, int el) {
    final temp = temperature[idx];
    final props = elementProperties[el];

    // Hot enough to melt?
    if (props.meltPoint > 0 && temp > 128 + props.meltPoint ~/ 2) {
      final target = props.meltsInto;
      if (target != 0) {
        grid[idx] = target;
        life[idx] = 0;
        markProcessed(idx);
        unsettleNeighbors(x, y);
        return true;
      }
    }

    // Hot enough to boil?
    // Clausius-Clapeyron: boiling point rises with pressure (depth).
    // Each 2 pressure units adds 1 to the effective boiling threshold.
    if (props.boilPoint > 0) {
      final pressureShift = pressure[idx] >> 1; // +1 per 2 depth units
      final effectiveBoilT = 128 + props.boilPoint ~/ 2 + pressureShift;
      if (temp > effectiveBoilT) {
        final target = props.boilsInto;
        if (target != 0) {
          grid[idx] = target;
          life[idx] = 0;
          // Evaporative cooling: vaporization absorbs latent heat.
          // Applied only to non-lava neighbors to avoid destabilizing
          // lava pools. Surface evaporation (in simWater) handles the
          // stronger cooling effect for ambient evaporation.
          for (int edy = -1; edy <= 1; edy++) {
            for (int edx = -1; edx <= 1; edx++) {
              if (edx == 0 && edy == 0) continue;
              final enx = wrapX(x + edx);
              final eny = y + edy;
              if (!inBoundsY(eny)) continue;
              final eni = eny * gridW + enx;
              // Skip lava: lava's own cooling is handled by simLava
              if (grid[eni] == El.lava) continue;
              final et = temperature[eni];
              if (et > 2) {
                temperature[eni] = et - 2;
              }
            }
          }
          markProcessed(idx);
          unsettleNeighbors(x, y);
          return true;
        }
      }
    }

    // Cold enough to freeze?
    if (props.freezePoint > 0 && temp < 128 - props.freezePoint ~/ 2) {
      final target = props.freezesInto;
      if (target != 0) {
        grid[idx] = target;
        life[idx] = 0;
        markProcessed(idx);
        unsettleNeighbors(x, y);
        return true;
      }
    }

    return false;
  }

  // =========================================================================
  // Density displacement
  // =========================================================================

  /// Try to displace the element at (x,y) downward through a lighter element.
  /// Returns true if a swap occurred.
  @pragma('vm:prefer-inline')
  bool tryDensityDisplace(int x, int y, int idx, int el) {
    final by = y + gravityDir;
    if (!inBoundsY(by)) return false;

    final bi = by * gridW + x;
    final belowEl = grid[bi];
    if (belowEl == El.empty) return false;

    final myDensity = elementDensity[el];
    final belowDensity = elementDensity[belowEl];

    // Skip if below is heavier or same density
    if (belowDensity >= myDensity) return false;

    // Skip if below element was already processed this frame
    final clockBit = simClock ? 0x80 : 0;
    if ((flags[bi] & 0x80) == clockBit) return false;

    // Only displace liquids and gases (not solids or granulars)
    final belowState = elementPhysicsState[belowEl];
    if (belowState != PhysicsState.liquid.index &&
        belowState != PhysicsState.gas.index) {
      return false;
    }

    // Swap: heavy sinks through light
    swap(idx, bi);
    return true;
  }

  /// Try to float upward through a heavier element (for gases/light liquids).
  @pragma('vm:prefer-inline')
  bool tryBuoyancy(int x, int y, int idx, int el) {
    final uy = y - gravityDir;
    if (!inBoundsY(uy)) return false;

    final ui = uy * gridW + x;
    final aboveEl = grid[ui];
    if (aboveEl == El.empty) return false;

    final myDensity = elementDensity[el];
    final aboveDensity = elementDensity[aboveEl];

    // Only float if we're lighter
    if (myDensity >= aboveDensity) return false;

    final clockBit = simClock ? 0x80 : 0;
    if ((flags[ui] & 0x80) == clockBit) return false;

    final aboveState = elementPhysicsState[aboveEl];
    if (aboveState != PhysicsState.liquid.index &&
        aboveState != PhysicsState.gas.index) {
      return false;
    }

    swap(idx, ui);
    return true;
  }

  // =========================================================================
  // Convection currents — hot liquids rise, cold liquids sink
  // =========================================================================

  /// Apply convection to a liquid cell: if this cell is hotter than the one
  /// above it (same liquid type), swap them so hot rises. Returns true if moved.
  @pragma('vm:prefer-inline')
  bool tryConvection(int x, int y, int idx, int el) {
    final myTemp = temperature[idx];
    // Only fire for meaningfully hot or cold liquids (deviation from neutral)
    if ((myTemp - 128).abs() < 8) return false;

    final g = gravityDir;
    final uy = y - g;
    if (!inBoundsY(uy)) return false;

    final ui = uy * gridW + x;
    final aboveEl = grid[ui];

    // Same liquid type: hot rises through cold (Rayleigh-Bénard convection).
    // Real physics: buoyancy force ∝ ΔT × thermal expansion coefficient.
    // Water has thermal expansion ~2×10⁻⁴/K, so even small ΔT drives
    // significant convection in columns of any depth. The Rayleigh number
    // Ra = gβΔTH³/(να) determines flow vigor; Ra > 1000 gives turbulent
    // convection. We model this by making swap probability proportional
    // to temperature difference, with a low threshold for activation.
    if (aboveEl == el) {
      final aboveTemp = temperature[ui];
      int diff = myTemp - aboveTemp;

      // Anomalous expansion of water: water is densest at 4°C (temp≈40
      // on our 0-255 scale). Below this temperature, water EXPANDS as it
      // cools — its density decreases. This means near-freezing water
      // (temp < 40) is less dense than water at 4°C, so it RISES.
      // This is why ponds freeze from the top down: the coldest water
      // floats to the surface where it can freeze, insulating the
      // liquid below. Without this, ice would form at the bottom and
      // lakes would freeze solid, killing aquatic life.
      // Reference: CRC Handbook, water density maximum at 3.98°C.
      if (el == El.water && myTemp < 40 && aboveTemp < 40) {
        // Both cells below the density maximum — invert convection.
        // Colder water is now LESS dense and should rise.
        diff = aboveTemp - myTemp; // flip: colder rises
      }

      // Hot cell below cold cell — swap (hot rises).
      // In real fluids, convection dominates conduction (Prandtl number
      // Pr_water ≈ 7, meaning momentum diffuses 7x faster than heat).
      // We must be aggressive: swap for any positive ΔT to outpace
      // the heat conduction that continually equalizes temperatures.
      // Without this, conduction flattens the gradient before convection
      // can establish thermal stratification.
      if (diff > 3) {
        // Meaningful difference: always swap
        swap(idx, ui);
        return true;
      }
      if (diff > 0) {
        // Tiny difference: probabilistic swap (50%)
        if (rng.nextBool()) {
          swap(idx, ui);
          return true;
        }
      }
      return false;
    }

    // Different liquid: hot liquid rises through cooler heavier liquid
    // only if temperature makes it effectively lighter
    final aboveState = elementPhysicsState[aboveEl];
    if (aboveState != PhysicsState.liquid.index) return false;

    final myDensity = elementDensity[el];
    final aboveDensity = elementDensity[aboveEl];
    // Normally heavier — but heat reduces effective density
    // Each 10 degrees above neutral reduces effective density by ~5
    final heatReduction = ((myTemp - 128).clamp(0, 127)) ~/ 2;
    final effectiveDensity = (myDensity - heatReduction).clamp(0, 255);

    if (effectiveDensity < aboveDensity) {
      final clockBit = simClock ? 0x80 : 0;
      if ((flags[ui] & 0x80) != clockBit) {
        swap(idx, ui);
        return true;
      }
    }
    return false;
  }

  // =========================================================================
  // Radiant heat — hot elements warm nearby air cells
  // =========================================================================

  /// Emit radiant heat from a hot element to surrounding empty (air) cells.
  /// Creates visible heat zones around lava, fire, etc.
  void emitRadiantHeat(int x, int y, int idx, int radius, int intensity) {
    final w = gridW;
    final h = gridH;
    final r2 = radius * radius;
    for (int dy = -radius; dy <= radius; dy++) {
      final ny = y + dy;
      if (ny < 0 || ny >= h) continue;
      for (int dx = -radius; dx <= radius; dx++) {
        final d2 = dx * dx + dy * dy;
        if (d2 == 0 || d2 > r2) continue;
        final nx = wrapX(x + dx);
        final ni = ny * w + nx;
        final el = grid[ni];
        // Radiant heat warms all surfaces that absorb infrared radiation.
        // Only highly conductive metals reflect significant IR (polished
        // metal emissivity ~0.05). Everything else absorbs and heats up.
        if (el == El.empty || elementHeatCond[el] < 200) {
          final falloff = intensity * (r2 - d2) ~/ r2;
          final current = temperature[ni];
          if (current < 128 + falloff) {
            temperature[ni] = (current + (falloff ~/ 3).clamp(1, 15)).clamp(0, 255);
          }
        }
      }
    }
  }

  // =========================================================================
  // Unified Chemistry Step (per-cell emergent reactions)
  // =========================================================================

  /// Check if any neighbor has reductionPotential above [threshold].
  /// Used for combustion: "is there an oxidizer nearby?"
  @pragma('vm:prefer-inline')
  bool _hasAdjacentOxidizer(int x, int y, int threshold) {
    final w = gridW;
    final g = grid;
    final maxY = gridH - 1;
    final xl = (x - 1 + w) % w;
    final xr = (x + 1) % w;
    if (y > 0) {
      final rowAbove = (y - 1) * w;
      if (g[rowAbove + xl] < maxElements && elementReductionPotential[g[rowAbove + xl]] > threshold) return true;
      if (g[rowAbove + x] < maxElements && elementReductionPotential[g[rowAbove + x]] > threshold) return true;
      if (g[rowAbove + xr] < maxElements && elementReductionPotential[g[rowAbove + xr]] > threshold) return true;
    }
    if (g[y * w + xl] < maxElements && elementReductionPotential[g[y * w + xl]] > threshold) return true;
    if (g[y * w + xr] < maxElements && elementReductionPotential[g[y * w + xr]] > threshold) return true;
    if (y < maxY) {
      final rowBelow = (y + 1) * w;
      if (g[rowBelow + xl] < maxElements && elementReductionPotential[g[rowBelow + xl]] > threshold) return true;
      if (g[rowBelow + x] < maxElements && elementReductionPotential[g[rowBelow + x]] > threshold) return true;
      if (g[rowBelow + xr] < maxElements && elementReductionPotential[g[rowBelow + xr]] > threshold) return true;
    }
    return false;
  }

  /// Find index of the weakest-bonded neighbor (lowest bondEnergy > 0).
  /// Returns -1 if no dissolvable neighbor found.
  @pragma('vm:prefer-inline')
  int _findWeakestNeighbor(int x, int y, int minReactivity) {
    final w = gridW;
    final g = grid;
    final bondEn = elementBondEnergy;
    final maxY = gridH - 1;
    int bestIdx = -1;
    int bestBond = 256;
    
    final xl = x == 0 ? w - 1 : x - 1;
    final xr = x == w - 1 ? 0 : x + 1;
    
    // Helper closure or macro-like behavior inline
    void check(int ni) {
      final ne = g[ni];
      if (ne == 0 || ne >= maxElements) return;
      final bond = bondEn[ne];
      if (bond > 0 && bond < minReactivity && bond < bestBond) {
        bestBond = bond;
        bestIdx = ni;
      }
    }

    if (y > 0) {
      final r = (y - 1) * w;
      check(r + xl); check(r + x); check(r + xr);
    }
    final r = y * w;
    check(r + xl); check(r + xr);
    if (y < maxY) {
      final r = (y + 1) * w;
      check(r + xl); check(r + x); check(r + xr);
    }
    
    return bestIdx;
  }

  /// Find the adjacent cell index with the highest voltage.
  /// Returns -1 if no conductive neighbor found, or all neighbors are at
  /// equal or lower voltage.
  @pragma('vm:prefer-inline')
  int _findHighestVoltageNeighbor(int x, int y, int myVoltage) {
    final w = gridW;
    final g = grid;
    final v = voltage;
    final maxY = gridH - 1;
    int bestIdx = -1;
    int bestVolt = myVoltage;

    final xl = x == 0 ? w - 1 : x - 1;
    final xr = x == w - 1 ? 0 : x + 1;

    void check(int ni) {
      final ne = g[ni];
      if (ne == 0 || ne >= maxElements) return;
      final nv = v[ni];
      if (nv > bestVolt) {
        bestVolt = nv;
        bestIdx = ni;
      }
    }

    if (y > 0) {
      final r = (y - 1) * w;
      check(r + xl); check(r + x); check(r + xr);
    }
    final r = y * w;
    check(r + xl); check(r + xr);
    if (y < maxY) {
      final r = (y + 1) * w;
      check(r + xl); check(r + x); check(r + xr);
    }

    return bestIdx;
  }

  /// Process unified chemistry for a single active cell.
  ///
  /// Handles combustion, corrosion, dissolution, moisture spread, and mass
  /// update using only the dynamic property tables — no hardcoded element
  /// checks. Every threshold and rate derives from ElementProperties so
  /// Optuna can tune any property and measure different outcomes.
  ///
  /// Called per dirty-chunk cell BEFORE element-specific behaviors.
  @pragma('vm:prefer-inline')
  void chemistryStep(int x, int y, int idx) {
    final el = grid[idx];
    if (el == El.empty || el >= maxElements) return;

    final temp = temperature[idx];
    final moist = moisture[idx];
    final ox = oxidation[idx];
    final react = elementReactivity[el];

    // -- COMBUSTION --
    // Element has fuel AND is hot enough AND an oxidizer is nearby.
    // Oxidizer detection threshold scales inversely with fuel reactivity:
    // highly reactive fuels ignite with weaker oxidizers.
    final fuel = elementFuelValue[el];
    if (fuel > 0) {
      final ignition = elementIgnitionTemp[el];
      // Oxidizer threshold: fuels with high reactivity need weaker oxidizers
      // reactivity 200 -> threshold ~7, reactivity 10 -> threshold ~55
      final oxThreshold = 60 - (react >> 2); // 60 - reactivity/4
      if (temp > ignition && _hasAdjacentOxidizer(x, y, oxThreshold > 0 ? oxThreshold : 0)) {
        // Burn rate scales with fuelValue: high-energy fuels burn faster.
        // fuel 255 -> rate 5, fuel 100 -> rate 2, fuel 50 -> rate 1
        final burnRate = 1 + (fuel >> 6) + (react >> 7);
        final newOx = ox + burnRate;
        if (newOx > 255) {
          // Fully combusted — transform
          final product = elementOxidizesInto[el];
          if (product != 0) {
            grid[idx] = product;
            life[idx] = 0;
            oxidation[idx] = 128; // reset
            // Spawn byproduct above if space available
            final byproduct = elementOxidationByproduct[el];
            if (byproduct != 0) {
              final aboveY = y - gravityDir;
              if (inBoundsY(aboveY)) {
                final aboveIdx = aboveY * gridW + x;
                if (grid[aboveIdx] == El.empty) {
                  grid[aboveIdx] = byproduct;
                  life[aboveIdx] = 0;
                  oxidation[aboveIdx] = 128;
                  // Byproduct temperature: proportional to fuel energy
                  final byTemp = temp - (fuel >> 3);
                  temperature[aboveIdx] = byTemp > 0 ? byTemp : 0;
                  markDirty(x, aboveY);
                }
              }
            }
          } else {
            clearCell(idx);
          }
          // Heat release proportional to fuelValue and bondEnergy (breaking
          // bonds releases stored energy). High bond + high fuel = big boom.
          final bond = elementBondEnergy[el];
          final heatRelease = (fuel >> 2) + (bond >> 5);
          final newTemp = temp + heatRelease;
          temperature[idx] = newTemp < 255 ? newTemp : 255;
          markDirty(x, y);
          unsettleNeighbors(x, y);
          queueReactionFlash(x, y, 255, 140, 20, 3);
          return; // cell transformed, done
        }
        oxidation[idx] = newOx;
        // Pre-combustion heating: scales with fuel energy density
        final preheat = (fuel >> 4) + (react >> 6);
        final preTemp = temp + preheat;
        temperature[idx] = preTemp < 255 ? preTemp : 255;
      }
    }

    // -- CORROSION --
    // Negative reductionPotential elements + moisture + adjacent oxidizer.
    // Moisture threshold scales with corrosionResistance: resistant metals
    // need more moisture to begin corroding.
    final redPot = elementReductionPotential[el];
    if (redPot < 0) {
      final corrResist = elementCorrosionResistance[el];
      // Moisture threshold: corrResist 90 -> need 53, corrResist 0 -> need 10
      final moistThreshold = 10 + (corrResist >> 1);
      // Oxidizer threshold: elements with more negative potential corrode
      // even with weaker oxidizers present
      final corrOxThreshold = redPot + 40; // e.g. -15+40=25, -80+40=-40
      if (moist > moistThreshold && _hasAdjacentOxidizer(x, y, corrOxThreshold < 0 ? 0 : corrOxThreshold)) {
        // Corrosion rate: wetter = faster, more negative potential = faster
        // moist 255 -> +3, redPot -80 -> +1 extra
        final moistFactor = (moist - moistThreshold) >> 6;
        final potFactor = (-redPot) >> 6;
        final corrRate = 1 + moistFactor + potFactor;
        final newOx = ox + corrRate;
        if (newOx > 255) {
          // Fully corroded — transform (e.g. metal -> rust)
          final product = elementOxidizesInto[el];
          if (product != 0) {
            grid[idx] = product;
            life[idx] = 0;
            oxidation[idx] = 128;
            markDirty(x, y);
            unsettleNeighbors(x, y);
            queueReactionFlash(x, y, 160, 80, 20, 2);
          }
          return;
        }
        oxidation[idx] = newOx;
      }
    }

    // -- DISSOLUTION --
    // Reactive elements dissolve weak-bonded neighbors.
    // Reactivity threshold: only elements with reactivity > bondEnergy/2
    // of self can dissolve others. Self-consumption scales with reactivity.
    if (react > 100) {
      // Dissolution power: reactivity determines what can be dissolved
      final victimIdx = _findWeakestNeighbor(x, y, react);
      if (victimIdx >= 0) {
        final victimX = victimIdx % gridW;
        final victimY = victimIdx ~/ gridW;
        clearCell(victimIdx);
        markDirty(victimX, victimY);
        // Self-consumption rate scales inversely with own bondEnergy:
        // strong acids (high react, low bond) wear out faster
        final selfBond = elementBondEnergy[el];
        final wearRate = 1 + ((255 - selfBond) >> 6); // bond 30->4, bond 200->1
        final newLife = life[idx] + wearRate;
        // Exhaustion threshold: higher reactivity = more uses before depletion
        final exhaustion = 200 + (react >> 3); // react 220->227, react 100->212
        if (newLife > exhaustion) {
          clearCell(idx);
          markDirty(x, y);
          return;
        }
        life[idx] = newLife;
        queueReactionFlash(victimX, victimY, 30, 255, 30, 2);
      }
    }

    // -- MOISTURE SPREAD --
    // Liquid cells spread moisture to porous neighbors.
    // Transfer rate scales with source reactivity (reactive liquids wet more
    // aggressively) and neighbor porosity.
    if ((elCategory[el] & ElCat.liquid) != 0) {
      // Source moisture intensity: water-like reactivity drives wetting
      final srcIntensity = 1 + (react >> 5); // react 60->2, react 220->7
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = (x + dx + gridW) % gridW;
          final ny = y + dy;
          if (ny < 0 || ny >= gridH) continue;
          final ni = ny * gridW + nx;
          final ne = grid[ni];
          if (ne == El.empty || ne >= maxElements) continue;
          final porosity = elementPorosity[ne];
          if (porosity > 0) {
            // Transfer: porosity/64 * srcIntensity (porosity 255->4*src, 30->0*src)
            final transfer = (porosity >> 6) * srcIntensity;
            if (transfer > 0) {
              final nm = moisture[ni];
              final updated = nm + transfer;
              moisture[ni] = updated < 255 ? updated : 255;
            }
          }
        }
      }
    }

    // Hot cells evaporate moisture.
    // Evaporation threshold derived from element's boilPoint (if it has one)
    // or heatCapacity. Higher heat capacity = resists evaporation longer.
    if (moist > 0 && temp > 128) {
      final heatCap = elementHeatCapacity[el];
      // Evaporation temp threshold: heatCap 10->178, heatCap 1->133
      final evapThreshold = 128 + (heatCap * 5);
      if (temp > evapThreshold) {
        // Rate scales with temperature excess
        final evap = 1 + ((temp - evapThreshold) >> 3);
        moisture[idx] = moist > evap ? moist - evap : 0;
      }
    }

    // -- MASS UPDATE --
    // mass = baseMass + moisture contribution + concentration contribution
    final bm = elementBaseMass[el];
    if (bm > 0) {
      final moistAdd = moist >> 3;
      final concAdd = concentration[idx] >> 4;
      final total = bm + moistAdd + concAdd;
      mass[idx] = total < 255 ? total : 255;
    }
  }

  // =========================================================================
  // Electricity Step (voltage propagation, ohmic heating)
  // =========================================================================

  /// Process electricity for a single conductive cell.
  ///
  /// Handles voltage propagation from high to low potential, ohmic heating,
  /// refractory period (Wireworld-inspired), electrolysis, and moisture
  /// conductivity boost. All thresholds derive from ElementProperties so
  /// Optuna can tune electronMobility, dielectric, bondEnergy, reactivity
  /// and measure different outcomes.
  ///
  /// Called per conductive cell every 2 frames.
  @pragma('vm:prefer-inline')
  void electricityStep(int x, int y, int idx) {
    final el = grid[idx];
    if (el == El.empty || el >= maxElements) return;

    final mobility = elementElectronMobility[el];
    // Moisture boosts effective conductivity (wet materials conduct better)
    final moistBoost = moisture[idx] >> 2;
    // Dissolved salt in water further boosts conductivity
    final saltBoost = (el == El.water && dissolvedType[idx] == El.salt)
        ? concentration[idx] >> 3 // conc 200 -> +25 mobility
        : 0;
    final effectiveMobility = mobility + moistBoost + saltBoost;
    // Conductivity threshold: dielectric constant determines minimum
    // mobility needed. High dielectric = needs more mobility to conduct.
    final dielectricThreshold = elementDielectric[el] >> 5; // 0..7
    if (effectiveMobility <= dielectricThreshold) return;

    final st = sparkTimer[idx];

    // Refractory period: cooldown length scales with dielectric
    // (insulators that DO conduct take longer to recover)
    final cooldownMax = 3 + (elementDielectric[el] >> 6); // 3..6
    if (st > 2) {
      if (st < cooldownMax) {
        sparkTimer[idx] = st - 1;
      } else {
        sparkTimer[idx] = 2; // snap down if somehow above max
      }
      return;
    }
    // Tail state: transition to cooling
    if (st == 2) {
      sparkTimer[idx] = cooldownMax;
      voltage[idx] = 0;
      return;
    }

    final myVolt = voltage[idx];

    // Find highest-voltage neighbor
    final srcIdx = _findHighestVoltageNeighbor(x, y, myVolt);
    if (srcIdx >= 0) {
      final srcVolt = voltage[srcIdx];
      final gradient = srcVolt - myVolt;
      // Flow threshold: scales with dielectric. Good conductors (low
      // dielectric) propagate smaller gradients. Insulators need big gaps.
      final flowThreshold = 1 + (elementDielectric[el] >> 5); // 1..8
      if (gradient > flowThreshold) {
        // Resistance = inverse of effective mobility
        final clampedMobility = effectiveMobility < 255 ? effectiveMobility : 255;
        final resistance = 255 - clampedMobility;
        // Attenuation: resistance/32, so mobility 240->0, mobility 80->5
        final attenuation = 1 + (resistance >> 5);
        final received = gradient - attenuation;

        if (received > 0) {
          final newVolt = myVolt + received;
          voltage[idx] = newVolt < 127 ? newVolt : 127;

          // Mark as spark head if was ready
          if (st == 0) {
            sparkTimer[idx] = 1; // head
          }

          // Ohmic heating: voltageDrop * resistance / 256.
          // High-resistance elements heat more (e.g. water conducts but heats,
          // copper conducts with almost no heat).
          // heatCapacity dampens: dense materials absorb the heat.
          final voltageDrop = gradient - received;
          final heatCap = elementHeatCapacity[el];
          final heating = (voltageDrop * resistance) >> (7 + heatCap);
          if (heating > 0) {
            final t = temperature[idx];
            final newTemp = t + heating;
            temperature[idx] = newTemp < 255 ? newTemp : 255;
          }

          markDirty(x, y);
        }
      }
    }

    // Spark head transitions to tail next frame
    if (st == 1) {
      sparkTimer[idx] = 2;
    }

    // -- CHARGE ACCUMULATION from voltage flow --
    // When current flows through a cell, charge builds up.
    if (myVolt.abs() > 5) {
      final ch = charge[idx];
      final addCharge = myVolt >> 2; // voltage/4
      final newCharge = ch + addCharge;
      charge[idx] = newCharge.clamp(-128, 127);
    }

    // -- ELECTROLYSIS --
    // Conductive liquid + high voltage splits molecules.
    // Voltage threshold scales with bondEnergy: stronger bonds need more
    // voltage to break. Probability scales with reactivity.
    // High charge on water also boosts electrolysis likelihood.
    final bond = elementBondEnergy[el];
    final react = elementReactivity[el];
    // Electrolysis voltage threshold: bondEnergy/3 + 10
    // water(bond=100) -> 43, salt(bond=100) -> 43
    final electrolysisThreshold = (bond >> 2) + 10;
    // High charge lowers the threshold (accumulated charge assists splitting)
    final ch = charge[idx];
    final chargeAssist = ch > 20 ? (ch - 20) >> 2 : 0;
    final effectiveThreshold = electrolysisThreshold - chargeAssist;
    if (myVolt > effectiveThreshold && (elCategory[el] & ElCat.liquid) != 0) {
      // Probability: higher reactivity = more likely to split
      // react 60 -> 1/28, react 220 -> 1/10
      final prob = 40 - (react >> 3); // 40 - react/8
      final clampedProb = prob > 3 ? prob : 3;
      if (rng.nextInt(clampedProb) == 0) {
        // Determine products from element's reduction potential
        final reducesTo = elementReducesInto[el];
        if (reducesTo != 0) {
          // Reduce: e.g. rust + voltage -> metal
          grid[idx] = reducesTo;
        } else {
          // Default: split into oxygen
          grid[idx] = El.oxygen;
        }
        life[idx] = 0;
        oxidation[idx] = 128;
        moisture[idx] = 0;
        voltage[idx] = 0;
        sparkTimer[idx] = 0;
        markDirty(x, y);
        unsettleNeighbors(x, y);
        // Spawn hydrogen above if space (only for water-like elements)
        if (el == El.water) {
          final aboveY = y - gravityDir;
          if (inBoundsY(aboveY)) {
            final aboveIdx = aboveY * gridW + x;
            if (grid[aboveIdx] == El.empty) {
              grid[aboveIdx] = El.hydrogen;
              life[aboveIdx] = 0;
              markDirty(x, aboveY);
            }
          }
        }
        queueReactionFlash(x, y, 100, 200, 255, 3);
      }
    }
  }

  // =========================================================================
  // pH, Dissolved Substances, and Charge Step
  // =========================================================================

  /// Process pH assignment, diffusion, dissolved substance effects, and
  /// charge accumulation/decay for a single cell.
  ///
  /// pH values: 0 = extremely acidic (pH ~0), 128 = neutral (pH 7),
  /// 255 = extremely alkaline (pH ~14).
  /// Called per dirty-chunk cell every 4 frames for performance.
  @pragma('vm:prefer-inline')
  void pHAndChargeStep(int x, int y, int idx) {
    final el = grid[idx];
    if (el == El.empty || el >= maxElements) return;

    // -- pH ASSIGNMENT --
    // Certain elements enforce their intrinsic pH on the cell.
    // Acid: very acidic (pH ~1.1), Water: neutral (pH 7),
    // Ash: alkaline (pH ~11), Compost: slightly acidic (pH ~6.5).
    if (el == El.acid) {
      pH[idx] = 20;
    } else if (el == El.water) {
      // Water starts neutral but can be shifted by dissolved substances
      final dissolved = dissolvedType[idx];
      if (dissolved == El.co2) {
        // Carbonic acid: pH drops proportional to concentration
        // conc 30->~115, conc 200->~68
        final conc = concentration[idx];
        final acidShift = conc >> 2; // 0..63
        final newPH = 128 - acidShift;
        pH[idx] = newPH > 0 ? newPH : 0;
      } else if (dissolved == 0) {
        // Pure water drifts toward neutral
        final curPH = pH[idx];
        if (curPH < 126) {
          pH[idx] = curPH + 1;
        } else if (curPH > 130) {
          pH[idx] = curPH - 1;
        }
      }
      // Salty water: pH stays near neutral (salt is neutral)
    } else if (el == El.ash) {
      pH[idx] = 200;
    } else if (el == El.compost) {
      pH[idx] = 115;
    }

    // -- pH DIFFUSION --
    // pH spreads to neighbors slowly (every 4 frames, 1/4 the rate of temp).
    // Only diffuse from cells with strong pH signal (far from neutral).
    final myPH = pH[idx];
    final phDist = myPH > 128 ? myPH - 128 : 128 - myPH; // distance from neutral
    if (phDist > 10) {
      // Pick one random neighbor to diffuse to (cheap, avoids 8-neighbor loop)
      final ndx = rng.nextInt(3) - 1; // -1, 0, 1
      final ndy = rng.nextInt(3) - 1;
      if (ndx != 0 || ndy != 0) {
        final nx = (x + ndx + gridW) % gridW;
        final ny = y + ndy;
        if (ny >= 0 && ny < gridH) {
          final ni = ny * gridW + nx;
          final ne = grid[ni];
          if (ne != El.empty && ne < maxElements) {
            final neighborPH = pH[ni];
            // Move neighbor pH 1 step toward this cell's pH
            if (myPH > neighborPH + 2) {
              pH[ni] = neighborPH + 1;
            } else if (myPH < neighborPH - 2) {
              pH[ni] = neighborPH - 1;
            }
          }
        }
      }
    }

    // -- NEUTRALIZATION: acid adjacent to ash --
    // Both pH values shift toward 128 (neutral).
    if (el == El.acid) {
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = (x + dx + gridW) % gridW;
          final ny = y + dy;
          if (ny < 0 || ny >= gridH) continue;
          final ni = ny * gridW + nx;
          if (grid[ni] == El.ash) {
            // Shift both toward neutral by 4 per step
            final acidPH = pH[idx];
            final ashPH = pH[ni];
            pH[idx] = acidPH < 124 ? acidPH + 4 : 128;
            pH[ni] = ashPH > 132 ? ashPH - 4 : 128;
            markDirty(nx, ny);
            break; // One neutralization per step
          }
        }
      }
    }

    // -- DISSOLVED SUBSTANCE EFFECTS --
    // Dissolved salt in water boosts effective conductivity.
    // This is handled in electricityStep via concentration check.
    // Dissolved CO2 lowers pH (handled above in pH assignment).

    // When water evaporates (becomes steam), deposits are left behind
    // in the evaporation code in simWater. This step handles concentration
    // decay for non-liquid cells (shouldn't have dissolved stuff).
    if ((elCategory[el] & ElCat.liquid) == 0 && concentration[idx] > 0) {
      // Non-liquids lose dissolved substances
      concentration[idx] = 0;
      dissolvedType[idx] = 0;
    }

    // Saturation cap
    if (concentration[idx] > 200) {
      concentration[idx] = 200;
    }

    // -- CHARGE ACCUMULATION AND DECAY --
    // Charge accumulates from voltage flow (set in electricityStep).
    // Decays slowly toward 0.
    final ch = charge[idx];
    if (ch != 0) {
      // Decay: 1 unit every step toward 0
      if (ch > 0) {
        charge[idx] = ch - 1;
      } else {
        charge[idx] = ch + 1;
      }
    }

    // High voltage on this cell adds charge
    final v = voltage[idx];
    if (v.abs() > 10) {
      final addCharge = v >> 3; // voltage/8
      final newCharge = ch + addCharge;
      charge[idx] = newCharge.clamp(-128, 127);
    }
  }

  // =========================================================================
  // Chemistry + Electricity pass over dirty chunks
  // =========================================================================

  /// Run chemistry on all active cells in dirty chunks.
  void runChemistryPass() {
    final w = gridW;
    final h = gridH;
    final g = grid;
    final dc = dirtyChunks;
    final cols = chunkCols;

    for (int y = 0; y < h; y++) {
      final chunkY = y >> 4;
      for (int x = 0; x < w; x++) {
        final chunkIdx = chunkY * cols + (x >> 4);
        if (dc[chunkIdx] == 0) continue;
        final idx = y * w + x;
        if (g[idx] == El.empty) continue;
        chemistryStep(x, y, idx);
      }
    }
  }

  /// Run pH, dissolved substances, and charge on all dirty-chunk cells.
  /// Called every 4 frames for performance.
  void runPHAndChargePass() {
    final w = gridW;
    final h = gridH;
    final g = grid;
    final dc = dirtyChunks;
    final cols = chunkCols;

    for (int y = 0; y < h; y++) {
      final chunkY = y >> 4;
      for (int x = 0; x < w; x++) {
        final chunkIdx = chunkY * cols + (x >> 4);
        if (dc[chunkIdx] == 0) continue;
        final idx = y * w + x;
        if (g[idx] == El.empty) continue;
        pHAndChargeStep(x, y, idx);
      }
    }
  }

  /// Run electricity on all conductive cells in dirty chunks.
  void runElectricityPass() {
    final w = gridW;
    final h = gridH;
    final g = grid;
    final dc = dirtyChunks;
    final cols = chunkCols;

    for (int y = 0; y < h; y++) {
      final chunkY = y >> 4;
      for (int x = 0; x < w; x++) {
        final chunkIdx = chunkY * cols + (x >> 4);
        if (dc[chunkIdx] == 0) continue;
        final idx = y * w + x;
        final el = g[idx];
        if (el == El.empty || el >= maxElements) continue;
        // Only process cells with any conductivity
        if (elementElectronMobility[el] > 0 || moisture[idx] > 20) {
          electricityStep(x, y, idx);
        }
      }
    }
  }

  // =========================================================================
  // Vibration propagation
  // =========================================================================

  /// Propagate vibration through solid cells. Called every 2 frames.
  /// Vibration spreads through solids based on hardness, decays each step.
  void updateVibration() {
    final w = gridW;
    final h = gridH;
    final g = grid;
    final dc = dirtyChunks;
    final cols = chunkCols;
    final vib = vibration;
    final vFreq = vibrationFreq;
    final hard = elementHardness;

    for (int y = 0; y < h; y++) {
      final chunkY = y >> 4;
      for (int x = 0; x < w; x++) {
        final chunkIdx = chunkY * cols + (x >> 4);
        if (dc[chunkIdx] == 0) continue;
        final idx = y * w + x;
        final v = vib[idx];
        if (v == 0) continue;
        final el = g[idx];
        if (el == El.empty) { vib[idx] = 0; continue; }

        // Spread to solid cardinal neighbors
        final myHardness = el < maxElements ? hard[el] : 0;
        if (myHardness > 0) {
          // Check 4 cardinal neighbors
          final above = y > 0 ? (y - 1) * w + x : -1;
          final below = y < h - 1 ? (y + 1) * w + x : -1;
          final left = y * w + ((x - 1 + w) % w);
          final right = y * w + ((x + 1) % w);

          // Propagation factor: (vibration * neighborHardness) >> 10
          for (final ni in [above, below, left, right]) {
            if (ni < 0) continue;
            final ne = g[ni];
            if (ne == El.empty) continue;
            final nh = ne < maxElements ? hard[ne] : 0;
            if (nh == 0) continue; // only propagates through solids
            final spread = (v * nh) >> 10;
            if (spread > 0) {
              final nv = vib[ni] + spread;
              vib[ni] = nv < 255 ? nv : 255;
              // Propagate frequency
              if (vFreq[ni] == 0) vFreq[ni] = vFreq[idx];
            }
          }
        }

        // Decay: vibration * 240 >> 8 (loses ~6% per step)
        final decayed = (v * 240) >> 8;
        vib[idx] = decayed;
        if (decayed == 0) vFreq[idx] = 0;

        // High vibration on weak structures causes collapse
        if (v > 200) {
          final bond = el < maxElements ? elementBondEnergy[el] : 255;
          if (bond < 50 && rng.nextInt(4) == 0) {
            // Structural collapse: weak element crumbles
            if (el == El.stone || el == El.dirt || el == El.mud) {
              grid[idx] = El.sand;
              life[idx] = 0;
              mass[idx] = elementBaseMass[El.sand];
              vib[idx] = 0;
              vFreq[idx] = 0;
              markDirty(x, y);
              unsettleNeighbors(x, y);
            }
          }
        }
      }
    }
  }

  // =========================================================================
  // Structural Support / Cantilever Physics
  // =========================================================================

  /// Propagates structural support from anchored elements (bedrock).
  /// Replaces the slow global Chunk finding with O(1) local propagation.
  /// Called every 2 frames.
  void updateSupport() {
    final w = gridW;
    final h = gridH;
    final g = grid;
    final sup = support;
    final dc = dirtyChunks;
    final cols = chunkCols;

    for (int y = h - 1; y >= 0; y--) {
      final chunkY = y >> 4;
      for (int x = 0; x < w; x++) {
        final chunkIdx = chunkY * cols + (x >> 4);
        if (dc[chunkIdx] == 0) continue;
        
        final idx = y * w + x;
        final el = g[idx];

        if (el == El.empty) {
          sup[idx] = 0;
          continue;
        }

        final state = el < maxElements ? elementPhysicsState[el] : 0;
        
        // Granular, liquid, and gas elements provide zero cantilever support
        if (state != PhysicsState.solid.index && state != PhysicsState.special.index) {
          sup[idx] = 0;
          continue;
        }

        // Anchors provide maximum support
        if (el == El.bedrock || (el == El.dirt && y == h - 1)) {
          sup[idx] = 255;
          continue;
        }

        // Structural elements pass support. Hardness determines how far they can stretch.
        int bestNeighborSupport = 0;
        
        final below = y < h - 1 ? (y + 1) * w + x : -1;
        final left = y * w + wrapX(x - 1);
        final right = y * w + wrapX(x + 1);
        final above = y > 0 ? (y - 1) * w + x : -1;

        // Support flows mostly from below and sides
        if (below >= 0 && sup[below] > bestNeighborSupport) bestNeighborSupport = sup[below];
        if (sup[left] > bestNeighborSupport) bestNeighborSupport = sup[left];
        if (sup[right] > bestNeighborSupport) bestNeighborSupport = sup[right];
        // Hanging support is weaker (requires stronger bonds)
        if (above >= 0 && sup[above] > bestNeighborSupport) bestNeighborSupport = sup[above];

        // Decay per tile based on material hardness
        // Hardness 100 (metal) -> decay 3 (can build ~80 tiles out)
        // Hardness 50 (stone) -> decay 10 (can build ~25 tiles out)
        // Hardness 20 (wood) -> decay 20 (can build ~12 tiles out)
        final hardness = el < maxElements ? elementHardness[el] : 10;
        final decay = ((120 - hardness) / 5).clamp(1, 50).toInt();
        
        final newSupport = bestNeighborSupport > decay ? bestNeighborSupport - decay : 0;
        sup[idx] = newSupport;

        // If support hits 0 and it's a rigid body, it snaps and falls
        if (newSupport == 0 && state == PhysicsState.solid.index) {
           velY[idx] = (velY[idx] + 1).clamp(0, 127).toInt();
           // Small chance to crumble from stress
           if (rng.nextInt(20) == 0) {
              if (el == El.stone) grid[idx] = El.dirt;
              else if (el == El.wood) grid[idx] = El.sand;
           }
        }
      }
    }
  }

  // =========================================================================
  // Stress accumulation
  // =========================================================================

  /// Accumulate structural stress from weight above. Called every 4 frames.
  /// Stress = cumulative mass of cells above in the column.
  void updateStress() {
    final w = gridW;
    final h = gridH;
    final g = grid;
    final dc = dirtyChunks;
    final cols = chunkCols;
    final st = stress;
    final m = mass;
    final bond = elementBondEnergy;

    // Scan columns top-to-bottom (gravity dir = 1)
    for (int x = 0; x < w; x++) {
      int accumulated = 0;
      for (int y = 0; y < h; y++) {
        final chunkIdx = (y >> 4) * cols + (x >> 4);
        if (dc[chunkIdx] == 0) {
          // Reset accumulation through non-dirty region
          accumulated = 0;
          continue;
        }
        final idx = y * w + x;
        final el = g[idx];
        if (el == El.empty) {
          accumulated = 0;
          st[idx] = 0;
          continue;
        }
        final cellMass = m[idx];
        accumulated = accumulated + cellMass;
        if (accumulated > 255) accumulated = 255;
        st[idx] = accumulated;

        // Structural failure: stress exceeds bondEnergy * 2
        if (el < maxElements) {
          final threshold = bond[el] << 1; // bondEnergy * 2
          if (accumulated > threshold && threshold > 0 && rng.nextInt(8) == 0) {
            // Crumble based on element type
            if (el == El.stone) {
              g[idx] = El.dirt;
              life[idx] = 0;
              m[idx] = elementBaseMass[El.dirt];
              markDirty(x, y);
              unsettleNeighbors(x, y);
            } else if (el == El.ice) {
              g[idx] = El.water;
              life[idx] = 100;
              m[idx] = elementBaseMass[El.water];
              markDirty(x, y);
              unsettleNeighbors(x, y);
            }
          }
        }
      }
    }
  }

  // =========================================================================
  // Wind field update
  // =========================================================================

  /// Update per-cell wind field with Perlin-like variation. Called every 30 frames.
  /// Base wind from global windForce, local variation from hash.
  @pragma('vm:prefer-inline')
  static int _windHash(int x, int y, int t) {
    // Fast integer hash for wind variation
    int h = x * 374761393 + y * 668265263 + t * 1274126177;
    h = (h ^ (h >> 13)) * 1103515245;
    return h;
  }

  void updateWindField() {
    final w = gridW;
    final h = gridH;
    final g = grid;
    final dc = dirtyChunks;
    final cols = chunkCols;
    final wx = windX2;
    final wy = windY2;
    final globalW = windForce;
    final t = frameCount ~/ 30; // changes every 30 frames

    for (int y = 0; y < h; y++) {
      final chunkY = y >> 4;
      for (int x = 0; x < w; x++) {
        final chunkIdx = chunkY * cols + (x >> 4);
        if (dc[chunkIdx] == 0) continue;
        final idx = y * w + x;

        // Terrain blocks wind: solid cells get zero wind
        final el = g[idx];
        if (el != El.empty) {
          final state = el < maxElements ? elementPhysicsState[el] : 0;
          if (state == PhysicsState.solid.index) {
            wx[idx] = 0;
            wy[idx] = 0;
            continue;
          }
        }

        // Base wind + hash variation
        final hash = _windHash(x, y, t);
        // Variation range: -3 to +3
        final varX = ((hash & 0x7) - 3);
        final varY = (((hash >> 3) & 0x7) - 3);

        // Check for solid terrain behind (upwind) reducing wind
        int shelter = 0;
        final windDir = globalW > 0 ? -1 : 1;
        for (int d = 1; d <= 3; d++) {
          final checkX = (x + windDir * d + w) % w;
          final checkEl = g[y * w + checkX];
          if (checkEl != El.empty) {
            final checkState = checkEl < maxElements ? elementPhysicsState[checkEl] : 0;
            if (checkState == PhysicsState.solid.index) {
              shelter += 2;
            }
          }
        }

        final effectiveWind = globalW > 0
            ? (globalW - shelter > 0 ? globalW - shelter : 0)
            : (globalW + shelter < 0 ? globalW + shelter : 0);

        final localX = effectiveWind + varX;
        final localY = varY >> 1; // vertical wind is weaker
        wx[idx] = localX.clamp(-127, 127);
        wy[idx] = localY.clamp(-127, 127);
      }
    }
  }

  /// Increment cellAge for all non-empty cells in dirty chunks.
  void updateCellAge() {
    final w = gridW;
    final h = gridH;
    final g = grid;
    final dc = dirtyChunks;
    final cols = chunkCols;
    final age = cellAge;

    for (int y = 0; y < h; y++) {
      final chunkY = y >> 4;
      for (int x = 0; x < w; x++) {
        final chunkIdx = chunkY * cols + (x >> 4);
        if (dc[chunkIdx] == 0) continue;
        final idx = y * w + x;
        if (g[idx] != El.empty) {
          final a = age[idx];
          if (a < 255) age[idx] = a + 1;
        }
      }
    }
  }

  // =========================================================================
  // Light emission + luminance
  // =========================================================================

  /// Write lightR/G/B for emitting cells in dirty chunks.
  /// Called every 4 frames from the game loop.
  void updateLightEmission() {
    final w = gridW;
    final h = gridH;
    final g = grid;
    final dc = dirtyChunks;
    final cols = chunkCols;
    final lr = lightR;
    final lg = lightG;
    final lb = lightB;
    final temp = temperature;
    final st = sparkTimer;

    for (int y = 0; y < h; y++) {
      final chunkY = y >> 4;
      for (int x = 0; x < w; x++) {
        final chunkIdx = chunkY * cols + (x >> 4);
        if (dc[chunkIdx] == 0) continue;
        final idx = y * w + x;
        final el = g[idx];

        if (el == El.empty) {
          lr[idx] = 0;
          lg[idx] = 0;
          lb[idx] = 0;
          continue;
        }

        final emission = elementLightEmission[el];

        // Electrical sparks: white light
        if (st[idx] == 1) {
          lr[idx] = 200;
          lg[idx] = 220;
          lb[idx] = 255;
          continue;
        }

        // Hot cells: incandescent glow
        final t = temp[idx];
        if (t > 200) {
          final heat = t - 200; // 0-55
          final rRaw = heat << 2;
          final r = rRaw < 255 ? rRaw : 255;
          final gvRaw = heat << 1;
          final gv = gvRaw < 255 ? gvRaw : 255;
          // Combine with element's own emission (take max)
          lr[idx] = r > elementLightR[el] ? r : elementLightR[el];
          lg[idx] = gv > elementLightG[el] ? gv : elementLightG[el];
          lb[idx] = elementLightB[el];
          continue;
        }

        // Normal element emission
        if (emission > 0) {
          lr[idx] = elementLightR[el];
          lg[idx] = elementLightG[el];
          lb[idx] = elementLightB[el];
        } else {
          lr[idx] = 0;
          lg[idx] = 0;
          lb[idx] = 0;
        }
      }
    }
  }

  /// Compute luminance for each cell from nearby light emitters.
  /// Called every 8 frames from the game loop. Used by plants, fungi, creatures.
  void updateLuminance() {
    final w = gridW;
    final h = gridH;
    final g = grid;
    final lr = lightR;
    final lg = lightG;
    final lb = lightB;
    final lum = luminance;
    final night = isNight;
    // Base luminance for surface cells from day/night cycle
    final baseLum = night ? 30 : 200;

    // Simple approach: scan radius 8 for emitters, accumulate weighted by distance.
    // For performance, only process dirty chunks.
    final dc = dirtyChunks;
    final cols = chunkCols;

    for (int cy = 0; cy < h; cy++) {
      final chunkY = cy >> 4;
      for (int cx = 0; cx < w; cx++) {
        final chunkIdx = chunkY * cols + (cx >> 4);
        if (dc[chunkIdx] == 0) continue;
        final idx = cy * w + cx;

        // Surface detection: is there open sky above this cell?
        // Scan upward for the first non-empty, non-gas cell
        bool isSurface = false;
        for (int sy = cy - 1; sy >= 0 && sy >= cy - 20; sy--) {
          final above = g[sy * w + cx];
          if (above == El.empty || above == El.oxygen || above == El.co2 ||
              above == El.smoke || above == El.steam || above == El.methane ||
              above == El.hydrogen) {
            continue;
          }
          // Hit a solid/liquid — not surface
          break;
        }
        // If we scanned all the way without hitting anything solid, it's surface
        if (cy <= 20 || g[0 * w + cx] == El.empty) {
          // Simple heuristic: check if sky column above is mostly empty
          int emptyCount = 0;
          int scanTop = cy - 20; if (scanTop < 0) scanTop = 0;
          for (int sy = cy - 1; sy >= scanTop; sy--) {
            if (g[sy * w + cx] == El.empty) emptyCount++;
          }
          isSurface = emptyCount > (cy - scanTop) ~/ 2;
        }

        // Accumulate light from nearby emitters
        int accum = 0;
        const radius = 8;
        final hm1 = h - 1;
        final wm1 = w - 1;
        int yMin = cy - radius; if (yMin < 0) yMin = 0;
        int yMax = cy + radius; if (yMax > hm1) yMax = hm1;
        int xMin = cx - radius; if (xMin < 0) xMin = 0;
        int xMax = cx + radius; if (xMax > wm1) xMax = wm1;

        for (int ey = yMin; ey <= yMax; ey++) {
          final dy = ey - cy; final ady = dy < 0 ? -dy : dy;
          final rowBase = ey * w;
          for (int ex = xMin; ex <= xMax; ex++) {
            final eidx = rowBase + ex;
            final r = lr[eidx];
            final gv = lg[eidx];
            final b = lb[eidx];
            if ((r | gv | b) == 0) continue;
            final dx = ex - cx; final adx = dx < 0 ? -dx : dx;
            final dist = ady > adx ? ady : adx; // Chebyshev distance
            if (dist == 0) continue;
            // Perceived brightness: approximate (r+g+b)/3 weighted by 1/dist
            final brightness = (r + gv + b) ~/ 3;
            accum += brightness ~/ dist;
          }
        }

        // Combine: surface gets base daylight, underground relies on emitters
        int finalLum;
        if (isSurface) {
          finalLum = baseLum + (accum > 55 ? 55 : accum);
        } else {
          finalLum = accum;
        }
        if (finalLum > 255) finalLum = 255;
        lum[idx] = finalLum;
      }
    }
  }

  // =========================================================================
  // Main simulation step
  // =========================================================================

  /// Process a specific vertical slice of the grid.
  /// Used for parallelized processing.
  void _processSlice(int startX, int endX, bool leftToRight, int currentClockBit, 
                    void Function(SimulationEngine engine, int el, int x, int y, int idx) simulateElement) {
    final yStart = gravityDir == 1 ? gridH - 1 : 0;
    final yEnd = gravityDir == 1 ? -1 : gridH;
    final yStep = gravityDir == 1 ? -1 : 1;
    final dc = dirtyChunks;
    final cols = chunkCols;
    final w = gridW;

    for (int y = yStart; y != yEnd; y += yStep) {
      final chunkY = y >> 4;
      final rowXStart = leftToRight ? startX : endX - 1;
      final rowXEnd = leftToRight ? endX : startX - 1;
      final dx = leftToRight ? 1 : -1;

      for (int x = rowXStart; x != rowXEnd; x += dx) {
        final chunkIdx = chunkY * cols + (x >> 4);
        if (dc[chunkIdx] == 0) continue;

        final idx = y * w + x;
        final flagVal = flags[idx];
        if ((flagVal & 0x80) == currentClockBit) continue;

        final el = grid[idx];
        if (el == El.empty) continue;

        if ((flagVal & 0x40) != 0) {
          if (neverSettle[el] != 0) {
            flags[idx] = flagVal & 0x80;
          } else {
            continue;
          }
        }

        final preEl = el;
        final preIdx = idx;
        final preLife = life[idx];

        simulateElement(this, el, x, y, idx);

        if (grid[preIdx] == preEl && (flags[preIdx] & 0x80) != currentClockBit) {
          if (life[preIdx] != preLife) {
            flags[preIdx] = flags[preIdx] & 0x80;
            markDirty(x, y);
          } else {
            final oldStable = (flagVal >> 4) & 0x03;
            final newStable = (oldStable + 1).clamp(0, 3);
            if (newStable >= 3) {
              flags[preIdx] = (flags[preIdx] & 0x80) | 0x70;
            } else {
              flags[preIdx] = (flags[preIdx] & 0x80) | (newStable << 4);
            }
            markDirty(x, y);
          }
        } else if (grid[preIdx] != preEl) {
          markDirty(x, y);
          unsettleNeighbors(x, y);
        }
      }
    }
  }

  /// Run one frame of physics simulation.
  void step(void Function(SimulationEngine engine, int el, int x, int y, int idx) simulateElement) {
    simClock = !simClock;
    final currentClockBit = simClock ? 0x80 : 0;

    processExplosions();

    if (windForce != 0 && frameCount % 2 == 0) applyWind();
    if (frameCount % 3 == 0) updateTemperature();
    if (frameCount % 4 == 0) updatePressure();
    if (frameCount % 4 == 0) runPHAndChargePass();
    if (frameCount % 2 == 0) updateVibration();
    if (frameCount % 4 == 0) updateStress();
    if (frameCount % 2 == 0) updateSupport();
    if (frameCount % 30 == 0) updateWindField();

    rainbowHue = (rainbowHue + 3) % 360;
    if (lightningFlashFrames > 0) lightningFlashFrames--;

    final leftToRight = frameCount.isEven;

    if (parallelUpdate && numSlices > 1) {
      // PHASE 9: Parallel Grid Slicing
      // In a real multi-isolate environment, we would dispatch to worker isolates.
      // Here we simulate the logic for a multi-threaded pass.
      final sWidth = gridW ~/ numSlices;
      for (int i = 0; i < numSlices; i++) {
        final startX = i * sWidth;
        final endX = (i == numSlices - 1) ? gridW : (i + 1) * sWidth;
        _processSlice(startX, endX, leftToRight, currentClockBit, simulateElement);
      }
    } else {
      _processSlice(0, gridW, leftToRight, currentClockBit, simulateElement);
    }

    final tmp = dirtyChunks;
    dirtyChunks = nextDirtyChunks;
    nextDirtyChunks = tmp;
    nextDirtyChunks.fillRange(0, nextDirtyChunks.length, 0);

    frameCount++;
  }
}

// ---------------------------------------------------------------------------
// SimTuning -- Centralized tuning parameters for all simulation probabilities
// ---------------------------------------------------------------------------

/// Every probability, rate, and threshold in the physics engine is stored here.
/// Optuna searches this parameter space to find optimal values.
/// All rates are 1/N chance per eligible tick unless otherwise noted.
class SimTuning {
  // -- Sand --
  static int sandToMudRate = 10;             // 1/N surface sand->mud with water
  static int sandToMudSubmergedRate = 80;    // 1/N submerged sand->mud (slower)

  // -- Water --
  static int waterTntDissolve = 10;          // 1/N dissolve TNT
  static int waterSmokeDissolve = 10;        // 1/N dissolve smoke
  static int waterRainbowSpread = 40;        // 1/N spread rainbow
  static int waterPlantDamage = 20;          // 1/N damage plant
  static int waterAcidPlantDamage = 10;      // 1/N acidic water damages plant
  static int waterBubbleRate = 500;          // 1/N spawn bubble at high mass
  static int waterPressurePush = 8;          // 1/N push sand/dirt sideways
  static int waterMomentumReset = 4;         // 1/N velocity resets
  static int waterDirtErosion = 20;          // 1/N erode dirt
  static int waterSandErosion = 30;          // 1/N erode sand
  static int waterSedimentDeposit = 40;      // 1/N deposit sediment
  static int waterSeepageRate = 12;          // 1/N underground seepage
  static int waterHydraulicRate = 3;         // 1/N hydraulic displacement
  static int waterStoneExit = 6;             // 1/N pressurized stone exit

  // -- Fire --
  static int fireOxygenConsume = 3;          // 1/N consume oxygen
  static int fireOilLifetimeBase = 70;       // base ticks near oil
  static int fireOilLifetimeVar = 50;        // variance near oil
  static int fireLifetimeBase = 40;          // base ticks
  static int fireLifetimeVar = 40;           // variance
  static int fireBurnoutSmoke = 3;           // N-1/N become smoke (2/3)
  static int firePlantIgnite = 2;            // 1/N ignite plant/seed
  static int fireOilChainIgnite = 3;         // 1/N chain ignite oil
  static int fireWoodPyrolysis = 3;          // 1/N start wood charring
  static int fireFlicker = 6;               // flicker range (0-5)
  static int fireLateralShimmy = 5;          // 1/N lateral move when trapped

  // -- Ice --
  static int iceRegelation = 4;              // 1/N regelation melt
  static int iceAmbientMeltDay = 20;         // 1/N ambient melt (day)
  static int iceAmbientMeltNight = 60;       // 1/N ambient melt (night)

  // -- Lightning --
  static int lightningElectrolysis = 3;      // 1/N water->bubble
  static int lightningOilChain = 3;          // 1/N chain ignite oil

  // -- Dirt --
  static int dirtAshAbsorb = 10;             // 1/N absorb ash
  static int dirtWaterErosionBase = 10;      // 1/N water erosion check
  static int dirtFlowingErosion = 8;         // 1/N flowing water erosion
  static int dirtCompactRate = 10;           // alias for backward compat

  // -- Plant --
  static int plantAcidDamage = 3;            // 1/N acid damage
  static int plantDecomposeRate = 10;        // 1/N decompose to compost with fungus
  static int plantO2Produce = 8;             // 1/N produce oxygen
  static int plantSeedRateYoung = 500;       // 1/N seed (young mature)
  static int plantSeedRateOld = 200;         // 1/N seed (aged mature)
  static int plantGrassSpread = 40;          // 1/N grass lateral spread
  static int plantMushroomSpread = 80;       // 1/N mushroom colony spread
  static int plantTreeBranch = 3;            // 1/N tree branch at wide canopy
  static int plantTreeRootGrow = 50;         // 1/N tree root growth
  static int plantTreeBranchSkip = 2;        // 1/N skip branch side

  // -- Lava --
  static int lavaCoolingBase = 200;          // base cooling threshold
  static int lavaCoolingVar = 50;            // cooling variance
  static int lavaCoolIsolated = 80;          // isolated base
  static int lavaCoolIsolatedVar = 30;       // isolated variance
  static int lavaCoolPartial = 140;          // partial base
  static int lavaCoolPartialVar = 40;        // partial variance
  static int lavaSmokeEmit = 80;             // 1/N smoke emission
  static int lavaSteamEmit = 120;            // 1/N steam emission
  static int lavaEruptionOpen = 60;          // 1/N eruption (low pressure)
  static int lavaEruptionPressured = 30;     // 1/N eruption (high pressure)
  static int lavaEruptThreshLow = 20;        // eruption threshold (low pressure)
  static int lavaEruptThreshHigh = 10;       // eruption threshold (high pressure)
  static int lavaSpatter = 100;              // 1/N spatter
  static int lavaIgniteFlammable = 2;        // 1/N ignite plant/oil/wood/seed
  static int lavaSandToGlass = 40;           // 1/N sand->glass
  static int lavaMeltMetal = 80;             // 1/N melt metal
  static int lavaDryMud = 10;               // 1/N mud->dirt
  static int lavaGasEmit = 100;              // 1/N gas emission (legacy)

  // -- Snow --
  static int snowMeltRateDay = 20;           // 1/N proximity melt rate (day)
  static int snowMeltRateNight = 40;         // 1/N proximity melt rate (night)
  static int snowFreezeWater = 30;           // 1/N freeze adjacent water
  static int snowAvalanche = 3;              // 1/N avalanche check
  static int snowWindDrift = 2;              // 1/N wind-driven drift

  // -- Wood --
  static int woodFireSpread = 12;            // 1/N fire spread to adjacent
  static int woodBurnoutBase = 40;           // base ticks before burnout
  static int woodBurnoutVar = 20;            // burnout variance
  static int woodCharcoalChance = 5;         // N<2 = charcoal, else ash
  static int woodAnoxicPyrolysis = 60;       // 1/N anoxic pyrolysis
  static int woodWaterAbsorb = 30;           // 1/N water absorption
  static int woodWetBurn = 5;               // 1/N burn when waterlogged
  static int woodPetrify = 80;              // 1/N petrification

  // -- Metal --
  static int metalFallResist = 30;           // 1/N start falling when unsupported
  static int metalRustRate = 500;            // 1/N rust in water (base)
  static int metalSaltRustRate = 100;        // 1/N rust in salt water
  static int metalSaltRustAlkaline = 300;    // 1/N salt rust (alkaline)
  static int metalHotIgniteRate = 6;         // 1/N hot metal ignites flammables
  static int metalHotWoodChar = 10;          // 1/N hot metal chars wood
  static int metalCondensation = 100;        // 1/N condensation

  // -- Smoke --
  static int smokeLateralDrift = 3;          // 1/N lateral drift

  // -- Bubble --
  static int bubbleWobble = 20;              // 1/N lateral wobble

  // -- Ash --
  static int ashLateralDrift = 3;            // 1/N lateral drift in water
  static int ashAvalanche = 3;               // 1/N avalanche

  // -- Mud --
  static int mudContactDry = 4;              // 1/N contact drying near fire
  static int mudProximityDry = 40;           // 1/N proximity drying

  // -- Steam --
  static int steamAltitudeRain = 5;          // 1/N condense at sky edge
  static int steamDeposition = 3;            // 1/N deposit as ice
  static int steamIceCondense = 4;           // N-1/N condense on ice (3/4)
  static int steamTrappedSeep = 40;          // 1/N seep through cracks

  // -- Oil --
  // (no standalone magic numbers — ignition handled by fire/lava)

  // -- Acid --
  static int acidLifetimeBase = 200;         // base life before expiry
  static int acidLifetimeVar = 60;           // variance
  static int acidWaterDilute = 8;            // 1/N dilute in water
  static int acidIceMelt = 8;               // 1/N melt ice
  static int acidSnowMelt = 5;              // 1/N melt snow
  static int acidLavaReact = 5;             // 1/N react with lava
  static int acidWaterBubble = 20;           // 1/N produce bubble in water

  // -- Stone --
  static int stoneThinSupport = 60;          // 1/N thin support crumble
  static int stoneNoLateralFall = 8;         // 1/N fall without diagonal support
  static int stoneWeatherWater = 60;         // 1/N water weathering
  static int stoneWeatherCrumble = 20;       // 1/N crumble when fully weathered
  static int stoneFrostWeather = 20;         // 1/N frost weathering
  static int stoneFrostCrumble = 15;         // 1/N frost crumble
  static int stoneLavaCrack = 200;           // 1/N crack into lava

  // -- Glass --
  static int glassLavaMeltBase = 80;         // base life near lava before melt
  static int glassLavaMeltVar = 40;          // variance
  static int glassThermalShatter = 3;        // 1/N probabilistic thermal shatter

  // -- Avalanche --
  static int avalancheStandard = 3;          // N-1/N chance (2/3 standard)
  static int avalancheExtended = 4;          // 1/N extended roll

  // -- Fungus --
  static int fungusDeathToCompost = 20;      // 1/N die to compost when dry
  static int fungusAshDecompose = 5;         // 1/N convert ash to compost
  static int fungusWoodRot = 80;             // 1/N decompose wood
  static int fungusDirtSpread = 40;          // 1/N spread to dirt
  static int fungusSporulate = 200;          // 1/N release spore
  static int fungusMethane = 300;            // 1/N produce methane

  // -- Spore --
  static int sporeFallRate = 3;              // 1/N slow fall
  static int sporeDriftRate = 2;             // 1/N lateral drift

  // -- Compost --
  static int compostDryToDirt = 100;         // 1/N become dirt when dry
  static int compostNutrient = 100;          // 1/N nutrient diffusion
  static int compostMethane = 400;           // 1/N produce methane

  // -- Rust --
  static int rustCrumble = 50;              // 1/N crumble under weight

  // -- Methane --
  static int methaneLateralDrift = 2;        // 1/N lateral drift

  // -- Salt --
  static int saltDissolveRate = 5;           // 1/N dissolve in water
  static int saltDeiceRate = 15;             // 1/N melt ice
  static int saltPlantKill = 30;             // 1/N damage plant

  // -- Algae --
  static int algaeGrowRate = 10;             // 1/N spread
  static int algaeO2Rate = 40;              // 1/N produce oxygen
  static int algaeCO2Absorb = 10;           // 1/N absorb CO2
  static int algaeBloomDieoff = 50;          // 1/N overpopulation death
  static int algaeBloomThreshold = 12;       // nearby algae count for bloom

  // -- Seaweed --
  static int seaweedO2Rate = 30;             // 1/N produce oxygen
  static int seaweedCO2Absorb = 8;           // 1/N absorb CO2
  static int seaweedBloomDieoff = 60;        // 1/N overpopulation death
  static int seaweedBloomThreshold = 14;     // nearby count for die-off

  // -- Moss --
  static int mossO2Rate = 60;               // 1/N produce oxygen
  static int mossCO2Absorb = 15;            // 1/N absorb CO2

  // -- Vine --
  static int vineAcidDamage = 3;            // 1/N acid damage
  static int vineO2Rate = 5;               // 1/N produce oxygen

  // -- Flower --
  static int flowerAcidDamage = 3;          // 1/N acid damage
  static int flowerO2Rate = 6;             // 1/N produce oxygen

  // -- Honey --
  static int honeyCrystallize = 50;          // 1/N crystallize at max life
  static int honeyCrystallizeLife = 250;     // life threshold

  // -- Hydrogen --
  static int hydrogenDrift = 2;             // 1/N lateral drift

  // -- Sulfur --
  static int sulfurTarnishRate = 300;        // 1/N tarnish metal

  // -- Copper --
  static int copperPatinaBase = 2000;        // 1/N base patina rate
  static int copperAcidRate = 20;           // 1/N acid dissolution

  // -- Web --
  static int webWaterDissolve = 30;          // 1/N dissolve in water
  static int webDecayLife = 200;             // ticks before decay

  // -- Thorn --
  static int thornDamage = 15;              // life damage per hit

  // -- Ant --
  static int antExplorerWander = 60;         // 1/N switch to explorer mode
  static int antBlobDisperse = 3;            // 1/N blob dispersal

  // -- Colony Dynamics --
  static int colonyMigrationThreshold = 5;  // min distance before colony moves
  static int colonyMigrationInterval = 60;  // ticks between migration checks

  // -- Queen --
  static int queenEggRate = 100;            // 1/N chance per tick to lay egg
  static int queenMaxAge = 180000;          // 10x worker lifespan
  static int queenFoodPerEgg = 3;           // food consumed per egg laid
  static int queenMoveSpeed = 10;           // ticks between queen movements (slow)
  static int orphanDecayRate = 500;         // 1/N chance orphan ant loses energy

  // -- Castes --
  static int casteWorkerRatio = 70;         // % workers in colony
  static int casteSoldierRatio = 15;        // % soldiers
  static int casteNurseRatio = 10;          // % nurses
  static int casteScoutRatio = 5;           // % scouts

  // -- Brood --
  static int eggHatchTicks = 200;           // ticks for egg → larva
  static int larvaGrowTicks = 400;          // ticks for larva → adult
  static int larvaFoodPerGrow = 2;          // food units per larva maturation

  // -- Nest Building --
  static int digSuccessRate = 3;            // 1/N chance dig succeeds per tick
  static int dirtCarryDrop = 2;             // 1/N chance to drop carried dirt
  static int soldierPatrolRadius = 8;       // cells soldiers patrol from nest
  static int alarmMobilizeRadius = 15;      // cells soldiers respond to alarm

  // -- Species-Specific --
  static int spiderWebRate = 8;             // 1/N chance spider spins web per tick
  static int beePollinateRate = 12;         // 1/N chance bee pollinates flower
  static int wormAerateRate = 15;           // 1/N chance worm aerates dirt
  static int beetleDecomposeRate = 10;      // 1/N chance beetle eats compost
  static int fishEatRate = 8;              // 1/N chance fish eats algae
  static int fishMaxPop = 30;              // max fish per colony
  static int beeMaxPop = 20;              // max bees per colony
  static int wormMaxPop = 40;             // max worms per colony

  // ===================================================================
  // THROTTLES — how often behaviors update (frameCount % N)
  // Lower = more frequent = more responsive but more CPU
  // ===================================================================
  static int throttleSandAbsorb = 3;         // sand moisture check interval
  static int throttleWaterMomentum = 6;      // water velocity damping interval
  static int throttleWaterSeep = 8;          // underground seepage interval
  static int throttleWaterPressure = 3;      // pressure-driven flow interval
  static int throttleWaterFountain = 4;      // high-pressure eruption interval
  static int throttleFireSpread = 6;         // fire spread attempt interval
  static int throttleFireSmoke = 10;         // smoke spawning interval
  static int throttleIceRegel = 8;           // regelation check interval
  static int throttleDirtMoistLoss = 15;     // dirt moisture evaporation interval
  static int throttleDirtErosion = 12;       // dirt erosion interval
  static int throttlePlantHydration = 5;     // plant water check interval
  static int throttlePlantGrow = 6;          // plant growth check interval
  static int throttlePlantPhotosynthesis = 15; // O2/CO2 exchange interval
  static int throttlePlantSeed = 30;         // seed production check interval
  static int throttleLavaCool = 10;          // lava cooling check interval
  static int throttleMetalHeat = 3;          // metal heat absorption interval
  static int throttleStoneCrack = 8;         // stone cracking check interval
  static int throttleFungusGrow = 20;        // fungus spread interval
  static int throttleAlgaeGrow = 30;         // algae spread interval
  static int throttleCompostDry = 10;        // compost drying interval

  // ===================================================================
  // THRESHOLDS — trigger points for state changes
  // ===================================================================
  static int thresholdPressureHigh = 6;      // pressure considered "high" for flow
  static int thresholdPressureErupt = 16;    // pressure for fountain eruption
  static int thresholdColumnHeavy = 6;       // liquid column depth for downward push
  static int thresholdWaterDeep = 4;         // water depth for visual/behavior change
  static int thresholdPlantWilt = 30;        // life below this = wilting
  static int thresholdPlantMature = 8;       // min size for maturity
  static int thresholdPlantSeedAge = 150;    // cellAge for seed production
  static int thresholdPHAcidDamage = 80;     // pH below this damages plants
  static int thresholdPHOptimalLo = 100;     // optimal pH range low
  static int thresholdPHOptimalHi = 140;     // optimal pH range high
  static int thresholdLightPhotosynthesis = 50; // min luminance for photosynthesis
  static int thresholdLightFungusMax = 30;   // max luminance fungus tolerates
  static int thresholdTempHot = 200;         // "hot" for incandescence/reactions
  static int thresholdTempWarm = 150;        // "warm" for enhanced reactions
  static int thresholdMoistureWet = 50;      // moisture considered "wet"
  static int thresholdAgingOld = 200;        // cellAge considered "old" for effects
  static int thresholdAgingDecay = 250;      // cellAge for accelerated decay
  static int thresholdStressFailure = 2;     // stress > bondEnergy * this = collapse
  static int thresholdVibrationBreak = 200;  // vibration level that breaks weak cells
  static int thresholdAlgaeBloom = 12;       // nearby algae for bloom die-off

  // ===================================================================
  // DISTANCES — sensing and interaction ranges
  // ===================================================================
  static int distAntScan = 8;               // ant horizontal scan distance
  static int distForagerScan = 12;           // forager scan distance
  static int distLightRadius = 8;           // luminance flood fill radius
  static int distWindShelter = 3;           // terrain wind sheltering distance
  static int distVibrationSpread = 1;       // vibration propagation per tick

  /// Load tuning from JSON (Optuna results).
  static void loadFromJson(Map<String, dynamic> json) {
    applyOverrides(json);
  }

  /// Apply numeric overrides from an external tuning/config payload.
  static void applyOverrides(Map<String, dynamic> json) {
    json.forEach((key, value) {
      if (value is num) {
        _setParam(key, value.round());
      }
    });
  }

  static final Map<String, void Function(int)> _paramSetters = {
    'sandToMudRate': (value) => sandToMudRate = value,
    'sandToMudSubmergedRate': (value) => sandToMudSubmergedRate = value,
    'waterTntDissolve': (value) => waterTntDissolve = value,
    'waterSmokeDissolve': (value) => waterSmokeDissolve = value,
    'waterRainbowSpread': (value) => waterRainbowSpread = value,
    'waterPlantDamage': (value) => waterPlantDamage = value,
    'waterAcidPlantDamage': (value) => waterAcidPlantDamage = value,
    'waterBubbleRate': (value) => waterBubbleRate = value,
    'waterPressurePush': (value) => waterPressurePush = value,
    'waterMomentumReset': (value) => waterMomentumReset = value,
    'waterDirtErosion': (value) => waterDirtErosion = value,
    'waterSandErosion': (value) => waterSandErosion = value,
    'waterSedimentDeposit': (value) => waterSedimentDeposit = value,
    'waterSeepageRate': (value) => waterSeepageRate = value,
    'waterHydraulicRate': (value) => waterHydraulicRate = value,
    'waterStoneExit': (value) => waterStoneExit = value,
    'fireOxygenConsume': (value) => fireOxygenConsume = value,
    'fireOilLifetimeBase': (value) => fireOilLifetimeBase = value,
    'fireOilLifetimeVar': (value) => fireOilLifetimeVar = value,
    'fireLifetimeBase': (value) => fireLifetimeBase = value,
    'fireLifetimeVar': (value) => fireLifetimeVar = value,
    'fireBurnoutSmoke': (value) => fireBurnoutSmoke = value,
    'firePlantIgnite': (value) => firePlantIgnite = value,
    'fireOilChainIgnite': (value) => fireOilChainIgnite = value,
    'fireWoodPyrolysis': (value) => fireWoodPyrolysis = value,
    'fireFlicker': (value) => fireFlicker = value,
    'fireLateralShimmy': (value) => fireLateralShimmy = value,
    'iceRegelation': (value) => iceRegelation = value,
    'iceAmbientMeltDay': (value) => iceAmbientMeltDay = value,
    'iceAmbientMeltNight': (value) => iceAmbientMeltNight = value,
    'lightningElectrolysis': (value) => lightningElectrolysis = value,
    'lightningOilChain': (value) => lightningOilChain = value,
    'dirtAshAbsorb': (value) => dirtAshAbsorb = value,
    'dirtWaterErosionBase': (value) => dirtWaterErosionBase = value,
    'dirtFlowingErosion': (value) => dirtFlowingErosion = value,
    'plantAcidDamage': (value) => plantAcidDamage = value,
    'plantDecomposeRate': (value) => plantDecomposeRate = value,
    'plantO2Produce': (value) => plantO2Produce = value,
    'plantSeedRateYoung': (value) => plantSeedRateYoung = value,
    'plantSeedRateOld': (value) => plantSeedRateOld = value,
    'plantGrassSpread': (value) => plantGrassSpread = value,
    'plantMushroomSpread': (value) => plantMushroomSpread = value,
    'plantTreeBranch': (value) => plantTreeBranch = value,
    'plantTreeRootGrow': (value) => plantTreeRootGrow = value,
    'plantTreeBranchSkip': (value) => plantTreeBranchSkip = value,
    'lavaCoolingBase': (value) => lavaCoolingBase = value,
    'lavaCoolingVar': (value) => lavaCoolingVar = value,
    'lavaCoolIsolated': (value) => lavaCoolIsolated = value,
    'lavaCoolIsolatedVar': (value) => lavaCoolIsolatedVar = value,
    'lavaCoolPartial': (value) => lavaCoolPartial = value,
    'lavaCoolPartialVar': (value) => lavaCoolPartialVar = value,
    'lavaSmokeEmit': (value) => lavaSmokeEmit = value,
    'lavaSteamEmit': (value) => lavaSteamEmit = value,
    'lavaEruptionOpen': (value) => lavaEruptionOpen = value,
    'lavaEruptionPressured': (value) => lavaEruptionPressured = value,
    'lavaEruptThreshLow': (value) => lavaEruptThreshLow = value,
    'lavaEruptThreshHigh': (value) => lavaEruptThreshHigh = value,
    'lavaSpatter': (value) => lavaSpatter = value,
    'lavaIgniteFlammable': (value) => lavaIgniteFlammable = value,
    'lavaSandToGlass': (value) => lavaSandToGlass = value,
    'lavaMeltMetal': (value) => lavaMeltMetal = value,
    'lavaDryMud': (value) => lavaDryMud = value,
    'snowMeltRateDay': (value) => snowMeltRateDay = value,
    'snowMeltRateNight': (value) => snowMeltRateNight = value,
    'snowFreezeWater': (value) => snowFreezeWater = value,
    'snowAvalanche': (value) => snowAvalanche = value,
    'snowWindDrift': (value) => snowWindDrift = value,
    'woodFireSpread': (value) => woodFireSpread = value,
    'woodBurnoutBase': (value) => woodBurnoutBase = value,
    'woodBurnoutVar': (value) => woodBurnoutVar = value,
    'woodCharcoalChance': (value) => woodCharcoalChance = value,
    'woodAnoxicPyrolysis': (value) => woodAnoxicPyrolysis = value,
    'woodWaterAbsorb': (value) => woodWaterAbsorb = value,
    'woodWetBurn': (value) => woodWetBurn = value,
    'woodPetrify': (value) => woodPetrify = value,
    'metalFallResist': (value) => metalFallResist = value,
    'metalRustRate': (value) => metalRustRate = value,
    'metalSaltRustRate': (value) => metalSaltRustRate = value,
    'metalSaltRustAlkaline': (value) => metalSaltRustAlkaline = value,
    'metalHotIgniteRate': (value) => metalHotIgniteRate = value,
    'metalHotWoodChar': (value) => metalHotWoodChar = value,
    'metalCondensation': (value) => metalCondensation = value,
    'smokeLateralDrift': (value) => smokeLateralDrift = value,
    'bubbleWobble': (value) => bubbleWobble = value,
    'ashLateralDrift': (value) => ashLateralDrift = value,
    'ashAvalanche': (value) => ashAvalanche = value,
    'mudContactDry': (value) => mudContactDry = value,
    'mudProximityDry': (value) => mudProximityDry = value,
    'steamAltitudeRain': (value) => steamAltitudeRain = value,
    'steamDeposition': (value) => steamDeposition = value,
    'steamIceCondense': (value) => steamIceCondense = value,
    'steamTrappedSeep': (value) => steamTrappedSeep = value,
    'acidLifetimeBase': (value) => acidLifetimeBase = value,
    'acidLifetimeVar': (value) => acidLifetimeVar = value,
    'acidWaterDilute': (value) => acidWaterDilute = value,
    'acidIceMelt': (value) => acidIceMelt = value,
    'acidSnowMelt': (value) => acidSnowMelt = value,
    'acidLavaReact': (value) => acidLavaReact = value,
    'acidWaterBubble': (value) => acidWaterBubble = value,
    'stoneThinSupport': (value) => stoneThinSupport = value,
    'stoneNoLateralFall': (value) => stoneNoLateralFall = value,
    'stoneWeatherWater': (value) => stoneWeatherWater = value,
    'stoneWeatherCrumble': (value) => stoneWeatherCrumble = value,
    'stoneFrostWeather': (value) => stoneFrostWeather = value,
    'stoneFrostCrumble': (value) => stoneFrostCrumble = value,
    'stoneLavaCrack': (value) => stoneLavaCrack = value,
    'glassLavaMeltBase': (value) => glassLavaMeltBase = value,
    'glassLavaMeltVar': (value) => glassLavaMeltVar = value,
    'glassThermalShatter': (value) => glassThermalShatter = value,
    'avalancheStandard': (value) => avalancheStandard = value,
    'avalancheExtended': (value) => avalancheExtended = value,
    'fungusDeathToCompost': (value) => fungusDeathToCompost = value,
    'fungusAshDecompose': (value) => fungusAshDecompose = value,
    'fungusWoodRot': (value) => fungusWoodRot = value,
    'fungusDirtSpread': (value) => fungusDirtSpread = value,
    'fungusSporulate': (value) => fungusSporulate = value,
    'fungusMethane': (value) => fungusMethane = value,
    'sporeFallRate': (value) => sporeFallRate = value,
    'sporeDriftRate': (value) => sporeDriftRate = value,
    'compostDryToDirt': (value) => compostDryToDirt = value,
    'compostNutrient': (value) => compostNutrient = value,
    'compostMethane': (value) => compostMethane = value,
    'rustCrumble': (value) => rustCrumble = value,
    'methaneLateralDrift': (value) => methaneLateralDrift = value,
    'saltDissolveRate': (value) => saltDissolveRate = value,
    'saltDeiceRate': (value) => saltDeiceRate = value,
    'saltPlantKill': (value) => saltPlantKill = value,
    'algaeGrowRate': (value) => algaeGrowRate = value,
    'algaeO2Rate': (value) => algaeO2Rate = value,
    'algaeCO2Absorb': (value) => algaeCO2Absorb = value,
    'algaeBloomDieoff': (value) => algaeBloomDieoff = value,
    'algaeBloomThreshold': (value) => algaeBloomThreshold = value,
    'seaweedO2Rate': (value) => seaweedO2Rate = value,
    'seaweedCO2Absorb': (value) => seaweedCO2Absorb = value,
    'seaweedBloomDieoff': (value) => seaweedBloomDieoff = value,
    'seaweedBloomThreshold': (value) => seaweedBloomThreshold = value,
    'mossO2Rate': (value) => mossO2Rate = value,
    'mossCO2Absorb': (value) => mossCO2Absorb = value,
    'vineAcidDamage': (value) => vineAcidDamage = value,
    'vineO2Rate': (value) => vineO2Rate = value,
    'flowerAcidDamage': (value) => flowerAcidDamage = value,
    'flowerO2Rate': (value) => flowerO2Rate = value,
    'honeyCrystallize': (value) => honeyCrystallize = value,
    'honeyCrystallizeLife': (value) => honeyCrystallizeLife = value,
    'hydrogenDrift': (value) => hydrogenDrift = value,
    'sulfurTarnishRate': (value) => sulfurTarnishRate = value,
    'copperPatinaBase': (value) => copperPatinaBase = value,
    'copperAcidRate': (value) => copperAcidRate = value,
    'webWaterDissolve': (value) => webWaterDissolve = value,
    'webDecayLife': (value) => webDecayLife = value,
    'thornDamage': (value) => thornDamage = value,
    'antExplorerWander': (value) => antExplorerWander = value,
    'antBlobDisperse': (value) => antBlobDisperse = value,
    'colonyMigrationThreshold': (value) => colonyMigrationThreshold = value,
    'colonyMigrationInterval': (value) => colonyMigrationInterval = value,
    'queenEggRate': (value) => queenEggRate = value,
    'queenMaxAge': (value) => queenMaxAge = value,
    'queenFoodPerEgg': (value) => queenFoodPerEgg = value,
    'queenMoveSpeed': (value) => queenMoveSpeed = value,
    'orphanDecayRate': (value) => orphanDecayRate = value,
    'casteWorkerRatio': (value) => casteWorkerRatio = value,
    'casteSoldierRatio': (value) => casteSoldierRatio = value,
    'casteNurseRatio': (value) => casteNurseRatio = value,
    'casteScoutRatio': (value) => casteScoutRatio = value,
    'eggHatchTicks': (value) => eggHatchTicks = value,
    'larvaGrowTicks': (value) => larvaGrowTicks = value,
    'larvaFoodPerGrow': (value) => larvaFoodPerGrow = value,
    'digSuccessRate': (value) => digSuccessRate = value,
    'dirtCarryDrop': (value) => dirtCarryDrop = value,
    'soldierPatrolRadius': (value) => soldierPatrolRadius = value,
    'alarmMobilizeRadius': (value) => alarmMobilizeRadius = value,
    'spiderWebRate': (value) => spiderWebRate = value,
    'beePollinateRate': (value) => beePollinateRate = value,
    'wormAerateRate': (value) => wormAerateRate = value,
    'beetleDecomposeRate': (value) => beetleDecomposeRate = value,
    'fishEatRate': (value) => fishEatRate = value,
    'fishMaxPop': (value) => fishMaxPop = value,
    'beeMaxPop': (value) => beeMaxPop = value,
    'wormMaxPop': (value) => wormMaxPop = value,
    'throttleSandAbsorb': (value) => throttleSandAbsorb = value,
    'throttleWaterMomentum': (value) => throttleWaterMomentum = value,
    'throttleWaterSeep': (value) => throttleWaterSeep = value,
    'throttleWaterPressure': (value) => throttleWaterPressure = value,
    'throttleWaterFountain': (value) => throttleWaterFountain = value,
    'throttleFireSpread': (value) => throttleFireSpread = value,
    'throttleFireSmoke': (value) => throttleFireSmoke = value,
    'throttleIceRegel': (value) => throttleIceRegel = value,
    'throttleDirtMoistLoss': (value) => throttleDirtMoistLoss = value,
    'throttleDirtErosion': (value) => throttleDirtErosion = value,
    'throttlePlantHydration': (value) => throttlePlantHydration = value,
    'throttlePlantGrow': (value) => throttlePlantGrow = value,
    'throttlePlantPhotosynthesis': (value) => throttlePlantPhotosynthesis = value,
    'throttlePlantSeed': (value) => throttlePlantSeed = value,
    'throttleLavaCool': (value) => throttleLavaCool = value,
    'throttleMetalHeat': (value) => throttleMetalHeat = value,
    'throttleStoneCrack': (value) => throttleStoneCrack = value,
    'throttleFungusGrow': (value) => throttleFungusGrow = value,
    'throttleAlgaeGrow': (value) => throttleAlgaeGrow = value,
    'throttleCompostDry': (value) => throttleCompostDry = value,
    'thresholdPressureHigh': (value) => thresholdPressureHigh = value,
    'thresholdPressureErupt': (value) => thresholdPressureErupt = value,
    'thresholdColumnHeavy': (value) => thresholdColumnHeavy = value,
    'thresholdWaterDeep': (value) => thresholdWaterDeep = value,
    'thresholdPlantWilt': (value) => thresholdPlantWilt = value,
    'thresholdPlantMature': (value) => thresholdPlantMature = value,
    'thresholdPlantSeedAge': (value) => thresholdPlantSeedAge = value,
    'thresholdPHAcidDamage': (value) => thresholdPHAcidDamage = value,
    'thresholdPHOptimalLo': (value) => thresholdPHOptimalLo = value,
    'thresholdPHOptimalHi': (value) => thresholdPHOptimalHi = value,
    'thresholdLightPhotosynthesis': (value) => thresholdLightPhotosynthesis = value,
    'thresholdLightFungusMax': (value) => thresholdLightFungusMax = value,
    'thresholdTempHot': (value) => thresholdTempHot = value,
    'thresholdTempWarm': (value) => thresholdTempWarm = value,
    'thresholdMoistureWet': (value) => thresholdMoistureWet = value,
    'thresholdAgingOld': (value) => thresholdAgingOld = value,
    'thresholdAgingDecay': (value) => thresholdAgingDecay = value,
    'thresholdStressFailure': (value) => thresholdStressFailure = value,
    'thresholdVibrationBreak': (value) => thresholdVibrationBreak = value,
    'thresholdAlgaeBloom': (value) => thresholdAlgaeBloom = value,
    'distAntScan': (value) => distAntScan = value,
    'distForagerScan': (value) => distForagerScan = value,
    'distLightRadius': (value) => distLightRadius = value,
    'distWindShelter': (value) => distWindShelter = value,
    'distVibrationSpread': (value) => distVibrationSpread = value,
  };

  static void _setParam(String key, int value) {
    final setter = _paramSetters[key];
    if (setter != null) {
      setter(value);
    }
  }

  /// Export all params to JSON for Optuna.
  static Map<String, int> toJson() => {
    'sandToMudRate': sandToMudRate,
    'sandToMudSubmergedRate': sandToMudSubmergedRate,
    'waterTntDissolve': waterTntDissolve,
    'waterSmokeDissolve': waterSmokeDissolve,
    'waterRainbowSpread': waterRainbowSpread,
    'waterPlantDamage': waterPlantDamage,
    'waterAcidPlantDamage': waterAcidPlantDamage,
    'waterBubbleRate': waterBubbleRate,
    'waterPressurePush': waterPressurePush,
    'waterMomentumReset': waterMomentumReset,
    'waterDirtErosion': waterDirtErosion,
    'waterSandErosion': waterSandErosion,
    'waterSedimentDeposit': waterSedimentDeposit,
    'waterSeepageRate': waterSeepageRate,
    'waterHydraulicRate': waterHydraulicRate,
    'waterStoneExit': waterStoneExit,
    'fireOxygenConsume': fireOxygenConsume,
    'fireOilLifetimeBase': fireOilLifetimeBase,
    'fireOilLifetimeVar': fireOilLifetimeVar,
    'fireLifetimeBase': fireLifetimeBase,
    'fireLifetimeVar': fireLifetimeVar,
    'fireBurnoutSmoke': fireBurnoutSmoke,
    'firePlantIgnite': firePlantIgnite,
    'fireOilChainIgnite': fireOilChainIgnite,
    'fireWoodPyrolysis': fireWoodPyrolysis,
    'fireFlicker': fireFlicker,
    'fireLateralShimmy': fireLateralShimmy,
    'iceRegelation': iceRegelation,
    'iceAmbientMeltDay': iceAmbientMeltDay,
    'iceAmbientMeltNight': iceAmbientMeltNight,
    'lightningElectrolysis': lightningElectrolysis,
    'lightningOilChain': lightningOilChain,
    'dirtAshAbsorb': dirtAshAbsorb,
    'dirtWaterErosionBase': dirtWaterErosionBase,
    'dirtFlowingErosion': dirtFlowingErosion,
    'plantAcidDamage': plantAcidDamage,
    'plantDecomposeRate': plantDecomposeRate,
    'plantO2Produce': plantO2Produce,
    'plantSeedRateYoung': plantSeedRateYoung,
    'plantSeedRateOld': plantSeedRateOld,
    'plantGrassSpread': plantGrassSpread,
    'plantMushroomSpread': plantMushroomSpread,
    'plantTreeBranch': plantTreeBranch,
    'plantTreeRootGrow': plantTreeRootGrow,
    'plantTreeBranchSkip': plantTreeBranchSkip,
    'lavaCoolingBase': lavaCoolingBase,
    'lavaCoolingVar': lavaCoolingVar,
    'lavaCoolIsolated': lavaCoolIsolated,
    'lavaCoolIsolatedVar': lavaCoolIsolatedVar,
    'lavaCoolPartial': lavaCoolPartial,
    'lavaCoolPartialVar': lavaCoolPartialVar,
    'lavaSmokeEmit': lavaSmokeEmit,
    'lavaSteamEmit': lavaSteamEmit,
    'lavaEruptionOpen': lavaEruptionOpen,
    'lavaEruptionPressured': lavaEruptionPressured,
    'lavaEruptThreshLow': lavaEruptThreshLow,
    'lavaEruptThreshHigh': lavaEruptThreshHigh,
    'lavaSpatter': lavaSpatter,
    'lavaIgniteFlammable': lavaIgniteFlammable,
    'lavaSandToGlass': lavaSandToGlass,
    'lavaMeltMetal': lavaMeltMetal,
    'lavaDryMud': lavaDryMud,
    'snowMeltRateDay': snowMeltRateDay,
    'snowMeltRateNight': snowMeltRateNight,
    'snowFreezeWater': snowFreezeWater,
    'snowAvalanche': snowAvalanche,
    'snowWindDrift': snowWindDrift,
    'woodFireSpread': woodFireSpread,
    'woodBurnoutBase': woodBurnoutBase,
    'woodBurnoutVar': woodBurnoutVar,
    'woodCharcoalChance': woodCharcoalChance,
    'woodAnoxicPyrolysis': woodAnoxicPyrolysis,
    'woodWaterAbsorb': woodWaterAbsorb,
    'woodWetBurn': woodWetBurn,
    'woodPetrify': woodPetrify,
    'metalFallResist': metalFallResist,
    'metalRustRate': metalRustRate,
    'metalSaltRustRate': metalSaltRustRate,
    'metalSaltRustAlkaline': metalSaltRustAlkaline,
    'metalHotIgniteRate': metalHotIgniteRate,
    'metalHotWoodChar': metalHotWoodChar,
    'metalCondensation': metalCondensation,
    'smokeLateralDrift': smokeLateralDrift,
    'bubbleWobble': bubbleWobble,
    'ashLateralDrift': ashLateralDrift,
    'ashAvalanche': ashAvalanche,
    'mudContactDry': mudContactDry,
    'mudProximityDry': mudProximityDry,
    'steamAltitudeRain': steamAltitudeRain,
    'steamDeposition': steamDeposition,
    'steamIceCondense': steamIceCondense,
    'steamTrappedSeep': steamTrappedSeep,
    'acidLifetimeBase': acidLifetimeBase,
    'acidLifetimeVar': acidLifetimeVar,
    'acidWaterDilute': acidWaterDilute,
    'acidIceMelt': acidIceMelt,
    'acidSnowMelt': acidSnowMelt,
    'acidLavaReact': acidLavaReact,
    'acidWaterBubble': acidWaterBubble,
    'stoneThinSupport': stoneThinSupport,
    'stoneNoLateralFall': stoneNoLateralFall,
    'stoneWeatherWater': stoneWeatherWater,
    'stoneWeatherCrumble': stoneWeatherCrumble,
    'stoneFrostWeather': stoneFrostWeather,
    'stoneFrostCrumble': stoneFrostCrumble,
    'stoneLavaCrack': stoneLavaCrack,
    'glassLavaMeltBase': glassLavaMeltBase,
    'glassLavaMeltVar': glassLavaMeltVar,
    'glassThermalShatter': glassThermalShatter,
    'avalancheStandard': avalancheStandard,
    'avalancheExtended': avalancheExtended,
    'fungusDeathToCompost': fungusDeathToCompost,
    'fungusAshDecompose': fungusAshDecompose,
    'fungusWoodRot': fungusWoodRot,
    'fungusDirtSpread': fungusDirtSpread,
    'fungusSporulate': fungusSporulate,
    'fungusMethane': fungusMethane,
    'sporeFallRate': sporeFallRate,
    'sporeDriftRate': sporeDriftRate,
    'compostDryToDirt': compostDryToDirt,
    'compostNutrient': compostNutrient,
    'compostMethane': compostMethane,
    'rustCrumble': rustCrumble,
    'methaneLateralDrift': methaneLateralDrift,
    'saltDissolveRate': saltDissolveRate,
    'saltDeiceRate': saltDeiceRate,
    'saltPlantKill': saltPlantKill,
    'algaeGrowRate': algaeGrowRate,
    'algaeO2Rate': algaeO2Rate,
    'algaeCO2Absorb': algaeCO2Absorb,
    'algaeBloomDieoff': algaeBloomDieoff,
    'algaeBloomThreshold': algaeBloomThreshold,
    'seaweedO2Rate': seaweedO2Rate,
    'seaweedCO2Absorb': seaweedCO2Absorb,
    'seaweedBloomDieoff': seaweedBloomDieoff,
    'seaweedBloomThreshold': seaweedBloomThreshold,
    'mossO2Rate': mossO2Rate,
    'mossCO2Absorb': mossCO2Absorb,
    'vineAcidDamage': vineAcidDamage,
    'vineO2Rate': vineO2Rate,
    'flowerAcidDamage': flowerAcidDamage,
    'flowerO2Rate': flowerO2Rate,
    'honeyCrystallize': honeyCrystallize,
    'honeyCrystallizeLife': honeyCrystallizeLife,
    'hydrogenDrift': hydrogenDrift,
    'sulfurTarnishRate': sulfurTarnishRate,
    'copperPatinaBase': copperPatinaBase,
    'copperAcidRate': copperAcidRate,
    'webWaterDissolve': webWaterDissolve,
    'webDecayLife': webDecayLife,
    'thornDamage': thornDamage,
    'antExplorerWander': antExplorerWander,
    'antBlobDisperse': antBlobDisperse,
    'colonyMigrationThreshold': colonyMigrationThreshold,
    'colonyMigrationInterval': colonyMigrationInterval,
    // Queen
    'queenEggRate': queenEggRate,
    'queenMaxAge': queenMaxAge,
    'queenFoodPerEgg': queenFoodPerEgg,
    'queenMoveSpeed': queenMoveSpeed,
    'orphanDecayRate': orphanDecayRate,
    // Castes
    'casteWorkerRatio': casteWorkerRatio,
    'casteSoldierRatio': casteSoldierRatio,
    'casteNurseRatio': casteNurseRatio,
    'casteScoutRatio': casteScoutRatio,
    // Brood
    'eggHatchTicks': eggHatchTicks,
    'larvaGrowTicks': larvaGrowTicks,
    'larvaFoodPerGrow': larvaFoodPerGrow,
    // Nest Building
    'digSuccessRate': digSuccessRate,
    'dirtCarryDrop': dirtCarryDrop,
    'soldierPatrolRadius': soldierPatrolRadius,
    'alarmMobilizeRadius': alarmMobilizeRadius,
    // Species-Specific
    'spiderWebRate': spiderWebRate,
    'beePollinateRate': beePollinateRate,
    'wormAerateRate': wormAerateRate,
    'beetleDecomposeRate': beetleDecomposeRate,
    'fishEatRate': fishEatRate,
    'fishMaxPop': fishMaxPop,
    'beeMaxPop': beeMaxPop,
    'wormMaxPop': wormMaxPop,
    // Throttles
    'throttleSandAbsorb': throttleSandAbsorb,
    'throttleWaterMomentum': throttleWaterMomentum,
    'throttleWaterSeep': throttleWaterSeep,
    'throttleWaterPressure': throttleWaterPressure,
    'throttleWaterFountain': throttleWaterFountain,
    'throttleFireSpread': throttleFireSpread,
    'throttleFireSmoke': throttleFireSmoke,
    'throttleIceRegel': throttleIceRegel,
    'throttleDirtMoistLoss': throttleDirtMoistLoss,
    'throttleDirtErosion': throttleDirtErosion,
    'throttlePlantHydration': throttlePlantHydration,
    'throttlePlantGrow': throttlePlantGrow,
    'throttlePlantPhotosynthesis': throttlePlantPhotosynthesis,
    'throttlePlantSeed': throttlePlantSeed,
    'throttleLavaCool': throttleLavaCool,
    'throttleMetalHeat': throttleMetalHeat,
    'throttleStoneCrack': throttleStoneCrack,
    'throttleFungusGrow': throttleFungusGrow,
    'throttleAlgaeGrow': throttleAlgaeGrow,
    'throttleCompostDry': throttleCompostDry,
    // Thresholds
    'thresholdPressureHigh': thresholdPressureHigh,
    'thresholdPressureErupt': thresholdPressureErupt,
    'thresholdColumnHeavy': thresholdColumnHeavy,
    'thresholdWaterDeep': thresholdWaterDeep,
    'thresholdPlantWilt': thresholdPlantWilt,
    'thresholdPlantMature': thresholdPlantMature,
    'thresholdPlantSeedAge': thresholdPlantSeedAge,
    'thresholdPHAcidDamage': thresholdPHAcidDamage,
    'thresholdPHOptimalLo': thresholdPHOptimalLo,
    'thresholdPHOptimalHi': thresholdPHOptimalHi,
    'thresholdLightPhotosynthesis': thresholdLightPhotosynthesis,
    'thresholdLightFungusMax': thresholdLightFungusMax,
    'thresholdTempHot': thresholdTempHot,
    'thresholdTempWarm': thresholdTempWarm,
    'thresholdMoistureWet': thresholdMoistureWet,
    'thresholdAgingOld': thresholdAgingOld,
    'thresholdAgingDecay': thresholdAgingDecay,
    'thresholdStressFailure': thresholdStressFailure,
    'thresholdVibrationBreak': thresholdVibrationBreak,
    'thresholdAlgaeBloom': thresholdAlgaeBloom,
    // Distances
    'distAntScan': distAntScan,
    'distForagerScan': distForagerScan,
    'distLightRadius': distLightRadius,
    'distWindShelter': distWindShelter,
    'distVibrationSpread': distVibrationSpread,
  };
}
