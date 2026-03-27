import 'dart:math';

/// Configuration for procedural world generation.
///
/// Default dimensions are landscape-oriented (320x180) to match the
/// [ParticleEngineGame] grid defaults.
///
/// Parameters are organized into tiers:
/// - Core: terrain shape, water, caves, vegetation (original)
/// - Geology: ore richness, stratigraphy depth, volcanic activity
/// - Ecosystem: oxygen, moisture, decomposition, fungal growth
/// - Electrical: ore conductivity paths, insulating layers
class WorldConfig {
  const WorldConfig({
    this.width = 320,
    this.height = 180,
    this.seed = 42,
    // -- Core --
    this.terrainScale = 1.0,
    this.waterLevel = 0.4,
    this.caveDensity = 0.3,
    this.vegetation = 0.5,
    this.placeAnts = false,
    // -- Geology --
    this.oreRichness = 0.4,
    this.copperDepth = 0.3,
    this.metalDepth = 0.6,
    this.coalSeams = 0.2,
    this.sulfurNearLava = 0.5,
    this.saltDeposits = 0.15,
    this.clayNearWater = 0.4,
    this.volcanicActivity = 0.3,
    // -- Ecosystem --
    this.oxygenFill = true,
    this.co2InCaves = 0.3,
    this.compostDepth = 0.4,
    this.fungalGrowth = 0.3,
    this.algaeInWater = 0.4,
    this.seedScatter = 0.3,
    // -- Electrical --
    this.conductiveVeins = 0.3,
    this.insulatingLayers = 0.2,
    // -- Tuning (Optuna-searchable multipliers) --
    this.dirtDepthBase = 8.0,
    this.dirtDepthVariance = 17.0,
    this.compostMaxCells = 4,
    this.clayMaxCells = 3,
    this.oreMinDepth = 8,
    this.copperSpread = 20.0,
    this.metalSpread = 15.0,
    this.copperThresholdBase = 0.70,
    this.metalThresholdBase = 0.68,
    this.coalMinDepth = 5,
    this.coalMaxDepthFrac = 0.5,
    this.coalSeamThickness = 0.03,
    this.sulfurSearchRadius = 3,
    this.saltSearchRadius = 2,
    this.fungalMinDepth = 8,
    this.fungalMoistureRadius = 3,
    this.algaeShallowDepth = 5,
    this.seedMoistureRadius = 6,
  });

  /// Grid width in cells (landscape: wider than tall).
  final int width;

  /// Grid height in cells.
  final int height;

  /// Random seed -- same seed produces the same world.
  final int seed;

  /// Noise scale: 0.5 = gentle rolling, 2.0 = dramatic peaks.
  final double terrainScale;

  /// Water fill fraction 0.0-1.0.
  final double waterLevel;

  /// Cave density 0.0-1.0.
  final double caveDensity;

  /// Vegetation density 0.0-1.0.
  final double vegetation;

  /// Whether to place starter ant colonies.
  final bool placeAnts;

  // -- Geology ----------------------------------------------------------------

  /// Overall ore density 0.0-1.0. Affects all ore types proportionally.
  final double oreRichness;

  /// Depth fraction (0=surface, 1=bedrock) where copper veins concentrate.
  /// Real geology: copper is shallower than iron/metal.
  final double copperDepth;

  /// Depth fraction where metal (iron) veins concentrate.
  /// Real geology: iron is deeper than copper.
  final double metalDepth;

  /// Coal/charcoal seam density 0.0-1.0 in organic layers.
  final double coalSeams;

  /// Sulfur placement probability near lava features 0.0-1.0.
  final double sulfurNearLava;

  /// Salt deposit density 0.0-1.0 in dried lake beds / cave floors.
  final double saltDeposits;

  /// Clay deposit density 0.0-1.0 near water bodies.
  final double clayNearWater;

  /// Volcanic activity 0.0-1.0. More lava, sulfur, obsidian potential.
  final double volcanicActivity;

  // -- Ecosystem --------------------------------------------------------------

  /// Whether to fill all air cells with oxygen (background atmosphere).
  final bool oxygenFill;

