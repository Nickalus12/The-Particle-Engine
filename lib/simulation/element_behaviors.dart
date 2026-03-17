import 'dart:typed_data';

import 'element_registry.dart';
import 'reactions/reaction_registry.dart';
import 'simulation_engine.dart';

// ---------------------------------------------------------------------------
// Element Behaviors -- Per-element simulation methods (extension on engine)
// Includes ant colony AI (pheromone system, bridge building, etc.)
// ---------------------------------------------------------------------------

/// Ant bridge state encoded in flags: bit 0x01 = bridge ant, bit 0x02 = alarmed.
const int _antBridgeFlag = 0x01;
const int _antAlarmFlag = 0x02;

/// Extension on [SimulationEngine] providing all 24 element behaviors.
extension ElementBehaviors on SimulationEngine {

  // =========================================================================
  // Sand
  // =========================================================================

  void simSand(int x, int y, int idx) {
    // Temperature-driven state change (sand melts to glass at high temp)
    if (checkTemperatureReaction(x, y, idx, El.sand)) return;

    if (checkAdjacent(x, y, El.lightning)) {
      grid[idx] = El.glass;
      life[idx] = 0;
      markProcessed(idx);
      queueReactionFlash(x, y, 200, 230, 255, 4);
      return;
    }
    if (checkAdjacent(x, y, El.water)) {
      grid[idx] = El.mud;
      removeOneAdjacent(x, y, El.water);
      markProcessed(idx);
      return;
    }
    // Porosity-based moisture absorption: sand near water darkens slightly
    final sandPorosity = elementPorosity[El.sand];
    if (sandPorosity > 0 && checkAdjacent(x, y, El.water)) {
      if (rng.nextInt(255) < sandPorosity ~/ 4) {
        life[idx] = (life[idx] + 1).clamp(0, 3); // slight moisture
      }
    }
    fallGranular(x, y, idx, El.sand);
    if (grid[idx] == El.sand && rng.nextInt(3) == 0) {
      _avalancheGranular(x, y, idx);
    }
  }

  // =========================================================================
  // Water
  // =========================================================================

