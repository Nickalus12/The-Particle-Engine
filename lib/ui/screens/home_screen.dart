import 'dart:math';
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
import '../theme/particle_theme.dart';
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
  late final AnimationController _atmosphereController;
  late final Animation<double> _heroGlow;

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
      duration: const Duration(milliseconds: 1600),
    )..forward();

    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    )..repeat(reverse: true);
    _heroGlow = Tween<double>(begin: 0.35, end: 1.0).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );

    _atmosphereController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    )..repeat();

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
    _atmosphereController.dispose();
    _simImage?.dispose();
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

  void _openWorldCreate({int initialPresetIndex = 0}) {
    _navigateTo(WorldCreateScreen(initialPresetIndex: initialPresetIndex));
  }

  void _quickStartBalancedWorld() {
    _navigateTo(
      SandboxScreen(
        worldConfig: WorldConfig.meadow(seed: 424242),
        worldName: 'Quick Start Meadow',
      ),
    );
  }

  void _quickStartBlankCanvas() {
    _navigateTo(
      const SandboxScreen(worldName: 'Quick Start Blank', isBlankCanvas: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final bool compact = size.width < 980;
    final bool veryCompact = size.width < 700;
    final double heroWidth = compact
        ? min(size.width - 32, 720.0)
        : min(size.width * 0.48, 760.0);
    final double headlineSize = veryCompact
        ? 42
        : compact
        ? 58
        : 76;
    final double contentTop = veryCompact ? 20 : 28;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: _simImage != null
                ? CustomPaint(
                    painter: _SimImagePainter(_simImage!),
                    size: Size.infinite,
                  )
                : const ColoredBox(color: AppColors.background),
          ),
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _atmosphereController,
              builder: (context, _) => CustomPaint(
                painter: _MenuAtmospherePainter(
                  progress: _atmosphereController.value,
                  glow: _heroGlow.value,
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      const Color(0xDE05060C),
                      AppColors.background.withValues(alpha: 0.68),
                      const Color(0xE60C1018),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.32, -0.18),
                    radius: 1.1,
                    colors: [
                      Colors.white.withValues(alpha: 0.03),
                      Colors.transparent,
                      AppColors.background.withValues(alpha: 0.82),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1500),
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    veryCompact ? 16 : 28,
                    contentTop,
                    veryCompact ? 16 : 28,
                    20,
                  ),
                  child: FadeTransition(
                    opacity: CurvedAnimation(
                      parent: _entranceController,
                      curve: Curves.easeOut,
                    ),
                    child: AnimatedBuilder(
                      animation: _glowController,
                      builder: (context, child) => Transform.translate(
                        offset: Offset(0, (1 - _entranceController.value) * 26),
                        child: child,
                      ),
                      child: compact
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildHero(
                                  context,
                                  heroWidth,
                                  headlineSize,
                                  compact,
                                  veryCompact,
                                ),
                                const SizedBox(height: 22),
                                _buildActionsCard(context, compact: true),
                              ],
                            )
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: heroWidth,
                                  child: _buildHero(
                                    context,
                                    heroWidth,
                                    headlineSize,
                                    compact,
                                    veryCompact,
                                  ),
                                ),
                                const SizedBox(width: 26),
                                Expanded(
                                  child: _buildActionsCard(
                                    context,
                                    compact: false,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHero(
    BuildContext context,
    double heroWidth,
    double headlineSize,
    bool compact,
    bool veryCompact,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildEyebrow(),
        const SizedBox(height: 18),
        ShaderMask(
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white,
              const Color(0xFFFFC68A),
              const Color(0xFF77C6FF),
            ],
          ).createShader(rect),
          child: Text(
            'A WORLD\nTHAT MOVES',
            style: AppTypography.title.copyWith(
              fontSize: headlineSize,
              height: 0.92,
              color: Colors.white,
              letterSpacing: 1.8,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(height: 18),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: min(heroWidth, 620.0)),
          child: Text(
            'Shape terrain, release water, ignite vents, and watch a reactive world settle into storms, rivers, erosion, and living ecosystems.',
            style: AppTypography.subheading.copyWith(
              fontSize: veryCompact ? 15 : 17,
              height: 1.55,
              color: AppColors.textPrimary.withValues(alpha: 0.86),
            ),
          ),
        ),
        const SizedBox(height: 22),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: const [
            _MetricBadge(value: '176x100', label: 'Live Menu Sim'),
            _MetricBadge(value: 'Waterfall', label: 'Hydrology Showcase'),
            _MetricBadge(value: 'Vents', label: 'Heat + Atmospherics'),
          ],
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: const [
            _InfoPill(
              icon: Icons.water_drop_outlined,
              label: 'Fluid-driven terrain',
            ),
            _InfoPill(icon: Icons.air, label: 'Reactive clouds and vapor'),
            _InfoPill(icon: Icons.landscape_outlined, label: 'Dynamic geology'),
          ],
        ),
      ],
    );
  }

  Widget _buildEyebrow() {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.black.withValues(alpha: 0.22),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.12),
          width: 0.8,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFFF7F50),
                boxShadow: ParticleTheme.glowShadow(const Color(0xFFFF7F50)),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'SIMULATION SHOWCASE',
              style: AppTypography.label.copyWith(
                letterSpacing: 1.8,
                color: AppColors.textPrimary.withValues(alpha: 0.92),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionsCard(BuildContext context, {required bool compact}) {
    final bool canContinue = _hasAutoSave && !_checkingAutoSave;

    return ParticleTheme.atmosphericPanel(
      accent: const Color(0xFF4FA7FF),
      borderRadius: 30,
      blurAmount: 24,
      padding: EdgeInsets.all(compact ? 18 : 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Choose your next world',
            style: AppTypography.heading.copyWith(fontSize: compact ? 24 : 28),
          ),
          const SizedBox(height: 8),
          Text(
            'Resume a living sandbox, jump into a curated terrain preset, or browse your saved worlds with a clearer launch flow built for mobile.',
            style: AppTypography.body.copyWith(fontSize: 14, height: 1.55),
          ),
          const SizedBox(height: 16),
          _QuickLaunchStrip(
            canContinue: canContinue,
            checkingAutoSave: _checkingAutoSave,
            onQuickStart: _quickStartBalancedWorld,
            onQuickBlank: _quickStartBlankCanvas,
            onContinue: _continueGame,
            onLoad: () => _navigateTo(const LoadScreen()),
          ),
          const SizedBox(height: 20),
          _ResumeSpotlight(
            key: const ValueKey('home_resume_spotlight'),
            canContinue: canContinue,
            checkingAutoSave: _checkingAutoSave,
            onContinue: _continueGame,
            onBrowse: () => _navigateTo(const LoadScreen()),
            onCreate: () => _openWorldCreate(initialPresetIndex: 1),
          ),
          const SizedBox(height: 18),
          _SectionEyebrow(
            label: 'WORLD MOODS',
            accent: const Color(0xFF79C7FF),
          ),
          const SizedBox(height: 12),
          _WorldMoodGrid(
            onSelectPreset: (presetIndex) =>
                _openWorldCreate(initialPresetIndex: presetIndex),
          ),
          const SizedBox(height: 18),
          _SessionStatusStrip(
            canContinue: canContinue,
            checkingAutoSave: _checkingAutoSave,
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              final bool stack = constraints.maxWidth < 560;
              final children = [
                Expanded(
                  child: _LaunchFeatureCard(
                    key: const ValueKey('home_create_button'),
                    title: 'Create World',
                    subtitle:
                        'Build a fresh simulation with preset terrain cards.',
                    accent: const Color(0xFF58B4FF),
                    icon: Icons.public,
                    onTap: () => _openWorldCreate(initialPresetIndex: 1),
                  ),
                ),
                Expanded(
                  child: _LaunchFeatureCard(
                    key: const ValueKey('home_load_button'),
                    title: 'Saved Worlds',
                    subtitle:
                        'Browse recent runs, rename slots, and jump back in fast.',
                    accent: const Color(0xFFFF9A62),
                    icon: Icons.folder_open_rounded,
                    onTap: () => _navigateTo(const LoadScreen()),
                  ),
                ),
                Expanded(
                  child: _LaunchFeatureCard(
                    key: const ValueKey('home_settings_button'),
                    title: 'Settings',
                    subtitle:
                        'Tune performance, controls, accessibility, and audio.',
                    accent: const Color(0xFFC98BFF),
                    icon: Icons.tune,
                    onTap: () => _navigateTo(const SettingsScreen()),
                  ),
                ),
              ];

              if (stack) {
                return Column(
                  children: [
                    for (int i = 0; i < children.length; i++) ...[
                      SizedBox(width: double.infinity, child: children[i]),
                      if (i != children.length - 1) const SizedBox(height: 10),
                    ],
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  children[0],
                  const SizedBox(width: 10),
                  children[1],
                  const SizedBox(width: 10),
                  children[2],
                ],
              );
            },
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: const [
              _FooterBadge(label: 'Offline-first'),
              _FooterBadge(label: 'Reactive Materials'),
              _FooterBadge(label: 'Mobile Optimized'),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionEyebrow extends StatelessWidget {
  const _SectionEyebrow({required this.label, required this.accent});

  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: accent,
            boxShadow: ParticleTheme.glowShadow(accent),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: AppTypography.label.copyWith(
            letterSpacing: 1.6,
            color: AppColors.textPrimary.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }
}

class _ResumeSpotlight extends StatelessWidget {
  const _ResumeSpotlight({
    super.key,
    required this.canContinue,
    required this.checkingAutoSave,
    required this.onContinue,
    required this.onBrowse,
    required this.onCreate,
  });

  final bool canContinue;
  final bool checkingAutoSave;
  final VoidCallback onContinue;
  final VoidCallback onBrowse;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final accent = canContinue
        ? const Color(0xFFFFB46E)
        : const Color(0xFF76C9FF);

    return Container(
      key: const ValueKey('home_resume_spotlight'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          colors: [
            accent.withValues(alpha: 0.18),
            Colors.black.withValues(alpha: 0.12),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: accent.withValues(alpha: 0.28), width: 0.9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(alpha: 0.15),
                ),
                child: Icon(
                  canContinue
                      ? Icons.play_arrow_rounded
                      : Icons.explore_rounded,
                  color: accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      canContinue
                          ? 'Resume the latest simulation'
                          : 'Start a guided world quickly',
                      style: AppTypography.subheading.copyWith(fontSize: 16),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      checkingAutoSave
                          ? 'Checking your latest save and session context.'
                          : canContinue
                          ? 'Autosave is ready, and your recent run can be reopened immediately.'
                          : 'No autosave was found, so the fastest path is creating a curated world or browsing saves.',
                      style: AppTypography.caption.copyWith(
                        fontSize: 11.5,
                        height: 1.45,
                        color: AppColors.textSecondary.withValues(alpha: 0.92),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _SpotlightAction(
                key: const ValueKey('home_resume_primary_button'),
                label: canContinue ? 'Continue Autosave' : 'Create Meadow',
                icon: canContinue
                    ? Icons.play_circle_fill_rounded
                    : Icons.park_rounded,
                accent: accent,
                enabled: !checkingAutoSave,
                onTap: canContinue ? onContinue : onCreate,
              ),
              _SpotlightAction(
                key: const ValueKey('home_resume_browse_button'),
                label: 'Browse Worlds',
                icon: Icons.folder_open_rounded,
                accent: const Color(0xFFFFA265),
                onTap: onBrowse,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SpotlightAction extends StatelessWidget {
  const _SpotlightAction({
    super.key,
    required this.label,
    required this.icon,
    required this.accent,
    this.enabled = true,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final Color accent;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.65,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: enabled ? onTap : null,
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: Colors.black.withValues(alpha: 0.2),
              border: Border.all(
                color: accent.withValues(alpha: 0.32),
                width: 0.8,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: accent),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: AppTypography.caption.copyWith(
                    fontSize: 11,
                    color: AppColors.textPrimary.withValues(alpha: 0.92),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WorldMoodGrid extends StatelessWidget {
  const _WorldMoodGrid({required this.onSelectPreset});

  final ValueChanged<int> onSelectPreset;

  @override
  Widget build(BuildContext context) {
    const moods =
        <
          ({
            String label,
            String subtitle,
            IconData icon,
            Color accent,
            int presetIndex,
          })
        >[
          (
            label: 'Meadow',
            subtitle: 'Friendly terrain for balanced colony starts.',
            icon: Icons.park_rounded,
            accent: Color(0xFF86D27A),
            presetIndex: 1,
          ),
          (
            label: 'Canyon',
            subtitle: 'Vertical routes, erosion, and dramatic pressure.',
            icon: Icons.terrain_rounded,
            accent: Color(0xFFE8A15A),
            presetIndex: 2,
          ),
          (
            label: 'Island',
            subtitle: 'Tight coastlines and exposed survival space.',
            icon: Icons.waves_rounded,
            accent: Color(0xFF66C7FF),
            presetIndex: 3,
          ),
          (
            label: 'Underground',
            subtitle: 'Heat pockets, caves, and constrained expansion.',
            icon: Icons.hive_rounded,
            accent: Color(0xFFE1C06A),
            presetIndex: 4,
          ),
          (
            label: 'Blank',
            subtitle: 'Pure sandbox for building from nothing.',
            icon: Icons.grid_on_rounded,
            accent: Color(0xFFC6D2E5),
            presetIndex: 0,
          ),
        ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool stack = constraints.maxWidth < 520;
        if (stack) {
          return Column(
            children: [
              for (int i = 0; i < moods.length; i++) ...[
                _WorldMoodCard(
                  key: ValueKey(
                    'home_world_mood_${moods[i].label.toLowerCase()}',
                  ),
                  label: moods[i].label,
                  subtitle: moods[i].subtitle,
                  icon: moods[i].icon,
                  accent: moods[i].accent,
                  onTap: () => onSelectPreset(moods[i].presetIndex),
                ),
                if (i != moods.length - 1) const SizedBox(height: 10),
              ],
            ],
          );
        }

        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: moods
              .map(
                (mood) => SizedBox(
                  width: constraints.maxWidth >= 740
                      ? (constraints.maxWidth - 20) / 3
                      : (constraints.maxWidth - 10) / 2,
                  child: _WorldMoodCard(
                    key: ValueKey(
                      'home_world_mood_${mood.label.toLowerCase()}',
                    ),
                    label: mood.label,
                    subtitle: mood.subtitle,
                    icon: mood.icon,
                    accent: mood.accent,
                    onTap: () => onSelectPreset(mood.presetIndex),
                  ),
                ),
              )
              .toList(),
        );
      },
    );
  }
}

class _WorldMoodCard extends StatelessWidget {
  const _WorldMoodCard({
    super.key,
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.accent,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final IconData icon;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            color: Colors.black.withValues(alpha: 0.16),
            border: Border.all(
              color: accent.withValues(alpha: 0.24),
              width: 0.8,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: accent.withValues(alpha: 0.16),
                ),
                child: Icon(icon, color: accent, size: 19),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: AppTypography.subheading.copyWith(fontSize: 14),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: AppTypography.caption.copyWith(
                        fontSize: 10.5,
                        height: 1.35,
                        color: AppColors.textSecondary.withValues(alpha: 0.88),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_rounded,
                color: accent.withValues(alpha: 0.92),
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LaunchFeatureCard extends StatelessWidget {
  const _LaunchFeatureCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final Color accent;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            color: Colors.black.withValues(alpha: 0.16),
            border: Border.all(
              color: accent.withValues(alpha: 0.24),
              width: 0.8,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: accent, size: 18),
              const SizedBox(height: 10),
              Text(
                title,
                style: AppTypography.subheading.copyWith(fontSize: 14),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: AppTypography.caption.copyWith(
                  fontSize: 10.5,
                  height: 1.35,
                  color: AppColors.textSecondary.withValues(alpha: 0.88),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickLaunchStrip extends StatelessWidget {
  const _QuickLaunchStrip({
    required this.canContinue,
    required this.checkingAutoSave,
    required this.onQuickStart,
    required this.onQuickBlank,
    required this.onContinue,
    required this.onLoad,
  });

  final bool canContinue;
  final bool checkingAutoSave;
  final VoidCallback onQuickStart;
  final VoidCallback onQuickBlank;
  final VoidCallback onContinue;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _QuickLaunchChip(
          key: const ValueKey('home_quick_start_button'),
          label: 'Quick Start',
          icon: Icons.flash_on_rounded,
          accent: const Color(0xFF50C2FF),
          onTap: onQuickStart,
        ),
        _QuickLaunchChip(
          key: const ValueKey('home_quick_blank_button'),
          label: 'Blank Canvas',
          icon: Icons.grid_on_rounded,
          accent: const Color(0xFFB6E06E),
          onTap: onQuickBlank,
        ),
        _QuickLaunchChip(
          key: const ValueKey('home_quick_continue_button'),
          label: canContinue ? 'Continue' : 'Saved Worlds',
          icon: canContinue
              ? Icons.play_circle_fill_rounded
              : Icons.folder_copy_rounded,
          accent: const Color(0xFFFFA265),
          enabled: !checkingAutoSave,
          trailing: checkingAutoSave
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                )
              : null,
          onTap: canContinue ? onContinue : onLoad,
        ),
      ],
    );
  }
}

class _QuickLaunchChip extends StatelessWidget {
  const _QuickLaunchChip({
    super.key,
    required this.label,
    required this.icon,
    required this.accent,
    this.enabled = true,
    this.trailing,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final Color accent;
  final bool enabled;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.65,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(999),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: Colors.black.withValues(alpha: 0.26),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.08),
                width: 0.8,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accent.withValues(alpha: 0.16),
                  ),
                  child: Icon(icon, size: 13, color: accent),
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: AppTypography.caption.copyWith(
                    fontSize: 11.5,
                    letterSpacing: 0.45,
                    color: AppColors.textPrimary.withValues(alpha: 0.9),
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionStatusStrip extends StatelessWidget {
  const _SessionStatusStrip({
    required this.canContinue,
    required this.checkingAutoSave,
  });

  final bool canContinue;
  final bool checkingAutoSave;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('home_session_status_strip'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.black.withValues(alpha: 0.18),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 0.8,
        ),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          _StatusCell(
            icon: Icons.save_rounded,
            label: 'Autosave',
            value: checkingAutoSave
                ? 'Checking...'
                : canContinue
                ? 'Ready'
                : 'Not found',
            accent: canContinue
                ? const Color(0xFF66E699)
                : const Color(0xFFFFB07A),
          ),
          const _StatusCell(
            icon: Icons.phone_android_rounded,
            label: 'Mobile Profile',
            value: 'Balanced 60fps',
            accent: Color(0xFF67B8FF),
          ),
          const _StatusCell(
            icon: Icons.pets_rounded,
            label: 'Creatures',
            value: 'Ants Recovery Enabled',
            accent: Color(0xFFE2C072),
          ),
        ],
      ),
    );
  }
}

class _StatusCell extends StatelessWidget {
  const _StatusCell({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: accent.withValues(alpha: 0.95)),
        const SizedBox(width: 6),
        Text(
          '$label: ',
          style: AppTypography.caption.copyWith(
            fontSize: 11,
            color: AppColors.textSecondary.withValues(alpha: 0.95),
          ),
        ),
        Text(
          value,
          style: AppTypography.caption.copyWith(
            fontSize: 11,
            color: AppColors.textPrimary.withValues(alpha: 0.9),
          ),
        ),
      ],
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

class _MenuAtmospherePainter extends CustomPainter {
  const _MenuAtmospherePainter({required this.progress, required this.glow});

  final double progress;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final emberPaint = Paint()..style = PaintingStyle.fill;
    final wavePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0x66A7D9FF);

    for (int i = 0; i < 9; i++) {
      final t = (progress + i * 0.11) % 1.0;
      final dx = size.width * (0.12 + (i * 0.09)) + sin(t * pi * 2 + i) * 18;
      final dy =
          size.height * (0.18 + (i.isEven ? 0.12 : 0.2)) +
          cos(t * pi * 2 + i * 0.7) * 30;
      final radius = 70 + (i % 4) * 18 + glow * 10;
      emberPaint.shader = ui.Gradient.radial(Offset(dx, dy), radius, [
        (i.isEven ? const Color(0x40FF8A4C) : const Color(0x303DB5FF))
            .withValues(alpha: 0.16 + glow * 0.07),
        Colors.transparent,
      ]);
      canvas.drawCircle(Offset(dx, dy), radius, emberPaint);
    }

    for (int i = 0; i < 4; i++) {
      final y = size.height * (0.58 + i * 0.08);
      final path = Path()..moveTo(0, y);
      for (double x = 0; x <= size.width; x += 14) {
        final offset =
            sin((x / size.width) * pi * 3 + progress * pi * 2 + i) *
            (7 + i * 2);
        path.lineTo(x, y + offset);
      }
      wavePaint.color =
          (i.isEven ? const Color(0x665FC5FF) : const Color(0x55FF9E57))
              .withValues(alpha: 0.22 - i * 0.03);
      canvas.drawPath(path, wavePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _MenuAtmospherePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.glow != glow;
  }
}

class _LargeMenuButton extends StatelessWidget {
  const _LargeMenuButton({
    super.key,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.icon,
    this.enabled = true,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final Color accent;
  final IconData icon;
  final bool enabled;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.6,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(24),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              color: Colors.black.withValues(alpha: 0.18),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.09),
                width: 0.8,
              ),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.16),
                  blurRadius: 24,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
              child: Row(
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          accent.withValues(alpha: 0.92),
                          accent.withValues(alpha: 0.38),
                        ],
                      ),
                    ),
                    child: Icon(icon, color: Colors.white),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: AppTypography.subheading.copyWith(
                            fontSize: 17,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: AppTypography.body.copyWith(
                            fontSize: 13,
                            color: AppColors.textSecondary.withValues(
                              alpha: 0.94,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  trailing ??
                      Icon(
                        Icons.arrow_forward_rounded,
                        color: Colors.white.withValues(alpha: 0.86),
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

class _MetricBadge extends StatelessWidget {
  const _MetricBadge({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Colors.black.withValues(alpha: 0.24),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: AppTypography.stat.copyWith(
              fontSize: 18,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: AppTypography.caption.copyWith(
              letterSpacing: 0.8,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.black.withValues(alpha: 0.2),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 0.8,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: Colors.white.withValues(alpha: 0.8)),
            const SizedBox(width: 8),
            Text(
              label,
              style: AppTypography.caption.copyWith(
                fontSize: 11,
                color: AppColors.textPrimary.withValues(alpha: 0.84),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FooterBadge extends StatelessWidget {
  const _FooterBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.white.withValues(alpha: 0.03),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.06),
          width: 0.8,
        ),
      ),
      child: Text(
        label,
        style: AppTypography.caption.copyWith(
          fontSize: 10.5,
          letterSpacing: 0.9,
          color: AppColors.textSecondary.withValues(alpha: 0.9),
        ),
      ),
    );
  }
}
