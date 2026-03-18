import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Element Registry -- Element type constants, colors, names, categories
// ---------------------------------------------------------------------------

/// Maximum number of element types the engine supports (byte range).
/// IDs 0..maxElements-1 are valid. The grid uses Uint8List so the hard
/// ceiling is 256, but we cap at 64 to keep lookup tables small.
const int maxElements = 64;

/// Element types stored in the grid as byte values.
///
/// Each constant maps to a unique byte used in the [SimulationEngine.grid]
/// array.  The first 25 (0..24) are built-in; higher IDs are available for
/// runtime-registered custom elements.
class El {
  static const int empty = 0;
  static const int sand = 1;
  static const int water = 2;
  static const int fire = 3;
  static const int ice = 4;
  static const int lightning = 5;
  static const int seed = 6;
  static const int stone = 7;
  static const int tnt = 8;
  static const int rainbow = 9;
  static const int mud = 10;
  static const int steam = 11;
  static const int ant = 12;
  static const int oil = 13;
  static const int acid = 14;
  static const int glass = 15;
  static const int dirt = 16;
  static const int plant = 17;
  static const int lava = 18;
  static const int snow = 19;
  static const int wood = 20;
  static const int metal = 21;
  static const int smoke = 22;
  static const int bubble = 23;
  static const int ash = 24;

  /// Sentinel used only in the UI to represent the eraser tool.
  static const int eraser = 99;

  /// Total number of built-in element types (0..24 inclusive).
  static const int count = 25;
}

/// Per-element base colors as packed 0xAARRGGBB integers.
///
/// Mutable list sized to [maxElements]. The renderer overrides these for
/// animated elements (fire, lava, rainbow, etc.) but falls back to these
/// values for everything else. Custom elements get their color set via
/// [ElementRegistry.register].
final List<int> baseColors = List<int>.filled(maxElements, 0x00000000)
  ..[El.empty] = 0x00000000
  ..[El.sand] = 0xFFD9C390     // Warm golden-tan
  ..[El.water] = 0xFF2E9AFF     // Deep clear blue
  ..[El.fire] = 0xFFFF8820      // Bright orange flame
  ..[El.ice] = 0xFFBDE5FF       // Light crystalline blue-white
  ..[El.lightning] = 0xFFFFFFA0  // Electric yellow-white
  ..[El.seed] = 0xFF8B7355      // Rich brown seed
  ..[El.stone] = 0xFF808090     // Cool blue-gray
  ..[El.tnt] = 0xFFCC2222       // Danger red
  ..[El.rainbow] = 0xFFFF00FF   // Magenta (cycles in renderer)
  ..[El.mud] = 0xFF7A5030       // Rich earthy brown
  ..[El.steam] = 0xFFE0E0F0     // Wispy blue-white
  ..[El.ant] = 0xFF222222       // Dark body
  ..[El.oil] = 0xFF3A2820       // Dark with warm undertone
  ..[El.acid] = 0xFF30F030      // Toxic bright green
  ..[El.glass] = 0xCCDDE8FF     // Semi-transparent blue-white
  ..[El.dirt] = 0xFF8C6830      // Rich brown earth
  ..[El.plant] = 0xFF28B040     // Vibrant green
  ..[El.lava] = 0xFFFF5010      // Molten orange-red
  ..[El.snow] = 0xFFF0F4FF      // Cold sparkle white
  ..[El.wood] = 0xFFA05530      // Warm brown with grain tone
  ..[El.metal] = 0xFFA8A8B8     // Metallic blue-gray sheen
  ..[El.smoke] = 0xB09A9AA0     // Semi-transparent gray
  ..[El.bubble] = 0xA0C8E8FF    // Translucent cyan-white
  ..[El.ash] = 0xDDB0B0B8;      // Light gray with transparency

