import 'dart:ui' as ui;

import 'package:flame/components.dart';

import '../../creatures/creature_registry.dart';

/// Renders all living ants as colored pixels on the simulation canvas.
///
/// Each colony gets a unique color. Ants carrying food get a brighter variant.
/// This component draws on top of the sandbox so ants appear above terrain.
class AntRenderer extends PositionComponent {
  AntRenderer({required this.registry});

  final CreatureRegistry registry;

  /// Colony colors — each colony gets a distinct tint.
  static const List<ui.Color> _colonyColors = [
    ui.Color(0xFFFF4444), // Red.
    ui.Color(0xFF4444FF), // Blue.
    ui.Color(0xFF44FF44), // Green.
    ui.Color(0xFFFFFF44), // Yellow.
    ui.Color(0xFFFF44FF), // Magenta.
    ui.Color(0xFF44FFFF), // Cyan.
    ui.Color(0xFFFF8800), // Orange.
    ui.Color(0xFF8844FF), // Purple.
  ];

  /// Brighter variant for ants carrying food.
  static const List<ui.Color> _carryingColors = [
    ui.Color(0xFFFFAAAA),
    ui.Color(0xFFAAAAFF),
    ui.Color(0xFFAAFFAA),
    ui.Color(0xFFFFFFAA),
    ui.Color(0xFFFFAAFF),
    ui.Color(0xFFAAFFFF),
    ui.Color(0xFFFFCC66),
    ui.Color(0xFFBB88FF),
  ];

  @override
  void render(ui.Canvas canvas) {
    super.render(canvas);

    final paint = ui.Paint();

    for (final colony in registry.colonies) {
      final colorIdx = colony.id % _colonyColors.length;
      final baseColor = _colonyColors[colorIdx];
      final carryColor = _carryingColors[colorIdx];

      for (final ant in colony.ants) {
        if (!ant.alive) continue;

        paint.color = ant.carryingFood ? carryColor : baseColor;

        // Draw ant as a single pixel.
        canvas.drawRect(
          ui.Rect.fromLTWH(
            ant.x.toDouble(),
            ant.y.toDouble(),
            1,
            1,
          ),
          paint,
        );
      }

      // Draw nest entrance as a slightly larger marker.
      paint.color = baseColor.withValues(alpha: 0.6);
      canvas.drawRect(
        ui.Rect.fromLTWH(
          (colony.originX - 1).toDouble(),
          (colony.originY - 1).toDouble(),
          3,
          3,
        ),
        paint,
      );
    }
  }
}
