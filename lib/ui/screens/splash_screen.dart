import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../audio/audio_manager.dart';
import '../../creatures/genome_library.dart';
import '../../simulation/element_registry.dart';
import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';
import 'home_screen.dart';
import 'intro_screen.dart';

/// Full-screen cinematic splash with a falling-elements simulation background,
/// large centered title with shimmer animation, and a thin progress bar at
/// the very bottom. Auto-transitions after ~2.5 seconds.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _simController;
  late final AnimationController _masterController;
  late final AnimationController _exitController;
  late final AnimationController _shimmerController;

  late final Animation<double> _titleFade;
  late final Animation<double> _titleScale;
  late final Animation<double> _progressFade;

  // Mini falling-element simulation state
  late final List<_FallingElement> _elements;
  late final Random _rng;

  static const String _hasSeenIntroKey = 'has_seen_intro';

  @override
  void initState() {
    super.initState();

    _rng = Random(42);

    // Generate falling elements of different types
    _elements = List.generate(200, (_) => _FallingElement.random(_rng));

    _simController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 60),
    )..repeat();
    _simController.addListener(_tickElements);

    _masterController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );

    _exitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();

    _titleFade = CurvedAnimation(
      parent: _masterController,
      curve: const Interval(0.15, 0.45, curve: Curves.easeOut),
    );
    _titleScale = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(
        parent: _masterController,
        curve: const Interval(0.15, 0.50, curve: Curves.easeOutCubic),
      ),
    );
    _progressFade = CurvedAnimation(
      parent: _masterController,
      curve: const Interval(0.30, 0.55, curve: Curves.easeOut),
    );

    _masterController.forward();
    _initialize();
  }

  void _tickElements() {
    for (final el in _elements) {
      el.y += el.vy;
      el.x += el.vx;
      // Reset when off-screen
      if (el.y > 1.15) {
        el.y = -0.05 - _rng.nextDouble() * 0.1;
        el.x = _rng.nextDouble();
      }
    }
  }

  @override
  void dispose() {
    _simController.dispose();
    _masterController.dispose();
    _exitController.dispose();
    _shimmerController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    final results = await Future.wait([
      _initServices(),
      Future.delayed(const Duration(milliseconds: 2600)),
    ]);

    if (!mounted) return;
    final hasSeenIntro = results[0] as bool;

    await _exitController.forward();
    if (!mounted) return;

    final destination =
        hasSeenIntro ? const HomeScreen() : const IntroScreen();

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, _, _) => destination,
        transitionsBuilder: (context, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: ParticleTheme.slowDuration,
      ),
    );
  }

  Future<bool> _initServices() async {
    ElementRegistry.init();
    await AudioManager.instance.init();
    // Load pre-trained creature brains from QDax archives (async, non-blocking)
    GenomeLibrary.instance.loadAll();
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_hasSeenIntroKey) ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: AnimatedBuilder(
        animation: _exitController,
        builder: (context, child) {
          return Opacity(
            opacity: 1.0 - _exitController.value,
            child: child,
          );
        },
        child: Stack(
          children: [
            // Full-screen falling elements simulation background
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _simController,
                builder: (context, _) {
                  return CustomPaint(
                    painter: _FallingElementsPainter(
                      _elements,
                      _simController.value,
                    ),
                    size: Size.infinite,
                  );
                },
              ),
            ),

            // Dark gradient overlay to make title readable
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.center,
                      radius: 0.8,
                      colors: [
                        AppColors.background.withValues(alpha: 0.7),
                        AppColors.background.withValues(alpha: 0.3),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Large centered title with shimmer
            Center(
              child: AnimatedBuilder(
                animation: _masterController,
                builder: (context, _) {
                  return FadeTransition(
                    opacity: _titleFade,
                    child: ScaleTransition(
                      scale: _titleScale,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // "THE" label
                          Text(
                            'THE',
                            style: AppTypography.label.copyWith(
                              fontSize: 16,
                              letterSpacing: 12.0,
                              color: AppColors.textDim,
                            ),
                          ),
                          const SizedBox(height: 8),
                          // Main title with shimmer
                          AnimatedBuilder(
                            animation: _shimmerController,
                            builder: (context, child) {
                              return ShaderMask(
                                shaderCallback: (bounds) {
                                  final shimmerX =
                                      _shimmerController.value * 3.0 - 1.0;
                                  return LinearGradient(
                                    begin: Alignment(shimmerX - 0.3, 0),
                                    end: Alignment(shimmerX + 0.3, 0),
                                    colors: const [
                                      AppColors.primary,
                                      Colors.white,
                                      AppColors.primary,
                                    ],
                                    stops: const [0.0, 0.5, 1.0],
                                  ).createShader(bounds);
                                },
                                child: child!,
                              );
                            },
                            child: Text(
                              'PARTICLE\nENGINE',
                              textAlign: TextAlign.center,
                              style: AppTypography.title.copyWith(
                                fontSize: 56,
                                color: Colors.white,
                                height: 0.95,
                                letterSpacing: 4.0,
                                shadows: [
                                  Shadow(
                                    color: AppColors.primary
                                        .withValues(alpha: 0.6),
                                    blurRadius: 30,
                                  ),
                                  Shadow(
                                    color: AppColors.accent
                                        .withValues(alpha: 0.3),
                                    blurRadius: 60,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

            // Thin progress bar at the very bottom
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: FadeTransition(
                opacity: _progressFade,
                child: SizedBox(
                  height: 2,
                  child: AnimatedBuilder(
                    animation: _masterController,
                    builder: (context, _) {
                      // Progress tied to master timeline
                      final progress =
                          (_masterController.value / 0.95).clamp(0.0, 1.0);
                      return Stack(
                        children: [
                          // Track
                          Positioned.fill(
                            child: Container(
                              color:
                                  AppColors.surfaceLight.withValues(alpha: 0.3),
                            ),
                          ),
                          // Fill
                          FractionallySizedBox(
                            widthFactor: progress,
                            child: Container(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    AppColors.primary,
                                    AppColors.accent,
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
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
// Falling element data
// =============================================================================

class _FallingElement {
  double x, y, vx, vy, size;
  Color color;
  int shape; // 0=square, 1=circle, 2=diamond

  _FallingElement({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.size,
    required this.color,
    required this.shape,
  });

  factory _FallingElement.random(Random rng) {
    const elementColors = [
      Color(0xFFDEB887), // Sand
      Color(0xFFC4A060), // Dark sand
      Color(0xFF3399FF), // Water
      Color(0xFF1166CC), // Deep water
      Color(0xFFFF4500), // Fire
      Color(0xFFFFAA00), // Fire bright
      Color(0xFFFF6600), // Lava
      Color(0xFF808080), // Stone
      Color(0xFF6B4423), // Dirt
      Color(0xFF28B040), // Plant
      Color(0xFF2E9AFF), // Water light
      Color(0xFFFFDD44), // Spark
    ];

    return _FallingElement(
      x: rng.nextDouble(),
      y: -rng.nextDouble(), // Start above screen
      vx: (rng.nextDouble() - 0.5) * 0.0005,
      vy: 0.001 + rng.nextDouble() * 0.003, // Gravity-like fall speed
      size: 2.0 + rng.nextDouble() * 4.0,
      color: elementColors[rng.nextInt(elementColors.length)],
      shape: rng.nextInt(3),
    );
  }
}

// =============================================================================
// Painter for falling elements
// =============================================================================

class _FallingElementsPainter extends CustomPainter {
  _FallingElementsPainter(this.elements, this.time);
  final List<_FallingElement> elements;
  final double time;

  @override
  void paint(Canvas canvas, Size size) {
    for (final el in elements) {
      if (el.y < -0.05 || el.y > 1.1) continue;

      final px = el.x * size.width;
      final py = el.y * size.height;
      final alpha = (0.3 + 0.5 * (1.0 - (el.y).clamp(0.0, 1.0)))
          .clamp(0.0, 1.0);
      final paint = Paint()..color = el.color.withValues(alpha: alpha);

      switch (el.shape) {
        case 0: // Square pixel
          canvas.drawRect(
            Rect.fromCenter(
              center: Offset(px, py),
              width: el.size,
              height: el.size,
            ),
            paint,
          );
          break;
        case 1: // Circle droplet
          canvas.drawCircle(Offset(px, py), el.size * 0.5, paint);
          break;
        case 2: // Diamond
          final path = Path()
            ..moveTo(px, py - el.size * 0.5)
            ..lineTo(px + el.size * 0.5, py)
            ..lineTo(px, py + el.size * 0.5)
            ..lineTo(px - el.size * 0.5, py)
            ..close();
          canvas.drawPath(path, paint);
          break;
      }

      // Small glow for fire/lava elements
      if ((el.color.r * 255).round() > 200 && (el.color.g * 255).round() < 150) {
        final glowPaint = Paint()
          ..color = el.color.withValues(alpha: alpha * 0.15)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, el.size * 2);
        canvas.drawCircle(Offset(px, py), el.size * 1.5, glowPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FallingElementsPainter old) => true;
}
