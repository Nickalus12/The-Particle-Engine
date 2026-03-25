import 'dart:math' as math;
import 'dart:typed_data';

import 'image_builder_stub.dart'
    if (dart.library.ui) 'image_builder_ui.dart' as image_builder;

import 'element_registry.dart';
import 'simulation_engine.dart';

/// Pure-integer sine approximation. Input: integer phase [0..255] wrapping.
/// Returns value in [0..256] where 128 = zero-crossing.
/// Equivalent to `(_fastSin(phase * 2*pi/256) * 128 + 128).round()`.
@pragma('vm:prefer-inline')
int _fastSinI(int phase) {
  final ix = phase & 0xFF; // wrap to [0, 255]
  if (ix < 64) {
    return 128 + (ix << 1); // 128 to 256
  } else if (ix < 128) {
    return 128 + ((128 - ix) << 1); // 256 to 128
  } else if (ix < 192) {
    return 128 - ((ix - 128) << 1); // 128 to 0
  } else {
    return 128 - ((256 - ix) << 1); // 0 to 128
  }
}

class PixelRenderer {
  final SimulationEngine engine;

  late Uint8List _pixels;

  final List<Int32List> _microParticles = [];
  static const int _maxMicroParticles = 120;

  late Uint8List _glowR;
  late Uint8List _glowG;
  late Uint8List _glowB;
  bool _glowBuffersValid = false;

  late List<int> _starPositions;
  late Set<int> _starSet;
  late Uint8List _starBrightness;
  late Uint8List _starTwinklePhase;
  late Map<int, int> _starIndexMap;
  bool _starsGenerated = false;

  /// Cached ground surface height per column. _groundLevel[x] = first y from
  /// top that has a solid element (stone/dirt/metal/sand/etc). Updated every
  /// few frames to avoid per-cell upward scans.
  late Int16List _groundLevel;
  int _groundLevelAge = 7; // Start at 7 so first renderPixels() triggers update

  /// Per-cell cave light level [0=dark, 255=fully lit]. Updated every 8 frames.
  late Uint8List _caveLightLevel;

  /// Per-column distance to nearest cave opening (column with no ground).
  late Int16List _surfaceProximity;

  /// Rock tint lookup tables indexed by element type for neighbor blending.
  late Uint8List _rockTintR;
  late Uint8List _rockTintG;
  late Uint8List _rockTintB;

  int _prevNightT256 = 0;

  PixelRenderer(this.engine);

  Uint8List get pixels => _pixels;
  List<Int32List> get microParticles => _microParticles;

  void init() {
    final total = engine.gridW * engine.gridH;
    _pixels = Uint8List(total * 4);
    _groundLevel = Int16List(engine.gridW);
    // Default ground level to grid height (no ground) so empty sky cells
    // are not misclassified as underground before the first cache update.
    _groundLevel.fillRange(0, engine.gridW, engine.gridH);
    _glowR = Uint8List(total);
    _glowG = Uint8List(total);
    _glowB = Uint8List(total);

    // Cave lighting buffers
    _caveLightLevel = Uint8List(total);
    _surfaceProximity = Int16List(engine.gridW);

    // Rock tint lookup tables for neighbor color blending
    _rockTintR = Uint8List(maxElements);
    _rockTintG = Uint8List(maxElements);
    _rockTintB = Uint8List(maxElements);
    // Populate rock tint for solid terrain elements
    _rockTintR[El.stone] = 80;  _rockTintG[El.stone] = 80;  _rockTintB[El.stone] = 90;
    _rockTintR[El.dirt]  = 90;  _rockTintG[El.dirt]  = 60;  _rockTintB[El.dirt]  = 30;
    _rockTintR[El.sand]  = 110; _rockTintG[El.sand]  = 100; _rockTintB[El.sand]  = 70;
    _rockTintR[El.mud]   = 60;  _rockTintG[El.mud]   = 40;  _rockTintB[El.mud]   = 25;
    _rockTintR[El.clay]  = 100; _rockTintG[El.clay]  = 68;  _rockTintB[El.clay]  = 45;
    _rockTintR[El.charcoal] = 30; _rockTintG[El.charcoal] = 30; _rockTintB[El.charcoal] = 32;
    _rockTintR[El.copper] = 95; _rockTintG[El.copper] = 58; _rockTintB[El.copper] = 26;
    _rockTintR[El.salt]  = 120; _rockTintG[El.salt]  = 116; _rockTintB[El.salt]  = 112;
    _rockTintR[El.sulfur] = 106; _rockTintG[El.sulfur] = 100; _rockTintB[El.sulfur] = 16;
    _rockTintR[El.rust]  = 80;  _rockTintG[El.rust]  = 36;  _rockTintB[El.rust]  = 16;
    _rockTintR[El.compost] = 40; _rockTintG[El.compost] = 22; _rockTintB[El.compost] = 6;
    // Periodic table ore tints
    _rockTintR[El.gold] = 128; _rockTintG[El.gold] = 100; _rockTintB[El.gold] = 10;
    _rockTintR[El.silver] = 96; _rockTintG[El.silver] = 96; _rockTintB[El.silver] = 100;
    _rockTintR[El.platinum] = 110; _rockTintG[El.platinum] = 110; _rockTintB[El.platinum] = 112;
    _rockTintR[El.aluminum] = 95; _rockTintG[El.aluminum] = 97; _rockTintB[El.aluminum] = 102;
    _rockTintR[El.titanium] = 68; _rockTintG[El.titanium] = 68; _rockTintB[El.titanium] = 65;
    _rockTintR[El.tungsten] = 64; _rockTintG[El.tungsten] = 64; _rockTintB[El.tungsten] = 64;
    _rockTintR[El.uranium] = 37; _rockTintG[El.uranium] = 64; _rockTintB[El.uranium] = 37;
    _rockTintR[El.thorium] = 72; _rockTintG[El.thorium] = 76; _rockTintB[El.thorium] = 76;
    _rockTintR[El.carbon] = 88; _rockTintG[El.carbon] = 116; _rockTintB[El.carbon] = 128;
    _rockTintR[El.tin] = 104; _rockTintG[El.tin] = 104; _rockTintB[El.tin] = 104;
    _rockTintR[El.nickel] = 96; _rockTintG[El.nickel] = 96; _rockTintB[El.nickel] = 88;
    _rockTintR[El.cobalt] = 48; _rockTintG[El.cobalt] = 56; _rockTintB[El.cobalt] = 88;
  }

  void generateStars() {
    if (_starsGenerated) return;
    _starsGenerated = true;
    final rng = engine.rng;
    final topRows = (engine.gridH * 0.85).floor().clamp(3, engine.gridH);
    _starPositions = [];
    _starBrightness = Uint8List(80);
    _starTwinklePhase = Uint8List(80);
    _starIndexMap = <int, int>{};
    for (int i = 0; i < 80; i++) {
      final sx = rng.nextInt(engine.gridW);
      // Weight toward upper sky: quadratic distribution
      final sy = rng.nextInt(topRows) * rng.nextInt(topRows) ~/ topRows;
      final pos = sy * engine.gridW + sx;
      _starPositions.add(pos);
      _starBrightness[i] = 80 + rng.nextInt(175); // [80, 254]
      _starTwinklePhase[i] = rng.nextInt(256); // [0, 255]
      _starIndexMap[pos] = i;
    }
    _starSet = Set<int>.from(_starPositions);
  }

  void clearParticles() {
    _microParticles.clear();
  }

  void spawnParticle(int x, int y, int r, int g, int b, int frames) {
    if (_microParticles.length >= _maxMicroParticles) return;
    final p = Int32List(6);
    p[0] = x; p[1] = y; p[2] = r; p[3] = g; p[4] = b; p[5] = frames;
    _microParticles.add(p);
  }

  void tickMicroParticles() {
    final rng = engine.rng;
    for (int i = _microParticles.length - 1; i >= 0; i--) {
      final p = _microParticles[i];
      p[5]--;
      if (p[5] <= 0) {
        _microParticles.removeAt(i);
        continue;
      }
      p[1] -= 1;
      if (rng.nextInt(3) == 0) p[0] += rng.nextInt(3) - 1;
      p[2] = (p[2] * 220) ~/ 256;
      p[3] = (p[3] * 220) ~/ 256;
      p[4] = (p[4] * 220) ~/ 256;
    }

    for (final rf in engine.reactionFlashes) {
      final rx = rf[0], ry = rf[1];
      final rr = rf[2], rg = rf[3], rb = rf[4];
      final count = rf[5];
      for (int i = 0; i < count; i++) {
        final dx = rng.nextInt(5) - 2;
        final dy = -(1 + rng.nextInt(3));
        spawnParticle(rx + dx, ry + dy, rr, rg, rb, 4 + rng.nextInt(3));
      }
    }
    engine.reactionFlashes.clear();

    for (final exp in engine.recentExplosions) {
      final count = (exp.radius * 3).clamp(6, 30);
      for (int i = 0; i < count; i++) {
        // Integer angle: phase256 in [0, 255] maps to [0, 2*pi)
        final phase256 = rng.nextInt(256);
        final dist = (exp.radius * 77 + rng.nextInt(exp.radius * 205)) >> 8;
        // cos(angle) ≈ sin(angle + pi/2) → phase + 64
        final sinV = _fastSinI(phase256) - 128; // [-128, 128]
        final cosV = _fastSinI(phase256 + 64) - 128; // [-128, 128]
        final px = exp.x + (dist * cosV) ~/ 128;
        final py = exp.y + (dist * sinV) ~/ 128;
        const pr = 255;
        final pg = 150 + rng.nextInt(105);
        final pb = rng.nextInt(100);
        spawnParticle(px, py, pr, pg, pb, 5 + rng.nextInt(6));
      }
    }
    engine.recentExplosions.clear();
  }

  @pragma('vm:prefer-inline')
  static int _lerpC(int a, int b, int t) =>
      (a + ((b - a) * t) ~/ 255).clamp(0, 255);

  @pragma('vm:prefer-inline')
  static int _smoothHash(int x, int y) =>
      ((x * 374761393 + y * 668265263) * 1274126177) & 0x7FFFFFFF;

  @pragma('vm:prefer-inline')
  static int _spatialBlend(int x, int y, int scale) {
    final h00 = _smoothHash(x ~/ scale, y ~/ scale);
    final h10 = _smoothHash(x ~/ scale + 1, y ~/ scale);
    final h01 = _smoothHash(x ~/ scale, y ~/ scale + 1);
    final h11 = _smoothHash(x ~/ scale + 1, y ~/ scale + 1);
    final fx = (x % scale) * 256 ~/ scale;
    final fy = (y % scale) * 256 ~/ scale;
    final top = (h00 % 256) + (((h10 % 256) - (h00 % 256)) * fx) ~/ 256;
    final bot = (h01 % 256) + (((h11 % 256) - (h01 % 256)) * fx) ~/ 256;
    return (top + ((bot - top) * fy) ~/ 256).clamp(0, 255);
  }

  /// Update the cached ground level for each column. Scans from top down
  /// to find the first THICK solid terrain per column. Requires 3+ consecutive
  /// solid cells to count as ground — prevents a single placed element from
  /// turning everything below it into dark "underground."
  void _updateGroundLevel() {
    final w = engine.gridW;
    final h = engine.gridH;
    final g = engine.grid;
    for (int x = 0; x < w; x++) {
      int level = h; // default: no ground found
      int consecutive = 0;
      for (int y = 0; y < h; y++) {
        final el = g[y * w + x];
        if (el == El.stone || el == El.dirt || el == El.metal ||
            el == El.sand || el == El.mud || el == El.wood ||
            el == El.glass || el == El.ice || el == El.clay ||
            el == El.charcoal || el == El.copper || el == El.salt ||
            el == El.sulfur || el == El.rust || el == El.compost) {
          consecutive++;
          if (consecutive >= 5) {
            level = y - 4; // top of the 5-cell solid run
            break;
          }
        } else {
          consecutive = 0;
        }
      }
      _groundLevel[x] = level;
    }
  }

  /// Check if a cell is underground using the cached ground level.
  /// A cell is underground if it is below the ground surface for its column.
  @pragma('vm:prefer-inline')
  bool _isUnderground(int x, int y, int w, Uint8List grid) {
    return y > _groundLevel[x];
  }

  /// Update per-cell cave light levels. Called every 8 frames alongside
  /// _updateGroundLevel. Computes proximity to cave openings and vertical
  /// distance below surface for each underground empty cell.
  void _updateCaveLightLevel() {
    final w = engine.gridW;
    final h = engine.gridH;

    // Step 1: Build _surfaceProximity[x] = distance to nearest column
    // where _groundLevel[x] >= h (no ground = cave opening).
    // Left-to-right sweep then right-to-left sweep. O(W).
    const maxDist = 32767; // Int16 safe large value
    _surfaceProximity[0] = _groundLevel[0] >= h ? 0 : maxDist;
    for (int x = 1; x < w; x++) {
      if (_groundLevel[x] >= h) {
        _surfaceProximity[x] = 0;
      } else {
        final prev = _surfaceProximity[x - 1];
        _surfaceProximity[x] = prev < maxDist ? prev + 1 : maxDist;
      }
    }
    for (int x = w - 2; x >= 0; x--) {
      final right = _surfaceProximity[x + 1];
      if (right + 1 < _surfaceProximity[x]) {
        _surfaceProximity[x] = right + 1;
      }
    }

    // Step 2: Per-cell cave light based on vertical + horizontal distance.
    final gl = _groundLevel;
    for (int x = 0; x < w; x++) {
      final groundY = gl[x];
      if (groundY >= h) {
        // No ground in this column — all cells are sky, zero out
        for (int y = 0; y < h; y++) {
          _caveLightLevel[y * w + x] = 0;
        }
        continue;
      }
      final horizDist = _surfaceProximity[x];
      for (int y = 0; y < h; y++) {
        if (y <= groundY) {
          // Above ground — not underground, no cave light needed
          _caveLightLevel[y * w + x] = 0;
        } else {
          final vertDist = y - groundY;
          final totalDist = vertDist + horizDist;
          final light = 255 - totalDist * 16;
          _caveLightLevel[y * w + x] = light > 0 ? (light < 256 ? light : 255) : 0;
        }
      }
    }
  }

  double dayNightT = 0.0;

  /// Vertical position of the camera center in world coordinates.
  double viewportY = 0.0;

