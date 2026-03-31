import '../element_registry.dart';
import 'feature_placer.dart';
import 'grid_data.dart';
import 'terrain_generator.dart';
import 'world_config.dart';
import 'worldgen_summary.dart';

/// Main entry point for procedural world generation.
class WorldGenerator {
  WorldGenerator._();

  static GridData generate(WorldConfig config) {
    final stages = <WorldGenStageSummary>[];

    final heightmapWatch = Stopwatch()..start();
    final heightmap = TerrainGenerator.generateHeightmap(config);
    heightmapWatch.stop();
    stages.add(
      WorldGenStageSummary(
        stageName: 'heightmap',
        durationMs: heightmapWatch.elapsedMicroseconds / 1000.0,
        writes: 0,
        overwrites: 0,
        validationFailures: 0,
      ),
    );

    final fillLayersWatch = Stopwatch()..start();
    final data = TerrainGenerator.fillLayers(config, heightmap);
    fillLayersWatch.stop();
    stages.add(
      WorldGenStageSummary(
        stageName: 'fill_layers',
        durationMs: fillLayersWatch.elapsedMicroseconds / 1000.0,
        writes: _countNonEmptyCells(data),
        overwrites: 0,
        validationFailures: 0,
      ),
    );

    _runStage(data, config, stages, 'carve_caves', () {
      FeaturePlacer.carveCaves(data, config, heightmap);
    });
    _runStage(data, config, stages, 'place_water', () {
      FeaturePlacer.placeWater(data, config, heightmap);
    });
    if (config.waterLevel >= 0.60 &&
        config.terrainScale >= 1.0 &&
        config.terrainScale <= 1.5) {
      _runStage(data, config, stages, 'fill_island_ocean', () {
        FeaturePlacer.fillIslandOcean(data, config, heightmap);
      });
    }
    if (config.terrainScale >= 1.8 &&
        config.caveDensity >= 0.4 &&
        config.waterLevel < 0.55) {
      _runStage(data, config, stages, 'place_canyon_features', () {
        FeaturePlacer.placeCanyonFeatures(data, config, heightmap);
      });
    }
    _runStage(data, config, stages, 'place_waterfalls', () {
      FeaturePlacer.placeWaterfalls(data, config, heightmap);
    });
    _runStage(data, config, stages, 'place_snow', () {
      FeaturePlacer.placeSnow(data, config, heightmap);
    });
    _runStage(data, config, stages, 'place_lava', () {
      FeaturePlacer.placeLava(data, config, heightmap);
    });
    _runStage(data, config, stages, 'place_sulfur', () {
      FeaturePlacer.placeSulfur(data, config, heightmap);
    });
    _runStage(data, config, stages, 'place_ore', () {
      FeaturePlacer.placeOre(data, config, heightmap);
    });
    _runStage(data, config, stages, 'place_coal_seams', () {
      FeaturePlacer.placeCoalSeams(data, config, heightmap);
    });
    _runStage(data, config, stages, 'place_salt_deposits', () {
      FeaturePlacer.placeSaltDeposits(data, config, heightmap);
    });
    _runStage(data, config, stages, 'place_periodic_ores', () {
      FeaturePlacer.placePeriodicOres(data, config, heightmap);
    });
    _runStage(data, config, stages, 'place_surface_detail', () {
      FeaturePlacer.placeSurfaceDetail(data, config, heightmap);
    });
    _runStage(data, config, stages, 'place_vegetation', () {
      FeaturePlacer.placeVegetation(data, config, heightmap);
    });
    _runStage(data, config, stages, 'place_atmosphere', () {
      FeaturePlacer.placeAtmosphere(data, config, heightmap);
    });
    _runStage(data, config, stages, 'place_ecosystem', () {
      FeaturePlacer.placeEcosystem(data, config, heightmap);
    });
    _runStage(data, config, stages, 'place_electrical_features', () {
      FeaturePlacer.placeElectricalFeatures(data, config, heightmap);
    });
    _runStage(data, config, stages, 'place_ant_colonies', () {
      final colonies = FeaturePlacer.placeAntColonies(data, config, heightmap);
      data.colonyPositions.addAll(colonies);
    });
    _runStage(
      data,
      config,
      stages,
      'initialize_temperatures',
      () => _initializeTemperatures(data, config),
      compareTemperature: true,
    );
    _runStage(data, config, stages, 'remove_floating_water', () {
      _removeFloatingWater(data, config);
    });

    data.worldGenSummary = WorldGenSummary(
      preset: _inferPreset(config),
      heightmap: List<int>.from(heightmap),
      stages: stages,
      topology: _topologySummary(data, config, heightmap),
      validation: _validateWorld(data, config, heightmap),
    );
    return data;
  }

  static void _runStage(
    GridData data,
    WorldConfig config,
    List<WorldGenStageSummary> stages,
    String stageName,
    void Function() action, {
    bool compareTemperature = false,
  }) {
    final beforeGrid = List<int>.from(data.grid);
    final beforeTemp = compareTemperature
        ? List<int>.from(data.temperature)
        : const <int>[];
    final watch = Stopwatch()..start();
    action();
    watch.stop();
    final writes = _countWrites(
      beforeGrid,
      List<int>.from(data.grid),
      beforeTemp,
      compareTemperature ? List<int>.from(data.temperature) : const <int>[],
    );
    final overwrites = _countOverwrites(beforeGrid, List<int>.from(data.grid));
    stages.add(
      WorldGenStageSummary(
        stageName: stageName,
        durationMs: watch.elapsedMicroseconds / 1000.0,
        writes: writes,
        overwrites: overwrites,
        validationFailures: 0,
      ),
    );
  }

