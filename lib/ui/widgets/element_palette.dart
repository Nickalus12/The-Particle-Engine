import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../game/particle_engine_game.dart';
import '../../simulation/element_registry.dart';
import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';
import 'element_info_card.dart';

/// Element category for grouping in the palette.
enum ElementCategory {
  // Original sandbox categories
  compounds('Compounds', AppColors.categorySolids, Icons.science_rounded),
  liquids('Liquids', AppColors.categoryLiquids, Icons.water_drop_rounded),
  gases('Gases', AppColors.categoryEnergy, Icons.cloud_rounded),
  life('Life', AppColors.categoryLife, Icons.park_rounded),
  energy('Energy', AppColors.categoryTools, Icons.flash_on_rounded),
  // Periodic table categories
  alkali('Alkali', Color(0xFFE87070), Icons.whatshot_rounded),
  alkaline('Alkaline', Color(0xFFE8A060), Icons.square_rounded),
  transition('Metals', Color(0xFF70A0D0), Icons.hardware_rounded),
  postTransition('Post-Trans', Color(0xFF60B8A0), Icons.grid_view_rounded),
  metalloid('Metalloids', Color(0xFFA080C0), Icons.hexagon_rounded),
  nonmetal('Nonmetals', Color(0xFF60C060), Icons.spa_rounded),
  halogen('Halogens', Color(0xFFD0D050), Icons.air_rounded),
  nobleGas('Noble Gas', Color(0xFF80B0E0), Icons.bubble_chart_rounded),
  lanthanide('Rare Earth', Color(0xFFD0A060), Icons.stars_rounded),
  actinide('Actinides', Color(0xFF70C070), Icons.warning_rounded),
  tools('Tools', AppColors.categoryTools, Icons.auto_fix_high_rounded);

  const ElementCategory(this.label, this.color, this.icon);
  final String label;
  final Color color;
  final IconData icon;

  /// Classify an element by its ID.
  static ElementCategory forElementId(int elId) {
    if (elId == El.eraser) return ElementCategory.tools;

    // Use the family metadata if available
    if (elId >= 0 && elId < maxElements) {
      final family = elementFamily[elId];
      switch (family) {
        case ElFamily.alkaliMetal: return ElementCategory.alkali;
        case ElFamily.alkalineEarth: return ElementCategory.alkaline;
        case ElFamily.transitionMetal: return ElementCategory.transition;
        case ElFamily.postTransition: return ElementCategory.postTransition;
        case ElFamily.metalloid: return ElementCategory.metalloid;
        case ElFamily.nonmetal: return ElementCategory.nonmetal;
        case ElFamily.halogen: return ElementCategory.halogen;
        case ElFamily.nobleGas: return ElementCategory.nobleGas;
        case ElFamily.lanthanide: return ElementCategory.lanthanide;
        case ElFamily.actinide: return ElementCategory.actinide;
        case ElFamily.superheavy: return ElementCategory.actinide; // group with actinides
      }
    }

    // Fallback for original sandbox elements
    switch (elId) {
      case El.water: case El.oil: case El.acid: case El.lava:
      case El.mud: case El.honey:
        return ElementCategory.liquids;
      case El.fire: case El.smoke: case El.steam:
      case El.oxygen: case El.co2: case El.methane:
      case El.hydrogen:
        return ElementCategory.gases;
      case El.seed: case El.plant: case El.fungus: case El.spore:
      case El.algae: case El.ant: case El.seaweed: case El.moss:
      case El.vine: case El.flower: case El.root: case El.thorn:
        return ElementCategory.life;
      case El.tnt: case El.c4:
        return ElementCategory.energy;
      case El.lightning: case El.rainbow:
        return ElementCategory.tools;
    }
    // Default: compounds (stone, glass, sand, dirt, etc.)
    return ElementCategory.compounds;
  }
}

/// Left-side vertical element palette panel with collapsible category sections.
class ElementPalette extends StatefulWidget {
  const ElementPalette({super.key, required this.game, this.onInteraction});

  final ParticleEngineGame game;
  final VoidCallback? onInteraction;

  /// Get the display color for an element ID from the registry.
  static Color colorForId(int elId) {
    if (elId == El.eraser) return const Color(0xFF666680);
    if (elId >= 0 && elId < maxElements) return Color(baseColors[elId]);
    return const Color(0xFF808080);
  }

  /// Get the display name for an element ID from the registry.
  static String nameForId(int elId) {
    if (elId == El.eraser) return 'Eraser';
    if (elId >= 0 && elId < maxElements) return elementNames[elId];
    return '???';
  }

  @override
  State<ElementPalette> createState() => _ElementPaletteState();
}

