import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/effects.dart';
import 'package:flame/particles.dart';

import '../simulation/element_registry.dart';

/// Visual feedback at the point of touch — a brief expanding ring that fades.
///
/// Uses Flame's [ParticleSystemComponent] with [ComputedParticle] for the
/// ripple effect, keeping everything within Flame's particle system rather
/// than hand-coding animation loops.
class TouchRippleEffect {
  TouchRippleEffect._();

  static const double _duration = 0.3;
  static const double _maxRadius = 20.0;

  /// Create a ripple [ParticleSystemComponent] at the given position.
  ///
  /// The ripple expands and fades over [_duration] seconds, colored to match
  /// the selected element.
  static ParticleSystemComponent create({
    required Vector2 position,
    Color? color,
  }) {
    final baseColor = color ?? const Color(0xFFFFFFFF);

    return ParticleSystemComponent(
      position: position,
      particle: ComputedParticle(
        lifespan: _duration,
        renderer: (canvas, particle) {
          final t = particle.progress;
          final radius = _maxRadius * t;
          final alpha = (1.0 - t) * 0.4;
          final paint = Paint()
            ..color = baseColor.withValues(alpha: alpha)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5;
          canvas.drawCircle(Offset.zero, radius, paint);
        },
      ),
    );
  }

  /// Create a ripple effect coloured to match the given element type (int).
  static ParticleSystemComponent forElement({
    required Vector2 position,
    required int element,
  }) {
    final color = element == El.empty || element >= baseColors.length
        ? null
        : Color(baseColors[element]);
    return create(position: position, color: color);
  }
}

/// A Flame component that pulses (scales up/down) briefly at a touch point,
/// using Flame's built-in [ScaleEffect] and [OpacityEffect].
///
/// Use this as an alternative to the particle-based ripple for a more
/// prominent visual indicator.
class TouchPulseEffect extends CircleComponent {
  TouchPulseEffect({
    required Vector2 center,
    Color? color,
  }) : super(
          position: center,
          radius: 8,
          anchor: Anchor.center,
          paint: Paint()
            ..color = (color ?? const Color(0xFFFFFFFF)).withValues(alpha: 0.4)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    add(
      SequenceEffect([
        ScaleEffect.by(
          Vector2.all(2.5),
          EffectController(duration: 0.2),
        ),
        OpacityEffect.to(
          0,
          EffectController(duration: 0.1),
        ),
        RemoveEffect(),
      ]),
    );
  }
}
