import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/reactions/reaction_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

SimulationEngine _makeEngine({int w = 32, int h = 32}) {
  ElementRegistry.init();
  ReactionRegistry.init();
  return SimulationEngine(gridW: w, gridH: h, seed: 1337);
}

int _idx(SimulationEngine e, int x, int y) => y * e.gridW + x;

void _setCell(SimulationEngine e, int x, int y, int el) {
  final i = _idx(e, x, y);
  e.clearCell(i);
  e.grid[i] = el;
  e.mass[i] = elementBaseMass[el];
  e.flags[i] = e.simClock ? 0 : 0x80;
  e.markDirty(x, y);
}

void main() {
  group('UpdateMoisture', () {
    test('water and mud cells become fully saturated', () {
      final e = _makeEngine();
      _setCell(e, 3, 3, El.water);
      _setCell(e, 4, 3, El.mud);
      e.moisture[_idx(e, 3, 3)] = 0;
      e.moisture[_idx(e, 4, 3)] = 0;

      e.updateMoisture();

      expect(e.moisture[_idx(e, 3, 3)], 255);
      expect(e.moisture[_idx(e, 4, 3)], 255);
    });

    test('porous dirt wicks moisture from nearby water', () {
      final e = _makeEngine();
      _setCell(e, 8, 8, El.water);
      _setCell(e, 9, 8, El.dirt);
      final dirt = _idx(e, 9, 8);
      expect(e.moisture[dirt], 0);

      for (int i = 0; i < 6; i++) {
        e.updateMoisture();
      }

      expect(e.moisture[dirt], greaterThan(0));
    });

    test('non-porous cells reset moisture to zero', () {
      final e = _makeEngine();
      _setCell(e, 10, 10, El.metal);
      final i = _idx(e, 10, 10);
      e.moisture[i] = 200;

      e.updateMoisture();

      expect(e.moisture[i], 0);
    });

    test('porous isolated cell slowly dries out', () {
      final e = _makeEngine();
      _setCell(e, 11, 11, El.dirt);
      final i = _idx(e, 11, 11);
      e.moisture[i] = 90;

      e.updateMoisture();

      expect(e.moisture[i], 89);
    });

    test('non-dirty chunks are skipped', () {
      final e = _makeEngine();
      _setCell(e, 12, 12, El.dirt);
      final i = _idx(e, 12, 12);
      e.moisture[i] = 33;
      e.dirtyChunks.fillRange(0, e.dirtyChunks.length, 0);

      e.updateMoisture();

      expect(e.moisture[i], 33);
    });
  });

  group('UpdateWindField', () {
    test('solid cells always get zero wind vectors', () {
      final e = _makeEngine();
      _setCell(e, 5, 5, El.stone);
      e.windForce = 3;

      e.updateWindField();

      final i = _idx(e, 5, 5);
      expect(e.windX2[i], 0);
      expect(e.windY2[i], 0);
    });

    test('positive global wind biases local wind rightward in open air', () {
      final e = _makeEngine();
      e.windForce = 3;
      e.markAllDirty();

      e.updateWindField();

      final i = _idx(e, 20, 10);
      expect(e.grid[i], El.empty);
      expect(e.windX2[i], inInclusiveRange(0, 6));
      expect(e.windY2[i], inInclusiveRange(-2, 2));
    });

    test('negative global wind biases local wind leftward in open air', () {
      final e = _makeEngine();
      e.windForce = -3;
      e.markAllDirty();

      e.updateWindField();

      final i = _idx(e, 21, 10);
      expect(e.grid[i], El.empty);
      expect(e.windX2[i], inInclusiveRange(-6, 0));
      expect(e.windY2[i], inInclusiveRange(-2, 2));
    });

    test('wind update respects dirty chunk gating', () {
      final e = _makeEngine();
      e.windForce = 3;
      final i = _idx(e, 7, 7);
      e.windX2[i] = 99;
      e.windY2[i] = -99;
      e.dirtyChunks.fillRange(0, e.dirtyChunks.length, 0);

      e.updateWindField();

      expect(e.windX2[i], 99);
      expect(e.windY2[i], -99);
    });
  });

  group('Light And Luminance', () {
    test('spark timer emits bright white-blue flash', () {
      final e = _makeEngine();
      _setCell(e, 8, 8, El.copper);
      final i = _idx(e, 8, 8);
      e.sparkTimer[i] = 1;

      e.updateLightEmission();

      expect(e.lightR[i], 200);
      expect(e.lightG[i], 220);
      expect(e.lightB[i], 255);
    });

    test('very hot non-emissive cell glows from incandescence', () {
      final e = _makeEngine();
      _setCell(e, 9, 9, El.stone);
      final i = _idx(e, 9, 9);
      e.temperature[i] = 240;

      e.updateLightEmission();

      expect(e.lightR[i], greaterThan(0));
      expect(e.lightG[i], greaterThan(0));
    });

    test('empty cells have zero emission', () {
      final e = _makeEngine();
      final i = _idx(e, 4, 4);
      e.lightR[i] = 99;
      e.lightG[i] = 88;
      e.lightB[i] = 77;

      e.updateLightEmission();

      expect(e.lightR[i], 0);
      expect(e.lightG[i], 0);
      expect(e.lightB[i], 0);
    });

    test('luminance is stronger near a light emitter', () {
      final e = _makeEngine();
      e.markAllDirty();
      final source = _idx(e, 10, 10);
      e.lightR[source] = 255;
      e.lightG[source] = 255;
      e.lightB[source] = 255;

      e.updateLuminance();

      final near = _idx(e, 11, 10);
      final far = _idx(e, 25, 10);
      expect(e.luminance[near], greaterThan(e.luminance[far]));
    });

    test('surface luminance is higher by day than by night', () {
      final e = _makeEngine();
      e.markAllDirty();
      final i = _idx(e, 12, 12);

      e.isNight = false;
      e.updateLuminance();
      final dayLum = e.luminance[i];

      e.isNight = true;
      e.updateLuminance();
      final nightLum = e.luminance[i];

      expect(dayLum, greaterThan(nightLum));
    });

    test('luminance update respects dirty chunks', () {
      final e = _makeEngine();
      final i = _idx(e, 6, 6);
      e.luminance[i] = 77;
      e.dirtyChunks.fillRange(0, e.dirtyChunks.length, 0);

      e.updateLuminance();

      expect(e.luminance[i], 77);
    });
  });

  group('CellAge', () {
    test('non-empty cells increment and saturate at 255', () {
      final e = _makeEngine();
      _setCell(e, 14, 14, El.sand);
      final i = _idx(e, 14, 14);
      e.cellAge[i] = 254;

      e.updateCellAge();
      expect(e.cellAge[i], 255);

      e.updateCellAge();
      expect(e.cellAge[i], 255);
    });

    test('empty cells are not incremented', () {
      final e = _makeEngine();
      final i = _idx(e, 15, 15);
      e.cellAge[i] = 13;

      e.updateCellAge();

      expect(e.cellAge[i], 13);
    });

    test('cell age respects dirty chunks', () {
      final e = _makeEngine();
      _setCell(e, 16, 16, El.sand);
      final i = _idx(e, 16, 16);
      e.cellAge[i] = 9;
      e.dirtyChunks.fillRange(0, e.dirtyChunks.length, 0);

      e.updateCellAge();

      expect(e.cellAge[i], 9);
    });
  });

  group('Vibration', () {
    test('vibration propagates to solid neighbors and decays at source', () {
      final e = _makeEngine();
      _setCell(e, 10, 10, El.stone);
      _setCell(e, 11, 10, El.stone);
      final source = _idx(e, 10, 10);
      final neighbor = _idx(e, 11, 10);
      e.vibration[source] = 200;
      e.vibrationFreq[source] = 123;

      e.updateVibration();

      expect(e.vibration[source], lessThan(200));
      expect(e.vibration[neighbor], greaterThan(0));
      expect(e.vibrationFreq[neighbor], 123);
    });

    test('vibration in empty cell is cleared', () {
      final e = _makeEngine();
      final i = _idx(e, 18, 18);
      e.vibration[i] = 44;

      e.updateVibration();

      expect(e.vibration[i], 0);
    });
  });
}