  /// CO2 density in caves 0.0-1.0. Pools in cave floor depressions.
  final double co2InCaves;

  /// Compost layer thickness under topsoil 0.0-1.0.
  final double compostDepth;

  /// Fungal growth probability in dark moist caves 0.0-1.0.
  final double fungalGrowth;

  /// Algae growth in water bodies 0.0-1.0.
  final double algaeInWater;

  /// Seed scatter on fertile dirt 0.0-1.0.
  final double seedScatter;

  // -- Electrical -------------------------------------------------------------

  /// Density of conductive metal veins connecting layers 0.0-1.0.
  final double conductiveVeins;

  /// Density of insulating clay/glass layers blocking current 0.0-1.0.
  final double insulatingLayers;

  // -- Tuning (Optuna-searchable multipliers) ---------------------------------
  // These replace hardcoded constants so Optuna can explore full parameter space.

  /// Base dirt layer depth in cells (before noise variance).
  final double dirtDepthBase;

  /// Noise-driven dirt depth range added to base.
  final double dirtDepthVariance;

  /// Maximum compost layer thickness in cells.
  final int compostMaxCells;

  /// Maximum clay transition thickness in cells.
  final int clayMaxCells;

  /// Minimum cells below surface before ore can appear.
  final int oreMinDepth;

  /// Gaussian spread for copper depth profile (higher = wider band).
  final double copperSpread;

  /// Gaussian spread for metal depth profile (higher = wider band).
  final double metalSpread;

  /// Base noise threshold for copper placement (lower = more copper).
  final double copperThresholdBase;

  /// Base noise threshold for metal placement (lower = more metal).
  final double metalThresholdBase;

  /// Minimum cells below surface for coal seams.
  final int coalMinDepth;

  /// Maximum depth fraction (0-1) for coal seams.
  final double coalMaxDepthFrac;

  /// Noise band width controlling coal seam thickness.
  final double coalSeamThickness;

  /// Search radius (cells) for sulfur near lava detection.
  final int sulfurSearchRadius;

  /// Search radius (cells) for salt near water detection.
  final int saltSearchRadius;

  /// Minimum cells underground for fungal growth.
  final int fungalMinDepth;

  /// Moisture detection radius (cells) for fungal placement.
  final int fungalMoistureRadius;

  /// Cells below surface considered "shallow" for algae preference.
  final int algaeShallowDepth;

  /// Moisture detection radius (cells) for seed scatter.
  final int seedMoistureRadius;

  // -- Presets ----------------------------------------------------------------

  /// Gentle rolling hills, ponds, lush green vegetation.
  factory WorldConfig.meadow({int seed = 42, int width = 320, int height = 180}) =>
      WorldConfig(
        width: width,
        height: height,
        seed: seed,
        terrainScale: 0.6,
        waterLevel: 0.50,
        caveDensity: 0.05,
        vegetation: 0.92,
        oreRichness: 0.15,
        copperDepth: 0.35,
        metalDepth: 0.65,
        coalSeams: 0.10,
        sulfurNearLava: 0.0,
        saltDeposits: 0.05,
        clayNearWater: 0.50,
        volcanicActivity: 0.0,
        co2InCaves: 0.10,
        compostDepth: 0.60,
        fungalGrowth: 0.15,
        algaeInWater: 0.60,
        seedScatter: 0.55,
        conductiveVeins: 0.10,
        insulatingLayers: 0.15,
        // Meadow: deep rich soil, thick compost.
        dirtDepthBase: 15.0,
        dirtDepthVariance: 10.0,
        compostMaxCells: 4,
      );