  void renderPixels() {
    final total = engine.gridW * engine.gridH;
    final w = engine.gridW;
    final h = engine.gridH;
    final g = engine.grid;
    final t = engine.isNight ? dayNightT : 0.0;
    final fc = engine.frameCount;

    // Update ground level cache every 8 frames
    _groundLevelAge++;
    if (_groundLevelAge >= 8) {
      _updateGroundLevel();
      _updateCaveLightLevel();
      _groundLevelAge = 0;
    }
    final temp = engine.temperature;

    // All night values as integers (t is [0.0, 1.0])
    final t256 = (t * 256).round(); // [0, 256]
    // glowMul256 = (1 + t*2) * 256 = 256 + t*512
    final glowMul256 = 256 + (t256 << 1); // [256, 768]

    final starSet = t256 > 13 ? _starSet : const <int>{}; // t > ~0.05

    // Pre-compute sky gradient stops interpolated between day and night
    // Day: Top(107,184,232) Mid(90,160,216) Bottom(72,136,200) Horizon(232,216,192)
    // Night: Top(6,8,24) Mid(12,16,40) Bottom(20,24,56) Horizon(26,24,48)
    final skyTopR = 107 + (((6 - 107) * t256) >> 8);
    final skyTopG = 184 + (((8 - 184) * t256) >> 8);
    final skyTopB = 232 + (((24 - 232) * t256) >> 8);
    final skyMidR = 90 + (((12 - 90) * t256) >> 8);
    final skyMidG = 160 + (((16 - 160) * t256) >> 8);
    final skyMidB = 216 + (((40 - 216) * t256) >> 8);
    final skyBotR = 72 + (((20 - 72) * t256) >> 8);
    final skyBotG = 136 + (((24 - 136) * t256) >> 8);
    final skyBotB = 200 + (((56 - 200) * t256) >> 8);
    final skyHorR = 232 + (((26 - 232) * t256) >> 8);
    final skyHorG = 216 + (((24 - 216) * t256) >> 8);
    final skyHorB = 192 + (((48 - 192) * t256) >> 8);
    final horizonStartY = h * 88 ~/ 100;

    final doGlow = fc % 6 == 0;

    final nightBoost = (t256 * 30) >> 8; // ≈ t * 30
    final nightBoostG = nightBoost ~/ 5; // ≈ nightBoost * 0.2
    final nightShimmer = (t256 * 50) >> 8; // ≈ t * 50
    final nightSmokeBoost = (t256 * 20) >> 8; // ≈ t * 20
    final nightDimWater = (256 - (t256 * 38 >> 8)).clamp(0, 256); // ≈ 256*(1-t*0.15)
    final nightDimGeneral = (256 - (t256 * 51 >> 8)).clamp(0, 256); // ≈ 256*(1-t*0.2)

    final dayNightTransitioning = t256 != _prevNightT256;
    _prevNightT256 = t256;

    bool forceFullRender = dayNightTransitioning;

    Uint8List glowR8 = _glowR;
    Uint8List glowG8 = _glowG;
    Uint8List glowB8 = _glowB;

    if (doGlow) {
      glowR8.fillRange(0, total, 0);
      glowG8.fillRange(0, total, 0);
      glowB8.fillRange(0, total, 0);

      bool hasEmissive = false;
      for (int i = 0; i < total; i++) {
        final el = g[i];

        // Data-driven emissive check via lookup table
        int emission = elementLightEmission[el];
        int emR = elementLightR[el];
        int emG = elementLightG[el];
        int emB = elementLightB[el];
        int glowRadius = 3;

        // Special case: heated stone/metal emits light dynamically
        final isHeatedSolid = (el == El.stone || el == El.metal) && engine.velX[i] > 2;
        if (isHeatedSolid) {
          final heatLevel = engine.velX[i].clamp(0, 5);
          emission = (heatLevel * 40).clamp(0, 200);
          emR = 255;
          emG = el == El.metal ? 100 : 80; // Metal glows slightly more orange
          emB = el == El.metal ? 20 : 0;
          glowRadius = 3;
        }

        if (emission == 0) continue;
        hasEmissive = true;

        final ex = i % w;
        final ey = i ~/ w;

        // Scale glow intensities by emission level and night multiplier (integer)
        // glowMul256 is [256, 768], emission [0, 255], emR/G/B [0, 255]
        // scaledX = emX * emission * glowMul / 255 ≈ (emX * emission * glowMul256) >> 16
        final scaledR = (emR * emission * glowMul256) >> 16;
        final scaledG = (emG * emission * glowMul256) >> 16;
        final scaledB = (emB * emission * glowMul256) >> 16;

        // Lava gets larger glow for atmospheric molten look
        if (el == El.lava) {
          glowRadius = 5;
        } else if (el == El.fire) {
          glowRadius = 4;
        } else if (emission > 200) {
          glowRadius = 4;
        }

        for (int dy = -glowRadius; dy <= glowRadius; dy++) {
          final ny = ey + dy;
          if (ny < 0 || ny >= h) continue;
          for (int dx = -glowRadius; dx <= glowRadius; dx++) {
            var nx = ex + dx;
            if (nx < 0) nx += w;
            if (nx >= w) nx -= w;
            final dist = dx.abs() + dy.abs();
            if (dist == 0) continue;
            final ni = ny * w + nx;

            // Glow affects empty cells at full strength, and adds subtle
            // warm tint to nearby non-empty cells (prevents dark halos)
            final neighborEl = g[ni];
            // Treat transparent gases (oxygen, hydrogen) same as empty for glow
            final isTarget = neighborEl == El.empty ||
                neighborEl == El.oxygen || neighborEl == El.hydrogen;
            final isTintable = !isTarget && neighborEl != el &&
                neighborEl != El.fire && neighborEl != El.lava &&
                neighborEl != El.lightning;
            if (!isTarget && !isTintable) continue;

            // Smooth quadratic falloff (integer math)
            final maxDist = glowRadius + 1;
            // falloff = (1 - (dist/maxDist)^2) * 256 = (maxDist^2 - dist^2) * 256 / maxDist^2
            final md2 = maxDist * maxDist;
            final dd = dist * dist;
            final falloff = ((md2 - dd) * 256) ~/ md2;
            // Non-empty cells get reduced glow to avoid washing out element color
            final tintScale = isTintable ? 96 : 256;

            final fr = (scaledR * falloff * tintScale) ~/ (256 * 256);
            final fg = (scaledG * falloff * tintScale) ~/ (256 * 256);
            final fb = (scaledB * falloff * tintScale) ~/ (256 * 256);

            glowR8[ni] = (glowR8[ni] + fr).clamp(0, 255);
            glowG8[ni] = (glowG8[ni] + fg).clamp(0, 255);
            glowB8[ni] = (glowB8[ni] + fb).clamp(0, 255);
          }
        }
      }
      _glowBuffersValid = true;
      if (hasEmissive) forceFullRender = true;
    } else if (!_glowBuffersValid) {
      glowR8 = _glowR;
      glowG8 = _glowG;
      glowB8 = _glowB;
    }

    final dc = engine.dirtyChunks;
    final chunkCols = engine.chunkCols;
    final chunkRows = engine.chunkRows;

    final life = engine.life;
    final velX = engine.velX;
    final velY = engine.velY;
    final pheroFood = engine.pheroFood;
    final pheroHome = engine.pheroHome;
    final rng = engine.rng;
    final pxBuf = _pixels;

    for (int cy = 0; cy < chunkRows; cy++) {
      final chunkRowBase = cy * chunkCols;
      final yStart = cy * 16;
      final yEnd = (yStart + 16).clamp(0, h);

      for (int cx = 0; cx < chunkCols; cx++) {
        if (!forceFullRender && dc[chunkRowBase + cx] == 0) continue;

        final xStart = cx * 16;
        final xEnd = (xStart + 16).clamp(0, w);

        for (int y = yStart; y < yEnd; y++) {
          final rowOff = y * w;
          for (int x = xStart; x < xEnd; x++) {
            final i = rowOff + x;
            final el = g[i];
            final pi4 = i * 4;

            // Transparent atmospheric gases above ground render as sky
            final isTransparentGas = (el == El.oxygen || el == El.hydrogen) &&
                !_isUnderground(x, y, w, g);
            if (el == El.empty || isTransparentGas) {
              // Check if this empty cell is underground (cave atmosphere)
              final underground = _isUnderground(x, y, w, g);

              int emptyR, emptyG, emptyB;
              final currentMoist = engine.moisture[i];

              if (underground) {
                // --- Enhanced cave atmosphere rendering ---
                // ... (existing cave logic) ...
                final depthTint = _spatialBlend(x, y, 8);
                final stoneVar = (depthTint * 8) ~/ 256;
                emptyR = 18 + stoneVar;
                emptyG = 16 + stoneVar;
                emptyB = 20 + stoneVar;

                final caveLight = _caveLightLevel[i];
                if (caveLight > 0) {
                  final lightBoost = (caveLight * 40) ~/ 255;
                  emptyR = emptyR + lightBoost;
                  emptyG = emptyG + lightBoost;
                  emptyB = emptyB + lightBoost;
                }

                final depthBelow = y - _groundLevel[x];
                final depthFrac256 = (depthBelow * 256 ~/ 50).clamp(0, 255);
                final warmR = 4 - (depthFrac256 * 7 ~/ 256);
                final coolB = -3 + (depthFrac256 * 7 ~/ 256);
                emptyR = emptyR + warmR;
                emptyB = emptyB + coolB;

                int tintR = 0, tintG = 0, tintB = 0, tintCount = 0;
                if (y > 0) {
                  final nEl = g[i - w];
                  final nr = _rockTintR[nEl];
                  if (nr > 0) { tintR = tintR + nr; tintG = tintG + _rockTintG[nEl]; tintB = tintB + _rockTintB[nEl]; tintCount++; }
                }
                if (y < h - 1) {
                  final nEl = g[i + w];
                  final nr = _rockTintR[nEl];
                  if (nr > 0) { tintR = tintR + nr; tintG = tintG + _rockTintG[nEl]; tintB = tintB + _rockTintB[nEl]; tintCount++; }
                }
                if (x > 0) {
                  final nEl = g[i - 1];
                  final nr = _rockTintR[nEl];
                  if (nr > 0) { tintR = tintR + nr; tintG = tintG + _rockTintG[nEl]; tintB = tintB + _rockTintB[nEl]; tintCount++; }
                }
                if (x < w - 1) {
                  final nEl = g[i + 1];
                  final nr = _rockTintR[nEl];
                  if (nr > 0) { tintR = tintR + nr; tintG = tintG + _rockTintG[nEl]; tintB = tintB + _rockTintB[nEl]; tintCount++; }
                }
                if (tintCount > 0) {
                  emptyR = emptyR + (tintR * 26) ~/ (tintCount * 256);
                  emptyG = emptyG + (tintG * 26) ~/ (tintCount * 256);
                  emptyB = emptyB + (tintB * 26) ~/ (tintCount * 256);
                }

                if (currentMoist > 20) {
                  emptyG = emptyG + (currentMoist >> 5);
                  emptyB = emptyB + (currentMoist >> 4);
                }

                final dustHash = _smoothHash(x * 53 + fc ~/ 8, y * 37 + fc ~/ 12);
                if (dustHash % 180 == 0) {
                  final baseDustBright = 25 + (dustHash >> 8) % 20;
                  final dustScale = 64 + (caveLight * 192 ~/ 255);
                  final dustBright = (baseDustBright * dustScale) ~/ 256;
                  emptyR = emptyR + dustBright;
                  emptyG = emptyG + dustBright - 3;
                  emptyB = emptyB + dustBright - 5;
                }

                emptyR = emptyR.clamp(0, 80);
                emptyG = emptyG.clamp(0, 75);
                emptyB = emptyB.clamp(0, 80);
              } else {
                final skyFrac256 = y * 256 ~/ h;
                int segFrac;
                if (skyFrac256 <= 141) {
                  segFrac = skyFrac256 * 256 ~/ 141;
                  emptyR = skyTopR + (((skyMidR - skyTopR) * segFrac) >> 8);
                  emptyG = skyTopG + (((skyMidG - skyTopG) * segFrac) >> 8);
                  emptyB = skyTopB + (((skyMidB - skyTopB) * segFrac) >> 8);
                } else {
                  segFrac = ((skyFrac256 - 141) * 256) ~/ (256 - 141);
                  emptyR = skyMidR + (((skyBotR - skyMidR) * segFrac) >> 8);
                  emptyG = skyMidG + (((skyBotG - skyMidG) * segFrac) >> 8);
                  emptyB = skyMidB + (((skyBotB - skyMidB) * segFrac) >> 8);
                }
                if (y > horizonStartY) {
                  final horFrac = ((y - horizonStartY) * 256) ~/ (h - horizonStartY);
                  final horBlend = (horFrac * 38) >> 8;
                  emptyR = emptyR + (((skyHorR - emptyR) * horBlend) >> 8);
                  emptyG = emptyG + (((skyHorG - emptyG) * horBlend) >> 8);
                  emptyB = emptyB + (((skyHorB - emptyB) * horBlend) >> 8);
                }

                // PHASE 10: Atmospheric Light Scattering (Haze)
                // Humid air catches light from the glow buffer much more strongly
                if (currentMoist > 50 && _glowBuffersValid) {
                   final scattering = (currentMoist * 30) >> 8; // 0-30 extra scattering
                   emptyR = (emptyR + (glowR8[i] * scattering) ~/ 20).clamp(0, 255);
                   emptyG = (emptyG + (glowG8[i] * scattering) ~/ 20).clamp(0, 255);
                   emptyB = (emptyB + (glowB8[i] * scattering) ~/ 20).clamp(0, 255);
                }
              }

              if (_glowBuffersValid) {
                final gr = glowR8[i];
                final gg = glowG8[i];
                final gb = glowB8[i];
                if (gr > 0 || gg > 0 || gb > 0) {
                  emptyR = (emptyR + gr).clamp(0, 255);
                  emptyG = (emptyG + gg).clamp(0, 255);
                  emptyB = (emptyB + gb).clamp(0, 255);
                }
              }

              // Temperature tinting on empty cells
              final cellTemp = temp[i];
              if (cellTemp > 148) {
                // Hot: reddish tint
                final heatAmount = ((cellTemp - 148) * 3 ~/ 10).clamp(0, 30);
                emptyR = (emptyR + heatAmount).clamp(0, 255);

                // Heat shimmer: distort color above hot sources (lava/fire)
                // Creates a wavy mirage-like effect
                if (!underground && cellTemp > 170 && y > 2) {
                  // Integer heat shimmer using phase-based sine
                  final hsp1 = (fc * 14 + x * 205 + y * 102) >> 8;
                  final hsp2 = (fc * 9 + x * 307 + y * 154 + 46) >> 8;
                  final shimmerPhase = _fastSinI(hsp1); // [0, 256]
                  final shimmerPhase2 = _fastSinI(hsp2); // [0, 256]
                  // heatIntensity: (cellTemp-170) / 80 as [0, 256]
                  final heatI256 = ((cellTemp - 170) * 256 ~/ 80).clamp(0, 256);
                  final shimmerAmount = (heatI256 * (shimmerPhase * 18 + shimmerPhase2 * 10)) >> 16;
                  // Warm orange-red shimmer tint
                  emptyR = (emptyR + shimmerAmount).clamp(0, 255);
                  emptyG = (emptyG + shimmerAmount ~/ 3).clamp(0, 255);
                  emptyB = (emptyB - shimmerAmount ~/ 4).clamp(0, 255);
                }
              } else if (cellTemp < 108) {
                // Cold: bluish tint
                final coldAmount = ((108 - cellTemp) * 3 ~/ 10).clamp(0, 25);
                emptyB = (emptyB + coldAmount).clamp(0, 255);
              }

              final foodP = pheroFood[i];
              final homeP = pheroHome[i];
              if (foodP > 8 || homeP > 8) {
                final foodR = foodP > 8 ? (foodP >> 4) : 0;
                final foodG2 = foodP > 8 ? (foodP >> 3) : 0;
                final homeB = homeP > 8 ? (homeP >> 4) : 0;
                emptyR = (emptyR + foodR).clamp(0, 255);
                emptyG = (emptyG + foodG2).clamp(0, 255);
                emptyB = (emptyB + homeB).clamp(0, 255);
              }

              if (starSet.contains(i)) {
                final starIdx = _starIndexMap[i];
                if (starIdx != null) {
                  final baseBright = _starBrightness[starIdx];
                  final phase = _starTwinklePhase[starIdx];
                  final twinkle = _fastSinI((fc * 3 + phase) & 0xFF); // [0, 256]
                  final starIntensity = (baseBright * twinkle * t256) >> 16;
                  final starB = (starIntensity * 240) >> 8; // warm tint: B at 94%
                  emptyR = (emptyR + starIntensity).clamp(0, 255);
                  emptyG = (emptyG + starIntensity).clamp(0, 255);
                  emptyB = (emptyB + starB).clamp(0, 255);
                }
              }

              // Sky cells are always visible (opaque) for the gradient
              // Underground cells too (cave atmosphere)
              // Glow cells use proportional alpha
              final hasGlow = _glowBuffersValid &&
                  (glowR8[i] > 0 || glowG8[i] > 0 || glowB8[i] > 0);
              pxBuf[pi4] = emptyR;
              pxBuf[pi4 + 1] = emptyG;
              pxBuf[pi4 + 2] = emptyB;
              if (underground || hasGlow || starSet.contains(i) ||
                  pheroFood[i] > 8 || pheroHome[i] > 8) {
                pxBuf[pi4 + 3] = 255;
              } else {
                // Sky: fully opaque so the gradient shows
                pxBuf[pi4 + 3] = 255;
              }
              continue;
            }

            if (fc % 2 == 0) {
              if (el == El.fire) {
                if (rng.nextInt(120) < 2 && y > 1) {
                  const sparkR = 255;
                  final sparkG = 180 + rng.nextInt(75);
                  final sparkB = rng.nextInt(120);
                  spawnParticle(x + rng.nextInt(3) - 1, y - 1, sparkR, sparkG,
                      sparkB, 4 + rng.nextInt(4));
                }
              } else if (el == El.lava) {
                final isLavaSurface =
                    y > 1 && g[(y - 1) * w + x] == El.empty;
                if (isLavaSurface) {
                  if (rng.nextInt(120) < 2) {
                    const emberR = 255;
                    final emberG = 160 + rng.nextInt(95);
                    final emberB = rng.nextInt(80);
                    spawnParticle(x + rng.nextInt(3) - 1,
                        y - 1 - rng.nextInt(2), emberR, emberG, emberB,
                        5 + rng.nextInt(5));
                  }
                  if (rng.nextInt(200) < 1) {
                    spawnParticle(
                        x + rng.nextInt(5) - 2,
                        y - 2 - rng.nextInt(2),
                        255,
                        255,
                        200 + rng.nextInt(55),
                        3 + rng.nextInt(3));
                  }
                } else if (y > 1) {
                  // Falling lava leaves ember trails more frequently
                  final belowEmpty = y < h - 1 &&
                      g[(y + 1) * w + x] == El.empty;
                  final trailChance = belowEmpty ? 100 : 150;
                  if (rng.nextInt(trailChance) < 2) {
                    spawnParticle(
                        x + rng.nextInt(3) - 1,
                        y - 1,
                        255,
                        120 + rng.nextInt(80),
                        10 + rng.nextInt(40),
                        4 + rng.nextInt(4));
                  }
                }
              } else if (el == El.lightning) {
                if (rng.nextInt(60) < 3 && y > 1) {
                  spawnParticle(
                      x + rng.nextInt(5) - 2,
                      y + rng.nextInt(3) - 1,
                      255,
                      255,
                      100 + rng.nextInt(155),
                      3 + rng.nextInt(2));
                }
              } else if (el == El.water) {
                // Splash particles when water lands on solid ground
                if (rng.nextInt(200) < 2 &&
                    y > 1 &&
                    y < h - 1) {
                  final below = g[(y + 1) * w + x];
                  final above = g[(y - 1) * w + x];
                  if (below != El.empty &&
                      below != El.water &&
                      above == El.empty) {
                    spawnParticle(
                        x + rng.nextInt(3) - 1, y - 1,
                        60 + rng.nextInt(30), 140 + rng.nextInt(60),
                        200 + rng.nextInt(55), 3 + rng.nextInt(3));
                  }
                }
              } else if (el == El.sand) {
                // Dust when sand lands on solid surface
                if (y > 1 && y < h - 1) {
                  final below = g[(y + 1) * w + x];
                  if (below != El.empty &&
                      below != El.sand &&
                      rng.nextInt(300) < 2) {
                    spawnParticle(
                        x + rng.nextInt(3) - 1, y - 1,
                        194, 178, 128, 3 + rng.nextInt(2));
                  } else if (below == El.empty &&
                      rng.nextInt(400) < 1) {
                    spawnParticle(x, y - 1, 194, 178, 128, 3);
                  }
                }
              } else if (el == El.acid) {
                if (rng.nextInt(80) < 2 && y > 1) {
                  spawnParticle(x + rng.nextInt(3) - 1, y - 1,
                      30 + rng.nextInt(40), 220 + rng.nextInt(35),
                      30 + rng.nextInt(30), 3 + rng.nextInt(3));
                }
              } else if (el == El.steam) {
                if (rng.nextInt(400) < 1 && y > 1) {
                  spawnParticle(x + rng.nextInt(3) - 1, y - 1,
                      180, 185, 200, 2 + rng.nextInt(2));
                }
              }
            }

            int r, g2, b, a = 255;
            _writeElementColor(
                el, i, x, y, w, h, g, life, velX, velY, fc, rng, temp, t256);
            r = _inlineR;
            g2 = _inlineG;
            b = _inlineB;
            a = _inlineA;

            // Apply glow tint from nearby emissive sources to non-empty cells
            if (_glowBuffersValid) {
              final gr = glowR8[i];
              final gg = glowG8[i];
              final gb = glowB8[i];
              if (gr > 0 || gg > 0 || gb > 0) {
                r = (r + gr).clamp(0, 255);
                g2 = (g2 + gg).clamp(0, 255);
                b = (b + gb).clamp(0, 255);
              }
            }

            // Atmospheric depth darkening for underground elements
            // Uses cave light level: darker where cave light is low
            if (y > 10) {
              final undergroundCheck = _isUnderground(x, y, w, g);
              if (undergroundCheck) {
                final caveLight = _caveLightLevel[i];
                // Darken based on inverse cave light: no light → max darken (25),
                // full light → no darken. darken = (255-caveLight)*25/255
                int darken = ((255 - caveLight) * 25) ~/ 255;

                // INNOVATION: Subterranean Fog based on camera focus
                // If camera is high up, underground is much darker
                final distToCamera = (y - viewportY).abs();
                if (viewportY < h * 0.8) { // Camera is mostly above ground
                   final fogFrac = (distToCamera / h).clamp(0.0, 1.0);
                   final fogDarken = (fogFrac * 120).toInt();
                   darken += fogDarken;
                }

                r = (r - darken).clamp(0, 255);
                g2 = (g2 - darken).clamp(0, 255);
                b = (b - darken).clamp(0, 255);
              }
            }

            if (nightBoost > 0) {
              if (el == El.fire || el == El.lava) {
                r = (r + nightBoost).clamp(0, 255);
                g2 = (g2 + nightBoostG).clamp(0, 255);
              } else if (el == El.lightning) {
                // stays bright
              } else if (el == El.water) {
                final isTop = i >= w && g[i - w] != El.water;
                if (isTop && ((fc + x * 3) % 12 < 3)) {
                  r = (r + nightShimmer).clamp(0, 255);
                  g2 = (g2 + nightShimmer).clamp(0, 255);
                  b = (b + nightShimmer).clamp(0, 255);
                } else {
                  r = (r * nightDimWater) >> 8;
                  g2 = (g2 * nightDimWater) >> 8;
                }
              } else if (el == El.smoke) {
                r = (r + nightSmokeBoost).clamp(0, 255);
                g2 = (g2 + nightSmokeBoost).clamp(0, 255);
                b = (b + nightSmokeBoost).clamp(0, 255);
              } else {
                r = (r * nightDimGeneral) >> 8;
                g2 = (g2 * nightDimGeneral) >> 8;
                b = (b * nightDimGeneral) >> 8;
              }
            }

            // Flow Jitter: shift color based on velocity for dynamic feel
            final flowX = velX[i];
            final flowY = velY[i];
            if (el == El.water && (flowX != 0 || flowY != 0)) {
               r = (r + (flowX * 10)).clamp(0, 255);
               g2 = (g2 + (flowY * 10)).clamp(0, 255);
               b = (b + 15).clamp(0, 255); // Flowing water is slightly brighter/more aerated
            }

            pxBuf[pi4] = r.clamp(0, 255);
            pxBuf[pi4 + 1] = g2.clamp(0, 255);
            pxBuf[pi4 + 2] = b.clamp(0, 255);
            pxBuf[pi4 + 3] = a;
          }
        }
      }
    }

    for (final p in _microParticles) {
      var px = p[0] % w;
      if (px < 0) px += w;
      final py = p[1];
      if (py < 0 || py >= h) continue;
      final pi4 = (py * w + px) * 4;
      pxBuf[pi4] = (pxBuf[pi4] + p[2]).clamp(0, 255);
      pxBuf[pi4 + 1] = (pxBuf[pi4 + 1] + p[3]).clamp(0, 255);
      pxBuf[pi4 + 2] = (pxBuf[pi4 + 2] + p[4]).clamp(0, 255);
      if (pxBuf[pi4 + 3] == 0) {
        pxBuf[pi4 + 3] = 255;
      }
    }
  }

