import 'dart:ui' as ui;

import 'package:flame/components.dart';

import '../../creatures/creature_registry.dart';

/// Optional overlay that visualizes pheromone trails.
///
/// When enabled, draws semi-transparent colored pixels over the grid:
/// - **Green** = food pheromone (where food was found).
/// - **Blue** = home pheromone (path back to nest).
/// - **Red** = danger pheromone (threats detected).
class PheromoneRenderer extends PositionComponent {
  PheromoneRenderer({required this.registry});

  final CreatureRegistry registry;

  /// Which pheromone channel to visualize (null = all).
  PheromoneChannel? activeChannel;

  /// Whether rendering is enabled.
  bool enabled = false;

  /// Minimum intensity to render (skip very faint signals).
  static const double _minIntensity = 0.01;

  @override
  void render(ui.Canvas canvas) {
    if (!enabled) return;
    super.render(canvas);

    final paint = ui.Paint();

    for (final colony in registry.colonies) {
      final food = colony.foodPheromones;
      final home = colony.homePheromones;
      final danger = colony.dangerPheromones;

      for (var y = 0; y < food.height; y++) {
        for (var x = 0; x < food.width; x++) {
          double fv = 0, hv = 0, dv = 0;

          if (activeChannel == null || activeChannel == PheromoneChannel.food) {
            fv = food.read(x, y);
          }
          if (activeChannel == null || activeChannel == PheromoneChannel.home) {
            hv = home.read(x, y);
          }
          if (activeChannel == null || activeChannel == PheromoneChannel.danger) {
            dv = danger.read(x, y);
          }

          final maxVal = [fv, hv, dv].reduce((a, b) => a > b ? a : b);
          if (maxVal < _minIntensity) continue;

          final r = (dv * 255).round().clamp(0, 255);
          final g = (fv * 255).round().clamp(0, 255);
          final b = (hv * 255).round().clamp(0, 255);
          final a = (maxVal * 180).round().clamp(0, 255);

          paint.color = ui.Color.fromARGB(a, r, g, b);
          canvas.drawRect(
            ui.Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1),
            paint,
          );
        }
      }
    }
  }
}

/// Which pheromone channel to visualize.
enum PheromoneChannel {
  food,
  home,
  danger,
}
