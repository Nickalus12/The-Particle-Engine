import 'dart:ui';

import 'package:flutter/material.dart';

import '../../simulation/element_registry.dart';
import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';
import 'element_palette.dart';

/// Glassmorphism info card that appears on long-press of an element.
///
/// Shows element name, animated preview, description, properties, and
/// a "Reacts with:" row of interacting element icons.
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
    with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;
  late final Animation<double> _scaleAnimation;

  /// Continuous icon animation matching the palette's cycle.
  late final AnimationController _iconAnimController;

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

    _iconAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    )..repeat();
  }

  @override
  void dispose() {
    _iconAnimController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() async {
    await _controller.reverse();
    widget.onDismiss();
  }

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
    El.oxygen: 'Invisible gas. Fuels fire and supports life. Lighter than CO2.',
    El.co2: 'Heavy gas. Sinks and smothers fire. Byproduct of combustion.',
    El.fungus: 'Bracket fungi. Grows on wood and organic matter. Produces spores.',
    El.spore: 'Fungal spore. Drifts in air. Colonizes organic surfaces.',
    El.charcoal: 'Carbon-rich fuel. Burns hotter and longer than wood.',
    El.compost: 'Decomposed organics. Rich soil amendment. Generates heat.',
    El.rust: 'Corroded metal. Brittle and crumbly. Forms from wet metal.',
    El.methane: 'Flammable gas. Lighter than air. Explosive near fire.',
    El.salt: 'Crystalline mineral. Dissolves in water. Preserves organics.',
    El.clay: 'Dense soil. Holds water. Can be fired into ceramics.',
    El.algae: 'Aquatic plant. Grows in water. Produces oxygen.',
    El.honey: 'Viscous liquid. Produced by ant colonies. Slow-flowing.',
    El.hydrogen: 'Lightest gas. Extremely flammable. Rises rapidly.',
    El.sulfur: 'Yellow mineral. Burns with blue flame. Reacts with metals.',
    El.copper: 'Conductive metal. Develops green patina. Excellent conductor.',
    El.web: 'Spider silk. Sticky and flammable. Traps small particles.',
  };

  static const Map<int, List<int>> _reactions = {
    El.sand: [El.lightning, El.water, El.lava],
    El.water: [El.fire, El.lava, El.ice, El.dirt, El.salt, El.metal, El.lightning],
    El.fire: [El.wood, El.oil, El.tnt, El.plant, El.hydrogen, El.methane, El.charcoal, El.web],
    El.ice: [El.fire, El.lava],
    El.lightning: [El.sand, El.water, El.metal, El.tnt, El.copper],
    El.seed: [El.dirt, El.water],
    El.stone: [El.lava, El.acid],
    El.tnt: [El.fire, El.lightning],
    El.mud: [El.water, El.dirt],
    El.steam: [El.ice],
    El.oil: [El.fire, El.water],
    El.acid: [El.stone, El.wood, El.metal, El.dirt, El.copper],
    El.glass: [El.acid],
    El.dirt: [El.water, El.seed, El.compost],
    El.plant: [El.fire, El.water],
    El.lava: [El.water, El.ice, El.wood, El.metal, El.stone],
    El.snow: [El.fire, El.lava],
    El.wood: [El.fire, El.acid, El.fungus],
    El.metal: [El.water, El.lightning, El.acid, El.lava],
    El.oxygen: [El.fire, El.hydrogen],
    El.co2: [El.fire, El.algae],
    El.fungus: [El.wood, El.compost, El.fire],
    El.spore: [El.wood, El.compost],
    El.charcoal: [El.fire, El.oxygen],
    El.compost: [El.dirt, El.seed, El.fungus],
    El.rust: [El.acid],
    El.methane: [El.fire, El.lightning],
    El.salt: [El.water, El.ice],
    El.clay: [El.water, El.fire],
    El.algae: [El.water, El.co2],
    El.honey: [El.water, El.ant],
    El.hydrogen: [El.fire, El.oxygen],
    El.sulfur: [El.fire, El.metal, El.copper],
    El.copper: [El.lightning, El.acid, El.water],
    El.web: [El.fire, El.acid],
  };

  String _descriptionFor(int elId) {
    if (elId == El.eraser) return 'Removes elements from the grid. Clears everything it touches.';
    return _descriptions[elId] ?? 'Custom element.';
  }

  List<int> _reactionsFor(int elId) => _reactions[elId] ?? const [];

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
    final cardWidth = 240.0;
    final left = (widget.position.dx - cardWidth / 2)
        .clamp(16.0, screenSize.width - cardWidth - 16.0);
    final top = (widget.position.dy - 220).clamp(16.0, screenSize.height - 240);

    final reactions = _reactionsFor(elId);

    return GestureDetector(
      onTap: _dismiss,
      behavior: HitTestBehavior.opaque,
      child: Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            Container(color: AppColors.scrim.withValues(alpha: 0.3)),
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
                              // Header with animated icon
                              Row(
                                children: [
                                  AnimatedBuilder(
                                    animation: _iconAnimController,
                                    builder: (context, _) {
                                      return Container(
                                        width: 48,
                                        height: 48,
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(10),
                                          boxShadow: [
                                            BoxShadow(
                                              color: elColor.withValues(alpha: 0.4),
                                              blurRadius: 12,
                                            ),
                                          ],
                                        ),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(10),
                                          child: CustomPaint(
                                            painter: AnimatedElementPreviewPainter(
                                              elId,
                                              elColor,
                                              _iconAnimController.value,
                                              isSelected: true,
                                            ),
                                            size: const Size(48, 48),
                                          ),
                                        ),
                                      );
                                    },
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
                              Text(
                                _descriptionFor(elId),
                                style: AppTypography.body,
                              ),
                              const SizedBox(height: 12),
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
                              if (reactions.isNotEmpty) ...[
                                const SizedBox(height: 12),
                                Text(
                                  'Reacts with:',
                                  style: AppTypography.caption.copyWith(
                                    color: AppColors.textDim,
                                    fontSize: 9,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                AnimatedBuilder(
                                  animation: _iconAnimController,
                                  builder: (context, _) {
                                    return Wrap(
                                      spacing: 4,
                                      runSpacing: 4,
                                      children: reactions.map((reactId) {
                                        final reactColor =
                                            ElementPalette.colorForId(reactId);
                                        final reactName =
                                            ElementPalette.nameForId(reactId);
                                        return Tooltip(
                                          message: reactName,
                                          child: Container(
                                            width: 22,
                                            height: 22,
                                            decoration: BoxDecoration(
                                              borderRadius: BorderRadius.circular(4),
                                              border: Border.all(
                                                color: reactColor.withValues(alpha: 0.3),
                                                width: 0.5,
                                              ),
                                            ),
                                            child: ClipRRect(
                                              borderRadius: BorderRadius.circular(3.5),
                                              child: CustomPaint(
                                                painter: AnimatedElementPreviewPainter(
                                                  reactId,
                                                  reactColor,
                                                  _iconAnimController.value,
                                                ),
                                                size: const Size(22, 22),
                                              ),
                                            ),
                                          ),
                                        );
                                      }).toList(),
                                    );
                                  },
                                ),
                              ],
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
