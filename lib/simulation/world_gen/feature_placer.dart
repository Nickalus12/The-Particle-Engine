import 'dart:math';
import 'dart:typed_data';

import '../element_registry.dart';
import 'grid_data.dart';
import 'noise.dart';
import 'world_config.dart';

/// Places specific features onto an already-generated base terrain.
///
/// Chemistry-aware placement pipeline:
/// 1. Caves (noise + cellular automata)
/// 2. Water bodies + underground pools
/// 3. Canyon/island features
/// 4. Waterfalls
/// 5. Snow on peaks
/// 6. Lava + sulfur (volcanic features)
/// 7. Ore veins (copper shallow, metal deep -- real geology)
/// 8. Coal seams in organic layers
/// 9. Salt deposits in dried beds
/// 10. Surface detail (sand, boulders, grass)
/// 11. Vegetation + trees
/// 12. Atmosphere (oxygen in air, CO2 in caves)
/// 13. Ecosystem (compost, fungus, algae, seeds)
/// 14. Electrical features (conductive veins, insulating layers)
/// 15. Ant colonies
class FeaturePlacer {
  FeaturePlacer._();

  // --------------------------------------------------------------------------
  // Cave carving
  // --------------------------------------------------------------------------

  static void carveCaves(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    if (config.caveDensity <= 0) return;

    final caveNoise = SimplexNoise(config.seed + 1000);
    final wormNoise = SimplexNoise(config.seed + 1100);

    final threshold = 0.55 - config.caveDensity * 0.27;

    for (var y = 0; y < config.height - 5; y++) {
      for (var x = 0; x < config.width; x++) {
        if (data.get(x, y) != El.stone) continue;
        if (y < heightmap[x] + 6) continue;

        final n1 = caveNoise.octaveNoise2D(
          x / (config.width * 0.12),
          y / (config.height * 0.12),
          octaves: 3,
          persistence: 0.45,
          lacunarity: 2.2,
        );

        final n2 = wormNoise.octaveNoise2D(
          x / (config.width * 0.06),
          y / (config.height * 0.06),
          octaves: 2,
          persistence: 0.4,
        );

        final isWorm = n2.abs() < 0.04 * config.caveDensity;
        final isCave = n1 > threshold;

        final depthFactor = ((y - heightmap[x]) / config.height).clamp(0.0, 1.0);
        final depthBonus = depthFactor * 0.05;

        if (isCave || (isWorm && depthFactor > 0.15)) {
          final adjacentEmpty = _countAdjacentEmpty(data, x, y);
          if (adjacentEmpty < 5 || (n1 > threshold + depthBonus + 0.08)) {
            data.set(x, y, El.empty);
          }
        }
      }
    }

    _carveBubbleCaverns(data, config, heightmap);

    for (var pass = 0; pass < 3; pass++) {
      _smoothCaves(data, config, heightmap);
    }

    if (config.caveDensity >= 0.6 && config.vegetation <= 0.1) {
      _carveUndergroundCaverns(data, config, heightmap);
    }
  }

  static void _carveBubbleCaverns(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    if (config.caveDensity < 0.1) return;

    final rng = Random(config.seed + 1150);
    final bubbleNoise = SimplexNoise(config.seed + 1160);
    final count = (2 + config.caveDensity * 5).round();

    for (var i = 0; i < count; i++) {
      final cx = (config.width * 0.1 + rng.nextDouble() * config.width * 0.8).round();
      final surfY = heightmap[cx.clamp(0, config.width - 1)];
      final minY = surfY + 10;
      final maxY = config.height - 10;
      if (minY >= maxY) continue;
      final cy = minY + rng.nextInt(maxY - minY);

      final rx = 4 + rng.nextInt(6);
      final ry = 3 + rng.nextInt(4);

      for (var dy = -ry; dy <= ry; dy++) {
        for (var dx = -rx; dx <= rx; dx++) {
          final nx = cx + dx;
          final ny = cy + dy;
          if (!data.inBounds(nx, ny)) continue;
          if (ny >= config.height - 5) continue;
          if (ny <= heightmap[nx.clamp(0, config.width - 1)] + 6) continue;
          if (data.get(nx, ny) != El.stone) continue;

          final ex = dx.toDouble() / rx;
          final ey = dy.toDouble() / ry;
          final dist = ex * ex + ey * ey;
          final edge = bubbleNoise.noise2D(nx / 5.0, ny / 5.0) * 0.15;
          if (dist < 0.80 + edge) {
            data.set(nx, ny, El.empty);
          }
        }
      }
    }
  }

