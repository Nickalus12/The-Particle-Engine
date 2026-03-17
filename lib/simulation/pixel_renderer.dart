import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'element_registry.dart';
import 'simulation_engine.dart';

class PixelRenderer {
  final SimulationEngine engine;

  late Uint8List _pixels;
  late Uint8List _pixels2;
  bool _useFirstBuffer = true;

  Uint8List get _activePixels => _useFirstBuffer ? _pixels : _pixels2;

  final List<Int32List> _microParticles = [];
  static const int _maxMicroParticles = 120;

  late Uint8List _glowR;
  late Uint8List _glowG;
  late Uint8List _glowB;
  bool _glowBuffersValid = false;

  late List<int> _starPositions;
  late Set<int> _starSet;
  bool _starsGenerated = false;

  double _prevDayNightT = 0.0;

  PixelRenderer(this.engine);

  Uint8List get pixels => _activePixels;
  List<Int32List> get microParticles => _microParticles;

  void init() {
    final total = engine.gridW * engine.gridH;
    _pixels = Uint8List(total * 4);
    _pixels2 = Uint8List(total * 4);
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

  double dayNightT = 0.0;

  void renderPixels() {
    final total = engine.gridW * engine.gridH;
    final w = engine.gridW;
    final h = engine.gridH;
    final g = engine.grid;
    final t = engine.isNight ? dayNightT : 0.0;
    final fc = engine.frameCount;

    final baseBgR = (12 - t * 6).round().clamp(0, 255);
    final baseBgG = (12 - t * 6).round().clamp(0, 255);
    final baseBgB = (28 - t * 10).round().clamp(0, 255);

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

        // High-emission elements (lightning) get larger radius
        if (emission > 200) glowRadius = 4;

        for (int dy = -glowRadius; dy <= glowRadius; dy++) {
          final ny = ey + dy;
          if (ny < 0 || ny >= h) continue;
          for (int dx = -glowRadius; dx <= glowRadius; dx++) {
            final nx = ex + dx;
            if (nx < 0 || nx >= w) continue;
            final dist = dx.abs() + dy.abs();
            if (dist == 0) continue;
            final ni = ny * w + nx;
            if (g[ni] != El.empty) continue;

            // Intensity falloff by distance
            int fr, fg, fb;
            if (dist <= 1) {
              fr = scaledR;
              fg = scaledG;
              fb = scaledB;
            } else if (dist <= 2) {
              fr = scaledR * 2 ~/ 3;
              fg = scaledG * 2 ~/ 3;
              fb = scaledB * 2 ~/ 3;
            } else if (dist <= 3) {
              fr = scaledR ~/ 3;
              fg = scaledG ~/ 3;
              fb = scaledB ~/ 3;
            } else {
              fr = scaledR ~/ 5;
              fg = scaledG ~/ 5;
              fb = scaledB ~/ 5;
            }
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
    final pxBuf = _activePixels;

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
              final gradientShift = (4 - (y * 6) ~/ h).clamp(0, 6);
              int emptyR = (baseBgR + gradientShift).clamp(0, 30);
              int emptyG = (baseBgG + gradientShift).clamp(0, 30);
              int emptyB = (baseBgB + gradientShift + 2).clamp(0, 40);

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

              final hasGlow = _glowBuffersValid &&
                  (glowR8[i] > 0 || glowG8[i] > 0 || glowB8[i] > 0);
              final hasPheromone = pheroFood[i] > 8 || pheroHome[i] > 8;
              final hasStar = starSet.contains(i);
              if (hasGlow || hasPheromone || hasStar) {
                pxBuf[pi4] = emptyR;
                pxBuf[pi4 + 1] = emptyG;
                pxBuf[pi4 + 2] = emptyB;
                // Use alpha proportional to glow intensity so glow
                // blends with the sky instead of painting opaque black.
                if (hasGlow) {
                  final glowMax = glowR8[i] > glowG8[i]
                      ? (glowR8[i] > glowB8[i] ? glowR8[i] : glowB8[i])
                      : (glowG8[i] > glowB8[i] ? glowG8[i] : glowB8[i]);
                  pxBuf[pi4 + 3] = glowMax < 5 ? 0 : glowMax.clamp(0, 200);
                } else {
                  pxBuf[pi4 + 3] = 255;
                }
              } else {
                pxBuf[pi4] = 0;
                pxBuf[pi4 + 1] = 0;
                pxBuf[pi4 + 2] = 0;
                pxBuf[pi4 + 3] = 0;
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
                  if (rng.nextInt(40) < 3) {
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
                if (rng.nextInt(200) < 1 && y > 1) {
                  spawnParticle(x + rng.nextInt(3) - 1, y - 1,
                      220, 220, 240, 3 + rng.nextInt(2));
                }
              }
            }

            int r, g2, b, a = 255;
            _writeElementColor(
                el, i, x, y, w, h, g, life, velX, velY, fc, rng);
            r = _inlineR;
            g2 = _inlineG;
            b = _inlineB;
            a = _inlineA;

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
      final px = p[0];
      final py = p[1];
      if (px < 0 || px >= w || py < 0 || py >= h) continue;
      final pi4 = (py * w + px) * 4;
      pxBuf[pi4] = (pxBuf[pi4] + p[2]).clamp(0, 255);
      pxBuf[pi4 + 1] = (pxBuf[pi4 + 1] + p[3]).clamp(0, 255);
      pxBuf[pi4 + 2] = (pxBuf[pi4 + 2] + p[4]).clamp(0, 255);
      if (pxBuf[pi4 + 3] == 0) {
        pxBuf[pi4 + 3] = 255;
      }
    }
  }

  Future<ui.Image> buildImage() async {
    final completedBuffer = _activePixels;
    _useFirstBuffer = !_useFirstBuffer;

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      completedBuffer,
      engine.gridW,
      engine.gridH,
      ui.PixelFormat.rgba8888,
      (image) => completer.complete(image),
    );
    return completer.future;
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
      math.Random rng) {
    switch (el) {
      case El.fire:
        final fireLife = life[idx];
        final slow1 = (frameCount + idx * 3) % 8;
        final slow2 = (frameCount * 2 + idx * 7) % 12;
        final slow3 = (frameCount + idx * 13) % 20;
        final flickerSum = (slow1 < 3 ? 18 : 0) +
            (slow2 < 4 ? 14 : 0) +
            (slow3 < 7 ? 10 : 0);
        if (fireLife < 8) {
          _inlineR = 255;
          _inlineG = (245 - flickerSum ~/ 3).clamp(228, 255);
          _inlineB = (200 - flickerSum ~/ 2).clamp(150, 220);
          _inlineA = 255;
        } else if (fireLife < 18) {
          final t2 = ((fireLife - 8) * 255 ~/ 10).clamp(0, 255);
          _inlineR = 255;
          _inlineG = _lerpC(235, 150, t2) + flickerSum ~/ 3;
          _inlineB = _lerpC(180, 15, t2) + flickerSum ~/ 4;
          _inlineG = _inlineG.clamp(120, 255);
          _inlineB = _inlineB.clamp(0, 200);
          _inlineA = 255;
        } else if (fireLife < 32) {
          final t2 = ((fireLife - 18) * 255 ~/ 14).clamp(0, 255);
          _inlineR = _lerpC(255, 230, t2);
          _inlineG = _lerpC(150, 45, t2) + flickerSum ~/ 4;
          _inlineB = (flickerSum ~/ 5).clamp(0, 15);
          _inlineG = _inlineG.clamp(20, 180);
          _inlineA = 255;
        } else {
          final remaining = (80 - fireLife).clamp(1, 48);
          final fade = (remaining * 255 ~/ 48).clamp(0, 255);
          _inlineA = (remaining * 5 + 60).clamp(60, 255);
          _inlineR = _lerpC(80, 200, fade) + flickerSum ~/ 4;
          _inlineG = _lerpC(10, 40, fade);
          _inlineB = (flickerSum ~/ 8).clamp(0, 8);
          _inlineR = _inlineR.clamp(60, 240);
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
        _inlineA = (180 - steamLife * 2).clamp(40, 180);
        final phase = (frameCount + idx * 5) % 30;
        final wisp = phase < 8 ? (8 - phase) * 2 : 0;
        final steamBase = _lerpC(230, 200, (steamLife * 255 ~/ 60).clamp(0, 255));
        _inlineR = (steamBase + wisp).clamp(195, 255);
        _inlineG = (steamBase + wisp).clamp(195, 255);
        _inlineB = (steamBase + 15 + wisp ~/ 2).clamp(210, 255);

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

          if (isTop) {
            final wave = math.sin((frameCount * 0.15 + x * 0.8)) * 0.5 + 0.5;
            final wave2 = math.sin((frameCount * 0.09 + x * 1.3 + 2.0)) * 0.5 + 0.5;
            final shimmer = ((wave * 30 + wave2 * 20)).round();

            final belowIdx = y < h - 1 ? (y + 1) * w + x : -1;
            final isSolid = belowIdx >= 0 && grid[belowIdx] != El.water &&
                grid[belowIdx] != El.empty && grid[belowIdx] != El.oil;

            if (isSolid) {
              _inlineR = (85 + shimmer).clamp(60, 140);
              _inlineG = (210 + shimmer).clamp(190, 255);
              _inlineB = 255;
              _inlineA = 210;
            } else {
              _inlineR = (55 + shimmer).clamp(35, 120);
              _inlineG = (185 + shimmer).clamp(165, 240);
              _inlineB = 255;
              _inlineA = 220;
            }
          } else {
            int depth = 0;
            for (int cy = y - 1; cy >= 0 && depth < 20; cy--) {
              if (grid[cy * w + x] == El.water) {
                depth++;
              } else {
                break;
              }
            }

            final depthFrac = (depth * 255 ~/ 20).clamp(0, 255);
            final baseR = _lerpC(50, 8, depthFrac);
            final baseG = _lerpC(160, 45, depthFrac);
            final baseB = _lerpC(255, 180, depthFrac);
            final baseA = _lerpC(225, 250, depthFrac);

            int caustic = 0;
            if (depth < 8) {
              final cx1 = math.sin((frameCount * 0.12 + x * 0.7 + y * 0.4)) * 0.5 + 0.5;
              final cx2 = math.sin((frameCount * 0.08 + x * 1.1 + y * 0.6 + 1.7)) * 0.5 + 0.5;
              final causticStrength = (1.0 - depth / 8.0);
              caustic = ((cx1 * 12 + cx2 * 8) * causticStrength).round();
            }

            bool nearEdge = false;
            if (x > 0 && grid[y * w + x - 1] != El.water &&
                grid[y * w + x - 1] != El.empty) {
              nearEdge = true;
            } else if (x < w - 1 && grid[y * w + x + 1] != El.water &&
                grid[y * w + x + 1] != El.empty) {
              nearEdge = true;
            }
            final edgeShift = nearEdge ? 12 : 0;

            _inlineR = (baseR + caustic + edgeShift).clamp(0, 80);
            _inlineG = (baseG + caustic + edgeShift).clamp(30, 200);
            _inlineB = (baseB + caustic ~/ 2).clamp(160, 255);
            _inlineA = baseA;
          }
        }

      case El.sand:
        _inlineA = 255;
        final spatial = _spatialBlend(x, y, 5);
        final variation = (spatial * 30) ~/ 256 - 15;
        final coarse = _smoothHash(x, y) % 256;
        final grain = (coarse * 6) ~/ 256 - 3;
        _inlineR = (210 + variation + grain).clamp(185, 238);
        _inlineG = (192 + variation + grain).clamp(168, 218);
        _inlineB = (138 + (variation * 2 ~/ 3) + grain).clamp(112, 165);

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
        final compactDarken = (compaction * 6).round(); // compacted = darker
        final spatial = _spatialBlend(x, y, 4);
        final variation = (spatial * 24) ~/ 256 - 12;
        final fine = _smoothHash(x, y) % 256;
        final grain = (fine * 4) ~/ 256 - 2;
        final warmth = _spatialBlend(x + 100, y + 100, 7);
        final warmShift = (warmth * 10) ~/ 256 - 5;
        final baseR = 135 + variation + warmShift - compactDarken;
        final baseG = 90 + variation ~/ 2 - compactDarken;
        final baseB = 35 + variation ~/ 3 - compactDarken ~/ 2;
        _inlineR =
            (baseR + grain - mFrac * 55).round().clamp(45, 160);
        _inlineG =
            (baseG + grain - mFrac * 45).round().clamp(25, 115);
        _inlineB =
            (baseB + grain - mFrac * 8).round().clamp(8, 55);
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
          _inlineR = (120 + variation).clamp(100, 150);
          _inlineG = (130 + variation).clamp(110, 160);
          _inlineB = (40 + variation).clamp(20, 60);
          _inlineA = 255;
        } else {
          final shade = ((idx % 5) * 8 + variation).clamp(0, 50);
          _inlineA = 255;
          switch (pType) {
            case kPlantGrass:
              _inlineR = 30 + shade;
              _inlineG = 170 + shade ~/ 2;
              _inlineB = 30 + shade;
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
              } else {
                _inlineR = 20 + shade;
                _inlineG = 160 + shade;
                _inlineB = 20 + shade;
              }
            case kPlantTree:
              if (pStage == kStGrowing) {
                _inlineR = (100 + variation).clamp(80, 120);
                _inlineG = (60 + variation).clamp(40, 80);
                _inlineB = (25 + variation).clamp(10, 40);
              } else {
                _inlineR = 15 + shade ~/ 2;
                _inlineG = 120 + shade;
                _inlineB = 15 + shade ~/ 2;
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
                _inlineR = 10 + shade;
                _inlineG = 180 + shade ~/ 2;
                _inlineB = 10 + shade;
              } else {
                _inlineR = 30 + shade;
                _inlineG = 140 + shade;
                _inlineB = 30 + shade;
              }
            default:
              _inlineR = 20 + shade;
              _inlineG = 160 + shade;
              _inlineB = 20 + shade;
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
        final depthDarken = (stoneDepth * 1.8).round(); // deeper = darker
        final spatial = _spatialBlend(x, y, 6);
        final layer = (spatial * 20) ~/ 256 - 10;
        final fine = _smoothHash(x * 3, y * 3) % 256;
        final grain = (fine * 6) ~/ 256 - 3;
        final sediment = _spatialBlend(x + 50, y * 2, 8);
        final sedimentShift = (sediment * 8) ~/ 256 - 4;
        _inlineR = (125 + layer + grain - depthDarken).clamp(68, 162);
        _inlineG = (123 + layer + grain + sedimentShift - depthDarken).clamp(66, 160);
        _inlineB = (135 + layer + grain - sedimentShift - depthDarken ~/ 2).clamp(80, 175);
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
        final variation = ((idx * 7 + y * 3) % 11) - 5;
        final v = ((idx % 5) * 5 + variation).clamp(0, 30);
        _inlineR = (139 - v).clamp(100, 150);
        _inlineG = (105 - v).clamp(70, 120);
        _inlineB = 20;
        _inlineA = 255;

      case El.oil:
        _inlineA = 255;
        final isTop = y > 0 && grid[(y - 1) * w + x] != El.oil;
        if (isTop) {
          final shimmer =
              (math.sin(frameCount * 0.2 + x * 0.5) * 12 + 12).round();
          _inlineR = 68 + shimmer;
          _inlineG = 50 + shimmer;
          _inlineB = 38 + shimmer ~/ 2;
        } else {
          final variation = ((idx * 7 + y * 3) % 11) - 5;
          _inlineR = (50 + variation).clamp(30, 70);
          _inlineG = (37 + variation).clamp(20, 55);
          _inlineB = (28 + variation).clamp(10, 45);
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
        final pulse1 = math.sin(frameCount * 0.08 + idx * 0.2) * 0.5 + 0.5;
        final pulse2 = math.sin(frameCount * 0.12 + idx * 0.35 + 1.5) * 0.5 + 0.5;
        final lavaFlicker = ((pulse1 * 25 + pulse2 * 18)).round();
        final isLavaSurf = y > 0 && grid[(y - 1) * w + x] == El.empty;
        final isBrightSpot = (idx * 17 + frameCount) % 25 == 0;
        final isSuperBright = (idx * 31 + frameCount * 2) % 60 == 0;
        if ((isBrightSpot || isSuperBright) && lavaLife < 150) {
          final spotB = isSuperBright ? 230 : 180;
          _inlineR = 255;
          _inlineG = 250 + lavaFlicker ~/ 6;
          _inlineG = _inlineG.clamp(245, 255);
          _inlineB = spotB;
          _inlineA = 255;
        } else if (lavaLife < 40) {
          final surfBoost = isLavaSurf ? 15 : 0;
          _inlineR = 255;
          _inlineG = (220 + lavaFlicker ~/ 2 + surfBoost).clamp(200, 255);
          _inlineB = (100 + lavaFlicker + surfBoost).clamp(80, 180);
          _inlineA = 255;
        } else if (lavaLife < 120) {
          final t2 = ((lavaLife - 40) * 255 ~/ 80).clamp(0, 255);
          final crustHash = _smoothHash(x, y);
          final isCrustVein = lavaLife > 60 && (crustHash % 8 == 0);
          if (isCrustVein) {
            _inlineR = (160 + lavaFlicker ~/ 2).clamp(140, 200);
            _inlineG = (25 + lavaFlicker ~/ 5).clamp(12, 50);
            _inlineB = (lavaFlicker ~/ 8).clamp(0, 10);
          } else {
            _inlineR = 255;
            _inlineG = (_lerpC(200, 50, t2) + lavaFlicker ~/ 2)
                .clamp(0, 255);
            _inlineB = (lavaFlicker ~/ 3).clamp(0, 40);
          }
          _inlineA = 255;
        } else {
          final t2 = ((lavaLife - 120) * 255 ~/ 80).clamp(0, 255);
          final crustHash = _smoothHash(x, y);
          final isDarkPatch = crustHash % 5 < 2;
          if (isDarkPatch) {
            _inlineR = (_lerpC(190, 90, t2)).clamp(0, 255);
            _inlineG = (_lerpC(25, 8, t2) + lavaFlicker ~/ 6).clamp(0, 40);
            _inlineB = 0;
          } else {
            _inlineR = _lerpC(250, 140, t2);
            _inlineG =
                (_lerpC(50, 20, t2) + lavaFlicker ~/ 4).clamp(0, 80);
            _inlineB = (lavaFlicker ~/ 6).clamp(0, 10);
          }
          _inlineA = 255;
        }

      case El.snow:
        _inlineA = 255;
        final snowSpatial = _smoothHash(x, y) % 256;
        final snowVar = (snowSpatial * 8) ~/ 256 - 4;
        final glint = (frameCount + idx * 7) % 30 < 2 ? 12 : 0;
        _inlineR = (238 + snowVar + glint).clamp(228, 255);
        _inlineG = (240 + snowVar + glint).clamp(232, 255);
        _inlineB = 255;

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
          final grainHash = _smoothHash(x, y * 3);
          final grainVal = (grainHash % 20) - 10;
          final isKnot = _smoothHash(x * 11, y * 7) % 19 == 0;
          final waterlog = velY[idx].clamp(0, 3) * 20;
          if (isKnot) {
            _inlineR = (110 - waterlog + grainVal).clamp(50, 135);
            _inlineG = (55 - waterlog + grainVal ~/ 2).clamp(25, 78);
            _inlineB = (30 - waterlog + grainVal ~/ 3).clamp(10, 50);
          } else {
            final band = _spatialBlend(x, y * 3, 3);
            final bandShift = (band * 18) ~/ 256 - 9;
            _inlineR = (158 - waterlog + variation + bandShift).clamp(65, 185);
            _inlineG = (82 - waterlog + variation ~/ 2 + bandShift ~/ 2).clamp(32, 110);
            _inlineB = (44 - waterlog + variation ~/ 3 + bandShift ~/ 3).clamp(12, 68);
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
        final bubblePhase = (frameCount * 3 + idx * 17) % 60;
        final bright = (frameCount + idx) % 8 < 3 ? 30 : 0;
        final variation = ((idx * 7 + y * 3) % 11) - 5;
        if (bubblePhase < 15) {
          _inlineR = (200 + bright + variation).clamp(170, 240);
          _inlineG = (180 + bright + variation).clamp(155, 220);
          _inlineB = (240 + bright).clamp(220, 255);
        } else if (bubblePhase < 30) {
          _inlineR = (150 + bright + variation).clamp(130, 195);
          _inlineG = (230 + bright + variation).clamp(210, 255);
          _inlineB = (245 + bright).clamp(230, 255);
        } else if (bubblePhase < 45) {
          _inlineR = (220 + bright + variation).clamp(195, 255);
          _inlineG = (220 + bright + variation).clamp(195, 255);
          _inlineB = (180 + bright).clamp(160, 220);
        } else {
          _inlineR = (173 + bright + variation).clamp(150, 220);
          _inlineG = (216 + bright + variation).clamp(190, 255);
          _inlineB = (230 + bright).clamp(210, 255);
        }
        _inlineA = 170;

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
