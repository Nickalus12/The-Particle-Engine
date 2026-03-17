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
  solids('Solids', AppColors.categorySolids, Icons.square_rounded),
  liquids('Liquids', AppColors.categoryLiquids, Icons.water_drop_rounded),
  energy('Energy', AppColors.categoryEnergy, Icons.bolt_rounded),
  life('Life', AppColors.categoryLife, Icons.eco_rounded),
  tools('Tools', AppColors.categoryTools, Icons.build_rounded);

  const ElementCategory(this.label, this.color, this.icon);
  final String label;
  final Color color;
  final IconData icon;

  /// Classify an element by its ID using the category bitmask table.
  /// Built-in elements use known mappings; custom elements derive from
  /// their registered [ElCat] bitmask.
  static ElementCategory forElementId(int elId) {
    // Built-in specific overrides for nuanced classification.
    switch (elId) {
      case El.sand:
      case El.stone:
      case El.dirt:
      case El.mud:
      case El.glass:
      case El.metal:
      case El.ice:
      case El.snow:
      case El.ash:
        return ElementCategory.solids;
      case El.water:
      case El.oil:
      case El.acid:
      case El.lava:
        return ElementCategory.liquids;
      case El.fire:
      case El.smoke:
      case El.steam:
      case El.lightning:
      case El.rainbow:
      case El.bubble:
        return ElementCategory.energy;
      case El.wood:
      case El.seed:
      case El.plant:
      case El.ant:
        return ElementCategory.life;
      case El.tnt:
        return ElementCategory.tools;
    }
    // Custom elements: derive category from bitmask.
    if (elId >= 0 && elId < maxElements) {
      final cat = elCategory[elId];
      if (cat & ElCat.liquid != 0) return ElementCategory.liquids;
      if (cat & ElCat.gas != 0) return ElementCategory.energy;
      if (cat & ElCat.organic != 0) return ElementCategory.life;
      if (cat & ElCat.solid != 0) return ElementCategory.solids;
    }
    return ElementCategory.tools;
  }
}

/// Sleek bottom drawer element palette with category filtering.
///
/// Slides up from the bottom with a frosted glass background. Elements are
/// displayed as a smooth horizontal grid, grouped by category. Long-press
/// shows an info card.
class ElementPalette extends StatefulWidget {
  const ElementPalette({super.key, required this.game, this.onInteraction});

  final ParticleEngineGame game;
  final VoidCallback? onInteraction;

  @override
  State<ElementPalette> createState() => _ElementPaletteState();
}

