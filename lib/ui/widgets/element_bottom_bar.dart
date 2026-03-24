import 'dart:ui';

import 'package:flutter/material.dart';

import '../../game/particle_engine_game.dart';
import '../../simulation/element_registry.dart';
import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';
import 'element_info_card.dart';
import 'element_palette.dart' show ElementCategory, ElementPalette;
import 'vector_element_icons.dart';

/// Bottom-anchored horizontal element bar with category tabs and scrollable tiles.
///
/// Replaces the cramped 80px left sidebar with a full-width bottom strip.
/// Category tabs sit at the top; large, beautiful element tiles scroll horizontally below.
class ElementBottomBar extends StatefulWidget {
  const ElementBottomBar({super.key, required this.game, this.onInteraction});

  final ParticleEngineGame game;
  final VoidCallback? onInteraction;

  @override
  State<ElementBottomBar> createState() => _ElementBottomBarState();
}

class _ElementBottomBarState extends State<ElementBottomBar>
    with TickerProviderStateMixin {
  int _selectedElId = El.sand;
  ElementCategory _activeCategory = ElementCategory.compounds;
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
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: ParticleTheme.defaultCurve,
    ));
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
    _selectScale = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _selectBounce, curve: Curves.elasticOut),
    );
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

    return SlideTransition(
      position: _slideAnimation,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(ParticleTheme.radiusLarge),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: Container(
                decoration: BoxDecoration(
                  // Dark translucent instead of grey glass
                  color: const Color(0xCC0A0A14),
                  borderRadius: BorderRadius.circular(ParticleTheme.radiusLarge),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                    width: 0.5,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x50000000),
                      blurRadius: 30,
                      offset: Offset(0, -4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Category tabs
                    _buildCategoryTabs(),
                    // Colored accent line below tabs
                    Container(
                      height: 1.5,
                      margin: const EdgeInsets.symmetric(horizontal: 12),
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
                    _buildElementStrip(elements),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryTabs() {
    return SizedBox(
      height: 42,
      child: Row(
        children: [
          const SizedBox(width: 6),
          // Selected element preview
          _buildSelectedPreview(),
          const SizedBox(width: 4),
          // Vertical divider
          Container(
            width: 0.5,
            height: 24,
            color: Colors.white.withValues(alpha: 0.1),
          ),
          const SizedBox(width: 4),
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
          _buildObserveButton(),
          const SizedBox(width: 6),
        ],
      ),
    );
  }

  Widget _buildSelectedPreview() {
    final color = ElementPalette.colorForId(_selectedElId);
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
                width: 34,
                height: 34,
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
                        _selectedElId, color, _iconAnimController.value),
                    size: const Size(34, 34),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildObserveButton() {
    return GestureDetector(
      onTap: () => widget.game.exitCreationMode(),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.1),
            width: 0.5,
          ),
        ),
        child: const Icon(
          Icons.visibility_rounded,
          size: 16,
          color: AppColors.textDim,
        ),
      ),
    );
  }

  Widget _buildElementStrip(List<int> elements) {
    return SizedBox(
      height: 76,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        itemCount: elements.length,
        itemBuilder: (context, index) {
          final elId = elements[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: _ElementTile(
              elId: elId,
              isSelected: elId == _selectedElId,
              color: ElementPalette.colorForId(elId),
              name: ElementPalette.nameForId(elId),
              categoryColor: _activeCategory.color,
              iconAnimController: _iconAnimController,
              glowController: _glowController,
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
            final scale = _hovered && !isSelected ? 1.06 : 1.0;

            return Transform.scale(
              scale: scale,
              child: SizedBox(
                width: 56,
                height: 64,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Icon container
                    Container(
                      width: 44,
                      height: 44,
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
                                  alpha: 0.15 + glowT * 0.2),
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
                          painter: VectorElementIcon(
                            widget.elId, color, phase),
                          size: const Size(44, 44),
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    // Label
                    Text(
                      widget.name,
                      style: AppTypography.caption.copyWith(
                        fontSize: 8,
                        fontWeight:
                            isSelected ? FontWeight.w700 : FontWeight.w500,
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
