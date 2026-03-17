import 'dart:ui';

import 'package:flutter/material.dart';

import '../../game/particle_engine_game.dart';
import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';

/// Brush modes for painting elements on the grid.
enum BrushMode {
  circle(Icons.circle_outlined, 'Circle'),
  line(Icons.linear_scale_rounded, 'Line'),
  spray(Icons.grain_rounded, 'Spray');

  const BrushMode(this.icon, this.label);
  final IconData icon;
  final String label;
}

/// Compact, glassmorphic toolbar positioned for thumb reach in landscape.
///
/// Contains brush controls, undo, clear, pause/play, day/night toggle,
/// and shake. Slides in from the right edge.
class ToolBar extends StatefulWidget {
  const ToolBar({super.key, required this.game, this.onInteraction});

  final ParticleEngineGame game;
  final VoidCallback? onInteraction;

  @override
  State<ToolBar> createState() => _ToolBarState();
}

class _ToolBarState extends State<ToolBar>
    with SingleTickerProviderStateMixin {
  int _brushSize = 3;
  BrushMode _brushMode = BrushMode.circle;
  bool _isPaused = false;
  bool _isNight = false;

  late final AnimationController _slideController;
  late final Animation<Offset> _slideAnimation;

  static const List<int> _brushSizes = [1, 3, 5];

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      vsync: this,
      duration: ParticleTheme.normalDuration,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: ParticleTheme.defaultCurve,
    ));
    _slideController.forward();
  }

  @override
  void dispose() {
    _slideController.dispose();
    super.dispose();
  }

  void _interact() => widget.onInteraction?.call();

  void _cycleBrushSize() {
    setState(() {
      final idx = _brushSizes.indexOf(_brushSize);
      _brushSize = _brushSizes[(idx + 1) % _brushSizes.length];
    });
    widget.game.sandboxWorld.sandboxComponent.brushSize = _brushSize;
    _interact();
  }

  void _cycleBrushMode() {
    setState(() {
      final idx = BrushMode.values.indexOf(_brushMode);
      _brushMode = BrushMode.values[(idx + 1) % BrushMode.values.length];
    });
    _interact();
  }

  void _togglePause() {
    setState(() => _isPaused = !_isPaused);
    widget.game.sandboxWorld.paused = _isPaused;
    _interact();
  }

  void _toggleDayNight() {
    setState(() => _isNight = !_isNight);
    widget.game.toggleDayNight();
    _interact();
  }

  void _clearGrid(BuildContext context) {
    _interact();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ParticleTheme.radiusMedium),
        ),
        title: Text('Clear World?', style: AppTypography.heading),
        content: Text(
          'This will remove all elements from the grid.',
          style: AppTypography.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel',
                style: AppTypography.button
                    .copyWith(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              widget.game.sandboxWorld.simulation.clear();
              Navigator.pop(ctx);
            },
            child: Text('Clear',
                style:
                    AppTypography.button.copyWith(color: AppColors.danger)),
          ),
        ],
      ),
    );
  }

  void _shake() {
    widget.game.sandboxWorld.simulation.doShake();
    _interact();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnimation,
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 10),
          child: ClipRRect(
            borderRadius:
                BorderRadius.circular(ParticleTheme.radiusLarge),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                width: 44,
                decoration: ParticleTheme.glassDecoration(
                  borderRadius: ParticleTheme.radiusLarge,
                ),
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Brush size
                    _BrushSizeButton(
                      size: _brushSize,
                      onTap: _cycleBrushSize,
                    ),
                    _divider(),
                    // Brush mode
                    _ToolButton(
                      icon: _brushMode.icon,
                      onTap: _cycleBrushMode,
                      tooltip: _brushMode.label,
                    ),
                    _divider(),
                    // Undo
                    _ToolButton(
                      icon: Icons.undo_rounded,
                      onTap: () => _interact(),
                      tooltip: 'Undo',
                    ),
                    _divider(),
                    // Clear
                    _ToolButton(
                      icon: Icons.delete_outline_rounded,
                      onTap: () => _clearGrid(context),
                      tooltip: 'Clear',
                      iconColor: AppColors.danger,
                      bgColor: AppColors.danger.withValues(alpha: 0.1),
                    ),
                    _divider(),
                    // Pause/Play
                    _PausePlayButton(
                      isPaused: _isPaused,
                      onTap: _togglePause,
                    ),
                    _divider(),
                    // Day/Night
                    _DayNightButton(
                      isNight: _isNight,
                      onTap: _toggleDayNight,
                    ),
                    _divider(),
                    // Shake
                    _ToolButton(
                      icon: Icons.vibration_rounded,
                      onTap: _shake,
                      tooltip: 'Shake',
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

  Widget _divider() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1, horizontal: 6),
        child: Divider(
          height: 1,
          color: Colors.white.withValues(alpha: 0.08),
        ),
      );
}

