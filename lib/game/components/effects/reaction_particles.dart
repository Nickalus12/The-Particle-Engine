import 'dart:math';
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/particles.dart';

import '../../../simulation/simulation_engine.dart';

/// Factory for Flame-native particle effects triggered by element reactions.
///
/// Each reaction type has a factory method that returns a
/// [ParticleSystemComponent] positioned at the reaction site. These components
/// are added to the game world and self-remove when their particles expire.
///
/// Uses Flame's built-in particle types:
/// - [AcceleratedParticle] for gravity-affected debris
/// - [MovingParticle] for directional sparks
/// - [ComputedParticle] for custom per-frame rendering (glow, flash)
/// - [CircleParticle] for simple colored dots
class ReactionParticles {
  ReactionParticles._();

  static final Random _rng = Random();

  /// Cell size in logical pixels -- set once during game init to match
  /// the [SandboxComponent.cellSize]. Defaults to 2.0.
  static double cellSize = 2.0;

  /// Convert grid coordinates to world position.
  static Vector2 _gridToWorld(int x, int y) =>
      Vector2(x * cellSize + cellSize / 2, y * cellSize + cellSize / 2);

  // ===========================================================================
  // Water + Fire → Steam wisps
  // ===========================================================================

  /// White wisps rising and fading — water extinguishing fire.
  static ParticleSystemComponent steamWisps(int x, int y) {
    return ParticleSystemComponent(
      position: _gridToWorld(x, y),
      particle: Particle.generate(
        count: 6,
        lifespan: 0.6,
        generator: (i) {
          final dx = (_rng.nextDouble() - 0.5) * 8;
          return AcceleratedParticle(
            speed: Vector2(dx, -15 - _rng.nextDouble() * 10),
            acceleration: Vector2(0, -5),
            child: _fadingCircle(
              radius: 1.5 + _rng.nextDouble(),
              color: Color.fromRGBO(
                220 + _rng.nextInt(35),
                220 + _rng.nextInt(35),
                230 + _rng.nextInt(25),
                0.6,
              ),
              lifespan: 0.6,
            ),
          );
        },
      ),
    );
  }

  // ===========================================================================
  // Lava + Water → Orange sparks + stone chunks
  // ===========================================================================

  /// Hot orange sparks and stone-colored debris — lava cooling.
  static ParticleSystemComponent lavaCoolingSparks(int x, int y) {
    return ParticleSystemComponent(
      position: _gridToWorld(x, y),
      particle: Particle.generate(
        count: 10,
        lifespan: 0.8,
        generator: (i) {
          final angle = _rng.nextDouble() * 2 * pi;
          final speed = 10 + _rng.nextDouble() * 20;
          final isStone = i > 6;

          final color = isStone
              ? Color.fromRGBO(
                  120 + _rng.nextInt(40),
                  120 + _rng.nextInt(40),
                  120 + _rng.nextInt(40),
                  0.9,
                )
              : Color.fromRGBO(
                  255,
                  100 + _rng.nextInt(120),
                  _rng.nextInt(60),
                  0.9,
                );

          return AcceleratedParticle(
            speed: Vector2(cos(angle) * speed, sin(angle) * speed),
            acceleration: Vector2(0, 30), // Gravity pulls debris down.
            child: _fadingCircle(
              radius: isStone ? 2.0 : 1.0 + _rng.nextDouble(),
              color: color,
              lifespan: 0.8,
            ),
          );
        },
      ),
    );
  }

  // ===========================================================================
  // TNT Explosion → Radial debris burst
  // ===========================================================================

