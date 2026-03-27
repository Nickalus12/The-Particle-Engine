import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';

import '../../helpers/simulation_harness.dart';

void main() {
  group('Structural Support Systems', () {
    test('bedrock acts as a full support anchor', () {
      final e = makeEngine(w: 32, h: 32);
      setCell(e, 10, 31, El.bedrock);

      e.updateSupport();

      expect(e.support[idx(e, 10, 31)], 255);
    });

    test('supported solids inherit non-zero support above anchors', () {
      final e = makeEngine(w: 32, h: 32);
      setCell(e, 10, 31, El.bedrock);
      setCell(e, 10, 30, El.stone);

      e.updateSupport();

      expect(e.support[idx(e, 10, 30)], greaterThan(0));
    });

    test('unsupported solids gain downward velocity and vibration', () {
      final e = makeEngine(w: 32, h: 32);
      setCell(e, 12, 12, El.wood);

      e.updateSupport();

      final i = idx(e, 12, 12);
      expect(e.support[i], 0);
      expect(e.velY[i], greaterThan(0));
      expect(e.vibration[i], 80);
      expect(e.vibrationFreq[i], 100);
    });

    test('liquids do not carry structural support', () {
      final e = makeEngine(w: 32, h: 32);
      setCell(e, 14, 14, El.water);

      e.updateSupport();

      expect(e.support[idx(e, 14, 14)], 0);
    });
  });

  group('Stress Accumulation Systems', () {
    test('stress accumulates down a mass column', () {
      final e = makeEngine(w: 32, h: 32);
      setCell(e, 7, 5, El.stone);
      setCell(e, 7, 6, El.stone);
      setCell(e, 7, 7, El.stone);

      e.updateStress();

      final s5 = e.stress[idx(e, 7, 5)];
      final s6 = e.stress[idx(e, 7, 6)];
      final s7 = e.stress[idx(e, 7, 7)];
      expect(s6, greaterThanOrEqualTo(s5));
      expect(s7, greaterThanOrEqualTo(s6));
    });

    test('empty cells reset stress and break accumulation', () {
      final e = makeEngine(w: 32, h: 32);
      setCell(e, 8, 5, El.stone);
      setCell(e, 8, 7, El.stone);

      e.updateStress();

      expect(e.stress[idx(e, 8, 6)], 0);
      expect(e.stress[idx(e, 8, 7)], equals(e.mass[idx(e, 8, 7)]));
    });

    test('stress update respects dirty chunk gating', () {
      final e = makeEngine(w: 32, h: 32);
      setCell(e, 9, 9, El.stone);
      final i = idx(e, 9, 9);
      e.stress[i] = 77;
      e.dirtyChunks.fillRange(0, e.dirtyChunks.length, 0);

      e.updateStress();

      expect(e.stress[i], 77);
    });
  });

  group('Chunk Discovery Systems', () {
    test('connected wood cluster forms an active falling chunk', () {
      final e = makeEngine(w: 32, h: 32);
      setCell(e, 15, 10, El.wood);
      setCell(e, 16, 10, El.wood);
      setCell(e, 15, 11, El.wood);

      e.updateChunks();

      expect(e.activeChunks, isNotEmpty);
      expect(e.chunkMap[idx(e, 15, 10)], greaterThan(0));
      expect(e.chunkMap[idx(e, 16, 10)], equals(e.chunkMap[idx(e, 15, 10)]));
      expect(e.velY[idx(e, 15, 10)], greaterThan(0));
    });

    test('cluster touching anchored dirt is not marked active', () {
      final e = makeEngine(w: 32, h: 32);
      setCell(e, 20, 31, El.dirt);
      setCell(e, 20, 30, El.wood);
      setCell(e, 20, 29, El.wood);
      e.flags[idx(e, 20, 31)] = 0x70;

      e.updateChunks();

      expect(e.activeChunks, isEmpty);
      expect(e.chunkMap[idx(e, 20, 30)], greaterThan(0));
      expect(e.velY[idx(e, 20, 30)], equals(0));
    });
  });
}