  Future<Object> buildImage() async {
    return image_builder.buildImageFromPixels(
        _pixels, engine.gridW, engine.gridH);
  }

  int _inlineR = 0;
  int _inlineG = 0;
  int _inlineB = 0;
  int _inlineA = 255;

  void _writeElementColor(
      int el,
      int idx,
      int x,
      int y,
      int w,
      int h,
      Uint8List grid,
      Uint8List life,
      Int8List velX,
      Int8List velY,
      int frameCount,
      math.Random rng,
      Uint8List temp,
      int nightT256) {
    switch (el) {
      case El.fire:
        final fireLife = life[idx];
        final slow1 = (frameCount + idx * 3) % 8;
        final slow2 = (frameCount * 2 + idx * 7) % 12;
        final slow3 = (frameCount + idx * 13) % 20;
        final flickerSum = (slow1 < 3 ? 18 : 0) +
            (slow2 < 4 ? 14 : 0) +
            (slow3 < 7 ? 10 : 0);

        // Smooth gradient: white-hot core -> orange -> red tips -> smoke edges
        if (fireLife < 6) {
          // White-hot center
          _inlineR = 255;
          _inlineG = (250 - flickerSum ~/ 4).clamp(235, 255);
          _inlineB = (220 - flickerSum ~/ 3).clamp(180, 235);
          _inlineA = 255;
        } else if (fireLife < 14) {
          // Bright yellow-orange
          final t2 = ((fireLife - 6) * 255 ~/ 8).clamp(0, 255);
          _inlineR = 255;
          _inlineG = _lerpC(245, 180, t2) + flickerSum ~/ 4;
          _inlineB = _lerpC(200, 30, t2) + flickerSum ~/ 5;
          _inlineG = _inlineG.clamp(150, 255);
          _inlineB = _inlineB.clamp(0, 210);
          _inlineA = 255;
        } else if (fireLife < 26) {
          // Orange body
          final t2 = ((fireLife - 14) * 255 ~/ 12).clamp(0, 255);
          _inlineR = 255;
          _inlineG = _lerpC(180, 80, t2) + flickerSum ~/ 4;
          _inlineB = _lerpC(30, 5, t2);
          _inlineG = _inlineG.clamp(50, 200);
          _inlineB = _inlineB.clamp(0, 40);
          _inlineA = 255;
        } else if (fireLife < 40) {
          // Red tips
          final t2 = ((fireLife - 26) * 255 ~/ 14).clamp(0, 255);
          _inlineR = _lerpC(255, 200, t2);
          _inlineG = _lerpC(80, 25, t2) + flickerSum ~/ 5;
          _inlineB = (flickerSum ~/ 8).clamp(0, 10);
          _inlineG = _inlineG.clamp(10, 100);
          _inlineA = 255;
        } else {
          // Smoke edges: fading dark red to grey
          final remaining = (80 - fireLife).clamp(1, 40);
          final fade = (remaining * 255 ~/ 40).clamp(0, 255);
          _inlineA = (remaining * 5 + 60).clamp(60, 255);
          _inlineR = _lerpC(90, 160, fade) + flickerSum ~/ 5;
          _inlineG = _lerpC(30, 60, fade) + flickerSum ~/ 8;
          _inlineB = _lerpC(25, 50, fade);
          _inlineR = _inlineR.clamp(60, 200);
          _inlineG = _inlineG.clamp(20, 80);
          _inlineB = _inlineB.clamp(15, 60);
        }

      case El.lightning:
        final boltLife = life[idx];
        if (boltLife < 5) {
          // White-hot core for very young bolts
          _inlineR = 255;
          _inlineG = 255;
          _inlineB = 255;
        } else {
          // Brightness fades with age: younger = brighter
          final ageDim = (boltLife * 2).clamp(0, 80);
          final pulse = _fastSinI((frameCount * 12 + idx * 5) & 0xFF);
          final pulseBoost = (pulse - 128).clamp(0, 128) ~/ 4; // 0-32
          _inlineR = (255 - ageDim ~/ 2 + pulseBoost).clamp(180, 255);
          _inlineG = (255 - ageDim + pulseBoost).clamp(150, 255);
          // Purple fringe on odd frames
          final purpleFringe = (frameCount & 1) == 1 ? 30 : 0;
          _inlineB = (255 - ageDim ~/ 3 + purpleFringe + pulseBoost).clamp(180, 255);
        }
        _inlineA = 255;

      case El.rainbow:
        // Integer HSV-to-RGB: no float math in hot render path
        // hue in [0, 360), sector = hue ~/ 60, f256 = fractional part scaled to [0, 255]
        final hue = (engine.rainbowHue + life[idx] * 7) % 360;
        final hi = hue ~/ 60; // sector [0..5]
        // f256 = ((hue % 60) * 256) ~/ 60 — fractional part in [0, 255]
        final f256 = ((hue - hi * 60) * 256) ~/ 60;
        const v = 255;
        const p2 = 51; // v * (1 - 0.8) = 255 * 0.2
        // q = v * (1 - 0.8*f) = 255 - 204*f256/256
        final q = 255 - ((204 * f256) >> 8);
        // t2 = v * (1 - 0.8*(1-f)) = 51 + 204*f256/256
        final t2 = 51 + ((204 * f256) >> 8);
        _inlineA = 255;
        switch (hi) {
          case 0:
            _inlineR = v;
            _inlineG = t2;
            _inlineB = p2;
          case 1:
            _inlineR = q;
            _inlineG = v;
            _inlineB = p2;
          case 2:
            _inlineR = p2;
            _inlineG = v;
            _inlineB = t2;
          case 3:
            _inlineR = p2;
            _inlineG = q;
            _inlineB = v;
          case 4:
            _inlineR = t2;
            _inlineG = p2;
            _inlineB = v;
          default:
            _inlineR = v;
            _inlineG = p2;
            _inlineB = q;
        }

      case El.steam:
        final steamLife = life[idx];
        // Steam should be nearly invisible wisps that fade quickly.
        // Alpha ramps down from ~50 at birth to ~8 near end-of-life,
        // so individual pixels are never bright white dots.
        final lifeFrac = (steamLife * 255 ~/ 30).clamp(0, 255);
        _inlineA = _lerpC(50, 8, lifeFrac);
        // Gentle shimmer: slow phase offset per-pixel avoids uniform look
        final phase = (frameCount ~/ 2 + idx * 7) % 40;
        final wisp = phase < 10 ? (10 - phase) : 0;
        // Tint toward sky-blue rather than bright white
        final steamBase = _lerpC(210, 180, lifeFrac);
        _inlineR = (steamBase + wisp).clamp(175, 220);
        _inlineG = (steamBase + wisp + 2).clamp(178, 225);
        _inlineB = (steamBase + 20 + wisp ~/ 2).clamp(195, 240);

      case El.water:
        if (life[idx] >= 200) {
          life[idx]--;
          if (life[idx] < 200) life[idx] = 0;
          _inlineR = 255;
          _inlineG = 255;
          _inlineB = 102;
          _inlineA = 255;
        } else if (life[idx] >= 140 && life[idx] < 200) {
          life[idx]--;
          final tFrac = ((life[idx] - 140) * 255 ~/ 60).clamp(0, 255);
          _inlineR = _lerpC(30, 170, tFrac);
          _inlineG = _lerpC(100, 220, tFrac);
          _inlineB = 255;
          _inlineA = 255;
        } else {
          final isTop = y > 0 &&
              grid[(y - 1) * w + x] != El.water &&
              grid[(y - 1) * w + x] != El.oil;

          // Determine if this water is underground
          final isUndergroundWater = _isUnderground(x, y, w, grid);

          if (isTop) {
            // Surface shimmer with gentle wave animation (pure integer math)
            // Phase inputs: frameCount*31/256 + x*154/256 ≈ fc*0.12 + x*0.6 in radians→phase
            final wavePhase1 = (frameCount * 31 + x * 154) >> 8;
            final wavePhase2 = (frameCount * 18 + x * 282 + 46) >> 8;
            // _fastSinI returns [0, 256], scale to shimmer range
            final wave = _fastSinI(wavePhase1); // [0, 256]
            final wave2 = _fastSinI(wavePhase2); // [0, 256]
            final shimmer = (wave * 25 + wave2 * 15) >> 8; // [0, 40]

            // Wave ripple brightness from velY (set by splash impacts)
            final waveVel = engine.velY[idx];
            final waveOffset = waveVel.abs() * 8; // 0..64 brightness boost

            // Foam/highlight where water meets solid elements
            final belowIdx = y < h - 1 ? (y + 1) * w + x : -1;
            final isSolid = belowIdx >= 0 && grid[belowIdx] != El.water &&
                grid[belowIdx] != El.empty && grid[belowIdx] != El.oil;

            // Check left/right for solid contact (foam)
            final leftSolid = x > 0 && grid[y * w + x - 1] != El.water &&
                grid[y * w + x - 1] != El.empty && grid[y * w + x - 1] != El.oil;
            final rightSolid = x < w - 1 && grid[y * w + x + 1] != El.water &&
                grid[y * w + x + 1] != El.empty && grid[y * w + x + 1] != El.oil;
            final hasFoam = isSolid || leftSolid || rightSolid;

            if (hasFoam) {
              // White-ish foam highlight with animated sparkle
              final foamFlicker = ((frameCount + x * 7) % 20 < 3) ? 25 : 0;
              _inlineR = (110 + shimmer * 2 + foamFlicker + waveOffset).clamp(80, 255);
              _inlineG = (225 + shimmer + foamFlicker ~/ 2 + waveOffset).clamp(200, 255);
              _inlineB = (255 + waveOffset).clamp(200, 255);
              _inlineA = 235;
            } else if (isUndergroundWater) {
              // Underground surface water: darker, more muted
              _inlineR = (30 + shimmer ~/ 2 + waveOffset).clamp(20, 100);
              _inlineG = (120 + shimmer ~/ 2 + waveOffset).clamp(100, 200);
              _inlineB = (200 + shimmer ~/ 3 + waveOffset).clamp(180, 255);
              _inlineA = 235;
            } else {
              // Surface water reflects sky color
              // Integer night dimming using frame-level nightT256
              final skyDimRG = 256 - (nightT256 * 218 >> 8); // ~(1 - t*0.85)*256
              final skyReflectR = (135 * skyDimRG) >> 8;
              final skyReflectG = (195 * skyDimRG) >> 8;
              final skyReflectB = (255 * (256 - (nightT256 * 77 >> 8))) >> 8; // ~(1-t*0.3)*255
              // Blend ~25% sky reflection into surface water + wave ripple brightness
              _inlineR = (55 + shimmer + (skyReflectR * 60) ~/ 256 + waveOffset).clamp(35, 200);
              _inlineG = (185 + shimmer + (skyReflectG * 30) ~/ 256 + waveOffset).clamp(165, 255);
              _inlineB = (240 + (skyReflectB * 15) ~/ 256 + waveOffset).clamp(230, 255);
              _inlineA = 215;
            }
          } else {
            // Depth calculation
            int depth = 0;
            for (int cy = y - 1; cy >= 0 && depth < 25; cy--) {
              if (grid[cy * w + x] == El.water) {
                depth++;
              } else {
                break;
              }
            }

            // Smooth depth darkening with no visible steps
            final depthFrac = (depth * 256 ~/ 25).clamp(0, 255);
            final pressureDarken = (engine.pressure[idx] * 40) >> 8; // Darken with pressure

            int baseR, baseG, baseB, baseA;
            if (isUndergroundWater) {
              // Underground water: much darker and murkier
              baseR = _lerpC(25, 3, depthFrac) - pressureDarken;
              baseG = _lerpC(90, 25, depthFrac) - pressureDarken;
              baseB = _lerpC(160, 80, depthFrac);
              baseA = _lerpC(230, 250, depthFrac);
            } else {
              // Surface water: clear blue gradient
              baseR = _lerpC(45, 5, depthFrac) - pressureDarken;
              baseG = _lerpC(155, 35, depthFrac) - pressureDarken;
              baseB = _lerpC(255, 160, depthFrac);
              baseA = _lerpC(220, 250, depthFrac);
            }

            // Caustics for shallow water
            int caustic = 0;
            if (depth < 10) {
              // Integer caustics: phase-based sine
              final cp1 = (frameCount * 26 + x * 154 + y * 90) >> 8;
              final cp2 = (frameCount * 18 + x * 230 + y * 128 + 46) >> 8;
              final cx1 = _fastSinI(cp1); // [0, 256]
              final cx2 = _fastSinI(cp2); // [0, 256]
              // causticStrength = (10 - depth) / 10 as [0, 256]
              final cStr = (10 - depth) * 256 ~/ 10;
              caustic = ((cx1 * 10 + cx2 * 6) * cStr) >> 16;
            }

            // Foam/highlight at water-solid edges
            bool nearEdge = false;
            if (x > 0 && grid[y * w + x - 1] != El.water &&
                grid[y * w + x - 1] != El.empty) {
              nearEdge = true;
            } else if (x < w - 1 && grid[y * w + x + 1] != El.water &&
                grid[y * w + x + 1] != El.empty) {
              nearEdge = true;
            }
            // Also check above/below for foam
            if (y > 0 && grid[(y - 1) * w + x] != El.water &&
                grid[(y - 1) * w + x] != El.empty &&
                grid[(y - 1) * w + x] != El.oil) {
              nearEdge = true;
            }
            if (y < h - 1 && grid[(y + 1) * w + x] != El.water &&
                grid[(y + 1) * w + x] != El.empty) {
              nearEdge = true;
            }
            final edgeHighlight = nearEdge ? 18 : 0;

            _inlineR = (baseR + caustic + edgeHighlight).clamp(0, 100);
            _inlineG = (baseG + caustic + edgeHighlight).clamp(20, 220);
            _inlineB = (baseB + caustic ~/ 2).clamp(80, 255);
            _inlineA = baseA;
          }
        }

      case El.sand:
        _inlineA = 255;
        // Per-grain variation: 4 tonal shades based on position hash
        final sandHash = _smoothHash(x * 31, y * 47);
        final grainType = sandHash % 4;
        int sandBaseR, sandBaseG, sandBaseB;
        if (grainType == 0) {
          // Warm golden
          sandBaseR = 218; sandBaseG = 198; sandBaseB = 135;
        } else if (grainType == 1) {
          // Pale cream
          sandBaseR = 228; sandBaseG = 212; sandBaseB = 155;
        } else if (grainType == 2) {
          // Dark amber
          sandBaseR = 195; sandBaseG = 172; sandBaseB = 108;
        } else {
          // Reddish tan
          sandBaseR = 210; sandBaseG = 182; sandBaseB = 118;
        }
        // Smooth spatial gradient for gentle blending between grains
        final sandSpatial = _spatialBlend(x, y, 6);
        final sandVar = (sandSpatial * 16) ~/ 256 - 8;
        // Gentle tonal banding (dune-like)
        final sandBand = _spatialBlend(x + 200, y * 2, 10);
        final sandBandShift = (sandBand * 8) ~/ 256 - 4;
        // Quartz glint: rare bright sparkle
        final sandSparkPhase = (sandHash % 80);
        final sandSparkActive = ((frameCount + sandSparkPhase) % 80);
        final isSandSparkle = sandSparkActive < 2 && (sandHash % 6 == 0);
        final sandSparkle = isSandSparkle ? 30 : 0;
        // Temperature coloring: heat = slightly redder, cold = bluer
        final sandTemp = temp[idx];
        final sandHeatTint = sandTemp > 148 ? ((sandTemp - 148) * 8 ~/ 107).clamp(0, 8) : 0;
        final sandColdTint = sandTemp < 108 ? ((108 - sandTemp) * 6 ~/ 108).clamp(0, 6) : 0;
        _inlineR = (sandBaseR + sandVar + sandBandShift + sandSparkle + sandHeatTint).clamp(185, 255);
        _inlineG = (sandBaseG + sandVar + sandBandShift + sandSparkle - sandHeatTint ~/ 2).clamp(165, 245);
        _inlineB = (sandBaseB + sandVar ~/ 2 + sandBandShift ~/ 2 + sandSparkle ~/ 2 - sandHeatTint + sandColdTint).clamp(95, 190);

      case El.tnt:
        _inlineA = 255;
        final tntLife = life[idx];
        if (tntLife > 200) {
          // Pre-detonation pulsing glow
          final urgency = ((tntLife - 200) * 255 ~/ 55).clamp(0, 255);
          final pulse = _fastSinI((frameCount * 8 + idx) & 0xFF);
          // Pulse intensity scales with urgency (0-255)
          final pulseVal = ((pulse - 128).clamp(0, 128) * urgency) ~/ 255;
          // Checker fades to bright orange-white as life -> 255
          final isChecker = (x + y) % 4 == 0;
          final checkerDim = isChecker ? ((255 - urgency) * 68) ~/ 255 : 0;
          // Base brightens toward orange-white
          _inlineR = (204 + urgency ~/ 5 + pulseVal ~/ 2 - checkerDim).clamp(60, 255);
          _inlineG = (34 + urgency ~/ 3 + pulseVal ~/ 3 - checkerDim ~/ 2).clamp(0, 255);
          _inlineB = (34 + urgency ~/ 6 + pulseVal ~/ 4 - checkerDim ~/ 3).clamp(0, 200);
        } else {
          // Sharp checkerboard pattern for stable TNT
          if ((x + y) % 2 == 0) {
            _inlineR = 68;
            _inlineG = 0;
            _inlineB = 0;
          } else {
            final tntVar = ((idx * 7 + y * 3) % 11) - 5;
            _inlineR = (204 + tntVar).clamp(180, 230);
            _inlineG = (34 + tntVar).clamp(10, 60);
            _inlineB = (34 + tntVar).clamp(10, 60);
          }
        }

      case El.ant:
        _inlineA = 255;
        final antState = velY[idx];
        // Carapace sheen: subtle highlight that shifts per-ant
        final antSheen = _smoothHash(x * 11, y * 7) % 4;
        final antSheenBoost = antSheen == 0 ? 12 : (antSheen == 1 ? 6 : 0);
        // Leg/segment variation: slight brightness difference
        final antSeg = (idx * 3 + y) % 5 == 0 ? 5 : 0;
        if (antState == antCarrierState) {
          final aboveIdx = idx - w;
          if (y > 0 && grid[aboveIdx] != El.ant) {
            // Food particle being carried: golden
            _inlineR = (139 + antSheenBoost).clamp(130, 160);
            _inlineG = (105 + antSheenBoost ~/ 2).clamp(95, 120);
            _inlineB = 20;
          } else {
            _inlineR = (61 + antSheenBoost + antSeg).clamp(55, 82);
            _inlineG = (43 + antSheenBoost ~/ 2 + antSeg ~/ 2).clamp(38, 60);
            _inlineB = (31 + antSheenBoost ~/ 3).clamp(28, 42);
          }
        } else if (antState == antDiggerState) {
          // Reddish-brown mandibles
          _inlineR = (48 + antSheenBoost + antSeg).clamp(42, 68);
          _inlineG = (20 + antSheenBoost ~/ 3).clamp(15, 30);
          _inlineB = (17 + antSheenBoost ~/ 4).clamp(14, 25);
        } else if (antState == antForagerState) {
          // Greenish tint: foraging
          _inlineR = (30 + antSheenBoost ~/ 2 + antSeg).clamp(24, 45);
          _inlineG = (48 + antSheenBoost + antSeg).clamp(42, 68);
          _inlineB = (20 + antSheenBoost ~/ 3).clamp(15, 30);
        } else if (antState == antReturningState) {
          // Bluish tint: heading home
          _inlineR = (20 + antSheenBoost ~/ 3 + antSeg).clamp(15, 32);
          _inlineG = (20 + antSheenBoost ~/ 3 + antSeg).clamp(15, 32);
          _inlineB = (42 + antSheenBoost + antSeg).clamp(36, 60);
        } else {
          // Default: dark chitin with segment variation
          final antBase = idx % 3 == 0 ? 48 : 20;
          _inlineR = (antBase + antSheenBoost + antSeg).clamp(15, 65);
          _inlineG = (antBase + antSheenBoost + antSeg).clamp(15, 65);
          _inlineB = (antBase + antSheenBoost ~/ 2 + antSeg).clamp(15, 65);
        }

      case El.seed:
        final seedLife = life[idx];
        final organic = _spatialBlend(x, y, 4);
        final organicVar = (organic * 16) ~/ 256 - 8;
        final v = ((idx % 5) * 4 + organicVar).clamp(0, 25);
        // Glossy specular highlight: one bright pixel per ~10
        final specHash = _smoothHash(x * 13, y * 11);
        final isGlossy = specHash % 10 == 0;
        final gloss = isGlossy ? 30 : 0;
        if (seedLife > 150) {
          // Germination: green tint creeps in
          final sproutFrac = ((seedLife - 150) * 255 ~/ 105).clamp(0, 255);
          _inlineR = (139 - v - sproutFrac ~/ 5 + gloss).clamp(80, 170);
          _inlineG = (115 - v + sproutFrac ~/ 3 + gloss).clamp(80, 170);
          _inlineB = (85 - v - sproutFrac ~/ 6 + gloss ~/ 2).clamp(40, 120);
        } else {
          _inlineR = (139 - v + gloss).clamp(100, 170);
          _inlineG = (115 - v + gloss).clamp(80, 145);
          _inlineB = (85 - v + gloss ~/ 2).clamp(50, 115);
        }
        _inlineA = 255;

      case El.dirt:
        final currentMoist = engine.moisture[idx];
        final compaction = velY[idx].clamp(0, 5);
        final compactDarken = compaction * 6;
        // Smooth spatial blending for earthy tones
        final dirtSpatial = _spatialBlend(x, y, 5);
        final dirtVar = (dirtSpatial * 20) ~/ 256 - 10;
        final dirtWarmth = _spatialBlend(x + 100, y + 100, 8);
        final dirtWarmShift = (dirtWarmth * 8) ~/ 256 - 4;
        // Organic texture: dark patches (decaying matter, roots)
        final dirtHash = _smoothHash(x * 19, y * 23);
        final isDarkPatch = dirtHash % 12 == 0; // ~8% of pixels
        final isRootFiber = dirtHash % 17 == 0 && (dirtHash >> 8) % 3 == 0;
        final organicDarken = isDarkPatch ? 18 : (isRootFiber ? 12 : 0);
        // Small lighter mineral specks (pebbles, sand grains)
        final dirtMineralHash = _smoothHash(x * 41, y * 37);
        final isMineralSpeck = dirtMineralHash % 20 == 0;
        final mineralSpeck = isMineralSpeck ? 14 : 0;
        // Tiny grub/worm: very rare lighter spot with warm tone
        final isGrub = dirtHash % 45 == 0 && (dirtHash >> 12) % 3 == 0;
        final grubR = isGrub ? 12 : 0;
        final grubG = isGrub ? 8 : 0;
        // Surface crust: top dirt is lighter (dried surface)
        final isDirtSurface = y > 0 && grid[(y - 1) * w + x] != El.dirt &&
            grid[(y - 1) * w + x] != El.plant && grid[(y - 1) * w + x] != El.stone;
        final surfaceCrust = isDirtSurface ? 12 : 0;
        // Moisture sheen on surface: wet top glints
        final moistSheen = isDirtSurface && currentMoist > 100 ? 8 : 0;
        final dirtBaseR = 140 + dirtVar + dirtWarmShift - compactDarken - organicDarken + mineralSpeck + grubR + surfaceCrust;
        final dirtBaseG = 95 + dirtVar ~/ 2 - compactDarken - organicDarken ~/ 2 + grubG + surfaceCrust ~/ 2;
        final dirtBaseB = 40 + dirtVar ~/ 3 - compactDarken ~/ 2 - organicDarken ~/ 3 + moistSheen;
        // Darker when moist: currentMoist is 0-255. darken up to 60 units.
        _inlineR = (dirtBaseR - ((currentMoist * 60) >> 8)).clamp(35, 175);
        _inlineG = (dirtBaseG - ((currentMoist * 50) >> 8)).clamp(18, 125);
        _inlineB = (dirtBaseB - ((currentMoist * 12) >> 8)).clamp(4, 60);
        _inlineA = 255;

      case El.plant:
        final pType = engine.plantType(idx);
        final pStage = engine.plantStage(idx);
        final variation = ((idx * 7 + y * 3) % 11) - 5;
        if (pStage == stDead) {
          _inlineR = (80 + variation).clamp(60, 100);
          _inlineG = (50 + variation).clamp(30, 70);
          _inlineB = 20;
          _inlineA = 255;
        } else if (pStage == stWilting) {
          // Yellow-green wilting
          _inlineR = (140 + variation).clamp(120, 170);
          _inlineG = (145 + variation).clamp(120, 175);
          _inlineB = (30 + variation).clamp(15, 50);
          _inlineA = 255;
        } else {
          _inlineA = 255;
          switch (pType) {
            case plantGrass:
              // Growth stage affects brightness
              if (pStage == stSprout) {
                // Bright lime green sprout
                _inlineR = (80 + variation).clamp(60, 110);
                _inlineG = (210 + variation).clamp(190, 240);
                _inlineB = (50 + variation).clamp(30, 75);
              } else if (pStage == stMature) {
                // Deep rich green
                _inlineR = (25 + variation).clamp(10, 45);
                _inlineG = (155 + variation).clamp(130, 180);
                _inlineB = (25 + variation).clamp(10, 45);
              } else {
                // Growing: mid green
                _inlineR = (40 + variation).clamp(20, 65);
                _inlineG = (180 + variation).clamp(155, 210);
                _inlineB = (35 + variation).clamp(15, 55);
              }
            case plantFlower:
              if (pStage == stMature) {
                final hue2 = ((idx * 37) % 5);
                switch (hue2) {
                  case 0:
                    _inlineR = 255;
                    _inlineG = 68;
                    _inlineB = 136;
                  case 1:
                    _inlineR = 255;
                    _inlineG = 221;
                    _inlineB = 68;
                  case 2:
                    _inlineR = 255;
                    _inlineG = 136;
                    _inlineB = 204;
                  case 3:
                    _inlineR = 153;
                    _inlineG = 68;
                    _inlineB = 255;
                  default:
                    _inlineR = 68;
                    _inlineG = 136;
                    _inlineB = 255;
                }
              } else if (pStage == stSprout) {
                _inlineR = (60 + variation).clamp(40, 85);
                _inlineG = (200 + variation).clamp(180, 230);
                _inlineB = (45 + variation).clamp(25, 70);
              } else {
                _inlineR = (30 + variation).clamp(15, 50);
                _inlineG = (170 + variation).clamp(145, 200);
                _inlineB = (30 + variation).clamp(15, 50);
              }
            case plantTree:
              if (pStage == stGrowing) {
                // Warm brown trunk with vertical grain
                final grainY = _spatialBlend(x, y * 4, 3);
                final grainShift = (grainY * 14) ~/ 256 - 7;
                _inlineR = (105 + variation + grainShift).clamp(80, 130);
                _inlineG = (65 + variation ~/ 2 + grainShift ~/ 2).clamp(40, 90);
                _inlineB = (30 + variation ~/ 3).clamp(12, 48);
              } else if (pStage == stSprout) {
                // Bright green sapling
                _inlineR = (55 + variation).clamp(35, 80);
                _inlineG = (195 + variation).clamp(170, 225);
                _inlineB = (40 + variation).clamp(20, 65);
              } else {
                // Mature: deep rich green canopy
                _inlineR = (15 + variation).clamp(5, 35);
                _inlineG = (130 + variation).clamp(105, 160);
                _inlineB = (18 + variation).clamp(5, 38);
              }
            case plantMushroom:
              if (pStage == stMature) {
                final spot = (idx * 13) % 7 == 0;
                if (spot) {
                  _inlineR = 240;
                  _inlineG = 240;
                  _inlineB = 224;
                } else {
                  _inlineR = (180 + variation).clamp(160, 210);
                  _inlineG = (50 + variation).clamp(30, 70);
                  _inlineB = (30 + variation).clamp(10, 50);
                }
              } else {
                _inlineR = (220 + variation).clamp(200, 240);
                _inlineG = (210 + variation).clamp(190, 230);
                _inlineB = (180 + variation).clamp(160, 200);
              }
            case plantVine:
              final isLeaf = velY[idx] % 4 == 0;
              if (isLeaf) {
                _inlineR = (15 + variation).clamp(5, 30);
                _inlineG = (185 + variation).clamp(160, 215);
                _inlineB = (15 + variation).clamp(5, 30);
              } else {
                _inlineR = (35 + variation).clamp(15, 55);
                _inlineG = (145 + variation).clamp(120, 175);
                _inlineB = (30 + variation).clamp(12, 50);
              }
            default:
              if (pStage == stSprout) {
                _inlineR = (60 + variation).clamp(40, 85);
                _inlineG = (200 + variation).clamp(175, 230);
                _inlineB = (45 + variation).clamp(25, 70);
              } else {
                _inlineR = (25 + variation).clamp(10, 45);
                _inlineG = (160 + variation).clamp(135, 190);
                _inlineB = (25 + variation).clamp(10, 45);
              }
          }
        }

      case El.ice:
        _inlineA = 255;
        // Multi-frequency sparkle: sharp glints at different rates per pixel
        final iceHash = _smoothHash(x * 31, y * 47);
        final iceGlintPhase = (iceHash % 45);
        final iceGlintActive = ((frameCount + iceGlintPhase) % 45);
        final isIceGlint = iceGlintActive < 2 && (iceHash % 3 == 0);
        final iceGlint = isIceGlint ? 40 : 0;
        // Crystalline facets: 6 tones for more visual variety
        final iceFacet = iceHash % 6;
        // Internal crack network: dark lines through the ice
        final crackHash = _smoothHash(x * 7, y * 13);
        final isCrack = crackHash % 15 == 0;
        final crackDarken = isCrack ? 35 : 0;
        // Internal refraction shimmer: slow color shift
        final iceRefP = (frameCount * 6 + x * 51 + y * 26) >> 8;
        final iceRefract = (_fastSinI(iceRefP) * 8) >> 8; // 0-8
        // Depth: deeper ice is bluer and darker
        int iceDepth = 0;
        for (int dy = 1; dy <= 8 && y - dy >= 0; dy++) {
          if (grid[(y - dy) * w + x] == El.ice) {
            iceDepth++;
          } else {
            break;
          }
        }
        final iceDepthDarken = (iceDepth * 4).clamp(0, 32);
        final iceDepthBlue = (iceDepth * 2).clamp(0, 16);
        int iceBaseR, iceBaseG;
        if (iceFacet == 0) {
          iceBaseR = 190; iceBaseG = 230;
        } else if (iceFacet == 1) {
          iceBaseR = 175; iceBaseG = 222;
        } else if (iceFacet == 2) {
          iceBaseR = 165; iceBaseG = 215;
        } else if (iceFacet == 3) {
          iceBaseR = 200; iceBaseG = 235;
        } else if (iceFacet == 4) {
          iceBaseR = 182; iceBaseG = 225;
        } else {
          iceBaseR = 172; iceBaseG = 218;
        }
        _inlineR = (iceBaseR + iceGlint + iceRefract - crackDarken - iceDepthDarken).clamp(130, 255);
        _inlineG = (iceBaseG + iceGlint + iceRefract ~/ 2 - crackDarken ~/ 2 - iceDepthDarken ~/ 2).clamp(175, 255);
        _inlineB = (255 + iceGlint ~/ 2 - crackDarken ~/ 3 + iceDepthBlue).clamp(220, 255);

      case El.stone:
        _inlineA = 255;
        final stoneHeat = velX[idx].clamp(0, 5);
        final stoneDepth = life[idx].clamp(0, 20);
        final depthDarken = stoneDepth * 2; // deeper = darker
        // Smooth layered look with spatial gradients
        final stoneSpatial = _spatialBlend(x, y, 6);
        final stoneLayer = (stoneSpatial * 16) ~/ 256 - 8;
        // Subtle geological strata — wide bands (20 rows), tight gray range
        final strataHash = _smoothHash(0, y ~/ 20);
        final strataType = strataHash % 4;
        int strataR, strataG, strataB;
        if (strataType == 0) {
          strataR = 125; strataG = 125; strataB = 130;
        } else if (strataType == 1) {
          strataR = 128; strataG = 126; strataB = 127;
        } else if (strataType == 2) {
          strataR = 122; strataG = 123; strataB = 128;
        } else {
          strataR = 126; strataG = 125; strataB = 126;
        }
        // Gentle transition at boundaries
        final strataEdge = (y % 20 == 0) ? -2 : 0;
        // Subtle horizontal sediment banding within each layer
        final sediment = _spatialBlend(x + 50, y * 2, 10);
        final sedimentShift = (sediment * 10) ~/ 256 - 5;
        // Horizontal band emphasis for sedimentary look
        final hBand = _spatialBlend(x * 3, y, 12);
        final hBandShift = (hBand * 6) ~/ 256 - 3;
        // Mineral vein network: diagonal dark lines through stone
        final veinHash = _smoothHash(x * 3 + y * 5, x * 7 - y * 3);
        final isVein = veinHash % 18 == 0;
        final veinDarken = isVein ? 18 : 0;
        // Quartz/mineral flecks: rare bright sparkly inclusions
        final mineralHash = _smoothHash(x * 41, y * 53);
        final isQuartz = mineralHash % 30 == 0;
        final quartzBoost = isQuartz ? 25 : 0;
        // Mica shimmer: very rare specular flash in certain pixels
        final micaPhase = (mineralHash % 70);
        final micaActive = ((frameCount + micaPhase) % 70);
        final isMica = micaActive < 2 && mineralHash % 22 == 0;
        final micaFlash = isMica ? 35 : 0;
        _inlineR = (strataR + stoneLayer + hBandShift + strataEdge - depthDarken - veinDarken + quartzBoost + micaFlash).clamp(50, 195);
        _inlineG = (strataG + stoneLayer + sedimentShift + hBandShift + strataEdge - depthDarken - veinDarken + quartzBoost ~/ 2 + micaFlash).clamp(48, 190);
        _inlineB = (strataB + stoneLayer - sedimentShift + hBandShift + strataEdge - depthDarken ~/ 2 - veinDarken ~/ 2 + quartzBoost ~/ 3 + micaFlash).clamp(60, 200);
        if (stoneHeat > 0) {
          // Integer heat glow: heatFrac = stoneHeat/5 as [0,256]
          final heatFrac256 = stoneHeat * 256 ~/ 5;
          // pulse = sin * 0.3 + 0.7 -> [0.4, 1.0] -> [102, 256]
          final pulsePhase = (frameCount * 77 + idx * 26) >> 8;
          final pulseI = _fastSinI(pulsePhase); // [0, 256]
          final pulse256 = 102 + (pulseI * 154) >> 8; // [102, 256]
          _inlineR =
              (_inlineR + ((heatFrac256 * 130 * pulse256) >> 16))
                  .clamp(0, 255);
          _inlineG =
              (_inlineG + ((heatFrac256 * 45 * pulse256) >> 16))
                  .clamp(0, 255);
          _inlineB =
              (_inlineB - (heatFrac256 * 70 >> 8)).clamp(0, 255);
          if (frameCount % 20 == 0) {
            velX[idx] = (stoneHeat - 1).clamp(0, 5);
          }
        }

      case El.mud:
        _inlineA = 255;
        // Rich brown earth tones with smooth spatial variation
        final mudSpatial = _spatialBlend(x, y, 5);
        final mudVar = (mudSpatial * 20) ~/ 256 - 10;
        final mudWarmth = _spatialBlend(x + 77, y + 33, 7);
        final mudWarmShift = (mudWarmth * 12) ~/ 256 - 6;
        // Surface detection
        final isMudTop = y > 0 && grid[(y - 1) * w + x] != El.mud;
        // Animated wetness sheen: slow wave across surface
        int mudWetBoost = 0;
        if (isMudTop) {
          final mudSheenP = (frameCount * 12 + x * 102) >> 8;
          final mudSheen = (_fastSinI(mudSheenP) * 12) >> 8;
          mudWetBoost = 8 + mudSheen;
        }
        // Bubble spots: rare transient light circles on surface
        final mudBubHash = _smoothHash(x * 23, y * 11);
        final isMudBubble = isMudTop && mudBubHash % 35 == 0 &&
            ((frameCount + mudBubHash % 40) % 40 < 3);
        final mudBubbleBoost = isMudBubble ? 18 : 0;
        // Pebble inclusions: occasional lighter hard specks
        final mudPebble = _smoothHash(x * 37, y * 43) % 28 == 0 ? 10 : 0;
        _inlineR = (80 + mudVar + mudWarmShift + mudWetBoost + mudBubbleBoost + mudPebble).clamp(50, 120);
        _inlineG = (65 + mudVar ~/ 2 + mudWarmShift ~/ 2 + mudWetBoost ~/ 2 + mudBubbleBoost ~/ 2).clamp(35, 95);
        _inlineB = (45 + mudVar ~/ 3 + mudWetBoost ~/ 3 + mudBubbleBoost ~/ 3).clamp(22, 70);

      case El.oil:
        _inlineA = 255;
        final isOilTop = y > 0 && grid[(y - 1) * w + x] != El.oil;
        if (isOilTop) {
          // Iridescent surface shimmer -- integer rainbow oil slick
          final sp1 = (frameCount * 38 + x * 179) >> 8;
          final sp2 = (frameCount * 31 + x * 282 + 31) >> 8;
          final shimmer1 = _fastSinI(sp1); // [0, 256]
          final shimmer2 = _fastSinI(sp2); // [0, 256]
          // Rainbow iridescence phase: [0, 256] mapped from x*37+fc*2
          final iridP = ((x * 37 + frameCount * 2) % 120) * 256 ~/ 120;
          final iridR = (_fastSinI(iridP) * 20 >> 8) + 10;
          final iridG = (_fastSinI(iridP + 85) * 15 >> 8) + 3; // +85 ≈ 2.09/6.28*256
          final iridB = (_fastSinI(iridP + 170) * 20 >> 8) + 5; // +170 ≈ 4.19/6.28*256
          final shimVal = (shimmer1 * 14 + shimmer2 * 8) >> 8;
          _inlineR = (60 + shimVal + iridR).clamp(45, 110);
          _inlineG = (45 + shimVal + iridG).clamp(32, 85);
          _inlineB = (35 + shimVal ~/ 2 + iridB).clamp(25, 75);
        } else {
          // Deep oil body: dark with subtle spatial variation
          final oilSpatial = _spatialBlend(x, y, 5);
          final oilVar = (oilSpatial * 14) ~/ 256 - 7;
          _inlineR = (42 + oilVar).clamp(28, 58);
          _inlineG = (32 + oilVar).clamp(18, 48);
          _inlineB = (25 + oilVar).clamp(12, 40);
        }

      case El.acid:
        final acidPulsePhase = (frameCount * 38 + idx * 77) >> 8;
        final acidPulse = _fastSinI(acidPulsePhase); // [0, 256]
        final acidGlow = (acidPulse * 30) >> 8;
        final acidVar = ((idx * 7 + y * 3) % 11) - 5;
        // Bubbling surface: transient bright spots
        final acidHash = _smoothHash(x * 17, y * 29);
        final isAcidBubble = acidHash % 20 == 0 &&
            ((frameCount + acidHash % 30) % 30 < 3);
        final acidBubble = isAcidBubble ? 25 : 0;
        // Corrosion streaks: darker pools where acid is concentrated
        final isAcidConc = acidHash % 9 == 0;
        final acidConc = isAcidConc ? 12 : 0;
        // Surface detection: top acid slightly brighter (fizzing)
        final isAcidTop = y > 0 && grid[(y - 1) * w + x] != El.acid;
        final acidSurfFizz = isAcidTop ? 15 : 0;
        _inlineR = (20 + acidVar + acidGlow ~/ 3 + acidBubble ~/ 2 - acidConc ~/ 2).clamp(0, 85);
        _inlineG = (235 + acidVar + acidGlow ~/ 4 + acidBubble + acidSurfFizz - acidConc).clamp(200, 255);
        _inlineB = (20 + acidVar + acidGlow ~/ 5 + acidBubble ~/ 3).clamp(0, 70);
        _inlineA = 255;

      case El.glass:
        // More frequent sparkle (1/10 frames instead of 2/20)
        final sparkle =
            (frameCount + idx * 3) % 10 < 1 ? 35 : 0;
        final variation = ((idx * 7 + y * 3) % 11) - 5;
        // Count glass depth (cells above that are also glass, max 6)
        int glassDepth = 0;
        for (int dy = 1; dy <= 6 && y - dy >= 0; dy++) {
          if (grid[(y - dy) * w + x] == El.glass) {
            glassDepth++;
          } else {
            break;
          }
        }
        // Deeper glass gets more blue-tinted
        final depthBlue = (glassDepth * 8).clamp(0, 48);
        // Refraction shimmer: slight RGB shift based on depth + frame
        final shimmerPhase = _fastSinI((frameCount * 3 + idx * 7 + glassDepth * 40) & 0xFF);
        final shimmerVal = (shimmerPhase - 128) ~/ 16; // -8 to +8
        _inlineR = (210 + variation + sparkle - depthBlue + shimmerVal).clamp(160, 255);
        _inlineG = (225 + variation + sparkle - depthBlue ~/ 2 + shimmerVal ~/ 2).clamp(185, 255);
        _inlineB = (255 + sparkle).clamp(240, 255);
        _inlineA = (200 + depthBlue ~/ 3).clamp(200, 220);

      case El.lava:
        final lavaLife = life[idx];
        // Two-frequency flicker for organic molten look
        final flickerHash1 = ((frameCount * 7 + idx * 13) >> 3) & 0x1F;
        final flickerHash2 = ((frameCount * 5 + idx * 19) >> 4) & 0xF;
        final lavaFlicker = (flickerHash1 < 16 ? flickerHash1 : 31 - flickerHash1) +
            (flickerHash2 < 8 ? flickerHash2 : 15 - flickerHash2) ~/ 2;
        final isLavaSurf = y > 0 && grid[(y - 1) * w + x] == El.empty;

        // Warm molten look — NOT blinding white
        if (lavaLife < 30) {
          // Fresh lava: warm orange-red with convection patterns
          final surfBoost = isLavaSurf ? 10 : 0;
          // Convection cells: slow-moving bright/dark patches
          final convectP = (frameCount * 3 + x * 26 + y * 18) >> 8;
          final convect = (_fastSinI(convectP) * 15) >> 8;
          _inlineR = 255;
          _inlineG = (160 + lavaFlicker + surfBoost + convect).clamp(135, 210);
          _inlineB = (40 + lavaFlicker ~/ 2 + convect ~/ 2).clamp(15, 85);
          _inlineA = 255;
        } else if (lavaLife < 80) {
          // Cooling: deep red-orange with dark crust forming
          final t2 = ((lavaLife - 30) * 255 ~/ 50).clamp(0, 255);
          final crustHash = _smoothHash(x, y);
          final isCrustVein = lavaLife > 45 && (crustHash % 5 == 0);
          if (isCrustVein) {
            // Dark cooling crust with pulsing glow underneath
            final crustGlowP = ((frameCount * 4 + idx * 7) >> 4) & 0xF;
            final crustGlow = crustGlowP < 8 ? crustGlowP * 3 : (15 - crustGlowP) * 3;
            _inlineR = (120 + crustGlow + lavaFlicker ~/ 3).clamp(90, 170);
            _inlineG = (14 + crustGlow ~/ 4 + lavaFlicker ~/ 6).clamp(6, 40);
            _inlineB = (crustGlow ~/ 8 + lavaFlicker ~/ 10).clamp(0, 10);
          } else {
            _inlineR = 255;
            _inlineG = (_lerpC(210, 55, t2) + lavaFlicker ~/ 2).clamp(0, 255);
            _inlineB = (lavaFlicker ~/ 3).clamp(0, 35);
          }
          _inlineA = 255;
        } else if (lavaLife < 140) {
          // Mostly cooled: dark red with glowing cracks
          final t2 = ((lavaLife - 80) * 255 ~/ 60).clamp(0, 255);
          final crustHash = _smoothHash(x, y);
          final isGlowingCrack = crustHash % 7 == 0;
          if (isGlowingCrack) {
            // Glowing crack in dark crust — cheap pulse
            final crackPhase = ((frameCount * 3 + idx * 5) >> 4) & 0xF;
            final crackPulse = crackPhase < 8 ? crackPhase : 15 - crackPhase;
            _inlineR = (220 + crackPulse * 2).clamp(200, 255);
            _inlineG = (60 + crackPulse * 2).clamp(40, 100);
            _inlineB = (10 + crackPulse ~/ 2).clamp(5, 25);
          } else {
            _inlineR = _lerpC(230, 100, t2);
            _inlineG = (_lerpC(40, 12, t2) + lavaFlicker ~/ 5).clamp(0, 50);
            _inlineB = (lavaFlicker ~/ 8).clamp(0, 8);
          }
          _inlineA = 255;
        } else {
          // Solidifying: very dark with occasional faint glow
          final t2 = ((lavaLife - 140) * 255 ~/ 60).clamp(0, 255);
          final crustHash = _smoothHash(x, y);
          final isDarkPatch = crustHash % 4 < 2;
          if (isDarkPatch) {
            _inlineR = (_lerpC(140, 70, t2)).clamp(0, 255);
            _inlineG = (_lerpC(15, 5, t2) + lavaFlicker ~/ 8).clamp(0, 25);
            _inlineB = 0;
          } else {
            _inlineR = _lerpC(200, 110, t2);
            _inlineG = (_lerpC(35, 12, t2) + lavaFlicker ~/ 5).clamp(0, 50);
            _inlineB = (lavaFlicker ~/ 8).clamp(0, 8);
          }
          _inlineA = 255;
        }

      case El.snow:
        _inlineA = 255;
        final snowHash = _smoothHash(x, y);
        final snowVar = (snowHash % 256 * 8) ~/ 256 - 4;
        // Multi-frequency sparkle/glitter — different pixels glint at different times
        final snowSparkHash = _smoothHash(x * 31, y * 47);
        final snowSparkPhase = (snowSparkHash % 50);
        final snowSparkActive = ((frameCount + snowSparkPhase) % 50);
        // Sharp, bright sparkle that appears and disappears quickly
        final isSnowSparkle = snowSparkActive < 3 && (snowSparkHash % 3 == 0);
        final snowSparkInt = isSnowSparkle ? 50 : 0;
        // Secondary rainbow prismatic glint: rare ice crystal refraction
        final isPrismatic = snowSparkActive < 1 && snowSparkHash % 12 == 0;
        // Slower gentle shimmer for overall snow surface
        final snowShimPhase = (frameCount * 6 + snowSparkHash) >> 8;
        final snowShimVal = (_fastSinI(snowShimPhase) * 6) >> 8;
        // Surface snow is slightly brighter than buried snow
        final isSnowSurface = y > 0 && grid[(y - 1) * w + x] != El.snow;
        final snowSurfBoost = isSnowSurface ? 8 : 0;
        // Depth: buried snow gets slightly blue-tinted (compacted ice)
        int snowDepth = 0;
        for (int dy = 1; dy <= 6 && y - dy >= 0; dy++) {
          if (grid[(y - dy) * w + x] == El.snow) {
            snowDepth++;
          } else {
            break;
          }
        }
        final snowDepthBlue = (snowDepth * 2).clamp(0, 12);
        final snowDepthDarken = (snowDepth).clamp(0, 6);
        // Prismatic: brief rainbow tint on sparkle
        final prismR = isPrismatic ? 15 : 0;
        final prismB = isPrismatic ? -10 : 0;
        _inlineR = (235 + snowVar + snowShimVal + snowSparkInt + snowSurfBoost - snowDepthDarken + prismR).clamp(218, 255);
        _inlineG = (238 + snowVar + snowShimVal + snowSparkInt + snowSurfBoost - snowDepthDarken ~/ 2).clamp(222, 255);
        _inlineB = (250 + snowSparkInt ~/ 2 + snowDepthBlue + prismB).clamp(240, 255);

      case El.wood:
        _inlineA = 255;
        final woodVar = ((idx * 7 + y * 3) % 11) - 5;
        if (life[idx] > 0) {
          // Burning wood: ember glow with charring edges
          final burnP = (frameCount * 64 + life[idx] * 77) >> 8;
          final burnPhase = _fastSinI(burnP); // [0, 256]
          final bright = (burnPhase * 35) >> 8;
          // Charring: some pixels go dark as burn progresses
          final burnHash = _smoothHash(x * 13, y * 17);
          final isCharring = life[idx] > 15 && burnHash % 4 == 0;
          if (isCharring) {
            _inlineR = (100 + bright ~/ 2).clamp(70, 140);
            _inlineG = (25 + bright ~/ 4).clamp(10, 50);
            _inlineB = 5;
          } else {
            _inlineR = (200 + bright).clamp(185, 255);
            _inlineG = (80 + bright - life[idx]).clamp(20, 120);
            _inlineB = 10;
          }
        } else {
          // Warm brown with visible vertical grain, knots, and bark texture
          final vertGrain = _spatialBlend(x, y * 4, 3);
          final grainVal = (vertGrain * 18) ~/ 256 - 9;
          final woodHash = _smoothHash(x * 11, y * 7);
          final isKnot = woodHash % 19 == 0;
          final waterlog = velY[idx].clamp(0, 3) * 20;
          // Growth ring effect: concentric darkening around knots
          final ringPhase = _spatialBlend(x * 2, y * 2, 5);
          final ringDark = (ringPhase > 180 && ringPhase < 200) ? 8 : 0;
          // Bark texture: exposed surface is rougher
          final isWoodSurface = (x > 0 && grid[y * w + x - 1] != El.wood) ||
              (x < w - 1 && grid[y * w + x + 1] != El.wood) ||
              (y > 0 && grid[(y - 1) * w + x] != El.wood);
          final barkRough = isWoodSurface ? (woodHash % 8 - 4).clamp(-3, 3) : 0;
          if (isKnot) {
            // Darker concentric knot with warm center
            final knotCenter = _smoothHash(x * 3, y * 3) % 3 == 0;
            final knotShift = knotCenter ? 8 : 0;
            _inlineR = (115 - waterlog + grainVal + knotShift).clamp(48, 145);
            _inlineG = (60 - waterlog + grainVal ~/ 2 + knotShift ~/ 2).clamp(22, 85);
            _inlineB = (32 - waterlog + grainVal ~/ 3).clamp(8, 52);
          } else {
            // Vertical grain emphasis with warm tones
            final woodBand = _spatialBlend(x, y * 5, 3);
            final woodBandShift = (woodBand * 20) ~/ 256 - 10;
            _inlineR = (160 - waterlog + woodVar + woodBandShift + barkRough - ringDark).clamp(60, 195);
            _inlineG = (85 - waterlog + woodVar ~/ 2 + woodBandShift ~/ 2 + barkRough ~/ 2 - ringDark ~/ 2).clamp(28, 118);
            _inlineB = (46 - waterlog + woodVar ~/ 3 + woodBandShift ~/ 3 - ringDark ~/ 3).clamp(10, 72);
          }
        }

      case El.metal:
        _inlineA = 255;
        final metalVar = ((idx * 7 + y * 3) % 11) - 5;
        if (life[idx] >= 200) {
          life[idx]--;
          if (life[idx] < 200) life[idx] = 0;
          _inlineR = 255;
          _inlineG = 255;
          _inlineB = 136;
        } else {
          final rustLevel = life[idx].clamp(0, 120);
          if (rustLevel > 0) {
            // Rust with pitting texture
            final rustHash = _smoothHash(x * 19, y * 23);
            final isPit = rustHash % 8 == 0;
            final pitDarken = isPit ? 15 : 0;
            _inlineR = (168 - (rustLevel * 29) ~/ 120 + metalVar - pitDarken).clamp(90, 200);
            _inlineG = (168 - (rustLevel * 78) ~/ 120 + metalVar - pitDarken).clamp(50, 200);
            _inlineB = (176 - (rustLevel * 133) ~/ 120 + metalVar - pitDarken ~/ 2).clamp(25, 210);
          } else {
            // Brushed metal texture: horizontal micro-scratches
            final brushHash = _smoothHash(x * 3, y * 71);
            final isScratch = brushHash % 7 == 0;
            final scratchShift = isScratch ? ((brushHash >> 8) % 5 - 2) : 0;
            // Two-frequency metallic sheen: broad + specular
            final sheenP1 = (frameCount * 26 + x * 77 + y * 51) >> 8;
            final sheenP2 = (frameCount * 14 + x * 154 + y * 26) >> 8;
            final sheen1 = (_fastSinI(sheenP1) * 14) >> 8;
            final sheen2 = (_fastSinI(sheenP2) * 8) >> 8;
            final totalSheen = sheen1 + sheen2;
            // Specular highlight: rare bright flash
            final metalSpecHash = _smoothHash(x * 43, y * 59);
            final metalSpecPhase = (metalSpecHash % 55);
            final metalSpecActive = ((frameCount + metalSpecPhase) % 55);
            final isMetalSpec = metalSpecActive < 2 && metalSpecHash % 5 == 0;
            final metalSpecFlash = isMetalSpec ? 28 : 0;
            _inlineR = (168 + totalSheen + metalVar + scratchShift + metalSpecFlash).clamp(140, 218);
            _inlineG = (168 + totalSheen + metalVar + scratchShift + metalSpecFlash).clamp(140, 218);
            _inlineB = (176 + totalSheen + metalVar + scratchShift ~/ 2 + metalSpecFlash).clamp(148, 225);
          }
          // Heat glow: hot metal shifts from silver to orange-red with pulsing
          final metalHeat = velX[idx].clamp(0, 5);
          if (metalHeat > 0) {
            final hf = metalHeat * 256 ~/ 5;
            final pp = (frameCount * 77 + idx * 26) >> 8;
            final pi = _fastSinI(pp);
            final p256 = 102 + (pi * 154) >> 8;
            _inlineR = (_inlineR + ((hf * 140 * p256) >> 16)).clamp(0, 255);
            _inlineG = (_inlineG + ((hf * 50 * p256) >> 16)).clamp(0, 255);
            _inlineB = (_inlineB - (hf * 80 >> 8)).clamp(0, 255);
            // White-hot at max heat
            if (metalHeat >= 4) {
              final whiteBlend = (metalHeat - 3) * 40;
              _inlineG = (_inlineG + whiteBlend).clamp(0, 255);
              _inlineB = (_inlineB + whiteBlend ~/ 3).clamp(0, 255);
            }
          }
        }

      case El.smoke:
        final smokeLife = life[idx];
        final smokeFade = (60 - smokeLife).clamp(0, 60);
        // Two-frequency wisp for more organic cloud feel
        final wispP1 = (frameCount * 26 + idx * 128) >> 8;
        final wispP2 = (frameCount * 18 + idx * 77 + 38) >> 8;
        final wisp1 = (_fastSinI(wispP1) * 12) >> 8;
        final wisp2 = (_fastSinI(wispP2) * 8) >> 8;
        final smokeWispVal = wisp1 + wisp2;
        // Alpha: young smoke is more opaque, fades to near-invisible wisps
        _inlineA = (smokeFade * 3 + 50).clamp(50, 200);
        final smokeBase =
            _lerpC(145, 90, (smokeLife * 255 ~/ 60).clamp(0, 255));
        final smokeVar = ((idx * 7 + y * 3) % 11) - 5;
        // Volumetric density: nearby smoke makes this cell denser (darker, more opaque)
        int smokeNeighbors = 0;
        if (y > 0 && grid[idx - w] == El.smoke) smokeNeighbors++;
        if (y < h - 1 && grid[idx + w] == El.smoke) smokeNeighbors++;
        if (x > 0 && grid[idx - 1] == El.smoke) smokeNeighbors++;
        if (x < w - 1 && grid[idx + 1] == El.smoke) smokeNeighbors++;
        final densityDarken = smokeNeighbors * 5;
        if (smokeNeighbors >= 3) {
          _inlineA = (_inlineA + 20).clamp(0, 220);
        }
        // Warm grey with slight brown tint (combustion smoke)
        _inlineR = (smokeBase + 8 + smokeVar + smokeWispVal - densityDarken).clamp(80, 175);
        _inlineG = (smokeBase + smokeVar + smokeWispVal ~/ 2 - densityDarken).clamp(72, 160);
        _inlineB = (smokeBase - 8 + smokeVar + smokeWispVal ~/ 3 - densityDarken ~/ 2).clamp(68, 158);

      case El.bubble:
        // Iridescent soap-bubble feel with shifting rainbow highlight (integer)
        final bubbleP1 = (frameCount * 20 + idx * 128) >> 8;
        final bubbleP2 = (frameCount * 14 + idx * 90 + 38) >> 8;
        final iridShift = _fastSinI(bubbleP1); // [0, 256]
        final iridShift2 = _fastSinI(bubbleP2); // [0, 256]
        // Specular highlight that moves across the bubble
        final highlight = (frameCount + idx * 7) % 40 < 4 ? 40 : 0;
        // Base: light cyan-white with rainbow shimmer
        _inlineR = (180 + (iridShift * 50 >> 8) + highlight).clamp(165, 255);
        _inlineG = (210 + (iridShift2 * 35 >> 8) + highlight).clamp(195, 255);
        _inlineB = (240 + highlight).clamp(230, 255);
        // Very translucent to show what's behind
        _inlineA = (120 + (iridShift * 30 >> 8)).clamp(100, 160);

      case El.ash:
        final ashVar = ((idx * 7 + y * 3) % 11) - 5;
        final ashV = ((idx % 7) * 3 + ashVar).clamp(0, 20);
        // Floating vs settled: airborne ash is lighter and more transparent
        final ashBelow = y < h - 1 ? grid[(y + 1) * w + x] : El.stone;
        final ashSettled = ashBelow != El.empty && ashBelow != El.smoke &&
            ashBelow != El.steam && ashBelow != El.ash;
        // Gentle drift shimmer for airborne ash
        final ashDriftP = (frameCount * 10 + idx * 51) >> 8;
        final ashDrift = ashSettled ? 0 : ((_fastSinI(ashDriftP) * 6) >> 8);
        // Settled ash is slightly darker and warmer (char residue)
        if (ashSettled) {
          _inlineR = (170 - ashV).clamp(140, 192);
          _inlineG = (168 - ashV).clamp(138, 190);
          _inlineB = (172 - ashV).clamp(142, 195);
          _inlineA = 230;
        } else {
          _inlineR = (182 - ashV + ashDrift).clamp(155, 210);
          _inlineG = (182 - ashV + ashDrift).clamp(155, 210);
          _inlineB = (188 - ashV + ashDrift ~/ 2).clamp(162, 215);
          _inlineA = (190 + ashDrift * 3).clamp(180, 215);
        }

      case El.oxygen:
        // Oxygen is INVISIBLE in open air (it IS the air).
        // Only shows as a faint shimmer underground where it's unusual.
        if (!_isUnderground(x, y, engine.gridW, engine.grid)) {
          _inlineA = 0; // fully transparent — sky gradient shows through
        } else {
          // Underground oxygen: subtle pale blue shimmer (rare, notable)
          final oxyWisp = ((frameCount * 3 + idx * 11) >> 4) & 0xF;
          final oxyShift = oxyWisp < 8 ? oxyWisp : 15 - oxyWisp;
          _inlineR = (192 + oxyShift).clamp(190, 205);
          _inlineG = (210 + oxyShift).clamp(208, 225);
          _inlineB = (240 + oxyShift ~/ 2).clamp(238, 250);
          _inlineA = 12 + oxyShift; // very subtle even underground
        }

      case El.co2:
        // CO2: visible underground (pooling in caves), subtle above ground
        final co2Wisp = ((frameCount * 2 + idx * 9) >> 4) & 0xF;
        final co2Shift = co2Wisp < 8 ? co2Wisp : 15 - co2Wisp;
        _inlineR = (150 + co2Shift).clamp(148, 165);
        _inlineG = (155 + co2Shift).clamp(153, 168);
        _inlineB = (175 + co2Shift ~/ 2).clamp(173, 185);
        _inlineA = _isUnderground(x, y, engine.gridW, engine.grid) ? 30 + co2Shift : 8 + (co2Shift >> 1);

      case El.hydrogen:
        // Hydrogen is invisible in open air, faint shimmer underground
        if (!_isUnderground(x, y, engine.gridW, engine.grid)) {
          _inlineA = 0;
        } else {
          final h2Wisp = ((frameCount * 4 + idx * 13) >> 4) & 0xF;
          final h2Shift = h2Wisp < 8 ? h2Wisp : 15 - h2Wisp;
          _inlineR = (210 + h2Shift).clamp(208, 225);
          _inlineG = (220 + h2Shift).clamp(218, 235);
          _inlineB = (248 + h2Shift ~/ 3).clamp(246, 255);
          _inlineA = 10 + h2Shift ~/ 2;
        }

      case El.methane:
        // Methane: visible underground (cave gas), subtle above ground
        final methWisp = ((frameCount * 3 + idx * 7) >> 4) & 0xF;
        final methShift = methWisp < 8 ? methWisp : 15 - methWisp;
        _inlineR = (170 + methShift).clamp(168, 185);
        _inlineG = (210 + methShift).clamp(208, 225);
        _inlineB = (170 + methShift ~/ 2).clamp(168, 180);
        _inlineA = _isUnderground(x, y, engine.gridW, engine.grid) ? 25 + methShift : 6 + (methShift >> 1);

      case El.fungus:
        // Rich brownish-gold with organic texture variation
        _inlineA = 255;
        final fungSpatial = _spatialBlend(x, y, 4);
        final fungVar = (fungSpatial * 24) ~/ 256 - 12;
        // Organic noise: dark fibrous patches
        final fungHash = _smoothHash(x * 17, y * 23);
        final isDarkFiber = fungHash % 7 == 0;
        final fiberDarken = isDarkFiber ? 22 : 0;
        // Light speckles for bracket fungi texture
        final isLight = fungHash % 11 == 0;
        final lightBoost = isLight ? 15 : 0;
        _inlineR = (139 + fungVar - fiberDarken + lightBoost).clamp(90, 170);
        _inlineG = (105 + fungVar ~/ 2 - fiberDarken + lightBoost ~/ 2).clamp(60, 130);
        _inlineB = (20 + fungVar ~/ 4 - fiberDarken ~/ 2).clamp(5, 45);

      case El.spore:
        // Tiny yellowish semi-transparent dots
        final sporePhase = ((frameCount * 5 + idx * 17) >> 4) & 0xF;
        final sporePulse = sporePhase < 8 ? sporePhase : 15 - sporePhase;
        _inlineR = (184 + sporePulse * 2).clamp(180, 205);
        _inlineG = (168 + sporePulse * 2).clamp(164, 190);
        _inlineB = (60 + sporePulse).clamp(55, 80);
        _inlineA = (140 + sporePulse * 4).clamp(130, 180);

      case El.charcoal:
        // Very dark grey-black with slight texture variation
        _inlineA = 255;
        final charSpatial = _spatialBlend(x, y, 4);
        final charVar = (charSpatial * 12) ~/ 256 - 6;
        // Rough fractured surface: occasional lighter facet
        final charHash = _smoothHash(x * 13, y * 19);
        final isFacet = charHash % 9 == 0;
        final facetBoost = isFacet ? 12 : 0;
        _inlineR = (38 + charVar + facetBoost).clamp(25, 60);
        _inlineG = (38 + charVar + facetBoost).clamp(25, 60);
        _inlineB = (42 + charVar + facetBoost).clamp(28, 65);

      case El.compost:
        // Dark rich brown, almost black, earthy
        _inlineA = 255;
        final compSpatial = _spatialBlend(x, y, 5);
        final compVar = (compSpatial * 16) ~/ 256 - 8;
        // Organic matter: occasional lighter decomposing flecks
        final compHash = _smoothHash(x * 19, y * 13);
        final isFleck = compHash % 10 == 0;
        final fleckBoost = isFleck ? 14 : 0;
        // Worm-like darker streaks
        final isStreak = compHash % 13 == 0 && (compHash >> 8) % 3 == 0;
        final streakDarken = isStreak ? 10 : 0;
        _inlineR = (52 + compVar + fleckBoost - streakDarken).clamp(28, 75);
        _inlineG = (36 + compVar ~/ 2 + fleckBoost ~/ 2 - streakDarken).clamp(14, 55);
        _inlineB = (8 + compVar ~/ 4 + fleckBoost ~/ 4).clamp(2, 22);

      case El.rust:
        // Orange-brown with rough texture — more variation than solid metal
        _inlineA = 255;
        final rustSpatial = _spatialBlend(x, y, 4);
        final rustVar = (rustSpatial * 28) ~/ 256 - 14;
        // Rough pitted surface with two-tone patchy look
        final rustHash = _smoothHash(x * 11, y * 17);
        final isPit = rustHash % 6 == 0;
        final pitDarken = isPit ? 20 : 0;
        // Lighter flaky patches
        final isFlake = rustHash % 8 == 0 && !isPit;
        final flakeBoost = isFlake ? 18 : 0;
        _inlineR = (160 + rustVar - pitDarken + flakeBoost).clamp(100, 195);
        _inlineG = (68 + rustVar ~/ 2 - pitDarken ~/ 2 + flakeBoost ~/ 2).clamp(30, 100);
        _inlineB = (28 + rustVar ~/ 4 - pitDarken ~/ 3).clamp(8, 50);

      case El.salt:
        // Bright white-cream crystalline with occasional sparkle
        _inlineA = 255;
        final saltHash = _smoothHash(x * 31, y * 47);
        final saltFacet = saltHash % 4;
        // Crystalline facets: slightly different tones
        final saltBase = saltFacet == 0 ? 240 : (saltFacet == 1 ? 236 : (saltFacet == 2 ? 244 : 238));
        // Sparkling: sharp bright pixel glints
        final saltSparkPhase = (saltHash % 50);
        final saltSparkActive = ((frameCount + saltSparkPhase) % 50);
        final isSaltSparkle = saltSparkActive < 2 && (saltHash % 3 == 0);
        final saltSparkIntensity = isSaltSparkle ? 16 : 0;
        _inlineR = (saltBase + saltSparkIntensity).clamp(228, 255);
        _inlineG = (saltBase - 4 + saltSparkIntensity).clamp(224, 255);
        _inlineB = (saltBase - 10 + saltSparkIntensity ~/ 2).clamp(218, 252);

      case El.clay:
        // Warm terracotta with slight depth variation
        _inlineA = 255;
        final claySpatial = _spatialBlend(x, y, 5);
        final clayVar = (claySpatial * 20) ~/ 256 - 10;
        // Sediment banding for layered look
        final clayBand = _spatialBlend(x + 60, y * 2, 8);
        final clayBandShift = (clayBand * 10) ~/ 256 - 5;
        // Occasional darker inclusions
        final clayHash = _smoothHash(x * 23, y * 11);
        final isInclusion = clayHash % 14 == 0;
        final inclusionDarken = isInclusion ? 15 : 0;
        _inlineR = (196 + clayVar + clayBandShift - inclusionDarken).clamp(155, 225);
        _inlineG = (130 + clayVar ~/ 2 + clayBandShift ~/ 2 - inclusionDarken).clamp(90, 160);
        _inlineB = (86 + clayVar ~/ 3 + clayBandShift ~/ 3 - inclusionDarken ~/ 2).clamp(55, 115);

      case El.algae:
        // Dark green, slightly transparent in water
        _inlineA = 255;
        final algaeSpatial = _spatialBlend(x, y, 3);
        final algaeVar = (algaeSpatial * 18) ~/ 256 - 9;
        // Check if submerged in water for transparency
        final algaeInWater = (y > 0 && grid[(y - 1) * w + x] == El.water) ||
            (y < h - 1 && grid[(y + 1) * w + x] == El.water);
        if (algaeInWater) {
          _inlineA = 200;
        }
        // Organic frond variation
        final algaeHash = _smoothHash(x * 7, y * 13);
        final isFrondTip = algaeHash % 8 == 0;
        final tipLighten = isFrondTip ? 20 : 0;
        _inlineR = (30 + algaeVar + tipLighten ~/ 2).clamp(15, 60);
        _inlineG = (125 + algaeVar + tipLighten).clamp(90, 170);
        _inlineB = (35 + algaeVar ~/ 2 + tipLighten ~/ 3).clamp(18, 60);

      case El.seaweed:
        _inlineA = 230;
        final swVar = ((idx * 7 + y * 5) % 13) - 6;
        // Subtle sway animation based on frame
        final swSway = ((frameCount + x * 3) % 40 < 20) ? 5 : -5;
        // Check for toxin tint from colony
        final swToxin = engine.plantColonies != null
            ? (engine.plantColonies!.colonyForCell(idx)?.toxinLevel ?? 0.0) : 0.0;
        final toxinShift = (swToxin * 30).toInt(); // purple shift for toxic
        _inlineR = (26 + swVar + toxinShift).clamp(10, 70);
        _inlineG = (96 + swVar + swSway).clamp(60, 140);
        _inlineB = (48 + swVar + toxinShift ~/ 2).clamp(25, 80);

      case El.moss:
        _inlineA = 255;
        final mossVar = ((idx * 11 + y * 3) % 9) - 4;
        final mossHash = _smoothHash(x * 5, y * 9);
        final isSpeck = mossHash % 12 == 0;
        final speckLight = isSpeck ? 15 : 0;
        _inlineR = (74 + mossVar + speckLight).clamp(50, 100);
        _inlineG = (122 + mossVar + speckLight).clamp(90, 155);
        _inlineB = (58 + mossVar ~/ 2).clamp(35, 80);

      case El.vine:
        _inlineA = 255;
        final vineVar = ((idx * 9 + y * 7) % 11) - 5;
        final vineIsLeaf = (velY[idx] % 3 == 0);
        if (vineIsLeaf) {
          _inlineR = (35 + vineVar).clamp(15, 55);
          _inlineG = (175 + vineVar).clamp(150, 210);
          _inlineB = (40 + vineVar).clamp(20, 60);
        } else {
          _inlineR = (48 + vineVar).clamp(25, 70);
          _inlineG = (140 + vineVar).clamp(110, 170);
          _inlineB = (35 + vineVar).clamp(15, 55);
        }

      case El.flower:
        _inlineA = 255;
        final flVar = ((idx * 13 + y * 5) % 11) - 5;
        final flSize = velY[idx].clamp(0, 127);
        if (flSize >= plantMaxH[plantNeuralFlower] - 1) {
          // Bloom: colorful petals, varied per-colony
          final hue = ((idx * 37) % 5);
          switch (hue) {
            case 0:
              _inlineR = (224 + flVar).clamp(200, 255);
              _inlineG = (96 + flVar).clamp(70, 130);
              _inlineB = (160 + flVar).clamp(130, 200);
            case 1:
              _inlineR = (255);
              _inlineG = (200 + flVar).clamp(170, 230);
              _inlineB = (60 + flVar).clamp(30, 90);
            case 2:
              _inlineR = (200 + flVar).clamp(170, 230);
              _inlineG = (60 + flVar).clamp(30, 90);
              _inlineB = (240 + flVar).clamp(210, 255);
            case 3:
              _inlineR = (255);
              _inlineG = (100 + flVar).clamp(70, 130);
              _inlineB = (100 + flVar).clamp(70, 130);
            default:
              _inlineR = (220 + flVar).clamp(190, 255);
              _inlineG = (180 + flVar).clamp(150, 210);
              _inlineB = (80 + flVar).clamp(50, 110);
          }
        } else {
          // Stem: green
          _inlineR = (45 + flVar).clamp(25, 65);
          _inlineG = (160 + flVar).clamp(135, 190);
          _inlineB = (35 + flVar).clamp(15, 55);
        }

      case El.root:
        _inlineA = 255;
        final rootVar = ((idx * 7 + x * 3) % 9) - 4;
        final rootHash = _smoothHash(x * 3, y * 7);
        final rootGrain = (rootHash % 5 == 0) ? 8 : 0;
        _inlineR = (106 + rootVar + rootGrain).clamp(75, 135);
        _inlineG = (74 + rootVar + rootGrain ~/ 2).clamp(45, 100);
        _inlineB = (32 + rootVar ~/ 2).clamp(15, 50);

      case El.thorn:
        _inlineA = 255;
        final thornVar = ((idx * 5 + y * 11) % 7) - 3;
        final thornHash = _smoothHash(x * 9, y * 3);
        final isPoint = thornHash % 5 == 0;
        final pointLight = isPoint ? 20 : 0;
        _inlineR = (80 + thornVar + pointLight).clamp(55, 115);
        _inlineG = (80 + thornVar + pointLight ~/ 2).clamp(55, 110);
        _inlineB = (48 + thornVar).clamp(30, 70);

      case El.honey:
        // Golden amber with depth gradient — darker at bottom, lighter at top
        _inlineA = 255;
        // Depth: count honey cells above
        int honeyDepth = 0;
        for (int dy = 1; dy <= 10 && y - dy >= 0; dy++) {
          if (grid[(y - dy) * w + x] == El.honey) {
            honeyDepth++;
          } else {
            break;
          }
        }
        final honeyDepthFrac = (honeyDepth * 256 ~/ 10).clamp(0, 255);
        // Top: lighter golden, deeper: darker amber
        final honeyR = _lerpC(220, 170, honeyDepthFrac);
        final honeyG = _lerpC(175, 110, honeyDepthFrac);
        final honeyB = _lerpC(50, 15, honeyDepthFrac);
        // Subtle viscous shimmer
        final honeyShimPhase = (frameCount * 8 + x * 51 + y * 26) >> 8;
        final honeyShim = (_fastSinI(honeyShimPhase) * 10) >> 8;
        _inlineR = (honeyR + honeyShim).clamp(150, 235);
        _inlineG = (honeyG + honeyShim ~/ 2).clamp(90, 190);
        _inlineB = (honeyB + honeyShim ~/ 4).clamp(8, 60);

      case El.sulfur:
        // Bright yellow with granular texture
        _inlineA = 255;
        final sulSpatial = _spatialBlend(x, y, 4);
        final sulVar = (sulSpatial * 20) ~/ 256 - 10;
        // Granular: slight per-pixel randomness
        final sulHash = _smoothHash(x * 29, y * 37);
        final sulGrain = (sulHash % 12) - 6;
        _inlineR = (210 + sulVar + sulGrain).clamp(185, 235);
        _inlineG = (198 + sulVar + sulGrain).clamp(172, 225);
        _inlineB = (25 + sulVar ~/ 3 + sulGrain ~/ 4).clamp(10, 45);

      case El.copper:
        // Warm orange-brown with metallic sheen
        _inlineA = 255;
        final copSpatial = _spatialBlend(x, y, 5);
        final copVar = (copSpatial * 18) ~/ 256 - 9;
        // Metallic sheen: slow moving highlight
        final copSheenP = (frameCount * 20 + x * 77 + y * 51) >> 8;
        final copSheen = (_fastSinI(copSheenP) * 14) >> 8;
        // Patina spots: occasional green-blue tarnish
        final copHash = _smoothHash(x * 17, y * 31);
        final isPatina = copHash % 12 == 0;
        if (isPatina) {
          _inlineR = (100 + copVar).clamp(75, 125);
          _inlineG = (120 + copVar).clamp(95, 145);
          _inlineB = (90 + copVar ~/ 2).clamp(70, 110);
        } else {
          _inlineR = (184 + copVar + copSheen).clamp(150, 215);
          _inlineG = (115 + copVar ~/ 2 + copSheen ~/ 2).clamp(85, 145);
          _inlineB = (51 + copVar ~/ 3 + copSheen ~/ 3).clamp(30, 75);
        }

      case El.web:
        // Very thin translucent silver-white threads, mostly transparent
        final webHash = _smoothHash(x * 7, y * 11);
        // Structural threads are slightly brighter
        final isJunction = webHash % 5 == 0;
        final junctionBoost = isJunction ? 25 : 0;
        // Subtle shimmer for dew/light catch
        final webShimP = (frameCount * 10 + idx * 51) >> 8;
        final webShim = (_fastSinI(webShimP) * 8) >> 8;
        _inlineR = (200 + webShim + junctionBoost).clamp(185, 255);
        _inlineG = (200 + webShim + junctionBoost).clamp(185, 255);
        _inlineB = (215 + webShim ~/ 2 + junctionBoost).clamp(200, 255);
        _inlineA = isJunction ? (70 + webShim * 2) : (35 + webShim);

      // -- Periodic Table: Hero Element Visuals --

      case El.gold:
        // Lustrous warm gold with dancing highlights
        _inlineA = 255;
        final auHash = _smoothHash(x * 5, y * 7);
        final auGrain = (auHash % 7) - 3;
        // Slow rolling shimmer (like candlelight on gold)
        final auPhase = (frameCount * 6 + x * 37 + y * 19) & 0xFF;
        final auShim = (_fastSinI(auPhase) * 25) >> 8;
        // Rare specular flash (brilliant highlight)
        final auSpec = ((auHash >> 4) % 30 == 0 && (frameCount + x) % 40 < 3) ? 40 : 0;
        _inlineR = (255).clamp(230, 255);
        _inlineG = (195 + auGrain + auShim + auSpec).clamp(160, 240);
        _inlineB = (20 + auGrain ~/ 2 + auSpec ~/ 2).clamp(0, 80);

      case El.silver:
        // Cool silver with subtle reflective flicker
        _inlineA = 255;
        final agHash = _smoothHash(x * 3, y * 11);
        final agVar = (agHash % 9) - 4;
        final agPhase = (frameCount * 4 + idx * 29) & 0xFF;
        final agShim = (_fastSinI(agPhase) * 12) >> 8;
        final agSpec = ((agHash >> 3) % 25 == 0 && (frameCount + y) % 35 < 2) ? 30 : 0;
        _inlineR = (192 + agVar + agShim + agSpec).clamp(175, 235);
        _inlineG = (192 + agVar + agShim + agSpec).clamp(175, 235);
        _inlineB = (200 + agVar + agShim + agSpec).clamp(185, 245);

      case El.platinum:
        // Elegant silver-white with subtle warm undertone
        _inlineA = 255;
        final ptHash = _smoothHash(x * 9, y * 5);
        final ptVar = (ptHash % 7) - 3;
        final ptShim = (_fastSinI((frameCount * 3 + idx * 17) & 0xFF) * 8) >> 8;
        _inlineR = (229 + ptVar + ptShim).clamp(215, 245);
        _inlineG = (228 + ptVar + ptShim).clamp(215, 242);
        _inlineB = (226 + ptVar + ptShim).clamp(213, 240);

      case El.mercury:
        // Liquid metal: high-contrast silver with rolling convection
        _inlineA = 255;
        // Convection cells (like lava but faster, cooler colors)
        final hgConv = _fastSinI((frameCount * 12 + x * 26 + y * 18) >> 3 & 0xFF);
        final hgConvD = (hgConv * 15) >> 8;
        // Sharp specular highlights on surface
        final hgHash = _smoothHash(x * 13, y * 7);
        final hgSpec = (hgHash % 6 == 0) ? 35 : 0;
        // Flowing droplet texture
        final hgFlow = _fastSinI((frameCount * 8 + idx * 41) & 0xFF);
        final hgFlowD = (hgFlow * 10) >> 8;
        _inlineR = (208 + hgConvD + hgFlowD + hgSpec).clamp(190, 255);
        _inlineG = (216 + hgConvD + hgFlowD + hgSpec).clamp(195, 255);
        _inlineB = (224 + hgConvD + hgFlowD + hgSpec).clamp(200, 255);

      case El.carbon: // Diamond
        // Brilliant transparent with rare prismatic flash
        _inlineA = 200;
        final diaHash = _smoothHash(x * 17, y * 13);
        final diaVar = (diaHash % 5) - 2;
        // Rare brilliant flash (simulates light refraction)
        final diaFlash = (diaHash % 60 == 0 && (frameCount + idx) % 50 < 2);
        if (diaFlash) {
          // Prismatic flash — cycle through spectral colors
          final diaHue = (frameCount * 40 + idx * 13) % 768;
          if (diaHue < 256) {
            _inlineR = 255; _inlineG = (diaHue).clamp(0, 255); _inlineB = 0;
          } else if (diaHue < 512) {
            _inlineR = (511 - diaHue).clamp(0, 255); _inlineG = 255; _inlineB = (diaHue - 256).clamp(0, 255);
          } else {
            _inlineR = (diaHue - 512).clamp(0, 255); _inlineG = (767 - diaHue).clamp(0, 255); _inlineB = 255;
          }
          _inlineA = 255;
        } else {
          // Base: ice-blue transparent crystal
          final diaShim = (_fastSinI((frameCount * 5 + idx * 7) & 0xFF) * 15) >> 8;
          _inlineR = (185 + diaVar + diaShim).clamp(170, 220);
          _inlineG = (235 + diaVar + diaShim).clamp(220, 255);
          _inlineB = (255).clamp(240, 255);
        }

      case El.uranium:
        // Eerie green glow with pulsing radioactive energy
        _inlineA = 255;
        final uPhase = (frameCount * 12 + idx * 5) & 0xFF;
        final uPulse = (_fastSinI(uPhase) - 128).clamp(0, 128);
        final uHash = _smoothHash(x * 7, y * 11);
        final uVar = (uHash % 7) - 3;
        _inlineR = (50 + uVar + (uPulse >> 3)).clamp(30, 80);
        _inlineG = (128 + uVar + (uPulse >> 1)).clamp(100, 200);
        _inlineB = (50 + uVar + (uPulse >> 3)).clamp(30, 80);

      case El.thorium:
        // Dark silvery with subtle green radioactive shimmer
        _inlineA = 255;
        final thPhase = (frameCount * 8 + idx * 11) & 0xFF;
        final thPulse = (_fastSinI(thPhase) * 8) >> 8;
        _inlineR = (144 + thPulse ~/ 2).clamp(130, 165);
        _inlineG = (152 + thPulse).clamp(140, 175);
        _inlineB = (152 + thPulse ~/ 2).clamp(140, 165);

      case El.plutonium:
        // Dark metal with intense green radioactive glow
        _inlineA = 255;
        final puPhase = (frameCount * 16 + idx * 7) & 0xFF;
        final puPulse = (_fastSinI(puPhase) - 128).clamp(0, 128);
        _inlineR = (60 + (puPulse >> 3)).clamp(45, 85);
        _inlineG = (105 + (puPulse >> 1)).clamp(80, 170);
        _inlineB = (70 + (puPulse >> 3)).clamp(50, 95);

      case El.tungsten:
        // Dense dark steel gray with subtle blue tint
        _inlineA = 255;
        final wHash = _smoothHash(x * 3, y * 5);
        final wVar = (wHash % 5) - 2;
        _inlineR = (128 + wVar).clamp(120, 140);
        _inlineG = (128 + wVar).clamp(120, 140);
        _inlineB = (132 + wVar).clamp(124, 144);

      case El.aluminum:
        // Light, bright metallic with brushed texture
        _inlineA = 255;
        final alHash = _smoothHash(x * 11, y * 3);
        final alGrain = (alHash % 3 == 0) ? 6 : 0; // brushed lines
        final alVar = (alHash % 7) - 3;
        _inlineR = (190 + alVar + alGrain).clamp(180, 210);
        _inlineG = (194 + alVar + alGrain).clamp(182, 215);
        _inlineB = (203 + alVar + alGrain).clamp(190, 225);

      case El.vapor:
        // Soft semi-transparent wisp
        final vPhase = (frameCount + idx * 7) % 60;
        final vPulse = vPhase < 30 ? vPhase : 59 - vPhase;
        _inlineR = (210 + vPulse).clamp(200, 255);
        _inlineG = (220 + vPulse).clamp(210, 255);
        _inlineB = (245 + vPulse).clamp(230, 255);
        _inlineA = (20 + vPulse).clamp(15, 60);

      case El.cloud:
        // Soft fluffy clouds with transparent edges.
        // life[idx] = cloud neighbor count (0-8) from simCloud.
        // More neighbors = denser core = more opaque.
        // Fewer neighbors = wispy edge = more transparent.
        final cMoist = engine.moisture[idx];
        final cNeighbors = life[idx].clamp(0, 8);
        final cHash = _smoothHash(x * 13 + frameCount ~/ 20, y * 17);
        final cVar = (cHash % 14) - 7;
        // Color: white → dark gray as moisture increases (storm)
        final cBase = 245 - (cMoist * 160 >> 8);
        _inlineR = (cBase + cVar).clamp(50, 255);
        _inlineG = (cBase + cVar).clamp(50, 255);
        _inlineB = (cBase + 15 + cVar).clamp(60, 255);
        // Alpha: wispy edges, dense core
        _inlineA = (30 + cNeighbors * 22).clamp(30, 210);

      case El.silicon:
        // Dark gray semi-metallic with semiconductor sparkle
        _inlineA = 255;
        final siHash = _smoothHash(x * 11, y * 31);
        final siVar = (siHash % 10) - 5;
        final siT = temp[idx];
        final siOx = engine.oxidation[idx];
        // Conduction shimmer: "Electric Cyan"
        final isConductive = siT > 150 || siOx > 200;
        int sparkle = 0;
        if (isConductive) {
           final p = (frameCount * 15 + idx * 7) % 60;
           if (p < 5) sparkle = 40;
        }
        _inlineR = (80 + siVar).clamp(60, 110);
        _inlineG = (85 + siVar + sparkle).clamp(60, 150);
        _inlineB = (100 + siVar + sparkle).clamp(80, 200);

      // Noble gases: show gas discharge glow when electrically excited
      case El.neon:
        final nLife = life[idx];
        if (nLife > 0) {
          // Excited neon: characteristic orange-red glow
          final intensity = (nLife * 12).clamp(0, 255);
          _inlineR = intensity;
          _inlineG = (intensity * 35) >> 8;
          _inlineB = (intensity * 15) >> 8;
          _inlineA = (60 + intensity * 3 ~/ 4).clamp(60, 220);
        } else {
          _inlineR = 255; _inlineG = 96; _inlineB = 64; _inlineA = 24;
        }
      case El.argon:
        final aLife = life[idx];
        if (aLife > 0) {
          final intensity = (aLife * 12).clamp(0, 255);
          _inlineR = (intensity * 160) >> 8;
          _inlineG = (intensity * 100) >> 8;
          _inlineB = intensity;
          _inlineA = (50 + intensity * 3 ~/ 4).clamp(50, 200);
        } else {
          _inlineR = 192; _inlineG = 160; _inlineB = 224; _inlineA = 21;
        }
      case El.krypton:
        final kLife = life[idx];
        if (kLife > 0) {
          final intensity = (kLife * 12).clamp(0, 255);
          _inlineR = intensity;
          _inlineG = (intensity * 240) >> 8;
          _inlineB = intensity;
          _inlineA = (50 + intensity * 3 ~/ 4).clamp(50, 220);
        } else {
          _inlineR = 224; _inlineG = 224; _inlineB = 224; _inlineA = 18;
        }
      case El.xenon:
        final xLife = life[idx];
        if (xLife > 0) {
          final intensity = (xLife * 12).clamp(0, 255);
          _inlineR = (intensity * 140) >> 8;
          _inlineG = (intensity * 160) >> 8;
          _inlineB = intensity;
          _inlineA = (60 + intensity * 3 ~/ 4).clamp(60, 230);
        } else {
          _inlineR = 128; _inlineG = 128; _inlineB = 255; _inlineA = 21;
        }

      default:
        final c = baseColors[el.clamp(0, baseColors.length - 1)];
        _inlineR = (c >> 16) & 0xFF;
        _inlineG = (c >> 8) & 0xFF;
        _inlineB = c & 0xFF;
        _inlineA = (c >> 24) & 0xFF;
    }
  }
}
