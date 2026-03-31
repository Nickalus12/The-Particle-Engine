import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../simulation/world_gen/terrain_generator.dart';
import '../../simulation/world_gen/world_config.dart';
import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';
import '../widgets/back_button.dart' show GlassBackButton;
import 'sandbox_screen.dart';

/// World creation: swipeable full-width terrain preview cards, seed input,
/// and a single large "CREATE WORLD" button.
class WorldCreateScreen extends StatefulWidget {
  const WorldCreateScreen({super.key, this.initialPresetIndex});

  final int? initialPresetIndex;

  @override
  State<WorldCreateScreen> createState() => _WorldCreateScreenState();
}

class _WorldCreateScreenState extends State<WorldCreateScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final Animation<double> _contentFade;
  late final PageController _pageController;

  late int _currentPage;
  final TextEditingController _seedController = TextEditingController();
  bool _creating = false;

  static const _presets = _WorldPreset.values;

  @override
  void initState() {
    super.initState();
    _currentPage = (widget.initialPresetIndex ?? 0).clamp(
      0,
      _presets.length - 1,
    );
    _fadeController = AnimationController(
      vsync: this,
      duration: ParticleTheme.normalDuration,
    )..forward();
    _contentFade = CurvedAnimation(
      parent: _fadeController,
      curve: ParticleTheme.defaultCurve,
    );
    _pageController = PageController(
      viewportFraction: 0.85,
      initialPage: _currentPage,
    );
    _seedController.text = Random().nextInt(1 << 30).toString();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _pageController.dispose();
    _seedController.dispose();
    super.dispose();
  }

  int get _currentSeed {
    final text = _seedController.text.trim();
    if (text.isEmpty) return Random().nextInt(1 << 30);
    return int.tryParse(text) ?? text.hashCode.abs();
  }

  void _randomizeSeed() {
    setState(() {
      _seedController.text = Random().nextInt(1 << 30).toString();
    });
  }

  _WorldPreset get _selectedPreset => _presets[_currentPage];

  WorldConfig _buildConfig() {
    final seed = _currentSeed;
    switch (_selectedPreset) {
      case _WorldPreset.blank:
        return WorldConfig(seed: seed);
      case _WorldPreset.meadow:
        return WorldConfig.meadow(seed: seed);
      case _WorldPreset.canyon:
        return WorldConfig.canyon(seed: seed);
      case _WorldPreset.island:
        return WorldConfig.island(seed: seed);
      case _WorldPreset.underground:
        return WorldConfig.underground(seed: seed);
      case _WorldPreset.random:
        return WorldConfig.random(seed: seed);
    }
  }

  void _createWorld() async {
    if (_creating) return;
    setState(() => _creating = true);

    final config = _buildConfig();

    await Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, _, _) => SandboxScreen(
          worldConfig: config,
          worldName: _selectedPreset.label,
          isBlankCanvas: _selectedPreset == _WorldPreset.blank,
        ),
        transitionsBuilder: (context, anim, _, child) {
          return FadeTransition(
            opacity: anim,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.96, end: 1.0).animate(
                CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
              ),
              child: child,
            ),
          );
        },
        transitionDuration: ParticleTheme.normalDuration,
      ),
    );

    if (mounted) setState(() => _creating = false);
  }

  @override
  Widget build(BuildContext context) {
    final preset = _selectedPreset;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxHeight < 760 || constraints.maxWidth < 420;
            final ultraCompact = constraints.maxHeight < 680;
            final seedBarHeight = ultraCompact ? 44.0 : 48.0;
            final createButtonHeight = ultraCompact ? 44.0 : 48.0;

            Widget buildSeedBar() {
              return ClipRRect(
                borderRadius: BorderRadius.circular(ParticleTheme.radiusMedium),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    height: seedBarHeight,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: AppColors.glass,
                      borderRadius: BorderRadius.circular(
                        ParticleTheme.radiusMedium,
                      ),
                      border: Border.all(
                        color: AppColors.glassBorder,
                        width: 0.5,
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.tag_rounded,
                          size: 16,
                          color: AppColors.textDim,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _seedController,
                            style: AppTypography.body.copyWith(
                              color: AppColors.textPrimary,
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            decoration: InputDecoration(
                              hintText: 'World seed...',
                              hintStyle: AppTypography.body.copyWith(
                                color: AppColors.textDim,
                              ),
                              border: InputBorder.none,
                              isDense: true,
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        _SmallIconButton(
                          icon: Icons.casino_rounded,
                          onTap: _randomizeSeed,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }

            return FadeTransition(
              opacity: _contentFade,
              child: Column(
                children: [
                  // Top bar with back button
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: ultraCompact ? 8 : 10,
                    ),
                    child: Row(
                      children: [
                        GlassBackButton(
                          onTap: () => Navigator.of(context).maybePop(),
                        ),
                        SizedBox(width: ultraCompact ? 10 : 16),
                        Text('New World', style: AppTypography.heading),
                        const Spacer(),
                        // Page indicator dots
                        Row(
                          children: List.generate(_presets.length, (i) {
                            final isActive = i == _currentPage;
                            return AnimatedContainer(
                              duration: ParticleTheme.fastDuration,
                              width: isActive ? (ultraCompact ? 16 : 20) : 6,
                              height: ultraCompact ? 5 : 6,
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(3),
                                color: isActive
                                    ? preset.color
                                    : AppColors.textDim.withValues(alpha: 0.3),
                              ),
                            );
                          }),
                        ),
                      ],
                    ),
                  ),

                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      compact ? 16 : 24,
                      4,
                      compact ? 16 : 24,
                      compact ? 8 : 12,
                    ),
                    child: _PresetInsightPanel(
                      key: const ValueKey('world_preset_insight_panel'),
                      preset: preset,
                      seed: _currentSeed,
                      compact: compact,
                    ),
                  ),

                  // Big terrain preview cards -- horizontal swipe
                  Expanded(
                    child: PageView.builder(
                      controller: _pageController,
                      itemCount: _presets.length,
                      onPageChanged: (i) => setState(() => _currentPage = i),
                      itemBuilder: (context, index) {
                        return AnimatedBuilder(
                          animation: _pageController,
                          builder: (context, child) {
                            double scale = 1.0;
                            if (_pageController.position.haveDimensions) {
                              final page = _pageController.page ?? 0.0;
                              scale = (1 - (page - index).abs() * 0.1).clamp(
                                0.85,
                                1.0,
                              );
                            }
                            return Transform.scale(scale: scale, child: child);
                          },
                          child: _PresetCard(
                            preset: _presets[index],
                            seed: _currentSeed,
                            isActive: index == _currentPage,
                          ),
                        );
                      },
                    ),
                  ),

                  // Bottom controls: seed input + create button
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      compact ? 16 : 24,
                      compact ? 6 : 8,
                      compact ? 16 : 24,
                      compact ? 10 : 12,
                    ),
                    child: compact
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              buildSeedBar(),
                              const SizedBox(height: 10),
                              _CreateWorldButton(
                                key: const ValueKey('world_create_button'),
                                onTap: _createWorld,
                                creating: _creating,
                                color: preset.color,
                                height: createButtonHeight,
                                fullWidth: true,
                              ),
                            ],
                          )
                        : Row(
                            children: [
                              Expanded(child: buildSeedBar()),
                              const SizedBox(width: 14),
                              _CreateWorldButton(
                                key: const ValueKey('world_create_button'),
                                onTap: _createWorld,
                                creating: _creating,
                                color: preset.color,
                                height: createButtonHeight,
                                fullWidth: false,
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

// =============================================================================
// Preset card with large terrain preview
// =============================================================================

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.preset,
    required this.seed,
    required this.isActive,
  });

  final _WorldPreset preset;
  final int seed;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ParticleTheme.radiusLarge),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: AnimatedContainer(
            duration: ParticleTheme.fastDuration,
            decoration: BoxDecoration(
              color: isActive
                  ? preset.color.withValues(alpha: 0.06)
                  : AppColors.glass,
              borderRadius: BorderRadius.circular(ParticleTheme.radiusLarge),
              border: Border.all(
                color: isActive
                    ? preset.color.withValues(alpha: 0.4)
                    : AppColors.glassBorder,
                width: isActive ? 1.0 : 0.5,
              ),
              boxShadow: isActive
                  ? [
                      BoxShadow(
                        color: preset.color.withValues(alpha: 0.15),
                        blurRadius: 30,
                      ),
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Terrain preview area (takes most of the card)
                Expanded(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(19),
                    ),
                    child: CustomPaint(
                      painter: _TerrainPreviewPainter(preset, seed),
                      size: Size.infinite,
                    ),
                  ),
                ),

                // Label area at bottom
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
                  child: Row(
                    children: [
                      // Icon
                      AnimatedContainer(
                        duration: ParticleTheme.fastDuration,
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: isActive
                              ? preset.color.withValues(alpha: 0.15)
                              : AppColors.surfaceLight,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isActive
                                ? preset.color.withValues(alpha: 0.3)
                                : Colors.white.withValues(alpha: 0.06),
                            width: 0.5,
                          ),
                        ),
                        child: Icon(
                          preset.icon,
                          size: 22,
                          color: isActive ? preset.color : AppColors.textDim,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              preset.label,
                              style: AppTypography.subheading.copyWith(
                                fontSize: 16,
                                color: isActive
                                    ? AppColors.textPrimary
                                    : AppColors.textSecondary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              preset.description,
                              style: AppTypography.caption.copyWith(
                                color: isActive
                                    ? AppColors.textSecondary
                                    : AppColors.textDim,
                                fontSize: 11,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
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

class _PresetInsightPanel extends StatelessWidget {
  const _PresetInsightPanel({
    super.key,
    required this.preset,
    required this.seed,
    required this.compact,
  });

  final _WorldPreset preset;
  final int seed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final config = preset.buildConfig(seed: seed);
    final metrics = preset.metrics(config);

    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: EdgeInsets.all(compact ? 14 : 16),
          decoration: BoxDecoration(
            color: AppColors.panelDark.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: preset.color.withValues(alpha: 0.22),
              width: 0.8,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      preset.tagline,
                      key: const ValueKey('world_preset_tagline'),
                      style: AppTypography.subheading.copyWith(
                        color: AppColors.textPrimary,
                        fontSize: compact ? 14 : 15,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: preset.color.withValues(alpha: 0.14),
                    ),
                    child: Text(
                      preset.climateLabel,
                      key: const ValueKey('world_preset_climate'),
                      style: AppTypography.caption.copyWith(
                        color: preset.color,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: preset.traits
                    .map(
                      (trait) => _TraitChip(label: trait, color: preset.color),
                    )
                    .toList(),
              ),
              const SizedBox(height: 12),
              compact
                  ? Column(
                      children: metrics
                          .map(
                            (metric) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _MetricStrip(
                                metric: metric,
                                color: preset.color,
                              ),
                            ),
                          )
                          .toList(),
                    )
                  : Row(
                      children: metrics
                          .map(
                            (metric) => Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: _MetricStrip(
                                  metric: metric,
                                  color: preset.color,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TraitChip extends StatelessWidget {
  const _TraitChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.white.withValues(alpha: 0.04),
        border: Border.all(color: color.withValues(alpha: 0.16), width: 0.7),
      ),
      child: Text(
        label,
        style: AppTypography.caption.copyWith(
          color: AppColors.textPrimary.withValues(alpha: 0.88),
          letterSpacing: 0.7,
        ),
      ),
    );
  }
}

class _MetricStrip extends StatelessWidget {
  const _MetricStrip({required this.metric, required this.color});

  final _WorldMetric metric;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.black.withValues(alpha: 0.16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.06),
          width: 0.7,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            metric.label,
            style: AppTypography.caption.copyWith(
              color: AppColors.textSecondary,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: metric.value,
            minHeight: 6,
            borderRadius: BorderRadius.circular(99),
            backgroundColor: Colors.white.withValues(alpha: 0.07),
            color: color,
          ),
          const SizedBox(height: 6),
          Text(
            metric.description,
            style: AppTypography.caption.copyWith(
              color: AppColors.textPrimary.withValues(alpha: 0.82),
              fontSize: 10.5,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Terrain preview painter
// =============================================================================

class _TerrainPreviewPainter extends CustomPainter {
  _TerrainPreviewPainter(this.preset, this.seed);
  final _WorldPreset preset;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final config = preset.buildConfig(seed: seed, width: 96, height: 60);
    final heightmap = preset == _WorldPreset.blank
        ? List<int>.filled(config.width, (config.height * 0.8).round())
        : TerrainGenerator.generateHeightmap(config);

    // Sky gradient
    final skyPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          preset.skyColor.withValues(alpha: 0.5),
          preset.skyColor.withValues(alpha: 0.1),
        ],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), skyPaint);

    if (preset == _WorldPreset.blank) {
      // Blank canvas: just a subtle grid
      final gridPaint = Paint()
        ..color = AppColors.textDim.withValues(alpha: 0.05)
        ..strokeWidth = 0.5;
      for (var x = 0.0; x < w; x += 20) {
        canvas.drawLine(Offset(x, 0), Offset(x, h), gridPaint);
      }
      for (var y = 0.0; y < h; y += 20) {
        canvas.drawLine(Offset(0, y), Offset(w, y), gridPaint);
      }
      return;
    }

    final segmentCount = heightmap.length - 1;

    // Background layer (distant hills)
    final bgPath = Path()..moveTo(0, h);
    for (var i = 0; i <= segmentCount; i++) {
      final x = (i / segmentCount) * w;
      final terrainY = _mapHeight(
        heightmap[i],
        config.height,
        h,
        offset: h * 0.08,
      );
      bgPath.lineTo(x, terrainY);
    }
    bgPath.lineTo(w, h);
    bgPath.close();
    canvas.drawPath(
      bgPath,
      Paint()..color = preset.color.withValues(alpha: 0.08),
    );

    // Main terrain
    final terrainPath = Path()..moveTo(0, h);
    for (var i = 0; i <= segmentCount; i++) {
      final x = (i / segmentCount) * w;
      final terrainY = _mapHeight(heightmap[i], config.height, h);
      terrainPath.lineTo(x, terrainY);
    }
    terrainPath.lineTo(w, h);
    terrainPath.close();

    final terrainPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          preset.color.withValues(alpha: 0.35),
          preset.color.withValues(alpha: 0.12),
        ],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawPath(terrainPath, terrainPaint);

    // Terrain outline
    final linePath = Path();
    for (var i = 0; i <= segmentCount; i++) {
      final x = (i / segmentCount) * w;
      final terrainY = _mapHeight(heightmap[i], config.height, h);
      if (i == 0) {
        linePath.moveTo(x, terrainY);
      } else {
        linePath.lineTo(x, terrainY);
      }
    }
    canvas.drawPath(
      linePath,
      Paint()
        ..color = preset.color.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    _paintWater(canvas, size, config, heightmap);
    _paintVegetation(canvas, size, config, heightmap);
    _paintAtmospherics(canvas, size, config);

    final rng = Random(seed + preset.index);
    for (var i = 0; i < 40; i++) {
      final fx = rng.nextDouble();
      final ix = (fx * segmentCount).floor().clamp(0, segmentCount - 1);
      final surfaceY = _mapHeight(heightmap[ix], config.height, h);
      final dotX = fx * w;
      final dotY = surfaceY + rng.nextDouble() * (h - surfaceY) * 0.6;
      final dotSize = 2.0 + rng.nextDouble() * 3.0;
      final dotAlpha = 0.15 + rng.nextDouble() * 0.25;

      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(dotX, dotY),
          width: dotSize,
          height: dotSize,
        ),
        Paint()..color = preset.color.withValues(alpha: dotAlpha),
      );
    }
  }

  void _paintWater(
    Canvas canvas,
    Size size,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final waterPaint = Paint()
      ..color = AppColors.categoryLiquids.withValues(alpha: 0.26)
      ..style = PaintingStyle.fill;
    final foamPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    final int? waterLine = config.waterLevel >= 0.3
        ? (config.height * 0.55).round()
        : null;
    final path = Path();
    bool started = false;
    for (var i = 0; i < heightmap.length; i++) {
      final x = (i / (heightmap.length - 1)) * size.width;
      final terrainY = _mapHeight(heightmap[i], config.height, size.height);
      final targetY = waterLine != null
          ? _mapHeight(waterLine, config.height, size.height)
          : terrainY - size.height * 0.015;
      if (targetY < terrainY - 1.5) {
        if (!started) {
          path.moveTo(x, targetY);
          started = true;
        } else {
          path.lineTo(x, targetY);
        }
      } else if (started) {
        path.lineTo(x, terrainY);
      }
    }
    if (started) {
      path.lineTo(size.width, size.height);
      path.lineTo(0, size.height);
      path.close();
      canvas.drawPath(path, waterPaint);
    }

    for (var i = 2; i < heightmap.length - 2; i += 8) {
      final terrainY = _mapHeight(heightmap[i], config.height, size.height);
      final nextY = _mapHeight(heightmap[i + 1], config.height, size.height);
      if ((nextY - terrainY).abs() > 8 && config.waterLevel > 0.2) {
        final x = (i / (heightmap.length - 1)) * size.width;
        canvas.drawLine(
          Offset(x, terrainY - 6),
          Offset(x, terrainY + 10),
          foamPaint,
        );
      }
    }
  }

  void _paintVegetation(
    Canvas canvas,
    Size size,
    WorldConfig config,
    List<int> heightmap,
  ) {
    if (config.vegetation <= 0.05) return;
    final rng = Random(seed + 9000 + preset.index);
    final paint = Paint()
      ..color = AppColors.categoryLife.withValues(alpha: 0.42);
    final stride = config.vegetation > 0.7 ? 5 : 8;
    for (var i = 2; i < heightmap.length - 2; i += stride) {
      if (rng.nextDouble() > config.vegetation * 0.55) continue;
      final x = (i / (heightmap.length - 1)) * size.width;
      final y = _mapHeight(heightmap[i], config.height, size.height);
      final height = 4.0 + rng.nextDouble() * 6.0;
      canvas.drawLine(
        Offset(x, y - 1),
        Offset(x, y - height),
        paint..strokeWidth = config.vegetation > 0.7 ? 2.2 : 1.5,
      );
    }
  }

  void _paintAtmospherics(Canvas canvas, Size size, WorldConfig config) {
    final rng = Random(seed + 12000 + preset.index);
    final vaporPaint = Paint();
    final count = config.waterLevel > 0.45
        ? 7
        : config.volcanicActivity > 0.2
        ? 6
        : 3;
    for (var i = 0; i < count; i++) {
      final cx = rng.nextDouble() * size.width;
      final cy = rng.nextDouble() * size.height * 0.35 + 8;
      final radius = 10.0 + rng.nextDouble() * 18.0;
      vaporPaint.shader = RadialGradient(
        colors: [
          (config.volcanicActivity > 0.25
                  ? const Color(0x66FF9B6A)
                  : Colors.white)
              .withValues(alpha: 0.13),
          Colors.transparent,
        ],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: radius));
      canvas.drawCircle(Offset(cx, cy), radius, vaporPaint);
    }
  }

  double _mapHeight(
    int cellY,
    int gridHeight,
    double canvasHeight, {
    double offset = 0,
  }) {
    return offset + (cellY / gridHeight) * canvasHeight;
  }

  @override
  bool shouldRepaint(covariant _TerrainPreviewPainter old) =>
      old.preset != preset || old.seed != seed;
}

// =============================================================================
// Presets (now includes Blank Canvas as first option)
// =============================================================================

enum _WorldPreset {
  blank(
    'Blank Canvas',
    'Empty world, build from scratch',
    Icons.crop_square_rounded,
    AppColors.textDim,
    skyColor: Color(0xFF1A1A2E),
    baseHeight: 0.85,
    amplitude: 0.0,
  ),
  meadow(
    'Meadow',
    'Gentle hills, ponds, lush vegetation',
    Icons.park_rounded,
    AppColors.categoryLife,
    skyColor: Color(0xFF4488CC),
    baseHeight: 0.55,
    amplitude: 0.15,
  ),
  canyon(
    'Canyon',
    'Dramatic cliffs, rivers, deep caves',
    Icons.terrain_rounded,
    AppColors.categorySolids,
    skyColor: Color(0xFFCC8844),
    baseHeight: 0.4,
    amplitude: 0.35,
  ),
  island(
    'Island',
    'Water surrounding a central landmass',
    Icons.water_rounded,
    AppColors.categoryLiquids,
    skyColor: Color(0xFF4477BB),
    baseHeight: 0.6,
    amplitude: 0.2,
  ),
  underground(
    'Underground',
    'Caves, lava pockets, ore deposits',
    Icons.dark_mode_rounded,
    AppColors.categoryEnergy,
    skyColor: Color(0xFF332222),
    baseHeight: 0.3,
    amplitude: 0.1,
  ),
  random(
    'Random',
    'Unique randomized parameters',
    Icons.casino_rounded,
    AppColors.categoryTools,
    skyColor: Color(0xFF664488),
    baseHeight: 0.5,
    amplitude: 0.25,
  );

  const _WorldPreset(
    this.label,
    this.description,
    this.icon,
    this.color, {
    required this.skyColor,
    required this.baseHeight,
    required this.amplitude,
  });

  final String label;
  final String description;
  final IconData icon;
  final Color color;
  final Color skyColor;
  final double baseHeight;
  final double amplitude;
  String get tagline {
    switch (this) {
      case _WorldPreset.blank:
        return 'Manual sandbox with no terrain bias.';
      case _WorldPreset.meadow:
        return 'Lowland wetlands, soft soil, and broad surface water.';
      case _WorldPreset.canyon:
        return 'Vertical relief, exposed stone, and narrow river cuts.';
      case _WorldPreset.island:
        return 'Central landmass ringed by ocean and sandy coasts.';
      case _WorldPreset.underground:
        return 'Compressed surface with dense caverns and geothermal pockets.';
      case _WorldPreset.random:
        return 'Procedural wildcard pulled from the full generator space.';
    }
  }

  String get climateLabel {
    switch (this) {
      case _WorldPreset.blank:
        return 'MANUAL';
      case _WorldPreset.meadow:
        return 'TEMPERATE';
      case _WorldPreset.canyon:
        return 'ARID';
      case _WorldPreset.island:
        return 'MARITIME';
      case _WorldPreset.underground:
        return 'SUBTERRANEAN';
      case _WorldPreset.random:
        return 'UNBOUNDED';
    }
  }

  List<String> get traits {
    switch (this) {
      case _WorldPreset.blank:
        return const ['No worldgen', 'Paint-first', 'Fast start'];
      case _WorldPreset.meadow:
        return const ['Flood basins', 'Dense vegetation', 'Soft shorelines'];
      case _WorldPreset.canyon:
        return const ['Steep walls', 'Exposed stone', 'Channel flow'];
      case _WorldPreset.island:
        return const ['Ocean edges', 'Beach bands', 'Central rise'];
      case _WorldPreset.underground:
        return const ['Cavern heavy', 'Volcanic heat', 'Ore dense'];
      case _WorldPreset.random:
        return const ['Seed driven', 'High variance', 'Discovery focused'];
    }
  }

  List<_WorldMetric> metrics(WorldConfig config) {
    return [
      _WorldMetric(
        label: 'Water',
        value: config.waterLevel.clamp(0.0, 1.0),
        description: _metricDescription(config.waterLevel),
      ),
      _WorldMetric(
        label: 'Relief',
        value: (config.terrainScale / 2.5).clamp(0.0, 1.0),
        description: _metricDescription(
          (config.terrainScale / 2.5).clamp(0.0, 1.0),
        ),
      ),
      _WorldMetric(
        label: 'Biology',
        value: config.vegetation.clamp(0.0, 1.0),
        description: _metricDescription(config.vegetation),
      ),
    ];
  }

  String _metricDescription(double value) {
    if (value >= 0.72) return 'High';
    if (value >= 0.42) return 'Medium';
    return 'Low';
  }

  WorldConfig buildConfig({
    required int seed,
    int width = 320,
    int height = 180,
  }) {
    switch (this) {
      case _WorldPreset.blank:
        return WorldConfig(seed: seed, width: width, height: height);
      case _WorldPreset.meadow:
        return WorldConfig.meadow(seed: seed, width: width, height: height);
      case _WorldPreset.canyon:
        return WorldConfig.canyon(seed: seed, width: width, height: height);
      case _WorldPreset.island:
        return WorldConfig.island(seed: seed, width: width, height: height);
      case _WorldPreset.underground:
        return WorldConfig.underground(
          seed: seed,
          width: width,
          height: height,
        );
      case _WorldPreset.random:
        return WorldConfig.random(seed: seed, width: width, height: height);
    }
  }
}

class _WorldMetric {
  const _WorldMetric({
    required this.label,
    required this.value,
    required this.description,
  });

  final String label;
  final double value;
  final String description;
}

// =============================================================================
// Shared widgets
// =============================================================================

class _CreateWorldButton extends StatefulWidget {
  const _CreateWorldButton({
    super.key,
    required this.onTap,
    required this.creating,
    required this.color,
    this.height = 48,
    this.fullWidth = false,
  });
  final VoidCallback onTap;
  final bool creating;
  final Color color;
  final double height;
  final bool fullWidth;

  @override
  State<_CreateWorldButton> createState() => _CreateWorldButtonState();
}

class _CreateWorldButtonState extends State<_CreateWorldButton> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.95 : 1.0,
          duration: ParticleTheme.fastDuration,
          child: AnimatedContainer(
            duration: ParticleTheme.fastDuration,
            height: widget.height,
            width: widget.fullWidth ? double.infinity : null,
            padding: const EdgeInsets.symmetric(horizontal: 28),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  widget.color.withValues(alpha: _hovered ? 0.3 : 0.2),
                  AppColors.accent.withValues(alpha: _hovered ? 0.2 : 0.12),
                ],
              ),
              borderRadius: BorderRadius.circular(ParticleTheme.radiusMedium),
              border: Border.all(
                color: widget.color.withValues(alpha: _hovered ? 0.6 : 0.4),
                width: 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: widget.color.withValues(alpha: _hovered ? 0.2 : 0.1),
                  blurRadius: _hovered ? 24 : 12,
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.creating)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: widget.color,
                    ),
                  )
                else
                  Icon(
                    Icons.rocket_launch_rounded,
                    size: 18,
                    color: widget.color,
                  ),
                const SizedBox(width: 10),
                Text(
                  widget.creating ? 'CREATING...' : 'CREATE WORLD',
                  style: AppTypography.button.copyWith(
                    color: widget.color,
                    letterSpacing: 1.5,
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

class _SmallIconButton extends StatefulWidget {
  const _SmallIconButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  State<_SmallIconButton> createState() => _SmallIconButtonState();
}

class _SmallIconButtonState extends State<_SmallIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: ParticleTheme.fastDuration,
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: _hovered
                ? AppColors.primary.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            widget.icon,
            size: 16,
            color: _hovered ? AppColors.primary : AppColors.textDim,
          ),
        ),
      ),
    );
  }
}