/// Human-readable element names (index = element type).
/// Mutable list sized to [maxElements].
final List<String> elementNames = List<String>.filled(maxElements, '')
  ..[El.sand] = 'Sand'
  ..[El.water] = 'Water'
  ..[El.fire] = 'Fire'
  ..[El.ice] = 'Ice'
  ..[El.lightning] = 'Zap'
  ..[El.seed] = 'Seed'
  ..[El.stone] = 'Stone'
  ..[El.tnt] = 'TNT'
  ..[El.rainbow] = 'Rainbow'
  ..[El.mud] = 'Mud'
  ..[El.steam] = 'Steam'
  ..[El.ant] = 'Ant'
  ..[El.oil] = 'Oil'
  ..[El.acid] = 'Acid'
  ..[El.glass] = 'Glass'
  ..[El.dirt] = 'Dirt'
  ..[El.plant] = 'Plant'
  ..[El.lava] = 'Lava'
  ..[El.snow] = 'Snow'
  ..[El.wood] = 'Wood'
  ..[El.metal] = 'Metal'
  ..[El.smoke] = 'Smoke'
  ..[El.bubble] = 'Bubble'
  ..[El.ash] = 'Ash';

/// Static elements unaffected by wind or shake.
final Set<int> staticElements = {
  El.stone, El.metal, El.wood, El.glass, El.ice,
};

/// Pre-computed wind sensitivity per element type.
///   0 = unaffected, 1 = heavy liquid, 2 = light, 3 = ultra-light (ash).
final Uint8List windSensitivity = () {
  final t = Uint8List(maxElements);
  for (final el in [
    El.sand, El.snow, El.smoke, El.fire, El.steam, El.bubble, El.seed,
  ]) {
    t[el] = 2;
  }
  for (final el in [El.water, El.oil, El.acid]) {
    t[el] = 1;
  }
  t[El.ash] = 3;
  return t;
}();

// ---------------------------------------------------------------------------
// Element category bitmasks (for AI sensing API)
// ---------------------------------------------------------------------------

/// Category flags for O(1) element classification.
class ElCat {
  static const int solid = 0x01;
  static const int liquid = 0x02;
  static const int gas = 0x04;
  static const int organic = 0x08;
  static const int danger = 0x10;
  static const int flammable = 0x20;
  static const int conductive = 0x40;
}

/// Pre-computed category bitmask per element type.
/// Sized to [maxElements] so custom elements can be registered.
final Uint8List elCategory = () {
  final t = Uint8List(maxElements);
  t[El.sand] = ElCat.organic;
  t[El.water] = ElCat.liquid | ElCat.conductive;
  t[El.fire] = ElCat.gas | ElCat.danger;
  t[El.ice] = ElCat.solid;
  t[El.lightning] = ElCat.danger;
  t[El.seed] = ElCat.organic | ElCat.flammable;
  t[El.stone] = ElCat.solid;
  t[El.tnt] = ElCat.danger;
  t[El.mud] = ElCat.liquid | ElCat.organic;
  t[El.steam] = ElCat.gas;
  t[El.oil] = ElCat.liquid | ElCat.flammable;
  t[El.acid] = ElCat.liquid | ElCat.danger;
  t[El.glass] = ElCat.solid;
  t[El.dirt] = ElCat.organic;
  t[El.plant] = ElCat.organic | ElCat.flammable;
  t[El.lava] = ElCat.liquid | ElCat.danger;
  t[El.snow] = ElCat.organic;
  t[El.wood] = ElCat.solid | ElCat.flammable;
  t[El.metal] = ElCat.solid | ElCat.conductive;
  t[El.smoke] = ElCat.gas;
  t[El.ash] = ElCat.organic;
  return t;
}();

// ---------------------------------------------------------------------------
// Never-settle table (elements that should never become dormant)
// ---------------------------------------------------------------------------

