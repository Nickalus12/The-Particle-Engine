import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';

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
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final Animation<double> _contentFade;

  bool _isProcedural = true;
  _WorldPreset _selectedPreset = _WorldPreset.meadow;
  final TextEditingController _nameController = TextEditingController();
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
    _nameController.text = 'My World';
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _nameController.dispose();
    super.dispose();
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

  void _createWorld() {
    if (_creating) return;
    setState(() => _creating = true);

    final config = _buildConfig();
    final name = _nameController.text.trim().isEmpty
        ? 'Untitled World'
        : _nameController.text.trim();

    Navigator.of(context).push(
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
                    Text('New World', style: AppTypography.heading),
                    const Spacer(),
                    _CreateButton(
                      onTap: _createWorld,
                      creating: _creating,
                    ),
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
                            _GlassPanel(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                child: TextField(
                                  controller: _nameController,
                                  style: AppTypography.body.copyWith(
                                    color: AppColors.textPrimary,
                                  ),
                                  decoration: InputDecoration(
                                    hintText: 'World name...',
                                    hintStyle: AppTypography.body.copyWith(
                                      color: AppColors.textDim,
                                    ),
                                    border: InputBorder.none,
                                    isDense: true,
                                    icon: const Icon(
                                      Icons.edit_rounded,
                                      size: 16,
                                      color: AppColors.textDim,
                                    ),
                                  ),
                                ),
                              ),
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
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),

                      // Right column: presets grid (procedural only)
                      if (_isProcedural)
                        Expanded(
                          child: _PresetGrid(
                            selected: _selectedPreset,
                            onSelected: (p) =>
                                setState(() => _selectedPreset = p),
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
// Presets
// ═══════════════════════════════════════════════════════════════════════════

enum _WorldPreset {
  meadow('Meadow', 'Gentle hills, ponds, lush vegetation', Icons.park_rounded,
      AppColors.categoryLife),
  canyon('Canyon', 'Dramatic cliffs, rivers, deep caves',
      Icons.terrain_rounded, AppColors.categorySolids),
  island('Island', 'Water surrounding a central landmass',
      Icons.water_rounded, AppColors.categoryLiquids),
  underground('Underground', 'Caves, lava pockets, ore deposits',
      Icons.dark_mode_rounded, AppColors.categoryEnergy),
  random('Random', 'Unique randomized parameters', Icons.casino_rounded,
      AppColors.categoryTools);

  const _WorldPreset(this.label, this.description, this.icon, this.color);

  final String label;
  final String description;
  final IconData icon;
  final Color color;
}

class _PresetGrid extends StatelessWidget {
  const _PresetGrid({required this.selected, required this.onSelected});

  final _WorldPreset selected;
  final ValueChanged<_WorldPreset> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: _WorldPreset.values.map((preset) {
        final isActive = preset == selected;
        return GestureDetector(
          onTap: () => onSelected(preset),
          child: AnimatedContainer(
            duration: ParticleTheme.fastDuration,
            width: 150,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isActive
                  ? preset.color.withValues(alpha: 0.12)
                  : AppColors.glass,
              borderRadius:
                  BorderRadius.circular(ParticleTheme.radiusMedium),
              border: Border.all(
                color: isActive
                    ? preset.color.withValues(alpha: 0.5)
                    : AppColors.glassBorder,
                width: isActive ? 1.0 : 0.5,
              ),
              boxShadow: isActive
                  ? [
                      BoxShadow(
                        color: preset.color.withValues(alpha: 0.15),
                        blurRadius: 16,
                      ),
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  preset.icon,
                  size: 24,
                  color: isActive ? preset.color : AppColors.textDim,
                ),
                const SizedBox(height: 8),
                Text(
                  preset.label,
                  style: AppTypography.subheading.copyWith(
                    color: isActive
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  preset.description,
                  style: AppTypography.caption.copyWith(
                    color: AppColors.textDim,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        );
      }).toList(),
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

class _CreateButton extends StatefulWidget {
  const _CreateButton({required this.onTap, required this.creating});
  final VoidCallback onTap;
  final bool creating;

  @override
  State<_CreateButton> createState() => _CreateButtonState();
}

class _CreateButtonState extends State<_CreateButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: ParticleTheme.fastDuration,
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.15),
            borderRadius:
                BorderRadius.circular(ParticleTheme.radiusMedium),
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.4),
              width: 0.5,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.1),
                blurRadius: 16,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.creating)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.primary,
                  ),
                )
              else
                const Icon(
                  Icons.rocket_launch_rounded,
                  size: 18,
                  color: AppColors.primary,
                ),
              const SizedBox(width: 8),
              Text(
                widget.creating ? 'Creating...' : 'Create',
                style: AppTypography.button.copyWith(
                  color: AppColors.primary,
                ),
              ),
            ],
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
