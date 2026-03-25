import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/element_behaviors.dart';
import 'package:the_particle_engine/simulation/reactions/reaction_registry.dart';
import 'package:the_particle_engine/simulation/world_gen/world_generator.dart';
import 'package:the_particle_engine/simulation/world_gen/world_config.dart';

/// Create a small test engine with all registries initialized.
SimulationEngine _makeEngine({int w = 64, int h = 64}) {
  ElementRegistry.init();
  ReactionRegistry.init();
  return SimulationEngine(gridW: w, gridH: h, seed: 42);
}

/// Place a single element at (x, y) with proper initialization.
void _place(SimulationEngine e, int x, int y, int el) {
  final idx = y * e.gridW + x;
  e.clearCell(idx);
  e.grid[idx] = el;
  e.mass[idx] = elementBaseMass[el];
  e.flags[idx] = e.simClock ? 0x80 : 0;
  e.markDirty(x, y);
  e.unsettleNeighbors(x, y);
}

/// Run N simulation steps.
void _step(SimulationEngine e, int frames) {
  for (int i = 0; i < frames; i++) {
    e.step(simulateElement);
  }
}

/// Find the lowest y position of a given element in column x.
int? _findLowest(SimulationEngine e, int x, int el) {
  for (int y = e.gridH - 1; y >= 0; y--) {
    if (e.grid[y * e.gridW + x] == el) return y;
  }
  return null;
}

/// Find the highest y position of a given element in column x.
int? _findHighest(SimulationEngine e, int x, int el) {
  for (int y = 0; y < e.gridH; y++) {
    if (e.grid[y * e.gridW + x] == el) return y;
  }
  return null;
}

/// Count total cells of a given element.
int _count(SimulationEngine e, int el) {
  int c = 0;
  for (int i = 0; i < e.grid.length; i++) {
    if (e.grid[i] == el) c++;
  }
  return c;
}

