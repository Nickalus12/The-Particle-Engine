import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../simulation/world_gen/world_config.dart';
import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';
import 'sandbox_screen.dart';

/// World creation: swipeable full-width terrain preview cards, seed input,
/// and a single large "CREATE WORLD" button.
class WorldCreateScreen extends StatefulWidget {
  const WorldCreateScreen({super.key});

  @override
  State<WorldCreateScreen> createState() => _WorldCreateScreenState();
}

class _WorldCreateScreenState extends State<WorldCreateScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final Animation<double> _contentFade;
  late final PageController _pageController;

  int _currentPage = 0;
  final TextEditingController _seedController = TextEditingController();
  bool _creating = false;

  static const _presets = _WorldPreset.values;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: ParticleTheme.normalDuration,
    )..forward();
    _contentFade = CurvedAnimation(
      parent: _fadeController,
      curve: ParticleTheme.defaultCurve,
    );
    _pageController = PageController(viewportFraction: 0.85);
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
        child: FadeTransition(
          opacity: _contentFade,
          child: Column(
            children: [
              // Top bar with back button
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    _BackButton(
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 16),
                    Text('New World', style: AppTypography.heading),
                    const Spacer(),
                    // Page indicator dots
                    Row(
                      children: List.generate(_presets.length, (i) {
                        final isActive = i == _currentPage;
                        return AnimatedContainer(
                          duration: ParticleTheme.fastDuration,
                          width: isActive ? 20 : 6,
                          height: 6,
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
                          scale = (1 - (page - index).abs() * 0.1)
                              .clamp(0.85, 1.0);
                        }
                        return Transform.scale(
                          scale: scale,
                          child: child,
                        );
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
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
                child: Row(
                  children: [
                    // Seed input
                    Expanded(
                      child: ClipRRect(
                        borderRadius:
                            BorderRadius.circular(ParticleTheme.radiusMedium),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                          child: Container(
                            height: 48,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              color: AppColors.glass,
                              borderRadius: BorderRadius.circular(
                                  ParticleTheme.radiusMedium),
                              border: Border.all(
                                color: AppColors.glassBorder,
                                width: 0.5,
                              ),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.tag_rounded,
                                    size: 16, color: AppColors.textDim),
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
                      ),
                    ),
                    const SizedBox(width: 14),
                    // Large create button
                    _CreateWorldButton(
                      onTap: _createWorld,
                      creating: _creating,
                      color: preset.color,
                    ),
                  ],
                ),
              ),
            ],
          ),
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
              borderRadius:
                  BorderRadius.circular(ParticleTheme.radiusLarge),
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
                          color: isActive
                              ? preset.color
                              : AppColors.textDim,
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

    // Generate multi-octave noise heightmap
    final segments = 60;
    final points = <double>[];
    for (var i = 0; i <= segments; i++) {
      points.add(_noise(i / segments));
    }

    // Background layer (distant hills)
    final bgPath = Path()..moveTo(0, h);
    for (var i = 0; i <= segments; i++) {
      final x = (i / segments) * w;
      final baseY = (preset.baseHeight + 0.1) * h;
      final terrainY = baseY + points[i] * preset.amplitude * h * 0.4;
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
    for (var i = 0; i <= segments; i++) {
      final x = (i / segments) * w;
      final baseY = preset.baseHeight * h;
      final terrainY = baseY + points[i] * preset.amplitude * h;
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
    for (var i = 0; i <= segments; i++) {
      final x = (i / segments) * w;
      final baseY = preset.baseHeight * h;
      final terrainY = baseY + points[i] * preset.amplitude * h;
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

    // Scatter some element-colored dots to represent placed elements
    final rng = Random(seed + preset.index);
    for (var i = 0; i < 40; i++) {
      final fx = rng.nextDouble();
      final ix = (fx * segments).floor().clamp(0, segments - 1);
      final baseY = preset.baseHeight * h;
      final surfaceY = baseY + points[ix] * preset.amplitude * h;
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

  double _noise(double x) {
    final s = seed;
    double val = 0;
    // 3 octaves for richer terrain
    for (var octave = 0; octave < 3; octave++) {
      final freq = 20.0 * (1 << octave);
      final amp = 1.0 / (1 << octave);
      final ix = (x * freq).floor();
      final r1 = Random(s + ix * 7 + octave * 1000).nextDouble() - 0.5;
      final r2 = Random(s + (ix + 1) * 7 + octave * 1000).nextDouble() - 0.5;
      final t = (x * freq) - ix;
      val += (r1 + (r2 - r1) * t) * amp;
    }
    return val;
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
}

// =============================================================================
// Shared widgets
// =============================================================================

class _CreateWorldButton extends StatefulWidget {
  const _CreateWorldButton({
    required this.onTap,
    required this.creating,
    required this.color,
  });
  final VoidCallback onTap;
  final bool creating;
  final Color color;

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
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 28),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  widget.color.withValues(alpha: _hovered ? 0.3 : 0.2),
                  AppColors.accent.withValues(alpha: _hovered ? 0.2 : 0.12),
                ],
              ),
              borderRadius:
                  BorderRadius.circular(ParticleTheme.radiusMedium),
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

class _BackButton extends StatefulWidget {
  const _BackButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_BackButton> createState() => _BackButtonState();
}

class _BackButtonState extends State<_BackButton> {
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
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: _hovered
                ? AppColors.glass.withValues(alpha: 0.3)
                : AppColors.glass,
            shape: BoxShape.circle,
            border: Border.all(
              color: _hovered
                  ? AppColors.glassBorder.withValues(alpha: 0.4)
                  : AppColors.glassBorder,
              width: 0.5,
            ),
          ),
          child: Icon(
            Icons.arrow_back_rounded,
            size: 18,
            color: _hovered ? AppColors.textPrimary : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
