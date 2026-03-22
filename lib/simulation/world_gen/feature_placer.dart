import 'dart:math';
import 'dart:typed_data';

import '../element_registry.dart';
import 'grid_data.dart';
import 'noise.dart';
import 'world_config.dart';

/// Places specific features onto an already-generated base terrain.
class FeaturePlacer {
  FeaturePlacer._();

  // --------------------------------------------------------------------------
  // Cave carving
  // --------------------------------------------------------------------------

  /// Carve caves in the stone layer using layered noise for natural tunnels.
  ///
  /// Uses tighter thresholds and multiple smoothing passes to produce
  /// small-to-medium tunnels rather than huge open chambers.
  static void carveCaves(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    if (config.caveDensity <= 0) return;

    final caveNoise = SimplexNoise(config.seed + 1000);
    final wormNoise = SimplexNoise(config.seed + 1100);

    // Tighter threshold = fewer caves, more solid underground.
    // caveDensity 0.15 → threshold 0.52 (small pockets)
    // caveDensity 0.5  → threshold 0.42 (moderate tunnels)
    // caveDensity 0.7  → threshold 0.36 (extensive networks)
    final threshold = 0.55 - config.caveDensity * 0.27;

    for (var y = 0; y < config.height - 5; y++) {
      for (var x = 0; x < config.width; x++) {
        if (data.get(x, y) != El.stone) continue;
        // Keep a buffer below terrain surface.
        if (y < heightmap[x] + 6) continue;

        // Primary cave noise (medium-scale tunnels).
        final n1 = caveNoise.octaveNoise2D(
          x / (config.width * 0.12),
          y / (config.height * 0.12),
          octaves: 3,
          persistence: 0.45,
          lacunarity: 2.2,
        );

        // Secondary worm-like tunnels (higher frequency, tighter).
        final n2 = wormNoise.octaveNoise2D(
          x / (config.width * 0.06),
          y / (config.height * 0.06),
          octaves: 2,
          persistence: 0.4,
        );

        // Combine: either primary caves OR narrow worm tunnels.
        // Worm tunnels use a very narrow band around 0 for thin passages.
        final isWorm = n2.abs() < 0.04 * config.caveDensity;
        final isCave = n1 > threshold;

        // Depth factor: caves get slightly more common deeper underground.
        final depthFactor = ((y - heightmap[x]) / config.height).clamp(0.0, 1.0);
        final depthBonus = depthFactor * 0.05;

        if (isCave || (isWorm && depthFactor > 0.15)) {
          // Size limiter: reduce probability of very large openings.
          final adjacentEmpty = _countAdjacentEmpty(data, x, y);
          if (adjacentEmpty < 5 || (n1 > threshold + depthBonus + 0.08)) {
            data.set(x, y, El.empty);
          }
        }
      }
    }

    // Carve rounded bubble caverns for organic cave rooms.
    _carveBubbleCaverns(data, config, heightmap);

    // Multiple smoothing passes to clean up jagged edges and fill pockets.
    for (var pass = 0; pass < 3; pass++) {
      _smoothCaves(data, config, heightmap);
    }

    // For underground preset: carve dramatic cavern chambers.
    if (config.caveDensity >= 0.6 && config.vegetation <= 0.1) {
      _carveUndergroundCaverns(data, config, heightmap);
    }
  }