/// Elements that must never settle (have ongoing time-based behaviors).
/// Sized to [maxElements] for extensibility.
final Uint8List neverSettle = () {
  final t = Uint8List(maxElements);
  for (final el in [
    El.lava, El.fire, El.smoke, El.steam, El.bubble, El.acid, El.ash,
    El.ant, El.plant, El.dirt, El.wood, El.metal, El.oil, El.mud,
    El.snow, El.rainbow,
  ]) {
    t[el] = 1;
  }
  return t;
}();

// ---------------------------------------------------------------------------
// Element physics states
// ---------------------------------------------------------------------------

/// Physics state determines how an element moves in the unified movement system.
enum PhysicsState {
  /// Does not move (stone, metal, glass, ice, wood).
  solid,
  /// Falls fast, piles diagonally (sand, dirt, TNT).
  granular,
  /// Falls, spreads laterally based on viscosity (water, oil, acid, lava, mud).
  liquid,
  /// Rises, spreads laterally (smoke, steam, fire, rainbow).
  gas,
  /// Falls very slowly, drifts (ash, snow, bubble).
  powder,
  /// Special movement handled entirely by custom logic (ant, lightning, seed, plant).
  special,
}

// ---------------------------------------------------------------------------
// Element properties -- property-driven physics data per element type
// ---------------------------------------------------------------------------

/// Physical properties for each element type.
///
/// This enables property-driven physics: movement, density displacement,
/// temperature reactions, and viscosity are all derived from these values
/// instead of being hard-coded per element.
class ElementProperties {
  /// Density (0-255). Heavier elements sink through lighter ones.
  /// Air/empty = 0, gases ~5-15, liquids ~60-120, granulars ~140-180, solids ~200-255.
  final int density;

  /// Viscosity (1-10). How many frames between lateral movements for liquids.
  /// Water=1, Oil=2, Mud=3, Lava=4, Honey=5.
  final int viscosity;

  /// Gravity strength. Positive = falls, negative = rises, 0 = static.
  /// Sand=2, Water=1, Smoke=-1, Stone=0.
  final int gravity;

  /// Physics state governing movement pattern.
  final PhysicsState state;

  /// Whether this element can catch fire.
  final bool flammable;

  /// Heat conductivity (0.0-1.0). How fast temperature transfers to neighbors.
  /// Metal=0.9, Stone=0.5, Water=0.3, Wood=0.1, Air=0.02.
  final double heatConductivity;

  /// Temperature at which a solid becomes liquid (0 = no melting).
  /// Ice=40, Stone=220, Metal=240, Glass=200.
  final int meltPoint;

  /// Temperature at which a liquid becomes gas (0 = no boiling).
  /// Water=180, Oil=160.
  final int boilPoint;

  /// Temperature at which a liquid becomes solid (0 = no freezing).
  /// Water=30, Lava=60.
  final int freezePoint;

  /// Element this becomes when it melts (0 = none).
  final int meltsInto;

  /// Element this becomes when it boils/evaporates (0 = none).
  final int boilsInto;

  /// Element this becomes when it freezes (0 = none).
  final int freezesInto;

  /// Base temperature this element emits (0 = neutral, >128 = hot, <128 = cold).
  /// Fire=230, Lava=250, Ice=20, Snow=40, neutral=128.
  final int baseTemperature;

  /// Corrosion resistance (0-255). Higher = harder for acid to dissolve.
  /// Wood=30, Ice=40, Glass=50, Stone=60, Metal=90, empty/liquids=0.
  final int corrosionResistance;

  /// Light emission intensity (0-255). 0 = no glow.
  /// Fire=180, Lava=220, Lightning=255, Rainbow=100.
  final int lightEmission;

  /// Light emission color (RGB components, 0-255).
  final int lightR;
  final int lightG;
  final int lightB;

  /// Decay rate: 0 = eternal, 1-10 = frames per life increment.
  /// Fire=3, Smoke=2, Steam=1, Rainbow=1.
  final int decayRate;

  /// Element this becomes when life expires from decay. 0 = empty.
  /// Fire→smoke(22), Smoke→empty(0), Steam→water(2).
  final int decaysInto;

