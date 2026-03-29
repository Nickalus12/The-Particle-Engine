import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../game/particle_engine_game.dart';
import '../../services/save_service.dart';
import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';
import 'hud_icon_badge.dart';

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
  const ToolBar({
    super.key,
    required this.game,
    this.onInteraction,
    this.reservedBottom = 0,
    this.panelInteractionKey,
    this.toggleInteractionKey,
  });

  final ParticleEngineGame game;
  final VoidCallback? onInteraction;
  final double reservedBottom;
  final Key? panelInteractionKey;
  final Key? toggleInteractionKey;

  @override
  State<ToolBar> createState() => _ToolBarState();
}

class _ToolBarState extends State<ToolBar> with TickerProviderStateMixin {
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
    _slideAnimation = Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _slideController,
            curve: ParticleTheme.defaultCurve,
          ),
        );
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
            child: Text(
              'Cancel',
              style: AppTypography.button.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              widget.game.sandboxWorld.clearWorld();
              Navigator.pop(ctx);
            },
            child: Text(
              'Clear',
              style: AppTypography.button.copyWith(color: AppColors.danger),
            ),
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

  Future<void> _saveWorld(BuildContext context) async {
    _interact();
    final request = await showDialog<_SaveRequest>(
      context: context,
      builder: (ctx) => _SaveWorldDialog(initialName: widget.game.worldName),
    );
    if (request == null) return;

    try {
      await widget.game.sandboxWorld.saveCurrentWorld(
        slot: request.slot,
        name: request.name,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.surface,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ParticleTheme.radiusSmall),
          ),
          content: Text(
            'Saved to slot ${request.slot}',
            style: AppTypography.body.copyWith(color: AppColors.success),
          ),
        ),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.surface,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ParticleTheme.radiusSmall),
          ),
          content: Text(
            'Save failed',
            style: AppTypography.body.copyWith(color: AppColors.danger),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final safe = MediaQuery.of(context).padding;
        final availableHeight =
            (constraints.maxHeight -
                    safe.top -
                    safe.bottom -
                    widget.reservedBottom -
                    8)
                .clamp(240.0, double.infinity)
                .toDouble();
        final compact = availableHeight < 620;
        final ultraCompact = availableHeight < 520;
        final panelWidth = ultraCompact ? 62.0 : (compact ? 68.0 : 72.0);
        final iconButtonSize = ultraCompact ? 40.0 : (compact ? 44.0 : 48.0);
        final iconSize = ultraCompact ? 16.0 : (compact ? 18.0 : 19.0);
        final collapseSize = ultraCompact ? 28.0 : 30.0;
        final collapseIconSize = ultraCompact ? 14.0 : 16.0;
        final verticalPadding = ultraCompact ? 5.0 : 8.0;
        final panelGap = ultraCompact ? 1.0 : 2.0;
        final dividerVertical = ultraCompact ? 2.0 : 3.0;
        final panelMaxHeight = (availableHeight - collapseSize - 8)
            .clamp(80.0, availableHeight)
            .toDouble();

        return SlideTransition(
          position: _slideAnimation,
          child: SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                key: const ValueKey('tool_bar_container'),
                padding: EdgeInsets.only(
                  left: 6,
                  top: 4,
                  bottom: 4 + widget.reservedBottom,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: availableHeight),
                  child: SingleChildScrollView(
                    physics: const ClampingScrollPhysics(),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _CollapseToggle(
                          collapsed: _collapsed,
                          onTap: _toggleCollapse,
                          size: collapseSize,
                          iconSize: collapseIconSize,
                          interactionKey: widget.toggleInteractionKey,
                        ),
                        const SizedBox(height: 4),
                        SizeTransition(
                          sizeFactor: CurvedAnimation(
                            parent: _collapseController,
                            curve: Curves.easeOutCubic,
                          ),
                          axisAlignment: -1.0,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: panelMaxHeight,
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(
                                ParticleTheme.radiusLarge,
                              ),
                              child: BackdropFilter(
                                filter: ImageFilter.blur(
                                  sigmaX: 24,
                                  sigmaY: 24,
                                ),
                                child: Container(
                                  key: widget.panelInteractionKey,
                                  width: panelWidth,
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Color(0xE0141B28),
                                        Color(0xD10A0F18),
                                      ],
                                    ),
                                    borderRadius: BorderRadius.circular(
                                      ParticleTheme.radiusLarge,
                                    ),
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
                                  padding: EdgeInsets.symmetric(
                                    vertical: verticalPadding,
                                  ),
                                  child: SingleChildScrollView(
                                    physics: const ClampingScrollPhysics(),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _BrushSizeButton(
                                          size: _brushSize,
                                          onTap: _cycleBrushSize,
                                          width: iconButtonSize,
                                          height: ultraCompact ? 32 : 36,
                                        ),
                                        SizedBox(height: panelGap),
                                        _ToolIcon(
                                          icon: _brushMode.icon,
                                          onTap: _cycleBrushMode,
                                          tooltip: _brushMode.label,
                                          accent: const Color(0xFF7EE3FF),
                                          motif: HudBadgeMotif.streak,
                                          size: iconButtonSize,
                                          iconSize: iconSize,
                                        ),
                                        _divider(vertical: dividerVertical),
                                        _PausePlayIcon(
                                          isPaused: _isPaused,
                                          onTap: _togglePause,
                                          size: iconButtonSize,
                                          iconSize: iconSize + 1,
                                        ),
                                        SizedBox(height: panelGap),
                                        _DayNightIcon(
                                          isNight: _isNight,
                                          onTap: _toggleDayNight,
                                          size: iconButtonSize,
                                          iconSize: iconSize,
                                        ),
                                        _divider(vertical: dividerVertical),
                                        _ToolIcon(
                                          icon: Icons.vibration_rounded,
                                          onTap: _shake,
                                          tooltip: 'Shake',
                                          accent: const Color(0xFFFFA35C),
                                          motif: HudBadgeMotif.streak,
                                          size: iconButtonSize,
                                          iconSize: iconSize,
                                        ),
                                        SizedBox(height: panelGap),
                                        _ToolIcon(
                                          icon: Icons.science_rounded,
                                          onTap: _openPeriodicTable,
                                          tooltip: 'Periodic Table',
                                          iconColor: const Color(0xFF80B0E0),
                                          accent: const Color(0xFF80B0E0),
                                          motif: HudBadgeMotif.orbit,
                                          size: iconButtonSize,
                                          iconSize: iconSize,
                                        ),
                                        SizedBox(height: panelGap),
                                        _ToolIcon(
                                          icon: Icons.save_outlined,
                                          onTap: () =>
                                              unawaited(_saveWorld(context)),
                                          tooltip: 'Save World',
                                          iconColor: const Color(0xFF80D0A8),
                                          accent: const Color(0xFF80D0A8),
                                          motif: HudBadgeMotif.lattice,
                                          size: iconButtonSize,
                                          iconSize: iconSize,
                                        ),
                                        SizedBox(height: panelGap),
                                        _ToolIcon(
                                          icon: Icons.delete_outline_rounded,
                                          onTap: () => _clearGrid(context),
                                          tooltip: 'Clear',
                                          iconColor: AppColors.danger,
                                          accent: AppColors.danger,
                                          motif: HudBadgeMotif.pulse,
                                          size: iconButtonSize,
                                          iconSize: iconSize,
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
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _divider({double vertical = 3}) => Padding(
    padding: EdgeInsets.symmetric(vertical: vertical, horizontal: 8),
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

class _SaveRequest {
  const _SaveRequest({required this.slot, required this.name});

  final int slot;
  final String? name;
}

class _SaveWorldDialog extends StatefulWidget {
  const _SaveWorldDialog({this.initialName});

  final String? initialName;

  @override
  State<_SaveWorldDialog> createState() => _SaveWorldDialogState();
}

class _SaveWorldDialogState extends State<_SaveWorldDialog> {
  late final TextEditingController _nameController;
  int _slot = 1;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final slots = List<int>.generate(
      SaveService.maxSlots - 1,
      (index) => index + 1,
    );

    return AlertDialog(
      scrollable: true,
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ParticleTheme.radiusMedium),
      ),
      title: Text('Save World', style: AppTypography.heading),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<int>(
              initialValue: _slot,
              decoration: const InputDecoration(labelText: 'Slot'),
              items: slots
                  .map(
                    (slot) => DropdownMenuItem<int>(
                      value: slot,
                      child: Text('Slot $slot'),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => _slot = value);
                }
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'Optional',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Cancel',
            style: AppTypography.button.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        ),
        TextButton(
          onPressed: () {
            final trimmed = _nameController.text.trim();
            Navigator.pop(
              context,
              _SaveRequest(slot: _slot, name: trimmed.isEmpty ? null : trimmed),
            );
          },
          child: Text(
            'Save',
            style: AppTypography.button.copyWith(color: AppColors.success),
          ),
        ),
      ],
    );
  }
}

/// Small pill-shaped toggle to collapse/expand the toolbar.
class _CollapseToggle extends StatelessWidget {
  const _CollapseToggle({
    required this.collapsed,
    required this.onTap,
    this.size = 30,
    this.iconSize = 16,
    this.interactionKey,
  });
  final bool collapsed;
  final VoidCallback onTap;
  final double size;
  final double iconSize;
  final Key? interactionKey;

  @override
  Widget build(BuildContext context) {
    return HudIconBadge(
      key: interactionKey,
      icon: collapsed
          ? Icons.chevron_left_rounded
          : Icons.chevron_right_rounded,
      onTap: onTap,
      tooltip: collapsed ? 'Expand toolbar' : 'Collapse toolbar',
      accent: const Color(0xFF74A8F5),
      motif: HudBadgeMotif.orbit,
      size: size,
      iconSize: iconSize,
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
    this.accent = const Color(0xFF74A8F5),
    this.motif = HudBadgeMotif.orbit,
    this.size = 48,
    this.iconSize = 19,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final Color? iconColor;
  final Color accent;
  final HudBadgeMotif motif;
  final double size;
  final double iconSize;

  @override
  State<_ToolIcon> createState() => _ToolIconState();
}

class _ToolIconState extends State<_ToolIcon> {
  @override
  Widget build(BuildContext context) {
    return HudIconBadge(
      icon: widget.icon,
      onTap: widget.onTap,
      tooltip: widget.tooltip,
      accent: widget.accent,
      motif: widget.motif,
      size: widget.size,
      iconSize: widget.iconSize,
      shape: BoxShape.rectangle,
      borderRadius: BorderRadius.circular(12),
      iconColor: widget.iconColor,
    );
  }
}

/// Compact pause/play icon.
class _PausePlayIcon extends StatelessWidget {
  const _PausePlayIcon({
    required this.isPaused,
    required this.onTap,
    this.size = 48,
    this.iconSize = 21,
  });
  final bool isPaused;
  final VoidCallback onTap;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final color = isPaused ? AppColors.danger : AppColors.success;
    return HudIconBadge(
      icon: isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
      onTap: onTap,
      tooltip: isPaused ? 'Play' : 'Pause',
      accent: color,
      motif: HudBadgeMotif.pulse,
      active: true,
      size: size,
      iconSize: iconSize,
      shape: BoxShape.rectangle,
      borderRadius: BorderRadius.circular(12),
    );
  }
}

/// Compact day/night toggle icon.
class _DayNightIcon extends StatelessWidget {
  const _DayNightIcon({
    required this.isNight,
    required this.onTap,
    this.size = 48,
    this.iconSize = 19,
  });
  final bool isNight;
  final VoidCallback onTap;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final color = isNight ? AppColors.accent : AppColors.warning;
    return HudIconBadge(
      icon: isNight ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
      onTap: onTap,
      tooltip: isNight ? 'Night' : 'Day',
      accent: color,
      motif: isNight ? HudBadgeMotif.orbit : HudBadgeMotif.streak,
      active: true,
      size: size,
      iconSize: iconSize,
      shape: BoxShape.rectangle,
      borderRadius: BorderRadius.circular(12),
    );
  }
}

/// Visual brush size indicator that shows a filled circle proportional to size.
class _BrushSizeButton extends StatelessWidget {
  const _BrushSizeButton({
    required this.size,
    required this.onTap,
    this.width = 48,
    this.height = 36,
  });

  final int size;
  final VoidCallback onTap;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final diameter = 4.0 + (size * 1.5);
    return Tooltip(
      message: 'Brush: ${size}px',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0x331FC7FF), Color(0x140A0F18)],
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.10),
              width: 0.8,
            ),
          ),
          alignment: Alignment.center,
          child: Container(
            width: diameter.clamp(6, 28),
            height: diameter.clamp(6, 28),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFEAF8FF), Color(0xFF81D8FF)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF74A8F5).withValues(alpha: 0.22),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ],
              border: Border.all(color: AppColors.textPrimary, width: 1),
            ),
          ),
        ),
      ),
    );
  }
}