  /// Deep V-shaped canyon with steep cliff walls and river at bottom.
  factory WorldConfig.canyon({int seed = 42, int width = 320, int height = 180}) =>
      WorldConfig(
        width: width,
        height: height,
        seed: seed,
        terrainScale: 2.5,
        waterLevel: 0.35,
        caveDensity: 0.50,
        vegetation: 0.12,
        oreRichness: 0.50,
        copperDepth: 0.25,
        metalDepth: 0.55,
        coalSeams: 0.30,
        sulfurNearLava: 0.40,
        saltDeposits: 0.20,
        clayNearWater: 0.35,
        volcanicActivity: 0.25,
        co2InCaves: 0.35,
        compostDepth: 0.20,
        fungalGrowth: 0.25,
        algaeInWater: 0.20,
        seedScatter: 0.10,
        conductiveVeins: 0.40,
        insulatingLayers: 0.25,
        // Canyon: thin dirt on cliff faces, wider ore bands.
        dirtDepthBase: 4.0,
        dirtDepthVariance: 6.0,
        compostMaxCells: 2,
        copperSpread: 25.0,
        metalSpread: 20.0,
      );

  /// Tropical island rising from deep ocean.
  factory WorldConfig.island({int seed = 42, int width = 320, int height = 180}) =>
      WorldConfig(
        width: width,
        height: height,
        seed: seed,
        terrainScale: 1.3,
        waterLevel: 0.70,
        caveDensity: 0.20,
        vegetation: 0.75,
        oreRichness: 0.30,
        copperDepth: 0.30,
        metalDepth: 0.60,
        coalSeams: 0.15,
        sulfurNearLava: 0.20,
        saltDeposits: 0.35,
        clayNearWater: 0.55,
        volcanicActivity: 0.15,
        co2InCaves: 0.20,
        compostDepth: 0.45,
        fungalGrowth: 0.20,
        algaeInWater: 0.70,
        seedScatter: 0.40,
        conductiveVeins: 0.20,
        insulatingLayers: 0.30,
        // Island: salt-rich from evaporation, wider salt detection.
        saltSearchRadius: 3,
        algaeShallowDepth: 7,
      );

  /// Cave explorer's dream -- massive underground cave system.
  factory WorldConfig.underground({int seed = 42, int width = 320, int height = 180}) =>
      WorldConfig(
        width: width,
        height: height,
        seed: seed,
        terrainScale: 0.3,
        waterLevel: 0.25,
        caveDensity: 0.80,
        vegetation: 0.02,
        oreRichness: 0.75,
        copperDepth: 0.25,
        metalDepth: 0.50,
        coalSeams: 0.45,
        sulfurNearLava: 0.70,
        saltDeposits: 0.40,
        clayNearWater: 0.30,
        volcanicActivity: 0.60,
        co2InCaves: 0.55,
        compostDepth: 0.10,
        fungalGrowth: 0.60,
        algaeInWater: 0.15,
        seedScatter: 0.02,
        conductiveVeins: 0.60,
        insulatingLayers: 0.35,
        // Underground: wide sulfur halos, deep coal, thick ore bands.
        sulfurSearchRadius: 5,
        coalMaxDepthFrac: 0.7,
        coalSeamThickness: 0.05,
        copperSpread: 25.0,
        metalSpread: 20.0,
        fungalMinDepth: 5,
        fungalMoistureRadius: 5,
      );

