import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
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

/// Right-side vertical tool panel with brush controls, simulation toggles,
/// and world actions. Slides in from the right edge with staggered sections.
///
/// Narrow (80px) glassmorphic panel mirroring the left element palette.
class ToolBar extends StatefulWidget {
  const ToolBar({super.key, required this.game, this.onInteraction});

  final ParticleEngineGame game;
  final VoidCallback? onInteraction;

  @override
  State<ToolBar> createState() => _ToolBarState();
}

class _ToolBarState extends State<ToolBar> with TickerProviderStateMixin {
  int _brushSize = 3;
  BrushMode _brushMode = BrushMode.circle;
  bool _isPaused = false;
  bool _isNight = false;
  bool _confirmClear = false;
  bool _isShaking = false;

  late final AnimationController _slideController;
  late final Animation<Offset> _slideAnimation;

  // Staggered entrance controllers for each section.
  late final AnimationController _brushSectionController;
  late final AnimationController _actionsSectionController;
  late final AnimationController _worldSectionController;
  late final Animation<double> _brushSectionAnim;
  late final Animation<double> _actionsSectionAnim;
  late final Animation<double> _worldSectionAnim;

  @override
  void initState() {
    super.initState();

    // Main slide-in.
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutBack,
    ));

    // Staggered section fade/scale.
    _brushSectionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _actionsSectionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _worldSectionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _brushSectionAnim = CurvedAnimation(
      parent: _brushSectionController,
      curve: Curves.easeOutCubic,
    );
    _actionsSectionAnim = CurvedAnimation(
      parent: _actionsSectionController,
      curve: Curves.easeOutCubic,
    );
    _worldSectionAnim = CurvedAnimation(
      parent: _worldSectionController,
      curve: Curves.easeOutCubic,
    );

    // Start entrance sequence.
    _slideController.forward();
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) _brushSectionController.forward();
    });
    Future.delayed(const Duration(milliseconds: 250), () {
      if (mounted) _actionsSectionController.forward();
    });
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) _worldSectionController.forward();
    });
  }

  @override
  void dispose() {
    _slideController.dispose();
    _brushSectionController.dispose();
    _actionsSectionController.dispose();
    _worldSectionController.dispose();
    super.dispose();
  }

  void _interact() => widget.onInteraction?.call();

  void _setBrushSize(int size) {
    setState(() => _brushSize = size);
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

  void _handleClear() {
    _interact();
    if (_confirmClear) {
      widget.game.sandboxWorld.simulation.clear();
      setState(() => _confirmClear = false);
    } else {
      setState(() => _confirmClear = true);
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _confirmClear = false);
      });
    }
  }

  void _shake() {
    widget.game.sandboxWorld.simulation.doShake();
    setState(() => _isShaking = true);
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _isShaking = false);
    });
    _interact();
  }

  void _zoomIn() {
    final vf = widget.game.camera.viewfinder;
    final newZoom =
        (vf.zoom + 0.5).clamp(widget.game.minZoom, widget.game.maxZoom);
    vf.zoom = newZoom;
    widget.game.clampCameraPosition();
    _interact();
    setState(() {});
  }

  void _zoomOut() {
    final vf = widget.game.camera.viewfinder;
    final newZoom =
        (vf.zoom - 0.5).clamp(widget.game.minZoom, widget.game.maxZoom);
    vf.zoom = newZoom;
    widget.game.clampCameraPosition();
    _interact();
    setState(() {});
  }

  void _resetZoom() {
    widget.game.onDoubleTap();
    _interact();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnimation,
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 8, top: 8, bottom: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(ParticleTheme.radiusLarge),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                width: 80,
                decoration: ParticleTheme.glassDecoration(
                  borderRadius: ParticleTheme.radiusLarge,
                ),
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // -- Brush section --
                    FadeTransition(
                      opacity: _brushSectionAnim,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const _SectionLabel(label: 'BRUSH'),
                          const SizedBox(height: 4),
                          _BrushSizeSlider(
                            size: _brushSize,
                            onChanged: _setBrushSize,
                          ),
                          const SizedBox(height: 4),
                          _ActiveToolButton(
                            icon: _brushMode.icon,
                            onTap: _cycleBrushMode,
                            tooltip: _brushMode.label,
                            label: _brushMode.label,
                            isActive: true,
                            activeColor: AppColors.primary,
                          ),
                        ],
                      ),
                    ),
                    _gradientDivider(),
                    // -- Actions section --
                    FadeTransition(
                      opacity: _actionsSectionAnim,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const _SectionLabel(label: 'ACTIONS'),
                          const SizedBox(height: 4),
                          _ClearButton(
                            isConfirming: _confirmClear,
                            onTap: _handleClear,
                          ),
                          const SizedBox(height: 4),
                          _ShakeButton(
                            isShaking: _isShaking,
                            onTap: _shake,
                          ),
                        ],
                      ),
                    ),
                    _gradientDivider(),
                    // -- World section --
                    FadeTransition(
                      opacity: _worldSectionAnim,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const _SectionLabel(label: 'WORLD'),
                          const SizedBox(height: 4),
                          _PausePlayButton(
                            isPaused: _isPaused,
                            onTap: _togglePause,
                          ),
                          const SizedBox(height: 4),
                          _DayNightButton(
                            isNight: _isNight,
                            onTap: _toggleDayNight,
                          ),
                          _gradientDivider(),
                          const _SectionLabel(label: 'ZOOM'),
                          const SizedBox(height: 4),
                          _ZoomControls(
                            onZoomIn: _zoomIn,
                            onZoomOut: _zoomOut,
                            onReset: _resetZoom,
                            currentZoom: widget.game.camera.viewfinder.zoom,
                          ),
                        ],
                      ),
                    ),
                    // -- Debug FPS --
                    if (kDebugMode) ...[
                      _gradientDivider(),
                      _FpsCounter(game: widget.game),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _gradientDivider() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
        child: Container(
          height: 1,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.white.withValues(alpha: 0.0),
                Colors.white.withValues(alpha: 0.12),
                Colors.white.withValues(alpha: 0.0),
              ],
            ),
          ),
        ),
      );
}