  static int _countNonEmptyCells(GridData data) {
    var total = 0;
    for (final cell in data.grid) {
      if (cell != El.empty) {
        total++;
      }
    }
    return total;
  }

  static int _countWrites(
    List<int> beforeGrid,
    List<int> afterGrid,
    List<int> beforeTemp,
    List<int> afterTemp,
  ) {
    var writes = 0;
    for (var i = 0; i < afterGrid.length; i++) {
      final gridChanged = beforeGrid[i] != afterGrid[i];
      final tempChanged =
          beforeTemp.isNotEmpty &&
          afterTemp.isNotEmpty &&
          beforeTemp[i] != afterTemp[i];
      if (gridChanged || tempChanged) {
        writes++;
      }
    }
    return writes;
  }

  static int _countOverwrites(List<int> beforeGrid, List<int> afterGrid) {
    var overwrites = 0;
    for (var i = 0; i < afterGrid.length; i++) {
      if (beforeGrid[i] != El.empty &&
          afterGrid[i] != El.empty &&
          beforeGrid[i] != afterGrid[i]) {
        overwrites++;
      }
    }
    return overwrites;
  }

  static String _inferPreset(WorldConfig config) {
    final target = config.toMap();
    final factories =
        <
          String,
          WorldConfig Function({
            required int seed,
            required int width,
            required int height,
          })
        >{
          'meadow': WorldConfig.meadow,
          'canyon': WorldConfig.canyon,
          'island': WorldConfig.island,
          'underground': WorldConfig.underground,
          'random': WorldConfig.random,
        };
    for (final entry in factories.entries) {
      final candidate = entry.value(
        seed: config.seed,
        width: config.width,
        height: config.height,
      );
      if (candidate.toMap().toString() == target.toString()) {
        return entry.key;
      }
    }
    return 'custom';
  }

  static WorldGenTopologySummary _topologySummary(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    var waterCells = 0;
    var caveAirCells = 0;
    var atmosphereCells = 0;
    var hazardCells = 0;
    for (var y = 0; y < config.height; y++) {
      for (var x = 0; x < config.width; x++) {
        final el = data.get(x, y);
        if (el == El.water) {
          waterCells++;
        }
        if ((el == El.empty || el == El.oxygen) && y > heightmap[x]) {
          caveAirCells++;
        }
        if (el == El.oxygen || el == El.co2) {
          atmosphereCells++;
        }
        if (el == El.lava || el == El.fire || el == El.sulfur) {
          hazardCells++;
        }
      }
    }
    var roughness = 0;
    for (var x = 1; x < heightmap.length; x++) {
      roughness += (heightmap[x] - heightmap[x - 1]).abs();
    }
    final totalCells = config.width * config.height;
    return WorldGenTopologySummary(
      preset: _inferPreset(config),
      waterCoverageRatio: waterCells / totalCells,
      caveAirRatio: caveAirCells / totalCells,
      surfaceRoughness: roughness / (heightmap.length - 1),
      hazardDensity: hazardCells / totalCells,
      atmosphereCoverageRatio: atmosphereCells / totalCells,
      colonyCount: data.colonyPositions.length,
    );
  }

  static WorldGenValidationSummary _validateWorld(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    var floatingLiquids = 0;
    var thermalAnomalies = 0;
    var invalidColonies = 0;
    var atmosphereConflicts = 0;

    for (var x = 0; x < config.width; x++) {
      for (var y = 0; y < config.height; y++) {
        final el = data.get(x, y);
        if (el == El.water && y < heightmap[x] - 2) {
          floatingLiquids++;
        }
        if ((el == El.lava || el == El.fire) &&
            data.temperature[data.toIndex(x, y)] < 170) {
          thermalAnomalies++;
        }
        if ((el == El.oxygen || el == El.co2) &&
            y > heightmap[x] &&
            data.get(x, y) != El.empty) {
          atmosphereConflicts++;
        }
      }
    }

    for (final (x, y) in data.colonyPositions) {
      if (!data.inBounds(x, y) ||
          data.get(x, y) == El.empty ||
          y <= 0 ||
          data.get(x, y - 1) == El.empty) {
        invalidColonies++;
      }
    }

    return WorldGenValidationSummary(
      unsupportedFloatingLiquids: floatingLiquids,
      thermalAnomalies: thermalAnomalies,
      invalidColonyPlacements: invalidColonies,
      atmosphereConflicts: atmosphereConflicts,
    );
  }

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
              final newTemp = (currentTemp + (baseTemp - currentTemp) * blend)
                  .round()
                  .clamp(0, 255);
              data.setTemp(nx, ny, newTemp);
            }
          }
        }
      }
    }
  }

  static void _removeFloatingWater(GridData data, WorldConfig config) {
    for (var x = 0; x < config.width; x++) {
      for (var y = 0; y < config.height - 1; y++) {
        if (data.get(x, y) != El.water) continue;
        if (y > 0 && data.get(x, y - 1) == El.empty) {
          var supported = false;

          for (var dx = -3; dx <= 3 && !supported; dx++) {
            final nx = x + dx;
            if (nx < 0 || nx >= config.width) continue;
            for (var dy = 0; dy <= 2; dy++) {
              final neighbor = data.get(nx, y + dy);
              if (neighbor == El.water || neighbor != El.empty) {
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
            }
          }
        }
      }
    }
  }

  static GridData generateBlank(int width, int height) {
    final data = GridData.empty(width, height);
    for (var y = height - 3; y < height; y++) {
      for (var x = 0; x < width; x++) {
        data.set(x, y, El.stone);
      }
    }
    return data;
  }
}
