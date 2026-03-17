import 'dart:math';

import '../element_registry.dart';
import '../simulation_engine.dart';

// ---------------------------------------------------------------------------
// ReactionRegistry -- Catalog of element-to-element interactions
// ---------------------------------------------------------------------------

/// Describes a single element reaction rule.
///
/// Reactions are executed inline within element behaviors for built-in
/// elements (see `element_behaviors.dart`). For custom elements, the registry
/// drives reactions automatically via [executeReactions].
class ReactionRule {
  /// The element that initiates the reaction.
  final int source;

  /// The neighbor element required to trigger the reaction.
  final int target;

  /// What the source cell becomes (null = unchanged).
  final int? sourceBecomesElement;

  /// What the target cell becomes (null = unchanged).
  final int? targetBecomesElement;

  /// Probability of the reaction occurring each tick (0.0 .. 1.0).
  final double probability;

  /// Human-readable description for tooling / UI.
  final String description;

  const ReactionRule({
    required this.source,
    required this.target,
    this.sourceBecomesElement,
    this.targetBecomesElement,
    this.probability = 1.0,
    this.description = '',
  });
}

/// Central catalog of all element reactions.
///
/// Built-in element reactions are hardcoded in `element_behaviors.dart` for
/// performance. This registry additionally provides:
/// - A data-driven catalog for inspection, serialization, and tooling.
/// - **Automatic reaction execution** for custom elements via [executeReactions].
///   Custom elements that register reactions get neighbor scanning and
///   transformation applied automatically without writing behavior code.
class ReactionRegistry {
  static final List<ReactionRule> _rules = [];

  /// Pre-built lookup: source element ID -> list of rules.
  /// Rebuilt when rules change. Avoids linear scan per tick.
  static final Map<int, List<ReactionRule>> _rulesBySource = {};

  /// Shared RNG for probability checks.
  static final Random _rng = Random();

  /// Initialize with all built-in reaction rules.
  static void init() {
    if (_rules.isNotEmpty) return;
    _rules.addAll(_builtInRules);
    _rebuildIndex();
  }

  /// Register a custom reaction rule at runtime.
  static void register(ReactionRule rule) {
    _rules.add(rule);
    _rebuildIndex();
  }

  /// Register multiple reaction rules at once.
  static void registerAll(List<ReactionRule> rules) {
    _rules.addAll(rules);
    _rebuildIndex();
  }

  /// Rebuild the source-indexed lookup table.
  static void _rebuildIndex() {
    _rulesBySource.clear();
    for (final rule in _rules) {
      (_rulesBySource[rule.source] ??= []).add(rule);
    }
  }

  /// All registered reaction rules.
  static List<ReactionRule> get rules => List.unmodifiable(_rules);

  /// Find all reactions involving a given source element.
  static List<ReactionRule> reactionsFor(int sourceElement) =>
      _rulesBySource[sourceElement] ?? const [];

  /// Find all reactions between two specific elements.
  static List<ReactionRule> reactionsBetween(int a, int b) => _rules
      .where((r) =>
          (r.source == a && r.target == b) ||
          (r.source == b && r.target == a))
      .toList();

  /// Execute data-driven reactions for a cell at (x, y).
  ///
  /// Scans 8 neighbors for matching reaction rules and applies
  /// transformations. Used by the default case in [simulateElement] for
  /// custom elements that don't have a dedicated behavior function.
  /// Returns true if any reaction fired.
  static bool executeReactions(SimulationEngine sim, int el, int x, int y, int idx) {
    final reactions = _rulesBySource[el];
    if (reactions == null || reactions.isEmpty) return false;

    bool anyFired = false;
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = sim.wrapX(x + dx);
        final ny = y + dy;
        if (!sim.inBoundsY(ny)) continue;
        final ni = ny * sim.gridW + nx;
        final neighborEl = sim.grid[ni];

        for (final rule in reactions) {
          if (rule.target != neighborEl) continue;
          if (rule.probability < 1.0 && _rng.nextDouble() > rule.probability) continue;

          // Apply source transformation.
          if (rule.sourceBecomesElement != null) {
            sim.grid[idx] = rule.sourceBecomesElement!;
            sim.life[idx] = 0;
            sim.markProcessed(idx);
          }
          // Apply target transformation.
          if (rule.targetBecomesElement != null) {
            sim.grid[ni] = rule.targetBecomesElement!;
            sim.life[ni] = 0;
            sim.markProcessed(ni);
          }
          anyFired = true;
          // Only one reaction per neighbor per tick.
          break;
        }

        // If the source cell was transformed, stop scanning neighbors.
        if (sim.grid[idx] != el) return true;
      }
    }
    return anyFired;
  }
}

// ---------------------------------------------------------------------------
// Built-in reaction rules (mirrors element_behaviors.dart logic)
// ---------------------------------------------------------------------------