  /// Carve rounded bubble caverns using overlapping noise spheres.
  ///
  /// Creates 2-5 organic oval rooms connected to the existing tunnel
  /// network, giving caves a more natural feel than pure noise carving.
  static void _carveBubbleCaverns(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    if (config.caveDensity < 0.1) return;

    final rng = Random(config.seed + 1150);
    final bubbleNoise = SimplexNoise(config.seed + 1160);

    // Number of bubble caverns scales with cave density.
    final count = (2 + config.caveDensity * 5).round();

    for (var i = 0; i < count; i++) {
      final cx = (config.width * 0.1 + rng.nextDouble() * config.width * 0.8).round();
      final surfY = heightmap[cx.clamp(0, config.width - 1)];
      final minY = surfY + 10;
      final maxY = config.height - 10;
      if (minY >= maxY) continue;
      final cy = minY + rng.nextInt(maxY - minY);

      // Elliptical radius with aspect variation.
      final rx = 4 + rng.nextInt(6); // 4-9
      final ry = 3 + rng.nextInt(4); // 3-6

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
          // Noisy edge for organic shape.
          final edge = bubbleNoise.noise2D(nx / 5.0, ny / 5.0) * 0.15;
          if (dist < 0.80 + edge) {
            data.set(nx, ny, El.empty);
          }
        }
      }
    }
  }

  /// Carve large dramatic cavern chambers for the underground preset.
  /// Creates 4-7 large rooms with stalactites, stalagmites, lava lake,
  /// underground rivers, crystal formations, and mushroom growths.
  static void _carveUndergroundCaverns(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final rng = Random(config.seed + 1200);
    final cavernCount = 4 + rng.nextInt(4); // 4-7 caverns

    // Track cavern centers for connecting with underground rivers.
    final cavernCenters = <(int, int)>[];

    // Distribute caverns at multiple depth layers.
    for (var c = 0; c < cavernCount; c++) {
      final cx = (config.width * 0.08 + rng.nextDouble() * config.width * 0.84).round();
      final surfY = heightmap[cx.clamp(0, config.width - 1)];

      // Layer distribution: shallow (20-40%), mid (40-65%), deep (65-85%).
      double minFrac, maxFrac;
      if (c < 2) {
        minFrac = 0.20; maxFrac = 0.40; // shallow
      } else if (c < 5) {
        minFrac = 0.40; maxFrac = 0.65; // mid
      } else {
        minFrac = 0.65; maxFrac = 0.85; // deep
      }
      final minY = (surfY + (config.height - surfY) * minFrac).round().clamp(surfY + 10, config.height - 15);
      final maxY = (surfY + (config.height - surfY) * maxFrac).round().clamp(minY + 5, config.height - 12);
      if (minY >= maxY) continue;
      final cy = minY + rng.nextInt(maxY - minY);

      // Larger caverns than before.
      final radiusX = 12 + rng.nextInt(16); // 12-27 cells wide
      final radiusY = 6 + rng.nextInt(10);  // 6-15 cells tall

      cavernCenters.add((cx, cy));

      // Carve the ellipse with noisy edges.
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

      // Stalactites — denser, longer.
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

      // Stalagmites — taller, denser.
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
          // Place mushroom plant on cave floor.
          data.setPlant(mx, floorY, kPlantMushroom, kStMature);
          // Occasionally a second mushroom adjacent.
          if (rng.nextBool() && data.inBounds(mx + 1, floorY) &&
              data.get(mx + 1, floorY) == El.empty) {
            data.setPlant(mx + 1, floorY, kPlantMushroom, kStMature);
          }
        }
      }

      // Water pool at cavern floor (most caverns).
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
    // Find the deepest cavern and place a large lava pool.
    if (cavernCenters.isNotEmpty) {
      var deepestIdx = 0;
      for (var i = 1; i < cavernCenters.length; i++) {
        if (cavernCenters[i].$2 > cavernCenters[deepestIdx].$2) {
          deepestIdx = i;
        }
      }
      final (lavaCX, lavaCY) = cavernCenters[deepestIdx];
      // Lava lake: 15+ cells wide at the floor of the deepest cavern.
      final lavaWidth = 15 + rng.nextInt(10);
      final lavaDepth = 3 + rng.nextInt(3);
      for (var px = -lavaWidth ~/ 2; px <= lavaWidth ~/ 2; px++) {
        for (var pd = 0; pd < lavaDepth; pd++) {
          final lx = lavaCX + px;
          // Place lava below the cavern center.
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

    // --- Underground river connecting 2-3 chambers ---
    if (cavernCenters.length >= 2) {
      // Sort by x position and connect adjacent caverns.
      final sorted = List<(int, int)>.from(cavernCenters)
        ..sort((a, b) => a.$1.compareTo(b.$1));
      final connectCount = min(3, sorted.length - 1);
      for (var i = 0; i < connectCount; i++) {
        final (x1, y1) = sorted[i];
        final (x2, y2) = sorted[i + 1];
        // Carve a horizontal tunnel between them, filled with water.
        final steps = (x2 - x1).abs() + (y2 - y1).abs();
        if (steps == 0) continue;
        for (var t = 0; t <= steps; t++) {
          final frac = t / steps;
          final rx = (x1 + (x2 - x1) * frac).round();
          final ry = (y1 + (y2 - y1) * frac).round();
          // Carve 3 cells tall tunnel and fill with water.
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
          // Water at the bottom of the tunnel.
          if (data.inBounds(rx, ry + 1) && data.get(rx, ry + 1) == El.empty) {
            data.set(rx, ry + 1, El.water);
          }
          if (data.inBounds(rx, ry) && data.get(rx, ry) == El.empty) {
            data.set(rx, ry, El.water);
          }
        }
      }
    }

    // --- Crystal formations in deep stone (below 70% depth) ---
    final crystalMinY = (config.height * 0.70).round();
    final crystalNoise = SimplexNoise(config.seed + 1300);
    for (var y = crystalMinY; y < config.height - 5; y++) {
      for (var x = 0; x < config.width; x++) {
        if (data.get(x, y) != El.stone) continue;
        // Check if adjacent to a cave.
        bool nearCave = false;
        for (var dy = -1; dy <= 1 && !nearCave; dy++) {
          for (var dx = -1; dx <= 1 && !nearCave; dx++) {
            if (data.get(x + dx, y + dy) == El.empty) nearCave = true;
          }
        }
        if (!nearCave) continue;
        final n = crystalNoise.noise2D(x / 6.0, y / 6.0);
        if (n > 0.55 && rng.nextDouble() < 0.3) {
          // Alternate between glass (crystal) and ice formations.
          data.set(x, y, rng.nextBool() ? El.glass : El.ice);
          if (data.get(x, y) == El.ice) {
            data.setTemp(x, y, 20);
          }
        }
      }
    }
  }

  /// Count empty neighbors (8-connected).
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

  /// Cellular automata smoothing: remove isolated stone, fill tiny holes.
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
        // Remove isolated stone pillars (surrounded by mostly empty).
        if (current == El.stone && stoneCount <= 2) {
          data.set(x, y, El.empty);
        }
        // Fill small isolated pockets (surrounded by mostly stone).
        if (current == El.empty && stoneCount >= 6) {
          data.set(x, y, El.stone);
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Water placement
  // --------------------------------------------------------------------------

  /// Fill terrain depressions with water and place small underground pools.
  ///
  /// Surface water is placed by finding local valleys/depressions in the
  /// heightmap rather than using a flat global water line.
  /// Meadow preset also gets thin streams connecting ponds.
  static void placeWater(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    if (config.waterLevel <= 0) return;

    // --- Surface water: fill depressions ---
    _fillDepressions(data, config, heightmap);

    // --- Meadow: thin streams connecting low points ---
    if (config.vegetation >= 0.8 && config.terrainScale < 1.0) {
      _placeMeadowStreams(data, config, heightmap);
    }

    // --- Underground pools: water collects at cave floors ---
    final rng = Random(config.seed + 2000);
    for (var x = 2; x < config.width - 2; x++) {
      for (var y = config.height - 6; y > heightmap[x] + 12; y--) {
        // Look for cave floor (empty above stone).
        if (data.get(x, y) == El.empty && data.get(x, y + 1) == El.stone) {
          // Higher probability, scaled by water level.
          if (rng.nextDouble() < config.waterLevel * 0.30) {
            // Scan the floor width to fill naturally.
            int left = x, right = x;
            while (left > 0 && data.get(left - 1, y) == El.empty &&
                   data.get(left - 1, y + 1) == El.stone) {
              left--;
            }
            while (right < config.width - 1 && data.get(right + 1, y) == El.empty &&
                   data.get(right + 1, y + 1) == El.stone) {
              right++;
            }
            // Limit pool width to something reasonable.
            final maxW = 2 + rng.nextInt(5);
            final poolLeft = max(left, x - maxW);
            final poolRight = min(right, x + maxW);
            final poolDepth = 1 + rng.nextInt(2);
            for (var px = poolLeft; px <= poolRight; px++) {
              for (var py = 0; py < poolDepth; py++) {
                final wy = y - py;
                if (data.inBounds(px, wy) && data.get(px, wy) == El.empty) {
                  data.set(px, wy, El.water);
                }
              }
            }
            x = poolRight + 3; // Skip ahead.
            break;
          }
        }
      }
    }
  }

  /// Fill heightmap depressions with water for natural ponds/lakes.
  static void _fillDepressions(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    // For each local minimum, flood-fill water up to the spillover point.
    final waterFilled = List<bool>.filled(config.width, false);

    for (var x = 1; x < config.width - 1; x++) {
      if (waterFilled[x]) continue;

      // Check if this is lower than both neighbors (valley).
      final h = heightmap[x];
      bool isDepression = false;

      // Look for a depression: find the left and right ridges.
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

      // Depression: current height is lower than ridges on both sides.
      final ridgeHeight = min(leftRidge, rightRidge);
      if (ridgeHeight < h - 1) {
        isDepression = true;
      }

      if (!isDepression) continue;

      // Water level fills to the spillover point (lower ridge).
      final waterSurface = ridgeHeight;

      // Only fill if the depression is deep enough.
      if (h - waterSurface < 2) continue;

      // Scale by waterLevel config — not all depressions get water.
      final rng = Random(config.seed + x);
      if (rng.nextDouble() > config.waterLevel * 0.8) continue;

      // Fill the depression with water.
      for (var fx = 0; fx < config.width; fx++) {
        if (heightmap[fx] >= waterSurface) continue;
        for (var fy = waterSurface; fy < heightmap[fx]; fy--) {
          if (fy < 0) break;
          if (data.get(fx, fy) == El.empty) {
            data.set(fx, fy, El.water);
            waterFilled[fx] = true;
          }
        }
      }
    }

    // Fallback: use a global water line for the lowest valleys if waterLevel
    // is high enough to warrant significant water coverage.
    if (config.waterLevel >= 0.3) {
      final sortedHeights = List<int>.from(heightmap)..sort();
      // Water line at a percentile based on waterLevel.
      final pct = (1.0 - config.waterLevel * 0.35)
          .clamp(0.0, 1.0);
      final waterLineIdx =
          (sortedHeights.length * pct).round().clamp(0, sortedHeights.length - 1);
      final waterLine = sortedHeights[waterLineIdx];

      for (var x = 0; x < config.width; x++) {
        for (var y = waterLine; y < config.height; y++) {
          if (y >= heightmap[x]) break;
          if (data.get(x, y) == El.empty) {
            data.set(x, y, El.water);
          }
        }
      }
    }
  }

  /// Place thin streams connecting low terrain points for meadow.
  static void _placeMeadowStreams(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final rng = Random(config.seed + 2500);
    // Find 2-3 low points to connect with streams.
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

    // Connect pairs of low points with thin water streams.
    for (var i = 0; i < lowPoints.length - 1 && i < 3; i++) {
      if (rng.nextDouble() > 0.5) continue;
      final x1 = lowPoints[i];
      final x2 = lowPoints[i + 1];
      for (var x = min(x1, x2); x <= max(x1, x2); x++) {
        final surfY = heightmap[x];
        // Place 1 cell of water just at the surface in low spots.
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

  /// Fill the ocean around an island landmass.
  /// Creates deep water, sand beaches (3-5 cells), underwater sand/dirt floor.
  static void fillIslandOcean(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final waterLine = (config.height * 0.55).round();

    for (var x = 0; x < config.width; x++) {
      final surface = heightmap[x];

      // Fill empty space below water line with water (ocean).
      for (var y = waterLine; y < config.height - 5; y++) {
        if (data.get(x, y) == El.empty) {
          data.set(x, y, El.water);
        }
      }

      // Also fill sky gaps between surface and water line at island edges.
      if (surface > waterLine) {
        for (var y = waterLine; y < surface; y++) {
          if (data.get(x, y) == El.empty) {
            data.set(x, y, El.water);
          }
        }
      }

      // Beach sand: where terrain meets the water line, 3-5 cells deep.
      if (surface >= waterLine - 6 && surface <= waterLine + 3) {
        // This is the shoreline — make it sandy (3-5 cells).
        for (var dy = -3; dy <= 5; dy++) {
          final by = surface + dy;
          if (data.inBounds(x, by) && data.get(x, by) == El.dirt) {
            data.set(x, by, El.sand);
          }
        }
      }

      // Underwater ocean floor: sand layer on top of dirt/stone.
      if (surface > waterLine + 3) {
        // Replace top 2-3 cells of underwater terrain with sand.
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

  /// Place canyon-specific features: river at floor, cliff-face caves,
  /// exposed stone layers, and sandy bottom near the river.
  static void placeCanyonFeatures(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final rng = Random(config.seed + 9000);
    final center = config.width ~/ 2;
    final canyonWidth = (config.width * 0.30).round();

    // --- Find the canyon floor (deepest point) ---
    int floorY = 0;
    for (var x = center - canyonWidth; x < center + canyonWidth; x++) {
      if (x >= 0 && x < config.width && heightmap[x] > floorY) {
        floorY = heightmap[x];
      }
    }

    // --- River at canyon bottom ---
    for (var x = center - canyonWidth + 5; x < center + canyonWidth - 5; x++) {
      if (x < 0 || x >= config.width) continue;
      final h = heightmap[x];
      // River where terrain is in the bottom 20% of the canyon.
      if (h > floorY - (config.height * 0.08).round()) {
        // Fill 2-4 cells of water above the canyon floor.
        for (var dy = 0; dy < 3; dy++) {
          final wy = h - 1 - dy;
          if (wy > 0 && data.get(x, wy) == El.empty) {
            data.set(x, wy, El.water);
          }
        }
        // Sandy bottom near river.
        for (var sd = 0; sd < 3; sd++) {
          if (data.inBounds(x, h + sd) && data.get(x, h + sd) == El.dirt) {
            data.set(x, h + sd, El.sand);
          }
        }
      }
    }

    // --- Cliff-face caves (small alcoves in the walls) ---
    for (var attempt = 0; attempt < 6; attempt++) {
      // Pick a spot on one of the cliff walls.
      final side = rng.nextBool() ? -1 : 1;
      final wallX = center + side * (canyonWidth ~/ 2 + rng.nextInt(canyonWidth ~/ 3));
      if (wallX < 3 || wallX >= config.width - 3) continue;

      final surfY = heightmap[wallX.clamp(0, config.width - 1)];
      final caveY = surfY + 5 + rng.nextInt(15);
      if (caveY >= config.height - 10) continue;

      // Carve a small cave (4-8 wide, 3-5 tall).
      final caveW = 4 + rng.nextInt(5);
      final caveH = 3 + rng.nextInt(3);
      for (var dy = -caveH ~/ 2; dy <= caveH ~/ 2; dy++) {
        for (var dx = 0; dx < caveW; dx++) {
          final nx = wallX + dx * -side; // Carve into the wall.
          final ny = caveY + dy;
          if (data.inBounds(nx, ny) && data.get(nx, ny) == El.stone) {
            data.set(nx, ny, El.empty);
          }
        }
      }
    }

    // --- Expose stone at cliff surfaces (thin dirt on walls) ---
    for (var x = center - canyonWidth; x < center + canyonWidth; x++) {
      if (x < 0 || x >= config.width) continue;
      final surfY = heightmap[x];
      // Where terrain is steep (big height differences), expose stone.
      if (x > 0 && x < config.width - 1) {
        final slopeL = (heightmap[x] - heightmap[x - 1]).abs();
        final slopeR = (heightmap[x] - heightmap[(x + 1).clamp(0, config.width - 1)]).abs();
        if (slopeL > 2 || slopeR > 2) {
          // Replace top dirt cells with stone for exposed cliff face.
          for (var dy = 0; dy < 3; dy++) {
            if (data.inBounds(x, surfY + dy) && data.get(x, surfY + dy) == El.dirt) {
              data.set(x, surfY + dy, El.stone);
            }
          }
        }
      }
    }

    // --- 1-2 waterfalls from cliff ledges ---
    int waterfallsPlaced = 0;
    for (var x = center - canyonWidth; x < center + canyonWidth && waterfallsPlaced < 2; x++) {
      if (x < 2 || x >= config.width - 2) continue;
      final h = heightmap[x];
      final nextH = heightmap[(x + 1).clamp(0, config.width - 1)];
      if ((nextH - h).abs() > 8 && rng.nextDouble() < 0.3) {
        // Place water source at the cliff edge.
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

  /// Place water sources at significant elevation drops.
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

  /// Place snow on the highest peaks (top 10% of terrain).
  /// Skips meadow (warm) and underground presets.
  static void placeSnow(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    // No snow on gentle terrain, meadow (warm), or underground.
    if (config.terrainScale <= 1.0) return;
    if (config.vegetation >= 0.8) return; // Meadow — warm feel.

    // Find elevation range.
    int minH = config.height;
    int maxH = 0;
    for (final h in heightmap) {
      if (h < minH) minH = h;
      if (h > maxH) maxH = h;
    }

    final range = maxH - minH;
    if (range <= 5) return;

    // Snow line: only the top 10% of the terrain range.
    final snowLine = minH + (range * 0.10).round();

    for (var x = 0; x < config.width; x++) {
      if (heightmap[x] > snowLine) continue;

      final surfaceY = heightmap[x];
      if (data.get(x, surfaceY) == El.dirt) {
        data.set(x, surfaceY, El.snow);
      }
      // Snow cap above surface.
      if (surfaceY > 0 && data.get(x, surfaceY - 1) == El.empty) {
        data.set(x, surfaceY - 1, El.snow);
      }
    }
  }

  // --------------------------------------------------------------------------
  // Lava pockets
  // --------------------------------------------------------------------------

  /// Place lava pockets deep underground.
  /// Meadow gets none. Underground gets larger pools handled separately.
  static void placeLava(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    // Meadow — warm and safe, no lava.
    if (config.vegetation >= 0.8 && config.terrainScale < 1.0) return;

    final rng = Random(config.seed + 7000);
    final lavaNoise = SimplexNoise(config.seed + 7000);

    final lavaMinY = (config.height * 0.7).round();

    for (var y = lavaMinY; y < config.height - 5; y++) {
      for (var x = 0; x < config.width; x++) {
        if (data.get(x, y) != El.stone) continue;

        final n = lavaNoise.octaveNoise2D(
          x / (config.width * 0.08),
          y / (config.height * 0.08),
          octaves: 2,
        );

        if (n > 0.65 && rng.nextDouble() < 0.5) {
          data.set(x, y, El.lava);
          data.setTemp(x, y, 250);
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Ore veins
  // --------------------------------------------------------------------------

  /// Place metal ore deposits as elongated veins in stone layers.
  ///
  /// Uses anisotropic noise sampling (stretched horizontally) to create
  /// vein-like streaks rather than round blobs. Deeper stone has denser ore.
  /// Underground preset gets significantly more veins.
  static void placeOre(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final rng = Random(config.seed + 3000);
    final oreNoise = SimplexNoise(config.seed + 3000);
    final veinAngle = SimplexNoise(config.seed + 3100);

    // Underground preset gets more ore.
    final isUnderground = config.caveDensity >= 0.6 && config.vegetation <= 0.1;
    final oreThreshold = isUnderground ? 0.52 : 0.68;
    final oreProbability = isUnderground ? 0.80 : 0.65;
    final minDepthBelow = isUnderground ? 10 : 20;

    for (var y = 0; y < config.height; y++) {
      for (var x = 0; x < config.width; x++) {
        if (data.get(x, y) != El.stone) continue;
        if (y < heightmap[x] + minDepthBelow) continue;

        // Anisotropic sampling: stretch along a noise-driven angle
        // to produce elongated vein shapes instead of round blobs.
        final angle = veinAngle.noise2D(x / 40.0, y / 40.0) * 1.2;
        final cosA = cos(angle);
        final sinA = sin(angle);
        // Rotate and stretch: 3x compression along one axis.
        final sx = (x * cosA - y * sinA) / (config.width * 0.04);
        final sy = (x * sinA + y * cosA) / (config.height * 0.12);

        final n = oreNoise.octaveNoise2D(sx, sy, octaves: 2);

        // Deeper ore is slightly more common.
        final depthFrac = ((y - heightmap[x.clamp(0, config.width - 1)]) /
                config.height)
            .clamp(0.0, 1.0);
        final depthBonus = depthFrac * 0.06;

        if (n > oreThreshold - depthBonus && rng.nextDouble() < oreProbability) {
          data.set(x, y, El.metal);
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Surface detail: sand, boulders, grass
  // --------------------------------------------------------------------------

  /// Place surface details: sand near water, boulders, grass on dirt,
  /// and cliff overhangs at steep elevation changes.
  static void placeSurfaceDetail(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    // --- Cliff overhangs at steep drops ---
    _placeCliffOverhangs(data, config, heightmap);

    final rng = Random(config.seed + 8000);
    final boulderNoise = SimplexNoise(config.seed + 8100);

    for (var x = 1; x < config.width - 1; x++) {
      final surfaceY = heightmap[x];
      if (surfaceY <= 1 || surfaceY >= config.height - 5) continue;
      if (data.get(x, surfaceY) != El.dirt) continue;

      // --- Sand near water edges (beaches) ---
      bool nearWater = false;
      for (var dx = -4; dx <= 4 && !nearWater; dx++) {
        for (var dy = -3; dy <= 3 && !nearWater; dy++) {
          if (data.get(x + dx, surfaceY + dy) == El.water) {
            nearWater = true;
          }
        }
      }
      if (nearWater && rng.nextDouble() < 0.7) {
        // Replace top dirt with sand for beach effect.
        data.set(x, surfaceY, El.sand);
        if (data.get(x, surfaceY + 1) == El.dirt && rng.nextDouble() < 0.4) {
          data.set(x, surfaceY + 1, El.sand);
        }
        continue; // No grass or boulders on sand.
      }

      // --- Occasional surface boulders ---
      final bn = boulderNoise.noise2D(x / 15.0, surfaceY / 15.0);
      if (bn > 0.7 && rng.nextDouble() < 0.15) {
        // Place 1-3 stone cells on surface.
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
        x += boulderSize; // Skip past boulder.
        continue;
      }

      // --- Grass on most dirt surfaces ---
      if (data.get(x, surfaceY - 1) == El.empty) {
        // Higher probability for meadow-like configs (vegetation >= 0.8).
        final grassChance = config.vegetation >= 0.8 ? 0.92 : 0.75;
        if (rng.nextDouble() < grassChance) {
          data.setPlant(x, surfaceY - 1, kPlantGrass, kStMature);
        }
      }
    }
  }

  /// Carve small overhangs into steep cliff faces for visual interest.
  ///
  /// Where the heightmap drops sharply (>4 cells between neighbors),
  /// carve a small shelf into the cliff face to create a natural overhang.
  static void _placeCliffOverhangs(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final rng = Random(config.seed + 8200);

    for (var x = 2; x < config.width - 2; x++) {
      final h = heightmap[x];
      final hNext = heightmap[x + 1];
      final drop = hNext - h; // positive = terrain drops right

      if (drop.abs() < 5) continue;
      if (rng.nextDouble() > 0.4) continue;

      // Carve a small shelf (2-4 wide, 1-2 tall) at the cliff face.
      final shelfWidth = 2 + rng.nextInt(3);
      final dir = drop > 0 ? 1 : -1;
      final shelfY = h + (drop.abs() ~/ 3);

      for (var dx = 0; dx < shelfWidth; dx++) {
        final sx = x + dx * dir;
        if (!data.inBounds(sx, shelfY)) continue;
        if (data.get(sx, shelfY) == El.stone || data.get(sx, shelfY) == El.dirt) {
          data.set(sx, shelfY, El.empty);
          // Also carve the cell above for a taller overhang.
          if (data.inBounds(sx, shelfY - 1) &&
              data.get(sx, shelfY - 1) == El.stone) {
            data.set(sx, shelfY - 1, El.empty);
          }
        }
      }
      x += shelfWidth + 2; // Skip past the overhang.
    }
  }

  // --------------------------------------------------------------------------
  // Vegetation & trees
  // --------------------------------------------------------------------------

  /// Place seeds and pre-grown trees using noise-based clustering.
  ///
  /// Trees cluster together in groves (5-8 trees) rather than being
  /// randomly scattered. Meadow gets flowers. No plants in caves or underwater.
  static void placeVegetation(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    if (config.vegetation <= 0) return;

    final rng = Random(config.seed + 4000);
    final clusterNoise = SimplexNoise(config.seed + 4100);
    final flowerNoise = SimplexNoise(config.seed + 4200);

    // Meadow detection: high vegetation, low terrain scale.
    final isMeadow = config.vegetation >= 0.8 && config.terrainScale < 1.0;

    for (var x = 2; x < config.width - 2; x++) {
      final surfaceY = heightmap[x];
      if (surfaceY <= 3 || surfaceY >= config.height - 5) continue;

      // Skip if surface is not dirt (could be sand, snow, etc.).
      final surfaceEl = data.get(x, surfaceY);
      if (surfaceEl != El.dirt) continue;

      // Must have empty space above for plants.
      if (data.get(x, surfaceY - 1) != El.empty) continue;

      // --- Cluster density from noise ---
      final density = clusterNoise.noise2D(x / 15.0, 0.0);
      final clusterFactor = ((density + 1.0) * 0.5).clamp(0.0, 1.0);

      // Check moisture: water within 8 cells.
      bool moist = false;
      for (var dx = -8; dx <= 8 && !moist; dx++) {
        for (var dy = -4; dy <= 4 && !moist; dy++) {
          if (data.get(x + dx, surfaceY + dy) == El.water) {
            moist = true;
          }
        }
      }

      // Base chance depends on vegetation config + cluster density.
      final baseChance = config.vegetation * clusterFactor;
      final chance = moist ? baseChance * 0.7 : baseChance * 0.30;

      if (rng.nextDouble() < chance) {
        // In high-density clusters, place tree groves (5-8 trees).
        if (clusterFactor > 0.45 && rng.nextDouble() < 0.45) {
          // Place a grove: multiple trees in sequence.
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

      // Meadow flowers: occasional flower seeds between trees.
      if (isMeadow && data.get(x, surfaceY - 1) == El.empty) {
        final fn = flowerNoise.noise2D(x / 10.0, 0.5);
        if (fn > 0.3 && rng.nextDouble() < 0.15) {
          data.setPlant(x, surfaceY - 1, kPlantFlower, kStMature);
        }
      }
    }
  }

  /// Place a pre-grown tree: wood trunk + plant canopy.
  static void _placeTree(GridData data, int x, int surfaceY, Random rng) {
    final trunkHeight = 3 + rng.nextInt(4); // 3-6 cells tall

    // Embed trunk base INTO the ground — replace surface dirt with wood.
    data.set(x, surfaceY, El.wood);

    // Build trunk upward from surface.
    for (var i = 1; i <= trunkHeight; i++) {
      final ty = surfaceY - i;
      if (ty < 1) break;
      if (data.get(x, ty) != El.empty) break;
      data.set(x, ty, El.wood);
    }

    // Roots — extend 2-4 cells into the dirt below the trunk.
    final rootDepth = 2 + rng.nextInt(3);
    for (var i = 1; i <= rootDepth; i++) {
      final ry = surfaceY + i;
      if (!data.inBounds(x, ry)) break;
      final below = data.get(x, ry);
      if (below == El.dirt) {
        data.set(x, ry, El.wood);
      } else {
        break; // Stop at stone or other non-dirt
      }
    }
    // Side roots spread diagonally through dirt.
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

    // Place plant (canopy) around the top of the trunk.
    final topY = surfaceY - trunkHeight;
    if (topY < 2) return;

    final canopyRadius = 1 + rng.nextInt(2);
    for (var dy = -canopyRadius; dy <= 0; dy++) {
      for (var dx = -canopyRadius; dx <= canopyRadius; dx++) {
        if (dx == 0 && dy == 0) continue;
        final px = x + dx;
        final py = topY + dy;
        if (data.inBounds(px, py) && data.get(px, py) == El.empty) {
          data.setPlant(px, py, kPlantTree, kStMature);
        }
      }
    }
    // Crown directly above trunk.
    if (data.inBounds(x, topY - 1) && data.get(x, topY - 1) == El.empty) {
      data.setPlant(x, topY - 1, kPlantTree, kStMature);
    }
  }

  // --------------------------------------------------------------------------
  // Ant colonies
  // --------------------------------------------------------------------------

  /// Find sheltered alcoves and place ant colony starter positions.
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
