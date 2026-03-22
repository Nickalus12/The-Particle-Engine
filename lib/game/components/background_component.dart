import 'dart:ui';

import 'package:flame/components.dart';

import '../particle_engine_game.dart';

/// Background component that renders the ground area visible when zoomed out
/// past grid bounds. Sky rendering is handled by the pixel buffer in
/// PixelRenderer.
///
/// Sized much larger than the grid so Flame never culls it — the sky/ground
/// fill must be visible at every zoom level to prevent black bars.
class BackgroundComponent extends PositionComponent
    with HasGameReference<ParticleEngineGame> {
  BackgroundComponent({
    required this.gridWidth,
    required this.gridHeight,
    required double cellSize,
  }) : _cellSize = cellSize,
       super(
          // Position the component so its origin is far above-left of the grid,
          // giving a huge margin that the camera can never escape.
          size: Vector2(
            gridWidth * cellSize + _margin * 2,
            gridHeight * cellSize + _margin * 2,
          ),
          position: Vector2(-_margin, -_margin),
        );

  /// Extra margin around the grid in each direction. At max zoom-out (1.0x)
  /// the viewport is exactly gridWidth*cellSize wide, so even a small margin
  /// suffices — but we use a generous value to be safe with any future zoom
  /// range or aspect-ratio letterboxing.
  static const double _margin = 10000.0;

  final int gridWidth;
  final int gridHeight;
  final double _cellSize;

  // -- Day/night sky bottom colours (for ground transition) -----------------
  static const Color _dayBottom = Color(0xFF4888C8);
  static const Color _nightBottom = Color(0xFF141838);

  // -- Ground colours (below the world) -------------------------------------
  static const Color _dayGround = Color(0xFF3A2A1A);
  static const Color _nightGround = Color(0xFF0D0A07);

  /// The Y position in local coords where the grid bottom sits.
  late final double _groundY;

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    _groundY = gridHeight * _cellSize;
  }

  @override
  void render(Canvas canvas) {
    final t = game.dayNightTransition;

    final skyColor = Color.lerp(_dayBottom, _nightBottom, t)!;
    final groundColor = Color.lerp(_dayGround, _nightGround, t)!;

    // Fill the entire component rect with sky colour.  Because the
    // component is positioned at (-_margin, -_margin) and sized with
    // _margin on each side, this covers everything the camera can see.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.x, size.y),
      Paint()..color = skyColor,
    );

    // _groundY is relative to the grid origin, but we are offset by
    // -_margin, so translate it into our local coords.
    final localGroundY = _groundY + _margin;

    // Draw ground below the world with a smooth gradient transition zone.
    final transitionHeight = gridHeight * _cellSize * 0.15;
    final transitionRect = Rect.fromLTWH(
      0, localGroundY, size.x, transitionHeight,
    );
    final transitionGradient = Gradient.linear(
      Offset(size.x / 2, localGroundY),
      Offset(size.x / 2, localGroundY + transitionHeight),
      [skyColor, groundColor],
    );
    canvas.drawRect(transitionRect, Paint()..shader = transitionGradient);

    // Solid ground fill below the transition to the bottom of the component.
    final solidGroundTop = localGroundY + transitionHeight;
    final solidGroundRect = Rect.fromLTWH(
      0, solidGroundTop,
      size.x, size.y - solidGroundTop,
    );
    canvas.drawRect(solidGroundRect, Paint()..color = groundColor);
  }
}