  /// Radial hot debris burst — TNT detonation.
  static ParticleSystemComponent explosionBurst(int x, int y, int radius) {
    final count = (radius * 4).clamp(8, 40);
    final lifespan = 0.5 + radius * 0.05;

    return ParticleSystemComponent(
      position: _gridToWorld(x, y),
      particle: Particle.generate(
        count: count,
        lifespan: lifespan,
        generator: (i) {
          final angle = _rng.nextDouble() * 2 * pi;
          final speed = radius * 3.0 + _rng.nextDouble() * radius * 5;
          final t = _rng.nextDouble();

          // Hot white core → orange → dark red at edges.
          final color = t < 0.3
              ? Color.fromRGBO(255, 240 + _rng.nextInt(15), 200, 1.0)
              : t < 0.7
                  ? Color.fromRGBO(255, 120 + _rng.nextInt(80), _rng.nextInt(40), 0.9)
                  : Color.fromRGBO(180 + _rng.nextInt(75), _rng.nextInt(60), 0, 0.8);

          return AcceleratedParticle(
            speed: Vector2(cos(angle) * speed, sin(angle) * speed),
            acceleration: Vector2(0, 20),
            child: _fadingCircle(
              radius: 1.0 + _rng.nextDouble() * 2,
              color: color,
              lifespan: lifespan,
            ),
          );
        },
      ),
    );
  }

  // ===========================================================================
  // Lightning Strike → Flash + electric sparks
  // ===========================================================================

  /// Bright electric sparks radiating outward — lightning impact.
  static ParticleSystemComponent lightningSparks(int x, int y) {
    return ParticleSystemComponent(
      position: _gridToWorld(x, y),
      particle: Particle.generate(
        count: 12,
        lifespan: 0.3,
        generator: (i) {
          final angle = _rng.nextDouble() * 2 * pi;
          final speed = 20 + _rng.nextDouble() * 30;

          return AcceleratedParticle(
            speed: Vector2(cos(angle) * speed, sin(angle) * speed),
            acceleration: Vector2(
              (_rng.nextDouble() - 0.5) * 40,
              (_rng.nextDouble() - 0.5) * 40,
            ),
            child: _fadingCircle(
              radius: 0.8 + _rng.nextDouble() * 0.8,
              color: Color.fromRGBO(
                255,
                255,
                100 + _rng.nextInt(155),
                1.0,
              ),
              lifespan: 0.3,
            ),
          );
        },
      ),
    );
  }

  // ===========================================================================
  // Acid Dissolving → Green bubbles rising
  // ===========================================================================

  /// Green bubbles floating upward — acid dissolving material.
  static ParticleSystemComponent acidBubbles(int x, int y) {
    return ParticleSystemComponent(
      position: _gridToWorld(x, y),
      particle: Particle.generate(
        count: 5,
        lifespan: 0.5,
        generator: (i) {
          final dx = (_rng.nextDouble() - 0.5) * 6;
          return AcceleratedParticle(
            speed: Vector2(dx, -8 - _rng.nextDouble() * 8),
            acceleration: Vector2(0, -3),
            child: _fadingCircle(
              radius: 1.0 + _rng.nextDouble() * 1.5,
              color: Color.fromRGBO(
                30 + _rng.nextInt(40),
                200 + _rng.nextInt(55),
                30 + _rng.nextInt(40),
                0.7,
              ),
              lifespan: 0.5,
            ),
          );
        },
      ),
    );
  }

  // ===========================================================================
  // Sand + Lightning → Glass formation flash
  // ===========================================================================

  /// White-blue flash and sparkle — sand fusing to glass.
  static ParticleSystemComponent glassFormationFlash(int x, int y) {
    return ParticleSystemComponent(
      position: _gridToWorld(x, y),
      particle: Particle.generate(
        count: 8,
        lifespan: 0.25,
        generator: (i) {
          final angle = _rng.nextDouble() * 2 * pi;
          final speed = 5 + _rng.nextDouble() * 15;
          return MovingParticle(
            from: Vector2.zero(),
            to: Vector2(cos(angle) * speed * 0.25, sin(angle) * speed * 0.25),
            child: _fadingCircle(
              radius: 0.8 + _rng.nextDouble(),
              color: Color.fromRGBO(
                200 + _rng.nextInt(55),
                220 + _rng.nextInt(35),
                255,
                1.0,
              ),
              lifespan: 0.25,
            ),
          );
        },
      ),
    );
  }