const List<ReactionRule> _builtInRules = [
  // Fire reactions
  ReactionRule(
    source: El.fire,
    target: El.oil,
    targetBecomesElement: El.fire,
    probability: 0.5,
    description: 'Fire ignites adjacent oil (chain ignition)',
  ),
  ReactionRule(
    source: El.fire,
    target: El.wood,
    description: 'Fire chars wood (increases wood life counter)',
    probability: 0.15,
  ),
  ReactionRule(
    source: El.fire,
    target: El.plant,
    targetBecomesElement: El.fire,
    probability: 0.3,
    description: 'Fire spreads to plants',
  ),
  ReactionRule(
    source: El.fire,
    target: El.seed,
    targetBecomesElement: El.fire,
    probability: 0.3,
    description: 'Fire ignites seeds',
  ),
  ReactionRule(
    source: El.fire,
    target: El.ice,
    targetBecomesElement: El.water,
    probability: 0.1,
    description: 'Fire melts ice into water',
  ),
  ReactionRule(
    source: El.fire,
    target: El.snow,
    targetBecomesElement: El.water,
    probability: 0.15,
    description: 'Fire melts snow into water',
  ),
  ReactionRule(
    source: El.fire,
    target: El.tnt,
    description: 'Fire detonates TNT (explosion)',
    probability: 0.3,
  ),

  // Water reactions
  ReactionRule(
    source: El.water,
    target: El.fire,
    sourceBecomesElement: El.steam,
    targetBecomesElement: El.empty,
    description: 'Water extinguishes fire, becoming steam',
  ),
  ReactionRule(
    source: El.water,
    target: El.lava,
    sourceBecomesElement: El.steam,
    targetBecomesElement: El.stone,
    description: 'Water cools lava into stone, becoming steam',
  ),

  // Lava reactions
  ReactionRule(
    source: El.lava,
    target: El.water,
    sourceBecomesElement: El.stone,
    targetBecomesElement: El.steam,
    description: 'Lava + water = stone + steam',
  ),
  ReactionRule(
    source: El.lava,
    target: El.ice,
    targetBecomesElement: El.water,
    description: 'Lava melts ice',
  ),
  ReactionRule(
    source: El.lava,
    target: El.snow,
    targetBecomesElement: El.steam,
    description: 'Lava instantly vaporizes snow',
  ),
  ReactionRule(
    source: El.lava,
    target: El.wood,
    targetBecomesElement: El.fire,
    probability: 0.4,
    description: 'Lava ignites wood',
  ),
  ReactionRule(
    source: El.lava,
    target: El.stone,
    description: 'Lava heats adjacent stone (stored in velX)',
    probability: 0.08,
  ),

  // Acid reactions
  ReactionRule(
    source: El.acid,
    target: El.stone,
    targetBecomesElement: El.empty,
    probability: 0.08,
    description: 'Acid dissolves stone',
  ),
  ReactionRule(
    source: El.acid,
    target: El.wood,
    targetBecomesElement: El.empty,
    probability: 0.12,
    description: 'Acid dissolves wood',
  ),
  ReactionRule(
    source: El.acid,
    target: El.metal,
    targetBecomesElement: El.empty,
    probability: 0.05,
    description: 'Acid corrodes metal',
  ),
  ReactionRule(
    source: El.acid,
    target: El.dirt,
    targetBecomesElement: El.empty,
    probability: 0.15,
    description: 'Acid dissolves dirt',
  ),
  ReactionRule(
    source: El.acid,
    target: El.ice,
    targetBecomesElement: El.water,
    probability: 0.1,
    description: 'Acid melts ice',
  ),

  // Seed reactions
  ReactionRule(
    source: El.seed,
    target: El.water,
    description: 'Seed near water and dirt can sprout into plant',
    probability: 0.02,
  ),

  // Lightning reactions
  ReactionRule(
    source: El.lightning,
    target: El.water,
    description: 'Lightning electrifies connected water body',
  ),
  ReactionRule(
    source: El.lightning,
    target: El.metal,
    description: 'Lightning conducts through connected metal',
  ),
  ReactionRule(
    source: El.lightning,
    target: El.sand,
    targetBecomesElement: El.glass,
    description: 'Lightning fuses sand into glass',
  ),
  ReactionRule(
    source: El.lightning,
    target: El.tnt,
    description: 'Lightning detonates TNT',
  ),

  // Snow / Ice reactions
  ReactionRule(
    source: El.snow,
    target: El.fire,
    sourceBecomesElement: El.water,
    description: 'Snow melts near fire',
  ),
  ReactionRule(
    source: El.ice,
    target: El.fire,
    sourceBecomesElement: El.water,
    description: 'Ice melts near fire',
  ),
];
