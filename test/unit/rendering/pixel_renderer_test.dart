import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/pixel_renderer.dart';
import 'package:the_particle_engine/simulation/reactions/reaction_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

SimulationEngine _makeEngine({int w = 32, int h = 32}) {
  ElementRegistry.init();
  ReactionRegistry.init();
  return SimulationEngine(gridW: w, gridH: h, seed: 2026);
}

int _idx(SimulationEngine e, int x, int y) => y * e.gridW + x;

int _hash(int x, int y) =>
    (((x * 374761393 + y * 668265263) * 1274126177) & 0x7FFFFFFF);

void _setCell(SimulationEngine e, int x, int y, int el) {
  final i = _idx(e, x, y);
  e.clearCell(i);
  e.grid[i] = el;
  e.mass[i] = elementBaseMass[el];
  e.flags[i] = e.simClock ? 0 : 0x80;
  e.markDirty(x, y);
}

List<int> _rgba(PixelRenderer r, SimulationEngine e, int x, int y) {
  final i4 = _idx(e, x, y) * 4;
  return [r.pixels[i4], r.pixels[i4 + 1], r.pixels[i4 + 2], r.pixels[i4 + 3]];
}

void main() {
  group('PixelRenderer Pipeline', () {
    test('init allocates pixel buffer for full grid', () {
      final e = _makeEngine();
      final r = PixelRenderer(e);

      r.init();

      expect(r.pixels.length, e.gridW * e.gridH * 4);
    });

    test('render writes visible sky pixels in empty world', () {
      final e = _makeEngine();
      final r = PixelRenderer(e)..init();

      r.renderPixels();

      final px = _rgba(r, e, 10, 10);
      expect(px[3], 255);
      expect(px[2], greaterThan(px[0]));
    });

    test('surface water is semi-transparent and deep water is denser', () {
      final e = _makeEngine();
      final r = PixelRenderer(e)..init();
      for (int y = 8; y <= 18; y++) {
        _setCell(e, 12, y, El.water);
      }

      r.renderPixels();

      final top = _rgba(r, e, 12, 8);
      final deep = _rgba(r, e, 12, 14);
      expect(top[3], lessThan(255));
      expect(deep[3], greaterThan(top[3]));
    });

    test('underground surface water is darker than open-sky surface water', () {
      final e = _makeEngine();
      final r = PixelRenderer(e)..init();

      for (int y = 0; y < 5; y++) {
        _setCell(e, 20, y, El.stone);
        final i = _idx(e, 20, y);
        e.cellAge[i] = 32;
        e.support[i] = 64;
      }
      _setCell(e, 20, 10, El.water);
      _setCell(e, 5, 10, El.water);

      r.renderPixels();

      final underground = _rgba(r, e, 20, 10);
      final openSky = _rgba(r, e, 5, 10);
      expect(underground[1], lessThan(openSky[1]));
      expect(underground[2], lessThan(openSky[2]));
    });

    test('floating sand does not turn the air beneath it into cave shading', () {
      final e = _makeEngine();
      final r = PixelRenderer(e)..init();

      for (int y = 4; y < 11; y++) {
        _setCell(e, 10, y, El.sand);
      }

      r.renderPixels();

      final underFloatingSand = _rgba(r, e, 10, 15);
      final openSky = _rgba(r, e, 20, 15);
      expect(underFloatingSand, openSky);
    });

    test(
      'freshly painted solid columns do not darken the air beneath them',
      () {
        final e = _makeEngine();
        final r = PixelRenderer(e)..init();

        for (int y = 4; y < 11; y++) {
          _setCell(e, 10, y, El.stone);
        }

        r.renderPixels();

        final underFreshStone = _rgba(r, e, 10, 15);
        final openSky = _rgba(r, e, 20, 15);
        expect(underFreshStone, openSky);
      },
    );

    test('settled solid terrain still shades underground air correctly', () {
      final e = _makeEngine();
      final r = PixelRenderer(e)..init();

      for (int y = 4; y < 11; y++) {
        _setCell(e, 10, y, El.stone);
        final i = _idx(e, 10, y);
        e.cellAge[i] = 32;
        e.support[i] = 64;
      }

      r.renderPixels();

      final underground = _rgba(r, e, 10, 15);
      final openSky = _rgba(r, e, 20, 15);
      expect(underground[0], lessThan(openSky[0]));
      expect(underground[1], lessThan(openSky[1]));
      expect(underground[2], lessThan(openSky[2]));
    });

    test('cloud alpha scales up with local cloud density life value', () {
      final e = _makeEngine();
      final r = PixelRenderer(e)..init();
      _setCell(e, 16, 12, El.cloud);
      final i = _idx(e, 16, 12);

      e.life[i] = 0;
      r.renderPixels();
      final sparseAlpha = _rgba(r, e, 16, 12)[3];

      e.life[i] = 8;
      e.markDirty(16, 12);
      r.renderPixels();
      final denseAlpha = _rgba(r, e, 16, 12)[3];

      expect(denseAlpha, greaterThan(sparseAlpha));
    });

    test(
      'vapor and steam stay visually soft (low alpha, no white-dot blasts)',
      () {
        final e = _makeEngine();
        final r = PixelRenderer(e)..init();
        _setCell(e, 10, 10, El.vapor);
        _setCell(e, 11, 10, El.steam);

        r.renderPixels();

        final vapor = _rgba(r, e, 10, 10);
        final steam = _rgba(r, e, 11, 10);
        expect(vapor[3], inInclusiveRange(7, 20));
        expect(steam[3], inInclusiveRange(8, 50));
        expect(steam[0], lessThan(230));
      expect(steam[1], lessThan(230));
      expect(steam[2], lessThan(245));
    },
    );

    test('freshly painted sand suppresses bright sparkle highlights', () {
      final e = _makeEngine();
      final r = PixelRenderer(e)..init();
      int targetX = 0;
      int targetY = 0;
      bool found = false;
      for (int y = 0; y < e.gridH && !found; y++) {
        for (int x = 0; x < e.gridW; x++) {
          final sandHash = _hash(x * 31, y * 47);
          if (sandHash % 6 == 0 && sandHash % 80 < 2) {
            targetX = x;
            targetY = y;
            found = true;
            break;
          }
        }
      }

      expect(found, isTrue);
      _setCell(e, targetX, targetY, El.sand);
      final i = _idx(e, targetX, targetY);

      e.cellAge[i] = 0;
      r.renderPixels();
      final fresh = _rgba(r, e, targetX, targetY);

      e.cellAge[i] = 32;
      e.frameCount = 0;
      r.renderPixels();
      final settled = _rgba(r, e, targetX, targetY);

      expect(fresh[0], lessThanOrEqualTo(settled[0]));
      expect(fresh[1], lessThanOrEqualTo(settled[1]));
      expect(fresh[2], lessThanOrEqualTo(settled[2]));
    });

    test('flowing water is brighter than still water due to flow jitter', () {
      final e = _makeEngine();
      final r = PixelRenderer(e)..init();
      _setCell(e, 14, 12, El.water);
      _setCell(e, 14, 11, El.water);
      _setCell(e, 14, 13, El.water);
      final i = _idx(e, 14, 12);

      e.velX[i] = 0;
      e.velY[i] = 0;
      r.renderPixels();
      final still = _rgba(r, e, 14, 12);

      e.velX[i] = 1;
      e.velY[i] = 1;
      e.markDirty(14, 12);
      r.renderPixels();
      final flowing = _rgba(r, e, 14, 12);

      expect(flowing[2], greaterThanOrEqualTo(still[2]));
    });

    test('hydrodynamics v2 turbulence increases water highlight intensity', () {
      final e = _makeEngine();
      final r = PixelRenderer(e)..init();
      _setCell(e, 15, 10, El.water);
      _setCell(e, 15, 11, El.water);
      _setCell(e, 15, 12, El.water);
      final i = _idx(e, 15, 11);

      e.hydroTurbulenceV2[i] = 0;
      r.renderPixels();
      final calm = _rgba(r, e, 15, 11);

      e.hydroTurbulenceV2[i] = 220;
      e.markDirty(15, 11);
      r.renderPixels();
      final turbulent = _rgba(r, e, 15, 11);

      expect(turbulent[2], greaterThanOrEqualTo(calm[2]));
    });

    test('night render can run without pre-generated stars', () {
      final e = _makeEngine();
      final r = PixelRenderer(e)..init();
      e.isNight = true;
      r.dayNightT = 1.0;

      expect(r.renderPixels, returnsNormally);
    });
  });

  group('MicroParticles', () {
    test('spawnParticle enforces hard cap', () {
      final e = _makeEngine();
      final r = PixelRenderer(e)..init();

      for (int i = 0; i < 240; i++) {
        r.spawnParticle(i, 10, 200, 200, 255, 5);
      }

      expect(r.microParticles.length, 120);
    });

    test('tickMicroParticles removes expired particles', () {
      final e = _makeEngine();
      final r = PixelRenderer(e)..init();
      r.spawnParticle(10, 10, 255, 255, 255, 1);
      r.spawnParticle(11, 10, 255, 255, 255, 3);

      r.tickMicroParticles();

      expect(r.microParticles.length, 1);
      expect(r.microParticles.first[5], 2);
    });

    test('reaction flash queue is consumed into particles', () {
      final e = _makeEngine();
      final r = PixelRenderer(e)..init();
      e.reactionFlashes.add(Int32List.fromList([8, 8, 255, 120, 60, 10]));

      r.tickMicroParticles();

      expect(e.reactionFlashes, isEmpty);
      expect(r.microParticles.length, greaterThan(0));
    });

    test('recent explosions are consumed and converted into particles', () {
      final e = _makeEngine();
      final r = PixelRenderer(e)..init();
      e.recentExplosions.add(const Explosion(12, 12, 4));

      r.tickMicroParticles();

      expect(e.recentExplosions, isEmpty);
      expect(r.microParticles.length, greaterThanOrEqualTo(6));
    });

    test('micro particles brighten pixels on top of base render', () {
      final e = _makeEngine();
      final r = PixelRenderer(e)..init();
      r.renderPixels();
      final before = _rgba(r, e, 9, 9);

      r.spawnParticle(9, 9, 120, 100, 80, 5);
      r.renderPixels();
      final after = _rgba(r, e, 9, 9);

      expect(after[0], greaterThanOrEqualTo(before[0]));
      expect(after[1], greaterThanOrEqualTo(before[1]));
      expect(after[2], greaterThanOrEqualTo(before[2]));
    });
  });
}
