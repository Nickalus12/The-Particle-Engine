import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../game/particle_engine_game.dart';
import '../../simulation/element_registry.dart';
import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';
import 'element_info_card.dart';

/// Element category for grouping in the palette.
enum ElementCategory {
  solids('Solids', AppColors.categorySolids, Icons.landscape_rounded),
  liquids('Liquids', AppColors.categoryLiquids, Icons.water_drop_rounded),
  energy('Energy', AppColors.categoryEnergy, Icons.local_fire_department_rounded),
  life('Life', AppColors.categoryLife, Icons.park_rounded),
  tools('Tools', AppColors.categoryTools, Icons.auto_fix_high_rounded);

  const ElementCategory(this.label, this.color, this.icon);
  final String label;
  final Color color;
  final IconData icon;

  /// Classify an element by its ID using the category bitmask table.
  static ElementCategory forElementId(int elId) {
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

/// Left-side vertical element palette panel with collapsible category sections.
///
/// Slides in from the left edge with a spring curve. Narrow (80px) glassmorphic
/// panel with vertical scrolling. Category icons act as section headers that
/// expand/collapse their element grids. Long-press shows an info card.
/// Keyboard shortcuts 1-9 select elements in the active category.
class ElementPalette extends StatefulWidget {
  const ElementPalette({super.key, required this.game, this.onInteraction});

  final ParticleEngineGame game;
  final VoidCallback? onInteraction;

  @override
  State<ElementPalette> createState() => _ElementPaletteState();
}

class _ElementPaletteState extends State<ElementPalette>
    with TickerProviderStateMixin {
  int _selectedElId = El.sand;
  ElementCategory _activeCategory = ElementCategory.solids;
  OverlayEntry? _infoOverlay;

  late final AnimationController _slideController;
  late final Animation<Offset> _slideAnimation;

  late final AnimationController _glowController;
  late final Animation<double> _glowAnimation;

  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(-1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutBack,
    ));
    _slideController.forward();

    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _glowAnimation = Tween<double>(begin: 0.3, end: 0.7).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _slideController.dispose();
    _glowController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
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

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    final key = event.logicalKey;
    // 1-9 quick select within active category
    final index = switch (key) {
      LogicalKeyboardKey.digit1 => 0,
      LogicalKeyboardKey.digit2 => 1,
      LogicalKeyboardKey.digit3 => 2,
      LogicalKeyboardKey.digit4 => 3,
      LogicalKeyboardKey.digit5 => 4,
      LogicalKeyboardKey.digit6 => 5,
      LogicalKeyboardKey.digit7 => 6,
      LogicalKeyboardKey.digit8 => 7,
      LogicalKeyboardKey.digit9 => 8,
      _ => null,
    };

    if (index != null) {
      final elements = _elementsForCategory(_activeCategory);
      if (index < elements.length) {
        _select(elements[index]);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: SlideTransition(
        position: _slideAnimation,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 8, top: 8, bottom: 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(ParticleTheme.radiusLarge),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
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
                      // Selected element indicator at top
                      _buildSelectedIndicator(),
                      _thinDivider(),
                      // Category tabs + scrollable element grid
                      Flexible(
                        child: _buildCategoryContent(),
                      ),
                      _thinDivider(),
                      // Observe mode button at bottom
                      _buildObserveButton(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSelectedIndicator() {
    final color = _colorForId(_selectedElId);
    final name = _nameForId(_selectedElId);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        children: [
          AnimatedBuilder(
            animation: _glowAnimation,
            builder: (context, child) => AnimatedScale(
              scale: 1.0,
              duration: ParticleTheme.fastDuration,
              child: AnimatedContainer(
                duration: ParticleTheme.fastDuration,
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: color.withValues(alpha: 0.8),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.3 + _glowAnimation.value * 0.3),
                      blurRadius: 12 + _glowAnimation.value * 6,
                      spreadRadius: 1,
                    ),
                    BoxShadow(
                      color: color.withValues(alpha: 0.15),
                      blurRadius: 24,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CustomPaint(
                    painter: _ElementPreviewPainter(_selectedElId, color),
                    size: const Size(36, 36),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            name,
            style: AppTypography.caption.copyWith(
              fontSize: 9,
              color: Colors.white,
              fontWeight: FontWeight.w700,
              shadows: [
                Shadow(
                  color: color.withValues(alpha: 0.6),
                  blurRadius: 6,
                ),
              ],
            ),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryContent() {
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: false,
      thickness: 2,
      radius: const Radius.circular(1),
      child: SingleChildScrollView(
        controller: _scrollController,
        physics: const BouncingScrollPhysics(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: ElementCategory.values.map((cat) {
            final isActive = cat == _activeCategory;
            final elements = _elementsForCategory(cat);
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Category header button
                _CategoryHeader(
                  category: cat,
                  isActive: isActive,
                  elementCount: elements.length,
                  onTap: () {
                    setState(() => _activeCategory = cat);
                    widget.onInteraction?.call();
                  },
                ),
                // Animated category content
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) {
                    return SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, -0.05),
                        end: Offset.zero,
                      ).animate(animation),
                      child: FadeTransition(
                        opacity: animation,
                        child: SizeTransition(
                          sizeFactor: animation,
                          axisAlignment: -1.0,
                          child: child,
                        ),
                      ),
                    );
                  },
                  child: isActive
                      ? Column(
                          key: ValueKey('cat_${cat.name}'),
                          mainAxisSize: MainAxisSize.min,
                          children: List.generate(elements.length, (i) {
                            final elId = elements[i];
                            final isSelected = elId == _selectedElId;
                            final color = _colorForId(elId);
                            final name = _nameForId(elId);
                            return _ElementTile(
                              elId: elId,
                              isSelected: isSelected,
                              color: color,
                              name: name,
                              shortcutIndex: i < 9 ? i + 1 : null,
                              glowAnimation: _glowAnimation,
                              onTap: () => _select(elId),
                              onLongPressStart: (details) {
                                _showInfoCard(
                                    context, elId, details.globalPosition);
                              },
                            );
                          }),
                        )
                      : const SizedBox.shrink(key: ValueKey('empty')),
                ),
                if (!isActive && cat != ElementCategory.values.last)
                  _thinDivider(),
              ],
            );
          }).toList(),
        ),
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

/// Category header icon button in the vertical palette.
class _CategoryHeader extends StatefulWidget {
  const _CategoryHeader({
    required this.category,
    required this.isActive,
    required this.elementCount,
    required this.onTap,
  });

  final ElementCategory category;
  final bool isActive;
  final int elementCount;
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
          message: '${cat.label} (${widget.elementCount})',
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
            ),
            child: Column(
              children: [
                AnimatedScale(
                  scale: isActive ? 1.1 : 1.0,
                  duration: ParticleTheme.fastDuration,
                  curve: Curves.easeOutCubic,
                  child: AnimatedContainer(
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
                ),
                const SizedBox(height: 3),
                // Active category: filled pill background
                AnimatedContainer(
                  duration: ParticleTheme.fastDuration,
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: isActive
                        ? cat.color.withValues(alpha: 0.2)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        cat.label,
                        style: AppTypography.caption.copyWith(
                          fontSize: 9,
                          color: isActive ? cat.color : AppColors.textSecondary,
                          fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                      if (isActive) ...[
                        const SizedBox(width: 2),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0),
                          decoration: BoxDecoration(
                            color: cat.color.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${widget.elementCount}',
                            style: AppTypography.caption.copyWith(
                              fontSize: 7,
                              color: cat.color,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
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

/// Individual element tile for vertical layout — compact square with preview.
class _ElementTile extends StatefulWidget {
  const _ElementTile({
    required this.elId,
    required this.isSelected,
    required this.color,
    required this.name,
    required this.shortcutIndex,
    required this.glowAnimation,
    required this.onTap,
    required this.onLongPressStart,
  });

  final int elId;
  final bool isSelected;
  final Color color;
  final String name;
  final int? shortcutIndex;
  final Animation<double> glowAnimation;
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
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          scale: isSelected ? 1.12 : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          child: isSelected
              ? AnimatedBuilder(
                  animation: widget.glowAnimation,
                  builder: (context, child) => _buildTileContent(
                    isSelected: isSelected,
                    color: color,
                    isHighlighted: isHighlighted,
                    glowValue: widget.glowAnimation.value,
                  ),
                )
              : _buildTileContent(
                  isSelected: isSelected,
                  color: color,
                  isHighlighted: isHighlighted,
                  glowValue: 0.5,
                ),
        ),
      ),
    );
  }

  Widget _buildTileContent({
    required bool isSelected,
    required Color color,
    required bool isHighlighted,
    required double glowValue,
  }) {
    return AnimatedContainer(
      duration: ParticleTheme.fastDuration,
      curve: ParticleTheme.defaultCurve,
      margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
      constraints: const BoxConstraints(minHeight: 48),
      decoration: BoxDecoration(
        color: isSelected
            ? AppColors.surfaceBright
            : _hovered
                ? AppColors.surface.withValues(alpha: 0.8)
                : Colors.transparent,
        borderRadius: BorderRadius.circular(ParticleTheme.radiusSmall),
        border: Border.all(
          color: isSelected
              ? color.withValues(alpha: 0.7 + glowValue * 0.3)
              : _hovered
                  ? color.withValues(alpha: 0.3)
                  : Colors.transparent,
          width: isSelected ? 1.5 : 0.5,
        ),
        boxShadow: isSelected
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.25 + glowValue * 0.2),
                  blurRadius: 10 + glowValue * 6,
                  spreadRadius: 0,
                ),
                BoxShadow(
                  color: color.withValues(alpha: 0.1),
                  blurRadius: 20,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Stack(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: ParticleTheme.fastDuration,
                curve: ParticleTheme.defaultCurve,
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSelected
                        ? color.withValues(alpha: 0.8)
                        : _hovered
                            ? color.withValues(alpha: 0.5)
                            : Colors.white.withValues(alpha: 0.15),
                    width: isSelected ? 2 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(
                        alpha: isSelected ? 0.7 : isHighlighted ? 0.4 : 0.1,
                      ),
                      blurRadius: isSelected ? 12 : isHighlighted ? 8 : 2,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: CustomPaint(
                    painter: _ElementPreviewPainter(widget.elId, color),
                    size: const Size(36, 36),
                  ),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                widget.name,
                style: AppTypography.caption.copyWith(
                  color: isSelected
                      ? Colors.white
                      : isHighlighted
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                  fontSize: 9,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  shadows: isSelected
                      ? [
                          Shadow(
                            color: color.withValues(alpha: 0.6),
                            blurRadius: 4,
                          ),
                        ]
                      : null,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          // Keyboard shortcut badge
          if (widget.shortcutIndex != null)
            Positioned(
              top: 0,
              right: 0,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: isSelected
                      ? color.withValues(alpha: 0.6)
                      : AppColors.surface.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(
                    color: isSelected
                        ? color.withValues(alpha: 0.8)
                        : Colors.white.withValues(alpha: 0.1),
                    width: 0.5,
                  ),
                ),
                child: Center(
                  child: Text(
                    '${widget.shortcutIndex}',
                    style: TextStyle(
                      fontSize: 7,
                      fontWeight: FontWeight.w600,
                      color: isSelected
                          ? Colors.white
                          : AppColors.textDim,
                      height: 1.0,
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

/// Paints a small textured preview of an element, simulating how it looks
/// in the pixel renderer with spatial variation and element-specific effects.
class _ElementPreviewPainter extends CustomPainter {
  _ElementPreviewPainter(this.elId, this.baseColor);
  final int elId;
  final Color baseColor;

  static int _smoothHash(int x, int y) =>
      ((x * 374761393 + y * 668265263) * 1274126177) & 0x7FFFFFFF;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    final cellSize = size.width / 8;

    if (elId == El.eraser) {
      for (int py = 0; py < 8; py++) {
        for (int px = 0; px < 8; px++) {
          final isDark = (px + py) % 2 == 0;
          paint.color = isDark
              ? const Color(0xFF444460)
              : const Color(0xFF555580);
          canvas.drawRect(
            Rect.fromLTWH(px * cellSize, py * cellSize, cellSize, cellSize),
            paint,
          );
        }
      }
      paint
        ..color = const Color(0xAAFF4444)
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke;
      canvas.drawLine(Offset(size.width * 0.2, size.height * 0.2),
          Offset(size.width * 0.8, size.height * 0.8), paint);
      canvas.drawLine(Offset(size.width * 0.8, size.height * 0.2),
          Offset(size.width * 0.2, size.height * 0.8), paint);
      return;
    }

    final r = (baseColor.r * 255.0).round().clamp(0, 255);
    final g = (baseColor.g * 255.0).round().clamp(0, 255);
    final b = (baseColor.b * 255.0).round().clamp(0, 255);

    for (int py = 0; py < 8; py++) {
      for (int px = 0; px < 8; px++) {
        final hash = _smoothHash(px + 10, py + 10);
        final variation = (hash % 30) - 15;

        int cr = r, cg = g, cb = b, ca = 255;

        switch (elId) {
          case El.sand:
            final band = _smoothHash(px + 200, py * 2 + 100) % 12 - 6;
            cr = (215 + variation ~/ 2 + band).clamp(190, 240);
            cg = (195 + variation ~/ 2 + band).clamp(172, 222);
            cb = (130 + variation ~/ 3).clamp(105, 158);
          case El.water:
            final depth = py;
            final shimmer = px % 3 == 0 && py == 0 ? 20 : 0;
            cr = (45 - depth * 5 + shimmer).clamp(5, 100);
            cg = (155 - depth * 12 + shimmer).clamp(35, 220);
            cb = (255 - depth * 8).clamp(160, 255);
            ca = 220 + depth * 3;
          case El.fire:
            final fireT = py / 7.0;
            if (fireT < 0.2) {
              cr = 255; cg = 250; cb = 220;
            } else if (fireT < 0.5) {
              cr = 255; cg = (200 - (fireT * 200).round()).clamp(100, 245); cb = 30;
            } else {
              cr = (255 - (fireT * 80).round()).clamp(180, 255);
              cg = (80 - (fireT * 60).round()).clamp(20, 80);
              cb = 5;
            }
            cr = (cr + variation ~/ 3).clamp(0, 255);
          case El.stone:
            final layer = _smoothHash(px, py + 50) % 16 - 8;
            cr = (128 + layer + variation ~/ 2).clamp(80, 165);
            cg = (126 + layer + variation ~/ 2).clamp(78, 163);
            cb = (138 + layer - variation ~/ 3).clamp(90, 178);
          case El.dirt:
            final moist = py > 5 ? 20 : 0;
            cr = (140 + variation ~/ 2 - moist).clamp(60, 165);
            cg = (95 + variation ~/ 3 - moist).clamp(30, 120);
            cb = (40 + variation ~/ 4 - moist ~/ 2).clamp(10, 55);
          case El.lava:
            final lavaPhase = py / 7.0;
            if (lavaPhase < 0.3) {
              cr = 255; cg = 225; cb = 110;
            } else if (lavaPhase < 0.6) {
              cr = 255; cg = (120 + variation).clamp(80, 180); cb = 10;
            } else {
              final isCrust = hash % 5 == 0;
              if (isCrust) {
                cr = 130; cg = 18; cb = 0;
              } else {
                cr = 230; cg = (50 + variation ~/ 2).clamp(20, 80); cb = 5;
              }
            }
          case El.wood:
            final grain = _smoothHash(px, py * 4 + 3) % 18 - 9;
            final isKnot = hash % 19 == 0;
            if (isKnot) {
              cr = 115; cg = 60; cb = 32;
            } else {
              cr = (160 + grain + variation ~/ 2).clamp(80, 190);
              cg = (85 + grain ~/ 2 + variation ~/ 3).clamp(40, 115);
              cb = (46 + grain ~/ 3).clamp(15, 70);
            }
          case El.metal:
            final sheen = (math.sin(px * 0.8 + py * 0.5) * 12).round();
            cr = (168 + sheen + variation ~/ 2).clamp(145, 200);
            cg = (168 + sheen + variation ~/ 2).clamp(145, 200);
            cb = (176 + sheen + variation ~/ 2).clamp(155, 210);
          case El.ice:
            final glint = hash % 20 == 0 ? 25 : 0;
            final facet = hash % 4;
            cr = (175 + facet * 8 + glint).clamp(160, 240);
            cg = (220 + facet * 5 + glint).clamp(210, 255);
            cb = 255;
          case El.oil:
            final iridPhase = (px * 37) % 120 / 120.0;
            final iridR = (math.sin(iridPhase * 6.28) * 12).round();
            if (py == 0) {
              cr = (60 + iridR).clamp(40, 80);
              cg = (50 + iridR ~/ 2).clamp(35, 65);
              cb = 40;
            } else {
              cr = (42 + variation ~/ 3).clamp(28, 58);
              cg = (32 + variation ~/ 4).clamp(18, 48);
              cb = (25 + variation ~/ 5).clamp(12, 40);
            }
          case El.acid:
            final pulse = (hash % 20) < 5 ? 15 : 0;
            cr = (20 + variation ~/ 3 + pulse ~/ 3).clamp(0, 60);
            cg = (240 + variation ~/ 4 + pulse).clamp(210, 255);
            cb = (20 + variation ~/ 5).clamp(0, 50);
          case El.glass:
            final sparkle = hash % 15 == 0 ? 30 : 0;
            cr = (210 + variation ~/ 2 + sparkle).clamp(180, 255);
            cg = (225 + variation ~/ 2 + sparkle).clamp(200, 255);
            cb = 255;
            ca = 180;
          case El.mud:
            final warmth = _smoothHash(px + 77, py + 33) % 12 - 6;
            cr = (115 + variation ~/ 2 + warmth).clamp(85, 145);
            cg = (75 + variation ~/ 3 + warmth ~/ 2).clamp(50, 105);
            cb = (32 + variation ~/ 4).clamp(15, 50);
          case El.snow:
            final glint = hash % 12 == 0 ? 10 : 0;
            cr = (238 + variation ~/ 4 + glint).clamp(228, 255);
            cg = (240 + variation ~/ 4 + glint).clamp(232, 255);
            cb = 255;
          case El.plant:
            final isLeafRow = py < 4;
            if (isLeafRow) {
              cr = (25 + variation ~/ 3).clamp(10, 50);
              cg = (160 + variation).clamp(130, 200);
              cb = (25 + variation ~/ 3).clamp(10, 50);
            } else {
              cr = (105 + variation ~/ 2).clamp(80, 130);
              cg = (65 + variation ~/ 3).clamp(40, 90);
              cb = 30;
            }
          case El.steam:
            final wisp = hash % 8 < 3 ? 10 : 0;
            cr = (225 + wisp).clamp(215, 245);
            cg = (225 + wisp).clamp(215, 245);
            cb = (235 + wisp).clamp(230, 255);
            ca = (140 + variation).clamp(100, 180);
          case El.smoke:
            final wispS = hash % 6 < 2 ? 8 : 0;
            cr = (140 + variation ~/ 2 + wispS).clamp(100, 170);
            cg = (135 + variation ~/ 2 + wispS ~/ 2).clamp(95, 165);
            cb = (140 + variation ~/ 2 + wispS ~/ 3).clamp(100, 170);
            ca = (140 + variation).clamp(80, 190);
          case El.bubble:
            final iridB = (math.sin(px * 1.0 + py * 0.5) * 20).round();
            cr = (190 + iridB).clamp(165, 240);
            cg = (215 + iridB ~/ 2).clamp(195, 250);
            cb = 245;
            ca = (120 + variation).clamp(90, 155);
          case El.ash:
            cr = (176 + variation ~/ 2).clamp(155, 200);
            cg = (176 + variation ~/ 2).clamp(155, 200);
            cb = (180 + variation ~/ 2).clamp(160, 205);
            ca = 210;
          case El.rainbow:
            final hue = ((px * 45 + py * 15) % 360).toDouble();
            final h6 = hue / 60.0;
            final hi = h6.floor() % 6;
            final f = h6 - h6.floor();
            switch (hi) {
              case 0: cr = 255; cg = (f * 204 + 51).round(); cb = 51;
              case 1: cr = (255 * (1 - 0.8 * f)).round(); cg = 255; cb = 51;
              case 2: cr = 51; cg = 255; cb = (f * 204 + 51).round();
              case 3: cr = 51; cg = (255 * (1 - 0.8 * f)).round(); cb = 255;
              case 4: cr = (f * 204 + 51).round(); cg = 51; cb = 255;
              default: cr = 255; cg = 51; cb = (255 * (1 - 0.8 * f)).round();
            }
          case El.tnt:
            if ((px + py) % 4 == 0) {
              cr = 68; cg = 0; cb = 0;
            } else {
              cr = (204 + variation ~/ 2).clamp(180, 230);
              cg = (34 + variation ~/ 3).clamp(10, 60);
              cb = (34 + variation ~/ 3).clamp(10, 60);
            }
          case El.lightning:
            final pulse = hash % 6 < 3;
            cr = 255; cg = 255; cb = pulse ? 180 : 255;
          case El.seed:
            cr = (139 + variation ~/ 2).clamp(110, 155);
            cg = (115 + variation ~/ 3).clamp(85, 135);
            cb = (85 + variation ~/ 4).clamp(55, 105);
          case El.ant:
            final segment = hash % 3 == 0;
            cr = segment ? 51 : 17;
            cg = segment ? 51 : 17;
            cb = segment ? 51 : 17;
          default:
            cr = (r + variation).clamp(0, 255);
            cg = (g + variation).clamp(0, 255);
            cb = (b + variation).clamp(0, 255);
        }

        paint.color = Color.fromARGB(ca.clamp(0, 255), cr.clamp(0, 255),
            cg.clamp(0, 255), cb.clamp(0, 255));
        canvas.drawRect(
          Rect.fromLTWH(px * cellSize, py * cellSize, cellSize + 0.5, cellSize + 0.5),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ElementPreviewPainter old) =>
      old.elId != elId;
}
