import 'dart:math';

import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/effects.dart';
import 'package:flutter/animation.dart';

/// Screen-level effects using Flame's built-in Effects system.
///
/// - [ScreenShake]: Rapid random offset on the camera viewfinder via MoveEffect.
/// - [LightningFlash]: Brief white overlay with Flame OpacityEffect.
/// - [ExplosionBump]: Directional camera kick and return via SequenceEffect.
class ScreenShake {
  ScreenShake._();

  /// Apply a screen-shake to the [viewfinder] by chaining random MoveEffects.
  ///
  /// [intensity] controls the max pixel offset per shake step.
  /// [duration] is the total shake time in seconds.
  static void apply(
    Viewfinder viewfinder, {
    double intensity = 3.0,
    double duration = 0.3,
  }) {
    final rng = Random();
    final steps = (duration / 0.03).ceil(); // ~30fps shake
    final stepDuration = duration / steps;
    final origin = viewfinder.position.clone();

    final effects = <Effect>[];
    for (var i = 0; i < steps; i++) {
      final offset = Vector2(
        (rng.nextDouble() - 0.5) * 2 * intensity,
        (rng.nextDouble() - 0.5) * 2 * intensity,
      );
      effects.add(
        MoveEffect.to(
          origin + offset,
          EffectController(duration: stepDuration),
        ),
      );
    }
    // Return to origin.
    effects.add(
      MoveEffect.to(
        origin,
        EffectController(duration: stepDuration, curve: Curves.easeOut),
      ),
    );

    viewfinder.add(
      SequenceEffect(effects.cast<Effect>()),
    );
  }
}

/// Brief white flash overlay using Flame's OpacityEffect.
///
/// Added as a child of the camera viewport so it covers the screen.
class LightningFlash extends RectangleComponent with HasVisibility {
  LightningFlash({required Vector2 screenSize})
      : super(
          size: screenSize,
          priority: 1000,
        ) {
    paint.color = const Color(0xFFFFFFFF);
    opacity = 0.7;
  }

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    add(
      OpacityEffect.fadeOut(
        EffectController(duration: 0.15, curve: Curves.easeOut),
        onComplete: removeFromParent,
      ),
    );
  }
}

/// Directional camera bump for explosions — kicks the viewfinder away from
/// the blast and smoothly returns.
class ExplosionBump {
  ExplosionBump._();

  /// Bump the [viewfinder] away from ([blastX], [blastY]) in world coords.
  ///
  /// The direction is from the blast toward the current camera center.
  /// [strength] scales the pixel displacement.
  static void apply(
    Viewfinder viewfinder, {
    required double blastX,
    required double blastY,
    double strength = 4.0,
  }) {
    final origin = viewfinder.position.clone();
    final dir = origin - Vector2(blastX, blastY);
    if (dir.length2 < 0.01) {
      dir.setValues(0, -1); // Default upward if blast is on camera center.
    }
    dir.normalize();

    final kickTarget = origin + dir * strength;

    viewfinder.add(
      SequenceEffect([
        MoveEffect.to(
          kickTarget,
          EffectController(duration: 0.06, curve: Curves.easeOut),
        ),
        MoveEffect.to(
          origin,
          EffectController(duration: 0.2, curve: Curves.elasticOut),
        ),
      ]),
    );
  }
}
