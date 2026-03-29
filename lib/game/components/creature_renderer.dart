import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/components.dart';

import '../../creatures/ant.dart';
import '../../creatures/colony.dart';
import '../../creatures/creature_registry.dart';
import '../particle_engine_game.dart';
import '../../simulation/element_registry.dart';
import '../../simulation/simulation_engine.dart';

/// Renders all living creatures with species-specific visuals, animation,
/// environmental awareness, state indication, trails, and nest effects.
///
/// All integer math. No heap allocation in render loop.
/// Uses pre-computed phenotype when available, falls back to defaults.
class CreatureRenderer extends PositionComponent
    with HasGameReference<ParticleEngineGame> {
  CreatureRenderer({
    required this.registry,
    required this.simulation,
    required this.cellSize,
  });

  final CreatureRegistry registry;
  final SimulationEngine simulation;
  final double cellSize;

  // -------------------------------------------------------------------------
  // Frame counter
  // -------------------------------------------------------------------------

  int _frameCount = 0;

  // -------------------------------------------------------------------------
  // Trail system
  // -------------------------------------------------------------------------

  /// Per-ant trail: key = colonyId * 10000 + antIndex.
  final Map<int, List<_TrailPoint>> _trails = {};
  static const int _maxTrailLength = 8;
  static const int _trailFadeFrames = 30;

  /// Grid-sized accumulator: cells > 10 render as dark tint (colony highways).
  Uint8List? _trailAccumulator;
  int _trailDecayCounter = 0;

  // -------------------------------------------------------------------------
  // Colony body colors — warm earth tones that fit the pixel world
  // -------------------------------------------------------------------------

  static const List<int> _colonyBodyColors = [
    0xFF2A1A10, // Dark brown
    0xFF1A1020, // Dark purple-brown
    0xFF102A1A, // Dark green-brown
    0xFF2A2010, // Dark amber
    0xFF1A1A2A, // Dark blue-grey
    0xFF2A1020, // Dark red-brown
    0xFF20201A, // Dark olive
    0xFF1A2020, // Dark teal
  ];

  static const List<int> _colonyAccentColors = [
    0xFFC89060, // Warm gold
    0xFF9060C8, // Purple
    0xFF60C890, // Green
    0xFFC8B060, // Amber
    0xFF6090C8, // Blue
    0xFFC86070, // Red
    0xFF90C860, // Lime
    0xFF60C0C8, // Cyan
  ];

  // -------------------------------------------------------------------------
  // Pre-computed food dot offsets for nest rendering
  // -------------------------------------------------------------------------

  static const List<int> _foodDotDx = [2, 1, 0, -1, -2, -1, 0, 1];
  static const List<int> _foodDotDy = [0, 1, 2, 1, 0, -1, -2, -1];

  // -------------------------------------------------------------------------
  // Static scratch fields for environment sampling (no allocation)
  // -------------------------------------------------------------------------

  static int _envR = 0;
  static int _envG = 0;
  static int _envB = 0;

  /// Reusable paint object to avoid per-frame allocation.
  static final ui.Paint _paint = ui.Paint();

  // -------------------------------------------------------------------------
  // Integer sine (copied from pixel_renderer.dart)
  // -------------------------------------------------------------------------

  /// Pure-integer sine approximation. Input: phase [0..255] wrapping.
  /// Returns value in [0..256] where 128 = zero-crossing.
  @pragma('vm:prefer-inline')
  static int _fastSinI(int phase) {
    final ix = phase & 0xFF;
    if (ix < 64) return 128 + (ix << 1);
    if (ix < 128) return 128 + ((128 - ix) << 1);
    if (ix < 192) return 128 - ((ix - 128) << 1);
    return 128 - ((256 - ix) << 1);
  }

  @pragma('vm:prefer-inline')
  static int _smoothHash(int x, int y) =>
      ((x * 374761393 + y * 668265263) * 1274126177) & 0x7FFFFFFF;

  // -------------------------------------------------------------------------
  // Render entry point
  // -------------------------------------------------------------------------

  @override
  void render(ui.Canvas canvas) {
    super.render(canvas);
    _frameCount++;
    canvas.save();
    canvas.scale(cellSize, cellSize);

    final paint = _paint;
    final mobileDetail = game.mobileCreatureDetail;
    final gridW = simulation.gridW;
    final gridH = simulation.gridH;
    final renderedByColony = <int, int>{};
    final view = _visibleViewportBounds(gridW, gridH);

    // Lazy-init trail accumulator.
    final totalCells = gridW * gridH;
    if ((mobileDetail || _trails.isNotEmpty) &&
        (_trailAccumulator == null ||
            _trailAccumulator!.length != totalCells)) {
      _trailAccumulator = Uint8List(totalCells);
    }

    // Decay trail accumulator every 60 frames.
    if (mobileDetail) {
      _trailDecayCounter++;
      if (_trailDecayCounter >= 60) {
        _trailDecayCounter = 0;
        final acc = _trailAccumulator!;
        for (var i = 0; i < acc.length; i++) {
          if (acc[i] > 0) acc[i]--;
        }
      }
    }
    final renderTrails = mobileDetail;
    final renderHighways = mobileDetail && (_frameCount & 1) == 0;

    if (renderHighways) {
      _renderHighways(canvas, paint, gridW, gridH);
    }
    if (renderTrails) {
      _renderTrails(canvas, paint);
    }

    // Render each colony.
    for (final colony in registry.colonies) {
      final colorIdx = colony.id % _colonyBodyColors.length;
      final bodyColor = _colonyBodyColors[colorIdx];
      final accentColor = _colonyAccentColors[colorIdx];

      // Nest.
      if (_isVisibleWrappedX(colony.originX.toDouble(), view, gridW) &&
          _isVisibleY(colony.originY.toDouble(), view)) {
        _renderNest(canvas, paint, colony, bodyColor);
      }

      // Each ant.
      for (var i = 0; i < colony.ants.length; i++) {
        final ant = colony.ants[i];
        if (!ant.alive) continue;
        if (!_isVisibleWrappedX(ant.x.toDouble(), view, gridW) ||
            !_isVisibleY(ant.y.toDouble(), view)) {
          continue;
        }
        renderedByColony[colony.id] = (renderedByColony[colony.id] ?? 0) + 1;

        // Compute environment context once per creature.
        _computeEnvironment(ant);

        // Render based on species and caste.
        switch (ant.species) {
          case CreatureSpecies.ant:
            if (ant.role == AntRole.queen) {
              _renderQueen(
                canvas,
                paint,
                ant,
                colony,
                bodyColor,
                accentColor,
                i,
              );
            } else {
              _renderAnt(canvas, paint, ant, colony, bodyColor, accentColor, i);
            }
          case CreatureSpecies.worm:
            _renderWorm(canvas, paint, ant, bodyColor, accentColor, i);
          case CreatureSpecies.beetle:
            _renderBeetle(canvas, paint, ant, bodyColor, accentColor, i);
          case CreatureSpecies.spider:
            _renderSpider(canvas, paint, ant, bodyColor, accentColor, i);
          case CreatureSpecies.fish:
            _renderFish(canvas, paint, ant, bodyColor, accentColor, i);
          case CreatureSpecies.bee:
            _renderBee(canvas, paint, ant, bodyColor, accentColor, i);
          case CreatureSpecies.firefly:
            _renderFirefly(canvas, paint, ant, bodyColor, accentColor, i);
        }

        if (mobileDetail) {
          _updateTrail(colony.id, i, ant);
        }
      }
    }
    registry.reportRenderedCounts(renderedByColony);
    canvas.restore();
  }

  ({double centerX, double centerY, double halfWidth, double halfHeight})
  _visibleViewportBounds(int gridW, int gridH) {
    final cam = game.camera.viewfinder;
    final viewport = game.camera.viewport.size;
    final halfWidth = viewport.x / cam.zoom / cellSize / 2.0 + 6.0;
    final halfHeight = viewport.y / cam.zoom / cellSize / 2.0 + 6.0;
    var centerX = (cam.position.x / cellSize) % gridW;
    if (centerX < 0) {
      centerX += gridW;
    }
    final centerY = (cam.position.y / cellSize).clamp(
      0.0,
      (gridH - 1).toDouble(),
    );
    return (
      centerX: centerX,
      centerY: centerY,
      halfWidth: halfWidth,
      halfHeight: halfHeight,
    );
  }

  @pragma('vm:prefer-inline')
  bool _isVisibleWrappedX(
    double x,
    ({double centerX, double centerY, double halfWidth, double halfHeight})
    view,
    int gridW,
  ) {
    final dx = (x - view.centerX).abs();
    final wrappedDx = dx < (gridW - dx) ? dx : (gridW - dx);
    return wrappedDx <= view.halfWidth;
  }

  @pragma('vm:prefer-inline')
  bool _isVisibleY(
    double y,
    ({double centerX, double centerY, double halfWidth, double halfHeight})
    view,
  ) {
    return (y - view.centerY).abs() <= view.halfHeight;
  }

  // -------------------------------------------------------------------------
  // Environment computation (Phase 4)
  // -------------------------------------------------------------------------

  /// Compute environmental color modulation for a creature. Writes to
  /// static scratch fields _envR/_envG/_envB. No allocation.
  void _computeEnvironment(Ant ant) {
    final gridW = simulation.gridW;
    final idx = ant.y * gridW + ant.x;
    final total = gridW * simulation.gridH;

    // Start from base white — caller applies to species base color.
    _envR = 256;
    _envG = 256;
    _envB = 256;

    // Underground: multiply RGB * 140/256.
    if (idx >= 0 && idx < total && idx < simulation.luminance.length) {
      if (simulation.luminance[idx] < 40) {
        _envR = 140;
        _envG = 140;
        _envB = 140;
      }
    }

    // In water: add blue, reduce red.
    if (idx >= 0 && idx < total && simulation.grid[idx] == El.water) {
      _envB = (_envB * 256 + 30 * 256) ~/ 256; // +30 blue (applied later)
      _envR = (_envR * 200) ~/ 256;
    }

    // Near fire (temperature > 180): warm tint.
    if (idx >= 0 && idx < total && idx < simulation.temperature.length) {
      if (simulation.temperature[idx] > 180) {
        // Flag for red/green boost — applied in color computation.
        _envR = (_envR + 20).clamp(0, 512);
        _envG = (_envG + 10).clamp(0, 512);
      }
    }
  }

  /// Apply environment modulation + state to base color components.
  /// Modifies r, g, b in place via return tuple. All integer math.
  @pragma('vm:prefer-inline')
  static (int, int, int) _applyEnvironmentAndState(
    int r,
    int g,
    int b,
    Ant ant,
    int accentColor,
    int frameCount,
  ) {
    // Apply environment multipliers.
    r = (r * _envR) >> 8;
    g = (g * _envG) >> 8;
    b = (b * _envB) >> 8;

    // Carrying food: blend toward gold accent.
    if (ant.carryingFood) {
      final ar = (accentColor >> 16) & 0xFF;
      final ag = (accentColor >> 8) & 0xFF;
      final ab = accentColor & 0xFF;
      r = (r + ar) >> 1;
      g = (g + ag) >> 1;
      b = (b + ab) >> 1;
    }

    // Fleeing/alert: brighter, reddish tint + flash.
    if (ant.dangerExposureTicks > 0) {
      r = r + 60;
      if (r > 255) r = 255;
      if (frameCount & 3 < 2) {
        r = r + 40;
        if (r > 255) r = 255;
      }
    }

    // Low energy: desaturate toward grey.
    if (ant.energy < 0.3) {
      final grey = (r * 77 + g * 150 + b * 29) >> 8;
      final blend = ((1.0 - ant.energy / 0.3) * 128).round();
      r = (r * (256 - blend) + grey * blend) >> 8;
      g = (g * (256 - blend) + grey * blend) >> 8;
      b = (b * (256 - blend) + grey * blend) >> 8;
    }

    // Idle: breathing oscillation +/- 8 brightness.
    if (ant.isIdle) {
      final breath = (_fastSinI((frameCount * 2) & 0xFF) - 128) >> 4; // [-8, 8]
      r = (r + breath).clamp(0, 255);
      g = (g + breath).clamp(0, 255);
      b = (b + breath).clamp(0, 255);
    }

    // Clamp final.
    if (r > 255) r = 255;
    if (g > 255) g = 255;
    if (b > 255) b = 255;
    if (r < 0) r = 0;
    if (g < 0) g = 0;
    if (b < 0) b = 0;

    return (r, g, b);
  }

  // -------------------------------------------------------------------------
  // ANT RENDERING (Phase 3)
  // -------------------------------------------------------------------------

  void _renderAnt(
    ui.Canvas canvas,
    ui.Paint paint,
    Ant ant,
    Colony colony,
    int bodyColor,
    int accentColor,
    int antIndex,
  ) {
    final x = ant.x.toDouble();
    final y = ant.y.toDouble();

    // Base color extraction.
    int r = (bodyColor >> 16) & 0xFF;
    int g = (bodyColor >> 8) & 0xFF;
    int b = bodyColor & 0xFF;

    // Individual variation from genome hash.
    final genHash = _smoothHash(ant.genomeIndex, ant.colonyId);
    r = (r + ((genHash & 0x1F) - 16)).clamp(0, 255);
    g = (g + (((genHash >> 5) & 0x1F) - 16)).clamp(0, 255);
    b = (b + (((genHash >> 10) & 0x1F) - 16)).clamp(0, 255);

    // Apply environment + state.
    final (mr, mg, mb) = _applyEnvironmentAndState(
      r,
      g,
      b,
      ant,
      accentColor,
      _frameCount,
    );

    // Direction: derive from ant index + position hash (no private field access).
    final dirHash = (ant.x * 17 + antIndex * 7 + _frameCount ~/ 4) & 0xFF;
    final dir = dirHash < 128 ? 1 : -1;

    // --- Head pixel (brighter) ---
    final headR = (mr + 15).clamp(0, 255);
    final headG = (mg + 10).clamp(0, 255);
    final headB = (mb + 5).clamp(0, 255);
    paint.color = ui.Color.fromARGB(255, headR, headG, headB);
    canvas.drawRect(ui.Rect.fromLTWH(x, y, 1, 1), paint);

    // --- Abdomen pixel (darker, behind head) ---
    final abdX = x - dir.toDouble();
    if (abdX >= 0 && abdX < simulation.gridW) {
      final abdR = (mr * 180) >> 8; // darker
      final abdG = (mg * 180) >> 8;
      final abdB = (mb * 180) >> 8;
      paint.color = ui.Color.fromARGB(255, abdR, abdG, abdB);
      canvas.drawRect(ui.Rect.fromLTWH(abdX, y, 1, 1), paint);

      // Carrying food: gold accent on abdomen.
      if (ant.carryingFood) {
        paint.color = const ui.Color.fromARGB(200, 200, 180, 80);
        canvas.drawRect(ui.Rect.fromLTWH(abdX, y, 1, 1), paint);
      }
      // Carrying dirt: brown accent on abdomen.
      if (ant.carryingDirt) {
        paint.color = const ui.Color.fromARGB(200, 120, 80, 40);
        canvas.drawRect(ui.Rect.fromLTWH(abdX, y, 1, 1), paint);
      }
    }

    // --- Legs: pixels above + below thorax, oscillating alpha ---
    final legPhase = (_frameCount + antIndex * 3) & 7;
    final legAlphaBase = 60;
    final legAlpha = legAlphaBase + ((legPhase < 4) ? 30 : 0);
    paint.color = ui.Color.fromARGB(legAlpha, mr, mg, mb);
    final thoraxX = abdX; // Legs are on the abdomen pixel.
    if (y > 0) {
      canvas.drawRect(ui.Rect.fromLTWH(thoraxX, y - 1, 1, 1), paint);
    }
    if (y < simulation.gridH - 1) {
      canvas.drawRect(ui.Rect.fromLTWH(thoraxX, y + 1, 1, 1), paint);
    }

    // --- Antennae: faint pixel ahead of head at y-1 ---
    final antAlpha = 40 + (((_frameCount + antIndex) % 20 < 10) ? 20 : 0);
    paint.color = ui.Color.fromARGB(antAlpha, headR, headG, headB);
    final antX = x + dir.toDouble();
    if (antX >= 0 && antX < simulation.gridW && y > 0) {
      canvas.drawRect(ui.Rect.fromLTWH(antX, y - 1, 1, 1), paint);
    }

    // --- Shadow: dark pixel below body (only above ground) ---
    final idx = ant.y * simulation.gridW + ant.x;
    final isUnderground =
        idx >= 0 &&
        idx < simulation.luminance.length &&
        simulation.luminance[idx] < 40;
    if (y < simulation.gridH - 1 && !isUnderground) {
      paint.color = const ui.Color.fromARGB(25, 0, 0, 0);
      canvas.drawRect(ui.Rect.fromLTWH(x, y + 1, 1, 1), paint);
    }
  }

  // -------------------------------------------------------------------------
  // QUEEN RENDERING — larger, distinctive, crown marking
  // -------------------------------------------------------------------------

  void _renderQueen(
    ui.Canvas canvas,
    ui.Paint paint,
    Ant ant,
    Colony colony,
    int bodyColor,
    int accentColor,
    int antIndex,
  ) {
    final x = ant.x.toDouble();
    final y = ant.y.toDouble();

    // Queen is brighter, warmer toned.
    int r = ((bodyColor >> 16) & 0xFF) + 30;
    int g = ((bodyColor >> 8) & 0xFF) + 15;
    int b = (bodyColor & 0xFF);
    r = r.clamp(0, 255);
    g = g.clamp(0, 255);

    final (mr, mg, mb) = _applyEnvironmentAndState(
      r,
      g,
      b,
      ant,
      accentColor,
      _frameCount,
    );

    final dir = ((ant.x * 17 + antIndex) & 1) == 0 ? 1 : -1;

    // --- Crown pixel (above head, golden) ---
    if (y > 0) {
      final crownPhase = (_frameCount + antIndex * 5) % 40;
      final crownAlpha = crownPhase < 20 ? 180 : 140;
      paint.color = ui.Color.fromARGB(crownAlpha, 220, 190, 60);
      canvas.drawRect(ui.Rect.fromLTWH(x, y - 1, 1, 1), paint);
    }

    // --- Head pixel (brightest) ---
    final headR = (mr + 25).clamp(0, 255);
    final headG = (mg + 15).clamp(0, 255);
    final headB = (mb + 5).clamp(0, 255);
    paint.color = ui.Color.fromARGB(255, headR, headG, headB);
    canvas.drawRect(ui.Rect.fromLTWH(x, y, 1, 1), paint);

    // --- Thorax pixel ---
    final thoraxX = x - dir.toDouble();
    paint.color = ui.Color.fromARGB(255, mr, mg, mb);
    canvas.drawRect(ui.Rect.fromLTWH(thoraxX, y, 1, 1), paint);

    // --- Large abdomen (2 pixels wide, extends back) ---
    final abd1X = thoraxX - dir.toDouble();
    final abdR = (mr * 200) >> 8;
    final abdG = (mg * 200) >> 8;
    final abdB = (mb * 200) >> 8;
    paint.color = ui.Color.fromARGB(255, abdR, abdG, abdB);
    canvas.drawRect(ui.Rect.fromLTWH(abd1X, y, 1, 1), paint);
    if (y < simulation.gridH - 1) {
      canvas.drawRect(ui.Rect.fromLTWH(abd1X, y + 1, 1, 1), paint);
    }
    // Extra abdomen segment for queen's large body.
    final abd2X = abd1X - dir.toDouble();
    paint.color = ui.Color.fromARGB(220, abdR, abdG, abdB);
    canvas.drawRect(ui.Rect.fromLTWH(abd2X, y, 1, 1), paint);

    // --- Legs (animated) ---
    final legPhase = (_frameCount + antIndex * 3) & 7;
    final legAlpha = 50 + ((legPhase < 4) ? 40 : 0);
    paint.color = ui.Color.fromARGB(legAlpha, mr, mg, mb);
    if (y > 0) {
      canvas.drawRect(ui.Rect.fromLTWH(thoraxX, y - 1, 1, 1), paint);
    }
    if (y < simulation.gridH - 1) {
      canvas.drawRect(ui.Rect.fromLTWH(thoraxX, y + 1, 1, 1), paint);
    }

    // --- Soft glow around queen (pulsing) ---
    final glowPhase = _fastSinI((_frameCount * 2) & 0xFF);
    final glowAlpha = 10 + ((glowPhase * 15) >> 8);
    paint.color = ui.Color.fromARGB(glowAlpha, 220, 190, 60);
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        canvas.drawRect(ui.Rect.fromLTWH(x + dx, y + dy, 1, 1), paint);
      }
    }
  }

  // -------------------------------------------------------------------------
  // WORM RENDERING
  // -------------------------------------------------------------------------

  void _renderWorm(
    ui.Canvas canvas,
    ui.Paint paint,
    Ant ant,
    int bodyColor,
    int accentColor,
    int antIndex,
  ) {
    final x = ant.x.toDouble();
    final y = ant.y.toDouble();

    int r = (bodyColor >> 16) & 0xFF;
    int g = (bodyColor >> 8) & 0xFF;
    int b = bodyColor & 0xFF;
    // Pink tint for worms.
    r = (r + 40).clamp(0, 255);
    b = (b + 15).clamp(0, 255);

    final (mr, mg, mb) = _applyEnvironmentAndState(
      r,
      g,
      b,
      ant,
      accentColor,
      _frameCount,
    );

    // Body length: 4 segments default.
    const bodyLength = 4;
    final dir = ((ant.x * 17 + antIndex) & 1) == 0 ? 1 : -1;

    for (var seg = 0; seg < bodyLength; seg++) {
      // Undulation offset per segment.
      final undY =
          _fastSinI((_frameCount * 3 + seg * 40) & 0xFF) >> 7; // 0 or 1
      final segX = x - dir * seg.toDouble();
      final segY = y + undY.toDouble();

      if (segX < 0 || segX >= simulation.gridW) continue;
      if (segY < 0 || segY >= simulation.gridH) continue;

      // Head = brightest, tail = progressively darker.
      final fade = 256 - (seg * 30);
      final sr = (mr * fade) >> 8;
      final sg = (mg * fade) >> 8;
      final sb = (mb * fade) >> 8;

      paint.color = ui.Color.fromARGB(
        255,
        sr.clamp(0, 255),
        sg.clamp(0, 255),
        sb.clamp(0, 255),
      );
      canvas.drawRect(ui.Rect.fromLTWH(segX, segY, 1, 1), paint);
    }
  }

  // -------------------------------------------------------------------------
  // BEETLE RENDERING (Phase 3)
  // -------------------------------------------------------------------------

  void _renderBeetle(
    ui.Canvas canvas,
    ui.Paint paint,
    Ant ant,
    int bodyColor,
    int accentColor,
    int antIndex,
  ) {
    final x = ant.x.toDouble();
    final y = ant.y.toDouble();

    int r = (bodyColor >> 16) & 0xFF;
    int g = (bodyColor >> 8) & 0xFF;
    int b = bodyColor & 0xFF;

    final (mr, mg, mb) = _applyEnvironmentAndState(
      r,
      g,
      b,
      ant,
      accentColor,
      _frameCount,
    );

    // 2px wide body (head + body).
    final dir = ((ant.x * 17 + antIndex) & 1) == 0 ? 1 : -1;
    paint.color = ui.Color.fromARGB(255, mr, mg, mb);
    canvas.drawRect(ui.Rect.fromLTWH(x, y, 1, 1), paint);

    final bodyX = x - dir.toDouble();
    if (bodyX >= 0 && bodyX < simulation.gridW) {
      // Specular shine: brightness boost via _fastSinI on body pixel.
      final shine =
          _fastSinI((_frameCount * 2 + ant.x * 7) & 0xFF) >> 4; // 0-16
      final sr = (mr + shine).clamp(0, 255);
      paint.color = ui.Color.fromARGB(255, sr, mg, mb);
      canvas.drawRect(ui.Rect.fromLTWH(bodyX, y, 1, 1), paint);

      // Fleeing: rear pixel alternates brightness every 2 frames.
      if (ant.dangerExposureTicks > 0 && (_frameCount & 3) < 2) {
        paint.color = ui.Color.fromARGB(
          255,
          (mr + 40).clamp(0, 255),
          (mg + 20).clamp(0, 255),
          mb,
        );
        canvas.drawRect(ui.Rect.fromLTWH(bodyX, y, 1, 1), paint);
      }
    }
  }

  // -------------------------------------------------------------------------
  // SPIDER RENDERING (Phase 3)
  // -------------------------------------------------------------------------

  void _renderSpider(
    ui.Canvas canvas,
    ui.Paint paint,
    Ant ant,
    int bodyColor,
    int accentColor,
    int antIndex,
  ) {
    final x = ant.x.toDouble();
    final y = ant.y.toDouble();

    int r = (bodyColor >> 16) & 0xFF;
    int g = (bodyColor >> 8) & 0xFF;
    int b = bodyColor & 0xFF;

    final (mr, mg, mb) = _applyEnvironmentAndState(
      r,
      g,
      b,
      ant,
      accentColor,
      _frameCount,
    );

    // In caves: INCREASE brightness by 20.
    final idx = ant.y * simulation.gridW + ant.x;
    final inCave =
        idx >= 0 &&
        idx < simulation.luminance.length &&
        simulation.luminance[idx] < 40;
    final caveBoost = inCave ? 20 : 0;

    // Center body: 1 dark pixel.
    final br = (mr * 140 ~/ 256 + caveBoost).clamp(0, 255);
    final bg = (mg * 140 ~/ 256 + caveBoost).clamp(0, 255);
    final bb = (mb * 140 ~/ 256 + caveBoost).clamp(0, 255);
    paint.color = ui.Color.fromARGB(255, br, bg, bb);
    canvas.drawRect(ui.Rect.fromLTWH(x, y, 1, 1), paint);

    // 4 diagonal legs: alternate pairs by frame.
    const legAlpha = 35;
    paint.color = ui.Color.fromARGB(legAlpha + caveBoost, mr, mg, mb);
    final legPair = (_frameCount >> 2) & 1; // switch every 4 frames
    if (legPair == 0) {
      // NE + SW
      _drawPixelIfValid(canvas, paint, x + 1, y - 1);
      _drawPixelIfValid(canvas, paint, x - 1, y + 1);
    } else {
      // NW + SE
      _drawPixelIfValid(canvas, paint, x - 1, y - 1);
      _drawPixelIfValid(canvas, paint, x + 1, y + 1);
    }
  }

  // -------------------------------------------------------------------------
  // FISH RENDERING (Phase 3)
  // -------------------------------------------------------------------------

  void _renderFish(
    ui.Canvas canvas,
    ui.Paint paint,
    Ant ant,
    int bodyColor,
    int accentColor,
    int antIndex,
  ) {
    final x = ant.x.toDouble();
    final y = ant.y.toDouble();

    int r = (bodyColor >> 16) & 0xFF;
    int g = (bodyColor >> 8) & 0xFF;
    int b = bodyColor & 0xFF;

    final (mr, mg, mb) = _applyEnvironmentAndState(
      r,
      g,
      b,
      ant,
      accentColor,
      _frameCount,
    );

    final dir = ((ant.x * 17 + antIndex) & 1) == 0 ? 1 : -1;

    // Blend 30% water blue into fish color.
    const waterB = 0xFF; // from 0xFF2E9AFF
    const waterG = 0x9A;
    const waterR = 0x2E;
    final fr = (mr * 179 + waterR * 77) >> 8; // 70% fish + 30% water
    final fg = (mg * 179 + waterG * 77) >> 8;
    final fb = (mb * 179 + waterB * 77) >> 8;

    // Head pixel: brighter, blue-shifted.
    final headR = (fr + 10).clamp(0, 255);
    final headG = (fg + 5).clamp(0, 255);
    final headB = (fb + 20).clamp(0, 255);
    paint.color = ui.Color.fromARGB(255, headR, headG, headB);
    canvas.drawRect(ui.Rect.fromLTWH(x, y, 1, 1), paint);

    // Body pixel with shimmer.
    final shimmer =
        _fastSinI((_frameCount * 4 + ant.x * 13) & 0xFF) >> 5; // 0-8
    paint.color = ui.Color.fromARGB(
      255,
      (fr + shimmer).clamp(0, 255),
      fg.clamp(0, 255),
      fb.clamp(0, 255),
    );
    final bodyX = x - dir.toDouble();
    if (bodyX >= 0 && bodyX < simulation.gridW) {
      canvas.drawRect(ui.Rect.fromLTWH(bodyX, y, 1, 1), paint);
    }

    // Tail: alternates Y position.
    final tailOsc = ((_frameCount ~/ 6) & 1); // 0 or 1
    final tailX = x - dir * 2.0;
    final tailY = y + tailOsc.toDouble();
    if (tailX >= 0 &&
        tailX < simulation.gridW &&
        tailY >= 0 &&
        tailY < simulation.gridH) {
      paint.color = ui.Color.fromARGB(
        180,
        fr.clamp(0, 255),
        fg.clamp(0, 255),
        fb.clamp(0, 255),
      );
      canvas.drawRect(ui.Rect.fromLTWH(tailX, tailY, 1, 1), paint);
    }
  }

  // -------------------------------------------------------------------------
  // BEE RENDERING (Phase 3)
  // -------------------------------------------------------------------------

  void _renderBee(
    ui.Canvas canvas,
    ui.Paint paint,
    Ant ant,
    int bodyColor,
    int accentColor,
    int antIndex,
  ) {
    final x = ant.x.toDouble();
    final y = ant.y.toDouble();

    // Body: alternate yellow/dark every 2 frames for stripe impression.
    final isYellow = ((_frameCount >> 1) & 1) == 0;
    int r, g, b;
    if (isYellow) {
      r = ant.carryingFood ? 0xE0 : 0xD0; // pollen = brighter
      g = ant.carryingFood ? 0xD0 : 0xB0;
      b = ant.carryingFood ? 0x40 : 0x20;
    } else {
      r = 0x40;
      g = 0x30;
      b = 0x10;
    }

    final (mr, mg, mb) = _applyEnvironmentAndState(
      r,
      g,
      b,
      ant,
      accentColor,
      _frameCount,
    );

    paint.color = ui.Color.fromARGB(255, mr, mg, mb);
    canvas.drawRect(ui.Rect.fromLTWH(x, y, 1, 1), paint);

    // Wing pixel above body at alpha 50, alternating x position.
    final wingX = x + (((_frameCount + antIndex) & 1) == 0 ? 0.0 : 1.0);
    if (wingX >= 0 && wingX < simulation.gridW && y > 0) {
      paint.color = ui.Color.fromARGB(50, 200, 200, 220);
      canvas.drawRect(ui.Rect.fromLTWH(wingX, y - 1, 1, 1), paint);
    }
  }

  // -------------------------------------------------------------------------
  // FIREFLY RENDERING (Phase 3)
  // -------------------------------------------------------------------------

  void _renderFirefly(
    ui.Canvas canvas,
    ui.Paint paint,
    Ant ant,
    int bodyColor,
    int accentColor,
    int antIndex,
  ) {
    final x = ant.x.toDouble();
    final y = ant.y.toDouble();

    // Dark body pixel.
    int r = (bodyColor >> 16) & 0xFF;
    int g = (bodyColor >> 8) & 0xFF;
    int b = bodyColor & 0xFF;

    final (mr, mg, mb) = _applyEnvironmentAndState(
      r,
      g,
      b,
      ant,
      accentColor,
      _frameCount,
    );

    // Glow phase: unique per individual.
    final glowPhaseOffset = _smoothHash(antIndex, ant.colonyId) & 0xFF;
    final glowVal = _fastSinI((_frameCount * 3 + glowPhaseOffset) & 0xFF);
    // glowVal is in [0, 256]; glow activates when > 192.

    if (!simulation.isNight || glowVal <= 192) {
      // No glow — dark body only.
      paint.color = ui.Color.fromARGB(80, mr, mg, mb);
      canvas.drawRect(ui.Rect.fromLTWH(x, y, 1, 1), paint);
      return;
    }

    // Glowing: bright body.
    final intensity = ((glowVal - 192) * 4).clamp(0, 255); // 0-255
    paint.color = ui.Color.fromARGB(
      255,
      (200 * intensity) >> 8,
      (220 * intensity) >> 8,
      (80 * intensity) >> 8,
    );
    canvas.drawRect(ui.Rect.fromLTWH(x, y, 1, 1), paint);

    // 8 surrounding glow pixels with radial falloff.
    final glowAlpha = (intensity * 120) >> 8;
    paint.color = ui.Color.fromARGB(
      glowAlpha,
      (200 * intensity) >> 8,
      (220 * intensity) >> 8,
      (80 * intensity) >> 8,
    );
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        _drawPixelIfValid(canvas, paint, x + dx, y + dy);
      }
    }
  }

  // -------------------------------------------------------------------------
  // Nest rendering (Phase 5)
  // -------------------------------------------------------------------------

  void _renderNest(
    ui.Canvas canvas,
    ui.Paint paint,
    Colony colony,
    int bodyColor,
  ) {
    final nx = colony.originX.toDouble();
    final ny = colony.originY.toDouble();

    // Nest pulse using _fastSinI instead of sin().
    final pulsePhase = (_frameCount * 3 + colony.id * 47) & 0xFF;
    final pulseVal = _fastSinI(pulsePhase); // [0, 256]
    // Map to [0.7, 1.0] range: 0.7 * 256 = 179, 0.3 * 256 = 77
    final pulse256 = 179 + ((pulseVal * 77) >> 8); // [179, 256]
    final alpha = (150 * pulse256) >> 8;

    // Outer glow (colony health indicator).
    final antCount = colony.ants.length;
    final healthRatio256 = (antCount * 256) ~/ 50; // normalized to 256
    final glowRadius = 2 + ((healthRatio256 * 2) >> 8).clamp(0, 3);

    final br = (bodyColor >> 16) & 0xFF;
    final bg = (bodyColor >> 8) & 0xFF;
    final bb = bodyColor & 0xFF;

    for (var dy = -glowRadius; dy <= glowRadius; dy++) {
      for (var dx = -glowRadius; dx <= glowRadius; dx++) {
        final d2 = dx * dx + dy * dy;
        if (d2 > glowRadius * glowRadius) continue;
        // Integer distance approximation: d2 / (radius^2) as falloff.
        final maxD2 = (glowRadius + 1) * (glowRadius + 1);
        final falloff = alpha * (maxD2 - d2) ~/ maxD2;
        paint.color = ui.Color.fromARGB(falloff.clamp(0, 255), br, bg, bb);
        canvas.drawRect(ui.Rect.fromLTWH(nx + dx, ny + dy, 1, 1), paint);
      }
    }

    // Center bright pixel.
    paint.color = ui.Color.fromARGB(
      (alpha + 50).clamp(0, 255),
      (br + 40).clamp(0, 255),
      (bg + 30).clamp(0, 255),
      (bb + 20).clamp(0, 255),
    );
    canvas.drawRect(ui.Rect.fromLTWH(nx, ny, 1, 1), paint);

    // Food count indicator: pre-computed offsets.
    final foodDots = (colony.foodStored ~/ 10).clamp(0, 8);
    for (var i = 0; i < foodDots; i++) {
      final fx = nx + _foodDotDx[i];
      final fy = ny + _foodDotDy[i];
      paint.color = const ui.Color.fromARGB(120, 200, 180, 80);
      canvas.drawRect(ui.Rect.fromLTWH(fx, fy, 1, 1), paint);
    }

    // Tunnel visualization: scan 5-cell radius, dirt cells with high life
    // values = excavated, render darker.
    for (var dy = -5; dy <= 5; dy++) {
      for (var dx = -5; dx <= 5; dx++) {
        if (dx * dx + dy * dy > 25) continue;
        final tx = colony.originX + dx;
        final ty = colony.originY + dy;
        if (tx < 0 || tx >= simulation.gridW) continue;
        if (ty < 0 || ty >= simulation.gridH) continue;
        final tidx = ty * simulation.gridW + tx;
        if (simulation.grid[tidx] == El.dirt && simulation.life[tidx] > 5) {
          // Excavated dirt: darken it.
          paint.color = const ui.Color.fromARGB(30, 0, 0, 0);
          canvas.drawRect(
            ui.Rect.fromLTWH(tx.toDouble(), ty.toDouble(), 1, 1),
            paint,
          );
        }
      }
    }
  }

  // -------------------------------------------------------------------------
  // Trail rendering (Phase 5)
  // -------------------------------------------------------------------------

  void _renderTrails(ui.Canvas canvas, ui.Paint paint) {
    final toRemove = <int>[];

    for (final entry in _trails.entries) {
      final trail = entry.value;
      var allDead = true;

      for (var i = trail.length - 1; i >= 0; i--) {
        final pt = trail[i];
        pt.age++;
        if (pt.age > _trailFadeFrames) {
          trail.removeAt(i);
          continue;
        }
        allDead = false;

        // Trail color by state.
        final fade = (((_trailFadeFrames - pt.age) * 30) ~/ _trailFadeFrames)
            .clamp(0, 255);
        int tr = pt.colorR;
        int tg = pt.colorG;
        int tb = pt.colorB;

        paint.color = ui.Color.fromARGB(fade, tr, tg, tb);
        canvas.drawRect(
          ui.Rect.fromLTWH(pt.x.toDouble(), pt.y.toDouble(), 1, 1),
          paint,
        );
      }

      if (allDead) toRemove.add(entry.key);
    }

    for (final key in toRemove) {
      _trails.remove(key);
    }
  }

  /// Render colony highways from the trail accumulator.
  void _renderHighways(ui.Canvas canvas, ui.Paint paint, int gridW, int gridH) {
    final acc = _trailAccumulator;
    if (acc == null) return;

    for (var y = 0; y < gridH; y++) {
      final rowBase = y * gridW;
      for (var x = 0; x < gridW; x++) {
        final v = acc[rowBase + x];
        if (v > 10) {
          final alpha = ((v - 10) * 3).clamp(0, 40);
          paint.color = ui.Color.fromARGB(alpha, 30, 20, 10);
          canvas.drawRect(
            ui.Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1),
            paint,
          );
        }
      }
    }
  }

  void _updateTrail(int colonyId, int antIndex, Ant ant) {
    final key = colonyId * 10000 + antIndex;
    final trail = _trails.putIfAbsent(key, () => []);

    // Only add if position changed.
    if (trail.isEmpty || trail.last.x != ant.x || trail.last.y != ant.y) {
      // Determine trail color by ant state.
      int tr, tg, tb;
      if (ant.carryingFood) {
        tr = 200;
        tg = 180;
        tb = 80; // gold
      } else if (ant.isNearNest) {
        tr = 80;
        tg = 100;
        tb = 200; // blue
      } else if (ant.dangerExposureTicks > 0) {
        tr = 200;
        tg = 60;
        tb = 60; // red
      } else {
        tr = 100;
        tg = 90;
        tb = 70; // brown
      }

      trail.add(_TrailPoint(ant.x, ant.y, tr, tg, tb));
      if (trail.length > _maxTrailLength) {
        trail.removeAt(0);
      }

      // Increment trail accumulator for colony highways.
      final acc = _trailAccumulator;
      if (acc != null) {
        final idx = ant.y * simulation.gridW + ant.x;
        if (idx >= 0 && idx < acc.length && acc[idx] < 255) {
          acc[idx]++;
        }
      }
    }
  }

  // -------------------------------------------------------------------------
  // Utility
  // -------------------------------------------------------------------------

  @pragma('vm:prefer-inline')
  void _drawPixelIfValid(ui.Canvas canvas, ui.Paint paint, double x, double y) {
    if (x >= 0 && x < simulation.gridW && y >= 0 && y < simulation.gridH) {
      canvas.drawRect(ui.Rect.fromLTWH(x, y, 1, 1), paint);
    }
  }
}

// ---------------------------------------------------------------------------
// Trail point with state-derived color
// ---------------------------------------------------------------------------

class _TrailPoint {
  _TrailPoint(this.x, this.y, this.colorR, this.colorG, this.colorB);
  final int x;
  final int y;
  final int colorR;
  final int colorG;
  final int colorB;
  int age = 0;
}
