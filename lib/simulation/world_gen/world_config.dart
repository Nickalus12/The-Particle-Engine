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
        terrainScale: 0.5,
        waterLevel: 0.45,
        caveDensity: 0.10,
        vegetation: 0.85,
      );

  /// Deep valley with steep cliff walls and river at bottom.
  ///
  /// Very high terrain scale for dramatic elevation. Water collects
  /// in the canyon floor. Snow caps on the highest peaks. Moderate
  /// cave networks in the cliff walls. Sparse vegetation.
  factory WorldConfig.canyon({int seed = 42, int width = 320, int height = 180}) =>
      WorldConfig(
        width: width,
        height: height,
        seed: seed,
        terrainScale: 2.2,
        waterLevel: 0.40,
        caveDensity: 0.45,
        vegetation: 0.20,
      );

  /// Central landmass surrounded by water on all sides.
  ///
  /// Island rises from sea with radial heightmap falloff. Sandy beaches
  /// at water edges. Moderate vegetation on the plateau. Small caves.
  factory WorldConfig.island({int seed = 42, int width = 320, int height = 180}) =>
      WorldConfig(
        width: width,
        height: height,
        seed: seed,
        terrainScale: 1.2,
        waterLevel: 0.65,
        caveDensity: 0.15,
        vegetation: 0.55,
      );

  /// Minimal sky, extensive cave networks, underground world.
  ///
  /// Surface is very high (small sky). Dense cave systems fill the
  /// underground. Underground water pools, lava pockets deep below.
  /// Almost no surface vegetation.
  factory WorldConfig.underground({int seed = 42, int width = 320, int height = 180}) =>
      WorldConfig(
        width: width,
        height: height,
        seed: seed,
        terrainScale: 0.4,
        waterLevel: 0.20,
        caveDensity: 0.75,
        vegetation: 0.03,
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