  /// Surface tension (0-10). Higher values make isolated droplets cohesive.
  /// Water=5, Oil=3, Acid=2, Lava=8, Mud=6.
  final int surfaceTension;

  /// Maximum fall velocity for momentum system.
  /// Sand=3, Water=2, Lava=1.
  final int maxVelocity;


  /// Porosity (0.0-1.0). How easily this element absorbs water.
  /// Dirt=0.6, sand=0.3, wood=0.2, mud=0.4, stone=0.0, metal=0.0.
  final double porosity;

  /// Hardness (0-255). Resistance to destruction by explosions and acid.
  /// Empty=0, water=0, fire=5, metal=95, stone=80.
  final int hardness;

  /// Electrical conductivity (0.0-1.0). How well this element conducts electricity.
  /// Metal=0.95, water=0.6, acid=0.4, lava=0.3, everything else=0.0.
  final double conductivity;

  /// Wind resistance (0.0-1.0). How much this element resists wind displacement.
  /// Ash=0.1, smoke=0.15, stone/metal=1.0, water=0.9.
  final double windResistance;

  const ElementProperties({
    this.density = 0,
    this.viscosity = 1,
    this.gravity = 0,
    this.state = PhysicsState.solid,
    this.flammable = false,
    this.heatConductivity = 0.1,
    this.meltPoint = 0,
    this.boilPoint = 0,
    this.freezePoint = 0,
    this.meltsInto = 0,
    this.boilsInto = 0,
    this.freezesInto = 0,
    this.baseTemperature = 128,
    this.corrosionResistance = 0,
    this.lightEmission = 0,
    this.lightR = 0,
    this.lightG = 0,
    this.lightB = 0,
    this.decayRate = 0,
    this.decaysInto = 0,
    this.surfaceTension = 0,
    this.maxVelocity = 2,
    this.porosity = 0.0,
    this.hardness = 0,
    this.conductivity = 0.0,
    this.windResistance = 1.0,
  });
}

/// Pre-computed element properties table indexed by element ID.
/// Sized to [maxElements] for extensibility.
final List<ElementProperties> elementProperties = List<ElementProperties>.generate(
  maxElements,
  (_) => const ElementProperties(),
  growable: false,
);

