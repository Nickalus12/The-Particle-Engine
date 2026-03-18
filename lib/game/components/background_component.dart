import 'dart:math';
import 'dart:ui';

import 'package:flame/components.dart';

import '../particle_engine_game.dart';

/// Dynamic sky gradient background with day/night cycle, twinkling stars,
/// and atmospheric horizon glow.
///
/// Sized to match the grid so the background fills the view at any zoom level.
/// The world sits within this sky -- no hard edges visible when zoomed out.
class BackgroundComponent extends PositionComponent
    with HasGameReference<ParticleEngineGame> {
  BackgroundComponent({
    required this.gridWidth,
    required this.gridHeight,
    required double cellSize,
  }) : _cellSize = cellSize,
       super(
          size: Vector2(
            gridWidth * cellSize,
            gridHeight * cellSize,
          ),
          position: Vector2.zero(),
        );

  final int gridWidth;
  final int gridHeight;
  final double _cellSize;

  // -- Day sky colours (richer azure gradient) --------------------------------
  static const Color _dayTop = Color(0xFF6BB8E8);
  static const Color _dayMid = Color(0xFF5AA0D8);
  static const Color _dayBottom = Color(0xFF4888C8);
  static const Color _dayHorizon = Color(0xFFE8D8C0); // warm horizon haze

  // -- Night sky colours ------------------------------------------------------
  static const Color _nightTop = Color(0xFF060818);
  static const Color _nightMid = Color(0xFF0C1028);
  static const Color _nightBottom = Color(0xFF141838);
  static const Color _nightHorizon = Color(0xFF1A1830); // dark purple horizon

  // -- Ground colours (below the world) ---------------------------------------
  static const Color _dayGround = Color(0xFF3A2A1A);
  static const Color _nightGround = Color(0xFF0D0A07);

  // -- Star cache -------------------------------------------------------------
  late final List<_Star> _stars;

  /// The Y position in local coords where the grid bottom sits.
  late final double _groundY;

  /// Elapsed time for star twinkling.
  double _elapsed = 0.0;

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    _groundY = gridHeight * _cellSize;
    _generateStars();
  }

  void _generateStars() {
    final rng = Random(42);
    // Stars only in the sky portion (above _groundY).
    _stars = List.generate(180, (_) {
      return _Star(
        x: rng.nextDouble() * size.x,
        y: rng.nextDouble() * _groundY * 0.85,
        radius: 0.4 + rng.nextDouble() * 1.2,
        brightness: 0.3 + rng.nextDouble() * 0.7,
        twinkleSpeed: 0.8 + rng.nextDouble() * 2.5,
        twinklePhase: rng.nextDouble() * 6.283,
        // A few bright "feature" stars
        isBright: rng.nextInt(12) == 0,
      );
    });
  }

  @override
  void update(double dt) {
    super.update(dt);
    _elapsed += dt;
  }

  @override
  void render(Canvas canvas) {
    final t = game.dayNightTransition;

    // Interpolate gradient colours between day and night.
    final topColor = Color.lerp(_dayTop, _nightTop, t)!;
    final midColor = Color.lerp(_dayMid, _nightMid, t)!;
    final bottomColor = Color.lerp(_dayBottom, _nightBottom, t)!;
    final horizonColor = Color.lerp(_dayHorizon, _nightHorizon, t)!;
    final groundColor = Color.lerp(_dayGround, _nightGround, t)!;

    // Draw sky gradient -- three-stop for richer depth
    final skyRect = Rect.fromLTWH(0, 0, size.x, _groundY);
    final skyGradient = Gradient.linear(
      Offset(size.x / 2, 0),
      Offset(size.x / 2, _groundY),
      [topColor, midColor, bottomColor],
      [0.0, 0.55, 1.0],
    );
    canvas.drawRect(skyRect, Paint()..shader = skyGradient);

    // Atmospheric horizon glow band near the bottom of the sky
    // Creates a warm haze effect at the horizon line
    final horizonHeight = _groundY * 0.12;
    final horizonRect = Rect.fromLTWH(
      0, _groundY - horizonHeight, size.x, horizonHeight,
    );
    final horizonGradient = Gradient.linear(
      Offset(size.x / 2, _groundY - horizonHeight),
      Offset(size.x / 2, _groundY),
      [
        horizonColor.withValues(alpha: 0.0),
        horizonColor.withValues(alpha: 0.15 + t * 0.05),
      ],
    );
    canvas.drawRect(horizonRect, Paint()..shader = horizonGradient);

    // Draw ground below the world with a smooth gradient transition zone.
    final transitionHeight = gridHeight * _cellSize * 0.15;
    final transitionRect = Rect.fromLTWH(
      0, _groundY, size.x, transitionHeight,
    );
    final transitionGradient = Gradient.linear(
      Offset(size.x / 2, _groundY),
      Offset(size.x / 2, _groundY + transitionHeight),
      [bottomColor, groundColor],
    );
    canvas.drawRect(transitionRect, Paint()..shader = transitionGradient);

    // Solid ground fill below the transition.
    final solidGroundRect = Rect.fromLTWH(
      0, _groundY + transitionHeight,
      size.x, size.y - _groundY - transitionHeight,
    );
    canvas.drawRect(solidGroundRect, Paint()..color = groundColor);

    // Draw twinkling stars (visible during night transition).
    if (t > 0.1) {
      final starAlpha = ((t - 0.1) / 0.9).clamp(0.0, 1.0);
      final starPaint = Paint();
      for (final star in _stars) {
        // Per-star sinusoidal brightness oscillation for twinkling
        final twinkle = 0.55 + 0.45 *
            sin(_elapsed * star.twinkleSpeed + star.twinklePhase);
        final effectiveBrightness = star.brightness * twinkle;

        starPaint.color = Color.fromRGBO(
          255, 255, star.isBright ? 240 : 255,
          starAlpha * effectiveBrightness,
        );
        canvas.drawCircle(
          Offset(star.x, star.y),
          star.radius,
          starPaint,
        );

        // Bright stars get a subtle soft glow halo
        if (star.isBright && effectiveBrightness > 0.6) {
          starPaint.color = Color.fromRGBO(
            220, 230, 255,
            starAlpha * effectiveBrightness * 0.15,
          );
          starPaint.maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0);
          canvas.drawCircle(
            Offset(star.x, star.y),
            star.radius * 3.0,
            starPaint,
          );
          starPaint.maskFilter = null;
        }
      }
    }
  }
}

class _Star {
  const _Star({
    required this.x,
    required this.y,
    required this.radius,
    required this.brightness,
    required this.twinkleSpeed,
    required this.twinklePhase,
    this.isBright = false,
  });

  final double x;
  final double y;
  final double radius;
  final double brightness;
  final double twinkleSpeed;
  final double twinklePhase;
  final bool isBright;
}