  /// Randomized parameters for maximum variety.
  factory WorldConfig.random({required int seed, int width = 320, int height = 180}) {
    final rng = Random(seed);
    return WorldConfig(
      width: width,
      height: height,
      seed: seed,
      terrainScale: 0.4 + rng.nextDouble() * 1.8,
      waterLevel: 0.1 + rng.nextDouble() * 0.6,
      caveDensity: rng.nextDouble() * 0.7,
      vegetation: 0.1 + rng.nextDouble() * 0.8,
      placeAnts: rng.nextBool(),
      oreRichness: 0.1 + rng.nextDouble() * 0.7,
      copperDepth: 0.15 + rng.nextDouble() * 0.30,
      metalDepth: 0.40 + rng.nextDouble() * 0.35,
      coalSeams: rng.nextDouble() * 0.5,
      sulfurNearLava: rng.nextDouble() * 0.7,
      saltDeposits: rng.nextDouble() * 0.4,
      clayNearWater: 0.1 + rng.nextDouble() * 0.5,
      volcanicActivity: rng.nextDouble() * 0.6,
      co2InCaves: rng.nextDouble() * 0.5,
      compostDepth: 0.1 + rng.nextDouble() * 0.5,
      fungalGrowth: rng.nextDouble() * 0.6,
      algaeInWater: 0.1 + rng.nextDouble() * 0.6,
      seedScatter: 0.1 + rng.nextDouble() * 0.5,
      conductiveVeins: rng.nextDouble() * 0.6,
      insulatingLayers: rng.nextDouble() * 0.4,
      // Tuning params: randomize within sensible ranges.
      dirtDepthBase: 4.0 + rng.nextDouble() * 14.0,
      dirtDepthVariance: 5.0 + rng.nextDouble() * 15.0,
      compostMaxCells: 2 + rng.nextInt(4),
      clayMaxCells: 1 + rng.nextInt(4),
      oreMinDepth: 5 + rng.nextInt(8),
      copperSpread: 12.0 + rng.nextDouble() * 18.0,
      metalSpread: 10.0 + rng.nextDouble() * 15.0,
      copperThresholdBase: 0.60 + rng.nextDouble() * 0.15,
      metalThresholdBase: 0.58 + rng.nextDouble() * 0.15,
      coalMinDepth: 3 + rng.nextInt(6),
      coalMaxDepthFrac: 0.3 + rng.nextDouble() * 0.4,
      coalSeamThickness: 0.02 + rng.nextDouble() * 0.06,
      sulfurSearchRadius: 2 + rng.nextInt(4),
      saltSearchRadius: 1 + rng.nextInt(3),
      fungalMinDepth: 5 + rng.nextInt(6),
      fungalMoistureRadius: 2 + rng.nextInt(4),
      algaeShallowDepth: 3 + rng.nextInt(6),
      seedMoistureRadius: 4 + rng.nextInt(5),
    );
  }

  /// Serialize to a flat map for Optuna / JSON round-tripping.
  Map<String, dynamic> toMap() => {
    'width': width,
    'height': height,
    'seed': seed,
    'terrainScale': terrainScale,
    'waterLevel': waterLevel,
    'caveDensity': caveDensity,
    'vegetation': vegetation,
    'placeAnts': placeAnts,
    'oreRichness': oreRichness,
    'copperDepth': copperDepth,
    'metalDepth': metalDepth,
    'coalSeams': coalSeams,
    'sulfurNearLava': sulfurNearLava,
    'saltDeposits': saltDeposits,
    'clayNearWater': clayNearWater,
    'volcanicActivity': volcanicActivity,
    'oxygenFill': oxygenFill,
    'co2InCaves': co2InCaves,
    'compostDepth': compostDepth,
    'fungalGrowth': fungalGrowth,
    'algaeInWater': algaeInWater,
    'seedScatter': seedScatter,
    'conductiveVeins': conductiveVeins,
    'insulatingLayers': insulatingLayers,
    'dirtDepthBase': dirtDepthBase,
    'dirtDepthVariance': dirtDepthVariance,
    'compostMaxCells': compostMaxCells,
    'clayMaxCells': clayMaxCells,
    'oreMinDepth': oreMinDepth,
    'copperSpread': copperSpread,
    'metalSpread': metalSpread,
    'copperThresholdBase': copperThresholdBase,
    'metalThresholdBase': metalThresholdBase,
    'coalMinDepth': coalMinDepth,
    'coalMaxDepthFrac': coalMaxDepthFrac,
    'coalSeamThickness': coalSeamThickness,
    'sulfurSearchRadius': sulfurSearchRadius,
    'saltSearchRadius': saltSearchRadius,
    'fungalMinDepth': fungalMinDepth,
    'fungalMoistureRadius': fungalMoistureRadius,
    'algaeShallowDepth': algaeShallowDepth,
    'seedMoistureRadius': seedMoistureRadius,
  };

