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

    return data;
  }

  /// Generate a blank world with only indestructible stone boundaries.
  static GridData generateBlank(int width, int height) {
    final data = GridData.empty(width, height);

    // Bottom boundary — 5 rows of stone.
    for (var y = height - 5; y < height; y++) {
      for (var x = 0; x < width; x++) {
        data.set(x, y, El.stone);
      }
    }

    // Side walls — 1 column each.
    for (var y = 0; y < height; y++) {
      data.set(0, y, El.stone);
      data.set(width - 1, y, El.stone);
    }

    return data;
  }
}