/// Initialize the element properties table with values for all built-in elements.
void _initElementProperties() {
  // Empty / Air
  elementProperties[El.empty] = const ElementProperties(
    density: 0, gravity: 0, state: PhysicsState.special,
    heatConductivity: 0.02, baseTemperature: 128,
  
    porosity: 0.0, hardness: 0, conductivity: 0.0, windResistance: 0.0,
  );
  // Sand
  elementProperties[El.sand] = const ElementProperties(
    density: 150, gravity: 2, state: PhysicsState.granular,
    heatConductivity: 0.3, meltPoint: 248, meltsInto: El.glass,
    baseTemperature: 128, maxVelocity: 3,

    porosity: 0.3, hardness: 10, conductivity: 0.0, windResistance: 0.4,
  );
  // Water
  elementProperties[El.water] = const ElementProperties(
    density: 100, viscosity: 1, gravity: 1, state: PhysicsState.liquid,
    heatConductivity: 0.4, boilPoint: 180, freezePoint: 30,
    boilsInto: El.steam, freezesInto: El.ice, baseTemperature: 128,
    surfaceTension: 5, maxVelocity: 2,
  
    conductivity: 0.6, windResistance: 0.9,
  );
  // Fire
  elementProperties[El.fire] = const ElementProperties(
    density: 5, gravity: -1, state: PhysicsState.gas,
    heatConductivity: 0.8, baseTemperature: 230,
    lightEmission: 180, lightR: 255, lightG: 120, lightB: 20,
    decayRate: 3, decaysInto: El.smoke,
  
    hardness: 5, windResistance: 0.2,
  );
  // Ice
  elementProperties[El.ice] = const ElementProperties(
    density: 90, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.6, meltPoint: 40, meltsInto: El.water,
    baseTemperature: 20, corrosionResistance: 40,

    hardness: 40, windResistance: 1.0,
  );
  // Lightning
  elementProperties[El.lightning] = const ElementProperties(
    density: 0, gravity: 1, state: PhysicsState.special,
    heatConductivity: 1.0, baseTemperature: 250,
    lightEmission: 255, lightR: 255, lightG: 255, lightB: 180,
  
    windResistance: 1.0,
  );
  // Seed
  elementProperties[El.seed] = const ElementProperties(
    density: 130, gravity: 1, state: PhysicsState.special,
    flammable: true, heatConductivity: 0.1, baseTemperature: 128,
  
    hardness: 5, windResistance: 0.4,
  );
  // Stone
  elementProperties[El.stone] = const ElementProperties(
    density: 255, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.5, meltPoint: 220, meltsInto: El.lava,
    baseTemperature: 128, corrosionResistance: 60,

    hardness: 80, windResistance: 1.0,
  );
  // TNT
  elementProperties[El.tnt] = const ElementProperties(
    density: 140, gravity: 2, state: PhysicsState.granular,
    flammable: true, heatConductivity: 0.2, baseTemperature: 128,
  
    hardness: 15, windResistance: 0.7,
  );
  // Rainbow
  elementProperties[El.rainbow] = const ElementProperties(
    density: 8, gravity: -1, state: PhysicsState.gas,
    heatConductivity: 0.0, baseTemperature: 128,
    lightEmission: 100, lightR: 200, lightG: 100, lightB: 255,
    decayRate: 1, decaysInto: El.empty,
  
    windResistance: 0.1,
  );
  // Mud
  elementProperties[El.mud] = const ElementProperties(
    density: 120, viscosity: 3, gravity: 1, state: PhysicsState.liquid,
    heatConductivity: 0.25, baseTemperature: 128,
    surfaceTension: 6, maxVelocity: 1,
  
    porosity: 0.4, hardness: 15, windResistance: 0.85,
  );
  // Steam
  elementProperties[El.steam] = const ElementProperties(
    density: 3, gravity: -1, state: PhysicsState.gas,
    heatConductivity: 0.3, freezePoint: 60, freezesInto: El.water,
    baseTemperature: 160,
    decayRate: 1, decaysInto: El.water,
  
    hardness: 2, windResistance: 0.2,
  );
  // Ant
  elementProperties[El.ant] = const ElementProperties(
    density: 80, gravity: 1, state: PhysicsState.special,
    flammable: true, heatConductivity: 0.1, baseTemperature: 128,
  
    hardness: 5, windResistance: 0.5,
  );
  // Oil
  elementProperties[El.oil] = const ElementProperties(
    density: 80, viscosity: 2, gravity: 1, state: PhysicsState.liquid,
    flammable: true, heatConductivity: 0.15, boilPoint: 160,
    boilsInto: El.smoke, baseTemperature: 128,
    surfaceTension: 3, maxVelocity: 2,
  
    hardness: 5, windResistance: 0.85,
  );
  // Acid
  elementProperties[El.acid] = const ElementProperties(
    density: 110, viscosity: 1, gravity: 1, state: PhysicsState.liquid,
    heatConductivity: 0.35, baseTemperature: 128,
    lightEmission: 30, lightR: 20, lightG: 255, lightB: 20,
    surfaceTension: 2, maxVelocity: 2,
  
    conductivity: 0.4, windResistance: 0.85,
  );
  // Glass
  elementProperties[El.glass] = const ElementProperties(
    density: 220, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.4, meltPoint: 200, meltsInto: El.sand,
    baseTemperature: 128, corrosionResistance: 50,

    hardness: 70, windResistance: 1.0,
  );
  // Dirt
  elementProperties[El.dirt] = const ElementProperties(
    density: 145, gravity: 1, state: PhysicsState.granular,
    heatConductivity: 0.2, baseTemperature: 128,
    maxVelocity: 3,
  
    porosity: 0.6, hardness: 30, windResistance: 0.7,
  );
  // Plant
  elementProperties[El.plant] = const ElementProperties(
    density: 60, gravity: 0, state: PhysicsState.special,
    flammable: true, heatConductivity: 0.1, baseTemperature: 128,
  
    porosity: 0.15, hardness: 20, windResistance: 1.0,
  );
  // Lava
  elementProperties[El.lava] = const ElementProperties(
    density: 200, viscosity: 4, gravity: 1, state: PhysicsState.liquid,
    heatConductivity: 0.9, freezePoint: 60, freezesInto: El.stone,
    baseTemperature: 250,
    lightEmission: 220, lightR: 255, lightG: 80, lightB: 10,
    surfaceTension: 8, maxVelocity: 1,
  
    hardness: 0, conductivity: 0.3, windResistance: 0.95,
  );
  // Snow
  elementProperties[El.snow] = const ElementProperties(
    density: 50, gravity: 1, state: PhysicsState.powder,
    heatConductivity: 0.15, meltPoint: 50, meltsInto: El.water,
    baseTemperature: 35,
  
    hardness: 8, windResistance: 0.3,
  );
  // Wood
  elementProperties[El.wood] = const ElementProperties(
    density: 85, gravity: 1, state: PhysicsState.solid,
    flammable: true, heatConductivity: 0.1, baseTemperature: 128,
    corrosionResistance: 30,

    porosity: 0.2, hardness: 50, windResistance: 1.0,
  );
  // Metal
  elementProperties[El.metal] = const ElementProperties(
    density: 240, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.9, meltPoint: 240, meltsInto: El.lava,
    baseTemperature: 128, corrosionResistance: 90,

    hardness: 95, conductivity: 0.95, windResistance: 1.0,
  );
  // Smoke
  elementProperties[El.smoke] = const ElementProperties(
    density: 4, gravity: -1, state: PhysicsState.gas,
    heatConductivity: 0.05, baseTemperature: 145,
    decayRate: 2, decaysInto: El.empty,
  
    hardness: 2, windResistance: 0.15,
  );
  // Bubble
  elementProperties[El.bubble] = const ElementProperties(
    density: 2, gravity: -1, state: PhysicsState.special,
    heatConductivity: 0.01, baseTemperature: 128,
  
    windResistance: 0.15,
  );
  // Ash
  elementProperties[El.ash] = const ElementProperties(
    density: 30, gravity: 1, state: PhysicsState.powder,
    heatConductivity: 0.1, baseTemperature: 135,
  
    hardness: 3, windResistance: 0.1,
  );

  // Rebuild all fast-access lookup tables
  _rebuildPropertyLookups();
}