  void simWater(int x, int y, int idx) {
    // Temperature-driven state changes (boil->steam, freeze->ice)
    if (checkTemperatureReaction(x, y, idx, El.water)) return;

    final g = gravityDir;
    final by = y + g;
    final uy = y - g;

    final lifeVal = life[idx];
    final bool isSpecialState = lifeVal >= 140;
    int mass = isSpecialState ? 100 : (lifeVal < 20 ? 100 : lifeVal);
    if (!isSpecialState && lifeVal < 20) {
      life[idx] = 100;
    }

    // Freeze near ice (legacy — kept as supplement to temperature system)
    if (rng.nextInt(60) == 0 && checkAdjacent(x, y, El.ice)) {
      grid[idx] = El.ice;
      markProcessed(idx);
      return;
    }

    // Evaporation near heat (legacy — kept as supplement to temperature system)
    final evapChance = isNight ? 30 : 15;
    if (rng.nextInt(evapChance) == 0) {
      for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final neighbor = grid[ny * gridW + nx];
          if (neighbor == El.fire || neighbor == El.lava) {
            grid[idx] = El.steam;
            life[idx] = 0;
            markProcessed(idx);
            return;
          }
        }
      }
    }

    // Surface evaporation (water cycle): surface water slowly evaporates
    // Surface = no water directly above, sky/empty above.
    {
      final aboveY = y - g;
      final isSurface = !inBoundsY(aboveY) ||
          (grid[aboveY * gridW + x] != El.water);
      if (isSurface) {
        // Check temperature for accelerated evaporation
        final temp = temperature[idx];
        final evapRate = temp > 150
            ? 60   // Near fire/lava: fast evaporation
            : (isNight ? 400 : 200); // Normal: slow, slower at night
        if (rng.nextInt(evapRate) == 0) {
          grid[idx] = El.steam;
          life[idx] = 0;
          markProcessed(idx);
          return;
        }
      }
    }

    // Density-based displacement: water sinks through lighter liquids (oil)
    if (tryDensityDisplace(x, y, idx, El.water)) return;

    // Neighbor reactions
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = wrapX(x + dx);
        final ny = y + dy;
        if (!inBoundsY(ny)) continue;
        final ni = ny * gridW + nx;
        final neighbor = grid[ni];
        if (neighbor == El.tnt && rng.nextInt(10) == 0) {
          grid[ni] = El.sand;
          life[ni] = 0;
          markProcessed(ni);
        }
        if (neighbor == El.smoke && rng.nextInt(10) == 0) {
          grid[ni] = El.empty;
          life[ni] = 0;
          markProcessed(ni);
        }
        if (neighbor == El.rainbow && rng.nextInt(40) == 0) {
          final rx = wrapX(x + rng.nextInt(3) - 1);
          final ry = uy;
          if (inBoundsY(ry) && grid[ry * gridW + rx] == El.empty) {
            grid[ry * gridW + rx] = El.rainbow;
            life[ry * gridW + rx] = 0;
            markProcessed(ry * gridW + rx);
          }
        }
        if (neighbor == El.plant && rng.nextInt(20) == 0) {
          if (life[ni] > 2) life[ni] -= 2;
        }
      }
    }

    // Use pressure grid (updated every 4 frames)
    final cellPressure = pressure[idx];
    int colAbove = 0;
    for (int cy = y - g; inBoundsY(cy) && colAbove < 12; cy -= g) {
      final c = grid[cy * gridW + x];
      if (c == El.water || c == El.oil) {
        colAbove++;
      } else {
        break;
      }
    }
    final totalCol = cellPressure + colAbove;

    // Pressure-based mass compression
    if (!isSpecialState) {
      final targetMass = (100 + (cellPressure * 2).clamp(0, 39)).clamp(20, 139);
      if (mass < targetMass) {
        mass = (mass + 3).clamp(20, 139);
      } else if (mass > targetMass) {
        mass = (mass - 3).clamp(20, 139);
      }
      life[idx] = mass;
    }

    // Bubble generation
    if (mass > 130 && rng.nextInt(500) == 0) {
      final bubbleY = y - g;
      if (inBoundsY(bubbleY)) {
        final bubbleIdx = bubbleY * gridW + x;
        if (grid[bubbleIdx] == El.water) {
          grid[bubbleIdx] = El.bubble;
          life[bubbleIdx] = 0;
          markProcessed(bubbleIdx);
        }
      }
    }

    // High pressure pushes sand/dirt sideways
    if (colAbove >= 4 && rng.nextInt(8) == 0) {
      for (final dir in [1, -1]) {
        final nx = wrapX(x + dir);
        final ni = y * gridW + nx;
        final neighbor = grid[ni];
        if (neighbor == El.sand || neighbor == El.dirt) {
          final pushX = wrapX(nx + dir);
          if (grid[y * gridW + pushX] == El.empty) {
            swap(ni, y * gridW + pushX);
            swap(idx, ni);
            return;
          }
        }
      }
    }

    // Pressure-based vertical mass transfer
    if (!isSpecialState && mass > 110 && inBoundsY(uy)) {
      final aboveI = uy * gridW + x;
      if (grid[aboveI] == El.water && life[aboveI] < 140) {
        final aboveMass = life[aboveI] < 20 ? 100 : life[aboveI];
        final diff = mass - aboveMass;
        if (diff > 8) {
          final transfer = (diff ~/ 4).clamp(1, 20);
          mass = (mass - transfer).clamp(20, 139);
          final newAbove = (aboveMass + transfer).clamp(20, 139);
          life[idx] = mass;
          life[aboveI] = newAbove;
        }
      }
    }

    // Fall with momentum
    if (inBoundsY(by) && grid[by * gridW + x] == El.empty) {
      final maxVel = elementMaxVelocity[El.water];
      final curVel = velY[idx];
      final newVel = (curVel + 1).clamp(0, maxVel);
      velY[idx] = newVel;
      // Multi-cell fall when velocity > 1
      if (newVel > 1) {
        int finalY = by;
        for (int d = 2; d <= newVel; d++) {
          final testY = y + g * d;
          if (!inBoundsY(testY)) break;
          if (grid[testY * gridW + x] != El.empty) break;
          finalY = testY;
        }
        swap(idx, finalY * gridW + x);
      } else {
        swap(idx, by * gridW + x);
      }
      return;
    }

    // Splash
    if (velY[idx] >= 3 && inBoundsY(by) && grid[by * gridW + x] != El.empty) {
      queueReactionFlash(x, y, 100, 180, 255, (velY[idx] ~/ 2).clamp(2, 4));
      for (int i = 0; i < (velY[idx] ~/ 2).clamp(1, 3); i++) {
        final sx = wrapX(x + (rng.nextBool() ? 1 : -1) * (1 + rng.nextInt(2)));
        final sy = y - g * rng.nextInt(2);
        if (inBoundsY(sy) && grid[sy * gridW + sx] == El.empty) {
          final splashIdx = sy * gridW + sx;
          grid[splashIdx] = El.water;
          final splashMass = (mass ~/ 2).clamp(20, 139);
          life[splashIdx] = splashMass;
          markProcessed(splashIdx);
          grid[idx] = El.empty;
          life[idx] = 0;
          velY[idx] = 0;
          return;
        }
      }
    }
    velY[idx] = 0;

    // Momentum-based lateral flow
    final momentum = velX[idx];
    final frameBias = rng.nextBool();
    final dl = momentum != 0 ? (momentum > 0) : frameBias;
    final x1 = wrapX(dl ? x + 1 : x - 1);
    final x2 = wrapX(dl ? x - 1 : x + 1);

    if (inBoundsY(by) && grid[by * gridW + x1] == El.empty) {
      velX[idx] = dl ? 1 : -1;
      swap(idx, by * gridW + x1);
      return;
    }
    if (inBoundsY(by) && grid[by * gridW + x2] == El.empty) {
      velX[idx] = dl ? -1 : 1;
      swap(idx, by * gridW + x2);
      return;
    }

    // Surface tension: isolated droplets resist lateral spread
    final st = elementSurfaceTension[El.water];
    if (st > 3) {
      int sameNeighbors = 0;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (inBoundsY(ny) && grid[ny * gridW + nx] == El.water) {
            sameNeighbors++;
          }
        }
      }
      // Isolated (0-1 same-type neighbors): 50% chance to resist spread
      if (sameNeighbors <= 1 && rng.nextBool()) {
        return; // Hold droplet shape
      }
    }

    // Pressure-driven lateral flow (uses pressure grid for radius)
    final flowDist = pressureFlowRadius(idx) + 1;

    if (!isSpecialState) {
      for (final dir in dl ? [1, -1] : [-1, 1]) {
        final nx = wrapX(x + dir);
        final ni = y * gridW + nx;
        if (grid[ni] == El.water && life[ni] < 140) {
          final neighborMass = life[ni] < 20 ? 100 : life[ni];
          final diff = mass - neighborMass;
          if (diff > 5) {
            final transfer = (diff ~/ 3).clamp(1, 20);
            life[idx] = (mass - transfer).clamp(20, 139);
            life[ni] = (neighborMass + transfer).clamp(20, 139);
          }
        }
      }
    }

    for (int d = 1; d <= flowDist; d++) {
      final sx1 = wrapX(dl ? x + d : x - d);
      final sx2 = wrapX(dl ? x - d : x + d);
      if (grid[y * gridW + sx1] == El.empty) {
        velX[idx] = dl ? 1 : -1;
        swap(idx, y * gridW + sx1);
        return;
      }
      if (grid[y * gridW + sx2] == El.empty) {
        velX[idx] = dl ? -1 : 1;
        swap(idx, y * gridW + sx2);
        return;
      }
    }

    // Surface leveling
    final aboveEl = inBoundsY(uy) ? grid[uy * gridW + x] : -1;
    if (aboveEl == El.empty || aboveEl == -1) {
      for (final dir in [1, -1]) {
        final nx = wrapX(x + dir);
        final nIdx = y * gridW + nx;
        if (grid[nIdx] != El.empty) continue;
        final belowNx = y + g;
        if (!inBoundsY(belowNx)) continue;
        final belowCell = grid[belowNx * gridW + nx];
        if (belowCell == El.empty) continue;
        int adjCol = 0;
        for (int cy = y + g; inBoundsY(cy) && adjCol < 12; cy += g) {
          if (grid[cy * gridW + nx] == El.water) {
            adjCol++;
          } else {
            break;
          }
        }
        if (totalCol > adjCol + 1) {
          velX[idx] = dir;
          swap(idx, nIdx);
          return;
        }
      }
      // Extended surface leveling
      for (final dir in [1, -1]) {
        for (int d = 2; d <= 4; d++) {
          final nx = wrapX(x + dir * d);
          bool pathClear = true;
          for (int pd = 1; pd < d; pd++) {
            final px = wrapX(x + dir * pd);
            if (grid[y * gridW + px] != El.empty) {
              pathClear = false;
              break;
            }
          }
          if (!pathClear) continue;
          if (grid[y * gridW + nx] != El.empty) continue;
          final belowNx = y + g;
          if (!inBoundsY(belowNx)) continue;
          if (grid[belowNx * gridW + nx] == El.empty) continue;

          int targetCol = 0;
          for (int cy = y + g; inBoundsY(cy) && targetCol < 12; cy += g) {
            if (grid[cy * gridW + nx] == El.water) {
              targetCol++;
            } else {
              break;
            }
          }
          if (totalCol > targetCol + 1) {
            velX[idx] = dir;
            swap(idx, y * gridW + nx);
            return;
          }
        }
      }

      // Mass-based surface leveling
      if (!isSpecialState) {
        for (final dir in [1, -1]) {
          for (int d = 1; d <= 4; d++) {
            final nx = wrapX(x + dir * d);
            final ni = y * gridW + nx;
            if (grid[ni] != El.water) break;
            final naboveY = y - g;
            if (!inBoundsY(naboveY)) continue;
            if (grid[naboveY * gridW + nx] != El.empty) continue;
            final nlife = life[ni];
            if (nlife >= 140) continue;
            final nMass = nlife < 20 ? 100 : nlife;
            final mDiff = mass - nMass;
            if (mDiff.abs() > 3) {
              final transfer = (mDiff ~/ 3).clamp(-5, 5);
              final newMass = (mass - transfer).clamp(20, 139);
              final newNMass = (nMass + transfer).clamp(20, 139);
              life[idx] = newMass;
              life[ni] = newNMass;
              mass = newMass;
            }
          }
        }
      }
    }

    if (rng.nextInt(4) == 0) velX[idx] = 0;

    // Underground water seepage: water slowly percolates through dirt
    if (!isSpecialState && frameCount % 8 == 0 && rng.nextInt(12) == 0) {
      final by2 = y + gravityDir;
      if (inBoundsY(by2)) {
        final belowI = by2 * gridW + x;
        if (grid[belowI] == El.dirt) {
          // Check if there's empty space or more dirt below the dirt
          final by3 = by2 + gravityDir;
          if (inBoundsY(by3)) {
            final below2 = grid[by3 * gridW + x];
            if (below2 == El.empty || below2 == El.water) {
              // Seep through: water replaces dirt, dirt moves up
              grid[idx] = El.dirt;
              life[idx] = life[belowI]; // preserve dirt moisture
              grid[belowI] = El.water;
              life[belowI] = mass;
              markProcessed(idx);
              markProcessed(belowI);
              return;
            }
          }
        }
      }
    }

    // Pressure equalization: highly pressurized water pushes upward against gravity
    if (!isSpecialState && cellPressure >= 6 && frameCount % 3 == 0) {
      for (final dir in [1, -1]) {
        for (int d = 1; d <= pressureFlowRadius(idx); d++) {
          final nx = wrapX(x + dir * d);
          final pe = grid[y * gridW + nx];
          if (pe != El.water && pe != El.empty) break;
          final aboveY = y - g;
          if (inBoundsY(aboveY) && grid[aboveY * gridW + nx] == El.empty) {
            velX[idx] = dir;
            swap(idx, aboveY * gridW + nx);
            return;
          }
        }
      }
    }

    // Underground pressure: water surrounded by stone pushes harder to find exits
    if (!isSpecialState && colAbove >= 6 && frameCount % 4 == 0) {
      // Count surrounding stone to detect underground pressure
      int stoneCount = 0;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          if (grid[ny * gridW + nx] == El.stone) stoneCount++;
        }
      }
      // Under pressure (surrounded by stone) — try harder to find exits
      if (stoneCount >= 4 && rng.nextInt(6) == 0) {
        for (int r = 2; r <= 8; r++) {
          for (final dir in [1, -1]) {
            final nx = wrapX(x + dir * r);
            if (grid[y * gridW + nx] == El.empty) {
              // Check path — allow pushing through water
              bool pathOk = true;
              for (int pd = 1; pd < r; pd++) {
                final px = wrapX(x + dir * pd);
                final pe = grid[y * gridW + px];
                if (pe != El.water && pe != El.empty) { pathOk = false; break; }
              }
              if (pathOk) {
                velX[idx] = dir;
                swap(idx, y * gridW + nx);
                return;
              }
            }
          }
        }
      }
    }
  }

  // =========================================================================
  // Fire
  // =========================================================================

  void simFire(int x, int y, int idx) {
    life[idx]++;

    final nearOil = checkAdjacent(x, y, El.oil);
    final burnoutLife = nearOil ? 70 + rng.nextInt(50) : 40 + rng.nextInt(40);

    if (life[idx] > burnoutLife) {
      grid[idx] = El.ash;
      life[idx] = 0;
      markProcessed(idx);
      final uy = y - gravityDir;
      if (rng.nextBool() && inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
        grid[uy * gridW + x] = El.smoke;
        life[uy * gridW + x] = 0;
        markProcessed(uy * gridW + x);
      }
      return;
    }

    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = wrapX(x + dx);
        final ny = y + dy;
        if (!inBoundsY(ny)) continue;
        final ni = ny * gridW + nx;
        final neighbor = grid[ni];
        if (neighbor == El.water) {
          grid[ni] = El.steam;
          life[ni] = 0;
          grid[idx] = El.empty;
          life[idx] = 0;
          markProcessed(ni);
          queueReactionFlash(nx, ny, 200, 200, 240, 3);
          return;
        }
        if ((neighbor == El.plant || neighbor == El.seed) && rng.nextInt(2) == 0) {
          grid[ni] = El.fire;
          life[ni] = 0;
          markProcessed(ni);
        }
        if (neighbor == El.wood && rng.nextInt(4) == 0) {
          grid[ni] = El.fire;
          life[ni] = 0;
          markProcessed(ni);
        }
        if (neighbor == El.oil) {
          grid[ni] = El.fire;
          life[ni] = 0;
          markProcessed(ni);
          queueReactionFlash(nx, ny, 255, 180, 50, 3);
          for (int dy2 = -2; dy2 <= 2; dy2++) {
            for (int dx2 = -2; dx2 <= 2; dx2++) {
              if (dx2 == 0 && dy2 == 0) continue;
              final ox = wrapX(nx + dx2);
              final oy = ny + dy2;
              if (!inBoundsY(oy)) continue;
              final oi = oy * gridW + ox;
              if (grid[oi] == El.oil && rng.nextInt(3) == 0) {
                grid[oi] = El.fire;
                life[oi] = 0;
                markProcessed(oi);
              }
            }
          }
        }
        if (neighbor == El.ice) {
          grid[ni] = El.water;
          life[ni] = 150;
          markProcessed(ni);
        }
        if (neighbor == El.snow) {
          grid[ni] = El.water;
          life[ni] = 80;
          markProcessed(ni);
          queueReactionFlash(nx, ny, 180, 220, 255, 2);
        }
        if (neighbor == El.tnt) {
          pendingExplosions.add(Explosion(nx, ny, calculateTNTRadius(nx, ny)));
          grid[idx] = El.empty;
          life[idx] = 0;
          return;
        }
      }
    }

    // Heat radiation: fire warms nearby stone
    if (frameCount % 6 == 0) {
      for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final ni = ny * gridW + nx;
          if (grid[ni] == El.stone) {
            final heat = velX[ni].clamp(0, 5);
            if (heat < 3) velX[ni] = (heat + 1);
          }
        }
      }
    }

    final uy = y - gravityDir;
    if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
      swap(idx, uy * gridW + x);
      return;
    }
    final drift = rng.nextInt(3) - 1;
    final driftX = wrapX(x + drift);
    if (inBoundsY(uy) && grid[uy * gridW + driftX] == El.empty) {
      swap(idx, uy * gridW + driftX);
    }
  }

  // =========================================================================
  // Ice
  // =========================================================================

  void simIce(int x, int y, int idx) {
    // Temperature-driven melting (ice -> water)
    if (checkTemperatureReaction(x, y, idx, El.ice)) return;

    if (checkAdjacent(x, y, El.fire) || checkAdjacent(x, y, El.lava)) {
      grid[idx] = El.water;
      life[idx] = 150;
      markProcessed(idx);
      return;
    }
    final ambientMeltChance = isNight ? 60 : 20;
    if (rng.nextInt(ambientMeltChance) == 0) {
      int waterCount = 0;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (inBoundsY(ny) && grid[ny * gridW + nx] == El.water) {
            waterCount++;
          }
        }
      }
      if (waterCount >= 3) {
        grid[idx] = El.water;
        life[idx] = 150;
        markProcessed(idx);
      }
    }
  }

  // =========================================================================
  // Lightning
  // =========================================================================

  void simLightning(int x, int y, int idx) {
    life[idx]++;
    if (life[idx] > 8) {
      grid[idx] = El.empty;
      life[idx] = 0;
      return;
    }

    lightningFlashFrames = 3;

    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = wrapX(x + dx);
        final ny = y + dy;
        if (!inBoundsY(ny)) continue;
        final ni = ny * gridW + nx;
        final neighbor = grid[ni];
        if (neighbor == El.tnt) {
          pendingExplosions.add(Explosion(nx, ny, calculateTNTRadius(nx, ny)));
        }
        if (neighbor == El.ice) {
          grid[ni] = El.water;
          life[ni] = 150;
          markProcessed(ni);
        }
        // Conduct electricity through any conductive material
        final neighborCond = neighbor < maxElements ? elementConductivity[neighbor] : 0;
        if (neighborCond > 0) {
          conductElectricity(nx, ny);
        }
        if (neighbor == El.sand) {
          grid[ni] = El.glass;
          life[ni] = 0;
          markProcessed(ni);
        }
      }
    }

    final dist = 2 + rng.nextInt(3);
    final ndx = rng.nextInt(3) - 1;
    final targetY = y + gravityDir * dist;
    final targetX = wrapX(x + ndx);
    if (!inBoundsY(targetY)) {
      grid[idx] = El.empty;
      life[idx] = 0;
      return;
    }
    final ni = targetY * gridW + targetX;
    if (grid[ni] == El.empty) {
      grid[ni] = El.lightning;
      life[ni] = life[idx];
      markProcessed(ni);
      grid[idx] = El.empty;
      life[idx] = 0;
    }
  }

  // =========================================================================
  // Seed
  // =========================================================================

  void simSeed(int x, int y, int idx) {
    final sType = velX[idx].clamp(1, 5);
    life[idx]++;
    if (checkAdjacent(x, y, El.fire) || checkAdjacent(x, y, El.lava)) {
      grid[idx] = El.ash; life[idx] = 0; velX[idx] = 0; markProcessed(idx); return;
    }
    if (checkAdjacent(x, y, El.acid)) {
      grid[idx] = El.empty; life[idx] = 0; velX[idx] = 0; return;
    }
    final by = y + gravityDir;
    bool onDirt = inBoundsY(by) && grid[by * gridW + x] == El.dirt;
    if (onDirt) {
      final soilM = life[by * gridW + x];
      if (soilM >= plantMinMoist[sType]) {
        if (life[idx] > 30) {
          grid[idx] = El.plant; life[idx] = 50;
          setPlantData(idx, sType, kStSprout); velY[idx] = 1; markProcessed(idx); return;
        }
        return;
      } else if (life[idx] > 60) {
        grid[idx] = El.empty; life[idx] = 0; velX[idx] = 0; return;
      }
    } else {
      bool onSolid = inBoundsY(by) && grid[by * gridW + x] != El.empty;
      if (onSolid) {
        if (life[idx] > 60) { grid[idx] = El.empty; life[idx] = 0; velX[idx] = 0; return; }
        return;
      }
    }
    fallGranular(x, y, idx, El.seed);
  }

  // =========================================================================
  // Dirt
  // =========================================================================

  void simDirt(int x, int y, int idx) {
    // Porosity-driven moisture absorption from adjacent water
    // Absorption rate = porosity * 0.1 per frame (replaces hardcoded frameCount % 5)
    final dirtPorosity = elementPorosity[El.dirt];
    if (dirtPorosity > 0 && life[idx] < 5 && checkAdjacent(x, y, El.water)) {
      // Higher porosity = more frequent absorption (porosity 153/255 ~= 0.6 -> ~6% per frame)
      if (rng.nextInt(255) < dirtPorosity ~/ 4) {
        life[idx]++;
      }
    }

    // Moisture propagation
    if (frameCount % 10 == 0 && life[idx] < 4) {
      for (int dy2 = -1; dy2 <= 1; dy2++) {
        for (int dx2 = -1; dx2 <= 1; dx2++) {
          if (dx2 == 0 && dy2 == 0) continue;
          final nx = wrapX(x + dx2);
          final ny = y + dy2;
          if (!inBoundsY(ny)) continue;
          final ni = ny * gridW + nx;
          if (grid[ni] == El.dirt && life[ni] > life[idx] + 1) {
            life[idx]++;
            break;
          }
        }
      }
    }

    // Moisture loss
    if (frameCount % 15 == 0 && life[idx] > 0 && !checkAdjacent(x, y, El.water)) {
      bool nearWetDirt = false;
      for (int dy2 = -1; dy2 <= 1; dy2++) {
        for (int dx2 = -1; dx2 <= 1; dx2++) {
          if (dx2 == 0 && dy2 == 0) continue;
          final nx = wrapX(x + dx2);
          final ny = y + dy2;
          if (inBoundsY(ny) && grid[ny * gridW + nx] == El.dirt &&
              life[ny * gridW + nx] > life[idx]) {
            nearWetDirt = true;
            break;
          }
        }
        if (nearWetDirt) break;
      }
      if (!nearWetDirt) life[idx]--;
    }

    // Saturated + lots of water -> mud
    if (life[idx] >= 5) {
      int wc = 0;
      for (int dy2 = -1; dy2 <= 1; dy2++) {
        for (int dx2 = -1; dx2 <= 1; dx2++) {
          if (dx2 == 0 && dy2 == 0) continue;
          final wnx = wrapX(x + dx2);
          final wny = y + dy2;
          if (inBoundsY(wny) &&
              grid[wny * gridW + wnx] == El.water) {
            wc++;
          }
        }
      }
      if (wc >= 3) {
        grid[idx] = El.mud;
        life[idx] = 0;
        markProcessed(idx);
        return;
      }
    }

    // Ash fertilizer: dirt absorbs adjacent ash, gaining +2 moisture.
    // This completes the cycle: plant dies → ash → dirt absorbs → moisture → new plant.
    if (rng.nextInt(10) == 0) {
      for (int dy2 = -1; dy2 <= 1; dy2++) {
        for (int dx2 = -1; dx2 <= 1; dx2++) {
          if (dx2 == 0 && dy2 == 0) continue;
          final nx = wrapX(x + dx2);
          final ny = y + dy2;
          if (inBoundsY(ny) && grid[ny * gridW + nx] == El.ash) {
            final ni = ny * gridW + nx;
            grid[ni] = El.empty;
            life[ni] = 0;
            markProcessed(ni);
            life[idx] = (life[idx] + 2).clamp(0, 5);
            break;
          }
        }
      }
    }

    // Underground compaction: dirt surrounded by stone compacts over time
    // Uses velY to track compaction level (0-5). Higher = denser, darker.
    if (frameCount % 30 == 0) {
      int stoneNeighbors = 0;
      for (int dy2 = -1; dy2 <= 1; dy2++) {
        for (int dx2 = -1; dx2 <= 1; dx2++) {
          if (dx2 == 0 && dy2 == 0) continue;
          final nx = wrapX(x + dx2);
          final ny = y + dy2;
          if (!inBoundsY(ny)) continue;
          final n = grid[ny * gridW + nx];
          if (n == El.stone || n == El.metal) stoneNeighbors++;
        }
      }
      final compaction = velY[idx].clamp(0, 5);
      if (stoneNeighbors >= 5 && compaction < 5) {
        velY[idx] = (compaction + 1);
        markDirty(x, y);
      } else if (stoneNeighbors <= 1 && compaction > 0) {
        // Decompact when exposed
        velY[idx] = (compaction - 1);
        markDirty(x, y);
      }
    }

    // Underground moisture retention: dirt near underground water stays moist longer
    // (already handles moisture gain; extend retention for compacted dirt)
    if (velY[idx] >= 3 && life[idx] > 0) {
      // Compacted dirt retains moisture — skip the normal moisture loss
      // by not falling through to fallGranularDisplace when fully surrounded
    }

    // Water erosion: dirt with water flowing over it slowly erodes
    if (frameCount % 20 == 0 && rng.nextInt(15) == 0) {
      // Check for water flowing above or beside this dirt
      int waterFlowCount = 0;
      for (int dx2 = -1; dx2 <= 1; dx2++) {
        final nx = wrapX(x + dx2);
        final uy = y - gravityDir;
        if (inBoundsY(uy) && grid[uy * gridW + nx] == El.water) {
          waterFlowCount++;
        }
      }
      if (waterFlowCount >= 2 && velY[idx] < 3) {
        // Erode: turn to mud or empty based on moisture
        if (life[idx] >= 3) {
          grid[idx] = El.mud;
          life[idx] = 0;
          velY[idx] = 0;
          markProcessed(idx);
          return;
        }
      }
    }

    fallGranularDisplace(x, y, idx, El.dirt);
  }

  // =========================================================================
  // Plant
  // =========================================================================

  void simPlant(int x, int y, int idx) {
    final pType = plantType(idx);
    final pStage = plantStage(idx);
    final hydration = life[idx];

    if (checkAdjacent(x, y, El.fire) || checkAdjacent(x, y, El.lava)) {
      grid[idx] = El.fire; life[idx] = 0; velX[idx] = 0; velY[idx] = 0;
      markProcessed(idx); return;
    }
    if (checkAdjacent(x, y, El.acid) && rng.nextInt(3) == 0) {
      grid[idx] = El.empty; life[idx] = 0; velX[idx] = 0; velY[idx] = 0;
      markProcessed(idx); return;
    }

    if (pStage == kStDead) {
      velY[idx] = (velY[idx] + 1).clamp(0, 127).toInt();
      if (velY[idx] > 120) {
        // Dead plants become ash (fertilization loop) instead of dirt.
        grid[idx] = El.ash; life[idx] = 0; velX[idx] = 0; velY[idx] = 0;
        markProcessed(idx);
      }
      return;
    }

    // Hydration
    if (frameCount % 5 == 0) {
      bool hasMoisture = false;
      for (int dy2 = -1; dy2 <= 1; dy2++) {
        for (int dx2 = -1; dx2 <= 1; dx2++) {
          final nx = wrapX(x + dx2); final ny = y + dy2;
          if (!inBoundsY(ny)) continue;
          final ni = ny * gridW + nx;
          if (grid[ni] == El.dirt && life[ni] >= plantMinMoist[pType.clamp(1, 5)]) {
            hasMoisture = true; break;
          }
          if (grid[ni] == El.water) { hasMoisture = true; break; }
        }
        if (hasMoisture) break;
      }
      if (hasMoisture) {
        life[idx] = (hydration + 2).clamp(0, 100);
      } else {
        life[idx] = (hydration - 1).clamp(0, 100);
      }
    }

    // Wilting / recovery
    if (life[idx] < 30 && pStage < kStWilting) {
      setPlantData(idx, pType, kStWilting);
    } else if (life[idx] >= 30 && pStage == kStWilting) {
      setPlantData(idx, pType, velY[idx] >= plantMaxH[pType.clamp(1, 5)] ? kStMature : kStGrowing);
    }
    if (life[idx] <= 0 && pStage == kStWilting) {
      setPlantData(idx, pType, kStDead);
      velY[idx] = 0;
      return;
    }

    if (pStage > kStMature) return;

    final maxH = plantMaxH[pType.clamp(1, 5)];
    final curSize = velY[idx].clamp(0, 127).toInt();
    if (curSize >= maxH) {
      if (pStage != kStMature) setPlantData(idx, pType, kStMature);

      // Mature plants drop seeds (1 in 500 chance per frame).
      if (rng.nextInt(500) == 0) {
        _plantDropSeed(x, y, idx);
      }

      return;
    }

    bool fertilized = checkAdjacent(x, y, El.ash);
    int growRate = plantGrowRate[pType.clamp(1, 5)];
    if (isNight && pType != kPlantMushroom) growRate = (growRate * 5);
    if (fertilized) growRate = (growRate * 2) ~/ 3;

    if (frameCount % growRate != 0) return;

    if (pStage == kStSprout) setPlantData(idx, pType, kStGrowing);

    switch (pType) {
      case kPlantGrass: _growGrass(x, y, idx, curSize);
      case kPlantFlower: _growFlower(x, y, idx, curSize);
      case kPlantTree: _growTree(x, y, idx, curSize);
      case kPlantMushroom: _growMushroom(x, y, idx, curSize);
      case kPlantVine: _growVine(x, y, idx, curSize);
    }
  }

  void _growGrass(int x, int y, int idx, int curSize) {
    if (curSize < 3) {
      final uy = y - gravityDir;
      if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
        final ni = uy * gridW + x;
        grid[ni] = El.plant; life[ni] = life[idx];
        setPlantData(ni, kPlantGrass, kStGrowing); velY[ni] = (curSize + 1);
        markProcessed(ni);
        velY[idx] = (curSize + 1);
      }
    }
    if (rng.nextInt(40) == 0) {
      final side = wrapX(rng.nextBool() ? x - 1 : x + 1);
      final by = y + gravityDir;
      if (grid[y * gridW + side] == El.empty &&
          inBoundsY(by) && grid[by * gridW + side] == El.dirt) {
        final ni = y * gridW + side;
        grid[ni] = El.plant; life[ni] = life[idx];
        setPlantData(ni, kPlantGrass, kStSprout); velY[ni] = 1;
        markProcessed(ni);
      }
    }
  }

  void _growFlower(int x, int y, int idx, int curSize) {
    if (curSize < 6) {
      final uy = y - gravityDir;
      if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
        final ni = uy * gridW + x;
        grid[ni] = El.plant; life[ni] = life[idx];
        final newSize = curSize + 1;
        setPlantData(ni, kPlantFlower, newSize >= 4 ? kStMature : kStGrowing);
        velY[ni] = newSize;
        markProcessed(ni);
        velY[idx] = newSize;
      }
    }
  }

  void _growTree(int x, int y, int idx, int curSize) {
    if (curSize < 15) {
      final uy = y - gravityDir;
      if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
        final ni = uy * gridW + x;
        grid[ni] = El.plant; life[ni] = life[idx];
        final newSize = curSize + 1;
        final isTrunk = newSize < 7;
        setPlantData(ni, kPlantTree, isTrunk ? kStGrowing : kStMature);
        velY[ni] = newSize;
        markProcessed(ni);
        velY[idx] = newSize;
      }
      if (curSize >= 6) {
        for (final side in [wrapX(x - 1), wrapX(x + 1)]) {
          if (rng.nextInt(2) == 0) continue;
          for (final sy in [y, y - gravityDir]) {
            if (inBoundsY(sy) && grid[sy * gridW + side] == El.empty) {
              final ni = sy * gridW + side;
              grid[ni] = El.plant; life[ni] = life[idx];
              setPlantData(ni, kPlantTree, kStMature); velY[ni] = curSize;
              markProcessed(ni);
              break;
            }
          }
        }
        if (curSize >= 10 && rng.nextInt(3) == 0) {
          for (final side in [wrapX(x - 2), wrapX(x + 2)]) {
            if (grid[y * gridW + side] == El.empty) {
              final ni = y * gridW + side;
              grid[ni] = El.plant; life[ni] = life[idx];
              setPlantData(ni, kPlantTree, kStMature); velY[ni] = curSize;
              markProcessed(ni);
            }
          }
        }
      }
    }

    // Root system: mature trees grow roots downward through dirt
    if (curSize >= 8 && rng.nextInt(50) == 0) {
      _growTreeRoots(x, y, idx);
    }
  }

  /// Extend tree roots downward through dirt. Roots don't penetrate stone.
  void _growTreeRoots(int x, int y, int idx) {
    final g = gravityDir;
    // Find the base of this tree — scan down to find dirt
    int baseY = y;
    for (int d = 1; d <= 20; d++) {
      final cy = y + g * d;
      if (!inBoundsY(cy)) break;
      final el = grid[cy * gridW + x];
      if (el == El.dirt) {
        baseY = cy;
        break;
      } else if (el != El.plant && el != El.wood && el != El.empty) {
        break;
      }
    }
    if (baseY == y) return;

    // Try to grow a root cell below or diagonally below
    final rootY = baseY + g;
    if (!inBoundsY(rootY)) return;

    // Pick a root direction: straight down or diagonal
    final dirs = <int>[0];
    if (rng.nextBool()) dirs.add(rng.nextBool() ? -1 : 1);

    for (final dx in dirs) {
      final rx = wrapX(x + dx);
      if (!inBoundsY(rootY)) continue;
      final ri = rootY * gridW + rx;
      final el = grid[ri];
      if (el == El.dirt) {
        // Convert dirt to plant root (tree type, growing stage)
        grid[ri] = El.plant;
        life[ri] = life[idx]; // share hydration
        setPlantData(ri, kPlantTree, kStGrowing);
        velY[ri] = 1; // root marker (small size)
        markProcessed(ri);
        // Roots help the surrounding dirt retain moisture
        for (int dy2 = -1; dy2 <= 1; dy2++) {
          for (int dx2 = -1; dx2 <= 1; dx2++) {
            final nx = wrapX(rx + dx2);
            final ny = rootY + dy2;
            if (!inBoundsY(ny)) continue;
            final ni = ny * gridW + nx;
            if (grid[ni] == El.dirt && life[ni] < 3) {
              life[ni] = (life[ni] + 1).clamp(0, 5);
            }
          }
        }
        return;
      }
      // Roots don't penetrate stone or metal
      if (el == El.stone || el == El.metal || el == El.glass) continue;
    }
  }

  void _growMushroom(int x, int y, int idx, int curSize) {
    if (curSize < 3) {
      final uy = y - gravityDir;
      if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
        final ni = uy * gridW + x;
        grid[ni] = El.plant; life[ni] = life[idx];
        final newSize = curSize + 1;
        setPlantData(ni, kPlantMushroom, newSize >= 2 ? kStMature : kStGrowing);
        velY[ni] = newSize;
        markProcessed(ni);
        velY[idx] = newSize;
      }
    }
    if (rng.nextInt(80) == 0) {
      for (int r = 1; r <= 3; r++) {
        final sx = wrapX(x + (rng.nextBool() ? r : -r));
        final by = y + gravityDir;
        if (grid[y * gridW + sx] == El.empty &&
            inBoundsY(by) && grid[by * gridW + sx] == El.dirt &&
            life[by * gridW + sx] >= 4) {
          final ni = y * gridW + sx;
          grid[ni] = El.plant; life[ni] = life[idx];
          setPlantData(ni, kPlantMushroom, kStSprout); velY[ni] = 1;
          markProcessed(ni);
          break;
        }
      }
    }
  }

  void _growVine(int x, int y, int idx, int curSize) {
    if (curSize < 12) {
      final directions = <List<int>>[];
      for (final d in [[-1, -gravityDir], [1, -gravityDir], [-1, 0], [1, 0], [0, -gravityDir]]) {
        final nx = wrapX(x + d[0]); final ny = y + d[1];
        if (!inBoundsY(ny)) continue;
        if (grid[ny * gridW + nx] != El.empty) continue;
        bool nearSolid = false;
        for (int dy2 = -1; dy2 <= 1; dy2++) {
          for (int dx2 = -1; dx2 <= 1; dx2++) {
            final sx = wrapX(nx + dx2); final sy = ny + dy2;
            if (!inBoundsY(sy)) continue;
            final se = grid[sy * gridW + sx];
            if (se == El.dirt || se == El.stone || se == El.wood || se == El.metal) {
              nearSolid = true; break;
            }
          }
          if (nearSolid) break;
        }
        if (nearSolid) directions.add(d);
      }
      if (directions.isNotEmpty) {
        final d = directions[rng.nextInt(directions.length)];
        final nx = x + d[0]; final ny = y + d[1];
        final ni = ny * gridW + nx;
        grid[ni] = El.plant; life[ni] = life[idx];
        setPlantData(ni, kPlantVine, kStGrowing);
        velY[ni] = (curSize + 1); markProcessed(ni);
        velY[idx] = (curSize + 1);
      }
    }
  }

  /// Drop a seed from a mature plant into the nearest empty adjacent cell.
  void _plantDropSeed(int x, int y, int idx) {
    for (int dy2 = -1; dy2 <= 1; dy2++) {
      for (int dx2 = -1; dx2 <= 1; dx2++) {
        if (dx2 == 0 && dy2 == 0) continue;
        final sx = wrapX(x + dx2);
        final sy = y + dy2;
        if (!inBoundsY(sy)) continue;
        final si = sy * gridW + sx;
        if (grid[si] == El.empty) {
          // Wind-assisted seed spread.
          final seedX = windForce != 0 && rng.nextBool()
              ? wrapX(sx + windForce.sign) : sx;
          final seedIdx = sy * gridW + seedX;
          if (grid[seedIdx] == El.empty) {
            grid[seedIdx] = El.seed;
            life[seedIdx] = 0;
            markDirty(seedX, sy);
          } else {
            grid[si] = El.seed;
            life[si] = 0;
            markDirty(sx, sy);
          }
          return;
        }
      }
    }
  }

  // =========================================================================
  // Lava
  // =========================================================================

  void simLava(int x, int y, int idx) {
    // Temperature-driven cooling (lava -> stone when cold enough)
    if (checkTemperatureReaction(x, y, idx, El.lava)) return;

    life[idx]++;
    final g = gravityDir;

    // Base cooling timeout
    int coolingThreshold = 200 + rng.nextInt(50);

    // Isolated lava cools faster (fewer lava neighbors = faster cooling)
    if (frameCount % 10 == 0) {
      int lavaNeighborCount = 0;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (inBoundsY(ny) && grid[ny * gridW + nx] == El.lava) {
            lavaNeighborCount++;
          }
        }
      }
      if (lavaNeighborCount <= 1) {
        // Isolated lava — cool much faster
        coolingThreshold = 80 + rng.nextInt(30);
      } else if (lavaNeighborCount <= 3) {
        // Partially isolated
        coolingThreshold = 140 + rng.nextInt(40);
      }
    }

    if (life[idx] > coolingThreshold) {
      grid[idx] = El.stone;
      life[idx] = 0;
      // Newly cooled stone retains heat
      velX[idx] = 4;
      markProcessed(idx);
      return;
    }

    // Volcanic gas emission
    final uy = y - g;
    if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
      if (rng.nextInt(80) == 0) {
        grid[uy * gridW + x] = El.smoke;
        life[uy * gridW + x] = 0;
        markProcessed(uy * gridW + x);
      } else if (rng.nextInt(120) == 0) {
        grid[uy * gridW + x] = El.steam;
        life[uy * gridW + x] = 0;
        markProcessed(uy * gridW + x);
      }
    }

    // Eruption pressure (enhanced by pressure grid)
    final lavaPressure = pressure[idx];
    final eruptionChance = lavaPressure > 20 ? 30 : 60;
    if (rng.nextInt(eruptionChance) == 0) {
      int capDepth = 0;
      for (int cy = y - g; inBoundsY(cy) && capDepth < 6; cy -= g) {
        if (grid[cy * gridW + x] == El.stone) {
          capDepth++;
        } else {
          break;
        }
      }
      int lavaBelow = 0;
      for (int cy = y + g; inBoundsY(cy) && lavaBelow < 8; cy += g) {
        if (grid[cy * gridW + x] == El.lava) {
          lavaBelow++;
        } else {
          break;
        }
      }
      // High pressure makes eruption more likely
      final eruptThresh = lavaPressure > 20 ? 10 : 20;
      if (capDepth >= 2 && lavaBelow >= 3 && rng.nextInt(eruptThresh) == 0) {
        final blastY = y - g * capDepth;
        if (inBoundsY(blastY)) {
          final blastIdx = blastY * gridW + x;
          grid[blastIdx] = El.lava;
          life[blastIdx] = 0;
          markProcessed(blastIdx);
          queueReactionFlash(x, blastY, 255, 200, 50, 8);
        }
        for (final dx in [-1, 1]) {
          final bx = wrapX(x + dx);
          final by2 = y - g * (capDepth - 1);
          if (inBoundsY(by2) && grid[by2 * gridW + bx] == El.stone && rng.nextBool()) {
            grid[by2 * gridW + bx] = El.fire;
            life[by2 * gridW + bx] = 0;
            markProcessed(by2 * gridW + bx);
          }
        }
      }
    }

    // Lava spatter
    if (rng.nextInt(100) == 0 && inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
      int lavaNeighbors = 0;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (inBoundsY(ny) && grid[ny * gridW + nx] == El.lava) {
            lavaNeighbors++;
          }
        }
      }
      if (lavaNeighbors >= 3) {
        final spatterH = 2 + rng.nextInt(4);
        final spatterDx = rng.nextInt(3) - 1;
        for (int d = 1; d <= spatterH; d++) {
          final sy = y - g * d;
          final sx = wrapX(x + spatterDx * (d > 2 ? 1 : 0));
          if (inBoundsY(sy) && grid[sy * gridW + sx] == El.empty) {
            if (d <= 2) {
              grid[sy * gridW + sx] = El.lava;
              life[sy * gridW + sx] = 150;
              markProcessed(sy * gridW + sx);
            } else {
              grid[sy * gridW + sx] = El.fire;
              life[sy * gridW + sx] = 0;
              markProcessed(sy * gridW + sx);
            }
          } else {
            break;
          }
        }
        queueReactionFlash(x, uy, 255, 180, 30, 5);
      }
    }

    // Heat stone
    if (frameCount % 4 == 0) {
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final ni = ny * gridW + nx;
          if (grid[ni] == El.stone) {
            final heat = velX[ni].clamp(0, 5);
            if (heat < 5) velX[ni] = (heat + 1);
          }
        }
      }
    }

    // Element interactions
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = wrapX(x + dx);
        final ny = y + dy;
        if (!inBoundsY(ny)) continue;
        final ni = ny * gridW + nx;
        final neighbor = grid[ni];
        if (neighbor == El.water) {
          grid[idx] = El.stone;
          life[idx] = 0;
          markProcessed(idx);
          grid[ni] = El.steam;
          life[ni] = 0;
          markProcessed(ni);
          queueReactionFlash(x, y, 255, 255, 255, 8);
          queueReactionFlash(nx, ny, 200, 220, 255, 5);
          final extraSteam = 3 + rng.nextInt(3);
          for (int s = 0; s < extraSteam; s++) {
            final sx = wrapX(x + rng.nextInt(7) - 3);
            final sy2 = y - g * (1 + rng.nextInt(3));
            if (inBoundsY(sy2) && grid[sy2 * gridW + sx] == El.empty) {
              grid[sy2 * gridW + sx] = El.steam;
              life[sy2 * gridW + sx] = 0;
              markProcessed(sy2 * gridW + sx);
            }
          }
          return;
        }
        if (neighbor == El.ice) {
          grid[idx] = El.stone; life[idx] = 0; markProcessed(idx);
          grid[ni] = El.water; life[ni] = 0; markProcessed(ni);
          queueReactionFlash(nx, ny, 180, 220, 255, 4);
          return;
        }
        if ((neighbor == El.plant || neighbor == El.seed ||
            neighbor == El.oil || neighbor == El.wood) && rng.nextInt(2) == 0) {
          grid[ni] = El.fire; life[ni] = 0; markProcessed(ni);
        }
        if (neighbor == El.snow) {
          grid[ni] = El.water; life[ni] = 100; markProcessed(ni);
        }
        if (neighbor == El.sand && rng.nextInt(40) == 0) {
          grid[ni] = El.glass; life[ni] = 0; markProcessed(ni);
          queueReactionFlash(nx, ny, 255, 200, 100, 3);
        }
      }
    }

    // Gravity — lava always falls if there's space below.
    final by = y + g;
    if (inBoundsY(by) && grid[by * gridW + x] == El.empty) {
      swap(idx, by * gridW + x);
      return;
    }

    // Density-based sinking: lava (density=200) sinks through lighter liquids
    if (tryDensityDisplace(x, y, idx, El.lava)) return;

    // Sink through water (specific reaction: produces steam)
    if (inBoundsY(by) && grid[by * gridW + x] == El.water) {
      final bi = by * gridW + x;
      grid[bi] = El.lava; life[bi] = life[idx];
      grid[idx] = El.steam; life[idx] = 0;
      markProcessed(idx); markProcessed(bi);
      queueReactionFlash(x, y, 220, 220, 255, 4);
      return;
    }

    final dl = rng.nextBool();
    // Viscous diagonal and lateral flow — uses property viscosity (lava=4)
    final visc = elementViscosity[El.lava];
    if (frameCount % visc != 0) return;

    final lx1 = wrapX(dl ? x - 1 : x + 1);
    final lx2 = wrapX(dl ? x + 1 : x - 1);
    if (inBoundsY(by) && grid[by * gridW + lx1] == El.empty) { swap(idx, by * gridW + lx1); return; }
    if (inBoundsY(by) && grid[by * gridW + lx2] == El.empty) { swap(idx, by * gridW + lx2); return; }

    // Surface tension: isolated lava resists lateral flow
    final lavaSt = elementSurfaceTension[El.lava];
    if (lavaSt > 3) {
      int lavaN = 0;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (inBoundsY(ny) && grid[ny * gridW + nx] == El.lava) lavaN++;
        }
      }
      if (lavaN <= 1 && rng.nextBool()) return;
    }

    // Very slow lateral flow
    if (frameCount % (visc + 1) == 0) {
      if (grid[y * gridW + lx1] == El.empty) { swap(idx, y * gridW + lx1); return; }
      if (grid[y * gridW + lx2] == El.empty) { swap(idx, y * gridW + lx2); }
    }
  }

  // =========================================================================
  // Snow
  // =========================================================================

  void simSnow(int x, int y, int idx) {
    // Temperature-driven melting (snow -> water)
    if (checkTemperatureReaction(x, y, idx, El.snow)) return;

    if (checkAdjacent(x, y, El.fire) || checkAdjacent(x, y, El.lava)) {
      if (!isNight || rng.nextBool()) {
        grid[idx] = El.water; life[idx] = 100; markProcessed(idx);
        queueReactionFlash(x, y, 150, 200, 255, 2);
        return;
      }
    }

    if (!isNight && rng.nextInt(200) == 0) {
      for (int dy = -3; dy <= 3; dy++) {
        for (int dx = -3; dx <= 3; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final n = grid[ny * gridW + nx];
          if (n == El.fire || n == El.lava) {
            grid[idx] = El.water; life[idx] = 80; markProcessed(idx); return;
          }
        }
      }
    }

    if (rng.nextInt(30) == 0) {
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (inBoundsY(ny) && grid[ny * gridW + nx] == El.water) {
            grid[ny * gridW + nx] = El.ice;
            life[ny * gridW + nx] = 0;
            markProcessed(ny * gridW + nx);
            break;
          }
        }
      }
    }

    // Snow compression into ice
    final ug = -gravityDir;
    int snowAbove = 0;
    for (int d = 1; d <= 4; d++) {
      final cy = y + ug * d;
      if (!inBoundsY(cy)) break;
      if (grid[cy * gridW + x] == El.snow) { snowAbove++; } else { break; }
    }
    if (snowAbove >= 3) {
      grid[idx] = El.ice; life[idx] = 0; markProcessed(idx); return;
    }

    // Snow falls every frame (gravity), but diagonal spread is gentle
    final by = y + gravityDir;
    if (inBoundsY(by) && grid[by * gridW + x] == El.empty) { swap(idx, by * gridW + x); return; }

    final dl = rng.nextBool();
    final sx1 = wrapX(dl ? x - 1 : x + 1);
    final sx2 = wrapX(dl ? x + 1 : x - 1);
    if (inBoundsY(by) && grid[by * gridW + sx1] == El.empty) { swap(idx, by * gridW + sx1); return; }
    if (inBoundsY(by) && grid[by * gridW + sx2] == El.empty) { swap(idx, by * gridW + sx2); return; }

    if (grid[idx] == El.snow && rng.nextInt(3) == 0) {
      _avalancheGranular(x, y, idx);
    }
  }

  // =========================================================================
  // Wood
  // =========================================================================

  void simWood(int x, int y, int idx) {
    if (life[idx] > 0) {
      life[idx]++;
      if (rng.nextInt(100) < 15) {
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            final nx = wrapX(x + dx);
            final ny = y + dy;
            if (!inBoundsY(ny)) continue;
            final ni = ny * gridW + nx;
            if (grid[ni] == El.wood && life[ni] == 0) {
              life[ni] = 1;
              break;
            }
          }
        }
      }
      if (life[idx] > 40 + rng.nextInt(20)) {
        grid[idx] = El.ash; life[idx] = 0; velY[idx] = 0; markProcessed(idx);
        final uy = y - gravityDir;
        if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
          grid[uy * gridW + x] = El.smoke; life[uy * gridW + x] = 0;
          markProcessed(uy * gridW + x);
        }
      }
      return;
    }

    if (checkAdjacent(x, y, El.water) && velY[idx] < 3) {
      if (rng.nextInt(30) == 0) {
        velY[idx] = (velY[idx] + 1).clamp(0, 3).toInt();
        removeOneAdjacent(x, y, El.water);
      }
    }

    if (velY[idx] >= 3) {
      final by = y + gravityDir;
      if (inBoundsY(by)) {
        final bi = by * gridW + x;
        if (grid[bi] == El.water) {
          final waterMass = life[bi];
          grid[idx] = El.water; life[idx] = waterMass < 20 ? 100 : waterMass;
          grid[bi] = El.wood; life[bi] = 0; velY[bi] = 3;
          markProcessed(idx); markProcessed(bi);
          return;
        }
      }
    }

    if (checkAdjacent(x, y, El.fire) || checkAdjacent(x, y, El.lava)) {
      if (velY[idx] < 3 || rng.nextInt(5) == 0) {
        life[idx] = 1; velY[idx] = 0;
        queueReactionFlash(x, y, 255, 150, 30, 3);
      }
    }
  }

  // =========================================================================
  // Metal
  // =========================================================================

  void simMetal(int x, int y, int idx) {
    if (life[idx] >= 200) return;

    if (checkAdjacent(x, y, El.water)) {
      life[idx]++;
      if (life[idx] > 120) {
        grid[idx] = El.dirt; life[idx] = 0; markProcessed(idx); return;
      }
    }

    if (rng.nextInt(100) == 0) {
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final ni = ny * gridW + nx;
          if (grid[ni] == El.empty && checkAdjacent(nx, ny, El.water)) {
            grid[ni] = El.water; life[ni] = 100; markProcessed(ni); return;
          }
        }
      }
    }
  }

  // =========================================================================
  // Smoke
  // =========================================================================

  void simSmoke(int x, int y, int idx) {
    life[idx]++;
    if (life[idx] > 60) {
      grid[idx] = El.empty; life[idx] = 0; return;
    }

    final uy = y - gravityDir;
    int drift = rng.nextInt(3) - 1;
    if (windForce != 0) {
      final windBias = windForce > 0 ? 1 : -1;
      if (rng.nextInt(3) < 2) drift = windBias;
    }

    if (inBoundsY(uy)) {
      final nx = wrapX(x + drift);
      if (grid[uy * gridW + nx] == El.empty) { swap(idx, uy * gridW + nx); return; }
      if (grid[uy * gridW + x] == El.empty) { swap(idx, uy * gridW + x); return; }
    }
    final side = wrapX(windForce != 0
        ? x + (windForce > 0 ? 1 : -1)
        : (rng.nextBool() ? x - 1 : x + 1));
    if (grid[y * gridW + side] == El.empty) {
      swap(idx, y * gridW + side);
    }
  }

  // =========================================================================
  // Bubble
  // =========================================================================

  void simBubble(int x, int y, int idx) {
    life[idx]++;

    final inWater = checkAdjacent(x, y, El.water);
    final uy = y - gravityDir;

    if (inWater) {
      if (life[idx] % 3 == 0 && inBoundsY(uy)) {
        final wobble = rng.nextInt(3) - 1;
        final riseX = wrapX(x + wobble);

        final ai = uy * gridW + riseX;
        if (grid[ai] == El.water) {
          grid[ai] = El.bubble; life[ai] = life[idx];
          grid[idx] = El.water; life[idx] = 100;
          markProcessed(ai); markProcessed(idx);
          return;
        }
        if (wobble != 0) {
          final straightUp = uy * gridW + x;
          if (grid[straightUp] == El.water) {
            grid[straightUp] = El.bubble; life[straightUp] = life[idx];
            grid[idx] = El.water; life[idx] = 100;
            markProcessed(straightUp); markProcessed(idx);
            return;
          }
        }
        // Pop at surface
        final surfaceIdx = uy * gridW + x;
        if (inBoundsY(uy) && grid[surfaceIdx] == El.empty) {
          grid[idx] = El.empty; life[idx] = 0;
          final droplets = 2 + rng.nextInt(3);
          for (int i = 0; i < droplets; i++) {
            final dx = rng.nextInt(5) - 2;
            final dy = -gravityDir * (rng.nextInt(3) + 1);
            final nx = wrapX(x + dx);
            final ny = y + dy;
            if (inBoundsY(ny) && grid[ny * gridW + nx] == El.empty) {
              grid[ny * gridW + nx] = El.water;
              life[ny * gridW + nx] = 60;
              markProcessed(ny * gridW + nx);
            }
          }
          queueReactionFlash(x, uy, 150, 210, 255, 3);
          return;
        }
      }
    } else {
      if (life[idx] > 20) {
        grid[idx] = El.empty; life[idx] = 0;
        queueReactionFlash(x, y, 130, 200, 240, 2);
      }
    }
  }

  // =========================================================================
  // Ash
  // =========================================================================

  void simAsh(int x, int y, int idx) {
    life[idx]++;
    final g = gravityDir;
    final by = y + g;

    // Fertilize dirt
    if (checkAdjacent(x, y, El.dirt)) {
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final ni = ny * gridW + nx;
          if (grid[ni] == El.dirt) {
            life[ni] = (life[ni] + 1).clamp(0, 4);
            grid[idx] = El.empty; life[idx] = 0; markProcessed(idx); return;
          }
        }
      }
    }

    // Ash in water
    final inWaterCheck = checkAdjacent(x, y, El.water);
    if (inWaterCheck) {
      velX[idx] = (velX[idx] + 1).clamp(0, 127).toInt();

      int waterCount = 0;
      for (int dy2 = -3; dy2 <= 3; dy2++) {
        for (int dx2 = -3; dx2 <= 3; dx2++) {
          final nx = wrapX(x + dx2);
          final ny = y + dy2;
          if (inBoundsY(ny) && grid[ny * gridW + nx] == El.water) waterCount++;
        }
      }

      final isLargeBody = waterCount > 20;

      if (isLargeBody) {
        if (velX[idx] > 15) {
          grid[idx] = El.empty; life[idx] = 0; velX[idx] = 0; return;
        }
      } else {
        if (velX[idx] < 30) {
          if (rng.nextInt(3) == 0) {
            final side = wrapX(rng.nextBool() ? x - 1 : x + 1);
            if (grid[y * gridW + side] == El.empty) {
              swap(idx, y * gridW + side);
            }
          }
          return;
        }
        if (life[idx] % 3 == 0 && inBoundsY(by)) {
          final bi = by * gridW + x;
          if (grid[bi] == El.water) {
            final waterMass2 = life[bi];
            grid[idx] = El.water; grid[bi] = El.ash;
            life[bi] = life[idx]; velX[bi] = velX[idx];
            life[idx] = waterMass2 < 20 ? 100 : waterMass2;
            velX[idx] = 0;
            markProcessed(idx); markProcessed(bi);
            return;
          }
        }
      }
      return;
    } else {
      velX[idx] = 0;
    }

    // Very slow fall
    if (life[idx] % 3 != 0) return;

    if (inBoundsY(by)) {
      final below = by * gridW + x;
      if (grid[below] == El.empty) { swap(idx, below); return; }
      if (grid[below] == El.water) return;
    }

    final dl = rng.nextBool();
    final ax1 = wrapX(dl ? x - 1 : x + 1);
    final ax2 = wrapX(dl ? x + 1 : x - 1);
    if (inBoundsY(by) && grid[by * gridW + ax1] == El.empty) { swap(idx, by * gridW + ax1); return; }
    if (inBoundsY(by) && grid[by * gridW + ax2] == El.empty) { swap(idx, by * gridW + ax2); return; }

    if (rng.nextInt(3) == 0) {
      final sx = wrapX(rng.nextBool() ? x - 1 : x + 1);
      if (grid[y * gridW + sx] == El.empty) { swap(idx, y * gridW + sx); }
    }
  }

  // =========================================================================
  // TNT
  // =========================================================================

  void simTNT(int x, int y, int idx) {
    fallGranular(x, y, idx, El.tnt);
  }

  // =========================================================================
  // Rainbow
  // =========================================================================

  void simRainbow(int x, int y, int idx) {
    final uy = y - gravityDir;
    if (rng.nextInt(2) == 0 && inBoundsY(uy)) {
      if (grid[uy * gridW + x] == El.empty) {
        swap(idx, uy * gridW + x);
        life[idx] = (life[idx] + 1) % 255;
        return;
      }
      final side = wrapX(rng.nextBool() ? x - 1 : x + 1);
      if (grid[uy * gridW + side] == El.empty) {
        swap(idx, uy * gridW + side);
      }
    }
    life[idx] = (life[idx] + 1) % 255;
  }

  // =========================================================================
  // Mud
  // =========================================================================

  void simMud(int x, int y, int idx) {
    if (rng.nextInt(20) == 0 && (checkAdjacent(x, y, El.fire) || checkAdjacent(x, y, El.lava))) {
      grid[idx] = El.dirt; life[idx] = 0; markProcessed(idx);
      queueReactionFlash(x, y, 180, 180, 200, 2);
      return;
    }

    final g = gravityDir;
    final by = y + g;

    // Gravity always applies — mud falls every frame
    if (inBoundsY(by) && grid[by * gridW + x] == El.empty) { swap(idx, by * gridW + x); return; }

    // Density displacement: mud (120) sinks through lighter liquids
    if (tryDensityDisplace(x, y, idx, El.mud)) return;

    // Legacy water displacement
    if (inBoundsY(by) && grid[by * gridW + x] == El.water) {
      final bi = by * gridW + x;
      final waterMass = life[bi];
      grid[idx] = El.water; life[idx] = waterMass < 20 ? 100 : waterMass;
      grid[bi] = El.mud; life[bi] = 0;
      markProcessed(idx); markProcessed(bi);
      return;
    }

    final dl = rng.nextBool();
    final mx1 = wrapX(dl ? x - 1 : x + 1);
    final mx2 = wrapX(dl ? x + 1 : x - 1);
    if (inBoundsY(by) && grid[by * gridW + mx1] == El.empty) { swap(idx, by * gridW + mx1); return; }
    if (inBoundsY(by) && grid[by * gridW + mx2] == El.empty) { swap(idx, by * gridW + mx2); return; }

    // Viscous lateral spread — uses property viscosity (mud=3)
    if (frameCount % elementViscosity[El.mud] == 0) {
      if (grid[y * gridW + mx1] == El.empty) { swap(idx, y * gridW + mx1); return; }
      if (grid[y * gridW + mx2] == El.empty) { swap(idx, y * gridW + mx2); }
    }
  }

  // =========================================================================
  // Steam
  // =========================================================================

  void simSteam(int x, int y, int idx) {
    // Temperature-driven condensation (steam -> water when cold)
    if (checkTemperatureReaction(x, y, idx, El.steam)) return;

    final lifeVal = life[idx];
    if (lifeVal < 250) life[idx] = lifeVal + 1;
    final uy = y - gravityDir;
    final atEdge = gravityDir == 1 ? y <= 2 : y >= gridH - 3;

    // Underground steam lasts longer — trapped in cave ceilings
    bool isTrappedUnderground = false;
    if (inBoundsY(uy)) {
      final above = grid[uy * gridW + x];
      if (above == El.stone || above == El.dirt || above == El.metal) {
        isTrappedUnderground = true;
      }
    }

    final steamLife = isTrappedUnderground
        ? (isNight ? 120 + rng.nextInt(60) : 160 + rng.nextInt(80))
        : (isNight ? 40 + rng.nextInt(20) : 80 + rng.nextInt(40));

    if (life[idx] > steamLife) {
      if (!atEdge && rng.nextInt(isNight ? 2 : 3) == 0) {
        grid[idx] = El.water; life[idx] = 100;
      } else {
        grid[idx] = El.empty; life[idx] = 0;
      }
      markProcessed(idx);
      return;
    }
    if (atEdge) {
      grid[idx] = El.empty; life[idx] = 0; markProcessed(idx); return;
    }

    // Condensation at altitude (water cycle): steam in top 10% of grid
    // has a chance to condense into water droplets (rain).
    final topThreshold = gravityDir == 1 ? gridH ~/ 10 : gridH - (gridH ~/ 10);
    final isAtAltitude = gravityDir == 1 ? y < topThreshold : y > topThreshold;
    if (isAtAltitude && rng.nextInt(isNight ? 80 : 150) == 0) {
      grid[idx] = El.water;
      life[idx] = 100;
      markProcessed(idx);
      return;
    }

    final condenseChance = isNight ? 15 : 30;
    if (rng.nextInt(condenseChance) == 0 && checkAdjacent(x, y, El.water)) {
      grid[idx] = El.water; life[idx] = 100; markProcessed(idx); return;
    }

    // Trapped steam dissipates slowly through cracks
    if (isTrappedUnderground && rng.nextInt(40) == 0) {
      // Look for gaps in the ceiling to seep through
      for (final dx in [-1, 0, 1]) {
        final nx = wrapX(x + dx);
        final uy2 = uy - gravityDir;
        if (inBoundsY(uy2) && grid[uy2 * gridW + nx] == El.empty) {
          // Found a crack — move through
          if (inBoundsY(uy) && grid[uy * gridW + nx] == El.empty) {
            swap(idx, uy * gridW + nx);
            return;
          }
        }
      }
      // Spread laterally along ceiling
      for (final dx in [1, -1]) {
        final nx = wrapX(x + dx);
        if (grid[y * gridW + nx] == El.empty) {
          swap(idx, y * gridW + nx);
          return;
        }
      }
    }

    if (inBoundsY(uy)) {
      final drift = rng.nextInt(3) - 1;
      final nx = wrapX(x + drift);
      if (grid[uy * gridW + nx] == El.empty) { swap(idx, uy * gridW + nx); return; }
      if (grid[uy * gridW + x] == El.empty) { swap(idx, uy * gridW + x); return; }
    }
    final side = wrapX(rng.nextBool() ? x - 1 : x + 1);
    if (grid[y * gridW + side] == El.empty) { swap(idx, y * gridW + side); }
  }

  // =========================================================================
  // Oil
  // =========================================================================

  void simOil(int x, int y, int idx) {
    // Temperature-driven boiling (oil -> smoke at high temp)
    if (checkTemperatureReaction(x, y, idx, El.oil)) return;

    if (checkAdjacent(x, y, El.fire)) {
      grid[idx] = El.fire; life[idx] = 0; markProcessed(idx); return;
    }

    final by = y + gravityDir;
    final uy = y - gravityDir;

    // Density-based buoyancy: oil floats up through heavier liquids (water)
    if (tryBuoyancy(x, y, idx, El.oil)) return;

    // Fall through empty
    if (inBoundsY(by) && grid[by * gridW + x] == El.empty) { swap(idx, by * gridW + x); return; }

    // Legacy buoyancy through water (kept for reliable behavior)
    final notProcessed = (simClock ? 0x80 : 0);
    if (inBoundsY(by) && grid[by * gridW + x] == El.water &&
        (flags[by * gridW + x] & 0x80) != notProcessed) {
      final bi = by * gridW + x;
      final waterMass = life[bi];
      grid[bi] = El.oil; life[bi] = life[idx];
      grid[idx] = El.water; life[idx] = waterMass < 20 ? 100 : waterMass;
      markProcessed(bi); markProcessed(idx);
      return;
    }

    // Upward buoyancy through water
    if (inBoundsY(uy) && grid[uy * gridW + x] == El.water &&
        (flags[uy * gridW + x] & 0x80) != notProcessed) {
      final ui2 = uy * gridW + x;
      final waterMass = life[ui2];
      grid[ui2] = El.oil; life[ui2] = life[idx];
      grid[idx] = El.water; life[idx] = waterMass < 20 ? 100 : waterMass;
      markProcessed(ui2); markProcessed(idx);
      return;
    }

    final dl = rng.nextBool();
    final ox1 = wrapX(dl ? x - 1 : x + 1);
    final ox2 = wrapX(dl ? x + 1 : x - 1);

    // Diagonal buoyancy
    for (final sx in [ox1, ox2]) {
      if (inBoundsY(by) && grid[by * gridW + sx] == El.water &&
          (flags[by * gridW + sx] & 0x80) != notProcessed) {
        final si = by * gridW + sx;
        final waterMass = life[si];
        grid[si] = El.oil; life[si] = life[idx];
        grid[idx] = El.water; life[idx] = waterMass < 20 ? 100 : waterMass;
        markProcessed(si); markProcessed(idx);
        return;
      }
    }

    if (inBoundsY(by) && grid[by * gridW + ox1] == El.empty) { swap(idx, by * gridW + ox1); return; }
    if (inBoundsY(by) && grid[by * gridW + ox2] == El.empty) { swap(idx, by * gridW + ox2); return; }

    // Surface tension: isolated oil droplets resist lateral spread
    final oilSt = elementSurfaceTension[El.oil];
    if (oilSt > 0) {
      int oilNeighbors = 0;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (inBoundsY(ny) && grid[ny * gridW + nx] == El.oil) oilNeighbors++;
        }
      }
      if (oilNeighbors <= 1 && oilSt > 3 && rng.nextBool()) return;
    }

    // Lateral spread — viscosity-throttled (oil viscosity = 2)
    if (frameCount % elementViscosity[El.oil] == 0) {
      if (grid[y * gridW + ox1] == El.empty) { swap(idx, y * gridW + ox1); return; }
      if (grid[y * gridW + ox2] == El.empty) { swap(idx, y * gridW + ox2); }
    }
  }

  // =========================================================================
  // Acid
  // =========================================================================

  void simAcid(int x, int y, int idx) {
    life[idx]++;

    if (life[idx] > 120 + rng.nextInt(60)) {
      grid[idx] = El.empty; life[idx] = 0; return;
    }

    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = wrapX(x + dx);
        final ny = y + dy;
        if (!inBoundsY(ny)) continue;
        final ni = ny * gridW + nx;
        final neighbor = grid[ni];

        // Hardness-driven acid dissolving: probability = (255 - hardness) / 255 * baseChance
        final neighborHardness = neighbor < maxElements ? elementHardness[neighbor] : 0;
        if (neighborHardness > 0 && neighbor != El.empty && neighbor != El.water &&
            neighbor != El.fire && neighbor != El.acid && neighbor != El.lava) {
          final dissolveProb = ((255 - neighborHardness) * 10) ~/ 255 + 3; // 3-13 range
          if (rng.nextInt(dissolveProb * 3) == 0) {
            grid[ni] = El.empty; life[ni] = 0; markProcessed(ni);
            grid[idx] = El.empty; life[idx] = 0;
            queueReactionFlash(nx, ny, 60, 230, 60, 4);
            return;
          }
        }
        if (neighbor == El.ant) {
          grid[ni] = El.empty; life[ni] = 0; markProcessed(ni);
        }
        if (neighbor == El.water && rng.nextInt(8) == 0) {
          grid[idx] = El.water; life[idx] = 100; markProcessed(idx); return;
        }
        if ((neighbor == El.plant || neighbor == El.seed) && rng.nextInt(3) == 0) {
          grid[ni] = El.empty; life[ni] = 0; markProcessed(ni);
          queueReactionFlash(nx, ny, 40, 200, 40, 2);
        }
        if (neighbor == El.wood && rng.nextInt(12) == 0) {
          grid[ni] = El.empty; life[ni] = 0; markProcessed(ni);
          grid[idx] = El.empty; life[idx] = 0;
          queueReactionFlash(nx, ny, 60, 220, 40, 4);
          return;
        }
        if (neighbor == El.ice && rng.nextInt(8) == 0) {
          grid[ni] = El.water; life[ni] = 80; markProcessed(ni);
          queueReactionFlash(nx, ny, 80, 255, 120, 3);
        }
        if (neighbor == El.lava && rng.nextInt(5) == 0) {
          // Acid + lava: violent reaction producing steam and smoke
          grid[ni] = El.steam; life[ni] = 0; markProcessed(ni);
          grid[idx] = El.smoke; life[idx] = 0; markProcessed(idx);
          queueReactionFlash(nx, ny, 200, 255, 100, 6);
          return;
        }
        if (neighbor == El.water && rng.nextInt(20) == 0) {
          grid[ni] = El.bubble; life[ni] = 0; markProcessed(ni);
        }
      }
    }

    final by = y + gravityDir;
    if (inBoundsY(by) && grid[by * gridW + x] == El.empty) { swap(idx, by * gridW + x); return; }

    final dl = rng.nextBool();
    final acx1 = wrapX(dl ? x - 1 : x + 1);
    final acx2 = wrapX(dl ? x + 1 : x - 1);
    if (inBoundsY(by) && grid[by * gridW + acx1] == El.empty) { swap(idx, by * gridW + acx1); return; }
    if (inBoundsY(by) && grid[by * gridW + acx2] == El.empty) { swap(idx, by * gridW + acx2); return; }
    if (grid[y * gridW + acx1] == El.empty) { swap(idx, y * gridW + acx1); return; }
    if (grid[y * gridW + acx2] == El.empty) { swap(idx, y * gridW + acx2); }
  }

  // =========================================================================
  // Stone (heated stone cooling)
  // =========================================================================

  void simStone(int x, int y, int idx) {
    // Temperature-driven melting (stone -> lava at extreme heat)
    if (checkTemperatureReaction(x, y, idx, El.stone)) return;

    final heat = velX[idx];

    // Depth tracking: life encodes how deep this stone is (stone cells above).
    // Updated infrequently to save perf. life 0 = surface, up to 20 = deep.
    if (frameCount % 60 == 0 && life[idx] == 0) {
      int depth = 0;
      for (int cy = y - gravityDir; depth < 20 && inBoundsY(cy); cy -= gravityDir) {
        final above = grid[cy * gridW + x];
        if (above == El.stone || above == El.metal || above == El.dirt) {
          depth++;
        } else {
          break;
        }
      }
      if (depth > 0) {
        life[idx] = depth.clamp(0, 20);
        markDirty(x, y);
      }
    }

    if (heat <= 0) return;

    // Slow cooling when not adjacent to heat sources
    if (frameCount % 8 == 0) {
      final nearHeat = checkAdjacent(x, y, El.lava) || checkAdjacent(x, y, El.fire);
      if (!nearHeat) {
        velX[idx] = (heat - 1).clamp(0, 5);
        markDirty(x, y);
      }
    }

    // Very hot stone can crack into lava if adjacent to enough lava
    if (heat >= 5 && rng.nextInt(200) == 0) {
      int lavaCount = 0;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (inBoundsY(ny) && grid[ny * gridW + nx] == El.lava) lavaCount++;
        }
      }
      if (lavaCount >= 3) {
        grid[idx] = El.lava;
        life[idx] = 0;
        velX[idx] = 0;
        markProcessed(idx);
        queueReactionFlash(x, y, 255, 150, 30, 4);
      }
    }
  }

  // =========================================================================
  // Glass (structural with shimmer)
  // =========================================================================

  void simGlass(int x, int y, int idx) {
    // Temperature-driven melting (glass -> sand at high temp)
    if (checkTemperatureReaction(x, y, idx, El.glass)) return;

    // Glass shatters when adjacent to explosions (handled by explosion system)
    // Glass melts back to sand when adjacent to lava for extended time
    if (checkAdjacent(x, y, El.lava)) {
      life[idx]++;
      if (life[idx] > 80 + rng.nextInt(40)) {
        grid[idx] = El.sand;
        life[idx] = 0;
        markProcessed(idx);
        queueReactionFlash(x, y, 255, 200, 100, 3);
      }
    } else if (life[idx] > 0 && !checkAdjacent(x, y, El.fire)) {
      // Cool down when not near heat
      if (frameCount % 10 == 0) life[idx] = (life[idx] - 1).clamp(0, 255);
    }
  }

  // =========================================================================
  // Avalanche (shared by sand, snow)
  // =========================================================================

  void _avalancheGranular(int x, int y, int idx) {
    final g = gravityDir;
    final by = y + g;
    if (!inBoundsY(by) || grid[by * gridW + x] == El.empty) return;

    final goLeft = rng.nextBool();
    final dir1 = goLeft ? -1 : 1;
    final dir2 = goLeft ? 1 : -1;

    for (final dir in [dir1, dir2]) {
      final sx = wrapX(x + dir);
      final sy = y;
      final sx2 = wrapX(x + dir * 2);
      final sy2 = y + g;
      if (grid[sy * gridW + sx] == El.empty &&
          inBoundsY(sy2) && grid[sy2 * gridW + sx] == El.empty) {
        swap(idx, sy2 * gridW + sx);
        return;
      }
      if (grid[sy * gridW + sx] == El.empty &&
          inBoundsY(sy2) && grid[sy2 * gridW + sx2] == El.empty &&
          grid[sy * gridW + sx2] == El.empty) {
        swap(idx, sy * gridW + sx);
        return;
      }
    }
  }

  // =========================================================================
  // Ant Colony AI
  // =========================================================================

  /// Evaporate both pheromone grids (call every ~8 frames).
  void evaporatePheromones() {
    final total = gridW * gridH;
    final pf = pheroFood;
    final ph = pheroHome;
    for (int i = 0; i < total; i++) {
      if (pf[i] > 0) pf[i] = pf[i] - 1;
      if (ph[i] > 0) ph[i] = ph[i] - 1;
    }
  }

  /// Diffuse pheromones to cardinal neighbors (restricted to dirty chunks).
  void diffusePheromones() {
    final w = gridW;
    final h = gridH;
    final g = grid;
    final pf = pheroFood;
    final ph = pheroHome;
    final dc = dirtyChunks;
    final cols = chunkCols;
    final rows = chunkRows;

    for (int cy = 0; cy < rows; cy++) {
      final chunkRowBase = cy * cols;
      final yStart = (cy * 16).clamp(1, h - 2);
      final yEnd = ((cy + 1) * 16).clamp(1, h - 2);

      for (int cx = 0; cx < cols; cx++) {
        if (dc[chunkRowBase + cx] == 0) continue;

        final xStart = (cx * 16).clamp(1, w - 2);
        final xEnd = ((cx + 1) * 16).clamp(1, w - 2);

        for (int y = yStart; y < yEnd; y++) {
          final row = y * w;
          for (int x = xStart; x < xEnd; x++) {
            final i = row + x;
            final fv = pf[i];
            if (fv > 2) {
              final spread = fv >> 3;
              if (spread > 0) {
                if (g[i - 1] == El.empty) pf[i - 1] = (pf[i - 1] + spread).clamp(0, 255);
                if (g[i + 1] == El.empty) pf[i + 1] = (pf[i + 1] + spread).clamp(0, 255);
                if (g[i - w] == El.empty) pf[i - w] = (pf[i - w] + spread).clamp(0, 255);
                if (g[i + w] == El.empty) pf[i + w] = (pf[i + w] + spread).clamp(0, 255);
              }
            }
            final hv = ph[i];
            if (hv > 2) {
              final spread = hv >> 3;
              if (spread > 0) {
                if (g[i - 1] == El.empty) ph[i - 1] = (ph[i - 1] + spread).clamp(0, 255);
                if (g[i + 1] == El.empty) ph[i + 1] = (ph[i + 1] + spread).clamp(0, 255);
                if (g[i - w] == El.empty) ph[i - w] = (ph[i - w] + spread).clamp(0, 255);
                if (g[i + w] == El.empty) ph[i + w] = (ph[i + w] + spread).clamp(0, 255);
              }
            }
          }
        }
      }
    }
  }

  /// Update colony centroid from dirty chunks.
  void updateColonyCentroid() {
    int sumX = 0, sumY = 0, count = 0;
    final w = gridW;
    final h = gridH;
    final dc = dirtyChunks;
    final cols = chunkCols;
    final rows = chunkRows;

    for (int cy = 0; cy < rows; cy++) {
      final chunkRowBase = cy * cols;
      final yStart = cy * 16;
      final yEnd = (yStart + 16).clamp(0, h);

      for (int cx = 0; cx < cols; cx++) {
        if (dc[chunkRowBase + cx] == 0) continue;

        final xStart = cx * 16;
        final xEnd = (xStart + 16).clamp(0, w);

        for (int y = yStart; y < yEnd; y++) {
          final rowOff = y * w;
          for (int x = xStart; x < xEnd; x++) {
            if (grid[rowOff + x] == El.ant) {
              sumX += x; sumY += y; count++;
            }
          }
        }
      }
    }
    if (count > 0) {
      colonyX = sumX ~/ count;
      colonyY = sumY ~/ count;
    }
  }

  bool _isUnderground(int x, int y) {
    final g = gravityDir;
    final aboveY = y - g;
    if (!inBoundsY(aboveY)) return false;
    final above = grid[aboveY * gridW + x];
    return above == El.dirt || above == El.mud || above == El.stone ||
        above == El.sand || above == El.ant;
  }

  int _antPheromoneDir(int x, int y, int dir, Uint8List pheroGrid) {
    final w = gridW;
    if (rng.nextInt(20) == 0) return rng.nextBool() ? 1 : -1;

    int bestDir = dir;
    int bestScore = -1;

    final fwdX = wrapX(x + dir);
    {
      final score = pheroGrid[y * w + fwdX] + rng.nextInt(10);
      if (score > bestScore) { bestScore = score; bestDir = dir; }
    }
    final uy = y - gravityDir;
    if (inBoundsY(uy)) {
      final score = pheroGrid[uy * w + fwdX] + rng.nextInt(10);
      if (score > bestScore) { bestScore = score; bestDir = dir; }
    }
    final bwdX = wrapX(x - dir);
    {
      final score = pheroGrid[y * w + bwdX] + rng.nextInt(10);
      if (score > bestScore) { bestScore = score; bestDir = -dir; }
    }

    return bestScore > 5 ? bestDir : dir;
  }

  void _fireAlarm(int x, int y) {
    final w = gridW;
    for (int dy = -4; dy <= 4; dy++) {
      for (int dx = -4; dx <= 4; dx++) {
        final nx = wrapX(x + dx); final ny = y + dy;
        if (!inBoundsY(ny)) continue;
        final ni = ny * w + nx;
        if (grid[ni] == El.ant) {
          final fleeDir = dx >= 0 ? 1 : -1;
          velX[ni] = fleeDir;
          if (velY[ni] != antDrowningBase && velY[ni] < antDrowningBase) {
            flags[ni] = (flags[ni] & 0xF0) | _antAlarmFlag;
          }
        }
      }
    }
  }

  // =========================================================================
  // Ant simulation
  // =========================================================================

  void simAnt(int x, int y, int idx) {
    int state = velY[idx];

    final isCarrying = (state == antCarrierState);
    if (!isCarrying && frameCount % 2 != 0) return;

    final g = gravityDir;
    final by = y + g;
    final uy = y - g;
    final homeX = life[idx];
    final w = gridW;

    // Acid dissolves ants
    if (checkAdjacent(x, y, El.acid)) {
      grid[idx] = El.empty; life[idx] = 0; velY[idx] = 0; return;
    }

    // Fire/lava: flee and alarm
    if (senseDanger(x, y, 1)) {
      final hasFire = checkAdjacent(x, y, El.fire) || checkAdjacent(x, y, El.lava);
      if (hasFire) {
        _fireAlarm(x, y);
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            final nx2 = wrapX(x + dx); final ny2 = y + dy;
            if (!inBoundsY(ny2)) continue;
            if (grid[ny2 * w + nx2] == El.empty && !senseDanger(nx2, ny2, 1)) {
              swap(idx, ny2 * w + nx2); return;
            }
          }
        }
        grid[idx] = El.empty; life[idx] = 0; velY[idx] = 0; return;
      }

      if ((flags[idx] & _antAlarmFlag) == 0) _fireAlarm(x, y);
    }

    // Alarmed ant fleeing
    if ((flags[idx] & _antAlarmFlag) != 0) {
      flags[idx] = flags[idx] & ~_antAlarmFlag;
      final fleeDir = velX[idx];
      final nx = wrapX(x + fleeDir);
      if (grid[y * w + nx] == El.empty) { swap(idx, y * w + nx); return; }
      if (inBoundsY(uy) && grid[uy * w + nx] == El.empty) { swap(idx, uy * w + nx); return; }
    }

    // Drowning
    if (checkAdjacent(x, y, El.water)) {
      if (state < antDrowningBase) { velY[idx] = antDrowningBase; state = antDrowningBase; }
      if (inBoundsY(uy) && rng.nextInt(3) == 0) {
        final ac = grid[uy * w + x];
        if (ac == El.empty || ac == El.water) { swap(idx, uy * w + x); return; }
      }
      for (final dir in [1, -1]) {
        final sx = wrapX(x + dir);
        if (grid[y * w + sx] == El.empty) { swap(idx, y * w + sx); return; }
      }
      velY[idx] = (state + 1);
      if (velY[idx] > 100) { grid[idx] = El.empty; life[idx] = 0; velY[idx] = 0; }
      return;
    }
    if (state >= antDrowningBase) { velY[idx] = 0; state = 0; }

    // Bridge ant
    if ((flags[idx] & _antBridgeFlag) != 0) {
      if (frameCount % 4 == 0) {
        if (inBoundsY(uy) && grid[uy * w + x] != El.ant) {
          final bridgeAge = (life[idx] >> 4) & 0x0F;
          if (bridgeAge > 8) {
            flags[idx] = flags[idx] & ~_antBridgeFlag;
            velY[idx] = antExplorerState;
          } else {
            life[idx] = (life[idx] & 0x0F) | ((bridgeAge + 1) << 4);
          }
        }
      }
      return;
    }

    // Initialize
    if (life[idx] == 0) {
      life[idx] = x.clamp(1, 255);
      if (colonyX < 0) { colonyX = x; colonyY = y; }
    }
    if (velX[idx] == 0) velX[idx] = rng.nextBool() ? 1 : -1;

    // Gravity
    if (inBoundsY(by) && grid[by * w + x] == El.empty) { swap(idx, by * w + x); return; }

    // -- NEAT neural integration: if a colony manages this ant, use brain ---
    if (creatureCallback != null && frameCount % 3 == 0) {
      final decision = creatureCallback!(x, y);
      if (decision.isNotEmpty) {
        final ndx = (decision['dx'] ?? 0.0).toInt().clamp(-1, 1);
        final ndy = (decision['dy'] ?? 0.0).toInt().clamp(-1, 1);
        final wantsPickup = (decision['pickup'] ?? 0.0) > 0.5;
        final wantsDrop = (decision['drop'] ?? 0.0) > 0.5;
        final pheromone = decision['pheromone'] ?? 0.0;

        // Neural-driven movement
        if (ndx != 0 || ndy != 0) {
          final nx = wrapX(x + ndx);
          final ny = y + ndy;
          if (inBoundsY(ny)) {
            final targetEl = grid[ny * w + nx];
            if (targetEl == El.empty) {
              velX[idx] = ndx;
              swap(idx, ny * w + nx);
            } else if (targetEl == El.dirt && rng.nextInt(3) == 0) {
              // Neural-driven digging
              grid[ny * w + nx] = El.empty;
              life[ny * w + nx] = 0;
              markDirty(nx, ny);
              swap(idx, ny * w + nx);
              velY[idx] = antCarrierState;
            } else if (ndx != 0 && grid[y * w + nx] == El.empty) {
              velX[idx] = ndx;
              swap(idx, y * w + nx);
            }
          }
        }

        // Neural-driven food pickup
        if (wantsPickup && state != antCarrierState) {
          for (int dy2 = -1; dy2 <= 1; dy2++) {
            for (int dx2 = -1; dx2 <= 1; dx2++) {
              if (dx2 == 0 && dy2 == 0) continue;
              final fx = wrapX(x + dx2);
              final fy = y + dy2;
              if (!inBoundsY(fy)) continue;
              final fi = fy * w + fx;
              final fe = grid[fi];
              if (fe == El.seed || fe == El.plant) {
                grid[fi] = El.empty; life[fi] = 0; markDirty(fx, fy);
                velY[idx] = antCarrierState;
                pheroFood[idx] = 200;
                break;
              }
            }
            if (velY[idx] == antCarrierState) break;
          }
        }

        // Neural-driven drop
        if (wantsDrop && state == antCarrierState) {
          for (int dy2 = -1; dy2 <= 1; dy2++) {
            for (int dx2 = -1; dx2 <= 1; dx2++) {
              if (dx2 == 0 && dy2 == 0) continue;
              final dx3 = wrapX(x + dx2);
              final dy3 = y + dy2;
              if (!inBoundsY(dy3)) continue;
              if (grid[dy3 * w + dx3] == El.empty) {
                grid[dy3 * w + dx3] = El.dirt;
                life[dy3 * w + dx3] = 0;
                markDirty(dx3, dy3);
                velY[idx] = antExplorerState;
                break;
              }
            }
            if (velY[idx] == antExplorerState) break;
          }
        }

        // Neural-driven pheromone deposit
        if (pheromone > 0.1) {
          final strength = (pheromone * 200).clamp(0, 250).toInt();
          if (state == antCarrierState || state == antReturningState) {
            if (pheroFood[idx] < strength) pheroFood[idx] = strength;
          } else {
            if (pheroHome[idx] < strength) pheroHome[idx] = strength;
          }
        }

        return; // Neural decision handled — skip hardcoded state machine.
      }
    }

    // -- Fallback: hardcoded state machine (when no colony manages this ant) --

    // Pheromone deposit
    if (state == antExplorerState || state == antForagerState) {
      if (pheroHome[idx] < 120) pheroHome[idx] = 120;
    }
    if (state == antCarrierState || state == antReturningState) {
      if (pheroFood[idx] < 120) pheroFood[idx] = 120;
    }

    // Colony distance check
    if (colonyX >= 0 && state == antExplorerState) {
      final dist = (x - colonyX).abs() + (y - colonyY).abs();
      if (dist > 60 && rng.nextInt(8) == 0) {
        velY[idx] = antReturningState; state = antReturningState;
      }
    }

    // Recruitment
    if (state == antExplorerState && frameCount % 4 == 0) {
      int bestPhero = 0;
      for (int dy = -5; dy <= 5; dy++) {
        for (int dx = -5; dx <= 5; dx++) {
          final nx2 = wrapX(x + dx); final ny2 = y + dy;
          if (!inBoundsY(ny2)) continue;
          final ni = ny2 * w + nx2;
          if (pheroFood[ni] > bestPhero) bestPhero = pheroFood[ni];
        }
      }
      if (bestPhero > 100 && rng.nextInt(3) == 0) {
        velY[idx] = antForagerState; state = antForagerState;
      }
    }

    final underground = _isUnderground(x, y);
    final nearDirt = checkAdjacent(x, y, El.dirt);

    switch (state) {
      case antExplorerState: _antExplore(x, y, idx, homeX, nearDirt, underground);
      case antDiggerState: _antDig(x, y, idx, underground);
      case antCarrierState: _antCarry(x, y, idx, homeX);
      case antReturningState: _antReturn(x, y, idx, homeX);
      case antForagerState: _antForage(x, y, idx, homeX, nearDirt);
    }
  }

  void _antExplore(int x, int y, int idx, int homeX, bool nearDirt, bool underground) {
    int dir = velX[idx];

    final nearbyCategories = senseCategories(x, y, 3);

    if (nearDirt && rng.nextInt(4) == 0) {
      final nearbyAnts = countNearby(x, y, 2, El.ant);
      if (nearbyAnts < 5) { velY[idx] = antDiggerState; return; }
    }

    if ((nearbyCategories & ElCat.organic) != 0 && rng.nextInt(6) == 0) {
      final organicDir = findNearestDirection(x, y, 5, ElCat.organic);
      if (organicDir >= 0) {
        final odx = (organicDir ~/ 3) - 1;
        if (odx != 0) dir = odx;
      }
    }

    dir = _antPheromoneDir(x, y, dir, pheroFood);

    int targetDir = dir;
    bool foundTarget = false;
    for (int scanD = 1; scanD <= 8; scanD++) {
      for (final sd in [dir, -dir]) {
        final sx = wrapX(x + sd * scanD);
        final sc = grid[y * gridW + sx];
        if (sc == El.dirt || sc == El.mud || sc == El.plant || sc == El.seed) {
          targetDir = sd; foundTarget = true; break;
        }
        if (sc == El.ant && rng.nextInt(3) == 0) {
          targetDir = sd; foundTarget = true; break;
        }
        if (sc < El.count && (elCategory[sc] & (ElCat.danger | ElCat.liquid)) != 0) {
          if (sc == El.water || sc == El.oil || (elCategory[sc] & ElCat.danger) != 0) {
            if (sd == dir) targetDir = -dir;
            break;
          }
        }
      }
      if (foundTarget) break;
    }

    if (!foundTarget && colonyX >= 0) {
      final dist = (x - colonyX).abs() + (y - colonyY).abs();
      if (dist < 10 && rng.nextInt(3) == 0) {
        targetDir = (x >= colonyX) ? 1 : -1;
      }
    }

    _antMove(x, y, idx, targetDir);
  }

  void _antForage(int x, int y, int idx, int homeX, bool nearDirt) {
    int dir = velX[idx];

    if (nearDirt || checkAdjacent(x, y, El.plant) || checkAdjacent(x, y, El.seed)) {
      pheroFood[idx] = 200;
      _antRecruitNearby(x, y);
      if (nearDirt) {
        velY[idx] = antDiggerState;
      } else {
        velY[idx] = antCarrierState;
      }
      return;
    }

    dir = _antPheromoneDir(x, y, dir, pheroFood);

    int targetDir = dir;
    bool foundTarget = false;
    for (int scanD = 1; scanD <= 12; scanD++) {
      for (final sd in [dir, -dir]) {
        final sx = wrapX(x + sd * scanD);
        final sc = grid[y * gridW + sx];
        if (sc == El.dirt || sc == El.mud || sc == El.plant || sc == El.seed) {
          targetDir = sd; foundTarget = true; break;
        }
        if (sc < El.count && (elCategory[sc] & ElCat.danger) != 0) {
          if (sd == dir) targetDir = -dir; break;
        }
        if (sc == El.water || sc == El.oil) {
          if (sd == dir) targetDir = -dir; break;
        }
      }
      if (foundTarget) break;
    }

    if (!foundTarget && rng.nextInt(60) == 0) velY[idx] = antExplorerState;

    _antMove(x, y, idx, targetDir);
  }

  void _antRecruitNearby(int x, int y) {
    final w = gridW;
    for (int dy = -5; dy <= 5; dy++) {
      for (int dx = -5; dx <= 5; dx++) {
        final nx2 = wrapX(x + dx); final ny2 = y + dy;
        if (!inBoundsY(ny2)) continue;
        final ni = ny2 * w + nx2;
        if (grid[ni] == El.ant && velY[ni] == antExplorerState) {
          if (rng.nextInt(2) == 0) {
            velY[ni] = antForagerState;
            velX[ni] = dx >= 0 ? 1 : -1;
          }
        }
      }
    }
  }

  void _antDig(int x, int y, int idx, bool underground) {
    final g = gravityDir;
    final by = y + g;
    final dir = velX[idx];
    final w = gridW;

    bool tryDig(int tx, int ty) {
      tx = wrapX(tx);
      if (!inBoundsY(ty)) return false;
      final ti = ty * w + tx;
      final el = grid[ti];
      if (el == El.dirt) {
        if (rng.nextInt(4) == 0) {
          grid[ti] = El.empty; life[ti] = 0; swap(idx, ti);
          velY[idx] = antCarrierState; pheroFood[ti] = 200; return true;
        }
      } else if (el == El.sand) {
        if (rng.nextInt(2) == 0) {
          grid[ti] = El.empty; life[ti] = 0; swap(idx, ti);
          velY[idx] = antCarrierState; pheroFood[ti] = 200; return true;
        }
      }
      return false;
    }

    if (tryDig(x, by)) return;
    if (tryDig(x + dir, y)) return;
    if (inBoundsY(by) && rng.nextInt(5) == 0) {
      if (tryDig(x + dir, by)) return;
    }

    if (underground && rng.nextInt(12) == 0) {
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          final cx = wrapX(x + dx); final cy = y + dy;
          if (inBoundsY(cy) && grid[cy * w + cx] == El.dirt) {
            grid[cy * w + cx] = El.empty; life[cy * w + cx] = 0; markDirty(cx, cy);
          }
        }
      }
    }

    if (!checkAdjacent(x, y, El.dirt) && !checkAdjacent(x, y, El.sand)) {
      velY[idx] = antExplorerState;
    }

    _antMove(x, y, idx, dir);
  }

  void _antCarry(int x, int y, int idx, int homeX) {
    final g = gravityDir;
    final uy = y - g;
    final w = gridW;

    if (pheroFood[idx] < 80) pheroFood[idx] = 80;

    if (inBoundsY(uy)) {
      final aboveCell = grid[uy * w + x];
      if (aboveCell == El.empty) { swap(idx, uy * w + x); return; }
    }

    final atSurface = !inBoundsY(uy) ||
        (grid[uy * w + x] == El.empty && !_isUnderground(x, y));

    if (atSurface || !inBoundsY(uy)) {
      final depositY = uy;
      final toHome = (homeX - x).sign;

      final nearColony = colonyX >= 0 && (x - colonyX).abs() < 8;
      int depositEl = El.dirt;

      if (nearColony && rng.nextInt(3) == 0) {
        final sandCount = countNearby(x, y, 3, El.sand);
        final snowCount = countNearby(x, y, 3, El.snow);
        if (sandCount > 2) { depositEl = El.sand; }
        else if (snowCount > 2) { depositEl = El.snow; }
      }

      for (final depositDx in [toHome, 0, -toHome]) {
        final depositX = wrapX(x + depositDx);
        if (inBoundsY(depositY) && grid[depositY * w + depositX] == El.empty) {
          grid[depositY * w + depositX] = depositEl; life[depositY * w + depositX] = 0;
          markDirty(depositX, depositY);
          velY[idx] = antReturningState; return;
        }
      }
      for (final dx in [1, -1]) {
        final sx = wrapX(x + dx);
        if (grid[y * w + sx] == El.empty) {
          grid[y * w + sx] = depositEl; life[y * w + sx] = 0;
          markDirty(sx, y);
          velY[idx] = antReturningState; return;
        }
      }
      velY[idx] = antExplorerState; return;
    }

    final pheroDir = _antPheromoneDir(x, y, velX[idx], pheroHome);
    final toHome = (homeX - x).sign;
    final moveDir = toHome != 0 ? toHome : pheroDir;
    _antMove(x, y, idx, moveDir);
  }

  void _antReturn(int x, int y, int idx, int homeX) {
    final g = gravityDir;
    final by = y + g;
    final w = gridW;

    final toHome = (homeX - x).sign;

    if ((x - homeX).abs() <= 2) {
      if (inBoundsY(by) && grid[by * w + x] == El.empty) {
        swap(idx, by * w + x); velY[idx] = antExplorerState; return;
      }
      for (final dx in [0, 1, -1, 2, -2]) {
        final tx = wrapX(x + dx);
        if (inBoundsY(by) && grid[by * w + tx] == El.empty) {
          if (grid[y * w + tx] == El.empty) {
            swap(idx, y * w + tx); return;
          }
        }
      }
      velY[idx] = antExplorerState; return;
    }

    // Plant farming near colony
    if (colonyX >= 0 && (x - colonyX).abs() < 12) {
      final moistDirtDir = findNearestDirection(x, y, 4, ElCat.organic);
      if (moistDirtDir >= 0 && rng.nextInt(8) == 0) {
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            final nx = wrapX(x + dx); final ny = y + dy;
            if (!inBoundsY(ny)) continue;
            final ni = ny * w + nx;
            if (grid[ni] == El.empty) {
              final belowY = ny + gravityDir;
              if (inBoundsY(belowY) && grid[belowY * w + nx] == El.dirt) {
                if (countNearby(nx, ny, 2, El.water) > 0) {
                  grid[ni] = El.seed; life[ni] = 0; markDirty(nx, ny);
                  velY[idx] = antExplorerState; return;
                }
              }
            }
          }
        }
      }
    }

    final pheroDir = _antPheromoneDir(x, y, velX[idx], pheroHome);
    final moveDir = toHome != 0 ? toHome : pheroDir;
    _antMove(x, y, idx, moveDir);
  }

  /// Shared ant movement: walk, climb, bridge, reverse.
  void _antMove(int x, int y, int idx, int moveDir) {
    final g = gravityDir;
    final uy = y - g;
    final w = gridW;
    final nx = wrapX(x + moveDir);

    if (grid[y * w + nx] == El.empty) {
      velX[idx] = moveDir; swap(idx, y * w + nx); return;
    }

    if (inBoundsY(uy) && grid[uy * w + nx] == El.empty) {
      velX[idx] = moveDir; swap(idx, uy * w + nx); return;
    }

    // Bridge over water
    if (grid[y * w + nx] == El.water) {
      bool landAhead = false;
      for (int d = 2; d <= 4; d++) {
        final fx = wrapX(x + moveDir * d);
        final fe = grid[y * w + fx];
        if (fe != El.water && fe != El.empty) { landAhead = true; break; }
        if (fe == El.empty) { landAhead = true; break; }
      }
      if (landAhead && rng.nextInt(3) == 0) {
        final wi = y * w + nx;
        grid[wi] = El.ant; life[wi] = life[idx]; velX[wi] = moveDir;
        velY[wi] = antExplorerState;
        grid[idx] = El.empty; life[idx] = 0; velX[idx] = 0; velY[idx] = 0;
        markProcessed(wi); markProcessed(idx);
        flags[wi] = flags[wi] | _antBridgeFlag;
        return;
      }
    }

    // Walk on bridge ants
    if (grid[y * w + nx] == El.ant &&
        (flags[y * w + nx] & _antBridgeFlag) != 0) {
      if (inBoundsY(uy) && grid[uy * w + nx] == El.empty) {
        velX[idx] = moveDir; swap(idx, uy * w + nx); return;
      }
    }

    if (inBoundsY(uy) && grid[uy * w + x] == El.empty) {
      if (grid[y * w + nx] != El.empty) {
        swap(idx, uy * w + x); return;
      }
    }

    // Snow slows ants
    if (grid[y * w + nx] == El.snow) {
      if (rng.nextInt(3) == 0) { velX[idx] = moveDir; return; }
    }

    velX[idx] = -moveDir;
    if (rng.nextInt(6) == 0) velX[idx] = rng.nextBool() ? 1 : -1;
  }
}

