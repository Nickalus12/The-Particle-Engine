import '../element_registry.dart';
import '../simulation_engine.dart';

// ---------------------------------------------------------------------------
// ReactionRegistry -- Data-driven element-to-element interaction system
// ---------------------------------------------------------------------------

/// Describes a single element reaction rule.
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

  /// Stable reaction family key for observability and tuning.
  final String reactionFamily;

  /// Summary of expected field/environment preconditions.
  final String expectedPreconditions;

  /// Whether the rule is expected to approximately conserve material.
  final bool conservesMaterial;

  /// Reaction flash color (R, G, B) and particle count. 0 = no flash.
  final int flashR;
  final int flashG;
  final int flashB;
  final int flashCount;

  /// Temperature range constraints. Reaction only fires if source temp
  /// is within [requiresMinTemp, requiresMaxTemp]. 0 = no constraint.
  final int requiresMinTemp;
  final int requiresMaxTemp;

  const ReactionRule({
    required this.source,
    required this.target,
    this.sourceBecomesElement,
    this.targetBecomesElement,
    this.probability = 1.0,
    this.description = '',
    this.reactionFamily = 'pairwise_neighbor',
    this.expectedPreconditions = '',
    this.conservesMaterial = false,
    this.flashR = 0,
    this.flashG = 0,
    this.flashB = 0,
    this.flashCount = 0,
    this.requiresMinTemp = 0,
    this.requiresMaxTemp = 0,
  });
}

/// Central catalog of all element reactions with O(1) flat-array lookup.
class ReactionRegistry {
  static final List<ReactionRule> _rules = [];

  /// Flat 2D lookup: _reactionTable[source * maxElements + neighbor]
  /// gives a list of applicable rules for that pair. Null = no reactions.
  static final List<List<ReactionRule>?> _reactionTable =
      List<List<ReactionRule>?>.filled(maxElements * maxElements, null);

  /// Pre-built lookup: source element ID -> list of rules (for query API).
  static final Map<int, List<ReactionRule>> _rulesBySource = {};

  // RNG is sourced from SimulationEngine.rng for determinism.

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

  /// Rebuild both the flat lookup table and the source-indexed map.
  static void _rebuildIndex() {
    // Clear flat table
    for (int i = 0; i < maxElements * maxElements; i++) {
      _reactionTable[i] = null;
    }
    _rulesBySource.clear();

    for (final rule in _rules) {
      // Flat table
      final key = rule.source * maxElements + rule.target;
      (_reactionTable[key] ??= []).add(rule);
      // Source map
      (_rulesBySource[rule.source] ??= []).add(rule);
    }
  }

  /// All registered reaction rules.
  static List<ReactionRule> get rules => List.unmodifiable(_rules);

