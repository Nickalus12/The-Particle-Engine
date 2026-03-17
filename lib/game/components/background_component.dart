import 'dart:math';
import 'dart:ui';

import 'package:flame/components.dart';

import '../particle_engine_game.dart';

/// Dynamic sky gradient background with day/night cycle and stars.
///
/// Sized much larger than the grid so the background fills the view at any
/// zoom level. The world sits within this sky — no hard edges visible when
/// zoomed out.
class BackgroundComponent extends PositionComponent
    with HasGameReference<ParticleEngineGame> {
  BackgroundComponent({
    required this.gridWidth,
    required this.gridHeight,
    required double cellSize,
  }) : _cellSize = cellSize,
       super(
          // Background extends well beyond the world so contain-fit
          // zoom never shows raw black beyond the edges.
          size: Vector2(
            gridWidth * cellSize * 3,
            gridHeight * cellSize * 3,
          ),
          position: Vector2(
            -gridWidth * cellSize,
            -gridHeight * cellSize,
          ),
        );

  final int gridWidth;
  final int gridHeight;
  final double _cellSize;

  // -- Day sky colours --------------------------------------------------------
  static const Color _dayTop = Color(0xFF87CEEB);
  static const Color _dayBottom = Color(0xFF4A90D9);

  // -- Night sky colours ------------------------------------------------------
  static const Color _nightTop = Color(0xFF0B0D21);
  static const Color _nightBottom = Color(0xFF1A1A3E);

  // -- Ground colours (below the world) ---------------------------------------
  static const Color _dayGround = Color(0xFF3A2A1A);
  static const Color _nightGround = Color(0xFF0D0A07);

  // -- Star cache -------------------------------------------------------------
  late final List<_Star> _stars;

  /// The Y position in local coords where the grid bottom sits.
  late final double _groundY;

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    // _groundY in local coords = world ground position minus our offset.
    _groundY = gridHeight * _cellSize - position.y;
    _generateStars();
  }

  void _generateStars() {
    final rng = Random(42);
    // Stars only in the sky portion (above _groundY).
    _stars = List.generate(120, (_) {
      return _Star(
        x: rng.nextDouble() * size.x,
        y: rng.nextDouble() * _groundY * 0.8,
        radius: 0.5 + rng.nextDouble() * 1.5,
        brightness: 0.4 + rng.nextDouble() * 0.6,
      );
    });
  }

  @override
  void render(Canvas canvas) {
    final t = game.dayNightTransition;

    // Interpolate gradient colours between day and night.
    final topColor = Color.lerp(_dayTop, _nightTop, t)!;
    final bottomColor = Color.lerp(_dayBottom, _nightBottom, t)!;
    final groundColor = Color.lerp(_dayGround, _nightGround, t)!;

    // Draw sky gradient across the full background.
    final skyRect = Rect.fromLTWH(0, 0, size.x, _groundY);
    final skyGradient = Gradient.linear(
      Offset(size.x / 2, 0),
      Offset(size.x / 2, _groundY),
      [topColor, bottomColor],
    );
    canvas.drawRect(skyRect, Paint()..shader = skyGradient);

    // Draw ground below the world with a gradient transition zone.
    // The transition blends from the sky's bottom color into the ground color
    // over a short band so the world doesn't sit on a hard color edge.
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

    // Draw stars (visible during night transition).
    if (t > 0.1) {
      final starAlpha = ((t - 0.1) / 0.9).clamp(0.0, 1.0);
      final starPaint = Paint();
      for (final star in _stars) {
        starPaint.color = Color.fromRGBO(
          255, 255, 255,
          starAlpha * star.brightness,
        );
        canvas.drawCircle(
          Offset(star.x, star.y),
          star.radius,
          starPaint,
        );
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
  });

  final double x;
  final double y;
  final double radius;
  final double brightness;
}