// ---------------------------------------------------------------------------
// Top-level dispatch function
// ---------------------------------------------------------------------------

/// Dispatch function passed to [SimulationEngine.step].
///
/// Built-in elements are dispatched via a switch for maximum performance.
/// Custom elements (registered at runtime) are dispatched through the
/// [ElementRegistry.customBehaviors] function table.
void simulateElement(SimulationEngine e, int el, int x, int y, int idx) {
  switch (el) {
    case El.sand: e.simSand(x, y, idx);
    case El.water: e.simWater(x, y, idx);
    case El.fire: e.simFire(x, y, idx);
    case El.ice: e.simIce(x, y, idx);
    case El.lightning: e.simLightning(x, y, idx);
    case El.seed: e.simSeed(x, y, idx);
    case El.tnt: e.simTNT(x, y, idx);
    case El.rainbow: e.simRainbow(x, y, idx);
    case El.mud: e.simMud(x, y, idx);
    case El.steam: e.simSteam(x, y, idx);
    case El.ant: e.simAnt(x, y, idx);
    case El.oil: e.simOil(x, y, idx);
    case El.acid: e.simAcid(x, y, idx);
    case El.dirt: e.simDirt(x, y, idx);
    case El.plant: e.simPlant(x, y, idx);
    case El.lava: e.simLava(x, y, idx);
    case El.snow: e.simSnow(x, y, idx);
    case El.wood: e.simWood(x, y, idx);
    case El.metal: e.simMetal(x, y, idx);
    case El.smoke: e.simSmoke(x, y, idx);
    case El.bubble: e.simBubble(x, y, idx);
    case El.ash: e.simAsh(x, y, idx);
    case El.stone: e.simStone(x, y, idx);
    case El.glass: e.simGlass(x, y, idx);
    default:
      // Custom element: look up registered behavior function.
      final fn = ElementRegistry.customBehaviors[el];
      if (fn != null) {
        fn(e, x, y, idx);
      } else {
        // No custom behavior — try data-driven reactions from the registry.
        ReactionRegistry.executeReactions(e, el, x, y, idx);
      }
  }
}