/// Pre-computed density lookup table (Uint8List for hot-loop performance).
final Uint8List elementDensity = Uint8List(maxElements);

/// Pre-computed gravity lookup table (Int8List for signed values).
final Int8List elementGravity = Int8List(maxElements);

/// Pre-computed viscosity lookup table.
final Uint8List elementViscosity = Uint8List(maxElements);

/// Pre-computed physics state lookup table.
final Uint8List elementPhysicsState = Uint8List(maxElements);

/// Pre-computed base temperature lookup table.
final Uint8List elementBaseTemp = Uint8List(maxElements);

/// Pre-computed heat conductivity lookup (scaled 0-255 for integer math).
final Uint8List elementHeatCond = Uint8List(maxElements);

/// Pre-computed flammable lookup table.
final Uint8List elementFlammable = Uint8List(maxElements);

/// Pre-computed corrosion resistance lookup table.
final Uint8List elementCorrosionResistance = Uint8List(maxElements);

/// Pre-computed light emission intensity lookup table.
final Uint8List elementLightEmission = Uint8List(maxElements);

/// Pre-computed light emission color (R) lookup table.
final Uint8List elementLightR = Uint8List(maxElements);

/// Pre-computed light emission color (G) lookup table.
final Uint8List elementLightG = Uint8List(maxElements);

