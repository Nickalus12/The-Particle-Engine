import 'dart:math' as math;
import 'dart:typed_data';

import 'image_builder_stub.dart'
    if (dart.library.ui) 'image_builder_ui.dart' as image_builder;

import 'element_registry.dart';
import 'simulation_engine.dart';

/// Fast sine approximation using integer-only math.
/// Returns value in [-1.0, 1.0] range. Accurate within ~2% for visual effects.
@pragma('vm:prefer-inline')
double _fastSin(double x) {
  // Normalize to [0, 4) representing quadrants (period = 4 = 2*pi equivalent)
  // Input x is in radians, period ~6.283
  // Map to [0, 256) integer range for lookup
  int ix = ((x * 40.743) % 256).toInt(); // 256 / 6.283 ≈ 40.743
  if (ix < 0) ix += 256;

  // Piecewise linear approximation using quadrants
  if (ix < 64) {
    return ix / 64.0; // 0 to 1
  } else if (ix < 128) {
    return (128 - ix) / 64.0; // 1 to 0
  } else if (ix < 192) {
    return -(ix - 128) / 64.0; // 0 to -1
  } else {
    return -(256 - ix) / 64.0; // -1 to 0
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
  bool _starsGenerated = false;

  /// Cached ground surface height per column. _groundLevel[x] = first y from
  /// top that has a solid element (stone/dirt/metal/sand/etc). Updated every
  /// few frames to avoid per-cell upward scans.
  late Int16List _groundLevel;
  int _groundLevelAge = 0;

  double _prevDayNightT = 0.0;

  PixelRenderer(this.engine);

  Uint8List get pixels => _pixels;
  List<Int32List> get microParticles => _microParticles;

  void init() {
    final total = engine.gridW * engine.gridH;
    _pixels = Uint8List(total * 4);
    _groundLevel = Int16List(engine.gridW);
    _glowR = Uint8List(total);
    _glowG = Uint8List(total);
    _glowB = Uint8List(total);
  }

  void generateStars() {
    if (_starsGenerated) return;
    _starsGenerated = true;
    final topRows = (engine.gridH * 0.10).floor().clamp(3, 30);
    _starPositions = [];
    for (int i = 0; i < 30; i++) {
      final sx = engine.rng.nextInt(engine.gridW);
      final sy = engine.rng.nextInt(topRows);
      _starPositions.add(sy * engine.gridW + sx);
    }
    _starSet = Set<int>.from(_starPositions);
  }

  void clearParticles() {
    _microParticles.clear();
  }

  void spawnParticle(int x, int y, int r, int g, int b, int frames) {
    if (_microParticles.length >= _maxMicroParticles) return;
    _microParticles.add(Int32List.fromList([x, y, r, g, b, frames]));
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
        final angle = rng.nextDouble() * 6.2832;
        final dist = exp.radius * 0.3 + rng.nextDouble() * exp.radius * 0.8;
        final px = exp.x + (dist * math.cos(angle)).round();
        final py = exp.y + (dist * math.sin(angle)).round();
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
  /// to find the first solid terrain cell per column.
  void _updateGroundLevel() {
    final w = engine.gridW;
    final h = engine.gridH;
    final g = engine.grid;
    for (int x = 0; x < w; x++) {
      int level = h; // default: no ground found
      for (int y = 0; y < h; y++) {
        final el = g[y * w + x];
        if (el == El.stone || el == El.dirt || el == El.metal ||
            el == El.sand || el == El.mud || el == El.wood ||
            el == El.glass || el == El.ice) {
          level = y;
          break;
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

  double dayNightT = 0.0;

  /// Accumulated time for animated effects (heat shimmer, snow sparkle).
  double _effectTime = 0.0;

  void renderPixels() {
    final total = engine.gridW * engine.gridH;
    final w = engine.gridW;
    final h = engine.gridH;
    final g = engine.grid;
    final t = engine.isNight ? dayNightT : 0.0;
    final fc = engine.frameCount;

    // Advance effect timer (~60fps assumed)
    _effectTime += 0.016;

    // Update ground level cache every 8 frames for underground detection
    _groundLevelAge++;
    if (_groundLevelAge >= 8) {
      _updateGroundLevel();
      _groundLevelAge = 0;
    }
    final temp = engine.temperature;

    final glowMul = 1.0 + t * 2.0;

    final starSet = t > 0.05 ? _starSet : const <int>{};

    final doGlow = fc % 6 == 0;

    final nightBoost = (t * 30).round();
    final nightBoostG = (nightBoost * 0.2).round();
    final nightShimmer = (t * 50).round();
    final nightSmokeBoost = (t * 20).round();
    final nightDimWater = (256 * (1.0 - t * 0.15)).round();
    final nightDimGeneral = (256 * (1.0 - t * 0.2)).round();

    final dayNightTransitioning = (t - _prevDayNightT).abs() > 0.001;
    _prevDayNightT = t;

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

        // Special case: heated stone emits light dynamically
        final isHeatedStone = el == El.stone && engine.velX[i] > 2;
        if (isHeatedStone) {
          final stoneHeatLevel = engine.velX[i].clamp(0, 5);
          emission = (stoneHeatLevel * 40).clamp(0, 200);
          emR = 255;
          emG = 80;
          emB = 0;
          glowRadius = 3;
        }

        if (emission == 0) continue;
        hasEmissive = true;

        final ex = i % w;
        final ey = i ~/ w;

        // Scale glow intensities by emission level and night multiplier
        final scaledR = (emR * emission * glowMul / 255.0).round();
        final scaledG = (emG * emission * glowMul / 255.0).round();
        final scaledB = (emB * emission * glowMul / 255.0).round();

        // Lava gets larger glow for atmospheric molten look
        if (el == El.lava) {
          glowRadius = 3;
        } else if (el == El.fire) {
          glowRadius = 3;
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
            final isTarget = neighborEl == El.empty;
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

            if (el == El.empty) {
              // Check if this empty cell is underground (cave atmosphere)
              final underground = _isUnderground(x, y, w, g);

              int emptyR, emptyG, emptyB;
              if (underground) {
                // Dark stone-tinted cave background
                final depthTint = _spatialBlend(x, y, 8);
                final stoneVar = (depthTint * 8) ~/ 256;
                emptyR = (18 + stoneVar).clamp(12, 30);
                emptyG = (16 + stoneVar).clamp(10, 28);
                emptyB = (20 + stoneVar).clamp(14, 32);
                // Floating dust motes in cave air — sparse twinkling specks
                final dustHash = _smoothHash(x * 53 + fc ~/ 8, y * 37 + fc ~/ 12);
                if (dustHash % 180 == 0) {
                  final dustBright = 25 + (dustHash >> 8) % 20;
                  emptyR = (emptyR + dustBright).clamp(0, 60);
                  emptyG = (emptyG + dustBright - 3).clamp(0, 55);
                  emptyB = (emptyB + dustBright - 5).clamp(0, 50);
                }
              } else {
                // Day sky: beautiful blue gradient from light top to deeper blue
                final skyFrac = y / h; // 0 at top, 1 at bottom
                // Top of sky: light azure, bottom: deeper blue
                emptyR = (135 - (skyFrac * 100).round()).clamp(25, 140);
                emptyG = (195 - (skyFrac * 100).round()).clamp(80, 200);
                emptyB = (255 - (skyFrac * 40).round()).clamp(200, 255);

                // Night dimming
                if (t > 0.0) {
                  emptyR = (emptyR * (1.0 - t * 0.9)).round().clamp(0, 255);
                  emptyG = (emptyG * (1.0 - t * 0.9)).round().clamp(0, 255);
                  emptyB = (emptyB * (1.0 - t * 0.85)).round().clamp(0, 255);
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
                  final shimmerPhase = _fastSin(
                      _effectTime * 3.5 + x * 0.8 + y * 0.4) * 0.5 + 0.5;
                  final shimmerPhase2 = _fastSin(
                      _effectTime * 2.3 + x * 1.2 + y * 0.6 + 1.9) * 0.5 + 0.5;
                  final heatIntensity = ((cellTemp - 170) / 80.0).clamp(0.0, 1.0);
                  final shimmerAmount = (heatIntensity * (shimmerPhase * 18 + shimmerPhase2 * 10)).round();
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
                final twinkle = ((fc + i * 17) % 40);
                if (twinkle < 6) {
                  final brightness = twinkle < 3 ? 200 : 140;
                  final starBright = (brightness * t).round();
                  emptyR = (emptyR + starBright).clamp(0, 255);
                  emptyG = (emptyG + starBright).clamp(0, 255);
                  emptyB = (emptyB + starBright).clamp(0, 255);
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
                } else if (rng.nextInt(150) < 2 && y > 1) {
                  spawnParticle(
                      x + rng.nextInt(3) - 1,
                      y - 1,
                      255,
                      140 + rng.nextInt(60),
                      20 + rng.nextInt(30),
                      5 + rng.nextInt(3));
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
              } else if (el == El.sand) {
                if (rng.nextInt(400) < 1 &&
                    y > 1 &&
                    y < h - 1 &&
                    g[(y + 1) * w + x] == El.empty) {
                  spawnParticle(x, y - 1, 194, 178, 128, 3);
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
                el, i, x, y, w, h, g, life, velX, velY, fc, rng, temp);
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
            if (y > 10) {
              final undergroundCheck = _isUnderground(x, y, w, g);
              if (undergroundCheck) {
                // Subtle darkening based on depth
                final depthFactor = (y * 256 ~/ h).clamp(0, 255);
                final darken = (depthFactor * 15) ~/ 256; // max ~15 units darker
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
      Uint8List temp) {
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
        final pulse = (frameCount + idx * 3) % 6;
        _inlineR = 255;
        _inlineG = 255;
        _inlineB = pulse < 3 ? 180 : 255;
        _inlineA = 255;

      case El.rainbow:
        final hue =
            ((engine.rainbowHue + life[idx] * 7) % 360).toDouble();
        final h6 = hue / 60.0;
        final hi = h6.floor() % 6;
        final f = h6 - h6.floor();
        const v = 255;
        const p = 51;
        final q = (v * (1.0 - 0.8 * f)).round();
        final t2 = (v * (1.0 - 0.8 * (1.0 - f))).round();
        _inlineA = 255;
        switch (hi) {
          case 0:
            _inlineR = v;
            _inlineG = t2;
            _inlineB = p;
          case 1:
            _inlineR = q;
            _inlineG = v;
            _inlineB = p;
          case 2:
            _inlineR = p;
            _inlineG = v;
            _inlineB = t2;
          case 3:
            _inlineR = p;
            _inlineG = q;
            _inlineB = v;
          case 4:
            _inlineR = t2;
            _inlineG = p;
            _inlineB = v;
          default:
            _inlineR = v;
            _inlineG = p;
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
            // Surface shimmer with gentle wave animation
            final wave = _fastSin((frameCount * 0.12 + x * 0.6)) * 0.5 + 0.5;
            final wave2 = _fastSin((frameCount * 0.07 + x * 1.1 + 1.8)) * 0.5 + 0.5;
            final shimmer = ((wave * 25 + wave2 * 15)).round();

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
              _inlineR = (110 + shimmer * 2 + foamFlicker).clamp(80, 200);
              _inlineG = (225 + shimmer + foamFlicker ~/ 2).clamp(200, 255);
              _inlineB = 255;
              _inlineA = 235;
            } else if (isUndergroundWater) {
              // Underground surface water: darker, more muted
              _inlineR = (30 + shimmer ~/ 2).clamp(20, 60);
              _inlineG = (120 + shimmer ~/ 2).clamp(100, 160);
              _inlineB = (200 + shimmer ~/ 3).clamp(180, 230);
              _inlineA = 235;
            } else {
              // Surface water reflects sky color — blend water blue with sky tint
              // Sky color shifts from azure (day) to dark blue (night)
              final skyReflectR = (135 * (1.0 - dayNightT * 0.85)).round();
              final skyReflectG = (195 * (1.0 - dayNightT * 0.7)).round();
              final skyReflectB = (255 * (1.0 - dayNightT * 0.3)).round();
              // Blend ~25% sky reflection into surface water
              _inlineR = (55 + shimmer + (skyReflectR * 60) ~/ 256).clamp(35, 140);
              _inlineG = (185 + shimmer + (skyReflectG * 30) ~/ 256).clamp(165, 245);
              _inlineB = (240 + (skyReflectB * 15) ~/ 256).clamp(230, 255);
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

            int baseR, baseG, baseB, baseA;
            if (isUndergroundWater) {
              // Underground water: much darker and murkier
              baseR = _lerpC(25, 3, depthFrac);
              baseG = _lerpC(90, 25, depthFrac);
              baseB = _lerpC(160, 80, depthFrac);
              baseA = _lerpC(230, 250, depthFrac);
            } else {
              // Surface water: clear blue gradient
              baseR = _lerpC(45, 5, depthFrac);
              baseG = _lerpC(155, 35, depthFrac);
              baseB = _lerpC(255, 160, depthFrac);
              baseA = _lerpC(220, 250, depthFrac);
            }

            // Caustics for shallow water
            int caustic = 0;
            if (depth < 10) {
              final cx1 = _fastSin((frameCount * 0.10 + x * 0.6 + y * 0.35)) * 0.5 + 0.5;
              final cx2 = _fastSin((frameCount * 0.07 + x * 0.9 + y * 0.5 + 1.7)) * 0.5 + 0.5;
              final causticStrength = (1.0 - depth / 10.0);
              caustic = ((cx1 * 10 + cx2 * 6) * causticStrength).round();
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
        // Smooth spatial gradient for warm golden tones
        final spatial = _spatialBlend(x, y, 6);
        final variation = (spatial * 22) ~/ 256 - 11;
        // Gentle tonal banding
        final band = _spatialBlend(x + 200, y * 2, 10);
        final bandShift = (band * 10) ~/ 256 - 5;
        _inlineR = (215 + variation + bandShift).clamp(190, 240);
        _inlineG = (195 + variation + bandShift).clamp(172, 222);
        _inlineB = (130 + (variation * 2 ~/ 3) + bandShift ~/ 2).clamp(105, 158);

      case El.tnt:
        _inlineA = 255;
        if ((x + y) % 4 == 0) {
          _inlineR = 68;
          _inlineG = 0;
          _inlineB = 0;
        } else {
          final tntVar = ((idx * 7 + y * 3) % 11) - 5;
          _inlineR = (204 + tntVar).clamp(180, 230);
          _inlineG = (34 + tntVar).clamp(10, 60);
          _inlineB = (34 + tntVar).clamp(10, 60);
        }

      case El.ant:
        _inlineA = 255;
        final antState = velY[idx];
        if (antState == antCarrierState) {
          final aboveIdx = idx - w;
          if (y > 0 && grid[aboveIdx] != El.ant) {
            _inlineR = 139;
            _inlineG = 105;
            _inlineB = 20;
          } else {
            _inlineR = 61;
            _inlineG = 43;
            _inlineB = 31;
          }
        } else if (antState == antDiggerState) {
          _inlineR = 42;
          _inlineG = 17;
          _inlineB = 17;
        } else if (antState == antForagerState) {
          _inlineR = 26;
          _inlineG = 42;
          _inlineB = 17;
        } else if (antState == antReturningState) {
          _inlineR = 17;
          _inlineG = 17;
          _inlineB = 34;
        } else {
          if (idx % 3 == 0) {
            _inlineR = 51;
            _inlineG = 51;
            _inlineB = 51;
          } else {
            _inlineR = 17;
            _inlineG = 17;
            _inlineB = 17;
          }
        }

      case El.seed:
        final variation = ((idx * 7 + y * 3) % 11) - 5;
        final v = ((idx % 5) * 4 + variation).clamp(0, 25);
        _inlineR = (139 - v).clamp(100, 150);
        _inlineG = (115 - v).clamp(80, 130);
        _inlineB = (85 - v).clamp(50, 100);
        _inlineA = 255;

      case El.dirt:
        final moisture = life[idx].clamp(0, 5);
        final mFrac = moisture / 5.0;
        final compaction = velY[idx].clamp(0, 5);
        final compactDarken = (compaction * 6).round();
        // Smooth spatial blending for earthy tones
        final spatial = _spatialBlend(x, y, 5);
        final variation = (spatial * 20) ~/ 256 - 10;
        final warmth = _spatialBlend(x + 100, y + 100, 8);
        final warmShift = (warmth * 8) ~/ 256 - 4;
        // Organic texture: dark patches (decaying matter, roots)
        final organicHash = _smoothHash(x * 19, y * 23);
        final isDarkPatch = organicHash % 12 == 0; // ~8% of pixels
        final isRootFiber = organicHash % 17 == 0 && (organicHash >> 8) % 3 == 0; // rare darker streaks
        final organicDarken = isDarkPatch ? 18 : (isRootFiber ? 12 : 0);
        // Small lighter mineral specks
        final mineralSpeck = (organicHash % 25 == 0) ? 10 : 0;
        final baseR = 140 + variation + warmShift - compactDarken - organicDarken + mineralSpeck;
        final baseG = 95 + variation ~/ 2 - compactDarken - organicDarken ~/ 2;
        final baseB = 40 + variation ~/ 3 - compactDarken ~/ 2 - organicDarken ~/ 3;
        // Darker when moist (driven by life value)
        _inlineR =
            (baseR - mFrac * 60).round().clamp(35, 168);
        _inlineG =
            (baseG - mFrac * 50).round().clamp(18, 120);
        _inlineB =
            (baseB - mFrac * 12).round().clamp(4, 55);
        _inlineA = 255;

      case El.plant:
        final pType = engine.plantType(idx);
        final pStage = engine.plantStage(idx);
        final variation = ((idx * 7 + y * 3) % 11) - 5;
        if (pStage == kStDead) {
          _inlineR = (80 + variation).clamp(60, 100);
          _inlineG = (50 + variation).clamp(30, 70);
          _inlineB = 20;
          _inlineA = 255;
        } else if (pStage == kStWilting) {
          // Yellow-green wilting
          _inlineR = (140 + variation).clamp(120, 170);
          _inlineG = (145 + variation).clamp(120, 175);
          _inlineB = (30 + variation).clamp(15, 50);
          _inlineA = 255;
        } else {
          _inlineA = 255;
          switch (pType) {
            case kPlantGrass:
              // Growth stage affects brightness
              if (pStage == kStSprout) {
                // Bright lime green sprout
                _inlineR = (80 + variation).clamp(60, 110);
                _inlineG = (210 + variation).clamp(190, 240);
                _inlineB = (50 + variation).clamp(30, 75);
              } else if (pStage == kStMature) {
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
            case kPlantFlower:
              if (pStage == kStMature) {
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
              } else if (pStage == kStSprout) {
                _inlineR = (60 + variation).clamp(40, 85);
                _inlineG = (200 + variation).clamp(180, 230);
                _inlineB = (45 + variation).clamp(25, 70);
              } else {
                _inlineR = (30 + variation).clamp(15, 50);
                _inlineG = (170 + variation).clamp(145, 200);
                _inlineB = (30 + variation).clamp(15, 50);
              }
            case kPlantTree:
              if (pStage == kStGrowing) {
                // Warm brown trunk with vertical grain
                final grainY = _spatialBlend(x, y * 4, 3);
                final grainShift = (grainY * 14) ~/ 256 - 7;
                _inlineR = (105 + variation + grainShift).clamp(80, 130);
                _inlineG = (65 + variation ~/ 2 + grainShift ~/ 2).clamp(40, 90);
                _inlineB = (30 + variation ~/ 3).clamp(12, 48);
              } else if (pStage == kStSprout) {
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
            case kPlantMushroom:
              if (pStage == kStMature) {
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
            case kPlantVine:
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
              if (pStage == kStSprout) {
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
        final glint = (frameCount + idx * 17) % 60 < 2 ? 25 : 0;
        final facet = _smoothHash(x, y) % 4;
        switch (facet) {
          case 0:
            _inlineR = (190 + glint).clamp(185, 230);
            _inlineG = (230 + glint).clamp(225, 255);
            _inlineB = 255;
          case 1:
            _inlineR = (175 + glint).clamp(170, 215);
            _inlineG = (220 + glint).clamp(215, 250);
            _inlineB = 252;
          case 2:
            _inlineR = (165 + glint).clamp(160, 205);
            _inlineG = (215 + glint).clamp(210, 248);
            _inlineB = 255;
          default:
            _inlineR = (200 + glint).clamp(195, 240);
            _inlineG = (235 + glint).clamp(230, 255);
            _inlineB = 255;
        }

      case El.stone:
        _inlineA = 255;
        final stoneHeat = velX[idx].clamp(0, 5);
        final stoneDepth = life[idx].clamp(0, 20);
        final depthDarken = (stoneDepth * 2.0).round(); // deeper = darker
        // Smooth layered look with spatial gradients
        final spatial = _spatialBlend(x, y, 6);
        final layer = (spatial * 16) ~/ 256 - 8;
        // Visible geological strata — horizontal bands every 4-6 rows
        // Uses y-coordinate directly for clear sedimentary layering
        final strataHash = _smoothHash(0, y ~/ 4);
        final strataType = strataHash % 5; // different rock "types" per band
        int strataR, strataG, strataB;
        if (strataType == 0) {
          // Blue-gray (standard)
          strataR = 128; strataG = 126; strataB = 138;
        } else if (strataType == 1) {
          // Warm brown-gray (sandstone-like)
          strataR = 140; strataG = 125; strataB = 115;
        } else if (strataType == 2) {
          // Cool dark gray (basalt-like)
          strataR = 110; strataG = 110; strataB = 120;
        } else if (strataType == 3) {
          // Light cream-gray (limestone-like)
          strataR = 148; strataG = 142; strataB = 135;
        } else {
          // Slight greenish-gray (slate-like)
          strataR = 120; strataG = 128; strataB = 125;
        }
        // Transition zone between strata — slight darkening at boundaries
        final strataEdge = (y % 4 == 0) ? -6 : 0;
        // Subtle horizontal sediment banding within each layer
        final sediment = _spatialBlend(x + 50, y * 2, 10);
        final sedimentShift = (sediment * 10) ~/ 256 - 5;
        // Horizontal band emphasis for sedimentary look
        final hBand = _spatialBlend(x * 3, y, 12);
        final hBandShift = (hBand * 6) ~/ 256 - 3;
        _inlineR = (strataR + layer + hBandShift + strataEdge - depthDarken).clamp(55, 175);
        _inlineG = (strataG + layer + sedimentShift + hBandShift + strataEdge - depthDarken).clamp(53, 173);
        _inlineB = (strataB + layer - sedimentShift + hBandShift + strataEdge - depthDarken ~/ 2).clamp(68, 185);
        if (stoneHeat > 0) {
          final heatFrac = stoneHeat / 5.0;
          final pulse = math.sin(frameCount * 0.3 + idx * 0.1) * 0.3 + 0.7;
          _inlineR =
              (_inlineR + (heatFrac * 130 * pulse).round())
                  .clamp(0, 255);
          _inlineG =
              (_inlineG + (heatFrac * 45 * pulse).round())
                  .clamp(0, 255);
          _inlineB =
              (_inlineB - (heatFrac * 70).round()).clamp(0, 255);
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
        final warmShift = (mudWarmth * 12) ~/ 256 - 6;
        // Subtle wetness sheen on surface
        final isMudTop = y > 0 && grid[(y - 1) * w + x] != El.mud;
        final wetBoost = isMudTop ? 10 : 0;
        _inlineR = (80 + mudVar + warmShift + wetBoost).clamp(55, 110);
        _inlineG = (65 + mudVar ~/ 2 + warmShift ~/ 2 + wetBoost ~/ 2).clamp(40, 90);
        _inlineB = (45 + mudVar ~/ 3 + wetBoost ~/ 3).clamp(25, 65);

      case El.oil:
        _inlineA = 255;
        final isOilTop = y > 0 && grid[(y - 1) * w + x] != El.oil;
        if (isOilTop) {
          // Iridescent surface shimmer -- rainbow oil slick effect
          final shimmer1 = math.sin(frameCount * 0.15 + x * 0.7) * 0.5 + 0.5;
          final shimmer2 = math.sin(frameCount * 0.12 + x * 1.1 + 1.2) * 0.5 + 0.5;
          final iridPhase = ((x * 37 + frameCount * 2) % 120) / 120.0;
          // Rainbow phase for iridescence
          final iridR = (math.sin(iridPhase * 6.28) * 20 + 20).round();
          final iridG = (math.sin(iridPhase * 6.28 + 2.09) * 15 + 10).round();
          final iridB = (math.sin(iridPhase * 6.28 + 4.19) * 20 + 15).round();
          final shimVal = (shimmer1 * 14 + shimmer2 * 8).round();
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
        final pulse = math.sin(frameCount * 0.15 + idx * 0.3) * 0.5 + 0.5;
        final acidGlow = (pulse * 30).round();
        final variation = ((idx * 7 + y * 3) % 11) - 5;
        _inlineR = (20 + variation + acidGlow ~/ 3).clamp(0, 80);
        _inlineG = (240 + variation + acidGlow ~/ 4).clamp(210, 255);
        _inlineB = (20 + variation + acidGlow ~/ 5).clamp(0, 60);
        _inlineA = 255;

      case El.glass:
        final sparkle =
            (frameCount + idx * 3) % 20 < 2 ? 30 : 0;
        final variation = ((idx * 7 + y * 3) % 11) - 5;
        _inlineR = (210 + variation + sparkle).clamp(180, 255);
        _inlineG = (225 + variation + sparkle).clamp(200, 255);
        _inlineB = 255;
        _inlineA = 200;

      case El.lava:
        final lavaLife = life[idx];
        // Use cheaper hash-based flicker instead of per-cell sin()
        final flickerHash = ((frameCount * 7 + idx * 13) >> 3) & 0x1F;
        final lavaFlicker = flickerHash < 16 ? flickerHash : 31 - flickerHash;
        final isLavaSurf = y > 0 && grid[(y - 1) * w + x] == El.empty;

        // Warm molten look — NOT blinding white
        if (lavaLife < 30) {
          // Fresh lava: warm orange-red, not white-hot
          final surfBoost = isLavaSurf ? 10 : 0;
          _inlineR = 255;
          _inlineG = (160 + lavaFlicker + surfBoost).clamp(140, 200);
          _inlineB = (40 + lavaFlicker ~/ 2).clamp(20, 80);
          _inlineA = 255;
        } else if (lavaLife < 80) {
          // Cooling: deep red-orange with dark crust veins
          final t2 = ((lavaLife - 30) * 255 ~/ 50).clamp(0, 255);
          final crustHash = _smoothHash(x, y);
          final isCrustVein = lavaLife > 45 && (crustHash % 6 == 0);
          if (isCrustVein) {
            // Dark cooling crust veins
            _inlineR = (130 + lavaFlicker ~/ 3).clamp(100, 170);
            _inlineG = (18 + lavaFlicker ~/ 6).clamp(8, 35);
            _inlineB = (lavaFlicker ~/ 10).clamp(0, 8);
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
        final snowSpatial = _smoothHash(x, y) % 256;
        final snowVar = (snowSpatial * 8) ~/ 256 - 4;
        // Multi-frequency sparkle/glitter — different pixels glint at different times
        final sparkleHash = _smoothHash(x * 31, y * 47);
        final sparklePhase = (sparkleHash % 60);
        final sparkleActive = ((frameCount + sparklePhase) % 60);
        // Sharp, bright sparkle that appears and disappears quickly
        final isSparkle = sparkleActive < 3 && (sparkleHash % 4 == 0);
        final sparkleIntensity = isSparkle ? 45 : 0;
        // Slower gentle shimmer for overall snow surface
        final shimmerVal = (math.sin(_effectTime * 1.5 + sparkleHash * 0.01) * 6).round();
        // Surface snow is slightly brighter than buried snow
        final isSnowSurface = y > 0 && grid[(y - 1) * w + x] != El.snow;
        final surfaceBoost = isSnowSurface ? 8 : 0;
        _inlineR = (235 + snowVar + shimmerVal + sparkleIntensity + surfaceBoost).clamp(225, 255);
        _inlineG = (238 + snowVar + shimmerVal + sparkleIntensity + surfaceBoost).clamp(228, 255);
        _inlineB = (250 + sparkleIntensity ~/ 2).clamp(245, 255);

      case El.wood:
        _inlineA = 255;
        final variation = ((idx * 7 + y * 3) % 11) - 5;
        if (life[idx] > 0) {
          final burnPhase = math.sin(frameCount * 0.25 + life[idx] * 0.3) * 0.5 + 0.5;
          final bright = (burnPhase * 35).round();
          _inlineR = (200 + bright).clamp(185, 255);
          _inlineG = (80 + bright - life[idx]).clamp(20, 120);
          _inlineB = 10;
        } else {
          // Warm brown with visible vertical grain pattern
          final vertGrain = _spatialBlend(x, y * 4, 3);
          final grainVal = (vertGrain * 18) ~/ 256 - 9;
          final isKnot = _smoothHash(x * 11, y * 7) % 19 == 0;
          final waterlog = velY[idx].clamp(0, 3) * 20;
          if (isKnot) {
            _inlineR = (115 - waterlog + grainVal).clamp(50, 140);
            _inlineG = (60 - waterlog + grainVal ~/ 2).clamp(25, 82);
            _inlineB = (32 - waterlog + grainVal ~/ 3).clamp(10, 52);
          } else {
            // Vertical grain emphasis with warm tones
            final band = _spatialBlend(x, y * 5, 3);
            final bandShift = (band * 20) ~/ 256 - 10;
            _inlineR = (160 - waterlog + variation + bandShift).clamp(65, 190);
            _inlineG = (85 - waterlog + variation ~/ 2 + bandShift ~/ 2).clamp(32, 115);
            _inlineB = (46 - waterlog + variation ~/ 3 + bandShift ~/ 3).clamp(12, 70);
          }
        }

      case El.metal:
        _inlineA = 255;
        final variation = ((idx * 7 + y * 3) % 11) - 5;
        if (life[idx] >= 200) {
          life[idx]--;
          if (life[idx] < 200) life[idx] = 0;
          _inlineR = 255;
          _inlineG = 255;
          _inlineB = 136;
        } else {
          final rustLevel = life[idx].clamp(0, 120);
          if (rustLevel > 0) {
            final rustFrac = rustLevel / 120.0;
            _inlineR = (168 - rustFrac * 29 + variation)
                .round()
                .clamp(100, 200);
            _inlineG = (168 - rustFrac * 78 + variation)
                .round()
                .clamp(60, 200);
            _inlineB = (176 - rustFrac * 133 + variation)
                .round()
                .clamp(30, 210);
          } else {
            final sheenPhase = math.sin(frameCount * 0.1 + x * 0.3 + y * 0.2) * 0.5 + 0.5;
            final sheen = (sheenPhase * 18).round();
            _inlineR = (168 + sheen + variation).clamp(145, 200);
            _inlineG = (168 + sheen + variation).clamp(145, 200);
            _inlineB = (176 + sheen + variation).clamp(155, 210);
          }
        }

      case El.smoke:
        final smokeLife = life[idx];
        final fade = (60 - smokeLife).clamp(0, 60);
        final wisp = math.sin(frameCount * 0.1 + idx * 0.5) * 0.5 + 0.5;
        final wispVal = (wisp * 15).round();
        _inlineA = (fade * 3 + 60).clamp(60, 200);
        final smokeBase =
            _lerpC(155, 110, (smokeLife * 255 ~/ 60).clamp(0, 255));
        final variation = ((idx * 7 + y * 3) % 11) - 5;
        _inlineR = (smokeBase + variation + wispVal).clamp(90, 180);
        _inlineG = (smokeBase + variation + wispVal ~/ 2).clamp(90, 175);
        _inlineB = (smokeBase + variation + wispVal ~/ 3).clamp(95, 180);

      case El.bubble:
        // Iridescent soap-bubble feel with shifting rainbow highlight
        final bubbleTime = frameCount * 0.08 + idx * 0.5;
        final iridShift = math.sin(bubbleTime) * 0.5 + 0.5;
        final iridShift2 = math.sin(bubbleTime * 0.7 + 1.5) * 0.5 + 0.5;
        // Specular highlight that moves across the bubble
        final highlight = (frameCount + idx * 7) % 40 < 4 ? 40 : 0;
        // Base: light cyan-white with rainbow shimmer
        _inlineR = (180 + (iridShift * 50).round() + highlight).clamp(165, 255);
        _inlineG = (210 + (iridShift2 * 35).round() + highlight).clamp(195, 255);
        _inlineB = (240 + highlight).clamp(230, 255);
        // Very translucent to show what's behind
        _inlineA = (120 + (iridShift * 30).round()).clamp(100, 160);

      case El.ash:
        final variation = ((idx * 7 + y * 3) % 11) - 5;
        final v = ((idx % 7) * 3 + variation).clamp(0, 20);
        _inlineR = (176 - v).clamp(150, 200);
        _inlineG = (176 - v).clamp(150, 200);
        _inlineB = (180 - v).clamp(155, 205);
        _inlineA = 220;

      default:
        final c = baseColors[el.clamp(0, baseColors.length - 1)];
        _inlineR = (c >> 16) & 0xFF;
        _inlineG = (c >> 8) & 0xFF;
        _inlineB = c & 0xFF;
        _inlineA = (c >> 24) & 0xFF;
    }
  }
}
