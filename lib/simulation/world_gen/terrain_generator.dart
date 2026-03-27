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
    final continentalNoise = SimplexNoise(config.seed);
    final macroNoise = SimplexNoise(config.seed + 100);
    final ridgeNoise = SimplexNoise(config.seed + 200);
    final detailNoise = SimplexNoise(config.seed + 300);
    final humidityNoise = SimplexNoise(config.seed + 400);
    final heightmap = List<int>.filled(config.width, 0);

    final baseHeight = (config.height * 0.39).round();
    final terrainAmplitude = config.height * (0.12 + config.terrainScale * 0.10);

    for (var x = 0; x < config.width; x++) {
      final nx = x / config.width;
      final continental = continentalNoise.octaveNoise2D(
        nx * 1.6,
        0.15,
        octaves: 3,
        persistence: 0.55,
        lacunarity: 2.0,
      );
      final macro = macroNoise.octaveNoise2D(
        nx * 4.0,
        0.6,
        octaves: 3,
        persistence: 0.48,
        lacunarity: 2.1,
      );
      final ridges = 1.0 - ridgeNoise.noise2D(nx * 7.0, 1.7).abs();
      final detail = detailNoise.octaveNoise2D(
        nx * 16.0,
        2.2,
        octaves: 2,
        persistence: 0.35,
        lacunarity: 2.6,
      );
      final humidity = (humidityNoise.noise2D(nx * 3.4, 4.3) + 1.0) * 0.5;

      double heightSignal =
          continental * 0.34 + macro * 0.33 + (ridges - 0.5) * 0.24 + detail * 0.09;

      // Wetter worlds get broader valleys so surface water can read as part of
      // the terrain instead of isolated post-placed pockets.
      final basinStrength = (config.waterLevel * 0.18 + config.vegetation * 0.08) * humidity;
      heightSignal -= basinStrength;

      // High-energy worlds should read craggier rather than simply taller.
      if (config.terrainScale > 1.2) {
        heightSignal += (ridges - 0.5) * 0.18 * (config.terrainScale - 1.0);
      }

      heightmap[x] = (baseHeight + heightSignal * terrainAmplitude)
          .round()
          .clamp(5, config.height - 20);
    }

    _smoothHeightmap(heightmap, config);
    _carveHydrologyBasins(heightmap, config);

    if (_isIslandConfig(config)) {
      _applyIslandFalloff(heightmap, config);
    } else if (_isCanyonConfig(config)) {
      _applyCanyonShape(heightmap, config);
    } else if (_isUndergroundConfig(config)) {
      _applyUndergroundShape(heightmap, config);
    }

    _smoothHeightmap(heightmap, config, passes: 1);
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

  static void _smoothHeightmap(
    List<int> heightmap,
    WorldConfig config, {
    int passes = 2,
  }) {
    for (var pass = 0; pass < passes; pass++) {
      final copy = List<int>.from(heightmap);
      for (var x = 1; x < heightmap.length - 1; x++) {
        final left = copy[x - 1];
        final center = copy[x];
        final right = copy[x + 1];
        final smoothed = ((left + center * 2 + right) / 4).round();
        final maxDelta = config.terrainScale > 1.6 ? 4 : 3;
        heightmap[x] = smoothed.clamp(center - maxDelta, center + maxDelta);
      }
    }
  }

  static void _carveHydrologyBasins(List<int> heightmap, WorldConfig config) {
    if (config.waterLevel < 0.20) return;

    final basinNoise = SimplexNoise(config.seed + 450);
    final minSpan = (config.width / 18).round().clamp(6, 20);

    for (var x = minSpan; x < config.width - minSpan; x++) {
      final basinSignal = (basinNoise.noise2D(x / 14.0, 1.3) + 1.0) * 0.5;
      if (basinSignal < 0.62) continue;

      final radius = (minSpan * (0.8 + basinSignal * 0.9)).round();
      final depth = (config.height * (0.015 + config.waterLevel * 0.035) * basinSignal).round();

      for (var dx = -radius; dx <= radius; dx++) {
        final nx = x + dx;
        if (nx <= 1 || nx >= config.width - 2) continue;
        final normalized = 1.0 - (dx.abs() / radius);
        final carve = (depth * normalized * normalized).round();
        heightmap[nx] = (heightmap[nx] + carve).clamp(5, config.height - 12);
      }

      x += radius ~/ 2;
    }
  }

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
  static GridData fillLayers(WorldConfig config, List<int> heightmap) {
    final data = GridData.empty(config.width, config.height);
    final soilNoise = SimplexNoise(config.seed + 500);
    final clayNoise = SimplexNoise(config.seed + 310);
    final moistureNoise = SimplexNoise(config.seed + 320);

    for (var x = 0; x < config.width; x++) {
      final surfaceY = heightmap[x];
      final left = heightmap[(x - 1).clamp(0, config.width - 1)];
      final right = heightmap[(x + 1).clamp(0, config.width - 1)];
      final slope = (right - left).abs();
      final localLowland = ((surfaceY / config.height) - 0.25).clamp(0.0, 1.0);
      final wetness = ((moistureNoise.noise2D(x / 18.0, 0.7) + 1.0) * 0.5) * 0.6 +
          config.waterLevel * 0.4;

      final dirtD = _dirtDepth(x, config, soilNoise, wetness, slope);
      final compostD = (config.compostDepth * config.compostMaxCells * (0.45 + wetness * 0.9) * (slope > 7 ? 0.35 : 1.0))
          .round()
          .clamp(0, config.compostMaxCells);
      final clayD = (config.clayNearWater * config.clayMaxCells * (0.35 + localLowland * 0.75 + wetness * 0.35) *
              ((clayNoise.noise2D(x / 15.0, 0.0) + 1) * 0.5))
          .round()
          .clamp(0, config.clayMaxCells + 1);
      final exposedStoneDepth = slope > 9 ? 2 : slope > 6 ? 1 : 0;

      for (var y = 0; y < config.height; y++) {
        if (y < surfaceY) continue;

        final depth = y - surfaceY;
        if (depth < compostD && config.compostDepth > 0 && slope < 8) {
          data.set(x, y, El.compost);
        } else if (depth < dirtD - exposedStoneDepth) {
          data.set(x, y, El.dirt);
        } else if (depth < dirtD + clayD) {
          data.set(x, y, slope > 10 ? El.stone : El.clay);
        } else {
          data.set(x, y, El.stone);
        }
      }
    }

    return data;
  }

  /// Variable dirt depth per column using noise plus biome-aware wetness and slope.
  static int _dirtDepth(
    int x,
    WorldConfig config,
    SimplexNoise noise,
    double wetness,
    int slope,
  ) {
    final n = noise.noise2D(x / 20.0, config.seed * 0.01);
    final normalized = (n + 1.0) * 0.5;
    final slopePenalty = slope > 10 ? 0.45 : slope > 6 ? 0.75 : 1.0;
    final depth = (config.dirtDepthBase + normalized * config.dirtDepthVariance) *
        (0.78 + wetness * 0.45) *
        slopePenalty;
    return depth.round().clamp(2, (config.dirtDepthBase + config.dirtDepthVariance).round() + 2);
  }
}