  static void _carveUndergroundCaverns(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final rng = Random(config.seed + 1200);
    final cavernCount = 4 + rng.nextInt(4);

    final cavernCenters = <(int, int)>[];

    for (var c = 0; c < cavernCount; c++) {
      final cx = (config.width * 0.08 + rng.nextDouble() * config.width * 0.84).round();
      final surfY = heightmap[cx.clamp(0, config.width - 1)];

      double minFrac, maxFrac;
      if (c < 2) {
        minFrac = 0.20; maxFrac = 0.40;
      } else if (c < 5) {
        minFrac = 0.40; maxFrac = 0.65;
      } else {
        minFrac = 0.65; maxFrac = 0.85;
      }
      final minY = (surfY + (config.height - surfY) * minFrac).round().clamp(surfY + 10, config.height - 15);
      final maxY = (surfY + (config.height - surfY) * maxFrac).round().clamp(minY + 5, config.height - 12);
      if (minY >= maxY) continue;
      final cy = minY + rng.nextInt(maxY - minY);

      final radiusX = 12 + rng.nextInt(16);
      final radiusY = 6 + rng.nextInt(10);

      cavernCenters.add((cx, cy));

      for (var dy = -radiusY; dy <= radiusY; dy++) {
        for (var dx = -radiusX; dx <= radiusX; dx++) {
          final nx = cx + dx;
          final ny = cy + dy;
          if (!data.inBounds(nx, ny)) continue;
          if (ny >= config.height - 5) continue;
          if (ny <= heightmap[nx.clamp(0, config.width - 1)] + 3) continue;

          final ex = dx.toDouble() / radiusX;
          final ey = dy.toDouble() / radiusY;
          final dist = ex * ex + ey * ey;
          final edgeNoise = ((nx * 7 + ny * 13) % 7) * 0.03;
          if (dist < 0.85 + edgeNoise) {
            data.set(nx, ny, El.empty);
          }
        }
      }

      // Stalactites.
      for (var sx = cx - radiusX + 2; sx < cx + radiusX - 2; sx += 1 + rng.nextInt(3)) {
        if (!data.inBounds(sx, cy - radiusY)) continue;
        final stalLen = 3 + rng.nextInt(5);
        for (var sy = 0; sy < stalLen; sy++) {
          final ty = cy - radiusY + sy + 1;
          if (data.inBounds(sx, ty) && data.get(sx, ty) == El.empty) {
            data.set(sx, ty, El.stone);
          }
        }
      }

      // Stalagmites.
      for (var sx = cx - radiusX + 2; sx < cx + radiusX - 2; sx += 2 + rng.nextInt(3)) {
        if (!data.inBounds(sx, cy + radiusY)) continue;
        final stagLen = 2 + rng.nextInt(4);
        for (var sy = 0; sy < stagLen; sy++) {
          final ty = cy + radiusY - sy - 1;
          if (data.inBounds(sx, ty) && data.get(sx, ty) == El.empty) {
            data.set(sx, ty, El.stone);
          }
        }
      }

      // Mushroom growths on cave floors.
      for (var mx = cx - radiusX + 3; mx < cx + radiusX - 3; mx += 4 + rng.nextInt(5)) {
        final floorY = cy + radiusY - 1;
        if (data.inBounds(mx, floorY) && data.get(mx, floorY) == El.empty) {
          data.setPlant(mx, floorY, plantMushroom, stMature);
          if (rng.nextBool() && data.inBounds(mx + 1, floorY) &&
              data.get(mx + 1, floorY) == El.empty) {
            data.setPlant(mx + 1, floorY, plantMushroom, stMature);
          }
        }
      }

      // Water pool at cavern floor.
      if (rng.nextDouble() < 0.7) {
        final poolWidth = 4 + rng.nextInt(radiusX ~/ 2);
        final poolDepth = 2 + rng.nextInt(2);
        for (var px = -poolWidth; px <= poolWidth; px++) {
          for (var pd = 0; pd < poolDepth; pd++) {
            final wx = cx + px;
            final floorY = cy + radiusY - 1 - pd;
            if (data.inBounds(wx, floorY) && data.get(wx, floorY) == El.empty) {
              data.set(wx, floorY, El.water);
            }
          }
        }
      }
    }

    // --- Lava lake in the deepest cavern ---
    if (cavernCenters.isNotEmpty) {
      var deepestIdx = 0;
      for (var i = 1; i < cavernCenters.length; i++) {
        if (cavernCenters[i].$2 > cavernCenters[deepestIdx].$2) {
          deepestIdx = i;
        }
      }
      final (lavaCX, lavaCY) = cavernCenters[deepestIdx];
      final lavaWidth = 15 + rng.nextInt(10);
      final lavaDepth = 3 + rng.nextInt(3);
      for (var px = -lavaWidth ~/ 2; px <= lavaWidth ~/ 2; px++) {
        for (var pd = 0; pd < lavaDepth; pd++) {
          final lx = lavaCX + px;
          final ly = lavaCY + 3 + pd;
          if (data.inBounds(lx, ly)) {
            final el = data.get(lx, ly);
            if (el == El.empty || el == El.water) {
              data.set(lx, ly, El.lava);
              data.setTemp(lx, ly, 250);
            }
          }
        }
      }
    }

    // --- Underground river connecting chambers ---
    if (cavernCenters.length >= 2) {
      final sorted = List<(int, int)>.from(cavernCenters)
        ..sort((a, b) => a.$1.compareTo(b.$1));
      final connectCount = min(3, sorted.length - 1);
      for (var i = 0; i < connectCount; i++) {
        final (x1, y1) = sorted[i];
        final (x2, y2) = sorted[i + 1];
        final steps = (x2 - x1).abs() + (y2 - y1).abs();
        if (steps == 0) continue;
        for (var t = 0; t <= steps; t++) {
          final frac = t / steps;
          final rx = (x1 + (x2 - x1) * frac).round();
          final ry = (y1 + (y2 - y1) * frac).round();
          for (var dy = -1; dy <= 1; dy++) {
            for (var dx = -1; dx <= 1; dx++) {
              final nx = rx + dx;
              final ny = ry + dy;
              if (!data.inBounds(nx, ny)) continue;
              if (ny >= config.height - 5) continue;
              if (ny <= heightmap[nx.clamp(0, config.width - 1)] + 3) continue;
              final el = data.get(nx, ny);
              if (el == El.stone || el == El.dirt) {
                data.set(nx, ny, dy == 1 ? El.water : El.empty);
              }
            }
          }
          if (data.inBounds(rx, ry + 1) && data.get(rx, ry + 1) == El.empty) {
            data.set(rx, ry + 1, El.water);
          }
          if (data.inBounds(rx, ry) && data.get(rx, ry) == El.empty) {
            data.set(rx, ry, El.water);
          }
        }
      }
    }

    // --- Crystal formations in deep stone ---
    final crystalMinY = (config.height * 0.70).round();
    final crystalNoise = SimplexNoise(config.seed + 1300);
    for (var y = crystalMinY; y < config.height - 5; y++) {
      for (var x = 0; x < config.width; x++) {
        if (data.get(x, y) != El.stone) continue;
        bool nearCave = false;
        for (var dy = -1; dy <= 1 && !nearCave; dy++) {
          for (var dx = -1; dx <= 1 && !nearCave; dx++) {
            if (data.get(x + dx, y + dy) == El.empty) nearCave = true;
          }
        }
        if (!nearCave) continue;
        final n = crystalNoise.noise2D(x / 6.0, y / 6.0);
        if (n > 0.55 && rng.nextDouble() < 0.3) {
          data.set(x, y, rng.nextBool() ? El.glass : El.ice);
          if (data.get(x, y) == El.ice) {
            data.setTemp(x, y, 20);
          }
        }
      }
    }
  }

