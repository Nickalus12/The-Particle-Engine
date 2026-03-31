import 'dart:ui';

import 'package:flutter/material.dart';

import '../../game/particle_engine_game.dart';
import '../../simulation/element_registry.dart';
import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';
import 'element_info_card.dart';
import 'element_palette.dart' show ElementCategory;
import 'vector_element_icons.dart';

Color _colorForId(int elId) {
  if (elId == El.eraser) return const Color(0xFF666680);
  if (elId >= 0 && elId < maxElements) return Color(baseColors[elId]);
  return const Color(0xFF808080);
}

String _nameForId(int elId) {
  if (elId == El.eraser) return 'Eraser';
  if (elId >= 0 && elId < maxElements) return elementNames[elId];
  return '???';
}

/// Bottom-anchored horizontal element bar with category tabs and scrollable tiles.
///
/// Replaces the cramped 80px left sidebar with a full-width bottom strip.
/// Category tabs sit at the top; large, beautiful element tiles scroll horizontally below.
class ElementBottomBar extends StatefulWidget {
  const ElementBottomBar({
    super.key,
    required this.game,
    this.onInteraction,
    this.interactionKey,
  });

  final ParticleEngineGame game;
  final VoidCallback? onInteraction;
  final Key? interactionKey;

  static double estimatedHeightFor(MediaQueryData media) {
    final compact = media.size.height < 760;
    final ultraCompact = media.size.height < 680;
    final bottomInset = media.padding.bottom;
    final tabsHeight = compact ? 38.0 : 42.0;
    final accentLineHeight = compact ? 1.0 : 1.5;
    final stripHeight = (compact || ultraCompact) ? 66.0 : 76.0;
    final innerVertical = compact ? 8.0 : 12.0;
    final outerBottom = 8 + (bottomInset > 0 ? bottomInset * 0.35 : 0);
    return tabsHeight +
        accentLineHeight +
        stripHeight +
        innerVertical +
        outerBottom;
  }

  @override
  State<ElementBottomBar> createState() => _ElementBottomBarState();
}

