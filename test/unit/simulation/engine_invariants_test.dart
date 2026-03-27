import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/element_behaviors.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/reactions/reaction_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

SimulationEngine _makeEngine({int w = 32, int h = 32}) {
  ElementRegistry.init();
  ReactionRegistry.init();
  return SimulationEngine(gridW: w, gridH: h, seed: 1337);
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
  group('Coordinates', () {
    test('wrapX wraps negatives and overflow', () {
      final e = _makeEngine(w: 32, h: 16);
      expect(e.wrapX(-1), 31);
      expect(e.wrapX(-33), 31);
      expect(e.wrapX(32), 0);
      expect(e.wrapX(65), 1);
    });

    test('inBoundsY is true only for valid rows', () {
      final e = _makeEngine(w: 16, h: 12);
      expect(e.inBoundsY(-1), isFalse);
      expect(e.inBoundsY(0), isTrue);
      expect(e.inBoundsY(11), isTrue);
      expect(e.inBoundsY(12), isFalse);
    });
  });

  group('Dirty Chunks', () {
    test('markAllDirty sets current and next dirty arrays', () {
      final e = _makeEngine(w: 48, h: 32);
      e.dirtyChunks.fillRange(0, e.dirtyChunks.length, 0);
      e.nextDirtyChunks.fillRange(0, e.nextDirtyChunks.length, 0);

      e.markAllDirty();

      for (int i = 0; i < e.dirtyChunks.length; i++) {
        expect(e.dirtyChunks[i], 1);
        expect(e.nextDirtyChunks[i], 1);
      }
    });

    test('markDirty wraps chunk neighbors horizontally at x=0', () {
      final e = _makeEngine(w: 32, h: 32); // 2x2 chunks
      e.nextDirtyChunks.fillRange(0, e.nextDirtyChunks.length, 0);

      e.markDirty(0, 8);

      // Own chunk (0,0) and wrapped left neighbor (1,0) are dirty.
      expect(e.nextDirtyChunks[0], 1);
      expect(e.nextDirtyChunks[1], 1);
    });
  });

  group('Pressure', () {
    test('water column pressure increases with depth', () {
      final e = _makeEngine(w: 16, h: 16);
      for (int y = 5; y <= 9; y++) {
        _place(e, 8, y, El.water);
      }

      e.markAllDirty();
      e.updatePressure();

      expect(e.pressure[5 * e.gridW + 8], 1);
      expect(e.pressure[6 * e.gridW + 8], 2);
      expect(e.pressure[7 * e.gridW + 8], 3);
      expect(e.pressure[8 * e.gridW + 8], 4);
      expect(e.pressure[9 * e.gridW + 8], 5);
    });

    test('gas pressure remains bounded by nearby liquid pressure', () {
      final e = _makeEngine(w: 16, h: 16);
      _place(e, 8, 4, El.water);
      _place(e, 8, 5, El.water);
      _place(e, 8, 6, El.steam);

      e.markAllDirty();
      e.updatePressure();

      final gasP = e.pressure[6 * e.gridW + 8];
      final liquidP = e.pressure[5 * e.gridW + 8];
      expect(gasP, inInclusiveRange(0, liquidP));
    });

    test('solid cells have zero pressure', () {
      final e = _makeEngine(w: 16, h: 16);
      _place(e, 8, 8, El.stone);

      e.markAllDirty();
      e.updatePressure();

      expect(e.pressure[8 * e.gridW + 8], 0);
    });
  });

  group('Swap', () {
    test('swap exchanges cell state and marks both processed', () {
      final e = _makeEngine(w: 16, h: 16);
      final a = 5 * e.gridW + 5;
      final b = 5 * e.gridW + 6;

      e.grid[a] = El.water;
      e.life[a] = 101;
      e.velX[a] = 2;
      e.temperature[a] = 130;
      e.mass[a] = 99;

      e.grid[b] = El.sand;
      e.life[b] = 7;
      e.velX[b] = -1;
      e.temperature[b] = 180;
      e.mass[b] = 150;

      e.simClock = true;
      e.swap(a, b);

      expect(e.grid[a], El.sand);
      expect(e.grid[b], El.water);
      expect(e.life[a], 7);
      expect(e.life[b], 101);
      expect(e.velX[a], -1);
      expect(e.velX[b], 2);
      expect(e.temperature[a], 180);
      expect(e.temperature[b], 130);
      expect(e.mass[a], 150);
      expect(e.mass[b], 99);
      expect(e.flags[a] & 0x80, 0x80);
      expect(e.flags[b] & 0x80, 0x80);
    });
  });

  group('Snapshot', () {
    test('capture and restore roundtrip preserves key fields', () {
      final e = _makeEngine(w: 24, h: 20);
      _place(e, 4, 4, El.water);
      _place(e, 5, 4, El.sand);
      final i = 4 * e.gridW + 4;
      e.life[i] = 111;
      e.velX[i] = 3;
      e.temperature[i] = 170;
      e.pressure[i] = 9;
      e.gravityDir = -1;
      e.windForce = 2;
      e.isNight = true;
      e.frameCount = 77;

      final snap = e.captureSnapshot();
      final restored = _makeEngine(w: 8, h: 8); // force resize path
      restored.restoreSnapshot(snap);

      expect(restored.gridW, 24);
      expect(restored.gridH, 20);
      expect(restored.grid[i], El.water);
      expect(restored.grid[4 * restored.gridW + 5], El.sand);
      expect(restored.life[i], 111);
      expect(restored.velX[i], 3);
      expect(restored.temperature[i], 170);
      expect(restored.pressure[i], 9);
      expect(restored.gravityDir, -1);
      expect(restored.windForce, 2);
      expect(restored.isNight, isTrue);
      expect(restored.frameCount, 77);
    });

    test('restore falls back safely when optional arrays are absent', () {
      final e = _makeEngine(w: 16, h: 16);
      final snap = <String, dynamic>{
        'gridW': 16,
        'gridH': 16,
        'grid': e.grid,
        'life': e.life,
      };

      expect(() => e.restoreSnapshot(snap), returnsNormally);
      expect(e.temperature[0], 128);
      expect(e.pressure[0], 0);
      expect(e.oxidation[0], 128);
      expect(e.pH[0], 128);
    });
  });

  group('Lifecycle', () {
    test('clear resets world arrays and marks chunks dirty', () {
      final e = _makeEngine(w: 16, h: 16);
      _place(e, 2, 2, El.water);
      e.temperature[2 * e.gridW + 2] = 220;
      e.life[2 * e.gridW + 2] = 77;
      e.dirtyChunks.fillRange(0, e.dirtyChunks.length, 0);
      e.nextDirtyChunks.fillRange(0, e.nextDirtyChunks.length, 0);

      e.clear();

      expect(e.grid[2 * e.gridW + 2], El.empty);
      expect(e.temperature[2 * e.gridW + 2], 128);
      expect(e.life[2 * e.gridW + 2], 0);
      for (int i = 0; i < e.dirtyChunks.length; i++) {
        expect(e.dirtyChunks[i], 1);
        expect(e.nextDirtyChunks[i], 1);
      }
    });
  });

  group('Step', () {
    test('step toggles simClock and increments frameCount', () {
      final e = _makeEngine(w: 16, h: 16);
      final initialClock = e.simClock;
      final initialFrame = e.frameCount;

      e.step(simulateElement);
      expect(e.simClock, isNot(initialClock));
      expect(e.frameCount, initialFrame + 1);

      e.step(simulateElement);
      expect(e.simClock, initialClock);
      expect(e.frameCount, initialFrame + 2);
    });

    test('step advances a simple water fall scenario', () {
      final e = _makeEngine(w: 24, h: 24);
      _place(e, 12, 4, El.water);

      for (int i = 0; i < 20; i++) {
        e.step(simulateElement);
      }

      bool foundLower = false;
      for (int y = 8; y < e.gridH; y++) {
        if (e.grid[y * e.gridW + 12] == El.water) {
          foundLower = true;
          break;
        }
      }
      expect(foundLower, isTrue);
    });
  });

  group('Neighbors', () {
    test('unsettleNeighbors clears settled bits around a change', () {
      final e = _makeEngine(w: 16, h: 16);
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          final x = 8 + dx;
          final y = 8 + dy;
          final idx = y * e.gridW + x;
          e.grid[idx] = El.stone;
          e.flags[idx] = 0x40; // settled
        }
      }

      e.unsettleNeighbors(8, 8);

      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final x = 8 + dx;
          final y = 8 + dy;
          final idx = y * e.gridW + x;
          expect(e.flags[idx] & 0x40, 0);
        }
      }
    });
  });
}
