import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

enum HudBadgeMotif {
  orbit,
  pulse,
  streak,
  lattice,
}

class HudIconBadge extends StatefulWidget {
  const HudIconBadge({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.accent = const Color(0xFF74A8F5),
    this.motif = HudBadgeMotif.orbit,
    this.active = false,
    this.size = 44,
    this.iconSize = 20,
    this.padding = const EdgeInsets.all(0),
    this.shape = BoxShape.circle,
    this.borderRadius,
    this.backgroundAlpha = 0.12,
    this.iconColor,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final Color accent;
  final HudBadgeMotif motif;
  final bool active;
  final double size;
  final double iconSize;
  final EdgeInsets padding;
  final BoxShape shape;
  final BorderRadius? borderRadius;
  final double backgroundAlpha;
  final Color? iconColor;

  @override
  State<HudIconBadge> createState() => _HudIconBadgeState();
}

class _HudIconBadgeState extends State<HudIconBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shape = widget.shape;
    final radius = widget.borderRadius ?? BorderRadius.circular(widget.size * 0.28);
    final iconColor = widget.iconColor ??
        (widget.active || _hovered
            ? Colors.white
            : Color.lerp(widget.accent, Colors.white, 0.28)!);

    final badge = AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final phase = _controller.value;
        return MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              width: widget.size,
              height: widget.size,
              padding: widget.padding,
              decoration: BoxDecoration(
                shape: shape,
                borderRadius: shape == BoxShape.circle ? null : radius,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    widget.accent.withValues(
                      alpha: widget.active ? 0.30 : _hovered ? 0.22 : widget.backgroundAlpha,
                    ),
                    const Color(0xFF0C111B).withValues(alpha: 0.92),
                  ],
                ),
                border: Border.all(
                  color: widget.accent.withValues(
                    alpha: widget.active ? 0.44 : _hovered ? 0.30 : 0.18,
                  ),
                  width: widget.active ? 1.1 : 0.8,
                ),
                boxShadow: [
                  BoxShadow(
                    color: widget.accent.withValues(
                      alpha: widget.active ? 0.24 : _hovered ? 0.16 : 0.08,
                    ),
                    blurRadius: widget.active ? 22 : 16,
                    spreadRadius: widget.active ? 1 : 0,
                  ),
                  const BoxShadow(
                    color: Color(0x50000000),
                    blurRadius: 18,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius:
                    shape == BoxShape.circle ? BorderRadius.circular(widget.size) : radius,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CustomPaint(
                      painter: _HudBadgePainter(
                        accent: widget.accent,
                        motif: widget.motif,
                        phase: phase,
                        emphasis: widget.active ? 1.0 : _hovered ? 0.78 : 0.56,
                      ),
                    ),
                    Align(
                      alignment: Alignment.topCenter,
                      child: Container(
                        height: widget.size * 0.34,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withValues(alpha: 0.12),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                    Center(
                      child: Icon(
                        widget.icon,
                        size: widget.iconSize,
                        color: iconColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    if ((widget.tooltip ?? '').isEmpty) return badge;
    return Tooltip(message: widget.tooltip!, child: badge);
  }
}

class _HudBadgePainter extends CustomPainter {
  const _HudBadgePainter({
    required this.accent,
    required this.motif,
    required this.phase,
    required this.emphasis,
  });

  final Color accent;
  final HudBadgeMotif motif;
  final double phase;
  final double emphasis;

  double get _theta => phase * math.pi * 2;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final softGlow = Paint()
      ..shader = RadialGradient(
        colors: [
          accent.withValues(alpha: 0.12 * emphasis),
          Colors.transparent,
        ],
      ).createShader(Rect.fromCircle(center: center, radius: size.width * 0.48));
    canvas.drawCircle(center, size.width * 0.48, softGlow);

    switch (motif) {
      case HudBadgeMotif.orbit:
        final orbitPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.white.withValues(alpha: 0.12 * emphasis);
        canvas.drawOval(
          Rect.fromCenter(
            center: center,
            width: size.width * 0.78,
            height: size.height * 0.42,
          ),
          orbitPaint,
        );
        final point = center +
            Offset(math.cos(_theta) * size.width * 0.29, math.sin(_theta) * size.height * 0.12);
        final dotPaint = Paint()..color = accent.withValues(alpha: 0.60 * emphasis);
        canvas.drawCircle(point, 2.4, dotPaint);
        break;
      case HudBadgeMotif.pulse:
        for (var i = 0; i < 3; i++) {
          final t = ((phase + i * 0.24) % 1.0);
          final radius = lerpDouble(size.width * 0.14, size.width * 0.45, t)!;
          final ring = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = accent.withValues(alpha: (1 - t) * 0.22 * emphasis);
          canvas.drawCircle(center, radius, ring);
        }
        break;
      case HudBadgeMotif.streak:
        final streakPaint = Paint()
          ..color = accent.withValues(alpha: 0.18 * emphasis)
          ..style = PaintingStyle.fill;
        for (var i = 0; i < 4; i++) {
          final offset = ((phase + i * 0.23) % 1.0) * (size.width + 20) - 10;
          final path = Path()
            ..moveTo(offset - 10, size.height * 0.16)
            ..lineTo(offset + 4, size.height * 0.50)
            ..lineTo(offset - 2, size.height * 0.50)
            ..lineTo(offset - 16, size.height * 0.16)
            ..close();
          canvas.drawPath(path, streakPaint);
        }
        break;
      case HudBadgeMotif.lattice:
        final nodePaint = Paint()
          ..color = Colors.white.withValues(alpha: 0.14 * emphasis)
          ..strokeWidth = 1;
        final nodes = <Offset>[
          Offset(size.width * 0.26, size.height * 0.32),
          Offset(size.width * 0.50, size.height * 0.24),
          Offset(size.width * 0.74, size.height * 0.34),
          Offset(size.width * 0.34, size.height * 0.68),
          Offset(size.width * 0.64, size.height * 0.72),
        ];
        for (var i = 0; i < nodes.length - 1; i++) {
          canvas.drawLine(nodes[i], nodes[i + 1], nodePaint);
        }
        for (final node in nodes) {
          canvas.drawCircle(node, 2, Paint()..color = accent.withValues(alpha: 0.36 * emphasis));
        }
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _HudBadgePainter oldDelegate) {
    return oldDelegate.phase != phase ||
        oldDelegate.emphasis != emphasis ||
        oldDelegate.accent != accent ||
        oldDelegate.motif != motif;
  }
}
