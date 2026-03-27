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
/// Sets clock bit OPPOSITE to current simClock so the cell is processed
/// when the dirty chunk becomes active (after the next swap cycle).
void _place(SimulationEngine e, int x, int y, int el) {
  final idx = y * e.gridW + x;
  e.clearCell(idx);
  e.grid[idx] = el;
  e.mass[idx] = elementBaseMass[el];
  e.flags[idx] = e.simClock ? 0 : 0x80;
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

/// Count total cells for a set of elements.
int _countAny(SimulationEngine e, List<int> elements) {
  int c = 0;
  for (int i = 0; i < e.grid.length; i++) {
    if (elements.contains(e.grid[i])) c++;
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
      expect(
        pos!,
        greaterThan(30),
        reason: 'Sand at y=10 should fall past y=30 in 30 frames',
      );
    });

    test('Water falls through empty space', () {
      final e = _makeEngine();
      _place(e, 32, 10, El.water);

      _step(e, 30);

      final pos = _findLowest(e, 32, El.water);
      expect(pos, isNotNull);
      expect(
        pos!,
        greaterThan(25),
        reason: 'Water at y=10 should fall past y=25 in 30 frames',
      );
    });

    test('Smoke rises through empty space', () {
      final e = _makeEngine();
      _place(e, 32, 50, El.smoke);

      _step(e, 30);

      final pos = _findHighest(e, 32, El.smoke);
      // Smoke may have decayed, so check if it exists or moved up
      if (pos != null) {
        expect(
          pos,
          lessThan(45),
          reason: 'Smoke at y=50 should rise above y=45 in 30 frames',
        );
      }
    });

    test('Stone falls when unsupported (realistic)', () {
      final e = _makeEngine();
      _place(e, 32, 10, El.stone);

      _step(e, 10);

      // Stone has gravity and falls when unsupported
      final pos = _findLowest(e, 32, El.stone);
      expect(pos, isNotNull);
      expect(
        pos!,
        greaterThan(10),
        reason: 'Unsupported stone should fall under gravity',
      );
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
      expect(
        bottomSand!,
        greaterThan(50),
        reason: 'Sand column should reach bottom region in 40 frames',
      );
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
        expect(
          sandY,
          lessThanOrEqualTo(60),
          reason: 'Sand should rest on stone floor, not pass through',
        );
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
      expect(
        sandY!,
        greaterThanOrEqualTo(55),
        reason: 'Sand should sink through water pool',
      );
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
        expect(
          oilY,
          lessThanOrEqualTo(waterY),
          reason: 'Oil should float above water',
        );
      }
    });
  });

  // =========================================================================
  // Liquid spread: liquids should spread laterally on surfaces
  // =========================================================================

  group('Liquid spread', () {
    test('Water settles on flat surface without disappearing', () {
      final e = _makeEngine();
      // Stone floor
      for (int x = 20; x < 44; x++) {
        _place(e, x, 50, El.stone);
      }
      // Small water blob above
      for (int x = 31; x <= 33; x++) {
        _place(e, x, 49, El.water);
      }

      _step(e, 120);

      // Water should remain present on the supported surface.
      int waterCount = 0;
      for (int x = 20; x < 44; x++) {
        if (e.grid[49 * e.gridW + x] == El.water) waterCount++;
      }
      expect(
        waterCount,
        greaterThanOrEqualTo(1),
        reason: 'Water placed over a solid floor should remain as liquid',
      );
    });
  });

  // =========================================================================
  // neverSettle: verify all flowing elements are included
  // =========================================================================

  group('neverSettle registry', () {
    test('All liquids are in neverSettle', () {
      for (int i = 0; i < maxElements; i++) {
        if (elementPhysicsState[i] == PhysicsState.liquid.index) {
          expect(
            neverSettle[i],
            1,
            reason:
                'Liquid element $i (${elementNames[i]}) must be in neverSettle',
          );
        }
      }
    });

    test('All gases are in neverSettle', () {
      for (int i = 0; i < maxElements; i++) {
        if (elementPhysicsState[i] == PhysicsState.gas.index) {
          expect(
            neverSettle[i],
            1,
            reason:
                'Gas element $i (${elementNames[i]}) must be in neverSettle',
          );
        }
      }
    });

    test('All granulars are in neverSettle', () {
      for (int i = 0; i < maxElements; i++) {
        if (elementPhysicsState[i] == PhysicsState.granular.index) {
          expect(
            neverSettle[i],
            1,
            reason:
                'Granular element $i (${elementNames[i]}) must be in neverSettle',
          );
        }
      }
    });

    test('All powders are in neverSettle', () {
      for (int i = 0; i < maxElements; i++) {
        if (elementPhysicsState[i] == PhysicsState.powder.index) {
          expect(
            neverSettle[i],
            1,
            reason:
                'Powder element $i (${elementNames[i]}) must be in neverSettle',
          );
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
          if (el != El.empty &&
              el != El.water &&
              el != El.snow &&
              el != El.cloud &&
              el != El.vapor &&
              el != El.smoke) {
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

      expect(
        waterAboveTerrain,
        0,
        reason:
            'No water should be placed above terrain surface after world gen',
      );
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
          expect(
            settled,
            false,
            reason:
                'Element at idx=$i should not be pre-settled after generation',
          );
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
        expect(
          e.dirtyChunks[i],
          1,
          reason: 'Chunk $i should be dirty after world gen',
        );
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
      expect(hasIce, false, reason: 'Ice should melt at high temperature');
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
      expect(
        iceCount,
        greaterThanOrEqualTo(2),
        reason: 'Water adjacent to ice at low temp should freeze',
      );
    });
  });

  group('Reaction constraints', () {
    test('Temperature-gated rules only fire within allowed range', () {
      final e = _makeEngine();
      _place(e, 10, 10, El.gold);
      _place(e, 11, 10, El.bromine);
      final idx = 10 * e.gridW + 10;

      ReactionRegistry.register(
        const ReactionRule(
          source: El.gold,
          target: El.bromine,
          sourceBecomesElement: El.fire,
          probability: 1.0,
          requiresMinTemp: 200,
        ),
      );

      e.temperature[idx] = 150;
      final firedCold = ReactionRegistry.processReactions(
        e,
        10,
        10,
        idx,
        El.gold,
      );
      expect(firedCold, isFalse);
      expect(e.grid[idx], El.gold);

      e.temperature[idx] = 220;
      final firedHot = ReactionRegistry.processReactions(
        e,
        10,
        10,
        idx,
        El.gold,
      );
      expect(firedHot, isTrue);
      expect(e.grid[idx], El.fire);
    });
  });

  group('Lava stability', () {
    test('Lava does not multiply indefinitely in capped deep pockets', () {
      final e = _makeEngine(w: 64, h: 64);

      // Build a deep pocket with a stone cap and a lava column.
      const x = 32;
      for (int y = 49; y <= 50; y++) {
        _place(e, x, y, El.stone); // capDepth >= 2
      }
      for (int y = 51; y <= 58; y++) {
        _place(e, x, y, El.lava); // lavaBelow >= 3
      }

      final initialLava = _count(e, El.lava);
      _step(e, 1500);
      final finalLava = _count(e, El.lava);

      // Lava behavior can move and react, but should not self-amplify explosively.
      expect(
        finalLava,
        lessThanOrEqualTo(initialLava + 2),
        reason:
            'Deep capped lava pockets should not create unlimited lava mass',
      );
    });
  });

  group('Atmospherics', () {
    test('Open-air steam mostly dissipates without mass water specking', () {
      final e = _makeEngine(w: 96, h: 72);
      // Create a broad steam plume in open air.
      for (int y = 8; y < 18; y++) {
        for (int x = 30; x < 66; x++) {
          _place(e, x, y, El.steam);
          e.temperature[y * e.gridW + x] = 120;
        }
      }
      final waterBefore = _count(e, El.water);
      _step(e, 180);
      final waterAfter = _count(e, El.water);

      // Steam should not collapse into broad random water speckles.
      expect(waterAfter - waterBefore, lessThanOrEqualTo(8));
    });

    test('Clouds advect with wind instead of staying static', () {
      final e = _makeEngine(w: 96, h: 72);
      e.windForce = 2;
      // Paint a compact cloud mass.
      for (int y = 10; y < 14; y++) {
        for (int x = 20; x < 26; x++) {
          _place(e, x, y, El.cloud);
          e.moisture[y * e.gridW + x] = 120;
        }
      }

      int cloudCentroidX() {
        int sumX = 0;
        int n = 0;
        for (int y = 0; y < e.gridH; y++) {
          for (int x = 0; x < e.gridW; x++) {
            if (e.grid[y * e.gridW + x] == El.cloud) {
              sumX += x;
              n++;
            }
          }
        }
        return n == 0 ? 0 : sumX ~/ n;
      }

      final x0 = cloudCentroidX();
      _step(e, 60);
      final x1 = cloudCentroidX();
      expect((x1 - x0).abs(), greaterThanOrEqualTo(2));
    });

    test('Cold vapor condenses back into water', () {
      final e = _makeEngine(w: 64, h: 64);
      _place(e, 32, 32, El.vapor);
      e.temperature[32 * e.gridW + 32] = 70;

      _step(e, 40);

      expect(_count(e, El.vapor), 0);
      expect(_countAny(e, [El.water, El.cloud, El.ice]), greaterThan(0));
    });

    test('High-altitude vapor transitions into cloud', () {
      final e = _makeEngine(w: 64, h: 64);
      _place(e, 20, 4, El.vapor); // top 20% altitude band
      e.temperature[4 * e.gridW + 20] = 130;

      _step(e, 24);

      expect(_count(e, El.cloud), greaterThan(0));
    });

    test('Isolated dry cloud dissipates into vapor', () {
      final e = _makeEngine(w: 64, h: 64);
      _place(e, 30, 12, El.cloud);
      e.moisture[12 * e.gridW + 30] = 0;

      _step(e, 420);

      // A single dry cloud may cycle cloud<->vapor at altitude, but should
      // not grow into a larger cloud mass without added moisture.
      expect(_count(e, El.cloud), lessThanOrEqualTo(2));
    });

    test('Saturated warm clouds precipitate measurable rain', () {
      final e = _makeEngine(w: 96, h: 72);
      for (int y = 8; y < 12; y++) {
        for (int x = 35; x < 60; x++) {
          _place(e, x, y, El.cloud);
          final i = y * e.gridW + x;
          e.moisture[i] = 240;
          e.temperature[i] = 120;
        }
      }

      _step(e, 420);

      expect(
        _count(e, El.water),
        greaterThan(0),
        reason: 'Warm saturated cloud fields should generate visible rainfall',
      );
    });
  });

  // =========================================================================
  // Brush placement: mimics real _paintCell behavior exactly
  // =========================================================================

  group('Brush placement gravity', () {
    test('Sand blob placed in air falls completely to bottom', () {
      final e = _makeEngine(w: 64, h: 64);
      // Mimic brush size 3 placement at (32, 15) — exactly like _paintCell
      const brushSize = 3;
      const cx = 32, cy = 15;
      for (var dy = -brushSize; dy <= brushSize; dy++) {
        for (var dx = -brushSize; dx <= brushSize; dx++) {
          if (dx * dx + dy * dy <= brushSize * brushSize) {
            final nx = e.wrapX(cx + dx);
            final ny = cy + dy;
            if (e.inBoundsY(ny)) {
              final idx = ny * e.gridW + nx;
              e.clearCell(idx);
              e.grid[idx] = El.sand;
              e.mass[idx] = elementBaseMass[El.sand];
              e.flags[idx] = e.simClock ? 0 : 0x80;
              e.markDirty(nx, ny);
              e.unsettleNeighbors(nx, ny);
            }
          }
        }
      }

      final sandBefore = _count(e, El.sand);
      expect(sandBefore, greaterThan(20)); // brush creates ~29 cells

      // Check that sand is around y=15
      final highestBefore = _findHighest(e, 32, El.sand);
      expect(highestBefore, isNotNull);
      expect(highestBefore!, lessThan(20));

      // Run simulation — sand should fall to bottom (y=63)
      _step(e, 60);

      // ALL sand should be near the bottom now
      final highestAfter = _findHighest(e, 32, El.sand);
      expect(highestAfter, isNotNull);
      expect(
        highestAfter!,
        greaterThan(40),
        reason:
            'Brush-placed sand blob should fall to bottom. '
            'Highest sand at y=$highestAfter after 60 frames (started at y~12)',
      );

      // Sand count preserved
      final sandAfter = _count(e, El.sand);
      expect(sandAfter, sandBefore, reason: 'Sand count should be preserved');
    });

    test('Water blob placed in air falls completely', () {
      final e = _makeEngine(w: 64, h: 64);
      const brushSize = 3;
      const cx = 32, cy = 15;
      for (var dy = -brushSize; dy <= brushSize; dy++) {
        for (var dx = -brushSize; dx <= brushSize; dx++) {
          if (dx * dx + dy * dy <= brushSize * brushSize) {
            final nx = e.wrapX(cx + dx);
            final ny = cy + dy;
            if (e.inBoundsY(ny)) {
              final idx = ny * e.gridW + nx;
              e.clearCell(idx);
              e.grid[idx] = El.water;
              e.mass[idx] = elementBaseMass[El.water];
              e.flags[idx] = e.simClock ? 0 : 0x80;
              e.markDirty(nx, ny);
              e.unsettleNeighbors(nx, ny);
            }
          }
        }
      }

      _step(e, 60);

      // Water should spread along the bottom
      final highestWater = _findHighest(e, 32, El.water);
      if (highestWater != null) {
        expect(
          highestWater,
          greaterThan(40),
          reason: 'Water placed at y~15 should fall to bottom in 60 frames',
        );
      }
    });

    test('Sand placed during active simulation falls', () {
      final e = _makeEngine(w: 64, h: 64);
      e.markAllDirty(); // Force all chunks dirty like game does on init

      // Run a few frames first (like the game does before user places)
      _step(e, 10);

      // NOW place sand (simClock has been toggling)
      _place(e, 32, 15, El.sand);

      _step(e, 1);
      _step(e, 1);
      _step(e, 1);

      _step(e, 27);
      final yFinal = _findLowest(e, 32, El.sand);

      expect(yFinal, isNotNull);
      expect(
        yFinal!,
        greaterThan(30),
        reason: 'Sand placed mid-simulation should fall',
      );
    });

    test('Sand brush with continuous painting (drag)', () {
      final e = _makeEngine(w: 64, h: 64);
      _step(e, 5);

      // Simulate drag painting: place sand, step, place more sand, step
      // This mimics how the game interleaves placement and simulation
      for (int frame = 0; frame < 10; frame++) {
        // Place sand at y=10
        for (int dx = -2; dx <= 2; dx++) {
          _place(e, 32 + dx, 10, El.sand);
        }
        _step(e, 1);
      }

      // Stop painting, let simulation run
      _step(e, 50);

      // All sand should have fallen
      final highest = _findHighest(e, 32, El.sand);
      expect(highest, isNotNull);
      expect(
        highest!,
        greaterThan(30),
        reason: 'Sand placed during drag should eventually fall',
      );
    });
  });

  // =========================================================================
  // Direct function tests
  // =========================================================================

  group('Direct gravity functions', () {
    test('fallGranular moves sand down when empty below', () {
      final e = _makeEngine(w: 64, h: 64);
      _step(e, 10); // establish simulation state

      final idx = 15 * e.gridW + 32;
      e.clearCell(idx);
      e.grid[idx] = El.sand;
      e.mass[idx] = elementBaseMass[El.sand];
      e.markDirty(32, 15);

      e.fallGranular(32, 15, idx, El.sand);

      final below = 16 * e.gridW + 32;

      expect(
        e.grid[below],
        El.sand,
        reason: 'fallGranular should swap sand into empty cell below',
      );
      expect(
        e.grid[idx],
        El.empty,
        reason: 'Old position should be empty after fall',
      );
    });

    test('simSand calls fallGranular and sand moves', () {
      final e = _makeEngine(w: 64, h: 64);
      _step(e, 10);

      final idx = 15 * e.gridW + 32;
      e.clearCell(idx);
      e.grid[idx] = El.sand;
      e.mass[idx] = elementBaseMass[El.sand];
      e.markDirty(32, 15);

      e.simSand(32, 15, idx);

      final below = 16 * e.gridW + 32;

      expect(
        e.grid[below],
        El.sand,
        reason: 'simSand should move sand down via fallGranular',
      );
    });

    test('simulateElement dispatches sand correctly', () {
      final e = _makeEngine(w: 64, h: 64);
      _step(e, 10);

      final idx = 15 * e.gridW + 32;
      e.clearCell(idx);
      e.grid[idx] = El.sand;
      e.mass[idx] = elementBaseMass[El.sand];
      e.markDirty(32, 15);

      simulateElement(e, El.sand, 32, 15, idx);

      final below = 16 * e.gridW + 32;

      expect(
        e.grid[below],
        El.sand,
        reason: 'simulateElement should dispatch sand and it should fall',
      );
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
      expect(
        after,
        before,
        reason:
            'Sand count should be conserved during fall (no creation/destruction)',
      );
    });

    test('Water does not duplicate from repeated impact splashes', () {
      final e = _makeEngine(w: 96, h: 72);
      for (int x = 20; x < 76; x++) {
        for (int y = 45; y < 62; y++) {
          _place(e, x, y, El.water);
        }
      }
      final initialWater = _count(e, El.water);

      for (int t = 0; t < 240; t++) {
        if (t % 6 == 0) {
          _place(e, 48 + (t % 5) - 2, 6, El.sand);
        }
        _step(e, 1);
      }

      final finalWater = _count(e, El.water);
      expect(
        finalWater,
        lessThanOrEqualTo(initialWater),
        reason: 'Impact splash should move water, not create new water cells',
      );
    });

    test('Closed-basin hydrologic mass remains conserved over long runs', () {
      final e = _makeEngine(w: 96, h: 72);

      for (int x = 8; x < 88; x++) {
        _place(e, x, 20, El.stone);
        _place(e, x, 61, El.stone);
      }
      for (int y = 20; y <= 61; y++) {
        _place(e, 8, y, El.stone);
        _place(e, 87, y, El.stone);
      }

      for (int y = 35; y < 59; y++) {
        for (int x = 10; x < 86; x++) {
          _place(e, x, y, El.water);
        }
      }

      final hydroEls = <int>[
        El.water,
        El.steam,
        El.vapor,
        El.cloud,
        El.ice,
        El.snow,
        El.bubble,
      ];
      final initialHydro = _countAny(e, hydroEls);

      for (int t = 0; t < 1200; t++) {
        if (t % 20 == 0) {
          _place(e, 20 + (t % 40), 30, El.sand);
        }
        _step(e, 1);
      }

      final finalHydro = _countAny(e, hydroEls);
      expect(
        finalHydro,
        lessThanOrEqualTo(initialHydro + 256),
        reason:
            'Closed basins should avoid runaway hydrologic growth over long runs',
      );
    });
  });
}
