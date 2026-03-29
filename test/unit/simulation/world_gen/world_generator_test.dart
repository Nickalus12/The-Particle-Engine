import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/world_gen/terrain_generator.dart';
import 'package:the_particle_engine/simulation/world_gen/world_config.dart';
import 'package:the_particle_engine/simulation/world_gen/world_generator.dart';

int _countElement(dynamic data, int element) {
  var total = 0;
  for (final cell in data.grid) {
    if (cell == element) total++;
  }
  return total;
}

int _countSurfaceAdjacentWater(dynamic data, List<int> heightmap) {
  var total = 0;
  for (var x = 1; x < data.width - 1; x++) {
    final y = heightmap[x];
    for (var dy = -1; dy <= 3; dy++) {
      if (data.get(x, y + dy) == El.water) {
        total++;
        break;
      }
    }
  }
  return total;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WorldGenerator', () {
    test('same seed produces identical meadow world', () {
      final config = WorldConfig.meadow(seed: 77, width: 180, height: 100);
      final first = WorldGenerator.generate(config);
      final second = WorldGenerator.generate(config);

      expect(first.grid, orderedEquals(second.grid));
      expect(first.temperature, orderedEquals(second.temperature));
      expect(
        first.worldGenSummary?.toMap(),
        equals(second.worldGenSummary?.toMap()),
      );
    });

    test('meadow world generates visible shoreline hydrology', () {
      final config = WorldConfig.meadow(seed: 31, width: 220, height: 120);
      final heightmap = TerrainGenerator.generateHeightmap(config);
      final world = WorldGenerator.generate(config);

      expect(_countElement(world, El.water), greaterThan(250));
      expect(_countElement(world, El.sand), greaterThan(80));
      expect(_countSurfaceAdjacentWater(world, heightmap), greaterThan(18));
    });

    test('island world keeps ocean on both edges with sandy coast', () {
      final config = WorldConfig.island(seed: 9, width: 220, height: 120);
      final world = WorldGenerator.generate(config);

      var leftWater = 0;
      var rightWater = 0;
      for (var y = 40; y < config.height - 8; y++) {
        if (world.get(4, y) == El.water) leftWater++;
        if (world.get(config.width - 5, y) == El.water) rightWater++;
      }

      expect(leftWater, greaterThan(18));
      expect(rightWater, greaterThan(18));
      expect(_countElement(world, El.sand), greaterThan(120));
    });

    test('canyon heightmap forms a lower center trench than edges', () {
      final config = WorldConfig.canyon(seed: 123, width: 240, height: 120);
      final heightmap = TerrainGenerator.generateHeightmap(config);

      final centerStart = config.width ~/ 2 - 20;
      final centerEnd = config.width ~/ 2 + 20;
      final centerAvg =
          heightmap.sublist(centerStart, centerEnd).reduce((a, b) => a + b) /
          (centerEnd - centerStart);
      final edgeAvg =
          [
            ...heightmap.sublist(0, 25),
            ...heightmap.sublist(config.width - 25),
          ].reduce((a, b) => a + b) /
          50;

      expect(centerAvg, greaterThan(edgeAvg + 12));
    });

    test(
      'underground preset creates compressed surface and substantial cave air',
      () {
        final config = WorldConfig.underground(
          seed: 41,
          width: 220,
          height: 120,
        );
        final heightmap = TerrainGenerator.generateHeightmap(config);
        final world = WorldGenerator.generate(config);

        final avgSurface = heightmap.reduce((a, b) => a + b) / heightmap.length;
        var caveAir = 0;
        for (var x = 0; x < config.width; x++) {
          for (var y = heightmap[x] + 6; y < config.height - 10; y++) {
            final cell = world.get(x, y);
            if (cell == El.empty || cell == El.oxygen) caveAir++;
          }
        }

        expect(avgSurface, lessThan(config.height * 0.16));
        expect(caveAir, greaterThan(1800));
      },
    );

    test('random preset remains deterministic for a fixed seed', () {
      final firstConfig = WorldConfig.random(seed: 88, width: 180, height: 100);
      final secondConfig = WorldConfig.random(
        seed: 88,
        width: 180,
        height: 100,
      );

      expect(firstConfig.toMap(), equals(secondConfig.toMap()));
    });

    test('world generation emits staged summary and validation artifacts', () {
      final config = WorldConfig.meadow(seed: 12, width: 180, height: 100);
      final world = WorldGenerator.generate(config);
      final summary = world.worldGenSummary;

      expect(summary, isNotNull);
      expect(summary!.stages, isNotEmpty);
      expect(summary.stages.first.stageName, 'heightmap');
      expect(summary.topology.waterCoverageRatio, greaterThan(0.0));
      expect(summary.validation.totalFailures, greaterThanOrEqualTo(0));
    });
  });
}
