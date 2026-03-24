import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';

/// Settings screen with organized sections: Graphics, Audio, Controls, About.
///
/// Dark themed with glassmorphism panels, custom sliders, and premium toggles.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final Animation<double> _contentFade;

  // -- Graphics --
  int _giQuality = 1; // 0=off, 1=low, 2=high
  double _bloomStrength = 0.5;
  double _renderScale = 1.0;

  // -- Audio --
  double _masterVolume = 0.8;
  double _sfxVolume = 1.0;
  double _musicVolume = 0.6;
  double _ambientVolume = 0.6;

  // -- Controls --
  double _brushSize = 3.0;
  double _touchSensitivity = 1.0;
  bool _hapticsEnabled = true;

  static const _giLabels = ['Off', 'Low', 'High'];
  static const _giDescriptions = [
    'No global illumination',
    'Balanced quality and performance',
    'Full radiance cascades GI',
  ];

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
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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

              // Settings list -- two column layout for landscape
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Left column: Graphics + Controls
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        children: [
                          const SizedBox(height: 4),

                          // Graphics section
                          _SectionHeader('GRAPHICS'),
                          const SizedBox(height: 8),
                          _SettingsPanel(
                            accent: AppColors.categoryEnergy,
                            children: [
                              _QualitySelector(
                                label: 'Global Illumination',
                                icon: Icons.light_mode_rounded,
                                value: _giQuality,
                                labels: _giLabels,
                                description: _giDescriptions[_giQuality],
                                onChanged: (v) =>
                                    setState(() => _giQuality = v),
                              ),
                              _Divider(),
                              _PremiumSlider(
                                label: 'Bloom Strength',
                                icon: Icons.blur_on_rounded,
                                value: _bloomStrength,
                                onChanged: (v) =>
                                    setState(() => _bloomStrength = v),
                              ),
                              _Divider(),
                              _PremiumSlider(
                                label: 'Render Scale',
                                icon: Icons.aspect_ratio_rounded,
                                value: _renderScale,
                                min: 0.5,
                                max: 2.0,
                                divisions: 6,
                                valueLabel:
                                    '${_renderScale.toStringAsFixed(1)}x',
                                onChanged: (v) =>
                                    setState(() => _renderScale = v),
                              ),
                            ],
                          ),

                          const SizedBox(height: 20),

                          // Controls section
                          _SectionHeader('CONTROLS'),
                          const SizedBox(height: 8),
                          _SettingsPanel(
                            accent: AppColors.primary,
                            children: [
                              _PremiumSlider(
                                label: 'Brush Size',
                                icon: Icons.brush_rounded,
                                value: _brushSize,
                                min: 1,
                                max: 10,
                                divisions: 9,
                                valueLabel:
                                    '${_brushSize.round()}',
                                onChanged: (v) =>
                                    setState(() => _brushSize = v),
                              ),
                              _Divider(),
                              _PremiumSlider(
                                label: 'Touch Sensitivity',
                                icon: Icons.touch_app_rounded,
                                value: _touchSensitivity,
                                min: 0.5,
                                max: 2.0,
                                divisions: 6,
                                valueLabel:
                                    '${_touchSensitivity.toStringAsFixed(1)}x',
                                onChanged: (v) =>
                                    setState(() => _touchSensitivity = v),
                              ),
                              _Divider(),
                              _PremiumToggle(
                                label: 'Haptic Feedback',
                                icon: Icons.vibration_rounded,
                                value: _hapticsEnabled,
                                onChanged: (v) =>
                                    setState(() => _hapticsEnabled = v),
                              ),
                            ],
                          ),
                          const SizedBox(height: 32),
                        ],
                      ),
                    ),

                    // Right column: Audio + About
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        children: [
                          const SizedBox(height: 4),

                          // Audio section
                          _SectionHeader('AUDIO'),
                          const SizedBox(height: 8),
                          _SettingsPanel(
                            accent: AppColors.accent,
                            children: [
                              _PremiumSlider(
                                label: 'Master',
                                icon: Icons.volume_up_rounded,
                                value: _masterVolume,
                                onChanged: (v) =>
                                    setState(() => _masterVolume = v),
                              ),
                              _Divider(),
                              _PremiumSlider(
                                label: 'Sound Effects',
                                icon: Icons.speaker_rounded,
                                value: _sfxVolume,
                                onChanged: (v) =>
                                    setState(() => _sfxVolume = v),
                              ),
                              _Divider(),
                              _PremiumSlider(
                                label: 'Music',
                                icon: Icons.music_note_rounded,
                                value: _musicVolume,
                                onChanged: (v) =>
                                    setState(() => _musicVolume = v),
                              ),
                              _Divider(),
                              _PremiumSlider(
                                label: 'Ambient',
                                icon: Icons.nature_rounded,
                                value: _ambientVolume,
                                onChanged: (v) =>
                                    setState(() => _ambientVolume = v),
                              ),
                            ],
                          ),

                          const SizedBox(height: 20),

                          // About section
                          _SectionHeader('ABOUT'),
                          const SizedBox(height: 8),
                          _SettingsPanel(
                            accent: AppColors.categoryLife,
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(14),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        // Mini gradient icon
                                        Container(
                                          width: 32,
                                          height: 32,
                                          decoration: BoxDecoration(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            gradient: const LinearGradient(
                                              colors: [
                                                AppColors.primary,
                                                AppColors.accent,
                                              ],
                                            ),
                                          ),
                                          child: const Icon(
                                            Icons.grain_rounded,
                                            size: 18,
                                            color: Colors.white,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'The Particle Engine',
                                              style:
                                                  AppTypography.subheading,
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              'v0.1.0',
                                              style: AppTypography.caption
                                                  .copyWith(
                                                color: AppColors.textDim,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    Container(
                                      width: double.infinity,
                                      height: 0.5,
                                      color: AppColors.glassBorder,
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      'A sandbox of elements, creatures, and ecosystems. '
                                      'Simulate physics, grow colonies, and watch life emerge.',
                                      style: AppTypography.body.copyWith(
                                        color: AppColors.textSecondary,
                                        height: 1.5,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Row(
                                      children: [
                                        _InfoChip(
                                          label: '41 Elements',
                                          color: AppColors.categoryLiquids,
                                        ),
                                        const SizedBox(width: 8),
                                        _InfoChip(
                                          label: 'Radiance GI',
                                          color: AppColors.categoryEnergy,
                                        ),
                                        const SizedBox(width: 8),
                                        _InfoChip(
                                          label: 'NEAT AI',
                                          color: AppColors.categoryLife,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 32),
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
    );
  }
}

// =============================================================================
// Section header with gradient accent line
// =============================================================================

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 12,
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

// =============================================================================
// Glass settings panel
// =============================================================================

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({
    required this.children,
    this.accent = AppColors.primary,
  });
  final List<Widget> children;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return ParticleTheme.atmosphericPanel(
      accent: accent,
      borderRadius: ParticleTheme.radiusMedium,
      blurAmount: 12,
      baseColor: const Color(0xCC10131C),
      child: Column(
        children: children,
      ),
    );
  }
}

// =============================================================================
// Subtle divider inside panels
// =============================================================================

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      height: 0.5,
      color: AppColors.glassBorder.withValues(alpha: 0.15),
    );
  }
}

// =============================================================================
// Premium slider with icon, label, and value display
// =============================================================================

class _PremiumSlider extends StatelessWidget {
  const _PremiumSlider({
    required this.label,
    required this.icon,
    required this.value,
    required this.onChanged,
    this.min = 0.0,
    this.max = 1.0,
    this.divisions,
    this.valueLabel,
  });

  final String label;
  final IconData icon;
  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final int? divisions;
  final String? valueLabel;

  @override
  Widget build(BuildContext context) {
    final displayValue = valueLabel ??
        '${((value - min) / (max - min) * 100).round()}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.textDim),
          const SizedBox(width: 10),
          Expanded(
            flex: 3,
            child: Text(
              label,
              style: AppTypography.body.copyWith(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            flex: 4,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: AppColors.primary,
                inactiveTrackColor: AppColors.surfaceLight,
                thumbColor: AppColors.primary,
                overlayColor: AppColors.primaryDim,
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 32,
            child: Text(
              displayValue,
              style: AppTypography.caption.copyWith(
                color: AppColors.textPrimary,
                fontFamily: 'monospace',
                fontSize: 11,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Premium toggle with custom styling
// =============================================================================

class _PremiumToggle extends StatelessWidget {
  const _PremiumToggle({
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.textDim),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: AppTypography.body.copyWith(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          GestureDetector(
            onTap: () => onChanged(!value),
            child: AnimatedContainer(
              duration: ParticleTheme.fastDuration,
              width: 40,
              height: 22,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                color: value
                    ? AppColors.primary.withValues(alpha: 0.25)
                    : AppColors.surfaceLight,
                border: Border.all(
                  color: value
                      ? AppColors.primary.withValues(alpha: 0.5)
                      : AppColors.glassBorder,
                  width: 0.5,
                ),
              ),
              child: AnimatedAlign(
                duration: ParticleTheme.fastDuration,
                curve: Curves.easeInOut,
                alignment:
                    value ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: value ? AppColors.primary : AppColors.textDim,
                    boxShadow: value
                        ? [
                            BoxShadow(
                              color: AppColors.primary
                                  .withValues(alpha: 0.4),
                              blurRadius: 6,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Quality selector (segmented control style)
// =============================================================================

class _QualitySelector extends StatelessWidget {
  const _QualitySelector({
    required this.label,
    required this.icon,
    required this.value,
    required this.labels,
    required this.onChanged,
    this.description,
  });

  final String label;
  final IconData icon;
  final int value;
  final List<String> labels;
  final ValueChanged<int> onChanged;
  final String? description;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: AppColors.textDim),
              const SizedBox(width: 10),
              Text(
                label,
                style: AppTypography.body.copyWith(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: List.generate(labels.length, (index) {
              final isActive = value == index;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    right: index < labels.length - 1 ? 6 : 0,
                  ),
                  child: GestureDetector(
                    onTap: () => onChanged(index),
                    child: AnimatedContainer(
                      duration: ParticleTheme.fastDuration,
                      height: 34,
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
                          width: 0.5,
                        ),
                        boxShadow: isActive
                            ? [
                                BoxShadow(
                                  color: AppColors.primary
                                      .withValues(alpha: 0.1),
                                  blurRadius: 8,
                                ),
                              ]
                            : null,
                      ),
                      child: Center(
                        child: Text(
                          labels[index],
                          style: AppTypography.label.copyWith(
                            fontSize: 11,
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
          if (description != null) ...[
            const SizedBox(height: 8),
            Text(
              description!,
              style: AppTypography.caption.copyWith(
                color: AppColors.textDim,
                fontSize: 10,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// =============================================================================
// Info chip for the About section
// =============================================================================

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: color.withValues(alpha: 0.25),
          width: 0.5,
        ),
      ),
      child: Text(
        label,
        style: AppTypography.caption.copyWith(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// =============================================================================
// Back button
// =============================================================================

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
