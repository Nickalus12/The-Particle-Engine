import '../element_registry.dart';
import 'grid_data.dart';
import 'noise.dart';
import 'world_config.dart';

/// Generates the base terrain layers from a heightmap.
///
/// Produces the raw geological structure: sky, topsoil, dirt, stone,
/// and deep stone. Cave carving, water, and features are applied separately
/// by [FeaturePlacer].
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

    // Terrain occupies roughly the middle portion of the grid vertically.
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

      // Combine layers with decreasing influence.
      final combined = macro * 0.65 + medium * 0.25 + micro * 0.10;

      // --- Plateau effect: flatten near certain elevations ---
      final plateauNoise = noise.noise2D(nx * 2.0, 3.0);
      double height = combined;
      if (plateauNoise > 0.3) {
        // Quantize to create flat plateaus.
        final steps = 4.0;
        final quantized = (combined * steps).roundToDouble() / steps;
        final blend = ((plateauNoise - 0.3) / 0.3).clamp(0.0, 1.0);
        height = combined * (1.0 - blend) + quantized * blend;
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

  /// Detect island-style config.
  static bool _isIslandConfig(WorldConfig config) =>
      config.waterLevel >= 0.60 &&
      config.terrainScale >= 1.0 &&
      config.terrainScale <= 1.5;

  /// Detect canyon-style config (high terrain scale, moderate cave density).
  static bool _isCanyonConfig(WorldConfig config) =>
      config.terrainScale >= 1.8 && config.caveDensity >= 0.4 &&
      config.waterLevel < 0.55;

  /// Detect underground-style config (high caves, low vegetation).
  static bool _isUndergroundConfig(WorldConfig config) =>
      config.caveDensity >= 0.6 && config.vegetation <= 0.1 &&
      config.terrainScale < 1.0;

  /// Push edges of the heightmap down to create an island shape.
  /// Creates a central landmass rising to a peak, with deep ocean at edges.
  static void _applyIslandFalloff(List<int> heightmap, WorldConfig config) {
    final center = config.width / 2.0;
    final maxDist = config.width / 2.0;
    // Water line — where the ocean surface sits.
    final waterLine = (config.height * 0.55).round();

    for (var x = 0; x < config.width; x++) {
      final dist = (x - center).abs() / maxDist;

      // Raise the center into a peak.
      if (dist < 0.15) {
        final peakFactor = 1.0 - (dist / 0.15);
        final raise = (peakFactor * config.height * 0.08).round();
        heightmap[x] = (heightmap[x] - raise).clamp(5, config.height - 10);
      }

      if (dist > 0.20) {
        // Steep falloff at island edges — pushes terrain below water line.
        final falloff = ((dist - 0.20) / 0.80);
        final push = (falloff * falloff * falloff * config.height * 0.8).round();
        heightmap[x] = (heightmap[x] + push).clamp(0, config.height - 8);
      }
      // Deep ocean floor at far edges.
      if (dist > 0.55) {
        final deepPush = ((dist - 0.55) / 0.45) * config.height * 0.15;
        heightmap[x] = (heightmap[x] + deepPush.round())
            .clamp(waterLine + 5, config.height - 8);
      }
    }
  }

  /// Create a deep V-shaped valley in the center for canyon preset.
  /// Canyon is 40-60% of grid height deep with steep cliff walls.
  static void _applyCanyonShape(List<int> heightmap, WorldConfig config) {
    final center = config.width / 2.0;
    final canyonWidth = config.width * 0.30;
    final canyonNoise = SimplexNoise(config.seed + 600);

    for (var x = 0; x < config.width; x++) {
      final dist = (x - center).abs();

      if (dist < canyonWidth) {
        // V-shape: linear depth increase toward center.
        final depth = 1.0 - (dist / canyonWidth);
        // Canyon cuts 40-55% of grid height deep.
        final valleyDepth = (depth * config.height * 0.50).round();
        // Add small noise for cliff texture.
        final noise = canyonNoise.noise2D(x / 8.0, 0.0) * 3;
        heightmap[x] = (heightmap[x] + valleyDepth + noise.round())
            .clamp(5, config.height - 15);
      }

      // Raise cliff walls dramatically at canyon edges.
      if (dist > canyonWidth * 0.7 && dist < canyonWidth * 1.4) {
        final wallFactor =
            1.0 - ((dist - canyonWidth * 0.7) / (canyonWidth * 0.7)).abs();
        final raise = (wallFactor * config.height * 0.18).round();
        heightmap[x] = (heightmap[x] - raise).clamp(5, config.height - 15);
      }
    }
  }

  /// Push terrain very high (5-10% sky) for underground preset.
  /// Leaves slight surface variation for 1-2 cave entrances.
  static void _applyUndergroundShape(List<int> heightmap, WorldConfig config) {
    final entranceNoise = SimplexNoise(config.seed + 500);
    for (var x = 0; x < config.width; x++) {
      // Base surface at ~6% from top (very little sky).
      var surface = (config.height * 0.06).round();
      // Slight variation for natural ceiling + occasional cave entrances.
      final variation = entranceNoise.noise2D(x / 12.0, 0.0);
      if (variation > 0.6) {
        // Cave entrance dip — sky reaches deeper here.
        surface += ((variation - 0.6) * config.height * 0.10).round();
      } else {
        surface += (variation * 2).round().abs();
      }
      heightmap[x] = surface.clamp(3, (config.height * 0.12).round());
    }
  }

  /// Fill the grid with terrain layers based on the heightmap.
  ///
  /// Layers from top to bottom at each column:
  /// 1. Empty (sky) — above heightmap
  /// 2. Grass (surface plant) — at terrain surface
  /// 3. Dirt (topsoil) — at surface, variable depth
  /// 4. Stone — bulk of underground
  /// 5. Deep stone (indestructible boundary) — bottom 5 cells
  static GridData fillLayers(WorldConfig config, List<int> heightmap) {
    final data = GridData.empty(config.width, config.height);
    final noise = SimplexNoise(config.seed + 300);

    for (var x = 0; x < config.width; x++) {
      final surfaceY = heightmap[x];
      final dirtD = _dirtDepth(x, config, noise);

      for (var y = 0; y < config.height; y++) {
        if (y < surfaceY) {
          // Sky — already El.empty (0).
          continue;
        }

        final depth = y - surfaceY;

        if (depth < dirtD) {
          data.set(x, y, El.dirt);
        } else if (y >= config.height - 5) {
          // Deep stone boundary (indestructible).
          data.set(x, y, El.stone);
        } else {
          data.set(x, y, El.stone);
        }
      }
    }

    return data;
  }

  /// Variable dirt depth per column using noise for organic variation.
  /// Meadow-like configs get richer dirt (15-25), canyon gets thin (4-10).
  static int _dirtDepth(int x, WorldConfig config, SimplexNoise noise) {
    final n = noise.noise2D(x / 20.0, config.seed * 0.01);
    final normalized = (n + 1.0) * 0.5; // 0..1

    // Canyon: thin dirt on cliff faces (exposed stone).
    if (_isCanyonConfig(config)) {
      return (4 + normalized * 6).round();
    }
    // Meadow: rich deep dirt.
    if (config.vegetation >= 0.8 && config.terrainScale < 1.0) {
      return (15 + normalized * 10).round();
    }
    // Default.
    return (8 + normalized * 17).round();
  }
}