class _ElementPaletteState extends State<ElementPalette>
    with TickerProviderStateMixin {
  int _selectedElId = El.sand;
  ElementCategory _activeCategory = ElementCategory.compounds;
  OverlayEntry? _infoOverlay;

  late final AnimationController _slideController;
  late final Animation<Offset> _slideAnimation;

  /// Continuous animation controller for smooth element icon animations.
  /// Runs at display refresh rate but painter uses sinusoidal easing internally.
  late final AnimationController _iconAnimController;

  /// 1Hz pulse controller for selection glow.
  late final AnimationController _glowController;

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      vsync: this,
      duration: ParticleTheme.normalDuration,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(-1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: ParticleTheme.defaultCurve,
    ));
    _slideController.forward();

    // Smooth continuous loop: 4-second period for gentle, eased animation.
    // The painter applies its own easing functions per-element.
    _iconAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    )..repeat();

    // 1.5Hz glow pulse (slightly slower feels more premium)
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _iconAnimController.dispose();
    _glowController.dispose();
    _slideController.dispose();
    _dismissInfoCard();
    super.dispose();
  }

  void _select(int elId) {
    setState(() => _selectedElId = elId);
    widget.game.sandboxWorld.sandboxComponent.selectedElement = elId;
    widget.onInteraction?.call();
  }

  List<int> get _placeableElements => ElementRegistry.placeableIds;

  List<int> _elementsForCategory(ElementCategory cat) {
    final elements = _placeableElements
        .where((id) => ElementCategory.forElementId(id) == cat)
        .toList();
    if (cat == ElementCategory.tools) {
      elements.insert(0, El.eraser);
    }
    return elements;
  }

  void _showInfoCard(BuildContext context, int elId, Offset position) {
    _dismissInfoCard();
    _infoOverlay = OverlayEntry(
      builder: (ctx) => ElementInfoCard(
        elementId: elId,
        position: position,
        onDismiss: _dismissInfoCard,
      ),
    );
    Overlay.of(context).insert(_infoOverlay!);
    widget.onInteraction?.call();
  }

  void _dismissInfoCard() {
    _infoOverlay?.remove();
    _infoOverlay = null;
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnimation,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 8, top: 8, bottom: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(ParticleTheme.radiusLarge),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 32, sigmaY: 32),
              child: Container(
                width: 80,
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height - 16,
                ),
                decoration: ParticleTheme.glassDecoration(
                  borderRadius: ParticleTheme.radiusLarge,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildSelectedIndicator(),
                    _thinDivider(),
                    Flexible(child: _buildCategoryContent()),
                    _thinDivider(),
                    _buildObserveButton(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSelectedIndicator() {
    final color = ElementPalette.colorForId(_selectedElId);
    final name = ElementPalette.nameForId(_selectedElId);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          AnimatedBuilder(
            animation: Listenable.merge([_glowController, _iconAnimController]),
            builder: (context, child) {
              // Ease the glow with a sine curve for smooth pulsing
              final glowT = Curves.easeInOut.transform(_glowController.value);
              final glowAlpha = 0.25 + glowT * 0.35;
              return Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: glowAlpha),
                      blurRadius: 10 + glowT * 4,
                      spreadRadius: glowT * 1.5,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CustomPaint(
                    painter: AnimatedElementPreviewPainter(
                      _selectedElId, color, _iconAnimController.value,
                      isSelected: true,
                    ),
                    size: const Size(32, 32),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 4),
          Text(
            name,
            style: AppTypography.caption.copyWith(
              fontSize: 8,
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryContent() {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: ElementCategory.values.map((cat) {
          final isActive = cat == _activeCategory;
          final elements = _elementsForCategory(cat);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CategoryHeader(
                category: cat,
                isActive: isActive,
                onTap: () {
                  setState(() => _activeCategory = cat);
                  widget.onInteraction?.call();
                },
              ),
              // Smooth expand/collapse
              AnimatedSize(
                duration: ParticleTheme.normalDuration,
                curve: ParticleTheme.defaultCurve,
                child: isActive
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 2),
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: elements.map((elId) {
                            return _ElementTile(
                              elId: elId,
                              isSelected: elId == _selectedElId,
                              color: ElementPalette.colorForId(elId),
                              name: ElementPalette.nameForId(elId),
                              iconAnimController: _iconAnimController,
                              glowController: _glowController,
                              onTap: () => _select(elId),
                              onLongPressStart: (details) {
                                _showInfoCard(
                                    context, elId, details.globalPosition);
                              },
                            );
                          }).toList(),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              if (!isActive && cat != ElementCategory.values.last)
                _thinDivider(),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildObserveButton() {
    return GestureDetector(
      onTap: () => widget.game.exitCreationMode(),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: AppColors.glass,
                borderRadius: BorderRadius.circular(ParticleTheme.radiusSmall),
                border: Border.all(
                  color: AppColors.glassBorder,
                  width: 0.5,
                ),
              ),
              child: const Icon(
                Icons.visibility_rounded,
                size: 16,
                color: AppColors.textDim,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Observe',
              style: AppTypography.caption.copyWith(
                fontSize: 7,
                color: AppColors.textDim,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _thinDivider() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
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

// ---------------------------------------------------------------------------
// Category header
// ---------------------------------------------------------------------------

class _CategoryHeader extends StatefulWidget {
  const _CategoryHeader({
    required this.category,
    required this.isActive,
    required this.onTap,
  });

  final ElementCategory category;
  final bool isActive;
  final VoidCallback onTap;

  @override
  State<_CategoryHeader> createState() => _CategoryHeaderState();
}

class _CategoryHeaderState extends State<_CategoryHeader> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cat = widget.category;
    final isActive = widget.isActive;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: cat.label,
          child: AnimatedContainer(
            duration: ParticleTheme.fastDuration,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: isActive
                  ? cat.color.withValues(alpha: 0.15)
                  : _hovered
                      ? AppColors.surfaceLight.withValues(alpha: 0.3)
                      : Colors.transparent,
              border: isActive
                  ? Border(
                      left: BorderSide(color: cat.color, width: 2.5),
                    )
                  : null,
            ),
            child: Column(
              children: [
                AnimatedContainer(
                  duration: ParticleTheme.fastDuration,
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: isActive
                        ? cat.color.withValues(alpha: 0.25)
                        : _hovered
                            ? cat.color.withValues(alpha: 0.1)
                            : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isActive
                          ? cat.color.withValues(alpha: 0.6)
                          : Colors.transparent,
                      width: 1.5,
                    ),
                    boxShadow: isActive
                        ? [
                            BoxShadow(
                              color: cat.color.withValues(alpha: 0.3),
                              blurRadius: 8,
                            ),
                          ]
                        : null,
                  ),
                  child: Icon(
                    cat.icon,
                    size: 20,
                    color: isActive
                        ? cat.color
                        : _hovered
                            ? cat.color.withValues(alpha: 0.7)
                            : AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  cat.label,
                  style: AppTypography.caption.copyWith(
                    fontSize: 9,
                    color: isActive ? cat.color : AppColors.textSecondary,
                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
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

// ---------------------------------------------------------------------------
// Element tile — 36x36 with hover scale, selection depth, smooth animation
// ---------------------------------------------------------------------------

class _ElementTile extends StatefulWidget {
  const _ElementTile({
    required this.elId,
    required this.isSelected,
    required this.color,
    required this.name,
    required this.iconAnimController,
    required this.glowController,
    required this.onTap,
    required this.onLongPressStart,
  });

  final int elId;
  final bool isSelected;
  final Color color;
  final String name;
  final AnimationController iconAnimController;
  final AnimationController glowController;
  final VoidCallback onTap;
  final void Function(LongPressStartDetails) onLongPressStart;

  @override
  State<_ElementTile> createState() => _ElementTileState();
}

class _ElementTileState extends State<_ElementTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final isSelected = widget.isSelected;
    final color = widget.color;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPressStart: widget.onLongPressStart,
        child: AnimatedBuilder(
          animation: Listenable.merge([
            widget.iconAnimController,
            if (isSelected) widget.glowController,
          ]),
          builder: (context, _) {
            final phase = widget.iconAnimController.value;
            final glowT = isSelected
                ? Curves.easeInOut.transform(widget.glowController.value)
                : 0.0;
            final glowAlpha = 0.25 + glowT * 0.35;

            // Hover: subtle scale-up. Selected: slight raise via offset.
            final scale = _hovered && !isSelected ? 1.08 : 1.0;

            return Transform.scale(
              scale: scale,
              child: SizedBox(
                width: 36,
                height: 36,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: isSelected
                          ? color.withValues(alpha: 0.9)
                          : _hovered
                              ? color.withValues(alpha: 0.4)
                              : Colors.white.withValues(alpha: 0.08),
                      width: isSelected ? 1.5 : 0.5,
                    ),
                    boxShadow: [
                      if (isSelected) ...[
                        // Raised depth shadow
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.4),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                        // Colored glow
                        BoxShadow(
                          color: color.withValues(alpha: glowAlpha),
                          blurRadius: 10 + glowT * 4,
                          spreadRadius: glowT,
                        ),
                      ] else if (_hovered)
                        BoxShadow(
                          color: color.withValues(alpha: 0.25),
                          blurRadius: 8,
                        ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(5.5),
                    child: CustomPaint(
                      painter: AnimatedElementPreviewPainter(
                        widget.elId,
                        color,
                        phase,
                        isSelected: isSelected,
                        isHovered: _hovered,
                      ),
                      size: const Size(36, 36),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Premium animated element preview painter — vector shapes
// ---------------------------------------------------------------------------

/// Paints clean vector icons for each element type.
///
/// Uses Canvas path drawing for smooth, resolution-independent shapes.
/// Each element has a recognizable symbol (drop, flame, crystal, etc.)
/// with subtle animation driven by [phase].
class AnimatedElementPreviewPainter extends CustomPainter {
  AnimatedElementPreviewPainter(
    this.elId,
    this.baseColor,
    this.phase, {
    this.isSelected = false,
    this.isHovered = false,
  });

  final int elId;
  final Color baseColor;

  /// Continuous phase 0.0-1.0 (loops).
  final double phase;
  final bool isSelected;
  final bool isHovered;

  // -- Math helpers --

  /// Smooth sinusoidal oscillation: returns -1.0 to 1.0
  double _wave(double speed, [double offset = 0.0]) =>
      math.sin((phase * speed + offset) * math.pi * 2);

  /// Smooth 0.0 to 1.0 oscillation
  double _pulse(double speed, [double offset = 0.0]) =>
      (_wave(speed, offset) + 1.0) * 0.5;

  /// Animation amplitude multiplier — selected elements are more alive
  double get _amp => isSelected ? 1.3 : 1.0;

  /// Lighter shade of the base color
  Color _light([double amount = 0.3]) => Color.lerp(baseColor, Colors.white, amount)!;

  /// Darker shade of the base color
  Color _dark([double amount = 0.3]) => Color.lerp(baseColor, Colors.black, amount)!;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final cy = h / 2;
    final r = w * 0.38; // standard radius
    final p = Paint()..isAntiAlias = true;

    // Subtle dark background fill
    p.color = _dark(0.65).withValues(alpha: 0.5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(w * 0.15)),
      p,
    );

    switch (elId) {
      case El.eraser:
        _paintEraser(canvas, w, h, cx, cy, p);
      case El.sand:
        _paintSand(canvas, w, h, cx, cy, r, p);
      case El.water:
        _paintDrop(canvas, w, h, cx, cy, r, p);
      case El.fire:
        _paintFlame(canvas, w, h, cx, cy, r, p);
      case El.lava:
        _paintLava(canvas, w, h, cx, cy, r, p);
      case El.ice:
        _paintCrystal(canvas, w, h, cx, cy, r, p);
      case El.steam:
        _paintSteam(canvas, w, h, cx, cy, r, p);
      case El.smoke:
        _paintSmoke(canvas, w, h, cx, cy, r, p);
      case El.metal:
        _paintIngot(canvas, w, h, cx, cy, r, p);
      case El.copper:
        _paintIngot(canvas, w, h, cx, cy, r, p);
      case El.lightning:
        _paintBolt(canvas, w, h, cx, cy, r, p);
      case El.plant:
        _paintLeaf(canvas, w, h, cx, cy, r, p);
      case El.ant:
        _paintAnt(canvas, w, h, cx, cy, r, p);
      case El.honey:
        _paintHoney(canvas, w, h, cx, cy, r, p);
      case El.fungus:
        _paintMushroom(canvas, w, h, cx, cy, r, p);
      case El.oil:
        _paintDrop(canvas, w, h, cx, cy, r, p);
      case El.acid:
        _paintDrop(canvas, w, h, cx, cy, r, p);
      case El.stone:
        _paintRock(canvas, w, h, cx, cy, r, p);
      case El.wood:
        _paintWood(canvas, w, h, cx, cy, r, p);
      case El.glass:
        _paintGlass(canvas, w, h, cx, cy, r, p);
      case El.dirt:
        _paintDirt(canvas, w, h, cx, cy, r, p);
      case El.mud:
        _paintDrop(canvas, w, h, cx, cy, r, p);
      case El.snow:
        _paintSnowflake(canvas, w, h, cx, cy, r, p);
      case El.tnt:
        _paintTNT(canvas, w, h, cx, cy, r, p);
      case El.rainbow:
        _paintRainbow(canvas, w, h, cx, cy, r, p);
      case El.seed:
        _paintSeed(canvas, w, h, cx, cy, r, p);
      case El.bubble:
        _paintBubble(canvas, w, h, cx, cy, r, p);
      case El.ash:
        _paintParticles(canvas, w, h, cx, cy, r, p);
      case El.oxygen:
        _paintGasCircles(canvas, w, h, cx, cy, r, p);
      case El.co2:
        _paintGasCircles(canvas, w, h, cx, cy, r, p);
      case El.hydrogen:
        _paintGasCircles(canvas, w, h, cx, cy, r, p);
      case El.methane:
        _paintGasCircles(canvas, w, h, cx, cy, r, p);
      case El.sulfur:
        _paintCrystal(canvas, w, h, cx, cy, r, p);
      case El.salt:
        _paintCrystal(canvas, w, h, cx, cy, r, p);
      case El.clay:
        _paintDirt(canvas, w, h, cx, cy, r, p);
      case El.algae:
        _paintLeaf(canvas, w, h, cx, cy, r, p);
      case El.spore:
        _paintParticles(canvas, w, h, cx, cy, r, p);
      case El.charcoal:
        _paintRock(canvas, w, h, cx, cy, r, p);
      case El.compost:
        _paintDirt(canvas, w, h, cx, cy, r, p);
      case El.rust:
        _paintRock(canvas, w, h, cx, cy, r, p);
      case El.web:
        _paintWeb(canvas, w, h, cx, cy, r, p);
      default:
        _paintGenericCircle(canvas, w, h, cx, cy, r, p);
    }
  }

  // -- Eraser: checkerboard with animated X --
  void _paintEraser(Canvas canvas, double w, double h, double cx, double cy, Paint p) {
    final cs = w / 4;
    for (int py = 0; py < 4; py++) {
      for (int px = 0; px < 4; px++) {
        p.color = (px + py) % 2 == 0
            ? const Color(0xFF3A3A55)
            : const Color(0xFF4A4A70);
        canvas.drawRect(Rect.fromLTWH(px * cs, py * cs, cs + 0.5, cs + 0.5), p);
      }
    }
    final xAlpha = 0.7 + _pulse(0.5) * 0.25;
    p
      ..color = const Color(0xFFFF4646).withValues(alpha: xAlpha)
      ..strokeWidth = w * 0.08
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(w * 0.22, h * 0.22), Offset(w * 0.78, h * 0.78), p);
    canvas.drawLine(Offset(w * 0.78, h * 0.22), Offset(w * 0.22, h * 0.78), p);
    p.style = PaintingStyle.fill;
  }

  // -----------------------------------------------------------------------
  // Vector shape renderers — clean, scalable, recognizable at a glance
  // -----------------------------------------------------------------------

  // -- Sand: falling grains and a pile --
  void _paintSand(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    // Small pile at bottom
    final pilePath = Path()
      ..moveTo(w * 0.12, h * 0.85)
      ..quadraticBezierTo(cx, h * 0.48, w * 0.88, h * 0.85)
      ..close();
    p.color = _dark(0.1);
    canvas.drawPath(pilePath, p);
    p.color = _light(0.15);
    final highlightPath = Path()
      ..moveTo(w * 0.25, h * 0.82)
      ..quadraticBezierTo(cx, h * 0.55, w * 0.75, h * 0.82)
      ..close();
    canvas.drawPath(highlightPath, p);

    // Falling grains
    for (int i = 0; i < 3; i++) {
      final fx = w * (0.25 + i * 0.25);
      final fy = h * ((phase * 1.2 + i * 0.33) % 1.0) * 0.55 + h * 0.08;
      final gr = w * (0.035 + i * 0.008);
      p.color = baseColor.withValues(alpha: 0.7 + _pulse(0.6, i * 0.3) * 0.3);
      canvas.drawCircle(Offset(fx, fy), gr, p);
    }
  }

  // -- Water/Oil/Acid/Mud: teardrop shape --
  void _paintDrop(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    final wobble = _wave(1.0) * r * 0.06 * _amp;
    final dropPath = Path()
      ..moveTo(cx, h * 0.15 + wobble)
      ..cubicTo(cx + r * 0.15, h * 0.28, cx + r * 1.05, h * 0.52, cx, h * 0.88)
      ..cubicTo(cx - r * 1.05, h * 0.52, cx - r * 0.15, h * 0.28, cx, h * 0.15 + wobble)
      ..close();
    // Gradient fill via layered shapes
    p.color = _dark(0.15);
    canvas.drawPath(dropPath, p);
    // Highlight crescent
    final hlPath = Path()
      ..moveTo(cx - r * 0.3, h * 0.35)
      ..quadraticBezierTo(cx - r * 0.5, h * 0.55, cx - r * 0.15, h * 0.68)
      ..quadraticBezierTo(cx - r * 0.6, h * 0.48, cx - r * 0.3, h * 0.35)
      ..close();
    p.color = _light(0.35).withValues(alpha: 0.5);
    canvas.drawPath(hlPath, p);
    // Small shine dot
    p.color = Colors.white.withValues(alpha: 0.5 + _pulse(0.8) * 0.2);
    canvas.drawCircle(Offset(cx - r * 0.22, h * 0.38), r * 0.12, p);
  }

  // -- Fire: flame shape --
  void _paintFlame(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    final flicker = _wave(2.0) * r * 0.08 * _amp;
    final flicker2 = _wave(3.0, 0.3) * r * 0.05 * _amp;
    // Outer flame
    final outerPath = Path()
      ..moveTo(cx, h * 0.10 + flicker)
      ..cubicTo(cx + r * 0.6, h * 0.25 + flicker2, cx + r * 1.1, h * 0.65, cx, h * 0.90)
      ..cubicTo(cx - r * 1.1, h * 0.65, cx - r * 0.6, h * 0.25 - flicker2, cx, h * 0.10 + flicker)
      ..close();
    p.color = baseColor;
    canvas.drawPath(outerPath, p);
    // Inner bright core
    final innerPath = Path()
      ..moveTo(cx, h * 0.28 + flicker * 0.5)
      ..cubicTo(cx + r * 0.35, h * 0.40, cx + r * 0.55, h * 0.62, cx, h * 0.85)
      ..cubicTo(cx - r * 0.55, h * 0.62, cx - r * 0.35, h * 0.40, cx, h * 0.28 + flicker * 0.5)
      ..close();
    p.color = _light(0.45);
    canvas.drawPath(innerPath, p);
    // Hot center
    p.color = Colors.white.withValues(alpha: 0.5 + _pulse(1.5) * 0.3);
    canvas.drawOval(Rect.fromCenter(center: Offset(cx, h * 0.65), width: r * 0.5, height: r * 0.35), p);
  }

  // -- Lava: pooled molten rock --
  void _paintLava(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    final bubble = _pulse(1.5) * r * 0.15 * _amp;
    // Molten pool
    p.color = _dark(0.2);
    canvas.drawOval(Rect.fromCenter(center: Offset(cx, cy + r * 0.15), width: r * 2.1, height: r * 1.5), p);
    p.color = baseColor;
    canvas.drawOval(Rect.fromCenter(center: Offset(cx, cy + r * 0.1), width: r * 1.7, height: r * 1.2), p);
    // Bright streaks
    p.color = _light(0.5);
    canvas.drawOval(Rect.fromCenter(center: Offset(cx - r * 0.3, cy), width: r * 0.6, height: r * 0.25), p);
    // Bubble
    p.color = _light(0.6).withValues(alpha: 0.6 + _pulse(2.0) * 0.3);
    canvas.drawCircle(Offset(cx + r * 0.25, cy - bubble * 0.5), r * 0.15 + bubble * 0.1, p);
  }

  // -- Ice/Crystal/Salt/Sulfur: faceted gem --
  void _paintCrystal(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    final sparkle = _pulse(1.2) * 0.2;
    // Hexagonal crystal
    final crystalPath = Path()
      ..moveTo(cx, h * 0.12)
      ..lineTo(cx + r * 0.8, h * 0.32)
      ..lineTo(cx + r * 0.8, h * 0.68)
      ..lineTo(cx, h * 0.88)
      ..lineTo(cx - r * 0.8, h * 0.68)
      ..lineTo(cx - r * 0.8, h * 0.32)
      ..close();
    p.color = _dark(0.1);
    canvas.drawPath(crystalPath, p);
    // Light face
    final lightFace = Path()
      ..moveTo(cx, h * 0.12)
      ..lineTo(cx + r * 0.8, h * 0.32)
      ..lineTo(cx, h * 0.52)
      ..lineTo(cx - r * 0.8, h * 0.32)
      ..close();
    p.color = _light(0.2 + sparkle);
    canvas.drawPath(lightFace, p);
    // Shine
    p.color = Colors.white.withValues(alpha: 0.3 + sparkle);
    canvas.drawCircle(Offset(cx - r * 0.15, h * 0.30), r * 0.12, p);
  }

  // -- Steam: wispy rising clouds --
  void _paintSteam(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    for (int i = 0; i < 3; i++) {
      final rise = _pulse(0.6, i * 0.33) * h * 0.15 * _amp;
      final ox = cx + _wave(0.8, i * 0.5) * r * 0.3;
      final oy = cy + r * 0.3 - i * r * 0.4 - rise;
      final cr = r * (0.45 - i * 0.08);
      p.color = baseColor.withValues(alpha: 0.35 - i * 0.08 + _pulse(0.5, i * 0.2) * 0.1);
      canvas.drawCircle(Offset(ox, oy), cr, p);
    }
  }

  // -- Smoke: dark puffs --
  void _paintSmoke(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    for (int i = 0; i < 3; i++) {
      final rise = _pulse(0.5, i * 0.3) * h * 0.12 * _amp;
      final ox = cx + _wave(0.7, i * 0.4) * r * 0.25;
      final oy = cy + r * 0.2 - i * r * 0.35 - rise;
      final cr = r * (0.5 - i * 0.06);
      p.color = baseColor.withValues(alpha: 0.5 - i * 0.12);
      canvas.drawCircle(Offset(ox, oy), cr, p);
    }
  }

  // -- Metal/Copper: ingot shape --
  void _paintIngot(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    final shine = _pulse(0.8) * 0.15;
    // Trapezoidal ingot
    final ingotPath = Path()
      ..moveTo(cx - r * 0.55, h * 0.28)
      ..lineTo(cx + r * 0.55, h * 0.28)
      ..lineTo(cx + r * 0.85, h * 0.75)
      ..lineTo(cx - r * 0.85, h * 0.75)
      ..close();
    p.color = _dark(0.15);
    canvas.drawPath(ingotPath, p);
    // Top face
    final topFace = Path()
      ..moveTo(cx - r * 0.55, h * 0.28)
      ..lineTo(cx + r * 0.55, h * 0.28)
      ..lineTo(cx + r * 0.35, h * 0.45)
      ..lineTo(cx - r * 0.35, h * 0.45)
      ..close();
    p.color = _light(0.2 + shine);
    canvas.drawPath(topFace, p);
    // Shine streak
    p.color = Colors.white.withValues(alpha: 0.25 + shine);
    p.strokeWidth = w * 0.04;
    p.style = PaintingStyle.stroke;
    p.strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(cx - r * 0.2, h * 0.33), Offset(cx + r * 0.2, h * 0.33), p);
    p.style = PaintingStyle.fill;
  }

  // -- Lightning: zigzag bolt --
  void _paintBolt(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    final flash = _pulse(2.5) * 0.4 * _amp;
    final boltPath = Path()
      ..moveTo(cx + r * 0.15, h * 0.10)
      ..lineTo(cx - r * 0.25, h * 0.45)
      ..lineTo(cx + r * 0.10, h * 0.45)
      ..lineTo(cx - r * 0.15, h * 0.90)
      ..lineTo(cx + r * 0.45, h * 0.42)
      ..lineTo(cx + r * 0.05, h * 0.42)
      ..close();
    // Glow
    p.color = _light(0.3).withValues(alpha: 0.3 + flash * 0.5);
    p.maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawPath(boltPath, p);
    p.maskFilter = null;
    // Solid bolt
    p.color = _light(0.1 + flash * 0.3);
    canvas.drawPath(boltPath, p);
    // Core
    p.color = Colors.white.withValues(alpha: 0.6 + flash * 0.3);
    p.style = PaintingStyle.stroke;
    p.strokeWidth = w * 0.04;
    canvas.drawPath(boltPath, p);
    p.style = PaintingStyle.fill;
  }

  // -- Plant/Algae: leaf shape --
  void _paintLeaf(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    final sway = _wave(0.7) * r * 0.06 * _amp;
    // Stem
    p.color = _dark(0.25);
    p.strokeWidth = w * 0.05;
    p.style = PaintingStyle.stroke;
    p.strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(cx, h * 0.85), Offset(cx + sway * 0.5, h * 0.45), p);
    p.style = PaintingStyle.fill;
    // Leaf body
    final leafPath = Path()
      ..moveTo(cx + sway, h * 0.15)
      ..cubicTo(cx + r * 1.0 + sway, h * 0.25, cx + r * 0.8 + sway, h * 0.65, cx + sway * 0.5, h * 0.55)
      ..cubicTo(cx - r * 0.8 + sway, h * 0.65, cx - r * 1.0 + sway, h * 0.25, cx + sway, h * 0.15)
      ..close();
    p.color = baseColor;
    canvas.drawPath(leafPath, p);
    // Vein
    p.color = _light(0.2);
    p.style = PaintingStyle.stroke;
    p.strokeWidth = w * 0.03;
    canvas.drawLine(Offset(cx + sway, h * 0.18), Offset(cx + sway * 0.5, h * 0.52), p);
    p.style = PaintingStyle.fill;
  }

  // -- Ant: simple bug silhouette --
  void _paintAnt(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    final walk = _wave(2.0) * r * 0.05 * _amp;
    p.color = baseColor;
    // Head
    canvas.drawOval(Rect.fromCenter(center: Offset(cx, h * 0.25), width: r * 0.65, height: r * 0.55), p);
    // Thorax
    canvas.drawOval(Rect.fromCenter(center: Offset(cx, h * 0.48), width: r * 0.55, height: r * 0.45), p);
    // Abdomen
    canvas.drawOval(Rect.fromCenter(center: Offset(cx, h * 0.72), width: r * 0.75, height: r * 0.65), p);
    // Legs
    p.style = PaintingStyle.stroke;
    p.strokeWidth = w * 0.035;
    p.strokeCap = StrokeCap.round;
    p.color = _dark(0.15);
    for (int i = 0; i < 3; i++) {
      final ly = h * (0.38 + i * 0.12);
      final legOut = r * (0.6 + (i == 1 ? 0.15 : 0));
      final legWalk = i.isEven ? walk : -walk;
      canvas.drawLine(Offset(cx, ly), Offset(cx - legOut + legWalk, ly + r * 0.15), p);
      canvas.drawLine(Offset(cx, ly), Offset(cx + legOut - legWalk, ly + r * 0.15), p);
    }
    // Antennae
    canvas.drawLine(Offset(cx - r * 0.15, h * 0.22), Offset(cx - r * 0.4, h * 0.08 + walk), p);
    canvas.drawLine(Offset(cx + r * 0.15, h * 0.22), Offset(cx + r * 0.4, h * 0.08 - walk), p);
    p.style = PaintingStyle.fill;
    // Eyes
    p.color = Colors.white.withValues(alpha: 0.7);
    canvas.drawCircle(Offset(cx - r * 0.12, h * 0.23), r * 0.07, p);
    canvas.drawCircle(Offset(cx + r * 0.12, h * 0.23), r * 0.07, p);
  }

  // -- Honey: hexagonal drop --
  void _paintHoney(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    final drip = _pulse(0.6) * r * 0.1 * _amp;
    // Hexagon
    final hex = Path();
    for (int i = 0; i < 6; i++) {
      final angle = math.pi / 3 * i - math.pi / 6;
      final x = cx + r * 0.75 * math.cos(angle);
      final y = cy - r * 0.1 + r * 0.75 * math.sin(angle);
      if (i == 0) {
        hex.moveTo(x, y);
      } else {
        hex.lineTo(x, y);
      }
    }
    hex.close();
    p.color = _dark(0.1);
    canvas.drawPath(hex, p);
    p.color = _light(0.15);
    canvas.drawCircle(Offset(cx - r * 0.15, cy - r * 0.2), r * 0.2, p);
    // Drip
    p.color = baseColor;
    canvas.drawOval(Rect.fromCenter(
      center: Offset(cx, h * 0.82 + drip),
      width: r * 0.35, height: r * 0.25 + drip * 0.5,
    ), p);
  }

  // -- Mushroom --
  void _paintMushroom(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    final breathe = _pulse(0.6) * r * 0.04 * _amp;
    // Stem
    p.color = _light(0.4);
    canvas.drawRRect(RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, h * 0.72), width: r * 0.45, height: r * 0.7),
      Radius.circular(r * 0.15),
    ), p);
    // Cap
    final capPath = Path()
      ..moveTo(cx - r * 1.0, h * 0.52)
      ..quadraticBezierTo(cx, h * 0.08 - breathe, cx + r * 1.0, h * 0.52)
      ..close();
    p.color = baseColor;
    canvas.drawPath(capPath, p);
    // Spots
    p.color = _light(0.35).withValues(alpha: 0.6);
    canvas.drawCircle(Offset(cx - r * 0.3, h * 0.35), r * 0.1, p);
    canvas.drawCircle(Offset(cx + r * 0.2, h * 0.30), r * 0.08, p);
    canvas.drawCircle(Offset(cx + r * 0.05, h * 0.42), r * 0.07, p);
  }

  // -- Stone/Charcoal/Rust: angular rock --
  void _paintRock(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    final rockPath = Path()
      ..moveTo(cx - r * 0.2, h * 0.18)
      ..lineTo(cx + r * 0.6, h * 0.22)
      ..lineTo(cx + r * 0.85, h * 0.52)
      ..lineTo(cx + r * 0.5, h * 0.82)
      ..lineTo(cx - r * 0.4, h * 0.85)
      ..lineTo(cx - r * 0.85, h * 0.55)
      ..lineTo(cx - r * 0.6, h * 0.28)
      ..close();
    p.color = _dark(0.1);
    canvas.drawPath(rockPath, p);
    // Lighter face
    final facePath = Path()
      ..moveTo(cx - r * 0.2, h * 0.18)
      ..lineTo(cx + r * 0.6, h * 0.22)
      ..lineTo(cx + r * 0.85, h * 0.52)
      ..lineTo(cx, h * 0.50)
      ..lineTo(cx - r * 0.6, h * 0.28)
      ..close();
    p.color = _light(0.12);
    canvas.drawPath(facePath, p);
    // Subtle crack
    p.color = _dark(0.2).withValues(alpha: 0.4);
    p.style = PaintingStyle.stroke;
    p.strokeWidth = w * 0.02;
    canvas.drawLine(Offset(cx - r * 0.1, h * 0.35), Offset(cx + r * 0.2, h * 0.60), p);
    p.style = PaintingStyle.fill;
  }

  // -- Wood: log cross-section --
  void _paintWood(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    // Outer bark
    p.color = _dark(0.2);
    canvas.drawOval(Rect.fromCenter(center: Offset(cx, cy), width: r * 2.0, height: r * 2.0), p);
    // Inner wood
    p.color = baseColor;
    canvas.drawOval(Rect.fromCenter(center: Offset(cx, cy), width: r * 1.6, height: r * 1.6), p);
    // Rings
    p.color = _dark(0.12).withValues(alpha: 0.4);
    p.style = PaintingStyle.stroke;
    p.strokeWidth = w * 0.02;
    canvas.drawOval(Rect.fromCenter(center: Offset(cx, cy), width: r * 1.1, height: r * 1.1), p);
    canvas.drawOval(Rect.fromCenter(center: Offset(cx, cy), width: r * 0.55, height: r * 0.55), p);
    p.style = PaintingStyle.fill;
    // Center
    p.color = _light(0.15);
    canvas.drawCircle(Offset(cx, cy), r * 0.15, p);
  }

  // -- Glass: transparent diamond --
  void _paintGlass(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    final sparkle = _pulse(1.0) * 0.2;
    final glassDiamond = Path()
      ..moveTo(cx, h * 0.12)
      ..lineTo(cx + r * 0.85, cy)
      ..lineTo(cx, h * 0.88)
      ..lineTo(cx - r * 0.85, cy)
      ..close();
    p.color = baseColor.withValues(alpha: 0.3);
    canvas.drawPath(glassDiamond, p);
    // Edge highlight
    p.color = _light(0.5).withValues(alpha: 0.4 + sparkle);
    p.style = PaintingStyle.stroke;
    p.strokeWidth = w * 0.04;
    canvas.drawPath(glassDiamond, p);
    p.style = PaintingStyle.fill;
    // Refraction line
    p.color = Colors.white.withValues(alpha: 0.3 + sparkle);
    canvas.drawLine(Offset(cx - r * 0.3, h * 0.35), Offset(cx + r * 0.1, h * 0.65), p..strokeWidth = w * 0.03..style = PaintingStyle.stroke);
    p.style = PaintingStyle.fill;
    // Shine
    p.color = Colors.white.withValues(alpha: 0.5 + sparkle * 0.5);
    canvas.drawCircle(Offset(cx - r * 0.15, h * 0.35), r * 0.1, p);
  }

  // -- Dirt/Clay/Compost: mound with texture --
  void _paintDirt(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    final moundPath = Path()
      ..moveTo(w * 0.08, h * 0.88)
      ..quadraticBezierTo(w * 0.3, h * 0.25, cx, h * 0.20)
      ..quadraticBezierTo(w * 0.7, h * 0.25, w * 0.92, h * 0.88)
      ..close();
    p.color = _dark(0.1);
    canvas.drawPath(moundPath, p);
    // Lighter top
    final topPath = Path()
      ..moveTo(w * 0.2, h * 0.75)
      ..quadraticBezierTo(w * 0.35, h * 0.32, cx, h * 0.25)
      ..quadraticBezierTo(w * 0.65, h * 0.32, w * 0.8, h * 0.75)
      ..close();
    p.color = _light(0.1);
    canvas.drawPath(topPath, p);
    // Specks
    p.color = _light(0.25).withValues(alpha: 0.5);
    canvas.drawCircle(Offset(cx - r * 0.3, h * 0.50), r * 0.06, p);
    canvas.drawCircle(Offset(cx + r * 0.2, h * 0.42), r * 0.05, p);
    canvas.drawCircle(Offset(cx + r * 0.4, h * 0.60), r * 0.04, p);
  }

  // -- Snow: snowflake --
  void _paintSnowflake(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    final spin = phase * math.pi * 0.3;
    p.color = _light(0.1);
    p.style = PaintingStyle.stroke;
    p.strokeWidth = w * 0.045;
    p.strokeCap = StrokeCap.round;
    for (int i = 0; i < 6; i++) {
      final angle = spin + math.pi / 3 * i;
      final dx = math.cos(angle) * r * 0.85;
      final dy = math.sin(angle) * r * 0.85;
      canvas.drawLine(Offset(cx, cy), Offset(cx + dx, cy + dy), p);
      // Branch tips
      final bAngle1 = angle + 0.5;
      final bAngle2 = angle - 0.5;
      final bx = cx + dx * 0.65;
      final by = cy + dy * 0.65;
      final bl = r * 0.3;
      p.strokeWidth = w * 0.03;
      canvas.drawLine(Offset(bx, by), Offset(bx + math.cos(bAngle1) * bl, by + math.sin(bAngle1) * bl), p);
      canvas.drawLine(Offset(bx, by), Offset(bx + math.cos(bAngle2) * bl, by + math.sin(bAngle2) * bl), p);
      p.strokeWidth = w * 0.045;
    }
    p.style = PaintingStyle.fill;
    // Center jewel
    p.color = Colors.white.withValues(alpha: 0.6 + _pulse(0.8) * 0.3);
    canvas.drawCircle(Offset(cx, cy), r * 0.15, p);
  }

  // -- TNT: stick of dynamite --
  void _paintTNT(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    final sparkle = _pulse(3.0) * _amp;
    // Stick body
    p.color = baseColor;
    canvas.drawRRect(RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy + r * 0.1), width: r * 1.2, height: r * 1.8),
      Radius.circular(r * 0.2),
    ), p);
    // Dark band
    p.color = _dark(0.3);
    canvas.drawRect(Rect.fromCenter(center: Offset(cx, cy + r * 0.1), width: r * 1.2, height: r * 0.25), p);
    // Fuse
    p.color = const Color(0xFF8B7355);
    p.style = PaintingStyle.stroke;
    p.strokeWidth = w * 0.04;
    p.strokeCap = StrokeCap.round;
    final fusePath = Path()
      ..moveTo(cx, h * 0.18)
      ..quadraticBezierTo(cx + r * 0.3, h * 0.08, cx + r * 0.15, h * 0.02);
    canvas.drawPath(fusePath, p);
    p.style = PaintingStyle.fill;
    // Spark at fuse tip
    if (sparkle > 0.5) {
      p.color = Colors.yellow.withValues(alpha: sparkle);
      canvas.drawCircle(Offset(cx + r * 0.15, h * 0.02), r * 0.12, p);
      p.color = Colors.white.withValues(alpha: sparkle * 0.7);
      canvas.drawCircle(Offset(cx + r * 0.15, h * 0.02), r * 0.06, p);
    }
  }

  // -- Rainbow: arc of colors --
  void _paintRainbow(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    final shift = phase;
    p.style = PaintingStyle.stroke;
    p.strokeCap = StrokeCap.round;
    const colors = [
      Color(0xFFFF0000), Color(0xFFFF8800), Color(0xFFFFFF00),
      Color(0xFF00CC00), Color(0xFF0066FF), Color(0xFF8800FF),
    ];
    for (int i = 0; i < colors.length; i++) {
      final arcR = r * (1.0 - i * 0.12);
      p.color = colors[(i + (shift * 6).floor()) % colors.length].withValues(alpha: 0.8);
      p.strokeWidth = w * 0.06;
      canvas.drawArc(
        Rect.fromCenter(center: Offset(cx, h * 0.75), width: arcR * 2, height: arcR * 2),
        math.pi, math.pi, false, p,
      );
    }
    p.style = PaintingStyle.fill;
  }

  // -- Seed: oval seed shape --
  void _paintSeed(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    final sprout = _pulse(0.5) * r * 0.15 * _amp;
    // Seed body
    p.color = _dark(0.1);
    canvas.drawOval(Rect.fromCenter(center: Offset(cx, cy + r * 0.1), width: r * 1.0, height: r * 1.4), p);
    p.color = baseColor;
    canvas.drawOval(Rect.fromCenter(center: Offset(cx, cy + r * 0.1), width: r * 0.85, height: r * 1.2), p);
    // Line
    p.color = _dark(0.2);
    p.style = PaintingStyle.stroke;
    p.strokeWidth = w * 0.025;
    canvas.drawLine(Offset(cx, cy - r * 0.4), Offset(cx, cy + r * 0.6), p);
    p.style = PaintingStyle.fill;
    // Tiny sprout
    p.color = const Color(0xFF4CAF50).withValues(alpha: 0.6 + sprout * 2);
    final sproutPath = Path()
      ..moveTo(cx, cy - r * 0.45)
      ..quadraticBezierTo(cx - r * 0.25, cy - r * 0.7 - sprout, cx - r * 0.1, cy - r * 0.85 - sprout);
    p.style = PaintingStyle.stroke;
    p.strokeWidth = w * 0.04;
    p.strokeCap = StrokeCap.round;
    canvas.drawPath(sproutPath, p);
    p.style = PaintingStyle.fill;
  }

  // -- Bubble: transparent sphere --
  void _paintBubble(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    final wobble = _wave(1.0) * r * 0.04 * _amp;
    final br = r * 0.8 + wobble;
    // Outer circle
    p.color = baseColor.withValues(alpha: 0.2);
    canvas.drawCircle(Offset(cx, cy), br, p);
    // Edge ring
    p.color = _light(0.3).withValues(alpha: 0.35);
    p.style = PaintingStyle.stroke;
    p.strokeWidth = w * 0.04;
    canvas.drawCircle(Offset(cx, cy), br, p);
    p.style = PaintingStyle.fill;
    // Highlights
    p.color = Colors.white.withValues(alpha: 0.45 + _pulse(0.7) * 0.2);
    canvas.drawOval(Rect.fromCenter(
      center: Offset(cx - br * 0.3, cy - br * 0.3),
      width: br * 0.45, height: br * 0.3,
    ), p);
    p.color = Colors.white.withValues(alpha: 0.25);
    canvas.drawCircle(Offset(cx + br * 0.25, cy + br * 0.15), br * 0.1, p);
  }

  // -- Ash/Spore: scattered particles --
  void _paintParticles(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    for (int i = 0; i < 7; i++) {
      final angle = i * 0.9 + phase * 0.8;
      final dist = r * (0.3 + (i * 0.37 % 1.0) * 0.65);
      final px = cx + math.cos(angle) * dist + _wave(0.5, i * 0.14) * r * 0.1;
      final py = cy + math.sin(angle) * dist + _wave(0.7, i * 0.2) * r * 0.1;
      final pr = r * (0.06 + (i % 3) * 0.03);
      p.color = baseColor.withValues(alpha: 0.4 + (i % 3) * 0.15);
      canvas.drawCircle(Offset(px, py), pr, p);
    }
  }

  // -- Gas circles: floating transparent spheres --
  void _paintGasCircles(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    for (int i = 0; i < 4; i++) {
      final rise = _pulse(0.4, i * 0.25) * h * 0.08 * _amp;
      final ox = cx + _wave(0.6, i * 0.3) * r * 0.35;
      final oy = cy - rise + (i - 1.5) * r * 0.3;
      final cr = r * (0.35 + i * 0.04);
      p.color = baseColor.withValues(alpha: 0.18 + i * 0.05);
      canvas.drawCircle(Offset(ox, oy), cr, p);
      p.color = _light(0.3).withValues(alpha: 0.15);
      p.style = PaintingStyle.stroke;
      p.strokeWidth = w * 0.02;
      canvas.drawCircle(Offset(ox, oy), cr, p);
      p.style = PaintingStyle.fill;
    }
  }

  // -- Web: radial web pattern --
  void _paintWeb(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    p.color = baseColor.withValues(alpha: 0.6);
    p.style = PaintingStyle.stroke;
    p.strokeWidth = w * 0.02;
    p.strokeCap = StrokeCap.round;
    // Radial threads
    for (int i = 0; i < 8; i++) {
      final angle = math.pi / 4 * i;
      canvas.drawLine(
        Offset(cx, cy),
        Offset(cx + math.cos(angle) * r * 0.9, cy + math.sin(angle) * r * 0.9),
        p,
      );
    }
    // Concentric rings
    for (int ring = 1; ring <= 3; ring++) {
      final rr = r * ring * 0.28;
      p.color = baseColor.withValues(alpha: 0.3 + ring * 0.08);
      canvas.drawCircle(Offset(cx, cy), rr, p);
    }
    p.style = PaintingStyle.fill;
    // Center
    p.color = baseColor.withValues(alpha: 0.5);
    canvas.drawCircle(Offset(cx, cy), r * 0.08, p);
  }

  // -- Generic fallback: simple filled circle --
  void _paintGenericCircle(Canvas canvas, double w, double h, double cx, double cy, double r, Paint p) {
    p.color = _dark(0.15);
    canvas.drawCircle(Offset(cx, cy), r * 0.85, p);
    p.color = baseColor;
    canvas.drawCircle(Offset(cx, cy), r * 0.7, p);
    p.color = _light(0.25).withValues(alpha: 0.4 + _pulse(0.6) * 0.2);
    canvas.drawCircle(Offset(cx - r * 0.2, cy - r * 0.2), r * 0.2, p);
  }

  @override
  bool shouldRepaint(covariant AnimatedElementPreviewPainter old) =>
      old.elId != elId || old.phase != phase ||
      old.isSelected != isSelected || old.isHovered != isHovered;
}

