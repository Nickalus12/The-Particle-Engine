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

/// Right-side collapsible vertical tool panel with brush controls,
/// simulation toggles, and world actions.
class ToolBar extends StatefulWidget {
  const ToolBar({super.key, required this.game, this.onInteraction});

  final ParticleEngineGame game;
  final VoidCallback? onInteraction;

  @override
  State<ToolBar> createState() => _ToolBarState();
}

class _ToolBarState extends State<ToolBar>
    with TickerProviderStateMixin {
  int _brushSize = 3;
  BrushMode _brushMode = BrushMode.circle;
  bool _isPaused = false;
  bool _isNight = false;
  bool _collapsed = false;

  late final AnimationController _slideController;
  late final Animation<Offset> _slideAnimation;
  late final AnimationController _collapseController;

  static const List<int> _brushSizes = [1, 3, 5, 8, 12];

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

    _collapseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: 1.0, // start expanded
    );
  }

  @override
  void dispose() {
    _slideController.dispose();
    _collapseController.dispose();
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

  void _toggleCollapse() {
    setState(() => _collapsed = !_collapsed);
    if (_collapsed) {
      _collapseController.reverse();
    } else {
      _collapseController.forward();
    }
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
    // Multiple passes for a more dramatic shake
    final sim = widget.game.sandboxWorld.simulation;
    sim.doShake();
    sim.doShake();
    sim.doShake();
    _interact();
  }

  void _openPeriodicTable() {
    widget.game.overlays.add(ParticleEngineGame.overlayPeriodicTable);
    _interact();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnimation,
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 6, top: 8, bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Collapse/expand toggle
              _CollapseToggle(
                collapsed: _collapsed,
                onTap: _toggleCollapse,
              ),
              const SizedBox(height: 4),
              // Main panel
              SizeTransition(
                sizeFactor: CurvedAnimation(
                  parent: _collapseController,
                  curve: Curves.easeOutCubic,
                ),
                axisAlignment: -1.0,
                child: ClipRRect(
                  borderRadius:
                      BorderRadius.circular(ParticleTheme.radiusLarge),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: Container(
                      width: 64,
                      decoration: BoxDecoration(
                        color: AppColors.panelDark,
                        borderRadius: BorderRadius.circular(ParticleTheme.radiusLarge),
                        border: Border.all(
                          color: AppColors.panelBorder,
                          width: 0.5,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x40000000),
                            blurRadius: 24,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // -- Brush --
                          _BrushSizeButton(
                            size: _brushSize,
                            onTap: _cycleBrushSize,
                          ),
                          const SizedBox(height: 2),
                          _ToolIcon(
                            icon: _brushMode.icon,
                            onTap: _cycleBrushMode,
                            tooltip: _brushMode.label,
                          ),
                          _divider(),
                          // -- Simulation --
                          _PausePlayIcon(
                            isPaused: _isPaused,
                            onTap: _togglePause,
                          ),
                          const SizedBox(height: 2),
                          _DayNightIcon(
                            isNight: _isNight,
                            onTap: _toggleDayNight,
                          ),
                          _divider(),
                          // -- Actions --
                          _ToolIcon(
                            icon: Icons.vibration_rounded,
                            onTap: _shake,
                            tooltip: 'Shake',
                          ),
                          const SizedBox(height: 2),
                          _ToolIcon(
                            icon: Icons.science_rounded,
                            onTap: _openPeriodicTable,
                            tooltip: 'Periodic Table',
                            iconColor: const Color(0xFF80B0E0),
                          ),
                          const SizedBox(height: 2),
                          _ToolIcon(
                            icon: Icons.delete_outline_rounded,
                            onTap: () => _clearGrid(context),
                            tooltip: 'Clear',
                            iconColor: AppColors.danger,
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
    );
  }

  Widget _divider() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 8),
        child: Container(
          height: 0.5,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.white.withValues(alpha: 0.0),
                Colors.white.withValues(alpha: 0.10),
                Colors.white.withValues(alpha: 0.0),
              ],
            ),
          ),
        ),
      );
}

/// Small pill-shaped toggle to collapse/expand the toolbar.
class _CollapseToggle extends StatelessWidget {
  const _CollapseToggle({required this.collapsed, required this.onTap});
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: AppColors.panelDark.withValues(alpha: 0.8),
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.panelBorder, width: 0.5),
        ),
        child: Icon(
          collapsed ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
          size: 16,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

/// Compact icon button for the toolbar (no label, just icon + tooltip).
class _ToolIcon extends StatefulWidget {
  const _ToolIcon({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.iconColor,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final Color? iconColor;

  @override
  State<_ToolIcon> createState() => _ToolIconState();
}

class _ToolIconState extends State<_ToolIcon> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip ?? '',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: ParticleTheme.fastDuration,
            width: 48,
            height: 36,
            decoration: BoxDecoration(
              color: _hovered
                  ? AppColors.surfaceLight.withValues(alpha: 0.3)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              widget.icon,
              size: 20,
              color: widget.iconColor ?? (_hovered ? AppColors.textPrimary : AppColors.textSecondary),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact pause/play icon.
class _PausePlayIcon extends StatelessWidget {
  const _PausePlayIcon({required this.isPaused, required this.onTap});
  final bool isPaused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isPaused ? AppColors.danger : AppColors.success;
    return Tooltip(
      message: isPaused ? 'Play' : 'Pause',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: ParticleTheme.fastDuration,
          width: 48,
          height: 36,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.3), width: 0.5),
          ),
          child: Icon(
            isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
            size: 22,
            color: color,
          ),
        ),
      ),
    );
  }
}

/// Compact day/night toggle icon.
class _DayNightIcon extends StatelessWidget {
  const _DayNightIcon({required this.isNight, required this.onTap});
  final bool isNight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isNight ? AppColors.accent : AppColors.warning;
    return Tooltip(
      message: isNight ? 'Night' : 'Day',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: ParticleTheme.fastDuration,
          width: 48,
          height: 36,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            isNight ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
            size: 20,
            color: color,
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
    final diameter = 4.0 + (size * 1.5);
    return Tooltip(
      message: 'Brush: ${size}px',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 48,
          height: 36,
          alignment: Alignment.center,
          child: Container(
            width: diameter.clamp(6, 28),
            height: diameter.clamp(6, 28),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.textPrimary.withValues(alpha: 0.7),
              border: Border.all(
                color: AppColors.textPrimary,
                width: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