/// Pre-computed light emission color (B) lookup table.
final Uint8List elementLightB = Uint8List(maxElements);

/// Pre-computed decay rate lookup table.
final Uint8List elementDecayRate = Uint8List(maxElements);

/// Pre-computed decays-into element lookup table.
final Uint8List elementDecaysInto = Uint8List(maxElements);

/// Pre-computed surface tension lookup table.
final Uint8List elementSurfaceTension = Uint8List(maxElements);

/// Pre-computed max velocity lookup table.
final Uint8List elementMaxVelocity = Uint8List(maxElements);


/// Pre-computed porosity lookup table (scaled 0-255).
final Uint8List elementPorosity = Uint8List(maxElements);

/// Pre-computed hardness lookup table.
final Uint8List elementHardness = Uint8List(maxElements);

/// Pre-computed electrical conductivity lookup table (scaled 0-255).
final Uint8List elementConductivity = Uint8List(maxElements);

/// Pre-computed wind resistance lookup table (scaled 0-255).
final Uint8List elementWindResistance = Uint8List(maxElements);

/// Rebuild all lookup tables from [elementProperties].
/// Called by [_initElementProperties] after property values are set.
void _rebuildPropertyLookups() {
  for (int i = 0; i < maxElements; i++) {
    final p = elementProperties[i];
    elementDensity[i] = p.density;
    elementGravity[i] = p.gravity;
    elementViscosity[i] = p.viscosity;
    elementPhysicsState[i] = p.state.index;
    elementBaseTemp[i] = p.baseTemperature;
    elementHeatCond[i] = (p.heatConductivity * 255).round().clamp(0, 255);
    elementFlammable[i] = p.flammable ? 1 : 0;
    elementCorrosionResistance[i] = p.corrosionResistance;
    elementLightEmission[i] = p.lightEmission;
    elementLightR[i] = p.lightR;
    elementLightG[i] = p.lightG;
    elementLightB[i] = p.lightB;
    elementDecayRate[i] = p.decayRate;
    elementDecaysInto[i] = p.decaysInto;
    elementPorosity[i] = (p.porosity * 255).round().clamp(0, 255);
    elementHardness[i] = p.hardness.clamp(0, 255);
    elementConductivity[i] = (p.conductivity * 255).round().clamp(0, 255);
    elementWindResistance[i] = (p.windResistance * 255).round().clamp(0, 255);
    elementSurfaceTension[i] = p.surfaceTension;
    elementMaxVelocity[i] = p.maxVelocity;
  }
}

// ---------------------------------------------------------------------------
// Plant data constants
// ---------------------------------------------------------------------------

const int kPlantGrass = 1;
const int kPlantFlower = 2;
const int kPlantTree = 3;
const int kPlantMushroom = 4;
const int kPlantVine = 5;

const int kStSprout = 0;
const int kStGrowing = 1;
const int kStMature = 2;
const int kStWilting = 3;
const int kStDead = 4;

/// Maximum height by plant type.
const List<int> plantMaxH = [0, 3, 6, 15, 3, 12];

/// Minimum soil moisture required to grow.
const List<int> plantMinMoist = [0, 1, 2, 3, 4, 2];

/// Growth rate (lower = faster). Tick modulo gate.
const List<int> plantGrowRate = [0, 25, 35, 20, 40, 30];

// ---------------------------------------------------------------------------
// Ant state constants
// ---------------------------------------------------------------------------

const int antExplorerState = 0;
const int antDiggerState = 1;
const int antCarrierState = 2;
const int antReturningState = 3;
const int antForagerState = 4;
const int antDrowningBase = 10;

// ---------------------------------------------------------------------------
// Element metadata registry (extensible)
// ---------------------------------------------------------------------------