class _ElementBottomBarState extends State<ElementBottomBar>
    with TickerProviderStateMixin {
  int _selectedElId = El.sand;
  ElementCategory _activeCategory = ElementCategory.solids;
  OverlayEntry? _infoOverlay;

  late final AnimationController _slideController;
  late final Animation<Offset> _slideAnimation;
  late final AnimationController _iconAnimController;
  late final AnimationController _glowController;
  late final AnimationController _selectBounce;
  late final Animation<double> _selectScale;

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      vsync: this,
      duration: ParticleTheme.normalDuration,
    );
    _slideAnimation = Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _slideController,
            curve: ParticleTheme.defaultCurve,
          ),
        );
    _slideController.forward();

    _iconAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    )..repeat();

    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _selectBounce = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _selectScale = Tween<double>(
      begin: 1.0,
      end: 1.15,
    ).animate(CurvedAnimation(parent: _selectBounce, curve: Curves.elasticOut));
  }

  @override
  void dispose() {
    _iconAnimController.dispose();
    _glowController.dispose();
    _slideController.dispose();
    _selectBounce.dispose();
    _dismissInfoCard();
    super.dispose();
  }

  void _select(int elId) {
    setState(() => _selectedElId = elId);
    widget.game.sandboxWorld.sandboxComponent.selectedElement = elId;
    widget.onInteraction?.call();
    // Bounce animation
    _selectBounce.forward(from: 0);
  }

  List<int> _elementsForCategory(ElementCategory cat) {
    final elements = ElementRegistry.placeableIds
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
    final elements = _elementsForCategory(_activeCategory);
    final media = MediaQuery.of(context);
    final compact = media.size.height < 760;
    final ultraCompact = media.size.height < 680;
    final bottomInset = media.padding.bottom;

    return SlideTransition(
      position: _slideAnimation,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          key: const ValueKey('element_bottom_bar_container'),
          padding: EdgeInsets.only(
            left: 8,
            right: 8,
            bottom: 8 + (bottomInset > 0 ? bottomInset * 0.35 : 0),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(ParticleTheme.radiusLarge),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: Container(
                key: widget.interactionKey,
                decoration: ParticleTheme.panelDecoration(
                  borderRadius: ParticleTheme.radiusLarge,
                  accent: _activeCategory.color,
                  baseColor: const Color(0xCC0A0A14),
                  borderOpacity: 0.08,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Category tabs
                    _buildCategoryTabs(compact: compact),
                    // Colored accent line below tabs
                    Container(
                      height: compact ? 1.0 : 1.5,
                      margin: EdgeInsets.symmetric(
                        horizontal: compact ? 8 : 12,
                      ),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.transparent,
                            _activeCategory.color.withValues(alpha: 0.5),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                    // Element tiles
                    _buildElementStrip(
                      elements,
                      compact: compact || ultraCompact,
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

  Widget _buildCategoryTabs({required bool compact}) {
    final tabHeight = compact ? 38.0 : 42.0;
    return SizedBox(
      height: tabHeight,
      child: Row(
        children: [
          SizedBox(width: compact ? 4 : 6),
          // Selected element preview
          _buildSelectedPreview(compact: compact),
          SizedBox(width: compact ? 2 : 4),
          // Vertical divider
          Container(
            width: 0.5,
            height: compact ? 20 : 24,
            color: Colors.white.withValues(alpha: 0.1),
          ),
          SizedBox(width: compact ? 2 : 4),
          // Category tabs
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              children: ElementCategory.values.map((cat) {
                return _CategoryTab(
                  category: cat,
                  isActive: cat == _activeCategory,
                  onTap: () {
                    setState(() => _activeCategory = cat);
                    widget.onInteraction?.call();
                  },
                );
              }).toList(),
            ),
          ),
          // Observe button
          _buildObserveButton(compact: compact),
          SizedBox(width: compact ? 4 : 6),
        ],
      ),
    );
  }

  Widget _buildSelectedPreview({required bool compact}) {
    final tile = compact ? 30.0 : 34.0;
    final color = _colorForId(_selectedElId);
    return AnimatedBuilder(
      animation: Listenable.merge([_glowController, _selectBounce]),
      builder: (context, _) {
        final glowT = Curves.easeInOut.transform(_glowController.value);
        return AnimatedBuilder(
          animation: _selectScale,
          builder: (context, _) {
            return Transform.scale(
              scale: _selectScale.value,
              child: Container(
                width: tile,
                height: tile,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.2 + glowT * 0.2),
                      blurRadius: 8 + glowT * 4,
                      spreadRadius: glowT,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CustomPaint(
                    painter: VectorElementIcon(
                      _selectedElId,
                      color,
                      _iconAnimController.value,
                    ),
                    size: Size(tile, tile),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildObserveButton({required bool compact}) {
    final size = compact ? 28.0 : 32.0;
    return GestureDetector(
      onTap: () => widget.game.exitCreationMode(),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.1),
            width: 0.5,
          ),
        ),
        child: Icon(
          Icons.visibility_rounded,
          size: compact ? 14 : 16,
          color: AppColors.textDim,
        ),
      ),
    );
  }

  Widget _buildElementStrip(List<int> elements, {required bool compact}) {
    return SizedBox(
      height: compact ? 66 : 76,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 6 : 8,
          vertical: compact ? 4 : 6,
        ),
        itemCount: elements.length,
        itemBuilder: (context, index) {
          final elId = elements[index];
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 3),
            child: _ElementTile(
              elId: elId,
              isSelected: elId == _selectedElId,
              color: _colorForId(elId),
              name: _nameForId(elId),
              categoryColor: _activeCategory.color,
              iconAnimController: _iconAnimController,
              glowController: _glowController,
              compact: compact,
              onTap: () => _select(elId),
              onLongPressStart: (details) {
                _showInfoCard(context, elId, details.globalPosition);
              },
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Category tab -- compact horizontal pill
// ---------------------------------------------------------------------------

class _CategoryTab extends StatefulWidget {
  const _CategoryTab({
    required this.category,
    required this.isActive,
    required this.onTap,
  });

  final ElementCategory category;
  final bool isActive;
  final VoidCallback onTap;

  @override
  State<_CategoryTab> createState() => _CategoryTabState();
}

class _CategoryTabState extends State<_CategoryTab> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cat = widget.category;
    final isActive = widget.isActive;
    final isHighlighted = isActive || _hovered;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: ParticleTheme.fastDuration,
          margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: isActive
                ? cat.color.withValues(alpha: 0.2)
                : _hovered
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: isActive
                ? Border.all(
                    color: cat.color.withValues(alpha: 0.4),
                    width: 0.8,
                  )
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                cat.icon,
                size: 14,
                color: isHighlighted ? cat.color : AppColors.textDim,
              ),
              const SizedBox(width: 5),
              Text(
                cat.label,
                style: AppTypography.caption.copyWith(
                  fontSize: 10,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                  color: isHighlighted ? cat.color : AppColors.textSecondary,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Element tile -- 56px with vector icon and label
// ---------------------------------------------------------------------------

class _ElementTile extends StatefulWidget {
  const _ElementTile({
    required this.elId,
    required this.isSelected,
    required this.color,
    required this.name,
    required this.categoryColor,
    required this.iconAnimController,
    required this.glowController,
    required this.compact,
    required this.onTap,
    required this.onLongPressStart,
  });

  final int elId;
  final bool isSelected;
  final Color color;
  final String name;
  final Color categoryColor;
  final AnimationController iconAnimController;
  final AnimationController glowController;
  final bool compact;
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
    final outerW = widget.compact ? 50.0 : 56.0;
    final outerH = widget.compact ? 56.0 : 64.0;
    final iconBox = widget.compact ? 38.0 : 44.0;
    final labelSize = widget.compact ? 7.0 : 8.0;

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
            final scale = _hovered && !isSelected ? 1.06 : 1.0;

            return Transform.scale(
              scale: scale,
              child: SizedBox(
                width: outerW,
                height: outerH,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Icon container
                    Container(
                      width: iconBox,
                      height: iconBox,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: isSelected
                            ? color.withValues(alpha: 0.12)
                            : _hovered
                            ? Colors.white.withValues(alpha: 0.06)
                            : Colors.white.withValues(alpha: 0.03),
                        border: Border.all(
                          color: isSelected
                              ? color.withValues(alpha: 0.7)
                              : _hovered
                              ? color.withValues(alpha: 0.25)
                              : Colors.white.withValues(alpha: 0.06),
                          width: isSelected ? 1.5 : 0.5,
                        ),
                        boxShadow: [
                          if (isSelected) ...[
                            BoxShadow(
                              color: color.withValues(
                                alpha: 0.15 + glowT * 0.2,
                              ),
                              blurRadius: 10 + glowT * 6,
                              spreadRadius: glowT,
                            ),
                          ] else if (_hovered)
                            BoxShadow(
                              color: color.withValues(alpha: 0.15),
                              blurRadius: 8,
                            ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8.5),
                        child: CustomPaint(
                          painter: VectorElementIcon(widget.elId, color, phase),
                          size: Size(iconBox, iconBox),
                        ),
                      ),
                    ),
                    SizedBox(height: widget.compact ? 1 : 2),
                    // Label
                    Text(
                      widget.name,
                      style: AppTypography.caption.copyWith(
                        fontSize: labelSize,
                        fontWeight: isSelected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: isSelected
                            ? color
                            : _hovered
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