class _ToolButton extends StatefulWidget {
  const _ToolButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.iconColor,
    this.bgColor,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final Color? iconColor;
  final Color? bgColor;

  @override
  State<_ToolButton> createState() => _ToolButtonState();
}

class _ToolButtonState extends State<_ToolButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final defaultBg = _hovered
        ? AppColors.surfaceLight.withValues(alpha: 0.3)
        : null;
    return Tooltip(
      message: widget.tooltip ?? '',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(ParticleTheme.radiusSmall),
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: ParticleTheme.fastDuration,
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: widget.bgColor ?? defaultBg,
                borderRadius:
                    BorderRadius.circular(ParticleTheme.radiusSmall),
              ),
              child: Icon(
                widget.icon,
                size: 22,
                color: widget.iconColor ?? AppColors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pause/Play button with distinct color states.
class _PausePlayButton extends StatelessWidget {
  const _PausePlayButton({
    required this.isPaused,
    required this.onTap,
  });

  final bool isPaused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isPaused ? AppColors.danger : AppColors.success;
    return Tooltip(
      message: isPaused ? 'Play' : 'Pause',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(ParticleTheme.radiusSmall),
          onTap: onTap,
          child: AnimatedContainer(
            duration: ParticleTheme.fastDuration,
            curve: ParticleTheme.defaultCurve,
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius:
                  BorderRadius.circular(ParticleTheme.radiusSmall),
              border: Border.all(
                color: color.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            child: Icon(
              isPaused
                  ? Icons.play_arrow_rounded
                  : Icons.pause_rounded,
              size: 22,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

/// Day/Night toggle with sun/moon icon and matching color.
class _DayNightButton extends StatelessWidget {
  const _DayNightButton({
    required this.isNight,
    required this.onTap,
  });

  final bool isNight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isNight ? AppColors.accent : AppColors.warning;
    return Tooltip(
      message: isNight ? 'Night' : 'Day',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(ParticleTheme.radiusSmall),
          onTap: onTap,
          child: AnimatedContainer(
            duration: ParticleTheme.fastDuration,
            curve: ParticleTheme.defaultCurve,
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius:
                  BorderRadius.circular(ParticleTheme.radiusSmall),
            ),
            child: Icon(
              isNight
                  ? Icons.dark_mode_rounded
                  : Icons.light_mode_rounded,
              size: 22,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

/// Visual brush size indicator that shows a filled circle proportional to size.
class _BrushSizeButton extends StatelessWidget {
  const _BrushSizeButton({required this.size, required this.onTap});

  final int size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final diameter = 8.0 + (size * 3.0);
    return Tooltip(
      message: 'Brush: ${size}px',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(ParticleTheme.radiusSmall),
          onTap: onTap,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Center(
              child: AnimatedContainer(
                duration: ParticleTheme.fastDuration,
                curve: ParticleTheme.defaultCurve,
                width: diameter,
                height: diameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.textPrimary,
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.5),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.3),
                      blurRadius: 8,
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
