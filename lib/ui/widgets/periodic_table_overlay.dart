import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../game/particle_engine_game.dart';
import '../../simulation/element_registry.dart';
import '../../simulation/reactions/reaction_registry.dart';
import '../theme/typography.dart';

typedef _ElementPlacement = ({int row, int col, int elId});

/// Periodic table explorer with a full inspector panel and sandbox demos.
///
/// Interaction model:
/// - Tap an element tile to inspect it.
/// - Use the inspector actions to equip the brush or stage a small live demo.
/// - Reaction cards can spawn quick interaction scenes in the sandbox.
class PeriodicTableOverlay extends StatefulWidget {
  const PeriodicTableOverlay({super.key, required this.game, this.onClose});

  final ParticleEngineGame game;
  final VoidCallback? onClose;

  @override
  State<PeriodicTableOverlay> createState() => _PeriodicTableOverlayState();
}

class _PeriodicTableOverlayState extends State<PeriodicTableOverlay>
    with TickerProviderStateMixin {
  static const List<_ElementPlacement> _layout = <_ElementPlacement>[
    (row: 0, col: 0, elId: El.hydrogen),
    (row: 0, col: 17, elId: El.helium),
    (row: 1, col: 0, elId: El.lithium),
    (row: 1, col: 1, elId: El.beryllium),
    (row: 1, col: 12, elId: El.boron),
    (row: 1, col: 13, elId: El.carbon),
    (row: 1, col: 14, elId: El.nitrogen),
    (row: 1, col: 15, elId: El.oxygen),
    (row: 1, col: 16, elId: El.fluorine),
    (row: 1, col: 17, elId: El.neon),
    (row: 2, col: 0, elId: El.sodium),
    (row: 2, col: 1, elId: El.magnesium),
    (row: 2, col: 12, elId: El.aluminum),
    (row: 2, col: 13, elId: El.silicon),
    (row: 2, col: 14, elId: El.phosphorus),
    (row: 2, col: 15, elId: El.sulfur),
    (row: 2, col: 16, elId: El.chlorine),
    (row: 2, col: 17, elId: El.argon),
    (row: 3, col: 0, elId: El.potassium),
    (row: 3, col: 1, elId: El.calcium),
    (row: 3, col: 2, elId: El.scandium),
    (row: 3, col: 3, elId: El.titanium),
    (row: 3, col: 4, elId: El.vanadium),
    (row: 3, col: 5, elId: El.chromium),
    (row: 3, col: 6, elId: El.manganese),
    (row: 3, col: 7, elId: El.metal),
    (row: 3, col: 8, elId: El.cobalt),
    (row: 3, col: 9, elId: El.nickel),
    (row: 3, col: 10, elId: El.copper),
    (row: 3, col: 11, elId: El.zinc),
    (row: 3, col: 12, elId: El.gallium),
    (row: 3, col: 13, elId: El.germanium),
    (row: 3, col: 14, elId: El.arsenic),
    (row: 3, col: 15, elId: El.selenium),
    (row: 3, col: 16, elId: El.bromine),
    (row: 3, col: 17, elId: El.krypton),
    (row: 4, col: 0, elId: El.rubidium),
    (row: 4, col: 1, elId: El.strontium),
    (row: 4, col: 2, elId: El.yttrium),
    (row: 4, col: 3, elId: El.zirconium),
    (row: 4, col: 4, elId: El.niobium),
    (row: 4, col: 5, elId: El.molybdenum),
    (row: 4, col: 6, elId: El.technetium),
    (row: 4, col: 7, elId: El.ruthenium),
    (row: 4, col: 8, elId: El.rhodium),
    (row: 4, col: 9, elId: El.palladium),
    (row: 4, col: 10, elId: El.silver),
    (row: 4, col: 11, elId: El.cadmium),
    (row: 4, col: 12, elId: El.indium),
    (row: 4, col: 13, elId: El.tin),
    (row: 4, col: 14, elId: El.antimony),
    (row: 4, col: 15, elId: El.tellurium),
    (row: 4, col: 16, elId: El.iodine),
    (row: 4, col: 17, elId: El.xenon),
    (row: 5, col: 0, elId: El.cesium),
    (row: 5, col: 1, elId: El.barium),
    (row: 5, col: 3, elId: El.hafnium),
    (row: 5, col: 4, elId: El.tantalum),
    (row: 5, col: 5, elId: El.tungsten),
    (row: 5, col: 6, elId: El.rhenium),
    (row: 5, col: 7, elId: El.osmium),
    (row: 5, col: 8, elId: El.iridium),
    (row: 5, col: 9, elId: El.platinum),
    (row: 5, col: 10, elId: El.gold),
    (row: 5, col: 11, elId: El.mercury),
    (row: 5, col: 12, elId: El.thallium),
    (row: 5, col: 13, elId: El.lead),
    (row: 5, col: 14, elId: El.bismuth),
    (row: 5, col: 16, elId: El.astatine),
    (row: 5, col: 17, elId: El.radon),
    (row: 6, col: 0, elId: El.francium),
    (row: 6, col: 1, elId: El.radium),
    (row: 6, col: 3, elId: El.rutherfordium),
    (row: 6, col: 4, elId: El.dubnium),
    (row: 6, col: 5, elId: El.seaborgium),
    (row: 6, col: 6, elId: El.bohrium),
    (row: 6, col: 7, elId: El.hassium),
    (row: 6, col: 8, elId: El.meitnerium),
    (row: 6, col: 9, elId: El.darmstadtium),
    (row: 6, col: 10, elId: El.roentgenium),
    (row: 6, col: 11, elId: El.copernicium),
    (row: 6, col: 12, elId: El.nihonium),
    (row: 6, col: 13, elId: El.flerovium),
    (row: 6, col: 14, elId: El.moscovium),
    (row: 6, col: 15, elId: El.livermorium),
    (row: 6, col: 17, elId: El.oganesson),
    (row: 8, col: 2, elId: El.lanthanum),
    (row: 8, col: 3, elId: El.cerium),
    (row: 8, col: 4, elId: El.praseodymium),
    (row: 8, col: 5, elId: El.neodymium),
    (row: 8, col: 6, elId: El.promethium),
    (row: 8, col: 7, elId: El.samarium),
    (row: 8, col: 8, elId: El.europium),
    (row: 8, col: 9, elId: El.gadolinium),
    (row: 8, col: 10, elId: El.terbium),
    (row: 8, col: 11, elId: El.dysprosium),
    (row: 8, col: 12, elId: El.holmium),
    (row: 8, col: 13, elId: El.erbium),
    (row: 8, col: 14, elId: El.thulium),
    (row: 8, col: 15, elId: El.ytterbium),
    (row: 8, col: 16, elId: El.lutetium),
    (row: 9, col: 2, elId: El.actinium),
    (row: 9, col: 3, elId: El.thorium),
    (row: 9, col: 4, elId: El.protactinium),
    (row: 9, col: 5, elId: El.uranium),
    (row: 9, col: 6, elId: El.neptunium),
    (row: 9, col: 7, elId: El.plutonium),
    (row: 9, col: 8, elId: El.americium),
    (row: 9, col: 9, elId: El.curium),
    (row: 9, col: 10, elId: El.berkelium),
    (row: 9, col: 11, elId: El.californium),
    (row: 9, col: 12, elId: El.einsteinium),
    (row: 9, col: 13, elId: El.fermium),
    (row: 9, col: 14, elId: El.mendelevium),
    (row: 9, col: 15, elId: El.nobelium),
    (row: 9, col: 16, elId: El.lawrencium),
  ];

  static const List<int> _mainPeriods = <int>[1, 2, 3, 4, 5, 6, 7];

  late final TextEditingController _searchController;
  late final AnimationController _entranceController;
  late final Animation<double> _entranceFade;
  late final Animation<double> _entranceScale;
  late final AnimationController _demoController;

  int? _hoveredElement;
  late int _activeElement;
  String _query = '';

  @override
  void initState() {
    super.initState();
    ReactionRegistry.init();
    _searchController = TextEditingController();
    final currentBrush =
        widget.game.sandboxWorld.sandboxComponent.selectedElement;
    _activeElement = currentBrush > 0 ? currentBrush : El.hydrogen;

    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _entranceFade = CurvedAnimation(
      parent: _entranceController,
      curve: Curves.easeOut,
    );
    _entranceScale = Tween<double>(begin: 0.94, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: Curves.easeOutCubic,
      ),
    );
    _entranceController.forward();

    _demoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    )..repeat();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _entranceController.dispose();
    _demoController.dispose();
    super.dispose();
  }

  bool _matchesQuery(int elId) {
    if (_query.trim().isEmpty) return true;
    final q = _query.trim().toLowerCase();
    final name = elementNames[elId].toLowerCase();
    final symbol = elementSymbol[elId].toLowerCase();
    final atomic = elementAtomicNumber[elId];
    return name.contains(q) ||
        symbol.contains(q) ||
        (atomic > 0 && '$atomic'.contains(q));
  }

  void _inspectElement(int elId) {
    setState(() => _activeElement = elId);
  }

  void _equipElement(int elId) {
    widget.game.sandboxWorld.sandboxComponent.selectedElement = elId;
    setState(() => _activeElement = elId);
  }

  List<ReactionRule> _reactionOptionsFor(int elId) {
    final related = <ReactionRule>[
      ...ReactionRegistry.reactionsFor(elId),
      ...ReactionRegistry.rules.where((rule) => rule.target == elId),
    ];

    final deduped = <String, ReactionRule>{};
    for (final rule in related) {
      final key = [
        rule.source,
        rule.target,
        rule.sourceBecomesElement ?? -1,
        rule.targetBecomesElement ?? -1,
      ].join(':');
      deduped.putIfAbsent(key, () => rule);
    }

    final result = deduped.values.toList()
      ..sort((a, b) => b.probability.compareTo(a.probability));
    return result;
  }

  void _placeElement(int x, int y, int elId, {int? temperatureOverride}) {
    final sim = widget.game.sandboxWorld.simulation;
    final wrappedX = sim.wrapX(x);
    if (!sim.inBoundsY(y)) return;
    final idx = y * sim.gridW + wrappedX;
    sim.clearCell(idx);
    sim.grid[idx] = elId;
    sim.mass[idx] = elementBaseMass[elId];
    sim.flags[idx] = sim.simClock ? 0x80 : 0;
    if (temperatureOverride != null) {
      sim.temperature[idx] = temperatureOverride.clamp(0, 255);
    } else {
      sim.temperature[idx] = elementProperties[elId].baseTemperature;
    }
    sim.markDirty(wrappedX, y);
    sim.unsettleNeighbors(wrappedX, y);
  }

  void _clearDemoArea(int centerX, int centerY) {
    final sim = widget.game.sandboxWorld.simulation;
    for (var dy = -11; dy <= 11; dy++) {
      final y = centerY + dy;
      if (!sim.inBoundsY(y)) continue;
      for (var dx = -20; dx <= 20; dx++) {
        final x = sim.wrapX(centerX + dx);
        final idx = y * sim.gridW + x;
        sim.clearCell(idx);
        sim.markDirty(x, y);
      }
    }
  }

  void _paintFloor(int centerX, int baselineY) {
    for (var dx = -18; dx <= 18; dx++) {
      _placeElement(centerX + dx, baselineY, El.stone);
      if (dx.abs() < 16) {
        _placeElement(centerX + dx, baselineY + 1, El.stone);
      }
    }
  }

  void _paintBlob(int centerX, int centerY, int elId, int radius) {
    final sim = widget.game.sandboxWorld.simulation;
    for (var dy = -radius; dy <= radius; dy++) {
      for (var dx = -radius; dx <= radius; dx++) {
        if (dx * dx + dy * dy > radius * radius) continue;
        final y = centerY + dy;
        if (!sim.inBoundsY(y)) continue;
        _placeElement(centerX + dx, y, elId);
      }
    }
  }

  void _paintPool(int centerX, int baselineY, int elId) {
    final sim = widget.game.sandboxWorld.simulation;
    for (var dx = -9; dx <= 9; dx++) {
      final widthFactor = 9 - dx.abs();
      final height = math.max(1, widthFactor ~/ 3);
      for (var h = 0; h < height; h++) {
        final y = baselineY - h;
        if (!sim.inBoundsY(y)) continue;
        _placeElement(centerX + dx, y, elId);
      }
    }
  }

  void _paintGasCloud(int centerX, int centerY, int elId) {
    for (var dy = -3; dy <= 3; dy++) {
      for (var dx = -10; dx <= 10; dx++) {
        final cloudMask = ((dx * dx) ~/ 3) + (dy * dy * 2);
        if (cloudMask > 20) continue;
        if ((dx + dy).isOdd) continue;
        _placeElement(centerX + dx, centerY + dy, elId);
      }
    }
  }

  void _paintColumn(int centerX, int baselineY, int elId) {
    for (var y = baselineY; y > baselineY - 8; y--) {
      _placeElement(centerX, y, elId);
      if ((baselineY - y).isEven) {
        _placeElement(centerX - 1, y, elId);
        _placeElement(centerX + 1, y, elId);
      }
    }
  }

  void _paintStateSample(
    int centerX,
    int baselineY,
    int elId,
    PhysicsState state,
  ) {
    switch (state) {
      case PhysicsState.gas:
        _paintGasCloud(centerX, baselineY - 6, elId);
        break;
      case PhysicsState.liquid:
        _paintPool(centerX, baselineY - 1, elId);
        break;
      case PhysicsState.granular:
      case PhysicsState.powder:
        _paintBlob(centerX, baselineY - 4, elId, 4);
        break;
      case PhysicsState.solid:
        _paintBlob(centerX, baselineY - 4, elId, 3);
        break;
      case PhysicsState.special:
        if (elId == El.fire || elId == El.lightning) {
          _paintColumn(centerX, baselineY - 1, elId);
        } else {
          _paintBlob(centerX, baselineY - 4, elId, 3);
        }
        break;
    }
  }

  void _stageDemo(int primaryEl, {ReactionRule? rule}) {
    final sim = widget.game.sandboxWorld.simulation;
    final centerX =
        (widget.game.camera.viewfinder.position.x / widget.game.cellSize).round();
    final centerY =
        (widget.game.camera.viewfinder.position.y / widget.game.cellSize).round();
    final baselineY = (centerY + 7).clamp(8, sim.gridH - 3);

    _clearDemoArea(centerX, baselineY);
    _paintFloor(centerX, baselineY);

    final primaryProps = elementProperties[primaryEl];
    _paintStateSample(centerX - 7, baselineY, primaryEl, primaryProps.state);

    if (rule != null) {
      final partnerEl = rule.source == primaryEl ? rule.target : rule.source;
      final partnerProps = elementProperties[partnerEl];
      _paintStateSample(centerX + 6, baselineY, partnerEl, partnerProps.state);
    }

    widget.game.sandboxWorld.simulation.markAllDirty();
  }

  String _familyName(int family) {
    switch (family) {
      case ElFamily.alkaliMetal:
        return 'Alkali Metal';
      case ElFamily.alkalineEarth:
        return 'Alkaline Earth Metal';
      case ElFamily.transitionMetal:
        return 'Transition Metal';
      case ElFamily.postTransition:
        return 'Post-Transition Metal';
      case ElFamily.metalloid:
        return 'Metalloid';
      case ElFamily.nonmetal:
        return 'Nonmetal';
      case ElFamily.halogen:
        return 'Halogen';
      case ElFamily.nobleGas:
        return 'Noble Gas';
      case ElFamily.lanthanide:
        return 'Lanthanide';
      case ElFamily.actinide:
        return 'Actinide';
      case ElFamily.superheavy:
        return 'Superheavy';
      case ElFamily.compound:
        return 'Compound';
      case ElFamily.organic:
        return 'Organic';
      default:
        return 'Sandbox Element';
    }
  }

  String _stateName(PhysicsState state) {
    switch (state) {
      case PhysicsState.gas:
        return 'Gas';
      case PhysicsState.liquid:
        return 'Liquid';
      case PhysicsState.granular:
        return 'Granular';
      case PhysicsState.powder:
        return 'Powder';
      case PhysicsState.solid:
        return 'Solid';
      case PhysicsState.special:
        return 'Special';
    }
  }

  Color _familyColor(int family) {
    switch (family) {
      case ElFamily.alkaliMetal:
        return const Color(0xFFE8665C);
      case ElFamily.alkalineEarth:
        return const Color(0xFFF3A550);
      case ElFamily.transitionMetal:
        return const Color(0xFF5CB4D8);
      case ElFamily.postTransition:
        return const Color(0xFF53B89A);
      case ElFamily.metalloid:
        return const Color(0xFF9E86D7);
      case ElFamily.nonmetal:
        return const Color(0xFF6FD06C);
      case ElFamily.halogen:
        return const Color(0xFFE4D45C);
      case ElFamily.nobleGas:
        return const Color(0xFF74A8F5);
      case ElFamily.lanthanide:
        return const Color(0xFFD98A4D);
      case ElFamily.actinide:
        return const Color(0xFF58C88E);
      case ElFamily.superheavy:
        return const Color(0xFF8D96B0);
      case ElFamily.compound:
        return const Color(0xFFA0A7C3);
      case ElFamily.organic:
        return const Color(0xFF7EB870);
      default:
        return const Color(0xFF707A92);
    }
  }

  String _headlineFor(int elId, ElementProperties props, int family) {
    final familyName = _familyName(family);
    final state = _stateName(props.state).toLowerCase();
    final parts = <String>[
      '$familyName sandboxed as a $state.',
    ];

    if (props.reactivity >= 180) {
      parts.add('Highly reactive and best demonstrated next to a partner.');
    } else if (props.conductivity >= 0.6) {
      parts.add('Strong electrical behavior makes it useful for conduction demos.');
    } else if (props.flammable) {
      parts.add('Carries stored chemical energy and can feed combustion.');
    } else if (props.lightEmission > 0) {
      parts.add('Emits visible light and reads clearly in the lighting stack.');
    } else if (props.state == PhysicsState.gas) {
      parts.add('Floats or settles depending on density and wind resistance.');
    } else if (props.state == PhysicsState.liquid) {
      parts.add('Forms pools, flows laterally, and exchanges heat fast.');
    } else if (props.state == PhysicsState.granular ||
        props.state == PhysicsState.powder) {
      parts.add('Falls, piles, and fractures into terrain-like motion.');
    } else {
      parts.add('Acts primarily as structure, mass, and thermal material.');
    }

    if (elId == El.silicon) {
      parts.add('In this sandbox it doubles as a logic-facing material.');
    }

    return parts.join(' ');
  }

  List<String> _behaviorBullets(int elId, ElementProperties props) {
    final bullets = <String>[
      'State: ${_stateName(props.state)} movement with density ${props.density} and gravity ${props.gravity}.',
    ];

    if (props.flammable || props.fuelValue > 0) {
      bullets.add(
        'Combustion: ignition ${props.ignitionTemp > 0 ? props.ignitionTemp : 'contextual'}, fuel value ${props.fuelValue}.',
      );
    }
    if (props.meltPoint > 0 || props.boilPoint > 0 || props.freezePoint > 0) {
      bullets.add(
        'Phase changes: melts ${props.meltPoint > 0 ? 'at ${props.meltPoint}' : 'never'}, boils ${props.boilPoint > 0 ? 'at ${props.boilPoint}' : 'never'}, freezes ${props.freezePoint > 0 ? 'at ${props.freezePoint}' : 'never'}.',
      );
    }
    if (props.conductivity > 0 || props.electronMobility > 0 || props.dielectric > 30) {
      bullets.add(
        'Electrical profile: conductivity ${(props.conductivity * 100).round()}%, mobility ${props.electronMobility}, dielectric ${props.dielectric}.',
      );
    }
    if (props.lightEmission > 0 || props.baseTemperature != 128) {
      bullets.add(
        'Energy profile: base temperature ${props.baseTemperature}, light emission ${props.lightEmission}.',
      );
    }
    if (props.hardness > 0 || props.baseMass > 0) {
      bullets.add(
        'Structure: hardness ${props.hardness}, mass ${props.baseMass}, wind resistance ${(props.windResistance * 100).round()}%.',
      );
    }
    if (elId == El.gold || elId == El.platinum || elId == El.lead) {
      bullets.add('Use this as a visual benchmark for dense, stable materials in the sandbox.');
    }

    return bullets.take(4).toList();
  }

  @override
  Widget build(BuildContext context) {
    final activeProps = elementProperties[_activeElement];
    final activeFamily = elementFamily[_activeElement];
    final reactions = _reactionOptionsFor(_activeElement);
    final size = MediaQuery.of(context).size;
    final activeColor = _familyColor(activeFamily);

    return FadeTransition(
      opacity: _entranceFade,
      child: ScaleTransition(
        scale: _entranceScale,
        child: Material(
          color: Colors.transparent,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: widget.onClose,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0.1, -0.2),
                        radius: 1.25,
                        colors: [
                          activeColor.withValues(alpha: 0.16),
                          Colors.black,
                        ],
                      ),
                    ),
                    child: Container(color: Colors.black.withValues(alpha: 0.70)),
                  ),
                ),
              ),
              Center(
                child: Container(
                  width: math.min(size.width * 0.96, 1380),
                  height: math.min(size.height * 0.94, 900),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: <Color>[
                        Color(0xFF101421),
                        Color(0xFF121A2D),
                        Color(0xFF0A0E17),
                      ],
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x80000000),
                        blurRadius: 48,
                        offset: Offset(0, 24),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: Stack(
                      children: [
                        Positioned(
                          top: -80,
                          right: -50,
                          child: _BackdropOrb(
                            size: 260,
                            color: activeColor.withValues(alpha: 0.18),
                          ),
                        ),
                        Positioned(
                          bottom: -120,
                          left: -70,
                          child: _BackdropOrb(
                            size: 320,
                            color: const Color(0xFF74A8F5).withValues(alpha: 0.12),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(22),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final horizontal = constraints.maxWidth >= 1120;
                              final table = _buildTablePane(
                                constraints,
                                horizontal,
                                activeColor,
                              );
                              final inspector = _buildInspectorPane(
                                _activeElement,
                                activeProps,
                                activeFamily,
                                reactions,
                              );

                              return Column(
                                children: [
                                  _buildHeader(activeColor),
                                  const SizedBox(height: 18),
                                  Expanded(
                                    child: horizontal
                                        ? Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              Expanded(flex: 7, child: table),
                                              const SizedBox(width: 18),
                                              Expanded(flex: 5, child: inspector),
                                            ],
                                          )
                                        : Column(
                                            children: [
                                              Expanded(flex: 6, child: table),
                                              const SizedBox(height: 16),
                                              Expanded(flex: 5, child: inspector),
                                            ],
                                          ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(Color accent) {
    final selectedChip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'SELECTED',
            style: AppTypography.caption.copyWith(
              color: Colors.white.withValues(alpha: 0.45),
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            elementNames[_activeElement],
            style: AppTypography.subheading.copyWith(color: Colors.white),
          ),
        ],
      ),
    );

    final search = SizedBox(
      width: 260,
      child: TextField(
        controller: _searchController,
        onChanged: (value) => setState(() => _query = value),
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: 'Search element, symbol, atomic #',
          hintStyle: TextStyle(
            color: Colors.white.withValues(alpha: 0.35),
            fontSize: 12,
          ),
          prefixIcon: const Icon(Icons.search_rounded, size: 18),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.06),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(
              color: Colors.white.withValues(alpha: 0.10),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: accent),
          ),
        ),
      ),
    );

    return Column(
      children: [
        Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: LinearGradient(
                  colors: <Color>[
                    accent.withValues(alpha: 0.92),
                    const Color(0xFF7EE3FF),
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.28),
                    blurRadius: 28,
                    spreadRadius: 1,
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.science_rounded, color: Colors.white),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'INTERACTIVE MATERIAL GALLERY',
                    style: AppTypography.caption.copyWith(
                      color: accent,
                      letterSpacing: 1.8,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Periodic Atlas',
                    style: AppTypography.heading.copyWith(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Tap a tile to inspect it, double-tap to equip it, or click a recipe to stage a live sandbox vignette.',
                    style: AppTypography.body.copyWith(
                      color: Colors.white.withValues(alpha: 0.66),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            IconButton(
              onPressed: widget.onClose,
              icon: const Icon(Icons.close_rounded),
              color: Colors.white70,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: [
            selectedChip,
            search,
          ],
        ),
      ],
    );
  }

  Widget _buildTablePane(
    BoxConstraints _constraints,
    bool horizontal,
    Color accent,
  ) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0x66202A3C),
            Color(0x33111824),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _PaneHeader(
              eyebrow: 'Material Grid',
              title: 'Element Families',
              subtitle:
                  'Color-grouped by family so the table reads fast before you drill into behavior.',
              accent: accent,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final family in <int>[
                  ElFamily.alkaliMetal,
                  ElFamily.transitionMetal,
                  ElFamily.nonmetal,
                  ElFamily.halogen,
                  ElFamily.nobleGas,
                  ElFamily.lanthanide,
                  ElFamily.actinide,
                ])
                  _LegendChip(
                    color: _familyColor(family),
                    label: _familyName(family),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: Colors.black.withValues(alpha: 0.12),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                ),
                child: LayoutBuilder(
                  builder: (context, paneConstraints) {
                    const cols = 18;
                    const rows = 10;
                    const labelBand = 22.0;
                    final usableWidth = paneConstraints.maxWidth - labelBand - 18;
                    final usableHeight = paneConstraints.maxHeight - labelBand - 18;
                    final cellSize = math.min(
                      usableWidth / cols,
                      usableHeight / rows,
                    ).clamp(horizontal ? 34.0 : 26.0, horizontal ? 54.0 : 42.0);
                    final tableWidth = labelBand + cols * cellSize;
                    final tableHeight = labelBand + rows * cellSize;

                    return Padding(
                      padding: const EdgeInsets.all(9),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SingleChildScrollView(
                            child: SizedBox(
                              width: tableWidth,
                              height: tableHeight,
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: CustomPaint(
                                        painter: _TableGridPainter(),
                                      ),
                                    ),
                                  ),
                                  for (var col = 0; col < cols; col++)
                                    Positioned(
                                      left: labelBand + col * cellSize,
                                      top: 0,
                                      width: cellSize,
                                      height: labelBand,
                                      child: Center(
                                        child: Text(
                                          '${col + 1}',
                                          style: AppTypography.caption.copyWith(
                                            color:
                                                Colors.white.withValues(alpha: 0.45),
                                          ),
                                        ),
                                      ),
                                    ),
                                  for (var row = 0; row < _mainPeriods.length; row++)
                                    Positioned(
                                      left: 0,
                                      top: labelBand + row * cellSize,
                                      width: labelBand,
                                      height: cellSize,
                                      child: Center(
                                        child: Text(
                                          '${_mainPeriods[row]}',
                                          style: AppTypography.caption.copyWith(
                                            color:
                                                Colors.white.withValues(alpha: 0.45),
                                          ),
                                        ),
                                      ),
                                    ),
                                  Positioned(
                                    left: 0,
                                    top: labelBand + 8 * cellSize,
                                    width: labelBand + 2 * cellSize,
                                    height: cellSize,
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        'La',
                                        style: AppTypography.caption.copyWith(
                                          color:
                                              Colors.white.withValues(alpha: 0.45),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    left: 0,
                                    top: labelBand + 9 * cellSize,
                                    width: labelBand + 2 * cellSize,
                                    height: cellSize,
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        'Ac',
                                        style: AppTypography.caption.copyWith(
                                          color:
                                              Colors.white.withValues(alpha: 0.45),
                                        ),
                                      ),
                                    ),
                                  ),
                                  for (final placement in _layout)
                                    Positioned(
                                      left: labelBand + placement.col * cellSize,
                                      top: labelBand + placement.row * cellSize,
                                      width: cellSize - 2,
                                      height: cellSize - 2,
                                      child: _buildElementCell(
                                        placement.elId,
                                        cellSize,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildElementCell(int elId, double cellSize) {
    final matched = _matchesQuery(elId);
    final selected = _activeElement == elId;
    final hovered = _hoveredElement == elId;
    final family = elementFamily[elId];
    final familyColor = _familyColor(family);
    final alpha = matched
        ? (selected ? 0.95 : hovered ? 0.84 : 0.70)
        : 0.04;

    return GestureDetector(
      onTap: () => _inspectElement(elId),
      onDoubleTap: () => _equipElement(elId),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hoveredElement = elId),
        onExit: (_) => setState(() => _hoveredElement = null),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            gradient: matched
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      familyColor.withValues(alpha: alpha),
                      familyColor.withValues(
                        alpha: (alpha - 0.26).clamp(0.10, 0.85),
                      ),
                    ],
                  )
                : null,
            color: matched ? null : Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? Colors.white
                  : matched
                      ? Colors.white.withValues(alpha: hovered ? 0.26 : 0.12)
                      : Colors.white.withValues(alpha: 0.04),
              width: selected ? 1.4 : 0.8,
            ),
            boxShadow: selected
                ? <BoxShadow>[
                    BoxShadow(
                      color: familyColor.withValues(alpha: 0.38),
                      blurRadius: 16,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: Opacity(
            opacity: matched ? 1.0 : 0.26,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (elementAtomicNumber[elId] > 0)
                  Text(
                    '${elementAtomicNumber[elId]}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.72),
                      fontSize: (cellSize * 0.16).clamp(7.0, 10.0),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                const Spacer(),
                Center(
                  child: Text(
                    elementSymbol[elId].isNotEmpty
                        ? elementSymbol[elId]
                        : elementNames[elId].substring(
                            0,
                            math.min(2, elementNames[elId].length),
                          ),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: (cellSize * 0.34).clamp(11.0, 19.0),
                      fontWeight: FontWeight.w800,
                      height: 1,
                    ),
                  ),
                ),
                const Spacer(),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        elementNames[elId],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.82),
                          fontSize: (cellSize * 0.14).clamp(6.0, 8.0),
                          fontWeight: FontWeight.w500,
                          height: 1,
                        ),
                      ),
                    ),
                    if (selected)
                      Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.only(left: 3),
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInspectorPane(
    int elId,
    ElementProperties props,
    int family,
    List<ReactionRule> reactions,
  ) {
    final familyColor = _familyColor(family);
    final symbol = elementSymbol[elId];
    final atomic = elementAtomicNumber[elId];
    final reactionPreview = reactions.isNotEmpty ? reactions.first : null;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0x66141D31),
            Color(0x33101520),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PaneHeader(
                eyebrow: 'Selected Element',
                title: elementNames[elId],
                subtitle: _headlineFor(elId, props, family),
                accent: familyColor,
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 104,
                    height: 104,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(26),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          familyColor.withValues(alpha: 0.92),
                          familyColor.withValues(alpha: 0.42),
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: familyColor.withValues(alpha: 0.30),
                          blurRadius: 20,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      symbol.isNotEmpty ? symbol : '?',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 38,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (atomic > 0)
                                _MetaChip(label: 'Atomic #', value: '$atomic'),
                              _MetaChip(
                                label: 'Family',
                                value: _familyName(family),
                              ),
                              _MetaChip(
                                label: 'State',
                                value: _stateName(props.state),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Click Behavior',
                            style: AppTypography.caption.copyWith(
                              color: familyColor,
                              letterSpacing: 1.4,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Inspect, equip, then stage a scene around the camera.',
                            style: AppTypography.body.copyWith(
                              color: Colors.white.withValues(alpha: 0.72),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _PrimaryActionButton(
                    label: 'Equip Brush',
                    icon: Icons.brush_rounded,
                    color: familyColor,
                    onTap: () => _equipElement(elId),
                  ),
                  _SecondaryActionButton(
                    label: 'Spawn Sample',
                    icon: Icons.auto_awesome_motion_rounded,
                    onTap: () => _stageDemo(elId),
                  ),
                  if (reactionPreview != null)
                    _SecondaryActionButton(
                      label: 'Run Best Reaction',
                      icon: Icons.bolt_rounded,
                      onTap: () => _stageDemo(elId, rule: reactionPreview),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              _SectionTitle(
                title: 'Demonstration',
                subtitle: 'A stylized preview plus one-click sandbox staging.',
              ),
              const SizedBox(height: 10),
              Container(
                height: 168,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      familyColor.withValues(alpha: 0.10),
                      const Color(0xFF111A2D),
                      const Color(0xFF090D15),
                    ],
                  ),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      top: 12,
                      left: 12,
                      child: _PreviewBadge(
                        label: _familyName(family),
                        color: familyColor.withValues(alpha: 0.86),
                      ),
                    ),
                    Positioned(
                      top: 12,
                      right: 12,
                      child: _PreviewBadge(
                        label: _stateName(props.state),
                        color: Colors.white.withValues(alpha: 0.14),
                      ),
                    ),
                    AnimatedBuilder(
                      animation: _demoController,
                      builder: (context, _) {
                        return CustomPaint(
                      painter: _ElementShowcasePainter(
                        family: family,
                        props: props,
                        color: familyColor,
                        progress: _demoController.value,
                          ),
                          child: Center(
                            child: Text(
                              'Previewing ${elementNames[elId]}',
                              style: AppTypography.body.copyWith(
                                color: Colors.white.withValues(alpha: 0.38),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    Positioned(
                      left: 14,
                      right: 14,
                      bottom: 12,
                      child: Text(
                        'Visual sketch only. Use the buttons above for the live sandbox version.',
                        textAlign: TextAlign.center,
                        style: AppTypography.caption.copyWith(
                          color: Colors.white.withValues(alpha: 0.50),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _SectionTitle(
                title: 'Property Signature',
                subtitle: 'Gameplay-weighted stats pulled from the simulation registry.',
              ),
              const SizedBox(height: 10),
              _MetricBar(
                label: 'Density',
                value: props.density / 255,
                accent: familyColor,
                trailing: '${props.density}',
              ),
              const SizedBox(height: 8),
              _MetricBar(
                label: 'Hardness',
                value: props.hardness / 255,
                accent: familyColor,
                trailing: '${props.hardness}',
              ),
              const SizedBox(height: 8),
              _MetricBar(
                label: 'Conductivity',
                value: props.conductivity.clamp(0.0, 1.0),
                accent: const Color(0xFF64D9FF),
                trailing: '${(props.conductivity * 100).round()}%',
              ),
              const SizedBox(height: 8),
              _MetricBar(
                label: 'Reactivity',
                value: props.reactivity / 255,
                accent: const Color(0xFFFFA35C),
                trailing: '${props.reactivity}',
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _FactChip(label: 'State', value: _stateName(props.state)),
                  if (props.flammable) const _FactChip(label: 'Combustion', value: 'Flammable'),
                  if (props.lightEmission > 0)
                    _FactChip(label: 'Light', value: '${props.lightEmission}'),
                  if (props.meltPoint > 0)
                    _FactChip(label: 'Melts', value: '${props.meltPoint}'),
                  if (props.boilPoint > 0)
                    _FactChip(label: 'Boils', value: '${props.boilPoint}'),
                  if (props.freezePoint > 0)
                    _FactChip(label: 'Freezes', value: '${props.freezePoint}'),
                  if (props.baseTemperature != 128)
                    _FactChip(label: 'Base Temp', value: '${props.baseTemperature}'),
                ],
              ),
              const SizedBox(height: 18),
              _SectionTitle(
                title: 'Sandbox Behavior',
                subtitle: 'What the player should expect once this element hits the world.',
              ),
              const SizedBox(height: 8),
              for (final bullet in _behaviorBullets(elId, props))
                Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: familyColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          bullet,
                          style: AppTypography.body.copyWith(
                            color: Colors.white.withValues(alpha: 0.72),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 18),
              _SectionTitle(
                title: 'Interaction Recipes',
                subtitle: 'Click one to stage a quick reaction vignette in the sandbox.',
              ),
              const SizedBox(height: 10),
              if (reactions.isEmpty)
                Text(
                  'No explicit data-driven reactions are registered for this element yet. Use Spawn Sample to inspect its motion, heat, and material response.',
                  style: AppTypography.body.copyWith(
                    color: Colors.white.withValues(alpha: 0.60),
                  ),
                )
              else
                Column(
                  children: [
                    for (final rule in reactions.take(5))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _ReactionCard(
                          rule: rule,
                          accent: familyColor,
                          onRun: () => _stageDemo(elId, rule: rule),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BackdropOrb extends StatelessWidget {
  const _BackdropOrb({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color,
              color.withValues(alpha: 0.0),
            ],
          ),
        ),
      ),
    );
  }
}

class _PaneHeader extends StatelessWidget {
  const _PaneHeader({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.accent,
  });

  final String eyebrow;
  final String title;
  final String subtitle;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: 0.15),
            Colors.white.withValues(alpha: 0.03),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            eyebrow.toUpperCase(),
            style: AppTypography.caption.copyWith(
              color: accent,
              letterSpacing: 1.6,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            title,
            style: AppTypography.heading.copyWith(
              fontSize: 24,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: AppTypography.body.copyWith(
              color: Colors.white.withValues(alpha: 0.68),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Text(
        '$label  $value',
        style: AppTypography.caption.copyWith(
          color: Colors.white.withValues(alpha: 0.78),
        ),
      ),
    );
  }
}

class _PreviewBadge extends StatelessWidget {
  const _PreviewBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Text(
        label,
        style: AppTypography.caption.copyWith(
          color: Colors.white,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

class _TableGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.025)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    const gap = 22.0;
    for (var x = gap; x < size.width; x += gap) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = gap; y < size.height; y += gap) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return false;
  }
}

class _LegendChip extends StatelessWidget {
  const _LegendChip({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.36)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: AppTypography.caption.copyWith(
              color: Colors.white.withValues(alpha: 0.72),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: AppTypography.caption.copyWith(
            color: Colors.white.withValues(alpha: 0.70),
            letterSpacing: 1.4,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          style: AppTypography.body.copyWith(
            color: Colors.white.withValues(alpha: 0.54),
          ),
        ),
      ],
    );
  }
}

class _MetricBar extends StatelessWidget {
  const _MetricBar({
    required this.label,
    required this.value,
    required this.accent,
    required this.trailing,
  });

  final String label;
  final double value;
  final Color accent;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: AppTypography.label.copyWith(color: Colors.white)),
            const Spacer(),
            Text(
              trailing,
              style: AppTypography.caption.copyWith(
                color: Colors.white.withValues(alpha: 0.64),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: clamped,
            minHeight: 9,
            backgroundColor: Colors.white.withValues(alpha: 0.08),
            valueColor: AlwaysStoppedAnimation<Color>(accent),
          ),
        ),
      ],
    );
  }
}

class _FactChip extends StatelessWidget {
  const _FactChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Text(
        '$label: $value',
        style: AppTypography.caption.copyWith(
          color: Colors.white.withValues(alpha: 0.78),
        ),
      ),
    );
  }
}

class _PrimaryActionButton extends StatelessWidget {
  const _PrimaryActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      icon: Icon(icon, size: 16),
      label: Text(label, style: AppTypography.button),
    );
  }
}

class _SecondaryActionButton extends StatelessWidget {
  const _SecondaryActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      icon: Icon(icon, size: 16),
      label: Text(label, style: AppTypography.button),
    );
  }
}

class _ReactionCard extends StatelessWidget {
  const _ReactionCard({
    required this.rule,
    required this.accent,
    required this.onRun,
  });

  final ReactionRule rule;
  final Color accent;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final sourceName = elementNames[rule.source];
    final targetName = elementNames[rule.target];
    final results = <String>[
      if (rule.sourceBecomesElement != null)
        elementNames[rule.sourceBecomesElement!],
      if (rule.targetBecomesElement != null)
        elementNames[rule.targetBecomesElement!],
    ];

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$sourceName + $targetName',
                  style: AppTypography.subheading,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${(rule.probability * 100).round()}%',
                  style: AppTypography.caption.copyWith(color: accent),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            rule.description.isNotEmpty
                ? rule.description
                : 'Transforms into ${results.isEmpty ? 'a new material state' : results.join(' + ')}.',
            style: AppTypography.body.copyWith(
              color: Colors.white.withValues(alpha: 0.68),
            ),
          ),
          if (results.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Outcome: ${results.join(' + ')}',
              style: AppTypography.caption.copyWith(
                color: Colors.white.withValues(alpha: 0.58),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: onRun,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(color: accent.withValues(alpha: 0.38)),
              ),
              icon: const Icon(Icons.play_circle_outline_rounded, size: 16),
              label: const Text('Stage Demo'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ElementShowcasePainter extends CustomPainter {
  _ElementShowcasePainter({
    required this.family,
    required this.props,
    required this.color,
    required this.progress,
  });

  final int family;
  final ElementProperties props;
  final Color color;
  final double progress;

  List<Color> _familyStageGradient() {
    switch (family) {
      case ElFamily.alkaliMetal:
      case ElFamily.alkalineEarth:
        return const [
          Color(0xFF22130F),
          Color(0xFF41211A),
          Color(0xFF0B0E15),
        ];
      case ElFamily.transitionMetal:
        return const [
          Color(0xFF101A25),
          Color(0xFF1D3242),
          Color(0xFF090D15),
        ];
      case ElFamily.postTransition:
      case ElFamily.metalloid:
        return const [
          Color(0xFF171522),
          Color(0xFF2A2441),
          Color(0xFF090D15),
        ];
      case ElFamily.nonmetal:
      case ElFamily.organic:
        return const [
          Color(0xFF101B14),
          Color(0xFF193226),
          Color(0xFF090D15),
        ];
      case ElFamily.halogen:
        return const [
          Color(0xFF1E1A0B),
          Color(0xFF403410),
          Color(0xFF090D15),
        ];
      case ElFamily.nobleGas:
        return const [
          Color(0xFF0F1730),
          Color(0xFF1A3260),
          Color(0xFF090D15),
        ];
      case ElFamily.lanthanide:
      case ElFamily.actinide:
      case ElFamily.superheavy:
        return const [
          Color(0xFF150F27),
          Color(0xFF2A1754),
          Color(0xFF090D15),
        ];
      case ElFamily.compound:
        return const [
          Color(0xFF12151D),
          Color(0xFF25303C),
          Color(0xFF090D15),
        ];
      default:
        return const [
          Color(0xFF1C2B46),
          Color(0xFF0A0E17),
        ];
    }
  }

  double _familyTempo() {
    switch (family) {
      case ElFamily.alkaliMetal:
      case ElFamily.alkalineEarth:
      case ElFamily.halogen:
        return 1.35;
      case ElFamily.nobleGas:
      case ElFamily.transitionMetal:
        return 0.82;
      case ElFamily.lanthanide:
      case ElFamily.actinide:
      case ElFamily.superheavy:
        return 0.95;
      default:
        return 1.0;
    }
  }

  double get _phase => progress * math.pi * 2 * _familyTempo();

  void _drawGlow(Canvas canvas, Offset center, double radius, double alpha) {
    final glowPaint = Paint()
      ..color = color.withValues(alpha: alpha)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.35);
    canvas.drawCircle(center, radius, glowPaint);
  }

  void _drawGasField(Canvas canvas, Size size, double groundY) {
    final particlePaint = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < 18; i++) {
      final t = ((progress * _familyTempo()) + i / 18) % 1.0;
      final x =
          size.width * (0.15 + (i % 6) * 0.13) + math.sin(t * math.pi * 2) * 8;
      final y = size.height * (0.18 + (i ~/ 6) * 0.18) - t * 14;
      canvas.drawCircle(
        Offset(x, y),
        8 + (i % 3) * 2,
        particlePaint..color = color.withValues(alpha: 0.18 + (i % 4) * 0.05),
      );
    }
  }

  void _drawLiquidField(Canvas canvas, Size size, double groundY, Paint paint) {
    final path = Path()..moveTo(0, groundY - 26);
    for (var x = 0.0; x <= size.width; x += 8) {
      final wave =
          math.sin((x / size.width) * math.pi * 3 + _phase) * 5;
      path.lineTo(x, groundY - 20 + wave);
    }
    path
      ..lineTo(size.width, groundY + 18)
      ..lineTo(0, groundY + 18)
      ..close();
    canvas.drawPath(path, paint);
  }

  void _drawGranularField(Canvas canvas, double groundY, Paint paint) {
    for (var i = 0; i < 40; i++) {
      final dx = (i % 10) * 14.0 + 40;
      final dy = groundY - (i ~/ 10) * 10 - (i % 2 == 0 ? 0 : 4);
      canvas.drawCircle(Offset(dx, dy), 4.2, paint);
    }
  }

  void _drawSolidBlock(Canvas canvas, Size size, double groundY, Paint paint) {
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(size.width * 0.50, groundY - 28),
        width: size.width * 0.44,
        height: 54,
      ),
      const Radius.circular(14),
    );
    canvas.drawRRect(rect, paint);
  }

  void _drawStateFallback(Canvas canvas, Size size, double groundY, Paint paint) {
    switch (props.state) {
      case PhysicsState.gas:
        _drawGasField(canvas, size, groundY);
        break;
      case PhysicsState.liquid:
        _drawLiquidField(canvas, size, groundY, paint);
        break;
      case PhysicsState.granular:
      case PhysicsState.powder:
        _drawGranularField(canvas, groundY, paint);
        break;
      case PhysicsState.solid:
        _drawSolidBlock(canvas, size, groundY, paint);
        break;
      case PhysicsState.special:
        if (props.lightEmission > 0 || props.baseTemperature > 180) {
          _drawGlow(canvas, Offset(size.width * 0.50, groundY - 36), 34, 0.20);
        }
        for (var i = 0; i < 6; i++) {
          final x = size.width * 0.24 + i * 24;
          final y = groundY - 20 - math.sin(_phase + i) * 14;
          canvas.drawCircle(Offset(x, y), 5 + (i.isEven ? 2 : 0), paint);
        }
        break;
    }
  }

  void _drawAtmosphere(Canvas canvas, Size size, double groundY) {
    final topGlow = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: 0.18),
          Colors.transparent,
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height * 0.62));
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height * 0.62),
      topGlow,
    );

    final horizon = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0, 0.25),
        radius: 0.8,
        colors: [
          color.withValues(alpha: 0.12),
          Colors.transparent,
        ],
      ).createShader(Rect.fromLTWH(0, groundY - 70, size.width, 120));
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * 0.5, groundY - 10),
        width: size.width * 0.86,
        height: 110,
      ),
      horizon,
    );

    final vignette = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0, -0.1),
        radius: 1.15,
        colors: [
          Colors.transparent,
          Colors.black.withValues(alpha: 0.34),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, vignette);
  }

  void _drawGroundReflection(Canvas canvas, Size size, double groundY) {
    final reflection = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: 0.10),
          Colors.transparent,
        ],
      ).createShader(Rect.fromLTWH(0, groundY - 4, size.width, 28));
    canvas.drawRect(
      Rect.fromLTWH(0, groundY - 4, size.width, 28),
      reflection,
    );
  }

  void _drawSparkleField(Canvas canvas, Size size, {int count = 12}) {
    final sparklePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = Colors.white.withValues(alpha: 0.18);
    for (var i = 0; i < count; i++) {
      final x = size.width * (0.10 + (i % 6) * 0.16);
      final y = size.height * (0.16 + (i ~/ 6) * 0.14) +
          math.sin(_phase + i * 0.8) * 7;
      canvas.drawLine(Offset(x - 4, y), Offset(x + 4, y), sparklePaint);
      canvas.drawLine(Offset(x, y - 4), Offset(x, y + 4), sparklePaint);
    }
  }

  void _drawFamilyScene(Canvas canvas, Size size, double groundY, Paint paint) {
    switch (family) {
      case ElFamily.alkaliMetal:
      case ElFamily.alkalineEarth:
        _drawLiquidField(canvas, size, groundY, paint);
        for (var i = 0; i < 9; i++) {
          final t = ((progress * _familyTempo()) + i / 9) % 1.0;
          final cx = size.width * (0.22 + i * 0.07);
          final cy = groundY - 18 - math.sin(t * math.pi * 2) * 12;
          _drawGlow(canvas, Offset(cx, cy), 10, 0.12);
          canvas.drawCircle(
            Offset(cx, cy),
            2.4 + (i.isEven ? 1.2 : 0),
            paint..color = color.withValues(alpha: 0.85),
          );
        }
        break;
      case ElFamily.transitionMetal:
        _drawSolidBlock(canvas, size, groundY, paint);
        final stroke = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white.withValues(alpha: 0.30);
        for (var i = 0; i < 3; i++) {
          final inset = 18.0 + i * 14;
          final wobble = math.sin(_phase + i) * 3;
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(
                inset + wobble,
                groundY - 74 + i * 4,
                size.width - inset * 2,
                18,
              ),
              const Radius.circular(9),
            ),
            stroke,
          );
        }
        _drawSparkleField(canvas, size, count: 6);
        break;
      case ElFamily.postTransition:
      case ElFamily.metalloid:
        final path = Path()
          ..moveTo(size.width * 0.24, groundY)
          ..lineTo(size.width * 0.37, groundY - 54)
          ..lineTo(size.width * 0.50, groundY - 26)
          ..lineTo(size.width * 0.63, groundY - 62)
          ..lineTo(size.width * 0.77, groundY)
          ..close();
        canvas.drawPath(path, paint);
        final facetPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = Colors.white.withValues(alpha: 0.22);
        canvas.drawLine(
          Offset(size.width * 0.37, groundY - 54),
          Offset(size.width * 0.63, groundY - 62),
          facetPaint,
        );
        canvas.drawLine(
          Offset(size.width * 0.50, groundY - 26),
          Offset(size.width * 0.37, groundY - 54),
          facetPaint,
        );
        canvas.drawLine(
          Offset(size.width * 0.50, groundY - 26),
          Offset(size.width * 0.63, groundY - 62),
          facetPaint,
        );
        _drawSparkleField(canvas, size, count: 8);
        break;
      case ElFamily.nonmetal:
      case ElFamily.organic:
        _drawGasField(canvas, size, groundY);
        for (var i = 0; i < 5; i++) {
          final orbit = _phase + i * 0.8;
          final center = Offset(size.width * 0.50, groundY - 44);
          final dot = center + Offset(math.cos(orbit) * 34, math.sin(orbit) * 18);
          canvas.drawCircle(dot, 4.5, paint..color = color.withValues(alpha: 0.86));
        }
        break;
      case ElFamily.halogen:
        for (var i = 0; i < 7; i++) {
          final shift = (((progress * _familyTempo()) + i / 7) % 1.0) * size.width;
          final slash = Path()
            ..moveTo(shift - 16, groundY - 64)
            ..lineTo(shift + 4, groundY - 12)
            ..lineTo(shift - 6, groundY - 12)
            ..lineTo(shift - 26, groundY - 64)
            ..close();
          canvas.drawPath(slash, paint..color = color.withValues(alpha: 0.40));
        }
        _drawGasField(canvas, size, groundY);
        break;
      case ElFamily.nobleGas:
        for (var i = 0; i < 4; i++) {
          final orbitRadius = 22.0 + i * 12;
          final center = Offset(size.width * 0.50, groundY - 40);
          final orbitPaint = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = Colors.white.withValues(alpha: 0.12);
          canvas.drawOval(
            Rect.fromCenter(
              center: center,
              width: orbitRadius * 2.6,
              height: orbitRadius * 1.2,
            ),
            orbitPaint,
          );
          final angle = _phase + i * 0.9;
          final point = center +
              Offset(math.cos(angle) * orbitRadius * 1.3, math.sin(angle) * orbitRadius * 0.6);
          _drawGlow(canvas, point, 10, 0.12);
          canvas.drawCircle(point, 5.5 - i * 0.5, paint);
        }
        break;
      case ElFamily.lanthanide:
      case ElFamily.actinide:
      case ElFamily.superheavy:
        _drawGlow(canvas, Offset(size.width * 0.50, groundY - 44), 58, 0.18);
        for (var i = 0; i < 6; i++) {
          final path = Path()..moveTo(0, groundY - 70 + i * 8);
          for (var x = 0.0; x <= size.width; x += 10) {
            final wave = math.sin(_phase + i * 0.5 + x * 0.03) * 7;
            path.lineTo(x, groundY - 70 + i * 8 + wave);
          }
          final ribbon = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..color = color.withValues(alpha: 0.18 + i * 0.05);
          canvas.drawPath(path, ribbon);
        }
        final corePaint = Paint()..color = color.withValues(alpha: 0.90);
        canvas.drawCircle(Offset(size.width * 0.50, groundY - 38), 18, corePaint);
        break;
      case ElFamily.compound:
        if (props.state == PhysicsState.liquid) {
          _drawLiquidField(canvas, size, groundY, paint);
        } else {
          _drawGranularField(canvas, groundY, paint);
        }
        final nodePaint = Paint()..color = Colors.white.withValues(alpha: 0.22);
        for (var i = 0; i < 5; i++) {
          final x = size.width * (0.24 + i * 0.14);
          final y = groundY - 34 - (i.isEven ? 10 : 0);
          canvas.drawCircle(Offset(x, y), 3, nodePaint);
          if (i < 4) {
            canvas.drawLine(
              Offset(x, y),
              Offset(size.width * (0.24 + (i + 1) * 0.14), groundY - 34 - ((i + 1).isEven ? 10 : 0)),
              nodePaint..strokeWidth = 1.2,
            );
          }
        }
        break;
      default:
        _drawStateFallback(canvas, size, groundY, paint);
        break;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: _familyStageGradient(),
      ).createShader(Offset.zero & size);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(20)),
      bgPaint,
    );

    final groundY = size.height * 0.78;
    _drawAtmosphere(canvas, size, groundY);
    final groundPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08);
    canvas.drawRect(
      Rect.fromLTWH(0, groundY, size.width, size.height - groundY),
      groundPaint,
    );
    _drawGroundReflection(canvas, size, groundY);

    final elementPaint = Paint()
      ..color = color.withValues(alpha: 0.92)
      ..style = PaintingStyle.fill;
    _drawFamilyScene(canvas, size, groundY, elementPaint);

    final stroke = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..style = PaintingStyle.stroke;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Offset.zero & size,
        const Radius.circular(20),
      ),
      stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _ElementShowcasePainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.color != color ||
        oldDelegate.props != props ||
        oldDelegate.family != family;
  }
}
