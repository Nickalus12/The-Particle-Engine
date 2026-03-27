import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/reactions/reaction_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

SimulationEngine _makeEngine({int w = 24, int h = 24}) {
  ElementRegistry.init();
  ReactionRegistry.init();
  return SimulationEngine(gridW: w, gridH: h, seed: 2026);
}

void _place(SimulationEngine e, int x, int y, int el) {
  final idx = y * e.gridW + x;
  e.clearCell(idx);
  e.grid[idx] = el;
  e.mass[idx] = elementBaseMass[el];
  e.flags[idx] = e.simClock ? 0 : 0x80;
  e.markDirty(x, y);
  e.unsettleNeighbors(x, y);
}

void main() {
  group('Cell Helpers', () {
    test('clearCell resets all key cell state fields', () {
      final e = _makeEngine();
      final idx = 5 * e.gridW + 5;
      e.grid[idx] = El.water;
      e.life[idx] = 123;
      e.velX[idx] = 7;
      e.velY[idx] = -3;
      e.temperature[idx] = 210;
      e.charge[idx] = 30;
      e.oxidation[idx] = 250;
      e.moisture[idx] = 180;
      e.pressure[idx] = 77;
      e.support[idx] = 91;
      e.voltage[idx] = 50;
      e.sparkTimer[idx] = 3;
      e.pH[idx] = 60;
      e.dissolvedType[idx] = El.salt;
      e.concentration[idx] = 220;
      e.mass[idx] = 120;
      e.momentum[idx] = 15;
      e.stress[idx] = 99;
      e.vibration[idx] = 44;
      e.vibrationFreq[idx] = 55;
      e.cellAge[idx] = 88;

      e.clearCell(idx);

      expect(e.grid[idx], El.empty);
      expect(e.life[idx], 0);
      expect(e.velX[idx], 0);
      expect(e.velY[idx], 0);
      expect(e.temperature[idx], 128);
      expect(e.charge[idx], 0);
      expect(e.oxidation[idx], 128);
      expect(e.moisture[idx], 0);
      expect(e.pressure[idx], 0);
      expect(e.support[idx], 0);
      expect(e.voltage[idx], 0);
      expect(e.sparkTimer[idx], 0);
      expect(e.pH[idx], 128);
      expect(e.dissolvedType[idx], 0);
      expect(e.concentration[idx], 0);
      expect(e.mass[idx], 0);
      expect(e.momentum[idx], 0);
      expect(e.stress[idx], 0);
      expect(e.vibration[idx], 0);
      expect(e.vibrationFreq[idx], 0);
      expect(e.cellAge[idx], 0);
    });
  });

  group('Adjacency', () {
    test('checkAdjacent detects horizontal wrap neighbors', () {
      final e = _makeEngine(w: 12, h: 12);
      _place(e, 0, 6, El.water);
      _place(e, 11, 6, El.fire); // wrapped left neighbor of x=0

      expect(e.checkAdjacent(0, 6, El.fire), isTrue);
    });

    test('checkAdjacentAny2 and Any3 detect target sets', () {
      final e = _makeEngine();
      _place(e, 10, 10, El.water);
      _place(e, 11, 10, El.smoke);

      expect(e.checkAdjacentAny2(10, 10, El.fire, El.smoke), isTrue);
      expect(e.checkAdjacentAny3(10, 10, El.fire, El.ice, El.smoke), isTrue);
      expect(e.checkAdjacentAny2(10, 10, El.fire, El.ice), isFalse);
    });

    test('readNeighbors returns expected order', () {
      final e = _makeEngine(w: 10, h: 10);
      final x = 5, y = 5;
      _place(e, 4, 4, El.stone); // NW
      _place(e, 5, 4, El.sand); // N
      _place(e, 6, 4, El.water); // NE
      _place(e, 4, 5, El.fire); // W
      _place(e, 6, 5, El.smoke); // E
      _place(e, 4, 6, El.ice); // SW
      _place(e, 5, 6, El.oil); // S
      _place(e, 6, 6, El.mud); // SE

      final out = Uint8List(8);
      e.readNeighbors(x, y, out);

      expect(out[0], El.stone);
      expect(out[1], El.sand);
      expect(out[2], El.water);
      expect(out[3], El.fire);
      expect(out[4], El.smoke);
      expect(out[5], El.ice);
      expect(out[6], El.oil);
      expect(out[7], El.mud);
    });

    test('checkAdjacentAnyOf uses lookup table correctly', () {
      final e = _makeEngine();
      _place(e, 8, 8, El.water);
      _place(e, 9, 8, El.fire);

      final mask = Uint8List(maxElements);
      mask[El.fire] = 1;
      mask[El.lava] = 1;

      expect(e.checkAdjacentAnyOf(8, 8, mask), isTrue);
      mask[El.fire] = 0;
      expect(e.checkAdjacentAnyOf(8, 8, mask), isFalse);
    });

    test('removeOneAdjacent removes at most one matching cell', () {
      final e = _makeEngine();
      _place(e, 10, 10, El.water);
      _place(e, 9, 10, El.oxygen);
      _place(e, 11, 10, El.oxygen);

      e.removeOneAdjacent(10, 10, El.oxygen);

      final left = e.grid[10 * e.gridW + 9] == El.oxygen;
      final right = e.grid[10 * e.gridW + 11] == El.oxygen;
      expect(left || right, isTrue);
      expect(left && right, isFalse);
    });

    test('findAdjacentIndex returns -1 when absent', () {
      final e = _makeEngine();
      _place(e, 8, 8, El.water);
      expect(e.findAdjacentIndex(8, 8, El.fire), -1);
    });

    test('countAdjacent counts all eight neighbors', () {
      final e = _makeEngine();
      final x = 12, y = 12;
      _place(e, x, y, El.water);
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          _place(e, x + dx, y + dy, El.sand);
        }
      }
      expect(e.countAdjacent(x, y, El.sand), 8);
    });
  });

  group('Sensing API', () {
    test('senseCategories ORs nearby element categories', () {
      final e = _makeEngine();
      _place(e, 10, 10, El.water);
      _place(e, 11, 10, El.fire);

      final mask = e.senseCategories(10, 10, 2);
      expect(mask & ElCat.liquid, isNot(0));
      expect(mask & ElCat.danger, isNot(0));
    });

    test('senseDanger detects dangerous element in radius', () {
      final e = _makeEngine();
      _place(e, 5, 5, El.sand);
      _place(e, 7, 5, El.lava);

      expect(e.senseDanger(5, 5, 3), isTrue);
      expect(e.senseDanger(5, 5, 1), isFalse);
    });

    test('countNearby and countNearbyByCategory are consistent', () {
      final e = _makeEngine();
      _place(e, 10, 10, El.water);
      _place(e, 11, 10, El.water);
      _place(e, 9, 10, El.oil);

      expect(e.countNearby(10, 10, 2, El.water), 2);
      expect(
        e.countNearbyByCategory(10, 10, 2, ElCat.liquid),
        greaterThanOrEqualTo(3),
      );
    });

    test('findNearestDirection points to nearest match', () {
      final e = _makeEngine();
      _place(e, 10, 10, El.sand);
      _place(e, 12, 10, El.fire); // to the right

      final dir = e.findNearestDirection(10, 10, 5, ElCat.danger);
      // (dx+1)*3 + (dy+1), with dx=1 dy=0 => 7
      expect(dir, 7);
    });

    test('scanLine wraps horizontally and stops at vertical bounds', () {
      final e = _makeEngine(w: 8, h: 8);
      _place(e, 7, 4, El.fire);
      _place(e, 0, 4, El.water);
      _place(e, 1, 4, El.sand);

      final line = e.scanLine(7, 4, 1, 0, 3);
      expect(line.length, 3);
      expect(line[0], El.water);
      expect(line[1], El.sand);
    });
  });

  group('Physics Helpers', () {
    test('pressureFlowRadius threshold mapping', () {
      final e = _makeEngine();
      e.pressure[0] = 1;
      e.pressure[1] = 6;
      e.pressure[2] = 16;
      expect(e.pressureFlowRadius(0), 1);
      expect(e.pressureFlowRadius(1), 3);
      expect(e.pressureFlowRadius(2), 6);
    });

    test(
      'tryDensityDisplace swaps heavier liquid downward through lighter',
      () {
        final e = _makeEngine();
        _place(e, 10, 10, El.water);
        _place(e, 10, 11, El.oil); // lighter than water
        final idx = 10 * e.gridW + 10;

        final moved = e.tryDensityDisplace(10, 10, idx, El.water);

        expect(moved, isTrue);
        expect(e.grid[11 * e.gridW + 10], El.water);
        expect(e.grid[10 * e.gridW + 10], El.oil);
      },
    );

    test('tryBuoyancy lets lighter gas rise through heavier gas', () {
      final e = _makeEngine();
      _place(e, 10, 10, El.hydrogen);
      _place(e, 10, 9, El.co2);
      final idx = 10 * e.gridW + 10;

      final moved = e.tryBuoyancy(10, 10, idx, El.hydrogen);

      expect(moved, isTrue);
      expect(e.grid[9 * e.gridW + 10], El.hydrogen);
    });

    test('tryConvection swaps hotter same-liquid cell upward', () {
      final e = _makeEngine();
      _place(e, 10, 10, El.water);
      _place(e, 10, 9, El.water);
      final idx = 10 * e.gridW + 10;
      final aboveIdx = 9 * e.gridW + 10;
      e.temperature[idx] = 180;
      e.temperature[aboveIdx] = 130;

      final moved = e.tryConvection(10, 10, idx, El.water);

      expect(moved, isTrue);
      expect(e.temperature[9 * e.gridW + 10], 180);
    });

    test('tryConvection returns false near-neutral temperatures', () {
      final e = _makeEngine();
      _place(e, 10, 10, El.water);
      _place(e, 10, 9, El.water);
      final idx = 10 * e.gridW + 10;
      e.temperature[idx] = 130; // within |temp-128| < 8

      expect(e.tryConvection(10, 10, idx, El.water), isFalse);
    });

    test(
      'checkTemperatureReaction boils water when above boiling threshold',
      () {
        final e = _makeEngine();
        _place(e, 10, 10, El.water);
        final idx = 10 * e.gridW + 10;
        e.temperature[idx] = 220;
        e.pressure[idx] = 0;

        final changed = e.checkTemperatureReaction(10, 10, idx, El.water);
        expect(changed, isTrue);
        expect(e.grid[idx], El.steam);
      },
    );

    test('checkTemperatureReaction freeze path transforms water to ice', () {
      final e = _makeEngine();
      _place(e, 10, 10, El.water);
      final idx = 10 * e.gridW + 10;
      e.temperature[idx] = 20;

      final changed = e.checkTemperatureReaction(10, 10, idx, El.water);
      expect(changed, isTrue);
      expect(e.grid[idx], El.ice);
    });
  });
}
