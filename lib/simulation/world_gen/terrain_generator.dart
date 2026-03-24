import '../element_registry.dart';
import 'grid_data.dart';
import 'noise.dart';
import 'world_config.dart';

/// Generates the base terrain layers from a heightmap.
///
/// Produces geologically realistic stratigraphy:
///   Sky > Grass > Compost > Dirt > Clay > Stone > Deep Stone (bedrock)
///
/// Density ordering matches real geology: lighter materials on top,
/// heavier materials at depth. Ore veins, coal seams, and other
/// geological features are placed by [FeaturePlacer] after this step.
class TerrainGenerator {
  TerrainGenerator._();

  /// Generate a heightmap using multi-octave simplex noise with macro/micro
  /// layering for natural-looking terrain.
  ///
  /// Returns a list of length [config.width] where each value is the Y
  /// coordinate of the terrain surface at that X position.
  /// Lower Y = higher elevation (screen coordinates).
  static List<int> generateHeightmap(WorldConfig config) {
    final noise = SimplexNoise(config.seed);
    final noise2 = SimplexNoise(config.seed + 100);
    final noise3 = SimplexNoise(config.seed + 200);
    final heightmap = List<int>.filled(config.width, 0);

    final baseHeight = (config.height * 0.38).round();
    final terrainAmplitude = config.height * 0.18 * config.terrainScale;

    for (var x = 0; x < config.width; x++) {
      final nx = x / config.width;

      // --- Macro shape: large rolling hills (low frequency) ---
      final macro = noise.octaveNoise2D(
        nx * 3.0,
        0.0,
        octaves: 3,
        persistence: 0.5,
        lacunarity: 2.0,
      );

      // --- Medium detail: ridges and valleys (medium frequency) ---
      final medium = noise2.octaveNoise2D(
        nx * 8.0,
        0.5,
        octaves: 2,
        persistence: 0.4,
        lacunarity: 2.0,
      );

      // --- Micro detail: small bumps and roughness (high frequency) ---
      final micro = noise3.octaveNoise2D(
        nx * 20.0,
        1.0,
        octaves: 2,
        persistence: 0.3,
        lacunarity: 2.5,
      );

      final combined = macro * 0.65 + medium * 0.25 + micro * 0.10;

      // --- Plateau effect: flatten near certain elevations ---
      final plateauNoise = noise.noise2D(nx * 2.0, 3.0);
      double height = combined;
      if (plateauNoise > 0.3) {
        final steps = 4.0;
        final quantized = (combined * steps).roundToDouble() / steps;
        final blend = ((plateauNoise - 0.3) / 0.3).clamp(0.0, 1.0);
        height = combined * (1.0 - blend) + quantized * blend;
      }

      // --- Ridge effect: sharp peaks at noise extremes ---
      final ridgeNoise = noise2.noise2D(nx * 5.0, 2.0);
      if (ridgeNoise.abs() < 0.15) {
        final ridgeStrength = 1.0 - (ridgeNoise.abs() / 0.15);
        height += ridgeStrength * 0.25 * config.terrainScale;
      }

      heightmap[x] = (baseHeight + height * terrainAmplitude).round().clamp(
            5,
            config.height - 20,
          );
    }

    // --- Preset-specific shaping ---
    if (_isIslandConfig(config)) {
      _applyIslandFalloff(heightmap, config);
    } else if (_isCanyonConfig(config)) {
      _applyCanyonShape(heightmap, config);
    } else if (_isUndergroundConfig(config)) {
      _applyUndergroundShape(heightmap, config);
    }

    return heightmap;
  }

  static bool _isIslandConfig(WorldConfig config) =>
      config.waterLevel >= 0.60 &&
      config.terrainScale >= 1.0 &&
      config.terrainScale <= 1.5;

  static bool _isCanyonConfig(WorldConfig config) =>
      config.terrainScale >= 1.8 && config.caveDensity >= 0.4 &&
      config.waterLevel < 0.55;

  static bool _isUndergroundConfig(WorldConfig config) =>
      config.caveDensity >= 0.6 && config.vegetation <= 0.1 &&
      config.terrainScale < 1.0;

  static void _applyIslandFalloff(List<int> heightmap, WorldConfig config) {
    final center = config.width / 2.0;
    final maxDist = config.width / 2.0;
    final waterLine = (config.height * 0.55).round();

    for (var x = 0; x < config.width; x++) {
      final dist = (x - center).abs() / maxDist;

      if (dist < 0.15) {
        final peakFactor = 1.0 - (dist / 0.15);
        final raise = (peakFactor * config.height * 0.08).round();
        heightmap[x] = (heightmap[x] - raise).clamp(5, config.height - 10);
      }

      if (dist > 0.20) {
        final falloff = ((dist - 0.20) / 0.80);
        final push = (falloff * falloff * falloff * config.height * 0.8).round();
        heightmap[x] = (heightmap[x] + push).clamp(0, config.height - 8);
      }
      if (dist > 0.55) {
        final deepPush = ((dist - 0.55) / 0.45) * config.height * 0.15;
        heightmap[x] = (heightmap[x] + deepPush.round())
            .clamp(waterLine + 5, config.height - 8);
      }
    }
  }

