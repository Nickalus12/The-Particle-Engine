import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../simulation/world_gen/world_config.dart';
import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';
import 'sandbox_screen.dart';

/// World creation screen: choose Blank Canvas or Procedural with presets.
///
/// Landscape layout with two columns:
/// - Left: world type selector (Blank / Procedural)
/// - Right: preset cards (for Procedural) or blank canvas description
///
/// "Create" button generates the world and navigates to SandboxScreen.
class WorldCreateScreen extends StatefulWidget {
  const WorldCreateScreen({super.key});

  @override
  State<WorldCreateScreen> createState() => _WorldCreateScreenState();
}

class _WorldCreateScreenState extends State<WorldCreateScreen>
    with TickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final Animation<double> _contentFade;

  // Staggered card entrance
  late final AnimationController _staggerController;

  bool _isProcedural = true;
  _WorldPreset _selectedPreset = _WorldPreset.meadow;
  final TextEditingController _nameController = TextEditingController();
  final FocusNode _nameFocus = FocusNode();
  bool _creating = false;

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
    _staggerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();
    _nameController.text = 'My World';
    _nameFocus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _staggerController.dispose();
    _nameController.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  Animation<double> _cardAnimation(int index) {
    final start = (index * 0.08).clamp(0.0, 0.6);
    final end = (start + 0.4).clamp(0.0, 1.0);
    return Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _staggerController,
        curve: Interval(start, end, curve: Curves.easeOutCubic),
      ),
    );
  }

  WorldConfig _buildConfig() {
    final seed = Random().nextInt(1 << 30);
    if (!_isProcedural) {
      return WorldConfig(seed: seed);
    }
    switch (_selectedPreset) {
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
    HapticFeedback.mediumImpact();

    final config = _buildConfig();
    final name = _nameController.text.trim().isEmpty
        ? 'Untitled World'
        : _nameController.text.trim();

    await Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, _, _) => SandboxScreen(
          worldConfig: config,
          worldName: name,
          isBlankCanvas: !_isProcedural,
        ),
        transitionsBuilder: (context, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: ParticleTheme.normalDuration,
      ),
    );

    if (mounted) {
      setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: FadeTransition(
          opacity: _contentFade,
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    _BackButton(
                        onTap: () => Navigator.of(context).maybePop()),
                    const SizedBox(width: 16),
                    Text('Create World', style: AppTypography.heading),
                    const Spacer(),
                  ],
                ),
              ),

              // Body
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Left column: type selector + name input
                      SizedBox(
                        width: 220,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // World name input
                            _WorldNameInput(
                              controller: _nameController,
                              focusNode: _nameFocus,
                              isFocused: _nameFocus.hasFocus,
                            ),
                            const SizedBox(height: 12),

                            // Type selector
                            _TypeToggle(
                              isProcedural: _isProcedural,
                              onChanged: (v) =>
                                  setState(() => _isProcedural = v),
                            ),
                            const SizedBox(height: 16),

                            // Description
                            if (!_isProcedural)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                child: Text(
                                  'An empty world with stone boundaries. '
                                  'Place elements freely to build your own landscape.',
                                  style: AppTypography.body.copyWith(
                                    color: AppColors.textDim,
                                  ),
                                ),
                              ),

                            const Spacer(),

                            // Create button at bottom of left column
                            _CreateButton(
                              onTap: _createWorld,
                              creating: _creating,
                              enabled: true,
                            ),
                            const SizedBox(height: 16),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),

                      // Right column: presets grid (procedural only)
                      if (_isProcedural)
                        Expanded(
                          child: AnimatedBuilder(
                            animation: _staggerController,
                            builder: (context, _) => _PresetGrid(
                              selected: _selectedPreset,
                              onSelected: (p) =>
                                  setState(() => _selectedPreset = p),
                              cardAnimation: _cardAnimation,
                            ),
                          ),
                        ),

                      // Blank canvas illustration
                      if (!_isProcedural)
                        Expanded(
                          child: Center(
                            child: _GlassPanel(
                              child: Padding(
                                padding: const EdgeInsets.all(32),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.landscape_rounded,
                                      size: 64,
                                      color: AppColors.textDim
                                          .withValues(alpha: 0.3),
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      'Blank Canvas',
                                      style: AppTypography.subheading,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Your imagination is the terrain.',
                                      style: AppTypography.body.copyWith(
                                        color: AppColors.textDim,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// World name input
// ═══════════════════════════════════════════════════════════════════════════

class _WorldNameInput extends StatelessWidget {
  const _WorldNameInput({
    required this.controller,
    required this.focusNode,
    required this.isFocused,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isFocused;

  static const int _maxLength = 24;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: ParticleTheme.fastDuration,
      decoration: BoxDecoration(
        color: AppColors.glass,
        borderRadius: BorderRadius.circular(ParticleTheme.radiusMedium),
        border: Border.all(
          color: isFocused
              ? AppColors.primary.withValues(alpha: 0.5)
              : AppColors.glassBorder,
          width: isFocused ? 1.0 : 0.5,
        ),
        boxShadow: isFocused
            ? [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  blurRadius: 16,
                  spreadRadius: -2,
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ParticleTheme.radiusMedium),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                TextField(
                  controller: controller,
                  focusNode: focusNode,
                  maxLength: _maxLength,
                  style: AppTypography.body.copyWith(
                    color: AppColors.textPrimary,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Name your world...',
                    hintStyle: AppTypography.body.copyWith(
                      color: AppColors.textDim,
                    ),
                    border: InputBorder.none,
                    isDense: true,
                    counterText: '',
                    icon: Icon(
                      Icons.edit_rounded,
                      size: 16,
                      color: isFocused ? AppColors.primary : AppColors.textDim,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    '${controller.text.length}/$_maxLength',
                    style: AppTypography.caption.copyWith(
                      color: AppColors.textDim,
                      fontSize: 9,
                    ),
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

// ═══════════════════════════════════════════════════════════════════════════
// Presets
// ═══════════════════════════════════════════════════════════════════════════

enum _WorldPreset {
  meadow(
    'Meadow',
    'Gentle rolling hills with lush vegetation',
    Icons.park_rounded,
    AppColors.categoryLife,
    [Color(0xFF064E3B), Color(0xFF10B981)],
  ),
  canyon(
    'Canyon',
    'Deep carved channels with waterfalls',
    Icons.terrain_rounded,
    AppColors.categorySolids,
    [Color(0xFF78350F), Color(0xFFF59E0B)],
  ),
  island(
    'Island',
    'Sandy beaches surrounded by ocean',
    Icons.water_rounded,
    AppColors.categoryLiquids,
    [Color(0xFF1E3A5F), Color(0xFF3B82F6)],
  ),
  underground(
    'Underground',
    'Massive cavern systems with lava',
    Icons.dark_mode_rounded,
    AppColors.categoryEnergy,
    [Color(0xFF3B0764), Color(0xFFEF4444)],
  ),
  random(
    'Random',
    'Surprise me!',
    Icons.casino_rounded,
    AppColors.categoryTools,
    [Color(0xFF4C1D95), Color(0xFF8B5CF6)],
  );

  const _WorldPreset(
    this.label,
    this.description,
    this.icon,
    this.color,
    this.gradientColors,
  );

  final String label;
  final String description;
  final IconData icon;
  final Color color;
  final List<Color> gradientColors;
}

class _PresetGrid extends StatelessWidget {
  const _PresetGrid({
    required this.selected,
    required this.onSelected,
    required this.cardAnimation,
  });

  final _WorldPreset selected;
  final ValueChanged<_WorldPreset> onSelected;
  final Animation<double> Function(int index) cardAnimation;

  @override
  Widget build(BuildContext context) {
    final presets = _WorldPreset.values;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: List.generate(presets.length, (index) {
        final preset = presets[index];
        final anim = cardAnimation(index);
        return Opacity(
          opacity: anim.value,
          child: Transform.translate(
            offset: Offset(40 * (1 - anim.value), 0),
            child: _PresetCard(
              preset: preset,
              isActive: preset == selected,
              onTap: () => onSelected(preset),
            ),
          ),
        );
      }),
    );
  }
}

class _PresetCard extends StatefulWidget {
  const _PresetCard({
    required this.preset,
    required this.isActive,
    required this.onTap,
  });

  final _WorldPreset preset;
  final bool isActive;
  final VoidCallback onTap;

  @override
  State<_PresetCard> createState() => _PresetCardState();
}

class _PresetCardState extends State<_PresetCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    final isActive = widget.isActive;
    final isHighlighted = isActive || _hovered;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          widget.onTap();
        },
        child: AnimatedScale(
          scale: _hovered ? 1.02 : 1.0,
          duration: ParticleTheme.fastDuration,
          curve: ParticleTheme.defaultCurve,
          child: AnimatedContainer(
            duration: ParticleTheme.fastDuration,
            curve: ParticleTheme.defaultCurve,
            width: 155,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: isActive
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        preset.gradientColors[0].withValues(alpha: 0.25),
                        preset.gradientColors[1].withValues(alpha: 0.08),
                      ],
                    )
                  : null,
              color: isActive
                  ? null
                  : _hovered
                      ? AppColors.glass.withValues(alpha: 0.18)
                      : AppColors.glass,
              borderRadius:
                  BorderRadius.circular(ParticleTheme.radiusMedium),
              border: Border.all(
                color: isActive
                    ? preset.color.withValues(alpha: 0.6)
                    : _hovered
                        ? AppColors.glassBorder.withValues(alpha: 0.4)
                        : AppColors.glassBorder,
                width: isActive ? 1.5 : 0.5,
              ),
              boxShadow: isActive
                  ? [
                      BoxShadow(
                        color: preset.color.withValues(alpha: 0.3),
                        blurRadius: 16,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Icon with colored background circle
                AnimatedContainer(
                  duration: ParticleTheme.fastDuration,
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    gradient: isHighlighted
                        ? LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              preset.color.withValues(alpha: 0.25),
                              preset.color.withValues(alpha: 0.10),
                            ],
                          )
                        : null,
                    color: isHighlighted
                        ? null
                        : AppColors.surfaceLight.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isHighlighted
                          ? preset.color.withValues(alpha: 0.4)
                          : Colors.white.withValues(alpha: 0.06),
                      width: 0.5,
                    ),
                  ),
                  child: Icon(
                    preset.icon,
                    size: 24,
                    color: isHighlighted ? preset.color : AppColors.textDim,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  preset.label,
                  style: AppTypography.subheading.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: isHighlighted
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  preset.description,
                  style: AppTypography.caption.copyWith(
                    color: isHighlighted
                        ? AppColors.textSecondary
                        : AppColors.textDim,
                    height: 1.3,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Create button (full-width, gradient)
// ═══════════════════════════════════════════════════════════════════════════

class _CreateButton extends StatefulWidget {
  const _CreateButton({
    required this.onTap,
    required this.creating,
    required this.enabled,
  });
  final VoidCallback onTap;
  final bool creating;
  final bool enabled;

  @override
  State<_CreateButton> createState() => _CreateButtonState();
}

class _CreateButtonState extends State<_CreateButton> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final canTap = widget.enabled && !widget.creating;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: canTap ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTapDown: canTap ? (_) => setState(() => _pressed = true) : null,
        onTapUp: canTap
            ? (_) {
                setState(() => _pressed = false);
                widget.onTap();
              }
            : null,
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1.0,
          duration: ParticleTheme.fastDuration,
          child: AnimatedContainer(
            duration: ParticleTheme.fastDuration,
            height: 48,
            decoration: BoxDecoration(
              gradient: canTap
                  ? LinearGradient(
                      colors: [
                        AppColors.primary,
                        AppColors.accent,
                      ],
                    )
                  : null,
              color: canTap ? null : AppColors.surfaceLight,
              borderRadius:
                  BorderRadius.circular(ParticleTheme.radiusMedium),
              boxShadow: canTap
                  ? [
                      BoxShadow(
                        color: AppColors.primary
                            .withValues(alpha: _hovered ? 0.5 : 0.3),
                        blurRadius: _hovered ? 20 : 12,
                      ),
                    ]
                  : null,
            ),
            child: Material(
              color: Colors.transparent,
              child: Center(
                child: widget.creating
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.rocket_launch_rounded,
                            size: 20,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Create World',
                            style: AppTypography.button.copyWith(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
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

// ═══════════════════════════════════════════════════════════════════════════
// Shared widgets
// ═══════════════════════════════════════════════════════════════════════════

class _TypeToggle extends StatelessWidget {
  const _TypeToggle({
    required this.isProcedural,
    required this.onChanged,
  });

  final bool isProcedural;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return _GlassPanel(
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Row(
          children: [
            _ToggleOption(
              label: 'Blank',
              icon: Icons.crop_square_rounded,
              isActive: !isProcedural,
              onTap: () => onChanged(false),
            ),
            const SizedBox(width: 6),
            _ToggleOption(
              label: 'Procedural',
              icon: Icons.auto_awesome_rounded,
              isActive: isProcedural,
              onTap: () => onChanged(true),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToggleOption extends StatelessWidget {
  const _ToggleOption({
    required this.label,
    required this.icon,
    required this.isActive,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: ParticleTheme.fastDuration,
          height: 40,
          decoration: BoxDecoration(
            color: isActive
                ? AppColors.primary.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius:
                BorderRadius.circular(ParticleTheme.radiusSmall),
            border: Border.all(
              color: isActive
                  ? AppColors.primary.withValues(alpha: 0.4)
                  : Colors.transparent,
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 14,
                color: isActive
                    ? AppColors.primary
                    : AppColors.textDim,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: AppTypography.label.copyWith(
                  color: isActive
                      ? AppColors.primary
                      : AppColors.textDim,
                  fontSize: 11,
                ),
              ),
            ],
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

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(ParticleTheme.radiusMedium),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: ParticleTheme.glassDecoration(
            borderRadius: ParticleTheme.radiusMedium,
          ),
          child: child,
        ),
      ),
    );
  }
}