  // ===========================================================================
  // Fire Spreading → Orange ember particles
  // ===========================================================================

  /// Floating ember particles — fire catching on flammable material.
  static ParticleSystemComponent fireEmbers(int x, int y) {
    return ParticleSystemComponent(
      position: _gridToWorld(x, y),
      particle: Particle.generate(
        count: 4,
        lifespan: 0.5,
        generator: (i) {
          return AcceleratedParticle(
            speed: Vector2(
              (_rng.nextDouble() - 0.5) * 10,
              -5 - _rng.nextDouble() * 10,
            ),
            acceleration: Vector2(0, -3),
            child: _fadingCircle(
              radius: 0.8 + _rng.nextDouble() * 0.8,
              color: Color.fromRGBO(
                255,
                120 + _rng.nextInt(100),
                _rng.nextInt(60),
                0.8,
              ),
              lifespan: 0.5,
            ),
          );
        },
      ),
    );
  }

  // ===========================================================================
  // Plant Growing → Green sparkle pops
  // ===========================================================================

  /// Small green sparkles — plant growth event.
  static ParticleSystemComponent plantGrowthSparkle(int x, int y) {
    return ParticleSystemComponent(
      position: _gridToWorld(x, y),
      particle: Particle.generate(
        count: 3,
        lifespan: 0.4,
        generator: (i) {
          return AcceleratedParticle(
            speed: Vector2(
              (_rng.nextDouble() - 0.5) * 8,
              -3 - _rng.nextDouble() * 6,
            ),
            acceleration: Vector2(0, 5),
            child: _fadingCircle(
              radius: 0.6 + _rng.nextDouble() * 0.6,
              color: Color.fromRGBO(
                50 + _rng.nextInt(40),
                180 + _rng.nextInt(75),
                50 + _rng.nextInt(40),
                0.7,
              ),
              lifespan: 0.4,
            ),
          );
        },
      ),
    );
  }

  // ===========================================================================
  // Generic reaction flash (for queued reactionFlashes from the engine)
  // ===========================================================================

  /// Generic colored particle burst from a [SimulationEngine.reactionFlashes]
  /// queue entry: [x, y, r, g, b, count].
  static ParticleSystemComponent fromFlashData(
    int x,
    int y,
    int r,
    int g,
    int b,
    int count,
  ) {
    return ParticleSystemComponent(
      position: _gridToWorld(x, y),
      particle: Particle.generate(
        count: count.clamp(1, 10),
        lifespan: 0.35,
        generator: (i) {
          final dx = (_rng.nextDouble() - 0.5) * 10;
          final dy = -(2 + _rng.nextDouble() * 8);
          return AcceleratedParticle(
            speed: Vector2(dx, dy),
            acceleration: Vector2(0, 5),
            child: _fadingCircle(
              radius: 1.0 + _rng.nextDouble(),
              color: Color.fromRGBO(r, g, b, 0.8),
              lifespan: 0.35,
            ),
          );
        },
      ),
    );
  }

  // ===========================================================================
  // Helper: fading circle particle
  // ===========================================================================

  /// A [ComputedParticle] that draws a circle which fades over its lifespan.
  static ComputedParticle _fadingCircle({
    required double radius,
    required Color color,
    required double lifespan,
  }) {
    return ComputedParticle(
      lifespan: lifespan,
      renderer: (canvas, particle) {
        final alpha = (1.0 - particle.progress) * (color.a / 255.0);
        final paint = Paint()
          ..color = color.withValues(alpha: alpha);
        canvas.drawCircle(Offset.zero, radius * (1.0 - particle.progress * 0.3), paint);
      },
    );
  }
}