  static void _applyCanyonShape(List<int> heightmap, WorldConfig config) {
    final center = config.width / 2.0;
    final canyonWidth = config.width * 0.30;
    final canyonNoise = SimplexNoise(config.seed + 600);

    for (var x = 0; x < config.width; x++) {
      final dist = (x - center).abs();

      if (dist < canyonWidth) {
        final depth = 1.0 - (dist / canyonWidth);
        final valleyDepth = (depth * config.height * 0.50).round();
        final noise = canyonNoise.noise2D(x / 8.0, 0.0) * 3;
        heightmap[x] = (heightmap[x] + valleyDepth + noise.round())
            .clamp(5, config.height - 15);
      }

      if (dist > canyonWidth * 0.7 && dist < canyonWidth * 1.4) {
        final wallFactor =
            1.0 - ((dist - canyonWidth * 0.7) / (canyonWidth * 0.7)).abs();
        final raise = (wallFactor * config.height * 0.18).round();
        heightmap[x] = (heightmap[x] - raise).clamp(5, config.height - 15);
      }
    }
  }

  static void _applyUndergroundShape(List<int> heightmap, WorldConfig config) {
    final entranceNoise = SimplexNoise(config.seed + 500);
    for (var x = 0; x < config.width; x++) {
      var surface = (config.height * 0.06).round();
      final variation = entranceNoise.noise2D(x / 12.0, 0.0);
      if (variation > 0.6) {
        surface += ((variation - 0.6) * config.height * 0.10).round();
      } else {
        surface += (variation * 2).round().abs();
      }
      heightmap[x] = surface.clamp(3, (config.height * 0.12).round());
    }
  }

  /// Fill the grid with geologically realistic terrain layers.
  ///
  /// Stratigraphy (top to bottom at each column):
  /// 1. Empty (sky) -- above heightmap
  /// 2. Compost -- thin decomposed organic layer under surface
  /// 3. Dirt (topsoil) -- variable depth, thicker in meadows
  /// 4. Clay transition -- between dirt and stone, near water bodies
  /// 5. Stone -- bulk underground
  /// 6. Deep stone (bedrock) -- bottom 5 cells, indestructible
  ///
  /// The compost and clay layers are new additions that create more
  /// geologically realistic stratigraphy and feed the chemistry system.
  static GridData fillLayers(WorldConfig config, List<int> heightmap) {
    final data = GridData.empty(config.width, config.height);
    final noise = SimplexNoise(config.seed + 300);
    final clayNoise = SimplexNoise(config.seed + 310);

    for (var x = 0; x < config.width; x++) {
      final surfaceY = heightmap[x];
      final dirtD = _dirtDepth(x, config, noise);
      // Compost: thin organic layer just under surface.
      final compostD = (1 + (config.compostDepth * (config.compostMaxCells - 1) *
          ((noise.noise2D(x / 12.0, 2.0) + 1) * 0.5))).round().clamp(0, config.compostMaxCells);
      // Clay transition between dirt and stone.
      final clayD = (config.clayNearWater * config.clayMaxCells *
          ((clayNoise.noise2D(x / 15.0, 0.0) + 1) * 0.5)).round().clamp(0, config.clayMaxCells);

      for (var y = 0; y < config.height; y++) {
        if (y < surfaceY) {
          // Sky -- already El.empty (0).
          continue;
        }

        final depth = y - surfaceY;

        if (depth < compostD && config.compostDepth > 0) {
          // Compost layer: decomposed organics right under surface.
          data.set(x, y, El.compost);
        } else if (depth < dirtD) {
          data.set(x, y, El.dirt);
        } else if (depth < dirtD + clayD) {
          // Clay transition between dirt and stone.
          data.set(x, y, El.clay);
        } else if (y >= config.height - 5) {
          // Bedrock boundary.
          data.set(x, y, El.stone);
        } else {
          data.set(x, y, El.stone);
        }
      }
    }

    return data;
  }

  /// Variable dirt depth per column using noise for organic variation.
  /// Uses config.dirtDepthBase and config.dirtDepthVariance instead of
  /// hardcoded values so Optuna can tune per-preset dirt profiles.
  static int _dirtDepth(int x, WorldConfig config, SimplexNoise noise) {
    final n = noise.noise2D(x / 20.0, config.seed * 0.01);
    final normalized = (n + 1.0) * 0.5; // 0..1
    return (config.dirtDepthBase + normalized * config.dirtDepthVariance).round();
  }
}
