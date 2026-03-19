import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';

/// Settings screen with audio, haptics, and graphics quality controls.
///
/// Dark themed with glassmorphism panels. Navigated to from the home screen.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entranceController;

  double _masterVolume = 0.8;
  double _sfxVolume = 1.0;
  double _ambientVolume = 0.6;
  bool _hapticsEnabled = true;
  int _graphicsQuality = 1; // 0=low, 1=medium, 2=high
  bool _dayNightCycle = true;
  bool _particleEffects = true;

  static const _qualityLabels = ['Low', 'Medium', 'High'];

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..forward();
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  Animation<double> _sectionAnimation(int index) {
    final start = (index * 0.1).clamp(0.0, 0.5);
    final end = (start + 0.5).clamp(0.0, 1.0);
    return Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: Interval(start, end, curve: Curves.easeOutCubic),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  _BackButton(
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 16),
                  Text('Settings', style: AppTypography.heading),
                ],
              ),
            ),

            // Settings list
            Expanded(
              child: AnimatedBuilder(
                animation: _entranceController,
                builder: (context, _) => ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    const SizedBox(height: 8),

                    // Audio section
                    _AnimatedSection(
                      animation: _sectionAnimation(0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _SectionHeader('AUDIO', Icons.volume_up_rounded),
                          const SizedBox(height: 8),
                          _SettingsPanel(
                            children: [
                              _VolumeSlider(
                                label: 'Master',
                                icon: Icons.volume_up_rounded,
                                value: _masterVolume,
                                onChanged: (v) =>
                                    setState(() => _masterVolume = v),
                              ),
                              _VolumeSlider(
                                label: 'Sound Effects',
                                icon: Icons.speaker_rounded,
                                value: _sfxVolume,
                                onChanged: (v) =>
                                    setState(() => _sfxVolume = v),
                              ),
                              _VolumeSlider(
                                label: 'Ambient',
                                icon: Icons.music_note_rounded,
                                value: _ambientVolume,
                                onChanged: (v) =>
                                    setState(() => _ambientVolume = v),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Haptics section
                    _AnimatedSection(
                      animation: _sectionAnimation(1),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _SectionHeader('HAPTICS', Icons.vibration_rounded),
                          const SizedBox(height: 8),
                          _SettingsPanel(
                            children: [
                              _SettingsToggle(
                                label: 'Vibration Feedback',
                                icon: Icons.vibration_rounded,
                                value: _hapticsEnabled,
                                onChanged: (v) =>
                                    setState(() => _hapticsEnabled = v),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Display section
                    _AnimatedSection(
                      animation: _sectionAnimation(2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _SectionHeader('DISPLAY', Icons.display_settings_rounded),
                          const SizedBox(height: 8),
                          _SettingsPanel(
                            children: [
                              _SettingsToggle(
                                label: 'Day/Night Cycle',
                                icon: Icons.dark_mode_rounded,
                                value: _dayNightCycle,
                                onChanged: (v) =>
                                    setState(() => _dayNightCycle = v),
                              ),
                              _SettingsToggle(
                                label: 'Particle Effects',
                                icon: Icons.auto_awesome_rounded,
                                value: _particleEffects,
                                onChanged: (v) =>
                                    setState(() => _particleEffects = v),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Graphics section
                    _AnimatedSection(
                      animation: _sectionAnimation(3),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _SectionHeader('GRAPHICS', Icons.auto_awesome_rounded),
                          const SizedBox(height: 8),
                          _SettingsPanel(
                            children: [
                              _QualitySelector(
                                value: _graphicsQuality,
                                labels: _qualityLabels,
                                onChanged: (v) =>
                                    setState(() => _graphicsQuality = v),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // About section
                    _AnimatedSection(
                      animation: _sectionAnimation(4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _SectionHeader('ABOUT', Icons.info_outline_rounded),
                          const SizedBox(height: 8),
                          _SettingsPanel(
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'The Particle Engine',
                                      style: AppTypography.subheading,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'v0.1.0',
                                      style: AppTypography.caption.copyWith(
                                        color: AppColors.primary,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'A sandbox of elements, creatures, and ecosystems. '
                                      'Simulate physics, grow colonies, and watch life emerge.',
                                      style: AppTypography.body,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Animated section wrapper
// ═══════════════════════════════════════════════════════════════════════════

class _AnimatedSection extends StatelessWidget {
  const _AnimatedSection({
    required this.animation,
    required this.child,
  });

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: animation.value,
      child: Transform.translate(
        offset: Offset(0, 20 * (1 - animation.value)),
        child: child,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Shared widgets
// ═══════════════════════════════════════════════════════════════════════════

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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text, this.icon);
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 14,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppColors.primary, AppColors.accent],
            ),
          ),
        ),
        Icon(icon, size: 12, color: AppColors.textDim),
        const SizedBox(width: 6),
        Text(
          text,
          style: AppTypography.label.copyWith(
            color: AppColors.textDim,
            letterSpacing: 2.5,
            fontSize: 10,
          ),
        ),
      ],
    );
  }
}

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({required this.children});
  final List<Widget> children;

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
          child: Column(
            children: children,
          ),
        ),
      ),
    );
  }
}

class _VolumeSlider extends StatelessWidget {
  const _VolumeSlider({
    required this.label,
    required this.icon,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final IconData icon;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.textDim),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Text(label, style: AppTypography.body),
          ),
          Expanded(
            flex: 3,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: value,
                onChanged: (v) {
                  HapticFeedback.selectionClick();
                  onChanged(v);
                },
                activeColor: AppColors.primary,
                inactiveColor: AppColors.surfaceLight,
              ),
            ),
          ),
          SizedBox(
            width: 36,
            child: Text(
              '${(value * 100).round()}',
              style: AppTypography.caption.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsToggle extends StatelessWidget {
  const _SettingsToggle({
    required this.label,
    required this.icon,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          AnimatedContainer(
            duration: ParticleTheme.fastDuration,
            child: Icon(
              icon,
              size: 18,
              color: value ? AppColors.primary : AppColors.textDim,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: AnimatedDefaultTextStyle(
              duration: ParticleTheme.fastDuration,
              style: AppTypography.body.copyWith(
                color: value ? AppColors.textPrimary : AppColors.textSecondary,
              ),
              child: Text(label),
            ),
          ),
          Switch(
            value: value,
            onChanged: (v) {
              HapticFeedback.selectionClick();
              onChanged(v);
            },
          ),
        ],
      ),
    );
  }
}

class _QualitySelector extends StatelessWidget {
  const _QualitySelector({
    required this.value,
    required this.labels,
    required this.onChanged,
  });

  final int value;
  final List<String> labels;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.speed_rounded,
                size: 18,
                color: AppColors.textDim,
              ),
              const SizedBox(width: 12),
              Text('Quality', style: AppTypography.body),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: List.generate(labels.length, (index) {
              final isActive = value == index;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    right: index < labels.length - 1 ? 8 : 0,
                  ),
                  child: GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      onChanged(index);
                    },
                    child: AnimatedContainer(
                      duration: ParticleTheme.fastDuration,
                      height: 36,
                      decoration: BoxDecoration(
                        color: isActive
                            ? AppColors.primary.withValues(alpha: 0.2)
                            : AppColors.surfaceLight,
                        borderRadius: BorderRadius.circular(
                          ParticleTheme.radiusSmall,
                        ),
                        border: Border.all(
                          color: isActive
                              ? AppColors.primary.withValues(alpha: 0.5)
                              : Colors.transparent,
                          width: 1,
                        ),
                        boxShadow: isActive
                            ? [
                                BoxShadow(
                                  color:
                                      AppColors.primary.withValues(alpha: 0.15),
                                  blurRadius: 8,
                                ),
                              ]
                            : null,
                      ),
                      child: Center(
                        child: Text(
                          labels[index],
                          style: AppTypography.label.copyWith(
                            color: isActive
                                ? AppColors.primary
                                : AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}