// =============================================================================
// Section label
// =============================================================================

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: AppTypography.caption.copyWith(
        fontSize: 8,
        color: AppColors.textDim,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.6,
      ),
    );
  }
}

// =============================================================================
// Brush size vertical slider with preview dot
// =============================================================================

class _BrushSizeSlider extends StatelessWidget {
  const _BrushSizeSlider({required this.size, required this.onChanged});

  final int size;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final diameter = 6.0 + (size * 2.0);
    return SizedBox(
      width: 62,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Preview dot.
          AnimatedContainer(
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
          const SizedBox(height: 4),
          // Vertical slider.
          SizedBox(
            height: 80,
            child: RotatedBox(
              quarterTurns: 3,
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 7),
                  activeTrackColor: AppColors.primary,
                  inactiveTrackColor:
                      AppColors.surfaceLight.withValues(alpha: 0.6),
                  thumbColor: AppColors.primary,
                  overlayColor: AppColors.primaryDim.withValues(alpha: 0.2),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 14),
                ),
                child: Slider(
                  value: size.toDouble(),
                  min: 1,
                  max: 10,
                  divisions: 9,
                  onChanged: (v) => onChanged(v.round()),
                ),
              ),
            ),
          ),
          Text(
            '${size}px',
            style: AppTypography.caption.copyWith(
              fontSize: 9,
              color: AppColors.textDim,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Active tool button with color fill when active
// =============================================================================

class _ActiveToolButton extends StatefulWidget {
  const _ActiveToolButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.label,
    this.isActive = false,
    this.activeColor,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final String? label;
  final bool isActive;
  final Color? activeColor;

  @override
  State<_ActiveToolButton> createState() => _ActiveToolButtonState();
}

class _ActiveToolButtonState extends State<_ActiveToolButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.activeColor ?? AppColors.primary;
    return Tooltip(
      message: widget.tooltip ?? '',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: ParticleTheme.fastDuration,
              width: 62,
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                color: widget.isActive
                    ? color.withValues(alpha: 0.25)
                    : (_hovered
                        ? AppColors.surfaceLight.withValues(alpha: 0.3)
                        : Colors.transparent),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: widget.isActive
                      ? color.withValues(alpha: 0.6)
                      : Colors.transparent,
                  width: 1.5,
                ),
                boxShadow: widget.isActive
                    ? [
                        BoxShadow(
                          color: color.withValues(alpha: 0.3),
                          blurRadius: 8,
                        ),
                      ]
                    : null,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.icon,
                    size: 24,
                    color: widget.isActive ? color : AppColors.textPrimary,
                  ),
                  if (widget.label != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      widget.label!,
                      style: AppTypography.caption.copyWith(
                        fontSize: 9,
                        color: widget.isActive
                            ? color
                            : (_hovered
                                ? AppColors.textPrimary
                                : AppColors.textSecondary),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Pause/Play — prominent with animated icon morph and pulse when paused
// =============================================================================

class _PausePlayButton extends StatefulWidget {
  const _PausePlayButton({
    required this.isPaused,
    required this.onTap,
  });

  final bool isPaused;
  final VoidCallback onTap;

  @override
  State<_PausePlayButton> createState() => _PausePlayButtonState();
}

class _PausePlayButtonState extends State<_PausePlayButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _pulseAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    if (widget.isPaused) _pulseController.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _PausePlayButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPaused && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (!widget.isPaused && _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.reset();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isPaused ? AppColors.warning : AppColors.success;
    return Tooltip(
      message: widget.isPaused ? 'Resume simulation' : 'Pause simulation',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(ParticleTheme.radiusMedium),
          onTap: widget.onTap,
          child: AnimatedBuilder(
            animation: _pulseAnim,
            builder: (context, child) {
              final pulseScale =
                  widget.isPaused ? 1.0 + _pulseAnim.value * 0.04 : 1.0;
              final pulseGlow =
                  widget.isPaused ? _pulseAnim.value * 0.15 : 0.0;
              return Transform.scale(
                scale: pulseScale,
                child: AnimatedContainer(
                  duration: ParticleTheme.fastDuration,
                  curve: ParticleTheme.defaultCurve,
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.18),
                    borderRadius:
                        BorderRadius.circular(ParticleTheme.radiusMedium),
                    border: Border.all(
                      color: color.withValues(alpha: 0.4),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: color.withValues(alpha: 0.2 + pulseGlow),
                        blurRadius: 12,
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        transitionBuilder: (child, anim) =>
                            RotationTransition(
                          turns:
                              Tween(begin: 0.75, end: 1.0).animate(anim),
                          child:
                              FadeTransition(opacity: anim, child: child),
                        ),
                        child: Icon(
                          widget.isPaused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                          key: ValueKey(widget.isPaused),
                          size: 28,
                          color: color,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.isPaused ? 'Play' : 'Pause',
                        style: AppTypography.caption.copyWith(
                          fontSize: 9,
                          color: color,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Day/Night toggle with animated sun/moon transition
// =============================================================================

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
      message: isNight ? 'Switch to day' : 'Switch to night',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(ParticleTheme.radiusSmall),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: ParticleTheme.defaultCurve,
            width: 62,
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius:
                  BorderRadius.circular(ParticleTheme.radiusSmall),
              border: Border.all(
                color: color.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (child, anim) {
                    return RotationTransition(
                      turns: Tween(begin: 0.5, end: 1.0).animate(
                        CurvedAnimation(
                            parent: anim, curve: Curves.easeOutBack),
                      ),
                      child: FadeTransition(opacity: anim, child: child),
                    );
                  },
                  child: Icon(
                    isNight
                        ? Icons.dark_mode_rounded
                        : Icons.light_mode_rounded,
                    key: ValueKey(isNight),
                    size: 24,
                    color: color,
                  ),
                ),
                const SizedBox(height: 2),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    isNight ? 'Night' : 'Day',
                    key: ValueKey(isNight),
                    style: AppTypography.caption.copyWith(
                      fontSize: 9,
                      color: color,
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

// =============================================================================
// Clear button — double-tap-to-confirm
// =============================================================================

class _ClearButton extends StatelessWidget {
  const _ClearButton({
    required this.isConfirming,
    required this.onTap,
  });

  final bool isConfirming;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isConfirming ? AppColors.danger : AppColors.textPrimary;
    return Tooltip(
      message: isConfirming ? 'Tap again to clear' : 'Clear world',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(ParticleTheme.radiusSmall),
          onTap: onTap,
          child: AnimatedContainer(
            duration: ParticleTheme.fastDuration,
            width: 62,
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: isConfirming
                  ? AppColors.danger.withValues(alpha: 0.2)
                  : Colors.transparent,
              borderRadius:
                  BorderRadius.circular(ParticleTheme.radiusSmall),
              border: Border.all(
                color: isConfirming
                    ? AppColors.danger.withValues(alpha: 0.5)
                    : Colors.transparent,
                width: 1.5,
              ),
              boxShadow: isConfirming
                  ? [
                      BoxShadow(
                        color: AppColors.danger.withValues(alpha: 0.25),
                        blurRadius: 8,
                      ),
                    ]
                  : null,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.delete_outline_rounded,
                  size: 24,
                  color: color,
                ),
                const SizedBox(height: 2),
                AnimatedSwitcher(
                  duration: ParticleTheme.fastDuration,
                  child: Text(
                    isConfirming ? 'Confirm' : 'Clear',
                    key: ValueKey(isConfirming),
                    style: AppTypography.caption.copyWith(
                      fontSize: 9,
                      color: color,
                      fontWeight:
                          isConfirming ? FontWeight.w700 : FontWeight.w500,
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

// =============================================================================
// Shake button with rotation animation
// =============================================================================

class _ShakeButton extends StatelessWidget {
  const _ShakeButton({
    required this.isShaking,
    required this.onTap,
  });

  final bool isShaking;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Shake world',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(ParticleTheme.radiusSmall),
          onTap: onTap,
          child: SizedBox(
            width: 62,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: isShaking ? 1.0 : 0.0),
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.elasticOut,
                    builder: (context, value, child) {
                      return Transform.rotate(
                        angle: sin(value * pi * 6) * 0.15,
                        child: child,
                      );
                    },
                    child: const Icon(
                      Icons.vibration_rounded,
                      size: 24,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Shake',
                    style: AppTypography.caption.copyWith(
                      fontSize: 9,
                      color: AppColors.textSecondary,
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

// =============================================================================
// Zoom controls
// =============================================================================

class _ZoomControls extends StatelessWidget {
  const _ZoomControls({
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
    required this.currentZoom,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;
  final double currentZoom;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 62,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SmallIconButton(
            icon: Icons.add_rounded,
            onTap: onZoomIn,
            tooltip: 'Zoom in',
          ),
          const SizedBox(height: 2),
          Text(
            '${(currentZoom * 100).round()}%',
            style: AppTypography.caption.copyWith(
              fontSize: 9,
              color: AppColors.textDim,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          _SmallIconButton(
            icon: Icons.remove_rounded,
            onTap: onZoomOut,
            tooltip: 'Zoom out',
          ),
          const SizedBox(height: 4),
          _SmallIconButton(
            icon: Icons.fit_screen_rounded,
            onTap: onReset,
            tooltip: 'Reset view',
          ),
        ],
      ),
    );
  }
}

class _SmallIconButton extends StatefulWidget {
  const _SmallIconButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  State<_SmallIconButton> createState() => _SmallIconButtonState();
}

class _SmallIconButtonState extends State<_SmallIconButton> {
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
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: _hovered
                  ? AppColors.surfaceLight.withValues(alpha: 0.4)
                  : AppColors.surfaceLight.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              widget.icon,
              size: 18,
              color:
                  _hovered ? AppColors.textPrimary : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// FPS counter (debug only)
// =============================================================================

class _FpsCounter extends StatefulWidget {
  const _FpsCounter({required this.game});
  final ParticleEngineGame game;

  @override
  State<_FpsCounter> createState() => _FpsCounterState();
}

class _FpsCounterState extends State<_FpsCounter> {
  int _frameCount = 0;
  double _fps = 0;
  DateTime _lastSample = DateTime.now();

  @override
  void initState() {
    super.initState();
    _tick();
  }

  void _tick() {
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      final now = DateTime.now();
      final elapsed = now.difference(_lastSample).inMilliseconds;
      // Read game's internal frame count for accuracy.
      final currentFrame =
          widget.game.sandboxWorld.simulation.frameCount;
      final delta = currentFrame - _frameCount;
      if (elapsed > 0 && delta > 0) {
        setState(() {
          _fps = (delta / elapsed * 1000).roundToDouble();
        });
      }
      _frameCount = currentFrame;
      _lastSample = now;
      _tick();
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = _fps >= 25
        ? AppColors.success
        : (_fps >= 15 ? AppColors.warning : AppColors.danger);
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${_fps.round()}',
            style: AppTypography.caption.copyWith(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            'FPS',
            style: AppTypography.caption.copyWith(
              fontSize: 7,
              color: AppColors.textDim,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}
