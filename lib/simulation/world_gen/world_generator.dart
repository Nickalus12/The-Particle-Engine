import '../element_registry.dart';
import 'feature_placer.dart';
import 'grid_data.dart';
import 'terrain_generator.dart';
import 'world_config.dart';

/// Main entry point for procedural world generation.
///
/// Produces a fully populated [GridData] from a [WorldConfig].
/// Deterministic: same config always produces the same world.
///
/// Usage:
/// ```dart
/// final config = WorldConfig.meadow(seed: 12345);
/// final gridData = WorldGenerator.generate(config);
/// gridData.loadIntoEngine(engine);
/// ```
class WorldGenerator {
  WorldGenerator._();

  /// Generate a complete procedural world.
  ///
  /// Pipeline:
  /// 1. Generate heightmap via multi-octave noise
  /// 2. Fill terrain layers (sky, dirt, stone, deep stone)
  /// 3. Carve caves using layered noise + cellular automata
  /// 4. Place water in depressions and underground pools
  /// 5. Place waterfalls at elevation drops
  /// 6. Place snow on highest peaks (top 10%)
  /// 7. Place lava pockets deep underground
  /// 8. Place metal ore deposits in stone
  /// 9. Place surface detail (sand beaches, boulders, grass)
  /// 10. Plant seeds and pre-grown trees in clusters
  /// 11. Optionally place ant colony starters
  static GridData generate(WorldConfig config) {
    // 1. Heightmap.
    final heightmap = TerrainGenerator.generateHeightmap(config);

    // 2. Base terrain layers.
    final data = TerrainGenerator.fillLayers(config, heightmap);

    // 3. Caves.
    FeaturePlacer.carveCaves(data, config, heightmap);

    // 4. Water.
    FeaturePlacer.placeWater(data, config, heightmap);

    // 5. Waterfalls.
    FeaturePlacer.placeWaterfalls(data, config, heightmap);

    // 6. Snow.
    FeaturePlacer.placeSnow(data, config, heightmap);

    // 7. Lava.
    FeaturePlacer.placeLava(data, config, heightmap);

    // 8. Ore deposits.
    FeaturePlacer.placeOre(data, config, heightmap);

    // 9. Surface detail (sand, boulders, grass).
    FeaturePlacer.placeSurfaceDetail(data, config, heightmap);

    // 10. Vegetation & trees.
    FeaturePlacer.placeVegetation(data, config, heightmap);

    // 11. Ant colonies.
    final colonies = FeaturePlacer.placeAntColonies(data, config, heightmap);
    data.colonyPositions.addAll(colonies);

    // 12. Initialize temperatures based on element properties.
    _initializeTemperatures(data, config);

    return data;
  }

  /// Set initial temperatures based on element base temperatures.
  ///
  /// Lava starts hot, ice/snow start cold, everything else neutral.
  /// Also warms stone near lava for a natural heat gradient.
  static void _initializeTemperatures(GridData data, WorldConfig config) {
    for (var y = 0; y < config.height; y++) {
      for (var x = 0; x < config.width; x++) {
        final el = data.get(x, y);
        final baseTemp = elementBaseTemp[el];
        if (baseTemp != 128) {
          data.setTemp(x, y, baseTemp);
          // Warm/cool neighbors for natural gradient.
          for (var dy = -2; dy <= 2; dy++) {
            for (var dx = -2; dx <= 2; dx++) {
              if (dx == 0 && dy == 0) continue;
              final nx = x + dx;
              final ny = y + dy;
              if (!data.inBounds(nx, ny)) continue;
              final dist = dx.abs() + dy.abs();
              final neighborEl = data.get(nx, ny);
              if (neighborEl == El.empty) continue;
              // Blend toward the heat source/sink based on distance.
              final blend = dist <= 1 ? 0.6 : 0.3;
              final currentTemp = data.temperature[data.toIndex(nx, ny)];
              final newTemp = (currentTemp + (baseTemp - currentTemp) * blend).round().clamp(0, 255);
              data.setTemp(nx, ny, newTemp);
            }
          }
        }
      }
    }
  }

  /// Generate a blank world with only a bottom boundary.
  /// No side walls — the world wraps horizontally.
  static GridData generateBlank(int width, int height) {
    final data = GridData.empty(width, height);

    // Bottom boundary — 3 rows of stone (bedrock).
    for (var y = height - 3; y < height; y++) {
      for (var x = 0; x < width; x++) {
        data.set(x, y, El.stone);
      }
    }

    return data;
  }
}
