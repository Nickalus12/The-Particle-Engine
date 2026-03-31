import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../simulation/element_registry.dart';
import '../../simulation/simulation_engine.dart';
import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import 'hud_icon_badge.dart';

/// Small corner minimap showing the full world when zoomed in.
///
/// Highlights the current viewport area with a bright rectangle. Tap to
/// jump to a location. Semi-transparent and unobtrusive. Only visible
/// when the zoom level exceeds 1.5x.
class MiniMap extends StatefulWidget {
  const MiniMap({
    super.key,
    required this.simulation,
    this.viewportRect,
    this.onTapLocation,
    this.isVisible = true,
  });

  final SimulationEngine simulation;

  /// The current viewport in grid coordinates (null if full view).
  final Rect? viewportRect;

  /// Called when the user taps a location on the minimap.
  final void Function(double gridX, double gridY)? onTapLocation;

  /// Whether the minimap should be visible.
  final bool isVisible;

  static const double displayWidth = 100;

  /// Compute display height based on the simulation's aspect ratio.
  double get displayHeight =>
      displayWidth * simulation.gridH / simulation.gridW;

  @override
  State<MiniMap> createState() => _MiniMapState();
}

class _MiniMapState extends State<MiniMap>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeController;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: ParticleTheme.normalDuration,
      value: widget.isVisible ? 1.0 : 0.0,
    );
  }

  @override
  void didUpdateWidget(MiniMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isVisible != oldWidget.isVisible) {
      if (widget.isVisible) {
        _fadeController.forward();
      } else {
        _fadeController.reverse();
      }
    }
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  void _handleTap(TapDownDetails details) {
    if (widget.onTapLocation == null) return;
    final local = details.localPosition;
    final gridX =
        local.dx / MiniMap.displayWidth * widget.simulation.gridW;
    final gridY =
        local.dy / widget.displayHeight * widget.simulation.gridH;
    widget.onTapLocation!(gridX, gridY);
  }

  @override
  Widget build(BuildContext context) {
    final mapHeight = widget.displayHeight;
    final accent = widget.viewportRect != null
        ? AppColors.categoryEnergy
        : AppColors.primary;
    return FadeTransition(
      opacity: _fadeController,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 150),
          child: ParticleTheme.atmosphericPanel(
            accent: accent,
            borderRadius: ParticleTheme.radiusMedium,
            blurAmount: 18,
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
            child: SizedBox(
              width: MiniMap.displayWidth + 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IgnorePointer(
                        child: HudIconBadge(
                          icon: Icons.map_rounded,
                          onTap: () {},
                          accent: accent,
                          motif: HudBadgeMotif.lattice,
                          size: 28,
                          iconSize: 14,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'World View',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ),
                      Text(
                        '${widget.simulation.gridW}×${widget.simulation.gridH}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppColors.textDim,
                              fontSize: 10,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTapDown: _handleTap,
                    child: ClipRRect(
                      borderRadius:
                          BorderRadius.circular(ParticleTheme.radiusSmall),
                      child: SizedBox(
                        width: MiniMap.displayWidth,
                        height: mapHeight,
                        child: CustomPaint(
                          size: Size(MiniMap.displayWidth, mapHeight),
                          painter: _MiniMapPainter(
                            widget.simulation.grid,
                            widget.simulation.gridW,
                            widget.simulation.gridH,
                            widget.viewportRect,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniMapPainter extends CustomPainter {
  _MiniMapPainter(this.grid, this.gridW, this.gridH, this.viewportRect);

  final Uint8List grid;
  final int gridW;
  final int gridH;
  final Rect? viewportRect;

  @override
  void paint(ui.Canvas canvas, Size size) {
    final scaleX = size.width / gridW;
    final scaleY = size.height / gridH;
    final paint = Paint();

    // Draw elements (sample every 2 cells for performance).
    for (var y = 0; y < gridH; y += 2) {
      for (var x = 0; x < gridW; x += 2) {
        final elType = grid[y * gridW + x];
        if (elType == El.empty) continue;
        final colorInt = elType < baseColors.length
            ? baseColors[elType]
            : 0xFFFFFFFF;
        paint.color = Color(colorInt);
        canvas.drawRect(
          Rect.fromLTWH(
            x * scaleX,
            y * scaleY,
            scaleX * 2,
            scaleY * 2,
          ),
          paint,
        );
      }
    }

    // Draw viewport indicator.
    if (viewportRect != null) {
      final vpRect = Rect.fromLTWH(
        viewportRect!.left * scaleX,
        viewportRect!.top * scaleY,
        viewportRect!.width * scaleX,
        viewportRect!.height * scaleY,
      );
      final borderPaint = Paint()
        ..color = AppColors.primary.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawRect(vpRect, borderPaint);

      final fillPaint = Paint()
        ..color = AppColors.primary.withValues(alpha: 0.1)
        ..style = PaintingStyle.fill;
      canvas.drawRect(vpRect, fillPaint);
    }

    final framePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(Offset.zero & size, framePaint);
  }

  @override
  bool shouldRepaint(covariant _MiniMapPainter old) => true;
}
