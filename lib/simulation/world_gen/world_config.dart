import 'dart:math';

/// Configuration for procedural world generation.
///
/// Default dimensions are landscape-oriented (400x360) to match the
/// [ParticleEngineGame] grid defaults.
class WorldConfig {
  const WorldConfig({
    this.width = 320,
    this.height = 180,
    this.seed = 42,
    this.terrainScale = 1.0,
    this.waterLevel = 0.4,
    this.caveDensity = 0.3,
    this.vegetation = 0.5,
    this.placeAnts = false,
  });

  /// Grid width in cells (landscape: wider than tall).
  final int width;

  /// Grid height in cells.
  final int height;

  /// Random seed — same seed produces the same world.
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

  // -- Presets ----------------------------------------------------------------

  /// Gentle rolling hills, ponds, lush green vegetation.
  ///
  /// Low terrain scale for smooth gentle slopes. Moderate water for
  /// natural ponds in valleys. Very high vegetation for dense forests
  /// and grass coverage. Minimal caves.
  factory WorldConfig.meadow({int seed = 42, int width = 320, int height = 180}) =>
      WorldConfig(
        width: width,
        height: height,
        seed: seed,
        terrainScale: 0.6,
        waterLevel: 0.50,
        caveDensity: 0.05,
        vegetation: 0.92,
      );

  /// Deep V-shaped canyon with steep cliff walls and river at bottom.
  ///
  /// Very high terrain scale for dramatic elevation. Water collects
  /// in the canyon floor with waterfalls from cliff ledges. Exposed
  /// stone layers, small cliff-face caves. Sandy bottom near river.
  factory WorldConfig.canyon({int seed = 42, int width = 320, int height = 180}) =>
      WorldConfig(
        width: width,
        height: height,
        seed: seed,
        terrainScale: 2.5,
        waterLevel: 0.35,
        caveDensity: 0.50,
        vegetation: 0.12,
      );

  /// Tropical island rising from deep ocean.
  ///
  /// Central landmass with radial heightmap falloff into deep ocean.
  /// Sandy beaches at waterline, lush vegetation, small caves in
  /// the island's stone core. Ocean at least 30% of grid height.
  factory WorldConfig.island({int seed = 42, int width = 320, int height = 180}) =>
      WorldConfig(
        width: width,
        height: height,
        seed: seed,
        terrainScale: 1.3,
        waterLevel: 0.70,
        caveDensity: 0.20,
        vegetation: 0.75,
      );

  /// Cave explorer's dream — massive underground cave system.
  ///
  /// Only 5-10% sky. 4-7 large cavern chambers with stalactites/
  /// stalagmites, underground lava lake, underground rivers, crystal
  /// formations, mushroom growths. Dense ore veins.
  factory WorldConfig.underground({int seed = 42, int width = 320, int height = 180}) =>
      WorldConfig(
        width: width,
        height: height,
        seed: seed,
        terrainScale: 0.3,
        waterLevel: 0.25,
        caveDensity: 0.80,
        vegetation: 0.02,
      );

  /// Randomized parameters for maximum variety.
  ///
  /// Each parameter is independently randomized within its valid range,
  /// producing unique worlds every time.
  factory WorldConfig.random({required int seed, int width = 320, int height = 180}) {
    final rng = Random(seed);
    return WorldConfig(
      width: width,
      height: height,
      seed: seed,
      terrainScale: 0.4 + rng.nextDouble() * 1.8,   // 0.4 - 2.2
      waterLevel: 0.1 + rng.nextDouble() * 0.6,      // 0.1 - 0.7
      caveDensity: rng.nextDouble() * 0.7,            // 0.0 - 0.7
      vegetation: 0.1 + rng.nextDouble() * 0.8,      // 0.1 - 0.9
      placeAnts: rng.nextBool(),
    );
  }
}
