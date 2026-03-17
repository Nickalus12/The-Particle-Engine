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

    // Multiple smoothing passes to clean up jagged edges and fill pockets.
    for (var pass = 0; pass < 3; pass++) {
      _smoothCaves(data, config, heightmap);
    }

    // For underground preset: carve dramatic cavern chambers.
    if (config.caveDensity >= 0.6 && config.vegetation <= 0.1) {
      _carveUndergroundCaverns(data, config, heightmap);
    }
  }

  /// Carve large dramatic cavern chambers for the underground preset.
  /// Creates 3-6 large rooms connected by the existing tunnel network.
  static void _carveUndergroundCaverns(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final rng = Random(config.seed + 1200);
    final cavernCount = 3 + rng.nextInt(4); // 3-6 caverns

    for (var c = 0; c < cavernCount; c++) {
      // Pick a random position in the stone area (below surface, above bedrock).
      final cx = (config.width * 0.1 + rng.nextDouble() * config.width * 0.8).round();
      final minY = (heightmap[cx.clamp(0, config.width - 1)] + 15).clamp(0, config.height);
      final maxY = config.height - 15;
      if (minY >= maxY) continue;
      final cy = minY + rng.nextInt(maxY - minY);

      // Cavern size — elliptical chamber.
      final radiusX = 8 + rng.nextInt(12); // 8-19 cells wide
      final radiusY = 5 + rng.nextInt(8);  // 5-12 cells tall

      // Carve the ellipse.
      for (var dy = -radiusY; dy <= radiusY; dy++) {
        for (var dx = -radiusX; dx <= radiusX; dx++) {
          final nx = cx + dx;
          final ny = cy + dy;
          if (!data.inBounds(nx, ny)) continue;
          if (ny >= config.height - 5) continue; // Don't break bedrock.
          if (ny <= heightmap[nx.clamp(0, config.width - 1)] + 3) continue; // Don't break surface.

          // Ellipse check with slight noise for organic shape.
          final ex = dx.toDouble() / radiusX;
          final ey = dy.toDouble() / radiusY;
          final dist = ex * ex + ey * ey;

          // Noisy edge for organic cavern walls.
          final edgeNoise = ((nx * 7 + ny * 13) % 5) * 0.04;
          if (dist < 0.85 + edgeNoise) {
            data.set(nx, ny, El.empty);
          }
        }
      }

      // Add stalactites hanging from the ceiling.
      for (var sx = cx - radiusX + 2; sx < cx + radiusX - 2; sx += 2 + rng.nextInt(3)) {
        if (!data.inBounds(sx, cy - radiusY)) continue;
        final stalLen = 2 + rng.nextInt(4);
        for (var sy = 0; sy < stalLen; sy++) {
          final ty = cy - radiusY + sy + 1;
          if (data.inBounds(sx, ty) && data.get(sx, ty) == El.empty) {
            data.set(sx, ty, El.stone);
          }
        }
      }

      // Add stalagmites rising from the floor.
      for (var sx = cx - radiusX + 3; sx < cx + radiusX - 3; sx += 3 + rng.nextInt(3)) {
        if (!data.inBounds(sx, cy + radiusY)) continue;
        final stagLen = 1 + rng.nextInt(3);
        for (var sy = 0; sy < stagLen; sy++) {
          final ty = cy + radiusY - sy - 1;
          if (data.inBounds(sx, ty) && data.get(sx, ty) == El.empty) {
            data.set(sx, ty, El.stone);
          }
        }
      }

      // Small water pool at cavern floor.
      if (rng.nextDouble() < 0.6) {
        final poolWidth = 3 + rng.nextInt(radiusX ~/ 2);
        for (var px = -poolWidth; px <= poolWidth; px++) {
          final wx = cx + px;
          final floorY = cy + radiusY - 1;
          if (data.inBounds(wx, floorY) && data.get(wx, floorY) == El.empty) {
            data.set(wx, floorY, El.water);
          }
          if (data.inBounds(wx, floorY - 1) && data.get(wx, floorY - 1) == El.empty && px.abs() < poolWidth - 1) {
            data.set(wx, floorY - 1, El.water);
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
  static void placeWater(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    if (config.waterLevel <= 0) return;

    // --- Surface water: fill depressions ---
    // Find local minima and fill up to the lowest neighboring ridge.
    _fillDepressions(data, config, heightmap);

    // --- Underground pools: small pools at cave floors ---
    final rng = Random(config.seed + 2000);
    for (var x = 2; x < config.width - 2; x++) {
      for (var y = config.height - 6; y > heightmap[x] + 12; y--) {
        // Look for cave floor (empty above stone).
        if (data.get(x, y) == El.empty && data.get(x, y + 1) == El.stone) {
          // Low probability, scaled by water level.
          if (rng.nextDouble() < config.waterLevel * 0.15) {
            // Fill a small puddle (1-3 cells deep, 2-5 cells wide).
            final poolWidth = 1 + rng.nextInt(3);
            final poolDepth = 1 + rng.nextInt(2);
            for (var px = -poolWidth; px <= poolWidth; px++) {
              for (var py = 0; py < poolDepth; py++) {
                final wx = x + px;
                final wy = y - py;
                if (data.get(wx, wy) == El.empty) {
                  data.set(wx, wy, El.water);
                }
              }
            }
            x += poolWidth + 3; // Skip ahead.
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

  // --------------------------------------------------------------------------
  // Island ocean fill
  // --------------------------------------------------------------------------

  /// Fill the ocean around an island landmass.
  /// Creates water at a fixed water line, adds sand beaches at the shoreline.
  static void fillIslandOcean(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final waterLine = (config.height * 0.65).round();

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

      // Beach sand: where terrain meets the water line, replace dirt with sand.
      if (surface >= waterLine - 4 && surface <= waterLine + 2) {
        // This is the shoreline — make it sandy.
        for (var dy = -2; dy <= 3; dy++) {
          final by = surface + dy;
          if (data.inBounds(x, by) && data.get(x, by) == El.dirt) {
            data.set(x, by, El.sand);
          }
        }
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
  static void placeSnow(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    // Snow on any world with significant terrain, not just terrainScale > 1.5.
    if (config.terrainScale <= 1.0) return;

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
  static void placeLava(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
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
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Ore veins
  // --------------------------------------------------------------------------

  /// Place metal ore deposits as clustered pockets in stone layers.
  static void placeOre(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    final rng = Random(config.seed + 3000);
    final oreNoise = SimplexNoise(config.seed + 3000);

    for (var y = 0; y < config.height; y++) {
      for (var x = 0; x < config.width; x++) {
        if (data.get(x, y) != El.stone) continue;
        if (y < heightmap[x] + 20) continue;

        final n = oreNoise.octaveNoise2D(
          x / (config.width * 0.05),
          y / (config.height * 0.05),
          octaves: 2,
        );

        if (n > 0.7 && rng.nextDouble() < 0.6) {
          data.set(x, y, El.metal);
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Surface detail: sand, boulders, grass
  // --------------------------------------------------------------------------

  /// Place surface details: sand near water, boulders, grass on dirt.
  static void placeSurfaceDetail(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
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
        // High probability of grass on exposed dirt.
        if (rng.nextDouble() < 0.75) {
          data.setPlant(x, surfaceY - 1, kPlantGrass, kStMature);
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Vegetation & trees
  // --------------------------------------------------------------------------

  /// Place seeds and pre-grown trees using noise-based clustering.
  ///
  /// Trees cluster together in groves rather than being randomly scattered.
  /// No plants in caves or underwater.
  static void placeVegetation(
    GridData data,
    WorldConfig config,
    List<int> heightmap,
  ) {
    if (config.vegetation <= 0) return;

    final rng = Random(config.seed + 4000);
    final clusterNoise = SimplexNoise(config.seed + 4100);

    for (var x = 2; x < config.width - 2; x++) {
      final surfaceY = heightmap[x];
      if (surfaceY <= 3 || surfaceY >= config.height - 5) continue;

      // Skip if surface is not dirt (could be sand, snow, etc.).
      final surfaceEl = data.get(x, surfaceY);
      if (surfaceEl != El.dirt) continue;

      // Must have empty space above for plants.
      if (data.get(x, surfaceY - 1) != El.empty) continue;

      // --- Cluster density from noise ---
      final density = clusterNoise.noise2D(x / 20.0, 0.0);
      // density in [-1, 1]; map to [0, 1] for probability scaling.
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
      final chance = moist ? baseChance * 0.7 : baseChance * 0.25;

      if (rng.nextDouble() < chance) {
        // 35% chance of a pre-grown tree in dense clusters, otherwise a seed.
        if (clusterFactor > 0.5 && rng.nextDouble() < 0.35) {
          _placeTree(data, x, surfaceY, rng);
          x += 2; // Trees need spacing.
        } else {
          // Place seed, more seeds near water.
          data.set(x, surfaceY - 1, El.seed);
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
