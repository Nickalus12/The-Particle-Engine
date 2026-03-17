import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../services/save_service.dart';
import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';
import 'load_screen.dart';
import 'sandbox_screen.dart';
import 'settings_screen.dart';
import 'world_create_screen.dart';

/// Premium cinematic main menu with staggered entrance animations,
/// glassmorphism buttons, animated title glow, and floating particle
/// background.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin {
  // -- Staggered entrance animation ------------------------------------------
  late final AnimationController _entranceController;
  late final Animation<double> _titleOpacity;
  late final Animation<double> _titleSlide;
  late final Animation<double> _subtitleOpacity;
  final List<Animation<double>> _buttonOpacities = [];
  final List<Animation<double>> _buttonSlides = [];
  late final Animation<double> _versionOpacity;

  // -- Title glow pulse ------------------------------------------------------
  late final AnimationController _glowController;
  late final Animation<double> _glowAnimation;

  // -- Save state ------------------------------------------------------------
  final SaveService _saveService = SaveService();
  bool _hasAutoSave = false;
  bool _checkingAutoSave = true;

  // -- Menu items (built after auto-save check) ------------------------------
  List<_MenuItemData> get _menuItems => [
        _MenuItemData(
          label: 'New World',
          icon: Icons.add_rounded,
          isPrimary: true,
          onTap: () => _navigateTo(const WorldCreateScreen()),
        ),
        if (!_checkingAutoSave && _hasAutoSave)
          _MenuItemData(
            label: 'Continue',
            icon: Icons.play_arrow_rounded,
            onTap: _continueGame,
          ),
        _MenuItemData(
          label: 'Load World',
          icon: Icons.folder_open_rounded,
          onTap: () => _navigateTo(const LoadScreen()),
        ),
        _MenuItemData(
          label: 'Settings',
          icon: Icons.tune_rounded,
          onTap: () => _navigateTo(const SettingsScreen()),
        ),
      ];

  static const int _maxButtons = 4;

  static const Duration _entranceDuration = Duration(milliseconds: 1800);
  static const Duration _initialDelay = Duration(milliseconds: 200);
  static const Duration _titleDuration = Duration(milliseconds: 400);
  static const Duration _subtitleDelay = Duration(milliseconds: 150);
  static const Duration _buttonStagger = Duration(milliseconds: 120);
  static const Duration _buttonSlideTime = Duration(milliseconds: 350);

  @override
  void initState() {
    super.initState();

    // -- Entrance controller --------------------------------------------------
    _entranceController = AnimationController(
      vsync: this,
      duration: _entranceDuration,
    );

    final totalMs = _entranceDuration.inMilliseconds.toDouble();

    // Title fade + slide
    final titleStart = _initialDelay.inMilliseconds / totalMs;
    final titleEnd =
        (_initialDelay.inMilliseconds + _titleDuration.inMilliseconds) /
            totalMs;
    _titleOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: Interval(titleStart, titleEnd, curve: Curves.easeOut),
      ),
    );
    _titleSlide = Tween<double>(begin: 30, end: 0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: Interval(titleStart, titleEnd, curve: Curves.easeOut),
      ),
    );

    // Subtitle
    final subtitleStart =
        (titleEnd * totalMs + _subtitleDelay.inMilliseconds) / totalMs;
    final subtitleEnd = (subtitleStart * totalMs + 300) / totalMs;
    _subtitleOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: Interval(
          subtitleStart.clamp(0, 1),
          subtitleEnd.clamp(0, 1),
          curve: Curves.easeOut,
        ),
      ),
    );

    // Buttons (staggered)
    final buttonsBaseMs = subtitleEnd * totalMs + 100;
    for (var i = 0; i < _maxButtons; i++) {
      final start =
          (buttonsBaseMs + _buttonStagger.inMilliseconds * i) / totalMs;
      final end =
          (start * totalMs + _buttonSlideTime.inMilliseconds) / totalMs;
      _buttonOpacities.add(
        Tween<double>(begin: 0, end: 1).animate(
          CurvedAnimation(
            parent: _entranceController,
            curve: Interval(
              start.clamp(0, 1),
              end.clamp(0, 1),
              curve: Curves.easeOut,
            ),
          ),
        ),
      );
      _buttonSlides.add(
        Tween<double>(begin: 40, end: 0).animate(
          CurvedAnimation(
            parent: _entranceController,
            curve: Interval(
              start.clamp(0, 1),
              end.clamp(0, 1),
              curve: Curves.easeOut,
            ),
          ),
        ),
      );
    }

    // Version badge
    _versionOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.7, 1.0, curve: Curves.easeOut),
      ),
    );

    _entranceController.forward();

    // -- Glow controller (continuous pulse) -----------------------------------
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat(reverse: true);
    _glowAnimation = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );

    _checkAutoSave();
  }

  Future<void> _checkAutoSave() async {
    final exists = await _saveService.slotExists(SaveService.autoSaveSlot);
    if (mounted) {
      setState(() {
        _hasAutoSave = exists;
        _checkingAutoSave = false;
      });
    }
  }

  @override
  void dispose() {
    _entranceController.dispose();
    _glowController.dispose();
    super.dispose();
  }

  void _navigateTo(Widget screen) {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, _, _) => screen,
        transitionsBuilder: (context, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: ParticleTheme.normalDuration,
      ),
    );
  }

  Future<void> _continueGame() async {
    final state = await _saveService.load(SaveService.autoSaveSlot);
    if (state != null && mounted) {
      _navigateTo(SandboxScreen(loadState: state));
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final items = _menuItems;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          // Animated particle background
          const Positioned.fill(child: _ParticleBackground()),

          // Subtle radial gradient overlay for depth
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.3, -0.2),
                    radius: 1.2,
                    colors: [
                      AppColors.primary.withValues(alpha: 0.03),
                      Colors.transparent,
                      AppColors.accent.withValues(alpha: 0.02),
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
              ),
            ),
          ),

          // Main content
          SafeArea(
            child: Center(
              child: AnimatedBuilder(
                animation: _entranceController,
                builder: (context, _) {
                  return ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 900),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Row(
                        children: [
                          // Left: branding
                          Expanded(child: _buildBranding()),
                          const SizedBox(width: 48),
                          // Right: menu buttons
                          Expanded(child: _buildMenu(items)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          // Version badge
          Positioned(
            bottom: 8,
            right: 12,
            child: FadeTransition(
              opacity: _versionOpacity,
              child: Text(
                'v0.1.0',
                style: AppTypography.caption.copyWith(
                  color: AppColors.textDim.withValues(alpha: 0.4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBranding() {
    return Opacity(
      opacity: _titleOpacity.value,
      child: Transform.translate(
        offset: Offset(0, _titleSlide.value),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // "THE" label
            Text(
              'THE',
              style: AppTypography.label.copyWith(
                fontSize: 14,
                letterSpacing: 8.0,
                color: AppColors.textDim,
              ),
            ),
            const SizedBox(height: 6),
            // Title with animated glow
            AnimatedBuilder(
              animation: _glowAnimation,
              builder: (context, child) {
                return ShaderMask(
                  shaderCallback: (bounds) => LinearGradient(
                    colors: [
                      AppColors.primary,
                      Color.lerp(
                        AppColors.accent,
                        AppColors.primary,
                        _glowAnimation.value * 0.3,
                      )!,
                    ],
                  ).createShader(bounds),
                  child: Text(
                    'PARTICLE\nENGINE',
                    textAlign: TextAlign.center,
                    style: AppTypography.title.copyWith(
                      fontSize: 42,
                      color: Colors.white,
                      height: 1.0,
                      shadows: [
                        Shadow(
                          color: AppColors.primary
                              .withValues(alpha: 0.6 * _glowAnimation.value),
                          blurRadius: 20 * _glowAnimation.value,
                        ),
                        Shadow(
                          color: AppColors.accent
                              .withValues(alpha: 0.3 * _glowAnimation.value),
                          blurRadius: 40 * _glowAnimation.value,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            // Subtitle
            Opacity(
              opacity: _subtitleOpacity.value,
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
    );
  }

  Widget _buildMenu(List<_MenuItemData> items) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(height: 14),
          Opacity(
            opacity:
                i < _buttonOpacities.length ? _buttonOpacities[i].value : 1.0,
            child: Transform.translate(
              offset: Offset(
                0,
                i < _buttonSlides.length ? _buttonSlides[i].value : 0,
              ),
              child: _MenuButton(
                label: items[i].label,
                icon: items[i].icon,
                isPrimary: items[i].isPrimary,
                onTap: items[i].onTap,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// =============================================================================
// Menu item data
// =============================================================================

class _MenuItemData {
  const _MenuItemData({
    required this.label,
    required this.icon,
    required this.onTap,
    this.isPrimary = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool isPrimary;
}

// =============================================================================
// Menu button with glassmorphism, press scale, and hover brightness
// =============================================================================

class _MenuButton extends StatefulWidget {
  const _MenuButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.isPrimary = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool isPrimary;

  @override
  State<_MenuButton> createState() => _MenuButtonState();
}

class _MenuButtonState extends State<_MenuButton>
    with SingleTickerProviderStateMixin {
  bool _hovered = false;

  late final AnimationController _pressController;
  late final Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _pressController = AnimationController(
      vsync: this,
      duration: ParticleTheme.fastDuration,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _pressController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pressController.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) {
    _pressController.forward();
  }

  void _onTapUp(TapUpDetails _) {
    _pressController.reverse();
    widget.onTap();
  }

  void _onTapCancel() {
    _pressController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final accentColor =
        widget.isPrimary ? AppColors.primary : AppColors.accent;
    final borderColor = widget.isPrimary
        ? AppColors.primary.withValues(alpha: _hovered ? 0.6 : 0.35)
        : AppColors.glassBorder.withValues(alpha: _hovered ? 0.5 : 0.2);
    final bgColor = widget.isPrimary
        ? AppColors.primary.withValues(alpha: _hovered ? 0.2 : 0.12)
        : AppColors.glass.withValues(alpha: _hovered ? 0.18 : 0.1);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: _onTapDown,
        onTapUp: _onTapUp,
        onTapCancel: _onTapCancel,
        child: AnimatedBuilder(
          animation: _scaleAnimation,
          builder: (context, child) {
            return Transform.scale(
              scale: _scaleAnimation.value,
              child: child,
            );
          },
          child: ClipRRect(
            borderRadius:
                BorderRadius.circular(ParticleTheme.radiusMedium),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: AnimatedContainer(
                duration: ParticleTheme.fastDuration,
                width: 280,
                height: 58,
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius:
                      BorderRadius.circular(ParticleTheme.radiusMedium),
                  border: Border.all(color: borderColor, width: 0.5),
                  boxShadow: widget.isPrimary
                      ? [
                          BoxShadow(
                            color: accentColor.withValues(
                                alpha: _hovered ? 0.2 : 0.1),
                            blurRadius: _hovered ? 30 : 20,
                          ),
                        ]
                      : _hovered
                          ? [
                              BoxShadow(
                                color:
                                    AppColors.accent.withValues(alpha: 0.08),
                                blurRadius: 16,
                              ),
                            ]
                          : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      widget.icon,
                      size: 22,
                      color: widget.isPrimary
                          ? AppColors.primary
                          : AppColors.textPrimary,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      widget.label,
                      style: AppTypography.button.copyWith(
                        fontSize: 15,
                        color: widget.isPrimary
                            ? AppColors.primary
                            : AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Animated particle background
// =============================================================================

class _ParticleBackground extends StatefulWidget {
  const _ParticleBackground();

  @override
  State<_ParticleBackground> createState() => _ParticleBackgroundState();
}

class _ParticleBackgroundState extends State<_ParticleBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<_Particle> _particles;

  @override
  void initState() {
    super.initState();
    final rng = Random(42);
    _particles = List.generate(
      80,
      (_) {
        final depth = rng.nextDouble(); // 0 = far, 1 = near
        return _Particle(
          x: rng.nextDouble(),
          y: rng.nextDouble(),
          vx: (rng.nextDouble() - 0.5) * 0.008 * (0.3 + depth * 0.7),
          vy: (rng.nextDouble() - 0.5) * 0.008 * (0.3 + depth * 0.7),
          size: 0.8 + depth * 3.0,
          alpha: 0.03 + depth * 0.2,
          color: _pickColor(rng),
          pulsePhase: rng.nextDouble() * 2 * pi,
          pulseSpeed: 0.5 + rng.nextDouble() * 1.5,
        );
      },
    );
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 60),
    )..repeat();
    _controller.addListener(_updateParticles);
  }

  static Color _pickColor(Random rng) {
    final colors = [
      AppColors.primary,
      AppColors.accent,
      AppColors.textDim,
    ];
    return colors[rng.nextInt(colors.length)];
  }

  void _updateParticles() {
    for (final p in _particles) {
      p.x += p.vx;
      p.y += p.vy;
      if (p.x < 0) p.x = 1.0;
      if (p.x > 1) p.x = 0.0;
      if (p.y < 0) p.y = 1.0;
      if (p.y > 1) p.y = 0.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          painter: _ParticlePainter(_particles, _controller.value),
          size: Size.infinite,
        );
      },
    );
  }
}

class _Particle {
  _Particle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.size,
    required this.alpha,
    required this.color,
    required this.pulsePhase,
    required this.pulseSpeed,
  });

  double x, y, vx, vy, size, alpha;
  Color color;
  double pulsePhase;
  double pulseSpeed;
}

class _ParticlePainter extends CustomPainter {
  _ParticlePainter(this.particles, this.time);
  final List<_Particle> particles;
  final double time;

  @override
  void paint(Canvas canvas, Size size) {
    final elapsed = time * 60; // seconds
    for (final p in particles) {
      final pulse =
          0.7 + 0.3 * sin(elapsed * p.pulseSpeed + p.pulsePhase);
      final paint = Paint()
        ..color = p.color.withValues(alpha: p.alpha * pulse)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, p.size * 1.5);
      canvas.drawCircle(
        Offset(p.x * size.width, p.y * size.height),
        p.size,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter old) => true;
}
