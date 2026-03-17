import 'dart:ui';

import 'package:flutter/material.dart';

import '../../simulation/element_registry.dart';
import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';

/// Glassmorphism info card that appears on long-press of an element.
///
/// Shows element name, description, category, and known properties.
/// Positioned near the long-press location and dismissible by tapping outside.
/// Works with element IDs directly so custom elements are supported.
class ElementInfoCard extends StatefulWidget {
  const ElementInfoCard({
    super.key,
    required this.elementId,
    required this.position,
    required this.onDismiss,
  });

  final int elementId;
  final Offset position;
  final VoidCallback onDismiss;

  @override
  State<ElementInfoCard> createState() => _ElementInfoCardState();
}

class _ElementInfoCardState extends State<ElementInfoCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;
  late final Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );
    _scaleAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() async {
    await _controller.reverse();
    widget.onDismiss();
  }

  /// Built-in descriptions keyed by [El] constant.
  static const Map<int, String> _descriptions = {
    El.sand: 'Granular solid that falls and piles. Forms dunes and foundations.',
    El.water: 'Flows and fills spaces. Sustains life and conducts electricity.',
    El.fire: 'Consumes flammable materials. Produces smoke, ash, and heat.',
    El.ice: 'Frozen solid. Melts near fire or lava into water.',
    El.lightning: 'Electric bolt. Fuses sand to glass, electrifies water and metal.',
    El.seed: 'Plants grow from seeds when placed near wet dirt.',
    El.stone: 'Immovable solid. Forms barriers and structures. Heated by lava.',
    El.tnt: 'Explosive! Detonates when touched by fire or lightning.',
    El.rainbow: 'Colorful falling element. Cycles through the spectrum.',
    El.mud: 'Thick liquid. Forms when dirt gets waterlogged.',
    El.steam: 'Hot gas. Rises quickly and disperses over time.',
    El.ant: 'Colony creature. Explores, digs, forages, and builds bridges.',
    El.oil: 'Flammable liquid. Floats on water. Burns intensely with chain ignition.',
    El.acid: 'Corrosive liquid. Dissolves stone, wood, metal, and dirt.',
    El.glass: 'Transparent solid. Created when lightning strikes sand.',
    El.dirt: 'Organic soil. Absorbs water and supports plant growth.',
    El.plant: 'Living growth. Five types: grass, flower, tree, mushroom, vine.',
    El.lava: 'Molten rock. Ignites flammable materials, creates stone on water contact.',
    El.snow: 'Light powder. Melts near fire or lava. Sparkles in light.',
    El.wood: 'Organic solid. Burns when exposed to fire. Shows wood grain.',
    El.metal: 'Conductive solid. Rusts over time. Conducts lightning.',
    El.smoke: 'Rises and disperses. Byproduct of combustion.',
    El.bubble: 'Fragile sphere. Floats upward and pops at the surface.',
    El.ash: 'Lightweight residue from burned materials. Drifts in wind.',
  };

  String _descriptionFor(int elId) {
    if (elId == El.eraser) return 'Removes elements from the grid. Clears everything it touches.';
    return _descriptions[elId] ?? 'Custom element.';
  }

  List<_PropertyTag> _propertiesFor(int elId) {
    final cat = elId < maxElements ? elCategory[elId] : 0;
    return [
      if (cat & ElCat.liquid != 0)
        _PropertyTag('Liquid', AppColors.categoryLiquids),
      if (cat & ElCat.gas != 0)
        _PropertyTag('Gas', AppColors.textDim),
      if (cat & ElCat.solid != 0)
        _PropertyTag('Solid', AppColors.categorySolids),
      if (cat & ElCat.organic != 0)
        _PropertyTag('Organic', AppColors.categoryLife),
      if (cat & ElCat.flammable != 0)
        _PropertyTag('Flammable', AppColors.categoryEnergy),
      if (cat & ElCat.conductive != 0)
        _PropertyTag('Conductive', AppColors.categoryTools),
      if (cat & ElCat.danger != 0)
        _PropertyTag('Dangerous', Colors.redAccent),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final elId = widget.elementId;
    final elColor = elId == El.eraser
        ? const Color(0xFF666680)
        : (elId >= 0 && elId < maxElements ? Color(baseColors[elId]) : const Color(0xFF808080));
    final elName = elId == El.eraser
        ? 'Eraser'
        : (elId >= 0 && elId < maxElements ? elementNames[elId] : '???');
    final screenSize = MediaQuery.of(context).size;
    // Position card above the long-press point, clamped to screen.
    final cardWidth = 240.0;
    final left = (widget.position.dx - cardWidth / 2)
        .clamp(16.0, screenSize.width - cardWidth - 16.0);
    final top = (widget.position.dy - 180).clamp(16.0, screenSize.height - 200);

    return GestureDetector(
      onTap: _dismiss,
      behavior: HitTestBehavior.opaque,
      child: Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            // Scrim
            Container(color: AppColors.scrim.withValues(alpha: 0.3)),
            // Card
            Positioned(
              left: left,
              top: top,
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: ScaleTransition(
                  scale: _scaleAnimation,
                  child: SizedBox(
                    width: cardWidth,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        ParticleTheme.radiusMedium,
                      ),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: ParticleTheme.glassDecoration(
                            borderRadius: ParticleTheme.radiusMedium,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Header
                              Row(
                                children: [
                                  Container(
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      color: elColor,
                                      borderRadius: BorderRadius.circular(8),
                                      boxShadow: [
                                        BoxShadow(
                                          color: elColor
                                              .withValues(alpha: 0.4),
                                          blurRadius: 12,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      elName,
                                      style: AppTypography.heading.copyWith(
                                        fontSize: 18,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              // Description
                              Text(
                                _descriptionFor(elId),
                                style: AppTypography.body,
                              ),
                              const SizedBox(height: 12),
                              // Property tags
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: _propertiesFor(elId)
                                    .map((tag) => Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: tag.color.withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(6),
                                            border: Border.all(
                                              color: tag.color.withValues(alpha: 0.3),
                                              width: 0.5,
                                            ),
                                          ),
                                          child: Text(
                                            tag.label,
                                            style: AppTypography.caption.copyWith(
                                              color: tag.color,
                                              fontSize: 9,
                                            ),
                                          ),
                                        ))
                                    .toList(),
                              ),
                            ],
                          ),
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
    );
  }
}

class _PropertyTag {
  const _PropertyTag(this.label, this.color);
  final String label;
  final Color color;
}
