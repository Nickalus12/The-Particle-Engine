import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';

/// Glassmorphic dialog action button with hover state.
class DialogButton extends StatefulWidget {
  const DialogButton({
    super.key,
    required this.label,
    required this.onTap,
    this.color,
  });
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  State<DialogButton> createState() => _DialogButtonState();
}

class _DialogButtonState extends State<DialogButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? AppColors.textSecondary;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: ParticleTheme.fastDuration,
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: _hovered
                ? color.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius:
                BorderRadius.circular(ParticleTheme.radiusSmall),
            border: Border.all(
              color: _hovered
                  ? color.withValues(alpha: 0.3)
                  : Colors.transparent,
              width: 0.5,
            ),
          ),
          child: Text(
            widget.label,
            style: AppTypography.button.copyWith(
              color: color,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}