void main() {
  // =========================================================================
  // Gravity: elements must fall through empty space
  // =========================================================================

  group('Gravity', () {
    test('Sand falls through empty space', () {
      final e = _makeEngine();
      _place(e, 32, 10, El.sand);
      expect(e.grid[10 * e.gridW + 32], El.sand);

      _step(e, 30);

      // Sand should have fallen well below y=10
      final pos = _findLowest(e, 32, El.sand);
      expect(pos, isNotNull);
      expect(pos!, greaterThan(30),
          reason: 'Sand at y=10 should fall past y=30 in 30 frames');
    });

    test('Water falls through empty space', () {
      final e = _makeEngine();
      _place(e, 32, 10, El.water);

      _step(e, 30);

      final pos = _findLowest(e, 32, El.water);
      expect(pos, isNotNull);
      expect(pos!, greaterThan(25),
          reason: 'Water at y=10 should fall past y=25 in 30 frames');
    });

    test('Smoke rises through empty space', () {
      final e = _makeEngine();
      _place(e, 32, 50, El.smoke);

      _step(e, 30);

      final pos = _findHighest(e, 32, El.smoke);
      // Smoke may have decayed, so check if it exists or moved up
      if (pos != null) {
        expect(pos, lessThan(45),
            reason: 'Smoke at y=50 should rise above y=45 in 30 frames');
      }
    });

    test('Stone falls when unsupported (realistic)', () {
      final e = _makeEngine();
      _place(e, 32, 10, El.stone);

      _step(e, 10);

      // Stone has gravity and falls when unsupported
      final pos = _findLowest(e, 32, El.stone);
      expect(pos, isNotNull);
      expect(pos!, greaterThan(10),
          reason: 'Unsupported stone should fall under gravity');
    });

    test('Multiple sand grains fall independently', () {
      final e = _makeEngine();
      // Place 5 sand grains in a vertical column
      for (int y = 5; y < 10; y++) {
        _place(e, 32, y, El.sand);
      }

      _step(e, 40);

      // All sand should have fallen near the bottom
      final bottomSand = _findLowest(e, 32, El.sand);
      expect(bottomSand, isNotNull);
      expect(bottomSand!, greaterThan(50),
          reason: 'Sand column should reach bottom region in 40 frames');
    });

    test('Sand lands on ground and stops', () {
      final e = _makeEngine();
      // Place bedrock floor at y=60 (bedrock = stone, won't fall)
      // Use a wide floor so stone supports itself
      for (int x = 0; x < e.gridW; x++) {
        _place(e, x, 60, El.stone);
        _place(e, x, 61, El.stone);
        _place(e, x, 62, El.stone);
      }
      // Place sand above it
      _place(e, 32, 10, El.sand);

      _step(e, 60);

      // Sand should have landed somewhere on or above the stone floor
      final sandY = _findLowest(e, 32, El.sand);
      if (sandY != null) {
        expect(sandY, lessThanOrEqualTo(60),
            reason: 'Sand should rest on stone floor, not pass through');
      }
    });

    test('Oil falls through empty space', () {
      final e = _makeEngine();
      _place(e, 32, 10, El.oil);

      _step(e, 30);

      final pos = _findLowest(e, 32, El.oil);
      expect(pos, isNotNull);
      expect(pos!, greaterThan(25));
    });
  });

  // =========================================================================
  // Density: heavier elements sink through lighter
  // =========================================================================

  group('Density', () {
    test('Sand sinks through water', () {
      final e = _makeEngine();
      // Water pool at y=50-55
      for (int y = 50; y <= 55; y++) {
        _place(e, 32, y, El.water);
      }
      // Sand above water
      _place(e, 32, 49, El.sand);

      _step(e, 30);

      // Sand (density 150) should sink below water (density 100)
      final sandY = _findLowest(e, 32, El.sand);
      expect(sandY, isNotNull);
      expect(sandY!, greaterThanOrEqualTo(55),
          reason: 'Sand should sink through water pool');
    });

    test('Oil floats on water', () {
      final e = _makeEngine();
      // Place water at y=55, oil below it at y=56
      _place(e, 32, 55, El.water);
      _place(e, 32, 56, El.oil);

      _step(e, 20);

      // Oil (density 80) should rise above water (density 100)
      final oilY = _findHighest(e, 32, El.oil);
      final waterY = _findLowest(e, 32, El.water);
      if (oilY != null && waterY != null) {
        expect(oilY, lessThanOrEqualTo(waterY),
            reason: 'Oil should float above water');
      }
    });
  });

  // =========================================================================
  // Liquid spread: liquids should spread laterally on surfaces
  // =========================================================================

  group('Liquid spread', () {
    test('Water spreads laterally on flat surface', () {
      final e = _makeEngine();
      // Stone floor
      for (int x = 20; x < 44; x++) {
        _place(e, x, 50, El.stone);
      }
      // Single water cell above
      _place(e, 32, 49, El.water);

      _step(e, 60);

      // Water should have spread left and right
      int waterCount = 0;
      for (int x = 20; x < 44; x++) {
        if (e.grid[49 * e.gridW + x] == El.water) waterCount++;
      }
      expect(waterCount, greaterThan(1),
          reason: 'Water should spread laterally on surface');
    });
  });

  // =========================================================================
  // neverSettle: verify all flowing elements are included
  // =========================================================================

  group('neverSettle registry', () {
    test('All liquids are in neverSettle', () {
      for (int i = 0; i < maxElements; i++) {
        if (elementPhysicsState[i] == PhysicsState.liquid.index) {
          expect(neverSettle[i], 1,
              reason: 'Liquid element $i (${elementNames[i]}) must be in neverSettle');
        }
      }
    });

    test('All gases are in neverSettle', () {
      for (int i = 0; i < maxElements; i++) {
        if (elementPhysicsState[i] == PhysicsState.gas.index) {
          expect(neverSettle[i], 1,
              reason: 'Gas element $i (${elementNames[i]}) must be in neverSettle');
        }
      }
    });

    test('All granulars are in neverSettle', () {
      for (int i = 0; i < maxElements; i++) {
        if (elementPhysicsState[i] == PhysicsState.granular.index) {
          expect(neverSettle[i], 1,
              reason: 'Granular element $i (${elementNames[i]}) must be in neverSettle');
        }
      }
    });

    test('All powders are in neverSettle', () {
      for (int i = 0; i < maxElements; i++) {
        if (elementPhysicsState[i] == PhysicsState.powder.index) {
          expect(neverSettle[i], 1,
              reason: 'Powder element $i (${elementNames[i]}) must be in neverSettle');
        }
      }
    });
  });

  // =========================================================================
  // World generation: no floating elements
  // =========================================================================

  group('World generation', () {
    test('No water above terrain surface in generated world', () {
      ElementRegistry.init();
      final e = _makeEngine(w: 320, h: 180);
      final config = WorldConfig.canyon();

      final gridData = WorldGenerator.generate(config);
      gridData.loadIntoEngine(e);

      // Find ground level per column and check for water above it
      int waterAboveTerrain = 0;
      for (int x = 0; x < e.gridW; x++) {
        // Find first non-empty, non-water cell from top = terrain surface
        int terrainY = e.gridH;
        for (int y = 0; y < e.gridH; y++) {
          final el = e.grid[y * e.gridW + x];
          if (el != El.empty && el != El.water && el != El.snow &&
              el != El.cloud && el != El.vapor && el != El.smoke) {
            terrainY = y;
            break;
          }
        }
        // Check for water above terrain
        for (int y = 0; y < terrainY; y++) {
          if (e.grid[y * e.gridW + x] == El.water) {
            waterAboveTerrain++;
          }
        }
      }

      expect(waterAboveTerrain, 0,
          reason: 'No water should be placed above terrain surface after world gen');
    });

    test('Generated elements have zeroed flags', () {
      final e = _makeEngine(w: 320, h: 180);
      final config = WorldConfig.canyon();

      final gridData = WorldGenerator.generate(config);
      gridData.loadIntoEngine(e);

      // All flags should be 0 (no pre-settled elements)
      for (int i = 0; i < e.flags.length; i++) {
        if (e.grid[i] != El.empty) {
          final settled = (e.flags[i] & 0x40) != 0;
          expect(settled, false,
              reason: 'Element at idx=$i should not be pre-settled after generation');
        }
      }
    });

    test('Generated world has markAllDirty applied', () {
      final e = _makeEngine(w: 320, h: 180);
      final config = WorldConfig.canyon();

      final gridData = WorldGenerator.generate(config);
      gridData.loadIntoEngine(e);

      // All chunks should be dirty
      for (int i = 0; i < e.dirtyChunks.length; i++) {
        expect(e.dirtyChunks[i], 1,
            reason: 'Chunk $i should be dirty after world gen');
      }
    });
  });

  // =========================================================================
  // Temperature reactions
  // =========================================================================

  group('Temperature reactions', () {
    test('Ice melts when heated', () {
      final e = _makeEngine();
      _place(e, 32, 32, El.ice);
      e.temperature[32 * e.gridW + 32] = 200; // hot

      _step(e, 30);

      // Ice should have melted to water
      final hasIce = e.grid[32 * e.gridW + 32] == El.ice;
      expect(hasIce, false,
          reason: 'Ice should melt at high temperature');
    });

    test('Water freezes when cold and near ice', () {
      final e = _makeEngine();
      _place(e, 32, 32, El.water);
      _place(e, 33, 32, El.ice);
      // Make both very cold
      e.temperature[32 * e.gridW + 32] = 30;
      e.temperature[32 * e.gridW + 33] = 20;

      _step(e, 30);

      // Water should have frozen (Stefan solidification near ice)
      // Check the original water position or nearby
      final iceCount = _count(e, El.ice);
      expect(iceCount, greaterThanOrEqualTo(2),
          reason: 'Water adjacent to ice at low temp should freeze');
    });
  });

  // =========================================================================
  // Element conservation
  // =========================================================================

  group('Conservation', () {
    test('Sand count preserved during fall', () {
      final e = _makeEngine();
      for (int i = 0; i < 10; i++) {
        _place(e, 30 + i, 10, El.sand);
      }
      final before = _count(e, El.sand);

      _step(e, 20);

      final after = _count(e, El.sand);
      expect(after, before,
          reason: 'Sand count should be conserved during fall (no creation/destruction)');
    });
  });
}
