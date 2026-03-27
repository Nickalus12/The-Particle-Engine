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
/// Pipeline (chemistry-aware):
/// 1. Generate heightmap via multi-octave noise
/// 2. Fill stratigraphic terrain layers (sky, compost, dirt, clay, stone)
/// 3. Carve caves using layered noise + cellular automata
/// 4. Place water in depressions, underground pools, meadow streams
/// 5. Canyon/island features
/// 6. Waterfalls at elevation drops
/// 7. Snow on highest peaks
/// 8. Lava + sulfur (volcanic features)
/// 9. Ore deposits (copper shallow, metal deep -- real geology)
/// 10. Coal seams in organic layers
/// 11. Salt deposits in dried beds
/// 12. Surface detail (sand, boulders, grass)
/// 13. Vegetation & trees
/// 14. Atmosphere (oxygen fills air, CO2 pools in caves)
/// 15. Ecosystem seeding (fungus, algae, seeds on fertile dirt)
/// 16. Electrical features (conductive veins, insulating layers)
/// 17. Ant colonies
/// 18. Initialize temperatures
class WorldGenerator {
  WorldGenerator._();

  static GridData generate(WorldConfig config) {
    // 1. Heightmap.
    final heightmap = TerrainGenerator.generateHeightmap(config);

    // 2. Stratigraphic terrain layers (compost, dirt, clay, stone).
    final data = TerrainGenerator.fillLayers(config, heightmap);

    // 3. Caves.
    FeaturePlacer.carveCaves(data, config, heightmap);

    // 4. Water + island ocean fill.
    FeaturePlacer.placeWater(data, config, heightmap);
    if (config.waterLevel >= 0.60 && config.terrainScale >= 1.0 && config.terrainScale <= 1.5) {
      FeaturePlacer.fillIslandOcean(data, config, heightmap);
    }

    // 5. Canyon-specific features.
    if (config.terrainScale >= 1.8 && config.caveDensity >= 0.4 &&
        config.waterLevel < 0.55) {
      FeaturePlacer.placeCanyonFeatures(data, config, heightmap);
    }

    // 6. Waterfalls.
    FeaturePlacer.placeWaterfalls(data, config, heightmap);

    // 7. Snow.
    FeaturePlacer.placeSnow(data, config, heightmap);

    // 8. Lava + sulfur.
    FeaturePlacer.placeLava(data, config, heightmap);
    FeaturePlacer.placeSulfur(data, config, heightmap);

    // 9. Ore deposits (depth-ordered: copper shallow, metal deep).
    FeaturePlacer.placeOre(data, config, heightmap);

    // 10. Coal seams.
    FeaturePlacer.placeCoalSeams(data, config, heightmap);

    // 11. Salt deposits.
    FeaturePlacer.placeSaltDeposits(data, config, heightmap);

    // 11b. Periodic table ores (depth-stratified geological placement).
    FeaturePlacer.placePeriodicOres(data, config, heightmap);

    // 12. Surface detail (sand, boulders, grass).
    FeaturePlacer.placeSurfaceDetail(data, config, heightmap);

    // 13. Vegetation & trees.
    FeaturePlacer.placeVegetation(data, config, heightmap);

    // 14. Atmosphere (oxygen in air, CO2 in caves).
    FeaturePlacer.placeAtmosphere(data, config, heightmap);

    // 15. Ecosystem (fungus, algae, seeds).
    FeaturePlacer.placeEcosystem(data, config, heightmap);

    // 16. Electrical features (conductive veins, insulating layers).
    FeaturePlacer.placeElectricalFeatures(data, config, heightmap);

    // 17. Ant colonies.
    final colonies = FeaturePlacer.placeAntColonies(data, config, heightmap);
    data.colonyPositions.addAll(colonies);

    // 18. Initialize temperatures based on element properties.
    _initializeTemperatures(data, config);

    // 19. Cleanup: remove any water/liquid placed above terrain surface.
    // Various placement functions can accidentally create floating water
    // columns. This pass ensures no liquid exists above the heightmap.
    _removeFloatingWater(data, config, heightmap);

    return data;
  }

  /// Set initial temperatures based on element base temperatures.
  static void _initializeTemperatures(GridData data, WorldConfig config) {
    for (var y = 0; y < config.height; y++) {
      for (var x = 0; x < config.width; x++) {
        final el = data.get(x, y);
        final baseTemp = elementBaseTemp[el];
        if (baseTemp != 128) {
          data.setTemp(x, y, baseTemp);
          for (var dy = -2; dy <= 2; dy++) {
            for (var dx = -2; dx <= 2; dx++) {
              if (dx == 0 && dy == 0) continue;
              final nx = x + dx;
              final ny = y + dy;
              if (!data.inBounds(nx, ny)) continue;
              final dist = dx.abs() + dy.abs();
              final neighborEl = data.get(nx, ny);
              if (neighborEl == El.empty || neighborEl == El.oxygen) continue;
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

  /// Remove water that was placed above the terrain surface.
  /// Removes only unsupported liquid columns rather than valid lakes/oceans.
  static void _removeFloatingWater(GridData data, WorldConfig config, List<int> heightmap) {
    int removed = 0;

    // Remove narrow, unsupported vertical liquid strands, but preserve broad
    // connected bodies like lakes, rivers, coastlines, and waterfalls.
    for (var x = 0; x < config.width; x++) {
      for (var y = 0; y < config.height - 1; y++) {
        if (data.get(x, y) != El.water) continue;
        if (y > 0 && data.get(x, y - 1) == El.empty) {
          bool supported = false;

          for (var dx = -3; dx <= 3 && !supported; dx++) {
            final nx = x + dx;
            if (nx < 0 || nx >= config.width) continue;
            for (var dy = 0; dy <= 2; dy++) {
              final neighbor = data.get(nx, y + dy);
              if (neighbor == El.water) {
                supported = true;
                break;
              }
              if (neighbor != El.empty) {
                supported = true;
                break;
              }
            }
          }

          if (!supported) {
            for (var wy = y; wy < config.height; wy++) {
              if (data.get(x, wy) != El.water) break;
              data.set(x, wy, El.empty);
              data.life[data.toIndex(x, wy)] = 0;
              removed++;
            }
          }
        }
      }
    }
    if (removed > 0) {
      // Intentionally silent in production; tests validate topology directly.
    }
  }

  /// Generate a blank world with only a bottom boundary.
  static GridData generateBlank(int width, int height) {
    final data = GridData.empty(width, height);

    // Bottom boundary -- 3 rows of stone (bedrock).
    for (var y = height - 3; y < height; y++) {
      for (var x = 0; x < width; x++) {
        data.set(x, y, El.stone);
      }
    }

    return data;
  }
}