  static int _countAdjacentEmpty(GridData data, int x, int y) {
    int count = 0;
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        if (data.get(x + dx, y + dy) == El.empty) count++;
      }
    }
    return count;
  }

  static void _smoothCaves(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final snapshot = Uint8List.fromList(data.grid);

    for (var y = 1; y < config.height - 1; y++) {
      for (var x = 1; x < config.width - 1; x++) {
        if (y < heightmap[x] + 5) continue;

        int stoneCount = 0;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            final nx = x + dx;
            final ny = y + dy;
            if (data.inBounds(nx, ny) &&
                snapshot[data.toIndex(nx, ny)] == El.stone) {
              stoneCount++;
            }
          }
        }

        final current = snapshot[data.toIndex(x, y)];
        if (current == El.stone && stoneCount <= 2) {
          data.set(x, y, El.empty);
        }
        if (current == El.empty && stoneCount >= 6) {
          data.set(x, y, El.stone);
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Water placement
  // --------------------------------------------------------------------------

  static void placeWater(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    if (config.waterLevel <= 0) return;

    _fillDepressions(data, config, heightmap);

    if (config.vegetation >= 0.8 && config.terrainScale < 1.0) {
      _placeMeadowStreams(data, config, heightmap);
    }

    // Underground pools.
    final rng = Random(config.seed + 2000);
    for (var x = 2; x < config.width - 2; x++) {
      for (var y = config.height - 6; y > heightmap[x] + 12; y--) {
        if (data.get(x, y) == El.empty && data.get(x, y + 1) == El.stone) {
          if (rng.nextDouble() < config.waterLevel * 0.30) {
            int left = x, right = x;
            while (left > 0 && data.get(left - 1, y) == El.empty &&
                   data.get(left - 1, y + 1) == El.stone) {
              left--;
            }
            while (right < config.width - 1 && data.get(right + 1, y) == El.empty &&
                   data.get(right + 1, y + 1) == El.stone) {
              right++;
            }
            final maxW = 2 + rng.nextInt(5);
            final poolLeft = max(left, x - maxW);
            final poolRight = min(right, x + maxW);
            final poolDepth = 1 + rng.nextInt(2);
            for (var px = poolLeft; px <= poolRight; px++) {
              for (var py = 0; py < poolDepth; py++) {
                final wy = y - py;
                if (data.inBounds(px, wy) && data.get(px, wy) == El.empty) {
                  data.set(px, wy, El.water);
                  data.setTemp(px, wy, 115); // cool underground water
                }
              }
            }
            x = poolRight + 3;
            break;
          }
        }
      }
    }
  }

  static void _fillDepressions(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final waterFilled = List<bool>.filled(config.width, false);

    for (var x = 1; x < config.width - 1; x++) {
      if (waterFilled[x]) continue;

      final h = heightmap[x];
      bool isDepression = false;

      int leftRidge = h;
      int rightRidge = h;

      for (var lx = x - 1; lx >= 0; lx--) {
        if (heightmap[lx] > leftRidge) break;
        leftRidge = heightmap[lx];
      }
      for (var rx = x + 1; rx < config.width; rx++) {
        if (heightmap[rx] > rightRidge) break;
        rightRidge = heightmap[rx];
      }

      final ridgeHeight = min(leftRidge, rightRidge);
      if (ridgeHeight < h - 1) {
        isDepression = true;
      }

      if (!isDepression) continue;

      final waterSurface = ridgeHeight;
      if (h - waterSurface < 2) continue;

      final rng = Random(config.seed + x);
      if (rng.nextDouble() > config.waterLevel * 0.8) continue;

      for (var fx = 0; fx < config.width; fx++) {
        // Only fill columns where terrain is below the water surface
        // (heightmap = y of terrain; larger y = lower on screen)
        if (heightmap[fx] <= waterSurface) continue;
        // Fill downward from water surface to terrain
        for (var fy = waterSurface; fy < heightmap[fx]; fy++) {
          if (fy < 0) continue;
          if (fy >= config.height) break;
          if (data.get(fx, fy) == El.empty) {
            data.set(fx, fy, El.water);
            data.setTemp(fx, fy, 120); // slightly cool water
            waterFilled[fx] = true;
          }
        }
      }
    }

    if (config.waterLevel >= 0.3) {
      final sortedHeights = List<int>.from(heightmap)..sort();
      final pct = (1.0 - config.waterLevel * 0.35).clamp(0.0, 1.0);
      final waterLineIdx =
          (sortedHeights.length * pct).round().clamp(0, sortedHeights.length - 1);
      final waterLine = sortedHeights[waterLineIdx];

      for (var x = 0; x < config.width; x++) {
        for (var y = waterLine; y < config.height; y++) {
          if (y >= heightmap[x]) break;
          if (data.get(x, y) == El.empty) {
            data.set(x, y, El.water);
            data.setTemp(x, y, 120); // slightly cool surface water
          }
        }
      }
    }
  }

  static void _placeMeadowStreams(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final rng = Random(config.seed + 2500);
    final lowPoints = <int>[];
    for (var x = 10; x < config.width - 10; x += 20) {
      int lowestX = x;
      for (var dx = -10; dx <= 10; dx++) {
        final cx = x + dx;
        if (cx >= 0 && cx < config.width && heightmap[cx] > heightmap[lowestX]) {
          lowestX = cx;
        }
      }
      lowPoints.add(lowestX);
    }

    for (var i = 0; i < lowPoints.length - 1 && i < 3; i++) {
      if (rng.nextDouble() > 0.5) continue;
      final x1 = lowPoints[i];
      final x2 = lowPoints[i + 1];
      for (var x = min(x1, x2); x <= max(x1, x2); x++) {
        final surfY = heightmap[x];
        if (data.get(x, surfY - 1) == El.empty &&
            data.get(x, surfY) == El.dirt) {
          data.set(x, surfY, El.water);
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Island ocean fill
  // --------------------------------------------------------------------------

  static void fillIslandOcean(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final waterLine = (config.height * 0.55).round();

    for (var x = 0; x < config.width; x++) {
      final surface = heightmap[x];

      for (var y = waterLine; y < config.height - 5; y++) {
        if (data.get(x, y) == El.empty) {
          data.set(x, y, El.water);
        }
      }

      if (surface > waterLine) {
        for (var y = waterLine; y < surface; y++) {
          if (data.get(x, y) == El.empty) {
            data.set(x, y, El.water);
          }
        }
      }

      if (surface >= waterLine - 6 && surface <= waterLine + 3) {
        for (var dy = -3; dy <= 5; dy++) {
          final by = surface + dy;
          if (data.inBounds(x, by) && data.get(x, by) == El.dirt) {
            data.set(x, by, El.sand);
          }
        }
      }

      if (surface > waterLine + 3) {
        for (var dy = 0; dy < 3; dy++) {
          if (data.inBounds(x, surface + dy) &&
              data.get(x, surface + dy) == El.dirt) {
            data.set(x, surface + dy, El.sand);
          }
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Canyon features
  // --------------------------------------------------------------------------

  static void placeCanyonFeatures(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final rng = Random(config.seed + 9000);
    final center = config.width ~/ 2;
    final canyonWidth = (config.width * 0.30).round();

    int floorY = 0;
    for (var x = center - canyonWidth; x < center + canyonWidth; x++) {
      if (x >= 0 && x < config.width && heightmap[x] > floorY) {
        floorY = heightmap[x];
      }
    }

    // River at canyon bottom.
    for (var x = center - canyonWidth + 5; x < center + canyonWidth - 5; x++) {
      if (x < 0 || x >= config.width) continue;
      final h = heightmap[x];
      if (h > floorY - (config.height * 0.08).round()) {
        for (var dy = 0; dy < 3; dy++) {
          final wy = h - 1 - dy;
          if (wy > 0 && data.get(x, wy) == El.empty) {
            data.set(x, wy, El.water);
          }
        }
        for (var sd = 0; sd < 3; sd++) {
          if (data.inBounds(x, h + sd) && data.get(x, h + sd) == El.dirt) {
            data.set(x, h + sd, El.sand);
          }
        }
      }
    }

    // Cliff-face caves.
    for (var attempt = 0; attempt < 6; attempt++) {
      final side = rng.nextBool() ? -1 : 1;
      final wallX = center + side * (canyonWidth ~/ 2 + rng.nextInt(canyonWidth ~/ 3));
      if (wallX < 3 || wallX >= config.width - 3) continue;

      final surfY = heightmap[wallX.clamp(0, config.width - 1)];
      final caveY = surfY + 5 + rng.nextInt(15);
      if (caveY >= config.height - 10) continue;

      final caveW = 4 + rng.nextInt(5);
      final caveH = 3 + rng.nextInt(3);
      for (var dy = -caveH ~/ 2; dy <= caveH ~/ 2; dy++) {
        for (var dx = 0; dx < caveW; dx++) {
          final nx = wallX + dx * -side;
          final ny = caveY + dy;
          if (data.inBounds(nx, ny) && data.get(nx, ny) == El.stone) {
            data.set(nx, ny, El.empty);
          }
        }
      }
    }

    // Expose stone at cliff surfaces.
    for (var x = center - canyonWidth; x < center + canyonWidth; x++) {
      if (x < 0 || x >= config.width) continue;
      final surfY = heightmap[x];
      if (x > 0 && x < config.width - 1) {
        final slopeL = (heightmap[x] - heightmap[x - 1]).abs();
        final slopeR = (heightmap[x] - heightmap[(x + 1).clamp(0, config.width - 1)]).abs();
        if (slopeL > 2 || slopeR > 2) {
          for (var dy = 0; dy < 3; dy++) {
            if (data.inBounds(x, surfY + dy) && data.get(x, surfY + dy) == El.dirt) {
              data.set(x, surfY + dy, El.stone);
            }
          }
        }
      }
    }

    // Waterfalls from cliff ledges.
    int waterfallsPlaced = 0;
    for (var x = center - canyonWidth; x < center + canyonWidth && waterfallsPlaced < 2; x++) {
      if (x < 2 || x >= config.width - 2) continue;
      final h = heightmap[x];
      final nextH = heightmap[(x + 1).clamp(0, config.width - 1)];
      if ((nextH - h).abs() > 8 && rng.nextDouble() < 0.3) {
        for (var dy = 0; dy < 4; dy++) {
          final wy = h - 1 - dy;
          if (wy > 0 && data.get(x, wy) == El.empty) {
            data.set(x, wy, El.water);
          }
        }
        waterfallsPlaced++;
        x += 15;
      }
    }
  }

  // --------------------------------------------------------------------------
  // Waterfalls
  // --------------------------------------------------------------------------

  static void placeWaterfalls(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    if (config.waterLevel <= 0.1) return;

    final rng = Random(config.seed + 6000);
    int placed = 0;
    final maxFalls = (config.width / 80).ceil().clamp(1, 5);

    for (var x = 5; x < config.width - 5; x++) {
      if (placed >= maxFalls) break;

      final h = heightmap[x];
      int maxDrop = 0;
      for (var dx = 1; dx <= 4; dx++) {
        if (x + dx >= config.width) break;
        final drop = heightmap[x + dx] - h;
        if (drop > maxDrop) maxDrop = drop;
      }

      if (maxDrop >= 5 && rng.nextDouble() < 0.4) {
        final sourceY = h - 1;
        if (sourceY > 0 && data.get(x, sourceY) == El.empty) {
          for (var dy = 0; dy < 3; dy++) {
            if (data.get(x, sourceY - dy) == El.empty) {
              data.set(x, sourceY - dy, El.water);
              data.setTemp(x, sourceY - dy, 120);
            }
          }
          placed++;
          x += 20;
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Snow on high elevations
  // --------------------------------------------------------------------------

  static void placeSnow(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    if (config.terrainScale <= 1.0) return;
    if (config.vegetation >= 0.8) return;

    int minH = config.height;
    int maxH = 0;
    for (final h in heightmap) {
      if (h < minH) minH = h;
      if (h > maxH) maxH = h;
    }

    final range = maxH - minH;
    if (range <= 5) return;

    final snowLine = minH + (range * 0.10).round();

    for (var x = 0; x < config.width; x++) {
      if (heightmap[x] > snowLine) continue;

      final surfaceY = heightmap[x];
      if (data.get(x, surfaceY) == El.dirt) {
        data.set(x, surfaceY, El.snow);
        data.setTemp(x, surfaceY, 80); // cold snow
      }
      if (surfaceY > 0 && data.get(x, surfaceY - 1) == El.empty) {
        data.set(x, surfaceY - 1, El.snow);
        data.setTemp(x, surfaceY - 1, 80); // cold snow
      }
    }
  }

  // --------------------------------------------------------------------------
  // Lava + sulfur (volcanic features)
  // --------------------------------------------------------------------------

  /// Place lava pockets deep underground with sulfur deposits nearby.
  /// Sulfur forms naturally near volcanic heat sources -- real geology.
  static void placeLava(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    if (config.vegetation >= 0.8 && config.terrainScale < 1.0) return;

    final rng = Random(config.seed + 7000);
    final lavaNoise = SimplexNoise(config.seed + 7000);

    final lavaMinY = (config.height * (0.75 - config.volcanicActivity * 0.15)).round();

    for (var y = lavaMinY; y < config.height - 5; y++) {
      for (var x = 0; x < config.width; x++) {
        if (data.get(x, y) != El.stone) continue;

        final n = lavaNoise.octaveNoise2D(
          x / (config.width * 0.08),
          y / (config.height * 0.08),
          octaves: 2,
        );

        // More lava with higher volcanic activity.
        final threshold = 0.65 - config.volcanicActivity * 0.15;
        if (n > threshold && rng.nextDouble() < 0.5) {
          data.set(x, y, El.lava);
          data.setTemp(x, y, 250);
        }
      }
    }
  }

  /// Place sulfur deposits near lava features.
  /// In real geology, sulfur concentrates around volcanic vents.
  static void placeSulfur(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    if (config.sulfurNearLava <= 0) return;

    final rng = Random(config.seed + 7500);

    final radius = config.sulfurSearchRadius;

    for (var y = 0; y < config.height - 5; y++) {
      for (var x = 0; x < config.width; x++) {
        if (data.get(x, y) != El.stone) continue;

        // Check for nearby lava within config-driven radius.
        bool nearLava = false;
        for (var dy = -radius; dy <= radius && !nearLava; dy++) {
          for (var dx = -radius; dx <= radius && !nearLava; dx++) {
            if (data.get(x + dx, y + dy) == El.lava) nearLava = true;
          }
        }
        if (!nearLava) continue;

        if (rng.nextDouble() < config.sulfurNearLava * 0.4) {
          data.set(x, y, El.sulfur);
          data.setTemp(x, y, 160); // Warm from nearby lava.
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Ore veins -- geologically realistic depth ordering
  // --------------------------------------------------------------------------

  /// Place ore deposits with real geological depth ordering:
  /// - Copper veins: shallower (real: 0-1km depth, porphyry deposits)
  /// - Metal (iron) veins: deeper (real: banded iron formations at depth)
  /// - Both use anisotropic noise for vein-like elongated shapes.
  ///
  /// Electrical conductivity: metal veins that span multiple depth layers
  /// create natural conductive paths through the rock.
  static void placeOre(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final rng = Random(config.seed + 3000);
    final oreNoise = SimplexNoise(config.seed + 3000);
    final copperNoise = SimplexNoise(config.seed + 3200);
    final veinAngle = SimplexNoise(config.seed + 3100);

    final isUnderground = config.caveDensity >= 0.6 && config.vegetation <= 0.1;
    final richness = config.oreRichness * (isUnderground ? 1.5 : 1.0);

    for (var y = 0; y < config.height; y++) {
      for (var x = 0; x < config.width; x++) {
        if (data.get(x, y) != El.stone) continue;
        final surfY = heightmap[x.clamp(0, config.width - 1)];
        if (y < surfY + config.oreMinDepth) continue;

        final depthFrac = ((y - surfY) / (config.height - surfY)).clamp(0.0, 1.0);

        // Anisotropic vein sampling.
        final angle = veinAngle.noise2D(x / 40.0, y / 40.0) * 1.2;
        final cosA = cos(angle);
        final sinA = sin(angle);
        final sx = (x * cosA - y * sinA) / (config.width * 0.04);
        final sy = (x * sinA + y * cosA) / (config.height * 0.12);

        // --- Copper: peaks at copperDepth, gaussian falloff ---
        final copperDist = (depthFrac - config.copperDepth).abs();
        final copperWeight = exp(-copperDist * copperDist * config.copperSpread);
        final cn = copperNoise.octaveNoise2D(sx * 1.2, sy * 1.2, octaves: 2);
        final copperThreshold = config.copperThresholdBase - richness * 0.15 - copperWeight * 0.12;

        if (cn > copperThreshold && rng.nextDouble() < richness * 0.6) {
          data.set(x, y, El.copper);
          continue;
        }

        // --- Iron/Metal: peaks at metalDepth, gaussian falloff ---
        final metalDist = (depthFrac - config.metalDepth).abs();
        final metalWeight = exp(-metalDist * metalDist * config.metalSpread);
        final mn = oreNoise.octaveNoise2D(sx, sy, octaves: 2);
        final metalThreshold = config.metalThresholdBase - richness * 0.12 - metalWeight * 0.10;

        if (mn > metalThreshold && rng.nextDouble() < richness * 0.65) {
          data.set(x, y, El.metal);
          continue;
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Coal seams in organic layers
  // --------------------------------------------------------------------------

  /// Place coal/charcoal seams -- ancient compressed organic material.
  /// Real geology: coal forms in sedimentary layers from ancient forests.
  /// Placed in the transition zone between dirt and stone.
  static void placeCoalSeams(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    if (config.coalSeams <= 0) return;

    final rng = Random(config.seed + 3500);
    final coalNoise = SimplexNoise(config.seed + 3500);

    for (var y = 0; y < config.height - 5; y++) {
      for (var x = 0; x < config.width; x++) {
        final el = data.get(x, y);
        // Coal forms at the dirt-stone boundary and within stone near surface.
        if (el != El.stone && el != El.dirt) continue;
        final surfY = heightmap[x.clamp(0, config.width - 1)];
        final depth = y - surfY;
        if (depth < config.coalMinDepth || depth > config.height * config.coalMaxDepthFrac) continue;

        // Horizontal seam noise (stretched horizontally for layers).
        final n = coalNoise.octaveNoise2D(
          x / (config.width * 0.05),
          y / (config.height * 0.25),
          octaves: 2,
          persistence: 0.3,
        );

        // Thin seam: narrow band around threshold.
        if (n.abs() < config.coalSeamThickness + config.coalSeams * config.coalSeamThickness) {
          if (rng.nextDouble() < config.coalSeams * 0.7) {
            data.set(x, y, El.charcoal);
          }
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Salt deposits
  // --------------------------------------------------------------------------

  /// Place salt deposits in dried lake beds and cave floors.
  /// Real geology: evaporite deposits form when water evaporates.
  static void placeSaltDeposits(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    if (config.saltDeposits <= 0) return;

    final rng = Random(config.seed + 3600);

    for (var y = 0; y < config.height - 5; y++) {
      for (var x = 0; x < config.width; x++) {
        final el = data.get(x, y);
        if (el != El.stone && el != El.dirt && el != El.clay) continue;

        // Must be at a cave floor (empty above) or near water.
        final above = data.get(x, y - 1);
        final below = data.get(x, y + 1);
        bool isCaveFloor = (above == El.empty && below != El.empty);
        bool nearWater = false;
        final saltR = config.saltSearchRadius;
        for (var dy = -saltR; dy <= saltR && !nearWater; dy++) {
          for (var dx = -saltR; dx <= saltR && !nearWater; dx++) {
            if (data.get(x + dx, y + dy) == El.water) nearWater = true;
          }
        }

        if ((isCaveFloor || nearWater) && rng.nextDouble() < config.saltDeposits * 0.25) {
          data.set(x, y, El.salt);
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Periodic table ores — depth-stratified geological placement
  // --------------------------------------------------------------------------

  /// Place periodic table elements as ore deposits at geologically
  /// appropriate depths. Real-world distribution: lighter elements near
  /// surface, heavier/rarer elements deeper underground.
  static void placePeriodicOres(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final rng = Random(config.seed + 5000);
    final noises = <int, SimplexNoise>{};
    SimplexNoise noiseFor(int el) =>
        noises.putIfAbsent(el, () => SimplexNoise(config.seed + 5000 + el));

    final richness = config.oreRichness;
    if (richness <= 0) return;

    // Ore placement table: (element, minDepthFrac, maxDepthFrac, rarity)
    // rarity: lower = more common. 0.0-1.0 scale.
    final ores = <(int, double, double, double)>[
      // Surface/shallow ores
      (El.aluminum, 0.05, 0.35, 0.15),
      (El.silicon,  0.0,  0.25, 0.12),
      (El.calcium,  0.05, 0.30, 0.10),
      (El.tin,      0.10, 0.40, 0.20),
      // Mid-depth ores
      (El.zinc,     0.15, 0.50, 0.22),
      (El.nickel,   0.20, 0.55, 0.25),
      (El.chromium, 0.20, 0.55, 0.25),
      (El.manganese,0.15, 0.50, 0.22),
      (El.cobalt,   0.25, 0.60, 0.28),
      (El.titanium, 0.20, 0.55, 0.26),
      (El.silver,   0.30, 0.65, 0.35),
      // Deep ores
      (El.gold,     0.45, 0.80, 0.45),
      (El.platinum, 0.50, 0.85, 0.50),
      (El.tungsten, 0.40, 0.75, 0.40),
      (El.molybdenum, 0.35, 0.70, 0.35),
      (El.iridium,  0.55, 0.90, 0.55),
      // Very deep / rare
      (El.thorium,  0.60, 0.90, 0.60),
      (El.plutonium,0.70, 0.95, 0.70),
      (El.neodymium,0.50, 0.80, 0.50),
      // Diamond from charcoal under pressure
      (El.carbon,   0.75, 0.95, 0.65),
    ];

    for (var y = 0; y < config.height - 5; y++) {
      for (var x = 0; x < config.width; x++) {
        if (data.get(x, y) != El.stone) continue;
        final surfY = heightmap[x.clamp(0, config.width - 1)];
        if (y <= surfY) continue;
        final depthFrac = ((y - surfY) / (config.height - surfY)).clamp(0.0, 1.0);

        for (final (el, minD, maxD, rarity) in ores) {
          if (depthFrac < minD || depthFrac > maxD) continue;
          // Gaussian weight centered on the optimal depth
          final center = (minD + maxD) / 2;
          final dist = (depthFrac - center).abs();
          final spread = (maxD - minD) / 2;
          final weight = exp(-dist * dist / (spread * spread));

          final n = noiseFor(el).octaveNoise2D(
            x / (config.width * 0.04),
            y / (config.height * 0.08),
            octaves: 2,
          );

          final threshold = 0.55 + rarity * 0.2 - weight * 0.15 - richness * 0.1;
          if (n > threshold && rng.nextDouble() < richness * (1.0 - rarity) * 0.3) {
            data.set(x, y, el);
            break; // Only one ore per cell
          }
        }
      }
    }

    // Noble gas pockets in caves
    for (var y = 0; y < config.height; y++) {
      for (var x = 0; x < config.width; x++) {
        if (data.get(x, y) != El.empty) continue;
        final surfY = heightmap[x.clamp(0, config.width - 1)];
        if (y <= surfY + 10) continue; // deep underground only
        // Small chance of argon/xenon pocket
        if (rng.nextInt(2000) == 0) {
          final gas = rng.nextBool() ? El.argon : El.xenon;
          for (var dy = -1; dy <= 1; dy++) {
            for (var dx = -1; dx <= 1; dx++) {
              if (data.get(x + dx, y + dy) == El.empty) {
                data.set(x + dx, y + dy, gas);
              }
            }
          }
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Surface detail: sand, boulders, grass
  // --------------------------------------------------------------------------

  static void placeSurfaceDetail(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    _placeCliffOverhangs(data, config, heightmap);

    final rng = Random(config.seed + 8000);
    final boulderNoise = SimplexNoise(config.seed + 8100);

    for (var x = 1; x < config.width - 1; x++) {
      final surfaceY = heightmap[x];
      if (surfaceY <= 1 || surfaceY >= config.height - 5) continue;
      if (data.get(x, surfaceY) != El.dirt) continue;

      // Sand near water edges.
      bool nearWater = false;
      for (var dx = -4; dx <= 4 && !nearWater; dx++) {
        for (var dy = -3; dy <= 3 && !nearWater; dy++) {
          if (data.get(x + dx, surfaceY + dy) == El.water) {
            nearWater = true;
          }
        }
      }
      if (nearWater && rng.nextDouble() < 0.7) {
        data.set(x, surfaceY, El.sand);
        if (data.get(x, surfaceY + 1) == El.dirt && rng.nextDouble() < 0.4) {
          data.set(x, surfaceY + 1, El.sand);
        }
        continue;
      }

      // Occasional surface boulders.
      final bn = boulderNoise.noise2D(x / 15.0, surfaceY / 15.0);
      if (bn > 0.7 && rng.nextDouble() < 0.15) {
        final boulderSize = 1 + rng.nextInt(2);
        for (var bx = 0; bx < boulderSize; bx++) {
          for (var by = 0; by < boulderSize; by++) {
            final px = x + bx;
            final py = surfaceY - 1 - by;
            if (py > 0 && data.get(px, py) == El.empty) {
              data.set(px, py, El.stone);
            }
          }
        }
        x += boulderSize;
        continue;
      }

      // Grass on most dirt surfaces.
      if (data.get(x, surfaceY - 1) == El.empty) {
        final grassChance = config.vegetation >= 0.8 ? 0.92 : 0.75;
        if (rng.nextDouble() < grassChance) {
          data.setPlant(x, surfaceY - 1, plantGrass, stMature);
        }
      }
    }
  }

  static void _placeCliffOverhangs(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final rng = Random(config.seed + 8200);

    for (var x = 2; x < config.width - 2; x++) {
      final h = heightmap[x];
      final hNext = heightmap[x + 1];
      final drop = hNext - h;

      if (drop.abs() < 5) continue;
      if (rng.nextDouble() > 0.4) continue;

      final shelfWidth = 2 + rng.nextInt(3);
      final dir = drop > 0 ? 1 : -1;
      final shelfY = h + (drop.abs() ~/ 3);

      for (var dx = 0; dx < shelfWidth; dx++) {
        final sx = x + dx * dir;
        if (!data.inBounds(sx, shelfY)) continue;
        if (data.get(sx, shelfY) == El.stone || data.get(sx, shelfY) == El.dirt) {
          data.set(sx, shelfY, El.empty);
          if (data.inBounds(sx, shelfY - 1) &&
              data.get(sx, shelfY - 1) == El.stone) {
            data.set(sx, shelfY - 1, El.empty);
          }
        }
      }
      x += shelfWidth + 2;
    }
  }

  // --------------------------------------------------------------------------
  // Vegetation & trees
  // --------------------------------------------------------------------------

  static void placeVegetation(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    if (config.vegetation <= 0) return;

    final rng = Random(config.seed + 4000);
    final clusterNoise = SimplexNoise(config.seed + 4100);
    final flowerNoise = SimplexNoise(config.seed + 4200);

    final isMeadow = config.vegetation >= 0.8 && config.terrainScale < 1.0;

    for (var x = 2; x < config.width - 2; x++) {
      final surfaceY = heightmap[x];
      if (surfaceY <= 3 || surfaceY >= config.height - 5) continue;

      final surfaceEl = data.get(x, surfaceY);
      if (surfaceEl != El.dirt) continue;

      if (data.get(x, surfaceY - 1) != El.empty) continue;

      final density = clusterNoise.noise2D(x / 15.0, 0.0);
      final clusterFactor = ((density + 1.0) * 0.5).clamp(0.0, 1.0);

      bool moist = false;
      for (var dx = -8; dx <= 8 && !moist; dx++) {
        for (var dy = -4; dy <= 4 && !moist; dy++) {
          if (data.get(x + dx, surfaceY + dy) == El.water) {
            moist = true;
          }
        }
      }

      final baseChance = config.vegetation * clusterFactor;
      final chance = moist ? baseChance * 0.7 : baseChance * 0.30;

      if (rng.nextDouble() < chance) {
        if (clusterFactor > 0.45 && rng.nextDouble() < 0.45) {
          final groveSize = isMeadow ? (5 + rng.nextInt(4)) : (2 + rng.nextInt(3));
          for (var t = 0; t < groveSize; t++) {
            final tx = x + t * 3;
            if (tx >= config.width - 2) break;
            final tSurface = heightmap[tx];
            if (data.get(tx, tSurface) == El.dirt &&
                data.get(tx, tSurface - 1) == El.empty) {
              _placeTree(data, tx, tSurface, rng);
            }
          }
          x += groveSize * 3;
        } else {
          data.set(x, surfaceY - 1, El.seed);
        }
      }

      // Meadow flowers.
      if (isMeadow && data.get(x, surfaceY - 1) == El.empty) {
        final fn = flowerNoise.noise2D(x / 10.0, 0.5);
        if (fn > 0.3 && rng.nextDouble() < 0.15) {
          data.setPlant(x, surfaceY - 1, plantFlower, stMature);
        }
      }
    }
  }

  static void _placeTree(GridData data, int x, int surfaceY, Random rng) {
    final trunkHeight = 3 + rng.nextInt(4);

    data.set(x, surfaceY, El.wood);

    for (var i = 1; i <= trunkHeight; i++) {
      final ty = surfaceY - i;
      if (ty < 1) break;
      if (data.get(x, ty) != El.empty) break;
      data.set(x, ty, El.wood);
    }

    // Roots.
    final rootDepth = 2 + rng.nextInt(3);
    for (var i = 1; i <= rootDepth; i++) {
      final ry = surfaceY + i;
      if (!data.inBounds(x, ry)) break;
      final below = data.get(x, ry);
      if (below == El.dirt) {
        data.set(x, ry, El.wood);
      } else {
        break;
      }
    }
    for (final dx in [-1, 1]) {
      final rootLen = 1 + rng.nextInt(2);
      for (var i = 1; i <= rootLen; i++) {
        final rx = x + dx * i;
        final ry = surfaceY + i;
        if (!data.inBounds(rx, ry)) break;
        if (data.get(rx, ry) == El.dirt) {
          data.set(rx, ry, El.wood);
        } else {
          break;
        }
      }
    }

    // Canopy.
    final topY = surfaceY - trunkHeight;
    if (topY < 2) return;

    final canopyRadius = 1 + rng.nextInt(2);
    for (var dy = -canopyRadius; dy <= 0; dy++) {
      for (var dx = -canopyRadius; dx <= canopyRadius; dx++) {
        if (dx == 0 && dy == 0) continue;
        final px = x + dx;
        final py = topY + dy;
        if (data.inBounds(px, py) && data.get(px, py) == El.empty) {
          data.setPlant(px, py, plantTree, stMature);
        }
      }
    }
    if (data.inBounds(x, topY - 1) && data.get(x, topY - 1) == El.empty) {
      data.setPlant(x, topY - 1, plantTree, stMature);
    }
  }

  // --------------------------------------------------------------------------
  // Atmosphere: oxygen + CO2
  // --------------------------------------------------------------------------

  /// Fill all air cells with oxygen (background atmosphere).
  /// CO2, being heavier, pools in cave floor depressions.
  static void placeAtmosphere(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final rng = Random(config.seed + 10000);

    for (var y = 0; y < config.height; y++) {
      for (var x = 0; x < config.width; x++) {
        if (data.get(x, y) != El.empty) continue;

        // Determine if this is underground (below terrain surface).
        final surfY = heightmap[x.clamp(0, config.width - 1)];
        final isUnderground = y > surfY + 3;

        if (isUnderground) {
          // CO2 pools at cave floors (heavier than air, sinks).
          final below = data.get(x, y + 1);
          final belowIsFloor = below == El.stone || below == El.dirt ||
              below == El.clay || below == El.metal;
          if (belowIsFloor && config.co2InCaves > 0 &&
              rng.nextDouble() < config.co2InCaves * 0.3) {
            data.set(x, y, El.co2);
            continue;
          }
        }

        // Fill remaining air with oxygen.
        if (config.oxygenFill) {
          data.set(x, y, El.oxygen);
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Ecosystem seeding: fungus, algae, seeds on fertile dirt
  // --------------------------------------------------------------------------

  /// Place living organisms in appropriate habitats:
  /// - Fungus in dark moist caves (no light needed)
  /// - Algae in water bodies
  /// - Extra seeds on fertile dirt near water (surface only)
  static void placeEcosystem(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final rng = Random(config.seed + 11000);

    // --- Fungus in caves ---
    if (config.fungalGrowth > 0) {
      final fungalR = config.fungalMoistureRadius;
      for (var y = 0; y < config.height - 5; y++) {
        for (var x = 0; x < config.width; x++) {
          final surfY = heightmap[x.clamp(0, config.width - 1)];
          if (y < surfY + config.fungalMinDepth) continue;

          final el = data.get(x, y);
          if (el != El.oxygen && el != El.empty) continue;

          // Must be on a cave floor.
          final below = data.get(x, y + 1);
          if (below != El.stone && below != El.dirt && below != El.compost) continue;

          // Check for moisture within config-driven radius.
          bool moist = false;
          for (var dy = -fungalR; dy <= fungalR && !moist; dy++) {
            for (var dx = -fungalR; dx <= fungalR && !moist; dx++) {
              final neighbor = data.get(x + dx, y + dy);
              if (neighbor == El.water) moist = true;
            }
          }

          if (moist && rng.nextDouble() < config.fungalGrowth * 0.15) {
            data.set(x, y, El.fungus);
          }
        }
      }
    }

    // --- Algae in water ---
    if (config.algaeInWater > 0) {
      for (var y = 0; y < config.height - 5; y++) {
        for (var x = 0; x < config.width; x++) {
          if (data.get(x, y) != El.water) continue;

          // Algae grows on surfaces in water (near stone/dirt).
          bool nearSurface = false;
          for (var dy = -1; dy <= 1 && !nearSurface; dy++) {
            for (var dx = -1; dx <= 1 && !nearSurface; dx++) {
              final neighbor = data.get(x + dx, y + dy);
              if (neighbor == El.stone || neighbor == El.dirt ||
                  neighbor == El.sand) {
                nearSurface = true;
              }
            }
          }

          // Surface water algae prefers shallow areas.
          final surfY = heightmap[x.clamp(0, config.width - 1)];
          final isShallow = y < surfY + config.algaeShallowDepth;
          final chance = isShallow
              ? config.algaeInWater * 0.12
              : config.algaeInWater * 0.04;

          if (nearSurface && rng.nextDouble() < chance) {
            data.set(x, y, El.algae);
          }
        }
      }
    }

    // --- Extra seeds on fertile dirt near water ---
    if (config.seedScatter > 0) {
      for (var x = 2; x < config.width - 2; x++) {
        final surfY = heightmap[x];
        if (surfY <= 2 || surfY >= config.height - 5) continue;
        if (data.get(x, surfY) != El.dirt) continue;
        if (data.get(x, surfY - 1) != El.oxygen &&
            data.get(x, surfY - 1) != El.empty) {
          continue;
        }

        // Check for nearby water (moisture) within config-driven radius.
        bool moist = false;
        final seedR = config.seedMoistureRadius;
        for (var dx = -seedR; dx <= seedR && !moist; dx++) {
          for (var dy = -(seedR ~/ 2); dy <= (seedR ~/ 2) && !moist; dy++) {
            if (data.get(x + dx, surfY + dy) == El.water) moist = true;
          }
        }

        // Also check if compost is below (fertile soil).
        bool fertile = false;
        for (var dy = 0; dy <= 3; dy++) {
          if (data.get(x, surfY + dy) == El.compost) {
            fertile = true;
            break;
          }
        }

        final chance = moist
            ? config.seedScatter * 0.15
            : (fertile ? config.seedScatter * 0.08 : config.seedScatter * 0.03);

        if (rng.nextDouble() < chance) {
          data.set(x, surfY - 1, El.seed);
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Electrical features: conductive veins + insulating layers
  // --------------------------------------------------------------------------

  /// Place electrically interesting geological features:
  /// - Conductive metal veins spanning depth layers (natural wires)
  /// - Insulating clay/glass layers that block current flow
  /// - Underground water tables as conductive paths
  static void placeElectricalFeatures(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    if (config.conductiveVeins <= 0 && config.insulatingLayers <= 0) return;

    final rng = Random(config.seed + 12000);
    final veinNoise = SimplexNoise(config.seed + 12000);

    // --- Vertical conductive veins (metal ore connecting layers) ---
    if (config.conductiveVeins > 0) {
      final veinCount = (2 + config.conductiveVeins * 6).round();
      for (var v = 0; v < veinCount; v++) {
        final startX = (config.width * 0.05 +
            rng.nextDouble() * config.width * 0.90).round();
        final surfY = heightmap[startX.clamp(0, config.width - 1)];
        final veinTop = surfY + 10 + rng.nextInt(15);
        final veinBottom = min(config.height - 6,
            veinTop + 15 + rng.nextInt(30));

        // Trace a slightly wandering vertical vein.
        var cx = startX;
        for (var y = veinTop; y < veinBottom; y++) {
          // Slight horizontal wander.
          final wander = veinNoise.noise2D(y / 8.0, v * 10.0);
          cx = (startX + wander * 3).round().clamp(1, config.width - 2);

          if (data.get(cx, y) == El.stone) {
            data.set(cx, y, El.metal);
          }
          // Occasionally widen the vein.
          if (rng.nextDouble() < 0.3) {
            final dx = rng.nextBool() ? 1 : -1;
            if (data.get(cx + dx, y) == El.stone) {
              data.set(cx + dx, y, El.metal);
            }
          }
        }
      }
    }

    // --- Horizontal insulating clay layers ---
    if (config.insulatingLayers > 0) {
      final layerCount = (1 + config.insulatingLayers * 4).round();
      for (var l = 0; l < layerCount; l++) {
        final layerY = (config.height * (0.3 + l * 0.15)).round();
        if (layerY >= config.height - 6) continue;

        final layerWidth = (config.width * (0.3 + rng.nextDouble() * 0.5)).round();
        final startX = rng.nextInt(config.width);
        final thickness = 1 + rng.nextInt(2);

        for (var dx = 0; dx < layerWidth; dx++) {
          final x = (startX + dx) % config.width; // Wraps horizontally.
          for (var dy = 0; dy < thickness; dy++) {
            final y = layerY + dy;
            if (!data.inBounds(x, y)) continue;
            if (data.get(x, y) == El.stone) {
              data.set(x, y, El.clay);
            }
          }
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Ant colonies
  // --------------------------------------------------------------------------

  static List<(int, int)> placeAntColonies(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    if (!config.placeAnts) return [];

    final rng = Random(config.seed + 5000);
    final colonies = <(int, int)>[];
    final targetCount = 2 + rng.nextInt(2);
    final segmentWidth = config.width ~/ (targetCount + 1);

    for (var i = 1; i <= targetCount; i++) {
      final centerX = segmentWidth * i;
      for (var attempt = 0; attempt < 30; attempt++) {
        final x = (centerX + rng.nextInt(segmentWidth) - segmentWidth ~/ 2)
            .clamp(5, config.width - 5);
        final surfaceY = heightmap[x];
        final testY = surfaceY + 5 + rng.nextInt(10);
        if (testY >= config.height - 5) continue;

        if (data.get(x, testY) == El.empty &&
            data.get(x, testY + 1) != El.empty) {
          data.set(x, testY, El.ant);
          colonies.add((x, testY));
          break;
        }
      }
    }

    return colonies;
  }
}

// dart:math provides exp(), cos(), sin() as top-level functions.