  static Map<String, int> familyCounts() {
    final counts = <String, int>{};
    for (final rule in _rules) {
      counts.update(
        rule.reactionFamily,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }
    return counts;
  }

  /// Find all reactions involving a given source element.
  static List<ReactionRule> reactionsFor(int sourceElement) =>
      _rulesBySource[sourceElement] ?? const [];

  /// Find all reactions between two specific elements.
  static List<ReactionRule> reactionsBetween(int a, int b) => _rules
      .where(
        (r) =>
            (r.source == a && r.target == b) ||
            (r.source == b && r.target == a),
      )
      .toList();

  /// O(1) lookup: get reaction rules for a specific (source, neighbor) pair.
  static List<ReactionRule>? rulesForPair(int source, int neighbor) =>
      _reactionTable[source * maxElements + neighbor];

  /// Generic reaction processor: scan 8 neighbors and apply matching rules.
  ///
  /// This is the unified entry point for data-driven reactions. It uses the
  /// flat 2D lookup table for O(1) pair matching. Returns true if any
  /// reaction fired.
  static bool processReactions(
    SimulationEngine sim,
    int x,
    int y,
    int idx,
    int el,
  ) {
    bool anyFired = false;
    final sourceBase = el * maxElements;

    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = sim.wrapX(x + dx);
        final ny = y + dy;
        if (!sim.inBoundsY(ny)) continue;
        final ni = ny * sim.gridW + nx;
        final neighborEl = sim.grid[ni];

        final rules = _reactionTable[sourceBase + neighborEl];
        if (rules == null) continue;

        for (final rule in rules) {
          final sourceTemp = sim.temperature[idx];
          if (rule.requiresMinTemp > 0 && sourceTemp < rule.requiresMinTemp) {
            continue;
          }
          if (rule.requiresMaxTemp > 0 && sourceTemp > rule.requiresMaxTemp) {
            continue;
          }
          if (rule.probability < 1.0 &&
              sim.rng.nextDouble() > rule.probability) {
            continue;
          }

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
          // Queue reaction flash if specified.
          if (rule.flashCount > 0) {
            sim.queueReactionFlash(
              nx,
              ny,
              rule.flashR,
              rule.flashG,
              rule.flashB,
              rule.flashCount,
            );
          }
          anyFired = true;
          break; // Only one reaction per neighbor per tick.
        }

        // If the source cell was transformed, stop scanning neighbors.
        if (sim.grid[idx] != el) return true;
      }
    }
    return anyFired;
  }

  /// Legacy compatibility: execute reactions for custom elements.
  static bool executeReactions(
    SimulationEngine sim,
    int el,
    int x,
    int y,
    int idx,
  ) {
    return processReactions(sim, x, y, idx, el);
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
    flashR: 255,
    flashG: 180,
    flashB: 50,
    flashCount: 3,
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
    flashR: 180,
    flashG: 220,
    flashB: 255,
    flashCount: 2,
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
    flashR: 200,
    flashG: 200,
    flashB: 240,
    flashCount: 3,
  ),
  ReactionRule(
    source: El.water,
    target: El.lava,
    sourceBecomesElement: El.steam,
    targetBecomesElement: El.stone,
    description: 'Water cools lava into stone, becoming steam',
  ),

  // Sand reactions
  ReactionRule(
    source: El.sand,
    target: El.lightning,
    sourceBecomesElement: El.glass,
    description: 'Lightning fuses sand into glass',
    flashR: 200,
    flashG: 230,
    flashB: 255,
    flashCount: 4,
  ),
  ReactionRule(
    source: El.sand,
    target: El.water,
    sourceBecomesElement: El.mud,
    description: 'Sand absorbs water to become mud',
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
    sourceBecomesElement: El.empty,
    probability: 0.08,
    description: 'Acid dissolves stone',
    flashR: 50,
    flashG: 255,
    flashB: 50,
    flashCount: 5,
  ),
  ReactionRule(
    source: El.acid,
    target: El.wood,
    targetBecomesElement: El.empty,
    sourceBecomesElement: El.empty,
    probability: 0.12,
    description: 'Acid dissolves wood',
    flashR: 60,
    flashG: 220,
    flashB: 40,
    flashCount: 4,
  ),
  ReactionRule(
    source: El.acid,
    target: El.metal,
    probability: 0.05,
    description: 'Acid corrodes metal (gradual damage via life)',
    flashR: 60,
    flashG: 230,
    flashB: 60,
    flashCount: 2,
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
    flashR: 80,
    flashG: 255,
    flashB: 120,
    flashCount: 3,
  ),
  ReactionRule(
    source: El.acid,
    target: El.glass,
    targetBecomesElement: El.empty,
    sourceBecomesElement: El.empty,
    probability: 0.1,
    description: 'Acid dissolves glass',
    flashR: 100,
    flashG: 255,
    flashB: 100,
    flashCount: 4,
  ),
  ReactionRule(
    source: El.acid,
    target: El.plant,
    targetBecomesElement: El.empty,
    probability: 0.33,
    description: 'Acid dissolves plants',
    flashR: 40,
    flashG: 200,
    flashB: 40,
    flashCount: 2,
  ),
  ReactionRule(
    source: El.acid,
    target: El.seed,
    targetBecomesElement: El.empty,
    probability: 0.33,
    description: 'Acid dissolves seeds',
    flashR: 40,
    flashG: 200,
    flashB: 40,
    flashCount: 2,
  ),
  ReactionRule(
    source: El.acid,
    target: El.ant,
    targetBecomesElement: El.empty,
    description: 'Acid kills ants',
  ),
  ReactionRule(
    source: El.acid,
    target: El.water,
    sourceBecomesElement: El.water,
    probability: 0.125,
    description: 'Acid dilutes in water',
  ),
  ReactionRule(
    source: El.acid,
    target: El.lava,
    sourceBecomesElement: El.smoke,
    targetBecomesElement: El.steam,
    probability: 0.2,
    description: 'Acid + lava = violent reaction',
    flashR: 200,
    flashG: 255,
    flashB: 100,
    flashCount: 6,
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
    flashR: 200,
    flashG: 230,
    flashB: 255,
    flashCount: 4,
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

  // Mud reactions
  ReactionRule(
    source: El.mud,
    target: El.fire,
    sourceBecomesElement: El.dirt,
    probability: 0.05,
    description: 'Mud dries near fire',
    flashR: 180,
    flashG: 180,
    flashB: 200,
    flashCount: 2,
  ),
  ReactionRule(
    source: El.mud,
    target: El.lava,
    sourceBecomesElement: El.dirt,
    probability: 0.05,
    description: 'Mud dries near lava',
    flashR: 180,
    flashG: 180,
    flashB: 200,
    flashCount: 2,
  ),

  // Lightning + Oil: arc ignition
  ReactionRule(
    source: El.lightning,
    target: El.oil,
    targetBecomesElement: El.fire,
    description: 'Lightning ignites oil',
    flashR: 255,
    flashG: 200,
    flashB: 50,
    flashCount: 5,
  ),

  // Acid + Snow: exothermic dissolution melts snow
  ReactionRule(
    source: El.acid,
    target: El.snow,
    targetBecomesElement: El.water,
    probability: 0.2,
    description: 'Acid melts snow into water',
    flashR: 80,
    flashG: 240,
    flashB: 100,
    flashCount: 3,
  ),

  // ==========================================================================
  // Periodic Table Reactions
  // ==========================================================================

  // -- Alkali metals + water (explosive, handled in behavior for main effect,
  //    but these provide extra spread) --
  ReactionRule(
    source: El.sodium,
    target: El.water,
    sourceBecomesElement: El.fire,
    targetBecomesElement: El.hydrogen,
    probability: 0.8,
    description: 'Sodium reacts violently with water',
    flashR: 255,
    flashG: 200,
    flashB: 50,
    flashCount: 6,
  ),
  ReactionRule(
    source: El.potassium,
    target: El.water,
    sourceBecomesElement: El.fire,
    targetBecomesElement: El.hydrogen,
    probability: 0.9,
    description: 'Potassium explodes in water',
    flashR: 255,
    flashG: 180,
    flashB: 220,
    flashCount: 8,
  ),
  ReactionRule(
    source: El.lithium,
    target: El.water,
    sourceBecomesElement: El.fire,
    targetBecomesElement: El.hydrogen,
    probability: 0.6,
    description: 'Lithium reacts with water',
    flashR: 255,
    flashG: 50,
    flashB: 50,
    flashCount: 4,
  ),
  ReactionRule(
    source: El.cesium,
    target: El.water,
    sourceBecomesElement: El.fire,
    targetBecomesElement: El.hydrogen,
    probability: 1.0,
    description: 'Cesium detonates in water',
    flashR: 255,
    flashG: 255,
    flashB: 100,
    flashCount: 10,
  ),

  // -- Halogen + metal → salt --
  ReactionRule(
    source: El.chlorine,
    target: El.sodium,
    sourceBecomesElement: El.empty,
    targetBecomesElement: El.salt,
    probability: 0.3,
    description: 'Chlorine + sodium = table salt (NaCl)',
    flashR: 255,
    flashG: 255,
    flashB: 200,
    flashCount: 3,
  ),
  ReactionRule(
    source: El.chlorine,
    target: El.metal,
    sourceBecomesElement: El.empty,
    targetBecomesElement: El.rust,
    probability: 0.1,
    description: 'Chlorine corrodes iron',
  ),
  ReactionRule(
    source: El.fluorine,
    target: El.glass,
    sourceBecomesElement: El.empty,
    targetBecomesElement: El.empty,
    probability: 0.15,
    description: 'Fluorine etches glass',
    flashR: 200,
    flashG: 255,
    flashB: 200,
    flashCount: 2,
  ),
  ReactionRule(
    source: El.fluorine,
    target: El.water,
    sourceBecomesElement: El.empty,
    targetBecomesElement: El.acid,
    probability: 0.2,
    description: 'Fluorine creates hydrofluoric acid',
  ),

  // -- Metal + acid → dissolution + hydrogen gas --
  ReactionRule(
    source: El.acid,
    target: El.aluminum,
    targetBecomesElement: El.empty,
    probability: 0.1,
    description: 'Acid dissolves aluminum',
    flashR: 100,
    flashG: 255,
    flashB: 100,
    flashCount: 2,
  ),
  ReactionRule(
    source: El.acid,
    target: El.zinc,
    targetBecomesElement: El.empty,
    probability: 0.08,
    description: 'Acid dissolves zinc, produces H₂',
    flashR: 100,
    flashG: 255,
    flashB: 100,
    flashCount: 2,
  ),
  ReactionRule(
    source: El.acid,
    target: El.tin,
    targetBecomesElement: El.empty,
    probability: 0.08,
    description: 'Acid dissolves tin',
  ),
  // Gold resists acid (no reaction = corrosionResistance: 255)

  // -- Silver tarnish --
  ReactionRule(
    source: El.silver,
    target: El.sulfur,
    probability: 0.05,
    description: 'Silver tarnishes with sulfur',
    // Visual: darken the silver (handled via life counter in renderer)
  ),

  // -- Zinc galvanization (protects iron from rust) --
  ReactionRule(
    source: El.zinc,
    target: El.rust,
    targetBecomesElement: El.metal,
    probability: 0.03,
    description: 'Zinc reduces rust back to iron',
    flashR: 180,
    flashG: 200,
    flashB: 220,
    flashCount: 2,
  ),

  // -- Mercury + gold/silver amalgamation --
  ReactionRule(
    source: El.mercury,
    target: El.gold,
    targetBecomesElement: El.mercury,
    probability: 0.02,
    description: 'Mercury amalgamates gold',
  ),
  ReactionRule(
    source: El.mercury,
    target: El.silver,
    targetBecomesElement: El.mercury,
    probability: 0.03,
    description: 'Mercury amalgamates silver',
  ),

  // -- Magnesium + fire = brilliant white flash --
  ReactionRule(
    source: El.magnesium,
    target: El.fire,
    sourceBecomesElement: El.ash,
    probability: 0.3,
    description: 'Magnesium burns with brilliant white light',
    flashR: 255,
    flashG: 255,
    flashB: 255,
    flashCount: 12,
  ),

  // -- Carbon (charcoal) + extreme pressure/heat → diamond --
  ReactionRule(
    source: El.charcoal,
    target: El.lava,
    sourceBecomesElement: El.carbon,
    probability: 0.005,
    description: 'Extreme heat+pressure: charcoal → diamond',
    flashR: 200,
    flashG: 230,
    flashB: 255,
    flashCount: 5,
    requiresMinTemp: 200,
  ),

  // -- Phosphorus auto-ignition with oxygen --
  ReactionRule(
    source: El.phosphorus,
    target: El.oxygen,
    sourceBecomesElement: El.fire,
    probability: 0.05,
    description: 'White phosphorus ignites in air',
    flashR: 255,
    flashG: 255,
    flashB: 200,
    flashCount: 4,
  ),

  // -- Bromine reactions --
  ReactionRule(
    source: El.bromine,
    target: El.aluminum,
    sourceBecomesElement: El.empty,
    targetBecomesElement: El.salt,
    probability: 0.1,
    description: 'Bromine reacts with aluminum',
    flashR: 200,
    flashG: 100,
    flashB: 50,
    flashCount: 3,
  ),

  // -- Tin + copper → bronze (simplified) --
  ReactionRule(
    source: El.tin,
    target: El.copper,
    probability: 0.01,
    description: 'Tin alloys with copper (bronze)',
    requiresMinTemp: 160,
  ),

  // -- Nuclear: uranium chain reaction effects --
  ReactionRule(
    source: El.plutonium,
    target: El.plutonium,
    probability: 0.02,
    description: 'Plutonium critical mass heating',
    flashR: 60,
    flashG: 255,
    flashB: 80,
    flashCount: 3,
  ),
  ReactionRule(
    source: El.thorium,
    target: El.thorium,
    probability: 0.01,
    description: 'Thorium sustained heat',
    flashR: 50,
    flashG: 200,
    flashB: 80,
    flashCount: 2,
  ),

  // -- Boron as neutron absorber (blocks uranium chain reactions) --
  ReactionRule(
    source: El.uranium,
    target: El.boron,
    probability: 0.05,
    description: 'Boron absorbs neutrons, slowing uranium',
    // No transformation — just presence slows chain reaction
  ),

  // -- Arsenic toxicity --
  ReactionRule(
    source: El.arsenic,
    target: El.water,
    probability: 0.02,
    description: 'Arsenic poisons water',
    flashR: 100,
    flashG: 80,
    flashB: 100,
    flashCount: 1,
  ),
];
