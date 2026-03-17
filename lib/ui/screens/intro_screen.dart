import 'dart:math';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/particles.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';
import 'home_screen.dart';

/// Cinematic intro sequence that plays on first launch.
///
/// Uses a dedicated [FlameGame] with [ParticleSystemComponent] effects for
/// a choreographed physics showcase: sand falling, water flowing, fire
/// erupting, lava meeting water with steam. The title fades in via Flutter
/// overlays on top of the Flame canvas.
///
/// Tap anywhere or wait for auto-advance to proceed to [HomeScreen].
/// Stores a "has_seen_intro" flag so it only plays once.
class IntroScreen extends StatefulWidget {
  const IntroScreen({super.key});

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen>
    with TickerProviderStateMixin {
  static const String _hasSeenIntroKey = 'has_seen_intro';
  static const Duration _totalDuration = Duration(milliseconds: 7000);

  late final _IntroGame _game;
  late final AnimationController _masterController;

  // Flutter-driven fade animations for text overlays.
  late final Animation<double> _titleFade;
  late final Animation<double> _subtitleFade;
  late final Animation<double> _skipHintFade;

  bool _navigating = false;

  @override
  void initState() {
    super.initState();

    _game = _IntroGame();

    _masterController = AnimationController(
      vsync: this,
      duration: _totalDuration,
    );

    _titleFade = CurvedAnimation(
      parent: _masterController,
      curve: const Interval(0.55, 0.85, curve: Curves.easeOut),
    );
    _subtitleFade = CurvedAnimation(
      parent: _masterController,
      curve: const Interval(0.70, 0.95, curve: Curves.easeOut),
    );
    _skipHintFade = CurvedAnimation(
      parent: _masterController,
      curve: const Interval(0.15, 0.30, curve: Curves.easeOut),
    );

    _masterController.forward();
    _masterController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _advance();
      }
    });
  }

  @override
  void dispose() {
    _masterController.dispose();
    super.dispose();
  }

  Future<void> _advance() async {
    if (_navigating) return;
    _navigating = true;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hasSeenIntroKey, true);

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, _, _) => const HomeScreen(),
        transitionsBuilder: (context, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: ParticleTheme.slowDuration,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _advance,
      behavior: HitTestBehavior.opaque,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Stack(
          children: [
            // Flame game canvas with particle effects.
            Positioned.fill(
              child: GameWidget(game: _game),
            ),

            // Vignette overlay for cinematic feel.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.center,
                      radius: 1.2,
                      colors: [
                        Colors.transparent,
                        const Color(0xFF0A0A0F).withValues(alpha: 0.6),
                      ],
                      stops: const [0.5, 1.0],
                    ),
                  ),
                ),
              ),
            ),

            // Title overlay.
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FadeTransition(
                    opacity: _titleFade,
                    child: ShaderMask(
                      shaderCallback: (bounds) => const LinearGradient(
                        colors: [AppColors.primary, AppColors.accent],
                      ).createShader(bounds),
                      child: Text(
                        'THE PARTICLE ENGINE',
                        style: AppTypography.title.copyWith(
                          fontSize: 40,
                          color: Colors.white,
                          letterSpacing: 3.0,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FadeTransition(
                    opacity: _subtitleFade,
                    child: Text(
                      'Elements, creatures & ecosystems',
                      style: AppTypography.body.copyWith(
                        color: AppColors.textDim,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Skip hint.
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: FadeTransition(
                opacity: _skipHintFade,
                child: Center(
                  child: Text(
                    'Tap to skip',
                    style: AppTypography.caption.copyWith(
                      color: AppColors.textDim.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Flame game for cinematic particle effects
// =============================================================================

/// Lightweight [FlameGame] that runs choreographed Flame particle effects.
///
/// Spawns [ParticleSystemComponent] instances on a timed schedule to showcase
/// sand, water, fire, lava, and steam physics. Uses Flame's [TimerComponent]
/// for staggered spawning within each phase.
class _IntroGame extends FlameGame {
  static const double _worldW = 640;
  static const double _worldH = 360;

  @override
  Color backgroundColor() => const Color(0xFF0A0A0F);

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    camera = CameraComponent.withFixedResolution(
      width: _worldW,
      height: _worldH,
    );
    camera.viewfinder.anchor = Anchor.topLeft;

    // Phase 1: Sand (starts immediately)
    world.add(_SandSpawner(world, _worldW, _worldH));

    // Phase 2: Water (starts at 1.0s)
    world.add(_DelayedSpawner(
      delay: 1.0,
      spawner: _WaterSpawner(world, _worldW, _worldH),
    ));

    // Phase 3: Fire (starts at 2.0s)
    world.add(_DelayedSpawner(
      delay: 2.0,
      spawner: _FireSpawner(world, _worldW, _worldH),
    ));

    // Phase 4: Lava (starts at 3.0s)
    world.add(_DelayedSpawner(
      delay: 3.0,
      spawner: _LavaSpawner(world, _worldW, _worldH),
    ));

    // Phase 5: Steam (starts at 4.0s)
    world.add(_DelayedSpawner(
      delay: 4.0,
      spawner: _SteamSpawner(world, _worldW, _worldH),
    ));
  }
}

// =============================================================================
// Delayed spawner -- waits then adds child component
// =============================================================================

class _DelayedSpawner extends Component {
  _DelayedSpawner({required this.delay, required this.spawner});

  final double delay;
  final Component spawner;
  double _elapsed = 0;
  bool _spawned = false;

  @override
  void update(double dt) {
    super.update(dt);
    if (_spawned) return;
    _elapsed += dt;
    if (_elapsed >= delay) {
      _spawned = true;
      parent?.add(spawner);
      removeFromParent();
    }
  }
}

// =============================================================================
// Phase spawners -- each spawns staggered particles over time
// =============================================================================

/// Sand particles falling with gravity from the top of the screen.
class _SandSpawner extends Component {
  _SandSpawner(this._world, this._worldW, double worldH);

  final World _world;
  final double _worldW;
  final Random _rng = Random(42);

  int _spawned = 0;
  double _elapsed = 0;

  static const int _total = 80;
  static const double _spawnDuration = 1.8;

  @override
  void update(double dt) {
    super.update(dt);
    _elapsed += dt;

    final target = (_elapsed / _spawnDuration * _total).toInt().clamp(0, _total);
    while (_spawned < target) {
      _spawnOne();
      _spawned++;
    }

    if (_spawned >= _total) removeFromParent();
  }

  void _spawnOne() {
    final x = _rng.nextDouble() * _worldW;
    final startY = -10.0 + _rng.nextDouble() * 20;
    final hue = _rng.nextDouble() * 0.1;
    final size = 2.0 + _rng.nextDouble() * 2.0;
    final speedX = (_rng.nextDouble() - 0.5) * 5;
    final speedY = 10 + _rng.nextDouble() * 20;

    _world.add(
      ParticleSystemComponent(
        position: Vector2(x, startY),
        particle: AcceleratedParticle(
          lifespan: 2.5,
          speed: Vector2(speedX, speedY),
          acceleration: Vector2(0, 40),
          child: ComputedParticle(
            lifespan: 2.5,
            renderer: (canvas, particle) {
              final alpha = (1.0 - particle.progress * 0.5);
              final color = Color.lerp(
                const Color(0xFFDEB887),
                const Color(0xFFC4A060),
                hue,
              )!.withValues(alpha: alpha);
              canvas.drawRect(
                Rect.fromLTWH(-size / 2, -size / 2, size, size),
                Paint()..color = color,
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Water particles flowing left-to-right with shimmer.
class _WaterSpawner extends Component {
  _WaterSpawner(this._world, this._worldW, this._worldH);

  final World _world;
  final double _worldW;
  final double _worldH;
  final Random _rng = Random(99);

  int _spawned = 0;
  double _elapsed = 0;
  bool _shimmerSpawned = false;

  static const int _total = 60;
  static const double _spawnDuration = 1.8;

  @override
  void update(double dt) {
    super.update(dt);
    _elapsed += dt;

    final target = (_elapsed / _spawnDuration * _total).toInt().clamp(0, _total);
    while (_spawned < target) {
      _spawnOne();
      _spawned++;
    }

    // Shimmer glow after halfway.
    if (!_shimmerSpawned && _elapsed > 0.8) {
      _shimmerSpawned = true;
      _spawnShimmer();
    }

    if (_spawned >= _total && _shimmerSpawned) removeFromParent();
  }

  void _spawnOne() {
    final y = _worldH * 0.5 + _rng.nextDouble() * _worldH * 0.3;
    final size = 2.0 + _rng.nextDouble() * 2.0;
    final speedX = 30 + _rng.nextDouble() * 50;
    final blend = _rng.nextDouble();

    _world.add(
      ParticleSystemComponent(
        position: Vector2(-20, y),
        particle: AcceleratedParticle(
          lifespan: 2.5,
          speed: Vector2(speedX, (_rng.nextDouble() - 0.5) * 10),
          acceleration: Vector2(-5, 8),
          child: ComputedParticle(
            lifespan: 2.5,
            renderer: (canvas, particle) {
              final alpha = 0.5 + (1.0 - particle.progress) * 0.4;
              final color = Color.lerp(
                const Color(0xFF3399FF),
                const Color(0xFF1166CC),
                blend,
              )!.withValues(alpha: alpha);
              canvas.drawRect(
                Rect.fromLTWH(-size / 2, -size / 2, size, size),
                Paint()..color = color,
              );
            },
          ),
        ),
      ),
    );
  }

  void _spawnShimmer() {
    _world.add(
      ParticleSystemComponent(
        position: Vector2(_worldW * 0.4, _worldH * 0.6),
        particle: ComputedParticle(
          lifespan: 2.0,
          renderer: (canvas, particle) {
            final alpha = particle.progress < 0.5
                ? particle.progress * 0.3
                : (1.0 - particle.progress) * 0.3;
            final paint = Paint()
              ..color = const Color(0xFF3399FF).withValues(alpha: alpha)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30);
            canvas.drawRect(
              Rect.fromLTWH(-_worldW * 0.3, -15, _worldW * 0.6, 30),
              paint,
            );
          },
        ),
      ),
    );
  }
}

/// Fire particles erupting upward from center-right.
class _FireSpawner extends Component {
  _FireSpawner(this._world, this._worldW, this._worldH);

  final World _world;
  final double _worldW;
  final double _worldH;
  final Random _rng = Random(77);

  int _spawned = 0;
  double _elapsed = 0;
  bool _glowSpawned = false;

  static const int _total = 50;
  static const double _spawnDuration = 1.8;

  static const _colors = [
    Color(0xFFFF4500),
    Color(0xFFFF6600),
    Color(0xFFFFAA00),
    Color(0xFFFFDD44),
  ];

  @override
  void update(double dt) {
    super.update(dt);
    _elapsed += dt;

    final target = (_elapsed / _spawnDuration * _total).toInt().clamp(0, _total);
    while (_spawned < target) {
      _spawnOne();
      _spawned++;
    }

    if (!_glowSpawned && _elapsed > 0.3) {
      _glowSpawned = true;
      _spawnGlow();
    }

    if (_spawned >= _total && _glowSpawned) removeFromParent();
  }

  void _spawnOne() {
    final centerX = _worldW * 0.6;
    final baseY = _worldH * 0.65;
    final angle = _rng.nextDouble() * pi * 2;
    final speed = 15 + _rng.nextDouble() * 40;
    final color = _colors[_rng.nextInt(_colors.length)];
    final size = 2.0 + _rng.nextDouble() * 3.0;

    _world.add(
      ParticleSystemComponent(
        position: Vector2(centerX, baseY),
        particle: AcceleratedParticle(
          lifespan: 2.0,
          speed: Vector2(cos(angle) * speed * 0.5, -speed),
          acceleration: Vector2(
            (_rng.nextDouble() - 0.5) * 10,
            15,
          ),
          child: ComputedParticle(
            lifespan: 2.0,
            renderer: (canvas, particle) {
              final alpha = (1.0 - particle.progress) * 0.9;
              canvas.drawRect(
                Rect.fromLTWH(-size / 2, -size / 2, size, size),
                Paint()..color = color.withValues(alpha: alpha),
              );
            },
          ),
        ),
      ),
    );
  }

  void _spawnGlow() {
    final centerX = _worldW * 0.6;
    final baseY = _worldH * 0.65;

    _world.add(
      ParticleSystemComponent(
        position: Vector2(centerX, baseY - 30),
        particle: ComputedParticle(
          lifespan: 2.5,
          renderer: (canvas, particle) {
            final alpha = particle.progress < 0.3
                ? particle.progress * 0.6
                : (1.0 - particle.progress) * 0.3;
            final paint = Paint()
              ..color = const Color(0xFFFF4500).withValues(alpha: alpha)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 40);
            canvas.drawCircle(Offset.zero, 60, paint);
          },
        ),
      ),
    );
  }
}

/// Lava particles flowing from the right side.
class _LavaSpawner extends Component {
  _LavaSpawner(this._world, this._worldW, this._worldH);

  final World _world;
  final double _worldW;
  final double _worldH;
  final Random _rng = Random(55);

  int _spawned = 0;
  double _elapsed = 0;

  static const int _total = 35;
  static const double _spawnDuration = 1.8;

  @override
  void update(double dt) {
    super.update(dt);
    _elapsed += dt;

    final target = (_elapsed / _spawnDuration * _total).toInt().clamp(0, _total);
    while (_spawned < target) {
      _spawnOne();
      _spawned++;
    }

    if (_spawned >= _total) removeFromParent();
  }

  void _spawnOne() {
    final y = _worldH * 0.6 + _rng.nextDouble() * _worldH * 0.2;
    final size = 3.0 + _rng.nextDouble() * 3.0;
    final blend = _rng.nextDouble();

    _world.add(
      ParticleSystemComponent(
        position: Vector2(_worldW + 10, y),
        particle: AcceleratedParticle(
          lifespan: 2.5,
          speed: Vector2(
            -(40 + _rng.nextDouble() * 30),
            (_rng.nextDouble() - 0.5) * 8,
          ),
          acceleration: Vector2(5, 5),
          child: ComputedParticle(
            lifespan: 2.5,
            renderer: (canvas, particle) {
              final alpha = 0.6 + (1.0 - particle.progress) * 0.4;
              final color = Color.lerp(
                const Color(0xFFFF4500),
                const Color(0xFFFF6600),
                blend,
              )!.withValues(alpha: alpha);
              canvas.drawRect(
                Rect.fromLTWH(-size / 2, -size / 2, size, size),
                Paint()..color = color,
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Steam wisps rising where lava meets water.
class _SteamSpawner extends Component {
  _SteamSpawner(this._world, this._worldW, this._worldH);

  final World _world;
  final double _worldW;
  final double _worldH;
  final Random _rng = Random(33);

  int _spawned = 0;
  double _elapsed = 0;
  bool _cloudSpawned = false;

  static const int _total = 30;
  static const double _spawnDuration = 1.8;

  @override
  void update(double dt) {
    super.update(dt);
    _elapsed += dt;

    final target = (_elapsed / _spawnDuration * _total).toInt().clamp(0, _total);
    while (_spawned < target) {
      _spawnOne();
      _spawned++;
    }

    if (!_cloudSpawned && _elapsed > 0.5) {
      _cloudSpawned = true;
      _spawnCloud();
    }

    if (_spawned >= _total && _cloudSpawned) removeFromParent();
  }

  void _spawnOne() {
    final meetX = _worldW * 0.48;
    final meetY = _worldH * 0.55;

    _world.add(
      ParticleSystemComponent(
        position: Vector2(
          meetX + (_rng.nextDouble() - 0.5) * 40,
          meetY,
        ),
        particle: AcceleratedParticle(
          lifespan: 2.5,
          speed: Vector2(
            (_rng.nextDouble() - 0.5) * 12,
            -(20 + _rng.nextDouble() * 30),
          ),
          acceleration: Vector2(0, -5),
          child: ComputedParticle(
            lifespan: 2.5,
            renderer: (canvas, particle) {
              final alpha = (1.0 - particle.progress) * 0.5;
              final radius = 2.0 + particle.progress * 4.0;
              canvas.drawCircle(
                Offset.zero,
                radius,
                Paint()
                  ..color = const Color(0xFFDDDDDD)
                      .withValues(alpha: alpha),
              );
            },
          ),
        ),
      ),
    );
  }

  void _spawnCloud() {
    final meetX = _worldW * 0.48;
    final meetY = _worldH * 0.55;

    _world.add(
      ParticleSystemComponent(
        position: Vector2(meetX, meetY - 50),
        particle: ComputedParticle(
          lifespan: 2.0,
          renderer: (canvas, particle) {
            final grow = particle.progress < 0.4
                ? particle.progress / 0.4
                : 1.0;
            final fade = particle.progress > 0.6
                ? (1.0 - particle.progress) / 0.4
                : 1.0;
            final alpha = grow * fade * 0.15;
            final paint = Paint()
              ..color = const Color(0xFFDDDDDD).withValues(alpha: alpha)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30);
            canvas.drawCircle(Offset.zero, 50 * grow, paint);
          },
        ),
      ),
    );
  }
}
