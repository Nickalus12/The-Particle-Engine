import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../game/particle_engine_game.dart';
import '../../simulation/element_registry.dart';
import '../../simulation/reactions/reaction_registry.dart';

/// A beautiful, animated periodic table overlay for selecting elements.
///
/// Shows all game elements organized in their periodic table positions with:
/// - Color-coded cells by element family
/// - Animated glow on hover/selection
/// - Tap to select element for placement
/// - Long-press for detailed element info card with reactions
class PeriodicTableOverlay extends StatefulWidget {
  const PeriodicTableOverlay({super.key, required this.game, this.onClose});

  final ParticleEngineGame game;
  final VoidCallback? onClose;

  @override
  State<PeriodicTableOverlay> createState() => _PeriodicTableOverlayState();
}

class _PeriodicTableOverlayState extends State<PeriodicTableOverlay>
    with TickerProviderStateMixin {
  int? _hoveredEl;
  int? _selectedEl;
  int? _detailEl; // Element showing detail card

  late final AnimationController _entranceController;
  late final Animation<double> _entranceFade;
  late final Animation<double> _entranceScale;

  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _entranceFade = CurvedAnimation(
      parent: _entranceController,
      curve: Curves.easeOut,
    );
    _entranceScale = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _entranceController, curve: Curves.easeOutCubic),
    );
    _entranceController.forward();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _entranceController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  void _selectElement(int elId) {
    setState(() => _selectedEl = elId);
    widget.game.sandboxWorld.sandboxComponent.selectedElement = elId;
  }

  void _showDetail(int elId) {
    setState(() => _detailEl = _detailEl == elId ? null : elId);
  }

  /// Family color for an element.
  static Color familyColor(int family) {
    switch (family) {
      case ElFamily.alkaliMetal: return const Color(0xFFE87070);
      case ElFamily.alkalineEarth: return const Color(0xFFE8A060);
      case ElFamily.transitionMetal: return const Color(0xFF70A0D0);
      case ElFamily.postTransition: return const Color(0xFF60B8A0);
      case ElFamily.metalloid: return const Color(0xFFA080C0);
      case ElFamily.nonmetal: return const Color(0xFF60C060);
      case ElFamily.halogen: return const Color(0xFFD0D050);
      case ElFamily.nobleGas: return const Color(0xFF80B0E0);
      case ElFamily.lanthanide: return const Color(0xFFD0A060);
      case ElFamily.actinide: return const Color(0xFF70C070);
      case ElFamily.superheavy: return const Color(0xFF808898);
      case ElFamily.compound: return const Color(0xFFA0A0B0);
      case ElFamily.organic: return const Color(0xFF80B870);
      default: return const Color(0xFF707080);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _entranceFade,
      child: ScaleTransition(
        scale: _entranceScale,
        child: Material(
          color: Colors.transparent,
          child: Stack(
            children: [
              // Backdrop
              GestureDetector(
                onTap: () {
                  if (_detailEl != null) {
                    setState(() => _detailEl = null);
                  } else {
                    widget.onClose?.call();
                  }
                },
                child: Container(color: Colors.black54),
              ),
              // Table content
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.95,
                    maxHeight: MediaQuery.of(context).size.height * 0.90,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildHeader(),
                      const SizedBox(height: 8),
                      Flexible(child: _buildTable()),
                      if (_detailEl != null) ...[
                        const SizedBox(height: 8),
                        _buildDetailCard(_detailEl!),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.science_rounded, color: Colors.white70, size: 20),
        const SizedBox(width: 8),
        const Text(
          'PERIODIC TABLE',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 2.0,
          ),
        ),
        const SizedBox(width: 8),
        const Icon(Icons.science_rounded, color: Colors.white70, size: 20),
      ],
    );
  }

  Widget _buildTable() {
    // Build a simplified periodic table layout
    // Each entry: (row, col, elementId) or null for gaps
    final cells = _buildPeriodicLayout();

    return LayoutBuilder(
      builder: (context, constraints) {
        // Calculate cell size to fit
        const cols = 18;
        const rows = 10; // 7 main + 2 lanthanide/actinide + 1 gap
        final cellW = (constraints.maxWidth / cols).clamp(20.0, 50.0);
        final cellH = (constraints.maxHeight / rows).clamp(20.0, 44.0);
        final cellSize = math.min(cellW, cellH);

        return SingleChildScrollView(
          child: SizedBox(
            width: cellSize * cols,
            height: cellSize * rows,
            child: Stack(
              children: [
                for (final cell in cells)
                  if (cell.$3 > 0 && elementNames[cell.$3].isNotEmpty)
                    Positioned(
                      left: cell.$2 * cellSize,
                      top: cell.$1 * cellSize,
                      width: cellSize - 1,
                      height: cellSize - 1,
                      child: _buildCell(cell.$3, cellSize),
                    ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCell(int elId, double size) {
    final family = elId < maxElements ? elementFamily[elId] : ElFamily.none;
    final color = familyColor(family);
    final symbol = elId < maxElements ? elementSymbol[elId] : '';
    final atomicNum = elId < maxElements ? elementAtomicNumber[elId] : 0;
    final isSelected = _selectedEl == elId;
    final isHovered = _hoveredEl == elId;
    final isDetail = _detailEl == elId;
    final name = elId < maxElements ? elementNames[elId] : '';

    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, _) {
        final pulseT = isSelected
            ? Curves.easeInOut.transform(_pulseController.value)
            : 0.0;
        final glowOpacity = isSelected ? 0.3 + pulseT * 0.3 : 0.0;

        return GestureDetector(
          onTap: () => _selectElement(elId),
          onLongPress: () => _showDetail(elId),
          child: MouseRegion(
            onEnter: (_) => setState(() => _hoveredEl = elId),
            onExit: (_) => setState(() => _hoveredEl = null),
            child: Container(
              decoration: BoxDecoration(
                color: color.withValues(alpha: isHovered || isDetail ? 0.9 : 0.65),
                borderRadius: BorderRadius.circular(3),
                border: isSelected
                    ? Border.all(color: Colors.white, width: 1.5)
                    : isDetail
                        ? Border.all(color: Colors.white70, width: 1)
                        : null,
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: color.withValues(alpha: glowOpacity),
                          blurRadius: 8,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
              ),
              padding: const EdgeInsets.all(1),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (size > 28 && atomicNum > 0)
                    Text(
                      '$atomicNum',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: (size * 0.18).clamp(6, 10),
                        height: 1.0,
                      ),
                    ),
                  Text(
                    symbol.isNotEmpty ? symbol : name.substring(0, math.min(2, name.length)),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: (size * 0.32).clamp(8, 16),
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                    ),
                  ),
                  if (size > 34)
                    Text(
                      name,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: (size * 0.15).clamp(5, 8),
                        height: 1.0,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetailCard(int elId) {
    final name = elementNames[elId];
    final symbol = elementSymbol[elId];
    final atomicNum = elementAtomicNumber[elId];
    final family = elementFamily[elId];
    final color = familyColor(family);
    final props = elementProperties[elId];

    // Get reactions involving this element
    ReactionRegistry.init();
    final reactions = ReactionRegistry.reactionsFor(elId);
    // Also find reactions where this element is the target
    final targetReactions = ReactionRegistry.rules
        .where((r) => r.target == elId)
        .toList();

    return Container(
      constraints: const BoxConstraints(maxWidth: 400),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  symbol.isNotEmpty ? symbol : '?',
                  style: TextStyle(
                    color: color,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        color: Colors.white, fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (atomicNum > 0)
                      Text(
                        'Atomic #$atomicNum  ·  ${_familyName(family)}',
                        style: TextStyle(color: color, fontSize: 11),
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18, color: Colors.white54),
                onPressed: () => setState(() => _detailEl = null),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Properties
          Wrap(
            spacing: 6, runSpacing: 4,
            children: [
              _propChip('Density', '${props.density}'),
              if (props.meltPoint > 0) _propChip('Melts', '${props.meltPoint}°'),
              if (props.boilPoint > 0) _propChip('Boils', '${props.boilPoint}°'),
              if (props.conductivity > 0) _propChip('Conducts', '${(props.conductivity * 100).round()}%'),
              if (props.reactivity > 0) _propChip('Reactivity', '${props.reactivity}'),
              if (props.hardness > 0) _propChip('Hardness', '${props.hardness}'),
              if (props.flammable) _propChip('Flammable', '🔥'),
              if (props.lightEmission > 0) _propChip('Glows', '${props.lightEmission}'),
              _propChip('State', props.state.name),
            ],
          ),
          // Reactions
          if (reactions.isNotEmpty || targetReactions.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              'REACTIONS',
              style: TextStyle(color: Colors.white54, fontSize: 10,
                  fontWeight: FontWeight.w600, letterSpacing: 1),
            ),
            const SizedBox(height: 4),
            ...reactions.take(4).map((r) => _reactionRow(r, isSource: true)),
            ...targetReactions.take(3).map((r) => _reactionRow(r, isSource: false)),
          ],
        ],
      ),
    );
  }

  Widget _propChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(color: Colors.white70, fontSize: 10),
      ),
    );
  }

  Widget _reactionRow(ReactionRule r, {required bool isSource}) {
    final sourceName = elementNames[r.source];
    final targetName = elementNames[r.target];
    final resultName = r.sourceBecomesElement != null
        ? elementNames[r.sourceBecomesElement!]
        : r.targetBecomesElement != null
            ? elementNames[r.targetBecomesElement!]
            : '?';
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        '$sourceName + $targetName → $resultName  (${(r.probability * 100).round()}%)',
        style: const TextStyle(color: Colors.white60, fontSize: 9),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  String _familyName(int family) {
    switch (family) {
      case ElFamily.alkaliMetal: return 'Alkali Metal';
      case ElFamily.alkalineEarth: return 'Alkaline Earth';
      case ElFamily.transitionMetal: return 'Transition Metal';
      case ElFamily.postTransition: return 'Post-Transition';
      case ElFamily.metalloid: return 'Metalloid';
      case ElFamily.nonmetal: return 'Nonmetal';
      case ElFamily.halogen: return 'Halogen';
      case ElFamily.nobleGas: return 'Noble Gas';
      case ElFamily.lanthanide: return 'Lanthanide';
      case ElFamily.actinide: return 'Actinide';
      case ElFamily.superheavy: return 'Superheavy';
      case ElFamily.compound: return 'Compound';
      case ElFamily.organic: return 'Organic';
      default: return 'Element';
    }
  }

  /// Build the periodic table layout as (row, col, elementId) triples.
  /// Standard periodic table positions.
  List<(int, int, int)> _buildPeriodicLayout() {
    return [
      // Row 0: H ... He
      (0, 0, El.hydrogen), (0, 17, El.helium),
      // Row 1: Li Be ... B C N O F Ne
      (1, 0, El.lithium), (1, 1, El.beryllium),
      (1, 12, El.boron), (1, 13, El.carbon), (1, 14, El.nitrogen),
      (1, 15, El.oxygen), (1, 16, El.fluorine), (1, 17, El.neon),
      // Row 2: Na Mg ... Al Si P S Cl Ar
      (2, 0, El.sodium), (2, 1, El.magnesium),
      (2, 12, El.aluminum), (2, 13, El.silicon), (2, 14, El.phosphorus),
      (2, 15, El.sulfur), (2, 16, El.chlorine), (2, 17, El.argon),
      // Row 3: K Ca Sc Ti V Cr Mn Fe Co Ni Cu Zn Ga Ge As Se Br Kr
      (3, 0, El.potassium), (3, 1, El.calcium),
      (3, 2, El.scandium), (3, 3, El.titanium), (3, 4, El.vanadium),
      (3, 5, El.chromium), (3, 6, El.manganese), (3, 7, El.metal), // Fe
      (3, 8, El.cobalt), (3, 9, El.nickel), (3, 10, El.copper),
      (3, 11, El.zinc), (3, 12, El.gallium), (3, 13, El.germanium),
      (3, 14, El.arsenic), (3, 15, El.selenium), (3, 16, El.bromine),
      (3, 17, El.krypton),
      // Row 4: Rb Sr Y Zr Nb Mo Tc Ru Rh Pd Ag Cd In Sn Sb Te I Xe
      (4, 0, El.rubidium), (4, 1, El.strontium),
      (4, 2, El.yttrium), (4, 3, El.zirconium), (4, 4, El.niobium),
      (4, 5, El.molybdenum), (4, 6, El.technetium), (4, 7, El.ruthenium),
      (4, 8, El.rhodium), (4, 9, El.palladium), (4, 10, El.silver),
      (4, 11, El.cadmium), (4, 12, El.indium), (4, 13, El.tin),
      (4, 14, El.antimony), (4, 15, El.tellurium), (4, 16, El.iodine),
      (4, 17, El.xenon),
      // Row 5: Cs Ba * Hf Ta W Re Os Ir Pt Au Hg Tl Pb Bi At Rn
      (5, 0, El.cesium), (5, 1, El.barium),
      (5, 3, El.hafnium), (5, 4, El.tantalum), (5, 5, El.tungsten),
      (5, 6, El.rhenium), (5, 7, El.osmium), (5, 8, El.iridium),
      (5, 9, El.platinum), (5, 10, El.gold), (5, 11, El.mercury),
      (5, 12, El.thallium), (5, 13, El.lead), (5, 14, El.bismuth),
      (5, 16, El.astatine), (5, 17, El.radon),
      // Row 6: Fr Ra * Rf Db Sg Bh ...
      (6, 0, El.francium), (6, 1, El.radium),
      (6, 3, El.rutherfordium), (6, 4, El.dubnium),
      (6, 5, El.seaborgium), (6, 6, El.bohrium),
      (6, 7, El.hassium), (6, 8, El.meitnerium),
      (6, 9, El.darmstadtium), (6, 10, El.roentgenium),
      (6, 11, El.copernicium), (6, 12, El.nihonium),
      (6, 13, El.flerovium), (6, 14, El.moscovium),
      (6, 15, El.livermorium), (6, 17, El.oganesson),
      // Row 8: Lanthanides (La-Lu)
      (8, 2, El.lanthanum), (8, 3, El.cerium), (8, 4, El.praseodymium),
      (8, 5, El.neodymium), (8, 6, El.promethium), (8, 7, El.samarium),
      (8, 8, El.europium), (8, 9, El.gadolinium), (8, 10, El.terbium),
      (8, 11, El.dysprosium), (8, 12, El.holmium), (8, 13, El.erbium),
      (8, 14, El.thulium), (8, 15, El.ytterbium), (8, 16, El.lutetium),
      // Row 9: Actinides (Ac-Lr)
      (9, 2, El.actinium), (9, 3, El.thorium), (9, 4, El.protactinium),
      (9, 5, El.uranium), (9, 6, El.neptunium), (9, 7, El.plutonium),
      (9, 8, El.americium), (9, 9, El.curium), (9, 10, El.berkelium),
      (9, 11, El.californium), (9, 12, El.einsteinium), (9, 13, El.fermium),
      (9, 14, El.mendelevium), (9, 15, El.nobelium), (9, 16, El.lawrencium),
    ];
  }
}