class _ElementPaletteState extends State<ElementPalette>
    with SingleTickerProviderStateMixin {
  int _selectedElId = El.sand;
  ElementCategory _activeCategory = ElementCategory.solids;
  OverlayEntry? _infoOverlay;

  late final AnimationController _slideController;
  late final Animation<Offset> _slideAnimation;

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
  }

  @override
  void dispose() {
    _slideController.dispose();
    _dismissInfoCard();
    super.dispose();
  }

  void _select(int elId) {
    setState(() => _selectedElId = elId);
    widget.game.sandboxWorld.sandboxComponent.selectedElement = elId;
    widget.onInteraction?.call();
  }

  /// Dynamic list of placeable element IDs from the registry.
  List<int> get _placeableElements => ElementRegistry.placeableIds;

  List<int> get _filteredElements {
    final elements = _placeableElements
        .where((id) => ElementCategory.forElementId(id) == _activeCategory)
        .toList();
    // Add eraser tool to the Tools category.
    if (_activeCategory == ElementCategory.tools) {
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
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12, left: 8, right: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(ParticleTheme.radiusLarge),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                decoration: ParticleTheme.glassDecoration(
                  borderRadius: ParticleTheme.radiusLarge,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildSelectedIndicator(),
                    _buildCategoryBar(),
                    _buildElementGrid(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Shows the currently selected element name and color prominently.
  Widget _buildSelectedIndicator() {
    final color = _colorForId(_selectedElId);
    final name = _nameForId(_selectedElId);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          AnimatedContainer(
            duration: ParticleTheme.fastDuration,
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(5),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.5),
                  blurRadius: 10,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          AnimatedSwitcher(
            duration: ParticleTheme.fastDuration,
            child: Text(
              name,
              key: ValueKey(_selectedElId),
              style: AppTypography.subheading.copyWith(
                fontSize: 14,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: () {
              widget.game.exitCreationMode();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.glass,
                borderRadius: BorderRadius.circular(ParticleTheme.radiusSmall),
                border: Border.all(
                  color: AppColors.glassBorder,
                  width: 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.visibility_rounded,
                    size: 14,
                    color: AppColors.textDim,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Observe',
                    style: AppTypography.caption.copyWith(
                      color: AppColors.textDim,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryBar() {
    return SizedBox(
      height: 36,
      child: Row(
        children: ElementCategory.values.map((cat) {
          final isActive = cat == _activeCategory;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                setState(() => _activeCategory = cat);
                widget.onInteraction?.call();
              },
              child: AnimatedContainer(
                duration: ParticleTheme.fastDuration,
                curve: ParticleTheme.defaultCurve,
                decoration: BoxDecoration(
                  color: isActive
                      ? cat.color.withValues(alpha: 0.15)
                      : Colors.transparent,
                  border: Border(
                    bottom: BorderSide(
                      color: isActive ? cat.color : Colors.transparent,
                      width: isActive ? 2.5 : 1,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      cat.icon,
                      size: 16,
                      color: isActive
                          ? cat.color
                          : AppColors.textDim,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      cat.label,
                      style: AppTypography.caption.copyWith(
                        color: isActive
                            ? cat.color
                            : AppColors.textDim,
                        fontWeight:
                            isActive ? FontWeight.w700 : FontWeight.w500,
                        fontSize: isActive ? 11 : 10,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// Get the display color for an element ID from the registry.
  static Color _colorForId(int elId) {
    if (elId == El.eraser) return const Color(0xFF666680);
    if (elId >= 0 && elId < maxElements) return Color(baseColors[elId]);
    return const Color(0xFF808080);
  }

  /// Get the display name for an element ID from the registry.
  static String _nameForId(int elId) {
    if (elId == El.eraser) return 'Eraser';
    if (elId >= 0 && elId < maxElements) return elementNames[elId];
    return '???';
  }

  Widget _buildElementGrid() {
    final elements = _filteredElements;
    return SizedBox(
      height: 72,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        itemCount: elements.length,
        itemBuilder: (context, index) {
          final elId = elements[index];
          final isSelected = elId == _selectedElId;
          final color = _colorForId(elId);
          final name = _nameForId(elId);
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _ElementTile(
              elId: elId,
              isSelected: isSelected,
              color: color,
              name: name,
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

/// Individual element tile with hover support for desktop.
class _ElementTile extends StatefulWidget {
  const _ElementTile({
    required this.elId,
    required this.isSelected,
    required this.color,
    required this.name,
    required this.onTap,
    required this.onLongPressStart,
  });

  final int elId;
  final bool isSelected;
  final Color color;
  final String name;
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
    final isHighlighted = isSelected || _hovered;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPressStart: widget.onLongPressStart,
        child: AnimatedContainer(
          duration: ParticleTheme.fastDuration,
          curve: ParticleTheme.defaultCurve,
          width: 56,
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.surfaceBright
                : _hovered
                    ? AppColors.surface.withValues(alpha: 0.8)
                    : AppColors.surface.withValues(alpha: 0.5),
            borderRadius:
                BorderRadius.circular(ParticleTheme.radiusMedium),
            border: Border.all(
              color: isSelected
                  ? color
                  : _hovered
                      ? color.withValues(alpha: 0.3)
                      : Colors.white.withValues(alpha: 0.06),
              width: isSelected ? 2.0 : 0.5,
            ),
            boxShadow: isSelected
                ? ParticleTheme.glowShadow(color, spread: 1)
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: ParticleTheme.fastDuration,
                curve: ParticleTheme.defaultCurve,
                width: isHighlighted ? 30 : 28,
                height: isHighlighted ? 30 : 28,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.white.withValues(
                      alpha: isHighlighted ? 0.3 : 0.1,
                    ),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(
                        alpha: isHighlighted ? 0.6 : 0.2,
                      ),
                      blurRadius: isHighlighted ? 12 : 4,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.name,
                style: AppTypography.caption.copyWith(
                  color: isHighlighted
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                  fontSize: 10,
                  fontWeight: isHighlighted
                      ? FontWeight.w700
                      : FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
