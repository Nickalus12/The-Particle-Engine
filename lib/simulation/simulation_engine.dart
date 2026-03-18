import 'dart:math';
import 'dart:typed_data';

import 'element_registry.dart';

// ---------------------------------------------------------------------------
// SimulationEngine -- Core grid data, helpers, and main simulation loop
// ---------------------------------------------------------------------------

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

  // -- Colony tracking -------------------------------------------------------

  int colonyX = -1;
  int colonyY = -1;

  // -- Random instance -------------------------------------------------------

  final Random rng = Random();

  // -- Frame counter ---------------------------------------------------------

  int frameCount = 0;

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

  // =========================================================================
  // Construction / initialization
  // =========================================================================

  /// Create an engine with the given grid dimensions.
  ///
  /// Pass landscape-oriented values (e.g. 320x180) for widescreen layouts.
  SimulationEngine({this.gridW = 320, this.gridH = 180}) {
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
      'temperature': Uint8List.fromList(temperature),
      'pressure': Uint8List.fromList(pressure),
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
    final savedTemp = snapshot['temperature'];
    if (savedTemp is Uint8List) {
      temperature.setAll(0, savedTemp);
    } else {
      temperature.fillRange(0, temperature.length, 128);
    }
    final savedPressure = snapshot['pressure'];
    if (savedPressure is Uint8List) {
      pressure.setAll(0, savedPressure);
    } else {
      pressure.fillRange(0, pressure.length, 0);
    }
    final savedVelX = snapshot['velX'];
    final savedVelY = snapshot['velY'];
    if (savedVelX is Int8List) {
      velX.setAll(0, savedVelX);
    } else {
      velX.fillRange(0, velX.length, 0);
    }
    if (savedVelY is Int8List) {
      velY.setAll(0, savedVelY);
    } else {
      velY.fillRange(0, velY.length, 0);
    }
    frameCount = (snapshot['frameCount'] as int?) ?? 0;
    gravityDir = (snapshot['gravityDir'] as int?) ?? 1;
    windForce = (snapshot['windForce'] as int?) ?? 0;
    isNight = (snapshot['isNight'] as bool?) ?? false;
    pheroFood.fillRange(0, pheroFood.length, 0);
    pheroHome.fillRange(0, pheroHome.length, 0);
    colonyX = -1;
    colonyY = -1;
    markAllDirty();
  }

  // =========================================================================
  // Reaction flash queue
  // =========================================================================

  /// Queue a reaction flash for the renderer to spawn particles.
  @pragma('vm:prefer-inline')
  void queueReactionFlash(int x, int y, int r, int g, int b, int count) {
    if (reactionFlashes.length < 20) {
      reactionFlashes.add(Int32List.fromList([x, y, r, g, b, count]));
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

    grid[a] = grid[b];
    life[a] = life[b];
    velX[a] = velX[b];
    velY[a] = velY[b];
    temperature[a] = temperature[b];

    grid[b] = tmpEl;
    life[b] = tmpLife;
    velX[b] = tmpVx;
    velY[b] = tmpVy;
    temperature[b] = tmpTemp;

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
  }

  /// Check if any of the 8 neighbors contains [elType]. Wraps horizontally.
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

  /// Remove one adjacent cell of the given type. Wraps horizontally.
  void removeOneAdjacent(int x, int y, int elType) {
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = wrapX(x + dx);
        final ny = y + dy;
        if (inBoundsY(ny)) {
          final ni = ny * gridW + nx;
          if (grid[ni] == elType) {
            grid[ni] = El.empty;
            life[ni] = 0;
            markProcessed(ni);
            return;
          }
        }
      }
    }
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
          final distFraction = dist2 / (r * r);
          final explosionForce = ((1.0 - distFraction) * 255).round();
          if (cellHardness >= explosionForce) continue;

          if (el != El.empty && el != El.tnt && dist2 > (r * r * 0.3).round()) {
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
        final angle = rng.nextDouble() * 2 * pi;
        final dist = r * 0.6 + rng.nextDouble() * r * 0.5;
        final fx = wrapX(exp.x + (cos(angle) * dist).round());
        final fy = exp.y + (sin(angle) * dist).round();
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
    final by = y + g;
    if (inBoundsY(by)) {
      final below = by * gridW + x;
      final belowEl = grid[below];
      if (belowEl == El.empty) {
        // Accelerate: increment velY
        final curVel = velY[idx];
        final newVel = (curVel + 1).clamp(0, maxVel);
        velY[idx] = newVel;

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
        velY[idx] = 0;
        final sinkWaterMass = life[below];
        grid[idx] = El.water;
        life[idx] = sinkWaterMass < 20 ? 100 : sinkWaterMass;
        grid[below] = elType;
        markProcessed(idx);
        markProcessed(below);
        return;
      }

      // Impact on solid: reset velocity, flash on high impact
      if (velY[idx] > 2) {
        queueReactionFlash(x, y, 200, 200, 180, 2);
      }
      velY[idx] = 0;

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
  // Solid fall helper (stone, glass, ice, metal)
  // =========================================================================

  /// Solid block fall — straight down only (no diagonal slide like granular).
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

    // Fall through empty space with momentum
    if (belowEl == El.empty) {
      final curVel = velY[idx];
      final newVel = (curVel + 1).clamp(0, 2); // lower terminal vel than granular
      velY[idx] = newVel;

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

    // Landing: reset velocity
    final landingVel = velY[idx];
    if (landingVel > 0) {
      velY[idx] = 0;
      if (landingVel > 2) {
        queueReactionFlash(x, y, 180, 180, 160, 2);
      }
    }
    return false;
  }

  /// Check if a water cell is trapped (surrounded, 0-1 water neighbors, no empty).
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
            final push = (diff * 0.3).round().clamp(-20, 20);
            temp[idx] = (current + push).clamp(0, 255);
          }
        }

        // Diffuse heat to cardinal neighbors
        final myTemp = temp[idx];
        final myCond = cond[el];
        if (myCond == 0) continue;
        if ((myTemp - 128).abs() < 3) continue; // near neutral, skip

        final xl = (x - 1 + w) % w;
        final xr = (x + 1) % w;

        // Transfer heat to each neighbor
        for (final ni in [idx - w, idx + w, y * w + xl, y * w + xr]) {
          if (ni < 0 || ni >= g.length) continue;
          final nEl = g[ni];
          final nCond = cond[nEl];
          if (nCond == 0) continue;

          final nTemp = temp[ni];
          final tDiff = myTemp - nTemp;
          if (tDiff.abs() < 3) continue;

          // Transfer rate based on min conductivity of the pair
          final rate = (myCond < nCond ? myCond : nCond);
          final transfer = (tDiff * rate) >> 10; // divide by ~1024
          if (transfer == 0) continue;

          temp[idx] = (myTemp - transfer).clamp(0, 255);
          temp[ni] = (nTemp + transfer).clamp(0, 255);
        }
      }
    }
  }

  // =========================================================================
  // Pressure system
  // =========================================================================

  /// Update pressure grid for liquid cells.
  /// Scans columns top-to-bottom, accumulating liquid depth.
  /// Only runs on dirty chunks for performance.
  void updatePressure() {
    final w = gridW;
    final h = gridH;
    final g = grid;
    final p = pressure;
    final dc = dirtyChunks;
    final cols = chunkCols;
    final gDir = gravityDir;

    for (int x = 0; x < w; x++) {
      final chunkX = x >> 4;
      // Check if any chunk in this column is dirty
      bool columnDirty = false;
      for (int cy = 0; cy < chunkRows; cy++) {
        if (dc[cy * cols + chunkX] != 0) { columnDirty = true; break; }
      }
      if (!columnDirty) continue;

      // Scan from top (opposite gravity direction) accumulating pressure
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
          p[idx] = liquidDepth.clamp(0, 255);
        } else {
          liquidDepth = 0;
          p[idx] = 0;
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
    if (props.boilPoint > 0 && temp > 128 + props.boilPoint ~/ 2) {
      final target = props.boilsInto;
      if (target != 0) {
        grid[idx] = target;
        life[idx] = 0;
        markProcessed(idx);
        unsettleNeighbors(x, y);
        return true;
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
    if ((myTemp - 128).abs() < 10) return false;

    final g = gravityDir;
    final uy = y - g;
    if (!inBoundsY(uy)) return false;

    final ui = uy * gridW + x;
    final aboveEl = grid[ui];

    // Same liquid type: hot rises through cold
    if (aboveEl == el) {
      final aboveTemp = temperature[ui];
      final diff = myTemp - aboveTemp;
      // Hot cell below cold cell of same type — swap (hot rises)
      if (diff > 15) {
        // Probability proportional to temperature difference
        if (rng.nextInt(60) < diff ~/ 4) {
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
        // Warm empty air cells and low-conductivity elements
        if (el == El.empty || elementHeatCond[el] < 20) {
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
  // Main simulation step
  // =========================================================================

  /// Run one frame of physics simulation.
  ///
  /// Element behaviors are dispatched via the provided [simulateElement]
  /// callback, keeping the engine decoupled from specific element logic.
  void step(void Function(SimulationEngine engine, int el, int x, int y, int idx) simulateElement) {
    simClock = !simClock;
    final currentClockBit = simClock ? 0x80 : 0;

    processExplosions();

    // Apply wind force to movable elements
    if (windForce != 0 && frameCount % 2 == 0) {
      applyWind();
    }

    // Update temperature system every 3 frames for performance
    if (frameCount % 3 == 0) {
      updateTemperature();
    }

    // Update pressure system every 4 frames for performance
    if (frameCount % 4 == 0) {
      updatePressure();
    }

    rainbowHue = (rainbowHue + 3) % 360;

    if (lightningFlashFrames > 0) lightningFlashFrames--;

    final dc = dirtyChunks;
    final cols = chunkCols;
    final w = gridW;

    final leftToRight = frameCount.isEven;
    final yStart = gravityDir == 1 ? gridH - 1 : 0;
    final yEnd = gravityDir == 1 ? -1 : gridH;
    final yStep = gravityDir == 1 ? -1 : 1;
    for (int y = yStart; y != yEnd; y += yStep) {
      final chunkY = y >> 4;
      final startX = leftToRight ? 0 : gridW - 1;
      final endX = leftToRight ? gridW : -1;
      final dx = leftToRight ? 1 : -1;
      for (int x = startX; x != endX; x += dx) {
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

    // Swap dirty chunk buffers for next frame
    final tmp = dirtyChunks;
    dirtyChunks = nextDirtyChunks;
    nextDirtyChunks = tmp;
    nextDirtyChunks.fillRange(0, nextDirtyChunks.length, 0);

    frameCount++;
  }
}