/// Callback type for custom element simulation behaviors.
typedef ElementBehaviorFn = void Function(
  dynamic engine, int x, int y, int idx,
);

/// Metadata for a single element type.
class ElementInfo {
  final int id;
  final String name;
  final int color;
  final int category;
  final int windSens;
  final bool isStatic;
  final bool neverSettles;

  /// Optional custom behavior function for runtime-registered elements.
  /// Built-in elements use the switch dispatch in element_behaviors.dart.
  final ElementBehaviorFn? behavior;

  /// Whether this element is available in the user palette.
  final bool placeable;

  const ElementInfo({
    required this.id,
    required this.name,
    required this.color,
    this.category = 0,
    this.windSens = 0,
    this.isStatic = false,
    this.neverSettles = false,
    this.behavior,
    this.placeable = true,
  });
}

/// Central registry of all element types and their metadata.
///
/// Truly extensible: [register] adds new elements and propagates their
/// properties to all lookup tables (colors, categories, wind sensitivity,
/// settle behavior, static set). The simulation engine's behavior dispatch
/// checks [customBehaviors] for IDs beyond the built-in set.
class ElementRegistry {
  static final Map<int, ElementInfo> _elements = {};

  /// Custom behavior functions for runtime-registered elements.
  /// The behavior dispatch checks this map for element IDs not handled
  /// by the built-in switch statement.
  static final Map<int, ElementBehaviorFn> customBehaviors = {};

  /// Track the next available ID for auto-assigned elements.
  static int _nextCustomId = El.count;

  /// Initialize with all built-in elements.
  static void init() {
    if (_elements.isNotEmpty) return;
    _initElementProperties();
    for (int i = 0; i < El.count; i++) {
      _elements[i] = ElementInfo(
        id: i,
        name: elementNames[i],
        color: baseColors[i],
        category: i < elCategory.length ? elCategory[i] : 0,
        windSens: i < windSensitivity.length ? windSensitivity[i] : 0,
        isStatic: staticElements.contains(i),
        neverSettles: neverSettle[i] != 0,
        placeable: i != El.empty,
      );
    }
  }

  /// Register a custom element type at runtime.
  ///
  /// Propagates all properties to the global lookup tables so the
  /// simulation engine, renderer, and AI sensing all recognize the
  /// new element without any code changes.
  static void register(ElementInfo info) {
    assert(info.id > 0 && info.id < maxElements,
        'Element ID ${info.id} out of range 1..${maxElements - 1}');
    _elements[info.id] = info;

    // Propagate to lookup tables.
    baseColors[info.id] = info.color;
    elementNames[info.id] = info.name;
    elCategory[info.id] = info.category;
    windSensitivity[info.id] = info.windSens;
    neverSettle[info.id] = info.neverSettles ? 1 : 0;
    if (info.isStatic) {
      staticElements.add(info.id);
    } else {
      staticElements.remove(info.id);
    }

    // Register custom behavior if provided.
    if (info.behavior != null) {
      customBehaviors[info.id] = info.behavior!;
    }

    // Update next ID tracker.
    if (info.id >= _nextCustomId) {
      _nextCustomId = info.id + 1;
    }
  }

  /// Allocate the next available element ID.
  static int nextId() {
    final id = _nextCustomId;
    _nextCustomId++;
    return id;
  }

  /// Look up element info by ID.
  static ElementInfo? byId(int id) => _elements[id];

  /// Look up element by name (case-insensitive).
  static ElementInfo? byName(String name) {
    final lower = name.toLowerCase();
    for (final e in _elements.values) {
      if (e.name.toLowerCase() == lower) return e;
    }
    return null;
  }

  /// All registered element types.
  static Iterable<ElementInfo> get all => _elements.values;

  /// All placeable element IDs (excludes empty, non-placeable).
  static List<int> get placeableIds =>
      _elements.values
          .where((e) => e.placeable && e.id != El.empty)
          .map((e) => e.id)
          .toList();
}