  WorldConfig copyWith({
    int? width,
    int? height,
    int? seed,
    double? terrainScale,
    double? waterLevel,
    double? caveDensity,
    double? vegetation,
    bool? placeAnts,
    double? oreRichness,
    double? copperDepth,
    double? metalDepth,
    double? coalSeams,
    double? sulfurNearLava,
    double? saltDeposits,
    double? clayNearWater,
    double? volcanicActivity,
    bool? oxygenFill,
    double? co2InCaves,
    double? compostDepth,
    double? fungalGrowth,
    double? algaeInWater,
    double? seedScatter,
    double? conductiveVeins,
    double? insulatingLayers,
    double? dirtDepthBase,
    double? dirtDepthVariance,
    int? compostMaxCells,
    int? clayMaxCells,
    int? oreMinDepth,
    double? copperSpread,
    double? metalSpread,
    double? copperThresholdBase,
    double? metalThresholdBase,
    int? coalMinDepth,
    double? coalMaxDepthFrac,
    double? coalSeamThickness,
    int? sulfurSearchRadius,
    int? saltSearchRadius,
    int? fungalMinDepth,
    int? fungalMoistureRadius,
    int? algaeShallowDepth,
    int? seedMoistureRadius,
  }) {
    return WorldConfig(
      width: width ?? this.width,
      height: height ?? this.height,
      seed: seed ?? this.seed,
      terrainScale: terrainScale ?? this.terrainScale,
      waterLevel: waterLevel ?? this.waterLevel,
      caveDensity: caveDensity ?? this.caveDensity,
      vegetation: vegetation ?? this.vegetation,
      placeAnts: placeAnts ?? this.placeAnts,
      oreRichness: oreRichness ?? this.oreRichness,
      copperDepth: copperDepth ?? this.copperDepth,
      metalDepth: metalDepth ?? this.metalDepth,
      coalSeams: coalSeams ?? this.coalSeams,
      sulfurNearLava: sulfurNearLava ?? this.sulfurNearLava,
      saltDeposits: saltDeposits ?? this.saltDeposits,
      clayNearWater: clayNearWater ?? this.clayNearWater,
      volcanicActivity: volcanicActivity ?? this.volcanicActivity,
      oxygenFill: oxygenFill ?? this.oxygenFill,
      co2InCaves: co2InCaves ?? this.co2InCaves,
      compostDepth: compostDepth ?? this.compostDepth,
      fungalGrowth: fungalGrowth ?? this.fungalGrowth,
      algaeInWater: algaeInWater ?? this.algaeInWater,
      seedScatter: seedScatter ?? this.seedScatter,
      conductiveVeins: conductiveVeins ?? this.conductiveVeins,
      insulatingLayers: insulatingLayers ?? this.insulatingLayers,
      dirtDepthBase: dirtDepthBase ?? this.dirtDepthBase,
      dirtDepthVariance: dirtDepthVariance ?? this.dirtDepthVariance,
      compostMaxCells: compostMaxCells ?? this.compostMaxCells,
      clayMaxCells: clayMaxCells ?? this.clayMaxCells,
      oreMinDepth: oreMinDepth ?? this.oreMinDepth,
      copperSpread: copperSpread ?? this.copperSpread,
      metalSpread: metalSpread ?? this.metalSpread,
      copperThresholdBase: copperThresholdBase ?? this.copperThresholdBase,
      metalThresholdBase: metalThresholdBase ?? this.metalThresholdBase,
      coalMinDepth: coalMinDepth ?? this.coalMinDepth,
      coalMaxDepthFrac: coalMaxDepthFrac ?? this.coalMaxDepthFrac,
      coalSeamThickness: coalSeamThickness ?? this.coalSeamThickness,
      sulfurSearchRadius: sulfurSearchRadius ?? this.sulfurSearchRadius,
      saltSearchRadius: saltSearchRadius ?? this.saltSearchRadius,
      fungalMinDepth: fungalMinDepth ?? this.fungalMinDepth,
      fungalMoistureRadius:
          fungalMoistureRadius ?? this.fungalMoistureRadius,
      algaeShallowDepth: algaeShallowDepth ?? this.algaeShallowDepth,
      seedMoistureRadius: seedMoistureRadius ?? this.seedMoistureRadius,
    );
  }
}
