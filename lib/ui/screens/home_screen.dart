import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../services/save_service.dart';
import '../../simulation/element_behaviors.dart';
import '../../simulation/element_registry.dart';
import '../../simulation/pixel_renderer.dart';
import '../../simulation/simulation_engine.dart';
import '../../simulation/world_gen/world_config.dart';
import '../../simulation/world_gen/world_generator.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'load_screen.dart';
import 'sandbox_screen.dart';
import 'settings_screen.dart';
import 'world_create_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  SimulationEngine? _sim;
  PixelRenderer? _renderer;
  ui.Image? _simImage;
  bool _decoding = false;

  late final AnimationController _simTicker;
  late final AnimationController _entranceController;
  late final AnimationController _glowController;

  final SaveService _saveService = SaveService();
  bool _hasAutoSave = false;
  bool _checkingAutoSave = true;

  double _simAccumulator = 0.0;
  static const double _simInterval = 1.0 / 30.0;
  static const int _demoW = 176;
  static const int _demoH = 100;

  @override
  void initState() {
    super.initState();
    ElementRegistry.init();
    final sim = SimulationEngine(gridW: _demoW, gridH: _demoH, seed: 84);
    final renderer = PixelRenderer(sim)..init();
    renderer.generateStars();
    _sim = sim;
    _renderer = renderer;
    _seedShowcaseWorld(sim);

    _simTicker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    _simTicker.addListener(_tickSimulation);

    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..forward();

    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    )..repeat(reverse: true);

    _checkAutoSave();
  }

  void _seedShowcaseWorld(SimulationEngine sim) {
    final showcaseConfig = WorldConfig(
      width: sim.gridW,
      height: sim.gridH,
      seed: 991,
      terrainScale: 1.05,
      waterLevel: 0.56,
      caveDensity: 0.18,
      vegetation: 0.74,
      oreRichness: 0.22,
      clayNearWater: 0.62,
      volcanicActivity: 0.42,
      sulfurNearLava: 0.45,
      compostDepth: 0.38,
      algaeInWater: 0.58,
      seedScatter: 0.42,
    );
    final gridData = WorldGenerator.generate(showcaseConfig);
    gridData.loadIntoEngine(sim);
    sim.windForce = 1;
    sim.markAllDirty();
  }

  void _tickSimulation() {
    final sim = _sim;
    final renderer = _renderer;
    if (sim == null || renderer == null) return;

    _simAccumulator += 1.0 / 60.0;
    while (_simAccumulator >= _simInterval) {
      _simAccumulator -= _simInterval;
      sim.step(simulateElement);
    }

    renderer.renderPixels();
    if (_decoding) return;
    _decoding = true;
    renderer.buildImage().then((image) {
      _simImage?.dispose();
      _simImage = image as ui.Image;
      _decoding = false;
      if (mounted) setState(() {});
    });
  }

  Future<void> _checkAutoSave() async {
    final exists = await _saveService.slotExists(SaveService.autoSaveSlot);
    if (!mounted) return;
    setState(() {
      _hasAutoSave = exists;
      _checkingAutoSave = false;
    });
  }

  @override
  void dispose() {
    _simTicker.removeListener(_tickSimulation);
    _simTicker.dispose();
    _entranceController.dispose();
    _glowController.dispose();
    _simImage?.dispose();
    super.dispose();
  }

  void _navigateTo(Widget screen) {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, _, _) => screen,
        transitionsBuilder: (context, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  Future<void> _continueGame() async {
    final state = await _saveService.load(SaveService.autoSaveSlot);
    if (state != null && mounted) {
      _navigateTo(SandboxScreen(loadState: state));
    }
  }

  void _quickStartBalancedWorld() {
    _navigateTo(
      SandboxScreen(
        worldConfig: WorldConfig.meadow(seed: 424242),
        worldName: 'Quick Start Meadow',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final bool compact = size.width < 600;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          // Live simulation background
          Positioned.fill(
            child: _simImage != null
                ? CustomPaint(
                    painter: _SimImagePainter(_simImage!),
                    size: Size.infinite,
                  )
                : const ColoredBox(color: AppColors.background),
          ),
          // Gradient overlay for readability
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.0, 0.3, 0.6, 1.0],
                    colors: [
                      Colors.black.withValues(alpha: 0.3),
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.4),
                      Colors.black.withValues(alpha: 0.85),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Content
          SafeArea(
            child: FadeTransition(
              opacity: CurvedAnimation(
                parent: _entranceController,
                curve: Curves.easeOut,
              ),
              child: Column(
                children: [
                  const Spacer(flex: 3),
                  // Title
                  AnimatedBuilder(
                    animation: _glowController,
                    builder: (context, child) => child!,
                    child: ShaderMask(
                      shaderCallback: (rect) => const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Colors.white,
                          Color(0xFFFFC68A),
                          Color(0xFF77C6FF),
                        ],
                      ).createShader(rect),
                      child: Text(
                        'THE PARTICLE\nENGINE',
                        textAlign: TextAlign.center,
                        style: AppTypography.title.copyWith(
                          fontSize: compact ? 36 : 52,
                          height: 0.95,
                          letterSpacing: 3.0,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'A living pixel sandbox',
                    style: AppTypography.body.copyWith(
                      fontSize: compact ? 14 : 16,
                      color: AppColors.textSecondary.withValues(alpha: 0.7),
                      letterSpacing: 1.2,
                    ),
                  ),
                  const Spacer(flex: 2),
                  // Action buttons
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 32 : size.width * 0.2,
                    ),
                    child: Column(
                      children: [
                        // Primary action: Continue or Play
                        _MenuButton(
                          key: const ValueKey('home_play_button'),
                          label: _hasAutoSave ? 'CONTINUE' : 'PLAY',
                          icon: Icons.play_arrow_rounded,
                          accent: const Color(0xFFFFB46E),
                          large: true,
                          loading: _checkingAutoSave,
                          onTap: _hasAutoSave
                              ? _continueGame
                              : _quickStartBalancedWorld,
                        ),
                        const SizedBox(height: 12),
                        // Secondary row
                        Row(
                          children: [
                            Expanded(
                              child: _MenuButton(
                                key: const ValueKey('home_create_button'),
                                label: 'NEW WORLD',
                                icon: Icons.public,
                                accent: const Color(0xFF58B4FF),
                                onTap: () => _navigateTo(
                                  const WorldCreateScreen(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _MenuButton(
                                key: const ValueKey('home_load_button'),
                                label: 'LOAD',
                                icon: Icons.folder_open_rounded,
                                accent: const Color(0xFFFF9A62),
                                onTap: () => _navigateTo(const LoadScreen()),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _MenuButton(
                          key: const ValueKey('home_settings_button'),
                          label: 'SETTINGS',
                          icon: Icons.tune_rounded,
                          accent: const Color(0xFFC98BFF),
                          small: true,
                          onTap: () => _navigateTo(const SettingsScreen()),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: compact ? 32 : 48),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Clean, glassmorphic menu button.
class _MenuButton extends StatelessWidget {
  const _MenuButton({
    super.key,
    required this.label,
    required this.icon,
    required this.accent,
    this.large = false,
    this.small = false,
    this.loading = false,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final Color accent;
  final bool large;
  final bool small;
  final bool loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final height = large ? 56.0 : small ? 42.0 : 48.0;
    final fontSize = large ? 16.0 : small ? 12.0 : 13.0;
    final iconSize = large ? 24.0 : small ? 16.0 : 18.0;

    return SizedBox(
      height: height,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: loading ? null : onTap,
          borderRadius: BorderRadius.circular(large ? 16 : 12),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(large ? 16 : 12),
              color: large
                  ? accent.withValues(alpha: 0.18)
                  : Colors.black.withValues(alpha: 0.3),
              border: Border.all(
                color: accent.withValues(alpha: large ? 0.4 : 0.2),
                width: 0.8,
              ),
            ),
            child: Center(
              child: loading
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: accent,
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: iconSize, color: accent),
                        const SizedBox(width: 10),
                        Text(
                          label,
                          style: AppTypography.label.copyWith(
                            fontSize: fontSize,
                            letterSpacing: 1.6,
                            color: AppColors.textPrimary
                                .withValues(alpha: 0.95),
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

class _SimImagePainter extends CustomPainter {
  const _SimImagePainter(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    final dst = Rect.fromLTWH(0, 0, size.width, size.height);
    paintImage(
      canvas: canvas,
      rect: dst,
      image: image,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
      alignment: Alignment.center,
    );

    final vignette = Paint()
      ..shader = ui.Gradient.radial(
        Offset(size.width * 0.5, size.height * 0.5),
        size.longestSide * 0.7,
        [Colors.transparent, const Color(0xB0000000)],
      );
    canvas.drawRect(dst, vignette);
  }

  @override
  bool shouldRepaint(covariant _SimImagePainter oldDelegate) =>
      oldDelegate.image != image;
}
