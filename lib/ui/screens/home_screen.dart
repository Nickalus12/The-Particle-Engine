import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../services/save_service.dart';
import '../../simulation/element_behaviors.dart';
import '../../simulation/element_registry.dart';
import '../../simulation/pixel_renderer.dart';
import '../../simulation/simulation_engine.dart';
import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';
import 'load_screen.dart';
import 'sandbox_screen.dart';
import 'settings_screen.dart';
import 'world_create_screen.dart';

/// Premium main menu with a LIVE simulation running as the background.
///
/// A real [SimulationEngine] generates a meadow world and ticks it each frame.
/// Sand falls, water flows, fire burns -- the world is alive behind the menu.
/// Three large frosted-glass buttons float over the living world.
///
/// When transitioning to sandbox, the menu UI fades away revealing the
/// simulation beneath, creating a seamless "dive in" feeling.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin {
  // -- Live simulation background --
  SimulationEngine? _sim;
  PixelRenderer? _renderer;
  ui.Image? _simImage;
  bool _simReady = false;
  bool _decoding = false;

  // -- Animation controllers --
  late final AnimationController _simTicker;
  late final AnimationController _entranceController;
  late final AnimationController _glowController;
  late final AnimationController _menuFadeController;

  // -- Entrance animations --
  late final Animation<double> _titleOpacity;
  late final Animation<double> _titleSlide;
  late final List<Animation<double>> _btnOpacities;
  late final List<Animation<double>> _btnSlides;
  late final Animation<double> _glowAnim;

  // -- Save state --
  final SaveService _saveService = SaveService();
  bool _hasAutoSave = false;
  bool _checkingAutoSave = true;

  // Accumulated time for fixed-rate sim stepping
  double _simAccumulator = 0.0;
  static const double _simInterval = 1.0 / 30.0;

  // Demo world grid (half resolution for performance on menu)
  static const int _demoW = 160;
  static const int _demoH = 90;

  @override
  void initState() {
    super.initState();

    // -- Initialize live simulation background --
    ElementRegistry.init();
    final sim = SimulationEngine(gridW: _demoW, gridH: _demoH, seed: 42);
    _sim = sim;
    final renderer = PixelRenderer(sim);
    _renderer = renderer;
    renderer.init();
    renderer.generateStars();

    // Simple demo scene: ground + falling elements + fire
    final rng = Random(77);
    for (var x = 0; x < _demoW; x++) {
      for (var y = _demoH - 15; y < _demoH; y++) {
        final idx = y * _demoW + x;
        sim.grid[idx] = y > _demoH - 5 ? El.stone : El.dirt;
        sim.markDirty(x, y);
      }
    }
    for (var i = 0; i < 80; i++) {
      final x = rng.nextInt(_demoW);
      final y = rng.nextInt(30) + 5;
      final idx = y * _demoW + x;
      if (sim.grid[idx] == El.empty) {
        sim.grid[idx] = i < 40 ? El.sand : El.water;
        sim.markDirty(x, y);
      }
    }
    for (var i = 0; i < 6; i++) {
      final x = 20 + rng.nextInt(_demoW - 40);
      final y = _demoH - 16;
      final idx = y * _demoW + x;
      if (sim.grid[idx] == El.empty) {
        sim.grid[idx] = El.fire;
        sim.temperature[idx] = 220;
        sim.markDirty(x, y);
      }
    }
    _simReady = true;

    // -- Sim ticker (runs every frame) --
    _simTicker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    _simTicker.addListener(_tickSimulation);

    // -- Entrance animations --
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );

    _titleOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.0, 0.35, curve: Curves.easeOut),
      ),
    );
    _titleSlide = Tween<double>(begin: -30, end: 0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.0, 0.35, curve: Curves.easeOutCubic),
      ),
    );

    _btnOpacities = [];
    _btnSlides = [];
    for (var i = 0; i < 3; i++) {
      final start = 0.25 + i * 0.1;
      final end = (start + 0.25).clamp(0.0, 1.0);
      _btnOpacities.add(
        Tween<double>(begin: 0, end: 1).animate(
          CurvedAnimation(
            parent: _entranceController,
            curve: Interval(start, end, curve: Curves.easeOut),
          ),
        ),
      );
      _btnSlides.add(
        Tween<double>(begin: 50, end: 0).animate(
          CurvedAnimation(
            parent: _entranceController,
            curve: Interval(start, end, curve: Curves.easeOutCubic),
          ),
        ),
      );
    }

    _entranceController.forward();

    // -- Title glow --
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat(reverse: true);
    _glowAnim = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );

    // -- Menu fade (for seamless transition) --
    _menuFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    _checkAutoSave();
  }

  void _tickSimulation() {
    if (!_simReady || _sim == null || _renderer == null) return;
    // Fixed-rate stepping at 30fps
    _simAccumulator += 1.0 / 60.0; // assume 60fps render
    while (_simAccumulator >= _simInterval) {
      _simAccumulator -= _simInterval;
      _sim!.step(simulateElement);
    }

    // Render pixels and build image
    _renderer!.renderPixels();
    if (!_decoding) {
      _decoding = true;
      _renderer!.buildImage().then((image) {
        _simImage?.dispose();
        _simImage = image as ui.Image;
        _decoding = false;
        if (mounted) setState(() {});
      });
    }
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
    _simTicker.dispose();
    _entranceController.dispose();
    _glowController.dispose();
    _menuFadeController.dispose();
    _simImage?.dispose();
    super.dispose();
  }

  void _navigateTo(Widget screen) {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, _, _) => screen,
        transitionsBuilder: (context, anim, _, child) {
          return FadeTransition(
            opacity: anim,
            child: child,
          );
        },
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          // LIVE SIMULATION BACKGROUND
          Positioned.fill(
            child: _simImage != null
                ? CustomPaint(
                    painter: _SimImagePainter(_simImage!),
                    size: Size.infinite,
                  )
                : const ColoredBox(color: AppColors.background),
          ),

          // Vignette overlay to focus attention on center UI
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 1.0,
                    colors: [
                      AppColors.background.withValues(alpha: 0.35),
                      AppColors.background.withValues(alpha: 0.8),
                    ],
                    stops: const [0.3, 1.0],
                  ),
                ),
              ),
            ),
          ),

          // Menu UI (fades out for seamless transition)
          AnimatedBuilder(
            animation: _menuFadeController,
            builder: (context, child) {
              return Opacity(
                opacity: 1.0 - _menuFadeController.value,
                child: child,
              );
            },
            child: SafeArea(
              child: AnimatedBuilder(
                animation: _entranceController,
                builder: (context, _) {
                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Title
                          Opacity(
                            opacity: _titleOpacity.value,
                            child: Transform.translate(
                              offset: Offset(0, _titleSlide.value),
                              child: _buildTitle(),
                            ),
                          ),

                          const SizedBox(height: 48),

                          // 3 large buttons
                          _buildButton(
                            index: 0,
                            label: 'CREATE',
                            icon: Icons.add_rounded,
                            color: AppColors.primary,
                            onTap: () =>
                                _navigateTo(const WorldCreateScreen()),
                          ),
                          const SizedBox(height: 16),
                          _buildButton(
                            index: 1,
                            label: (!_checkingAutoSave && _hasAutoSave)
                                ? 'CONTINUE'
                                : 'LOAD WORLD',
                            icon: (!_checkingAutoSave && _hasAutoSave)
                                ? Icons.play_arrow_rounded
                                : Icons.folder_open_rounded,
                            color: AppColors.accent,
                            onTap: (!_checkingAutoSave && _hasAutoSave)
                                ? _continueGame
                                : () => _navigateTo(const LoadScreen()),
                          ),
                          const SizedBox(height: 16),
                          _buildButton(
                            index: 2,
                            label: 'SETTINGS',
                            icon: Icons.tune_rounded,
                            color: AppColors.textDim,
                            onTap: () =>
                                _navigateTo(const SettingsScreen()),
                          ),
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
            child: Text(
              'v0.1.0',
              style: AppTypography.caption.copyWith(
                color: AppColors.textDim.withValues(alpha: 0.3),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTitle() {
    return AnimatedBuilder(
      animation: _glowAnim,
      builder: (context, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'THE',
              style: AppTypography.label.copyWith(
                fontSize: 14,
                letterSpacing: 10.0,
                color: AppColors.textDim,
              ),
            ),
            const SizedBox(height: 4),
            ShaderMask(
              shaderCallback: (bounds) => LinearGradient(
                colors: [
                  AppColors.primary,
                  Color.lerp(
                    AppColors.accent,
                    AppColors.primary,
                    _glowAnim.value * 0.3,
                  )!,
                ],
              ).createShader(bounds),
              child: Text(
                'PARTICLE\nENGINE',
                textAlign: TextAlign.center,
                style: AppTypography.title.copyWith(
                  fontSize: 52,
                  color: Colors.white,
                  height: 0.95,
                  letterSpacing: 3.0,
                  shadows: [
                    Shadow(
                      color: AppColors.primary
                          .withValues(alpha: 0.5 * _glowAnim.value),
                      blurRadius: 20 * _glowAnim.value,
                    ),
                    Shadow(
                      color: AppColors.accent
                          .withValues(alpha: 0.25 * _glowAnim.value),
                      blurRadius: 40 * _glowAnim.value,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: 80,
              height: 2,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(1),
                gradient: LinearGradient(
                  colors: [
                    AppColors.primary.withValues(alpha: 0.0),
                    AppColors.primary.withValues(alpha: 0.7),
                    AppColors.accent.withValues(alpha: 0.7),
                    AppColors.accent.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Elements, creatures & ecosystems',
              style: AppTypography.body.copyWith(
                color: AppColors.textSecondary,
                fontSize: 13,
                letterSpacing: 1.5,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildButton({
    required int index,
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    final opacity =
        index < _btnOpacities.length ? _btnOpacities[index].value : 1.0;
    final slide =
        index < _btnSlides.length ? _btnSlides[index].value : 0.0;

    return Opacity(
      opacity: opacity,
      child: Transform.translate(
        offset: Offset(0, slide),
        child: _LargeMenuButton(
          label: label,
          icon: icon,
          accentColor: color,
          onTap: onTap,
        ),
      ),
    );
  }
}

// =============================================================================
// Painter that draws the simulation's ui.Image scaled to fill the widget
// =============================================================================

class _SimImagePainter extends CustomPainter {
  _SimImagePainter(this.image);
  final ui.Image image;

  static final _paint = ui.Paint()
    ..filterQuality = ui.FilterQuality.none; // Pixel-perfect, no smoothing

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    // Scale the small sim image (160x90) to fill the screen
    final scaleX = size.width / image.width;
    final scaleY = size.height / image.height;
    final scale = scaleX > scaleY ? scaleX : scaleY; // cover
    final dx = (size.width - image.width * scale) / 2;
    final dy = (size.height - image.height * scale) / 2;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale, scale);
    canvas.drawImage(image, ui.Offset.zero, _paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SimImagePainter old) =>
      !identical(old.image, image);
}

// =============================================================================
// Large frosted-glass menu button
// =============================================================================

class _LargeMenuButton extends StatefulWidget {
  const _LargeMenuButton({
    required this.label,
    required this.icon,
    required this.accentColor,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color accentColor;
  final VoidCallback onTap;

  @override
  State<_LargeMenuButton> createState() => _LargeMenuButtonState();
}

class _LargeMenuButtonState extends State<_LargeMenuButton>
    with SingleTickerProviderStateMixin {
  bool _hovered = false;
  late final AnimationController _pressController;
  late final Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _pressController = AnimationController(
      vsync: this,
      duration: ParticleTheme.fastDuration,
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 0.96).animate(
      CurvedAnimation(parent: _pressController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.accentColor;
    final isPrimary = color == AppColors.primary;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => _pressController.forward(),
        onTapUp: (_) {
          _pressController.reverse();
          widget.onTap();
        },
        onTapCancel: () => _pressController.reverse(),
        child: AnimatedBuilder(
          animation: _scaleAnim,
          builder: (context, child) {
            return Transform.scale(
              scale: _scaleAnim.value,
              child: child,
            );
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(ParticleTheme.radiusLarge),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: AnimatedContainer(
                duration: ParticleTheme.fastDuration,
                width: double.infinity,
                height: 64,
                decoration: BoxDecoration(
                  color: isPrimary
                      ? color.withValues(alpha: _hovered ? 0.2 : 0.12)
                      : AppColors.glass
                          .withValues(alpha: _hovered ? 0.25 : 0.15),
                  borderRadius:
                      BorderRadius.circular(ParticleTheme.radiusLarge),
                  border: Border.all(
                    color: isPrimary
                        ? color.withValues(alpha: _hovered ? 0.6 : 0.35)
                        : color.withValues(alpha: _hovered ? 0.4 : 0.15),
                    width: isPrimary ? 1.0 : 0.5,
                  ),
                  boxShadow: _hovered
                      ? [
                          BoxShadow(
                            color: color.withValues(
                                alpha: isPrimary ? 0.25 : 0.08),
                            blurRadius: 30,
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (isPrimary)
                      Container(
                        width: 3,
                        height: 28,
                        margin: const EdgeInsets.only(right: 16),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(2),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              color.withValues(
                                  alpha: _hovered ? 1.0 : 0.7),
                              AppColors.accent.withValues(
                                  alpha: _hovered ? 0.8 : 0.4),
                            ],
                          ),
                        ),
                      ),
                    Icon(
                      widget.icon,
                      size: 22,
                      color: isPrimary
                          ? color
                          : _hovered
                              ? AppColors.textPrimary
                              : AppColors.textSecondary,
                    ),
                    const SizedBox(width: 14),
                    Text(
                      widget.label,
                      style: AppTypography.button.copyWith(
                        fontSize: 16,
                        letterSpacing: 2.0,
                        fontWeight: FontWeight.w700,
                        color: isPrimary
                            ? color
                            : _hovered
                                ? AppColors.textPrimary
                                : AppColors.textSecondary,
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
