import 'dart:typed_data';

import 'element_registry.dart';
import 'plant_colony.dart';
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
    // Fall/sink first — sand should sink through water before dissolving
    fallGranular(x, y, idx, El.sand);
    if (grid[idx] == El.sand) {
      _avalancheGranular(x, y, idx);
    }
    
    // Sand absorbs moisture. If highly saturated, it turns into mud.
    final currentMoisture = moisture[idx];
    if (currentMoisture > 180) {
      final waterAbove = inBoundsY(y - gravityDir) &&
          grid[(y - gravityDir) * gridW + x] == El.water;
      final mudRate = waterAbove ? SimTuning.sandToMudSubmergedRate : SimTuning.sandToMudRate;
      if (rng.nextInt(mudRate) == 0) {
        grid[idx] = El.mud;
        markProcessed(idx);
        return;
      }
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

    // Thermal convection: hot water rises through cold water
    // Real physics: buoyancy force proportional to temperature difference
    if (frameCount % 4 == 0) {
      final myTemp = temperature[idx];
      if (inBoundsY(uy)) {
        final aboveIdx = uy * gridW + x;
        if (grid[aboveIdx] == El.water) {
          final aboveTemp = temperature[aboveIdx];
          // Hot water below cold water → swap (convection)
          if (myTemp > aboveTemp + 5 && rng.nextInt(4) == 0) {
            swap(idx, aboveIdx);
            return;
          }
        }
      }
    }

    final lifeVal = life[idx];
    final bool isSpecialState = lifeVal >= 140;
    int mass = isSpecialState ? 100 : (lifeVal < 20 ? 100 : lifeVal);
    if (!isSpecialState && lifeVal < 20) {
      life[idx] = 100;
    }

    // Stefan solidification: water adjacent to ice freezes via
    // heterogeneous nucleation. The ice surface provides a nucleation
    // template that lowers the energy barrier for crystal formation.
    // Real water nucleates heterogeneously at ~-1°C on ice surfaces
    // vs ~-40°C for homogeneous nucleation. The rate follows classical
    // nucleation theory: J ∝ exp(-ΔG*/kT), exponentially faster at
    // deeper subcooling.
    {
      final t = temperature[idx];
      if (t < 127 && checkAdjacent(x, y, El.ice)) {
        final subcooling = 127 - t; // 1..127
        // Deterministic freeze at deep subcooling (temp < 107)
        if (subcooling > 20) {
          grid[idx] = El.ice;
          temperature[idx] = (t - 10).clamp(0, 255); // latent heat absorbed
          markProcessed(idx);
          return;
        }
        // Probabilistic near threshold: 1/6 at 1° to 1/2 at 20°
        // Heterogeneous nucleation on ice surfaces has very low energy
        // barrier — even 1°C subcooling triggers rapid crystal growth.
        final rate = (6 - (subcooling * 4) ~/ 20).clamp(2, 6);
        if (rng.nextInt(rate) == 0) {
          grid[idx] = El.ice;
          temperature[idx] = (t - 5).clamp(0, 255); // latent heat absorbed
          markProcessed(idx);
          return;
        }
      }
    }

    // Surface evaporation (water cycle): surface water slowly evaporates.
    // Surface = no water directly above.
    // Near-heat evaporation is handled by the temperature system (checkTemperatureReaction).
    // Tuned for natural feel: evaporation should be rare except near heat.
    // At neutral temperature, a surface cell evaporates roughly once per
    // 50-80 real seconds — barely noticeable, like real ambient evaporation.
    {
      final aboveY = y - g;
      final isSurface = !inBoundsY(aboveY) ||
          (grid[aboveY * gridW + x] != El.water);
      if (isSurface) {
        final temp = temperature[idx];
        int evapRate;
        if (temp > 200) {
          evapRate = 80;       // Extreme heat (near lava): visible steam
        } else if (temp > 170) {
          evapRate = 250;      // Hot: occasional wisps
        } else if (temp > 145) {
          evapRate = 600;      // Warm: rare evaporation
        } else {
          evapRate = isNight ? 5000 : 3000; // Neutral: very rare ambient evaporation
        }
        if (rng.nextInt(evapRate) == 0) {
          // Deposit dissolved substance when water evaporates
          final dissolved = dissolvedType[idx];
          final conc = concentration[idx];
          if (dissolved != 0 && conc > 30) {
            // Leave behind solid deposit (salt crystals, etc.)
            grid[idx] = dissolved;
            life[idx] = 0;
            dissolvedType[idx] = 0;
            concentration[idx] = 0;
            pH[idx] = 128;
            markProcessed(idx);
            return;
          }
          grid[idx] = El.steam;
          life[idx] = 0;
          dissolvedType[idx] = 0;
          concentration[idx] = 0;
          // Evaporative cooling: the latent heat of vaporization
          // (2260 kJ/kg for water) is absorbed from surrounding cells,
          // cooling them. This is why sweating cools the body and why
          // wet-bulb temperature is always ≤ dry-bulb temperature.
          // Each evaporation event cools adjacent cells by ~5 units.
          for (int edy = -1; edy <= 1; edy++) {
            for (int edx = -1; edx <= 1; edx++) {
              if (edx == 0 && edy == 0) continue;
              final enx = wrapX(x + edx);
              final eny = y + edy;
              if (!inBoundsY(eny)) continue;
              final eni = eny * gridW + enx;
              final et = temperature[eni];
              if (et > 5) {
                temperature[eni] = et - 5;
              }
            }
          }
          markProcessed(idx);
          return;
        }
      }
    }

    // Leidenfrost effect: water on extremely hot surfaces forms a
    // protective vapor cushion. Instead of instant boiling, the water
    // droplet levitates on its own steam, dramatically increasing its
    // lifetime. Real Leidenfrost point for water ≈ 193°C (above 100°C BP).
    if (frameCount % 3 == 0) {
      final by2 = y + g;
      if (inBoundsY(by2)) {
        final belowIdx = by2 * gridW + x;
        final belowTemp = temperature[belowIdx];
        if (belowTemp > 220 && grid[belowIdx] != El.empty) {
          // Extreme heat below — Leidenfrost regime
          // Create steam cushion: spawn steam below if possible
          final uy2 = y - g;
          if (inBoundsY(uy2) && grid[uy2 * gridW + x] == El.empty) {
            // Bounce upward on vapor cushion
            swap(idx, uy2 * gridW + x);
            queueReactionFlash(x, y, 200, 220, 255, 3);
            return;
          }
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
        if (neighbor == El.tnt && rng.nextInt(SimTuning.waterTntDissolve) == 0) {
          grid[ni] = El.sand;
          life[ni] = 0;
          markProcessed(ni);
        }
        if (neighbor == El.smoke && rng.nextInt(SimTuning.waterSmokeDissolve) == 0) {
          grid[ni] = El.empty;
          life[ni] = 0;
          markProcessed(ni);
        }
        if (neighbor == El.rainbow && rng.nextInt(SimTuning.waterRainbowSpread) == 0) {
          final rx = wrapX(x + rng.nextInt(3) - 1);
          final ry = uy;
          if (inBoundsY(ry) && grid[ry * gridW + rx] == El.empty) {
            grid[ry * gridW + rx] = El.rainbow;
            life[ry * gridW + rx] = 0;
            markProcessed(ry * gridW + rx);
          }
        }
        if (neighbor == El.plant && rng.nextInt(SimTuning.waterPlantDamage) == 0) {
          if (life[ni] > 2) life[ni] -= 2;
        }
        // Acidic water (low pH from dissolved CO2 or acid contact) damages plants
        if (neighbor == El.plant && pH[idx] < 80 && rng.nextInt(SimTuning.waterAcidPlantDamage) == 0) {
          final acidDmg = (80 - pH[idx]) >> 4; // stronger acid = more damage
          final plantLife = life[ni];
          life[ni] = plantLife > acidDmg ? plantLife - acidDmg : 0;
          markDirty(nx, ny);
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
    if (mass > 130 && rng.nextInt(SimTuning.waterBubbleRate) == 0) {
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

    // Pressure-driven momentum: deep water flows faster laterally
    // Real physics: flow velocity ~ sqrt(pressure * 2 / density)
    if (!isSpecialState && cellPressure > 3) {
      // Build momentum proportional to pressure
      final targetMomentum = (cellPressure >> 1).clamp(0, 5);
      if (momentum[idx] < targetMomentum) {
        momentum[idx] = (momentum[idx] + 1).clamp(0, 255);
      }
      // Momentum enables multi-cell lateral flow (skip cells when moving)
      final flowDist = (momentum[idx] >> 1).clamp(1, 3);
      if (velX[idx] != 0 && flowDist > 1) {
        final flowDir = velX[idx] > 0 ? 1 : -1;
        for (int d = 1; d <= flowDist; d++) {
          final fx = wrapX(x + flowDir * d);
          final fi = y * gridW + fx;
          if (grid[fi] == El.empty) {
            swap(idx, fi);
            markProcessed(fi);
            break;
          } else if (grid[fi] != El.water) {
            break;
          }
        }
      }
    } else if (momentum[idx] > 0) {
      // Friction: momentum decays in shallow water
      momentum[idx] = (momentum[idx] - 1).clamp(0, 255);
    }

    // High pressure pushes sand/dirt sideways
    if (colAbove >= SimTuning.thresholdColumnHeavy && rng.nextInt(SimTuning.waterPressurePush) == 0) {
      for (int dirI = 0; dirI < 2; dirI++) { final dir = dirI == 0 ? 1 : -1;
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

    // Fall with momentum — Torricelli: v = sqrt(2*g*h)
    // Pressurized water gets an initial velocity boost proportional to sqrt(pressure)
    if (inBoundsY(by) && isEmptyOrGas(grid[by * gridW + x])) {
      final maxVel = elementMaxVelocity[El.water];
      int curVel = velY[idx];
      // Pressure-driven initial velocity (Torricelli's theorem)
      if (curVel == 0 && cellPressure > 2) {
        // sqrt approximation: pressure 4->2, 9->3, 16->4, 25->5
        int pVel = 1;
        int p2 = cellPressure;
        while (pVel * pVel < p2 && pVel < maxVel) { pVel++; }
        curVel = pVel;
      }
      final newVel = (curVel + 1).clamp(0, maxVel);
      velY[idx] = newVel;
      // Multi-cell fall when velocity > 1
      if (newVel > 1) {
        int finalY = by;
        for (int d = 2; d <= newVel; d++) {
          final testY = y + g * d;
          if (!inBoundsY(testY)) break;
          if (!isEmptyOrGas(grid[testY * gridW + x])) break;
          finalY = testY;
        }
        swap(idx, finalY * gridW + x);
      } else {
        swap(idx, by * gridW + x);
      }
      return;
    }

    // Splash — also seed wave ripples at impact point
    if (velY[idx] >= 3 && inBoundsY(by) && grid[by * gridW + x] != El.empty) {
      // Seed wave energy on the impacted cell and neighbors
      final impactVel = velY[idx];
      final waveEnergy = (impactVel ~/ 2).clamp(1, 8);
      velY[idx] = waveEnergy;
      for (final wd in const [-1, 1]) {
        final wx = wrapX(x + wd);
        final wi = y * gridW + wx;
        if (grid[wi] == El.water && velY[wi].abs() < waveEnergy) {
          velY[wi] = waveEnergy;
          markDirty(wx, y);
        }
      }
      queueReactionFlash(x, y, 100, 180, 255, (impactVel ~/ 2).clamp(2, 4));
      for (int i = 0; i < (velY[idx] ~/ 2).clamp(1, 3); i++) {
        final sx = wrapX(x + (rng.nextBool() ? 1 : -1) * (1 + rng.nextInt(2)));
        final sy = y - g * rng.nextInt(2);
        if (inBoundsY(sy) && grid[sy * gridW + sx] == El.empty) {
          final splashIdx = sy * gridW + sx;
          grid[splashIdx] = El.water;
          final splashMass = (mass ~/ 2).clamp(20, 139);
          life[splashIdx] = splashMass;
          // Seed wave ripple from splash impact
          velY[splashIdx] = (velY[idx] ~/ 2).clamp(1, 8);
          markProcessed(splashIdx);
          grid[idx] = El.empty;
          life[idx] = 0;
          velY[idx] = 0;
          return;
        }
      }
    }

    // Surface wave propagation: ripples spread laterally across water surface.
    // A water cell is "surface" if the cell above is empty or gas.
    // velY encodes wave displacement for surface cells.
    {
      final aboveY = y - g;
      final isSurface = !inBoundsY(aboveY) ||
          isEmptyOrGas(grid[aboveY * gridW + x]);
      if (isSurface) {
        final myVel = velY[idx];
        if (myVel != 0) {
          // Propagate wave energy to left and right surface water neighbors
          for (final dir in const [-1, 1]) {
            final nx = wrapX(x + dir);
            final ni = y * gridW + nx;
            if (grid[ni] == El.water) {
              // Neighbor must also be surface water
              final naboveY = y - g;
              if (!inBoundsY(naboveY) ||
                  isEmptyOrGas(grid[naboveY * gridW + nx])) {
                final nv = velY[ni];
                // Transfer: nv += (myVel - nv) * 0.3  (integer: * 77 >> 8)
                velY[ni] = nv + ((myVel - nv) * 77) ~/ 256;
                markDirty(nx, y);
              }
            }
          }
          // Dampen own wave: lose ~6% per frame (velY * 240 >> 8)
          velY[idx] = (myVel * 240) >> 8;
        }
      } else {
        velY[idx] = 0;
      }
    }

    // Puddle spreading: water with enough mass on a solid surface splits
    // laterally to fill depressions, simulating real fluid behavior.
    if (!isSpecialState && mass >= 60) {
      for (final dir in rng.nextBool() ? [1, -1] : [-1, 1]) {
        final nx = wrapX(x + dir);
        final ni = y * gridW + nx;
        if (isEmptyOrGas(grid[ni])) {
          // Check that the lateral cell has a solid floor below it
          final nby = y + g;
          if (inBoundsY(nby)) {
            final belowNeighbor = grid[nby * gridW + nx];
            if (!isEmptyOrGas(belowNeighbor) && belowNeighbor != El.water &&
                belowNeighbor != El.oil) {
              // Split: create new water cell with half the mass
              final halfMass = mass ~/ 2;
              life[idx] = halfMass.clamp(20, 139);
              grid[ni] = El.water;
              life[ni] = halfMass.clamp(20, 139);
              temperature[ni] = temperature[idx];
              markProcessed(ni);
              return;
            }
          }
        }
      }
    }

    // Momentum-based lateral flow (velX encodes flow direction)
    final flowMomentum = velX[idx];
    final frameBias = rng.nextBool();
    final dl = flowMomentum != 0 ? (flowMomentum > 0) : frameBias;
    final x1 = wrapX(dl ? x + 1 : x - 1);
    final x2 = wrapX(dl ? x - 1 : x + 1);

    if (inBoundsY(by) && isEmptyOrGas(grid[by * gridW + x1])) {
      velX[idx] = dl ? 1 : -1;
      swap(idx, by * gridW + x1);
      return;
    }
    if (inBoundsY(by) && isEmptyOrGas(grid[by * gridW + x2])) {
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

    // Scan preferred direction first, then opposite.
    // Stop scanning in a direction if we hit a solid/granular wall.
    for (int pass = 0; pass < 2; pass++) {
      final dir = pass == 0 ? (dl ? 1 : -1) : (dl ? -1 : 1);
      for (int d = 1; d <= flowDist; d++) {
        final sx = wrapX(x + dir * d);
        final cell = grid[y * gridW + sx];
        if (cell == El.empty) {
          velX[idx] = dir;
          swap(idx, y * gridW + sx);
          return;
        }
        // If we hit a non-liquid cell, the path is blocked — stop this direction
        final state = elementPhysicsState[cell];
        if (state != PhysicsState.liquid.index) break;
      }
    }

    // Hydraulic displacement: Pascal's principle — pressure applied to
    // confined fluid transmits equally. High-pressure water pushes water
    // through a filled channel to a lower-pressure column, pumping water
    // from the tall column's surface to the short column's surface.
    if (cellPressure > 8 && rng.nextInt(SimTuning.waterHydraulicRate) == 0) {
      for (final dir in dl ? [1, -1] : [-1, 1]) {
        for (int d = 1; d <= 20; d++) {
          final sx = wrapX(x + dir * d);
          final si = y * gridW + sx;
          final cell = grid[si];
          if (cell == El.water || cell == El.oil) {
            if (pressure[si] >= cellPressure - 2) continue;
            // Found lower-pressure water — scan upward to find its surface
            int surfTargetY = -1;
            for (int cy = y - g; inBoundsY(cy); cy -= g) {
              final ci = cy * gridW + sx;
              if (grid[ci] == El.water || grid[ci] == El.oil) continue;
              if (grid[ci] == El.empty) {
                surfTargetY = cy;
              }
              break;
            }
            if (surfTargetY >= 0) {
              // Find our column's surface
              int surfSrcY = y;
              for (int cy = y - g; inBoundsY(cy); cy -= g) {
                if (grid[cy * gridW + x] == El.water) {
                  surfSrcY = cy;
                } else {
                  break;
                }
              }
              // Only pump if our surface is higher (more water above)
              final srcDepth = (y - surfSrcY).abs();
              final tgtDepth = (y - surfTargetY).abs();
              if (srcDepth > tgtDepth + 1) {
                // Pump water to the target surface
                grid[surfTargetY * gridW + sx] = El.water;
                life[surfTargetY * gridW + sx] = 80;
                temperature[surfTargetY * gridW + sx] = temperature[idx];
                markProcessed(surfTargetY * gridW + sx);
                // Remove water from our surface
                grid[surfSrcY * gridW + x] = El.empty;
                life[surfSrcY * gridW + x] = 0;
                unsettleNeighbors(x, surfSrcY);
                return;
              }
            }
            continue;
          }
          break; // hit non-liquid (wall or empty)
        }
      }
    }

    // Fast surface leveling (Scan-line Leveling)
    // Enhanced: increased scan distance (12 cells) and multi-step flow
    final aboveEl = inBoundsY(uy) ? grid[uy * gridW + x] : -1;
    if (aboveEl == El.empty || aboveEl == -1) {
      for (int dirI = 0; dirI < 2; dirI++) { 
        final dir = dirI == 0 ? (dl ? 1 : -1) : (dl ? -1 : 1);
        // Deep scan for nearby "holes" or lower columns
        for (int d = 1; d <= 12; d++) {
          final nx = wrapX(x + dir * d);
          final ni = y * gridW + nx;
          if (grid[ni] != El.empty) {
            // Hit a wall or water body — if it's water, check its height
            if (grid[ni] == El.water) {
              // Surface height check: find distance to surface in neighbor column
              int neighborDepth = 0;
              for (int cy = y - g; inBoundsY(cy) && neighborDepth < 15; cy -= g) {
                if (grid[cy * gridW + nx] == El.water) neighborDepth++;
                else break;
              }
              // If neighbor column surface is lower, flow there rapidly
              if (neighborDepth < 0) { // relative height comparison
                 velX[idx] = dir;
                 swap(idx, y * gridW + wrapX(x + dir));
                 return;
              }
            }
            break; 
          }
          
          final belowNx = y + g;
          if (inBoundsY(belowNx) && grid[belowNx * gridW + nx] == El.empty) {
            // Found a step-down! Move towards it with high momentum
            velX[idx] = dir;
            swap(idx, y * gridW + wrapX(x + dir));
            return;
          }
        }
      }
    }

    if (rng.nextInt(SimTuning.waterMomentumReset) == 0) velX[idx] = 0;

    // Convection: hot water rises through cold water above (every frame).
    // Rayleigh-Bénard convection: hot fluid expands, becomes less dense,
    // and rises through cooler fluid above. This is fundamental to
    // thermal stratification in liquids.
    if (!isSpecialState) {
      if (tryConvection(x, y, idx, El.water)) return;
    }

    // Erosion: flowing water with momentum picks up dirt/sand particles
    // Sediment is encoded in life >= 140 (special state: 140-199 = carrying sediment)
    // 140-159 = carrying dirt, 160-179 = carrying sand
    if (!isSpecialState && velX[idx] != 0 && frameCount % 6 == 0) {
      // Check below for erodible material
      final erosionDir = velX[idx] > 0 ? 1 : -1;
      final downY = y + gravityDir;
      if (inBoundsY(downY)) {
        // Erode material in the direction of flow, below the water
        for (int edyI = 0; edyI < 2; edyI++) { final edy = edyI == 0 ? 0 : 1;
          final ey = downY + edy * gravityDir;
          if (!inBoundsY(ey)) continue;
          final ex = wrapX(x + erosionDir);
          final ei = ey * gridW + ex;
          final eEl = grid[ei];
          // Erosion scales with momentum: flowing water erodes faster
          final erosionBoost = (momentum[idx] >> 2) + 1; // 1-4x
          if (eEl == El.dirt && rng.nextInt(SimTuning.waterDirtErosion ~/ erosionBoost) == 0) {
            grid[ei] = El.empty;
            life[ei] = 0;
            markProcessed(ei);
            // Become sediment-carrying water
            life[idx] = 145; // carrying dirt
            markDirty(x, y);
            break;
          } else if (eEl == El.sand && rng.nextInt(SimTuning.waterSandErosion ~/ erosionBoost) == 0) {
            grid[ei] = El.empty;
            life[ei] = 0;
            markProcessed(ei);
            life[idx] = 165; // carrying sand
            markDirty(x, y);
            break;
          }
        }
      }
    }

    // Sediment deposition: carrying water drops sediment when it slows down
    if (isSpecialState && lifeVal >= 140 && lifeVal < 200) {
      final carryingDirt = lifeVal < 160;
      // Deposit when velocity is zero (water stopped flowing) or randomly
      if (velX[idx] == 0 || rng.nextInt(SimTuning.waterSedimentDeposit) == 0) {
        final depY = y + gravityDir;
        if (inBoundsY(depY)) {
          final depI = depY * gridW + x;
          if (grid[depI] == El.empty) {
            grid[depI] = carryingDirt ? El.dirt : El.sand;
            life[depI] = 0;
            markProcessed(depI);
            life[idx] = 100; // back to normal water
            markDirty(x, y);
          } else if (grid[depI] != El.water) {
            // Can't deposit below — try sides
            for (int sideDirI = 0; sideDirI < 2; sideDirI++) { final sideDir = sideDirI == 0 ? 1 : -1;
              final sx = wrapX(x + sideDir);
              final si = depY * gridW + sx;
              if (grid[si] == El.empty) {
                grid[si] = carryingDirt ? El.dirt : El.sand;
                life[si] = 0;
                markProcessed(si);
                life[idx] = 100;
                markDirty(x, y);
                break;
              }
            }
          }
        }
      }
    }

    // Underground water seepage: water slowly percolates through dirt
    if (!isSpecialState && frameCount % 8 == 0 && rng.nextInt(SimTuning.waterSeepageRate) == 0) {
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

    // Fountain effect: highly pressurized water erupts upward.
    // If pressure > 16, it has a significant chance to swap with empty above.
    if (!isSpecialState && cellPressure >= SimTuning.thresholdPressureErupt && 
        frameCount % SimTuning.throttleWaterFountain == 0) {
      if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
        swap(idx, uy * gridW + x);
        velY[uy * gridW + x] = -1; // give it slight upward momentum
        return;
      }
    }

    // Pressure equalization: highly pressurized water pushes upward against gravity
    if (!isSpecialState && cellPressure >= SimTuning.thresholdPressureHigh && frameCount % SimTuning.throttleWaterPressure == 0) {
      for (int dirI = 0; dirI < 2; dirI++) { final dir = dirI == 0 ? 1 : -1;
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
    if (!isSpecialState && colAbove >= SimTuning.thresholdColumnHeavy && frameCount % SimTuning.throttleWaterFountain == 0) {
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
      if (stoneCount >= 4 && rng.nextInt(SimTuning.waterStoneExit) == 0) {
        for (int r = 2; r <= 8; r++) {
          for (int dirI = 0; dirI < 2; dirI++) { final dir = dirI == 0 ? 1 : -1;
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
    // Fire triangle: oxygen deprivation — count air (empty) neighbors.
    // Fire enclosed by solids/liquids with no empty cells lacks oxygen
    // and suffocates rapidly. Real fires need O₂ concentration > ~16%.
    int airNeighbors = 0;
    bool hasOxygen = false;
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final ax = wrapX(x + dx);
        final ay = y + dy;
        if (!inBoundsY(ay)) continue;
        final ne = grid[ay * gridW + ax];
        if (ne == El.empty) airNeighbors++;
        if (ne == El.oxygen) { airNeighbors += 2; hasOxygen = true; }
      }
    }
    // Consume oxygen and produce CO2
    if (hasOxygen && rng.nextInt(SimTuning.fireOxygenConsume) == 0) {
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          final ax = wrapX(x + dx); final ay = y + dy;
          if (!inBoundsY(ay)) continue;
          final ni = ay * gridW + ax;
          if (grid[ni] == El.oxygen) {
            grid[ni] = El.co2; markDirty(ax, ay); break;
          }
        }
      }
    }

    // Oxygen-modulated burnout: 0 air = instant death (suffocation),
    // 1 air = rapid burnout, 2+ air = normal combustion
    life[idx]++;
    if (airNeighbors == 0) {
      // No oxygen: fire suffocates immediately → smoke
      grid[idx] = El.smoke;
      life[idx] = 0;
      markProcessed(idx);
      return;
    }

    final nearOil = checkAdjacent(x, y, El.oil);
    int burnoutLife = nearOil ? SimTuning.fireOilLifetimeBase + rng.nextInt(SimTuning.fireOilLifetimeVar) : SimTuning.fireLifetimeBase + rng.nextInt(SimTuning.fireLifetimeVar);
    // Reduced air accelerates burnout (oxygen-limited combustion)
    if (airNeighbors == 1) burnoutLife = burnoutLife ~/ 2;

    if (life[idx] > burnoutLife) {
      // Fire burns out — always produce smoke, sometimes ash
      final uy = y - gravityDir;
      if (rng.nextInt(SimTuning.fireBurnoutSmoke) > 0) {
        // 2/3 chance: become smoke directly (fire rises into smoke naturally)
        grid[idx] = El.smoke;
        life[idx] = 0;
        markProcessed(idx);
      } else {
        // 1/3 chance: leave ash behind
        grid[idx] = El.ash;
        life[idx] = 0;
        markProcessed(idx);
      }
      // Spawn extra smoke above
      if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
        grid[uy * gridW + x] = El.smoke;
        life[uy * gridW + x] = 0;
        markProcessed(uy * gridW + x);
      }
      return;
    }

    // Intermittent smoke while burning (visible plume)
    // High frequency for dense, realistic smoke column
    final smokeChance = life[idx] < 10 ? 2 : 3;
    if (rng.nextInt(smokeChance) == 0) {
      final uy = y - gravityDir;
      if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
        grid[uy * gridW + x] = El.smoke;
        life[uy * gridW + x] = 0;
        markProcessed(uy * gridW + x);
      }
    }

    // Anisotropic heat transfer: fire heats via both radiation (isotropic)
    // and convection (anisotropic — hot gases rise). The Grashof number
    // Gr = gβΔTL³/ν² >> 1 for fire, meaning convection dominates above
    // the flame. Cells above fire receive convective + radiative heating
    // (~12 units), while lateral and below cells get radiation only (~6).
    // This creates the characteristic thermal plume shape above fires.
    {
      final g = gravityDir;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final hx = wrapX(x + dx);
          final hy = y + dy;
          if (!inBoundsY(hy)) continue;
          final hi = hy * gridW + hx;
          final nt = temperature[hi];
          if (nt < 220) {
            // Convective bonus for cells above the fire (against gravity)
            final isAbove = (g == 1 && dy == -1) || (g == -1 && dy == 1);
            final heatAmount = isAbove ? 12 : 6;
            temperature[hi] = nt + heatAmount;
          }
        }
      }
    }

    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = wrapX(x + dx);
        final ny = y + dy;
        if (!inBoundsY(ny)) continue;
        final ni = ny * gridW + nx;
        final neighbor = grid[ni];
        
        // Moisture interaction: fire expends energy evaporating moisture
        final neighborMoist = moisture[ni];
        if (neighborMoist > 50) {
           moisture[ni] = (neighborMoist - 10).clamp(0, 255);
           // Generate steam occasionally from evaporating moisture
           if (rng.nextInt(10) == 0 && inBoundsY(ny - gravityDir) && grid[(ny - gravityDir) * gridW + nx] == El.empty) {
               grid[(ny - gravityDir) * gridW + nx] = El.steam;
               life[(ny - gravityDir) * gridW + nx] = 0;
           }
           // Fire gets weak when fighting moisture
           if (rng.nextInt(3) == 0) {
              grid[idx] = El.smoke;
              life[idx] = 0;
              markProcessed(idx);
              return;
           }
        }

        if (neighbor == El.water) {
          grid[ni] = El.steam;
          life[ni] = 0;
          grid[idx] = El.empty;
          life[idx] = 0;
          markProcessed(ni);
          queueReactionFlash(nx, ny, 200, 200, 240, 3);
          return;
        }
        if ((neighbor == El.plant || neighbor == El.seed) && rng.nextInt(SimTuning.firePlantIgnite) == 0) {
          grid[ni] = El.fire;
          life[ni] = 0;
          markProcessed(ni);
        }
        if (neighbor == El.wood) {
          // Temperature-based ignition: wood at flash point auto-ignites
          // from radiated heat. This produces consistent Fisher-KPP
          // propagation velocity v = 2*sqrt(k*α).
          if (temperature[ni] >= 190) {
            grid[ni] = El.fire;
            life[ni] = 0;
            markProcessed(ni);
          } else if (life[ni] == 0 && rng.nextInt(SimTuning.fireWoodPyrolysis) == 0) {
            // Contact pyrolysis: flame touching wood surface starts
            // internal charring, igniting the wood from within
            life[ni] = 1;
          }
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
              if (grid[oi] == El.oil && rng.nextInt(SimTuning.fireOilChainIgnite) == 0) {
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

    // Radiant heat: fire warms nearby air cells (smaller radius than lava)
    if (frameCount % 10 == 0) {
      emitRadiantHeat(x, y, idx, 2, 25);
    }

    // Movement: fire rises with horizontal flickering for a dancing flame effect
    // Wind biases fire drift direction
    final localWind = windX2[idx];
    final uy = y - gravityDir;
    // Flicker: mostly rise straight, occasionally drift for flame dance
    final flicker = rng.nextInt(SimTuning.fireFlicker); // 0-3 = straight up, 4 = drift left, 5 = drift right
    if (flicker <= 3 && localWind == 0) {
      // Rise straight up (only when no wind)
      if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
        swap(idx, uy * gridW + x);
        return;
      }
    }
    // Drift diagonally upward — wind biases direction
    final windBias = localWind != 0 ? (localWind > 0 ? 1 : -1) : 0;
    final drift = windBias != 0 ? windBias
        : (flicker == 4 ? -1 : (flicker == 5 ? 1 : (rng.nextBool() ? -1 : 1)));
    final driftX = wrapX(x + drift);
    if (inBoundsY(uy) && grid[uy * gridW + driftX] == El.empty) {
      swap(idx, uy * gridW + driftX);
      return;
    }
    // Fallback: try straight up if diagonal failed
    if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
      swap(idx, uy * gridW + x);
      return;
    }
    // Occasional lateral shimmy when trapped (fire dances sideways)
    if (rng.nextInt(SimTuning.fireLateralShimmy) == 0) {
      final sideX = wrapX(x + (windBias != 0 ? windBias : (rng.nextBool() ? 1 : -1)));
      if (grid[y * gridW + sideX] == El.empty) {
        swap(idx, y * gridW + sideX);
      }
    }
  }

  // =========================================================================
  // Ice
  // =========================================================================

  void simIce(int x, int y, int idx) {
    // Temperature-driven melting (ice -> water)
    if (checkTemperatureReaction(x, y, idx, El.ice)) return;

    // Regelation: ice under high pressure melts at lower temperature.
    // Real ice melting point decreases ~0.0075°C/atm (Clausius-Clapeyron
    // with negative slope due to water's anomalous density).
    // In our engine: if pressure > 8, ice can melt even at slightly
    // below-freezing temperatures (enables glacial flow).
    if (frameCount % 8 == 0) {
      final p = pressure[idx];
      if (p > 8) {
        final t = temperature[idx];
        // Normal freeze point is ~128 - 30/2 = 113. Regelation lowers it.
        // At pressure 8: melt at 120, pressure 16: melt at 115
        final regelationThreshold = 120 - (p >> 2);
        if (t > regelationThreshold && rng.nextInt(SimTuning.iceRegelation) == 0) {
          grid[idx] = El.water;
          life[idx] = 100;
          markProcessed(idx);
          return;
        }
      }
    }

    // Gravity: ice falls when unsupported but floats on water
    // (ice density 90 < water density 100, so sinkThroughLiquids still
    // won't sink through water due to density check in fallSolid)
    if (fallSolid(x, y, idx, El.ice)) return;

    if (checkAdjacentAny2(x, y, El.fire, El.lava)) {
      grid[idx] = El.water;
      life[idx] = 150;
      markProcessed(idx);
      return;
    }
    final ambientMeltChance = isNight ? SimTuning.iceAmbientMeltNight : SimTuning.iceAmbientMeltDay;
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

    // Lightning sets charge to max on this cell and neighbors
    charge[idx] = 127;

    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = wrapX(x + dx);
        final ny = y + dy;
        if (!inBoundsY(ny)) continue;
        final ni = ny * gridW + nx;
        // Lightning sets neighbor charge to max
        charge[ni] = 127;
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
        // Electrolysis: lightning through water produces gas bubbles
        // (H₂O → H₂ + O₂). Real electrolysis requires 1.23V minimum.
        if (neighbor == El.water && rng.nextInt(SimTuning.lightningElectrolysis) == 0) {
          grid[ni] = El.bubble;
          life[ni] = 0;
          markProcessed(ni);
          queueReactionFlash(nx, ny, 180, 200, 255, 3);
        }
        // Arc ignition: lightning's plasma (~30,000 K) instantly ignites
        // oil vapor. Real oil flash points (200-300°C) are far below
        // lightning channel temperature. The arc also ignites nearby oil
        // via radiative heating within a 2-cell radius.
        if (neighbor == El.oil) {
          grid[ni] = El.fire; life[ni] = 0; markProcessed(ni);
          queueReactionFlash(nx, ny, 255, 200, 50, 5);
          // Chain ignition: lightning's heat radiates to nearby oil
          for (int ody = -2; ody <= 2; ody++) {
            for (int odx = -2; odx <= 2; odx++) {
              if (odx == 0 && ody == 0) continue;
              final ox = wrapX(nx + odx);
              final oy = ny + ody;
              if (!inBoundsY(oy)) continue;
              final oi = oy * gridW + ox;
              if (grid[oi] == El.oil && rng.nextInt(SimTuning.lightningOilChain) == 0) {
                grid[oi] = El.fire; life[oi] = 0; markProcessed(oi);
              }
            }
          }
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
    final sType = velX[idx].clamp(1, 11);
    life[idx]++;
    if (checkAdjacentAny2(x, y, El.fire, El.lava)) {
      grid[idx] = El.ash; life[idx] = 0; velX[idx] = 0; markProcessed(idx); return;
    }
    if (checkAdjacent(x, y, El.acid)) {
      grid[idx] = El.empty; life[idx] = 0; velX[idx] = 0; return;
    }

    // Seaweed seeds sprout in water, not on dirt
    if (sType == plantSeaweed) {
      if (checkAdjacent(x, y, El.water) && life[idx] > 20) {
        grid[idx] = El.seaweed; life[idx] = 50;
        velY[idx] = 1; markProcessed(idx);
        // Create or join a colony
        final registry = plantColonies;
        if (registry != null) {
          registry.spawn(idx, rng: rng);
        }
        return;
      }
      if (life[idx] > 80) {
        grid[idx] = El.empty; life[idx] = 0; velX[idx] = 0; return;
      }
      fallGranular(x, y, idx, El.seed);
      return;
    }

    final by = y + gravityDir;
    bool onDirt = inBoundsY(by) && grid[by * gridW + x] == El.dirt;
    if (onDirt) {
      final soilM = life[by * gridW + x];
      final clampedType = sType.clamp(1, plantMinMoist.length - 1);
      if (soilM >= plantMinMoist[clampedType]) {
        if (life[idx] > 30) {
          // Map seed type to element type for new plant variants
          final elType = _seedTypeToElement(sType);
          grid[idx] = elType; life[idx] = 50;
          if (elType == El.plant) {
            setPlantData(idx, sType, stSprout);
          }
          velY[idx] = 1; markProcessed(idx);
          // Register neural plant colony for new variant types
          if (sType >= plantSeaweed) {
            final registry = plantColonies;
            if (registry != null) {
              registry.spawn(idx, rng: rng);
            }
          }
          return;
        }
        return;
      } else if (life[idx] > 60) {
        grid[idx] = El.empty; life[idx] = 0; velX[idx] = 0; return;
      }
    } else {
      // Moss seeds can sprout on stone
      if (sType == plantMoss && inBoundsY(by)) {
        final belowEl = grid[by * gridW + x];
        if (belowEl == El.stone || belowEl == El.clay || belowEl == El.wood) {
          if (life[idx] > 25) {
            grid[idx] = El.moss; life[idx] = 50;
            velY[idx] = 1; markProcessed(idx);
            final registry = plantColonies;
            if (registry != null) registry.spawn(idx, rng: rng);
            return;
          }
          return;
        }
      }
      bool onSolid = inBoundsY(by) && grid[by * gridW + x] != El.empty;
      if (onSolid) {
        if (life[idx] > 60) { grid[idx] = El.empty; life[idx] = 0; velX[idx] = 0; return; }
        return;
      }
    }
    fallGranular(x, y, idx, El.seed);
  }

  /// Map plant seed type constant to the element type it sprouts into.
  @pragma('vm:prefer-inline')
  int _seedTypeToElement(int sType) {
    switch (sType) {
      case plantSeaweed: return El.seaweed;
      case plantMoss: return El.moss;
      case plantNeuralVine: return El.vine;
      case plantNeuralFlower: return El.flower;
      case plantRoot: return El.root;
      case plantThorn: return El.thorn;
      default: return El.plant; // original plant types 1-5
    }
  }

  // =========================================================================
  // Dirt
  // =========================================================================

  void simDirt(int x, int y, int idx) {
    // Saturated dirt + lots of water -> mud
    // The higher the moisture, the fewer water neighbors needed to turn to mud
    if (moisture[idx] > 150) {
      int wc = 0;
      for (int dy2 = -1; dy2 <= 1; dy2++) {
        for (int dx2 = -1; dx2 <= 1; dx2++) {
          if (dx2 == 0 && dy2 == 0) continue;
          final wnx = wrapX(x + dx2);
          final wny = y + dy2;
          if (inBoundsY(wny) && grid[wny * gridW + wnx] == El.water) {
            wc++;
          }
        }
      }
      final neededWater = moisture[idx] > 220 ? 1 : 3;
      if (wc >= neededWater) {
        grid[idx] = El.mud;
        life[idx] = 0;
        markProcessed(idx);
        return;
      }
    }

    // Ash fertilizer: dirt absorbs adjacent ash, gaining +2 moisture.
    // This completes the cycle: plant dies → ash → dirt absorbs → moisture → new plant.
    if (rng.nextInt(SimTuning.dirtAshAbsorb) == 0) {
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

    // Capillary wicking: water below dirt gets pulled upward through pores.
    // Washburn equation: L² ∝ (γ·r·cos θ·t) / (2·η)
    // Higher porosity = faster wicking. Check below for water and above for empty.
    if (frameCount % 6 == 0 && life[idx] >= 2) {
      // Only wick upward if there's space above
      final uy = y - 1;
      if (uy >= 0) {
        final ui = uy * gridW + x;
        if (grid[ui] == El.dirt && life[ui] < life[idx] - 1) {
          // Transfer moisture upward (capillary action)
          life[ui]++;
          life[idx]--;
          markDirty(x, uy);
          markDirty(x, y);
        } else if (grid[ui] == El.empty) {
          // Saturated dirt with water below: pull water up through the column
          final dy2 = y + 1;
          if (dy2 < gridH) {
            final di = dy2 * gridW + x;
            if (grid[di] == El.water && life[idx] >= 4) {
              // Absorb water from below and push moisture up
              grid[di] = El.empty;
              life[di] = 0;
              markProcessed(di);
              life[idx] = 5; // re-saturate
              markDirty(x, y);
            }
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

    // Water erosion: dirt with water flowing over it erodes
    // Enhanced: checks for flowing water (with momentum) for stronger erosion
    if (frameCount % 12 == 0 && rng.nextInt(SimTuning.dirtWaterErosionBase) == 0) {
      int waterFlowCount = 0;
      bool hasFlowingWater = false;
      for (int dx2 = -1; dx2 <= 1; dx2++) {
        final nx = wrapX(x + dx2);
        final uy = y - gravityDir;
        if (inBoundsY(uy)) {
          final wi = uy * gridW + nx;
          if (grid[wi] == El.water) {
            waterFlowCount++;
            // Check if the water has lateral momentum (flowing)
            if (velX[wi] != 0) hasFlowingWater = true;
          }
        }
      }
      if (velY[idx] < 3) {
        if (hasFlowingWater && rng.nextInt(SimTuning.dirtFlowingErosion) == 0) {
          // Flowing water erodes more aggressively — dirt becomes empty
          // and the water picks it up as sediment
          grid[idx] = El.empty;
          life[idx] = 0;
          velY[idx] = 0;
          markProcessed(idx);
          // Try to make an adjacent water cell carry the sediment
          final uy = y - gravityDir;
          if (inBoundsY(uy)) {
            for (int dx2 = -1; dx2 <= 1; dx2++) {
              final nx = wrapX(x + dx2);
              final wi = uy * gridW + nx;
              if (grid[wi] == El.water && life[wi] < 140) {
                life[wi] = 145; // carrying dirt
                markDirty(nx, uy);
                break;
              }
            }
          }
          return;
        } else if (waterFlowCount >= 2 && life[idx] >= 3) {
          // Static water still erodes saturated dirt into mud
          grid[idx] = El.mud;
          life[idx] = 0;
          velY[idx] = 0;
          markProcessed(idx);
          return;
        }
      }
    }

    // Darcy seepage: pressure-driven water percolation through porous
    // soil. Darcy's law: Q = -kA(ΔP/ΔL)/μ. When a water column above
    // creates hydrostatic pressure, water seeps through saturated dirt
    // to emerge below. The seepage rate is proportional to the pressure
    // head and inversely proportional to soil compaction (permeability).
    // This models groundwater flow, spring emergence, and levee seepage.
    if (frameCount % 8 == 0 && life[idx] >= 4) {
      final g = gravityDir;
      final belowY = y + g;
      if (inBoundsY(belowY)) {
        final belowIdx = belowY * gridW + x;
        final belowEl = grid[belowIdx];
        if (belowEl == El.empty) {
          // Check for water pressure above
          int waterHead = 0;
          for (int sy = y - g; inBoundsY(sy) && waterHead < 8; sy -= g) {
            final se = grid[sy * gridW + x];
            if (se == El.water) {
              waterHead++;
            } else if (se != El.dirt) {
              break;
            }
          }
          // Compacted dirt (velY >= 3) is less permeable
          final compaction = velY[idx].clamp(0, 5);
          final permeability = 5 - compaction; // 5=loose, 0=packed
          if (waterHead >= 2 && permeability > 0 &&
              rng.nextInt(20 ~/ permeability) == 0) {
            // Seep water through: spawn water below, consume from above
            grid[belowIdx] = El.water;
            life[belowIdx] = 100;
            markProcessed(belowIdx);
            // Remove one water cell from the column above
            for (int sy = y - g; inBoundsY(sy); sy -= g) {
              final si = sy * gridW + x;
              if (grid[si] == El.water) {
                grid[si] = El.empty;
                life[si] = 0;
                markProcessed(si);
                break;
              }
              if (grid[si] != El.dirt) break;
            }
            life[idx] = (life[idx] - 1).clamp(0, 5); // partial desaturation
            markDirty(x, y);
          }
        }
      }
    }

    // Galilean freefall: dirt falls at the same rate as sand in vacuum
    // (gravity is mass-independent). Use velocity-based fallGranular
    // for proper acceleration. In water, use displacement-based fall
    // to preserve water containment and avoid excessive moisture exposure.
    final by = y + gravityDir;
    final inWater = inBoundsY(by) && grid[by * gridW + x] == El.water;
    if (inWater) {
      fallGranularDisplace(x, y, idx, El.dirt);
    } else {
      fallGranular(x, y, idx, El.dirt);
    }
  }

  // =========================================================================
  // Plant
  // =========================================================================

  void simPlant(int x, int y, int idx) {
    final pType = plantType(idx);
    final pStage = plantStage(idx);
    final hydration = life[idx];

    if (checkAdjacentAny2(x, y, El.fire, El.lava)) {
      grid[idx] = El.fire; life[idx] = 0; velX[idx] = 0; velY[idx] = 0;
      markProcessed(idx); return;
    }
    if (checkAdjacent(x, y, El.acid) && rng.nextInt(SimTuning.plantAcidDamage) == 0) {
      grid[idx] = El.empty; life[idx] = 0; velX[idx] = 0; velY[idx] = 0;
      markProcessed(idx); return;
    }

    if (pStage == stDead) {
      // Fungus decomposes dead plants into compost
      if (checkAdjacent(x, y, El.fungus) && rng.nextInt(SimTuning.plantDecomposeRate) == 0) {
        grid[idx] = El.compost; life[idx] = 50; velX[idx] = 0; velY[idx] = 0;
        markProcessed(idx); return;
      }
      velY[idx] = (velY[idx] + 1).clamp(0, 127).toInt();
      if (velY[idx] > 120) {
        grid[idx] = El.ash; life[idx] = 0; velX[idx] = 0; velY[idx] = 0;
        markProcessed(idx);
      }
      return;
    }

    // Hydration: plants consume moisture from their local environment.
    // The moisture system (SimulationEngine.updateMoisture) handles 
    // capillary wicking through dirt/compost.
    if (frameCount % SimTuning.throttlePlantHydration == 0) {
      final localMoisture = moisture[idx];
      // Sample neighbors for root-like absorption
      int ambientMoist = localMoisture;
      for (int dy2 = -1; dy2 <= 1; dy2++) {
        for (int dx2 = -1; dx2 <= 1; dx2++) {
          if (dx2 == 0 && dy2 == 0) continue;
          final nx = wrapX(x + dx2); final ny = y + dy2;
          if (inBoundsY(ny)) {
            final nm = moisture[ny * gridW + nx];
            if (nm > ambientMoist) ambientMoist = nm;
          }
        }
      }

      final minNeeded = plantMinMoist[pType.clamp(1, 5)];
      if (ambientMoist >= minNeeded) {
        // Hydrated: gain health
        life[idx] = (hydration + 2).clamp(0, 100);
        // Slowly consume the moisture we just absorbed
        if (localMoisture > 0) moisture[idx] = localMoisture - 1;
      } else {
        // Dehydrating: lose health
        life[idx] = (hydration - 1).clamp(0, 100);
      }
    }

    // pH effects on plant health
    {
      final cellPH = pH[idx];
      // Acid rain damage: pH < 80 damages plants (acid environment)
      if (cellPH < SimTuning.thresholdPHAcidDamage && frameCount % SimTuning.throttlePlantGrow == 0) {
        final damage = (80 - cellPH) >> 4; // pH 20 -> 3 damage, pH 60 -> 1
        life[idx] = (life[idx] - damage - 1).clamp(0, 100);
      }
      // Optimal pH range (100-140) boosts growth
      if (cellPH >= SimTuning.thresholdPHOptimalLo && cellPH <= SimTuning.thresholdPHOptimalHi && frameCount % 10 == 0) {
        life[idx] = (life[idx] + 1).clamp(0, 100);
      }
    }

    // Photosynthesis: absorb CO2, produce oxygen (living plants only)
    // Requires luminance > 50 for non-mushroom plants to photosynthesize
    final lum = luminance[idx];
    if (pStage >= stGrowing && pStage <= stMature && frameCount % 15 == 0) {
      final canPhotosynthesize = pType == plantMushroom || lum > 50;
      if (canPhotosynthesize) {
        // Absorb CO2 if nearby
        if (checkAdjacent(x, y, El.co2)) {
          removeOneAdjacent(x, y, El.co2);
        }
        // Produce oxygen into empty neighbor
        if (rng.nextInt(SimTuning.plantO2Produce) == 0) {
          final uy = y - gravityDir;
          if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
            grid[uy * gridW + x] = El.oxygen; markDirty(x, uy);
          }
        }
      }
    }

    // Low light accelerates wilting for non-mushroom plants
    if (pType != plantMushroom && lum < SimTuning.thresholdLightPhotosynthesis && frameCount % SimTuning.throttlePlantGrow == 0) {
      life[idx] = (life[idx] - 1).clamp(0, 100);
    }

    // Wilting / recovery
    if (life[idx] < SimTuning.thresholdPlantWilt && pStage < stWilting) {
      setPlantData(idx, pType, stWilting);
    } else if (life[idx] >= 30 && pStage == stWilting) {
      setPlantData(idx, pType, velY[idx] >= plantMaxH[pType.clamp(1, 5)] ? stMature : stGrowing);
    }
    if (life[idx] <= 0 && pStage == stWilting) {
      setPlantData(idx, pType, stDead);
      velY[idx] = 0;
      return;
    }

    // Gravity: plants fall if unsupported by solid ground or other plants
    if (fallSolid(x, y, idx, El.plant)) {
      return; // Fell this frame, skip growing
    }

    if (pStage > stMature) return;

    final maxH = plantMaxH[pType.clamp(1, 5)];
    final curSize = velY[idx].clamp(0, 127).toInt();
    if (curSize >= maxH) {
      if (pStage != stMature) setPlantData(idx, pType, stMature);

      // Mature plants drop seeds — rate increases with age (maturity).
      // Young mature plants: 1/500, aged plants (cellAge>150): 1/200
      final plantAge = cellAge[idx];
      final seedRate = plantAge > SimTuning.thresholdPlantSeedAge ? SimTuning.plantSeedRateOld : SimTuning.plantSeedRateYoung;
      if (rng.nextInt(seedRate) == 0) {
        _plantDropSeed(x, y, idx);
      }

      return;
    }

    bool fertilized = checkAdjacent(x, y, El.ash);
    int growRate = plantGrowRate[pType.clamp(1, 5)];
    // Low luminance slows non-mushroom plants; mushrooms thrive in dark
    if (pType != plantMushroom) {
      if (lum < SimTuning.thresholdLightPhotosynthesis) {
        growRate = (growRate * 5); // near-dark: very slow
      } else if (lum < 100) {
        growRate = (growRate * 2); // dim: slower
      }
    } else {
      // Mushrooms grow faster in darkness, slower in bright light
      if (lum > 30) growRate = (growRate * 3);
    }
    if (fertilized) growRate = (growRate * 2) ~/ 3;

    if (frameCount % growRate != 0) return;

    if (pStage == stSprout) setPlantData(idx, pType, stGrowing);

    switch (pType) {
      case plantGrass: _growGrass(x, y, idx, curSize);
      case plantFlower: _growFlower(x, y, idx, curSize);
      case plantTree: _growTree(x, y, idx, curSize);
      case plantMushroom: _growMushroom(x, y, idx, curSize);
      case plantVine: _growVine(x, y, idx, curSize);
    }
  }

  void _growGrass(int x, int y, int idx, int curSize) {
    if (curSize < 3) {
      final uy = y - gravityDir;
      if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
        final ni = uy * gridW + x;
        grid[ni] = El.plant; life[ni] = life[idx];
        setPlantData(ni, plantGrass, stGrowing); velY[ni] = (curSize + 1);
        markProcessed(ni);
        velY[idx] = (curSize + 1);
      }
    }
    if (rng.nextInt(SimTuning.plantGrassSpread) == 0) {
      final side = wrapX(rng.nextBool() ? x - 1 : x + 1);
      final by = y + gravityDir;
      if (grid[y * gridW + side] == El.empty &&
          inBoundsY(by) && grid[by * gridW + side] == El.dirt) {
        final ni = y * gridW + side;
        grid[ni] = El.plant; life[ni] = life[idx];
        setPlantData(ni, plantGrass, stSprout); velY[ni] = 1;
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
        setPlantData(ni, plantFlower, newSize >= 4 ? stMature : stGrowing);
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
        setPlantData(ni, plantTree, isTrunk ? stGrowing : stMature);
        velY[ni] = newSize;
        markProcessed(ni);
        velY[idx] = newSize;
      }
      if (curSize >= 6) {
        for (int sideI = 0; sideI < 2; sideI++) { final side = sideI == 0 ? wrapX(x - 1) : wrapX(x + 1);
          if (rng.nextInt(SimTuning.plantTreeBranchSkip) == 0) continue;
          for (int syI = 0; syI < 2; syI++) { final sy = syI == 0 ? y : y - gravityDir;
            if (inBoundsY(sy) && grid[sy * gridW + side] == El.empty) {
              final ni = sy * gridW + side;
              grid[ni] = El.plant; life[ni] = life[idx];
              setPlantData(ni, plantTree, stMature); velY[ni] = curSize;
              markProcessed(ni);
              break;
            }
          }
        }
        if (curSize >= 10 && rng.nextInt(SimTuning.plantTreeBranch) == 0) {
          for (int sideI = 0; sideI < 2; sideI++) { final side = sideI == 0 ? wrapX(x - 2) : wrapX(x + 2);
            if (grid[y * gridW + side] == El.empty) {
              final ni = y * gridW + side;
              grid[ni] = El.plant; life[ni] = life[idx];
              setPlantData(ni, plantTree, stMature); velY[ni] = curSize;
              markProcessed(ni);
            }
          }
        }
      }
    }

    // Root system: mature trees grow roots downward through dirt
    if (curSize >= 8 && rng.nextInt(SimTuning.plantTreeRootGrow) == 0) {
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
        setPlantData(ri, plantTree, stGrowing);
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
        setPlantData(ni, plantMushroom, newSize >= 2 ? stMature : stGrowing);
        velY[ni] = newSize;
        markProcessed(ni);
        velY[idx] = newSize;
      }
    }
    if (rng.nextInt(SimTuning.plantMushroomSpread) == 0) {
      for (int r = 1; r <= 3; r++) {
        final sx = wrapX(x + (rng.nextBool() ? r : -r));
        final by = y + gravityDir;
        if (grid[y * gridW + sx] == El.empty &&
            inBoundsY(by) && grid[by * gridW + sx] == El.dirt &&
            life[by * gridW + sx] >= 4) {
          final ni = y * gridW + sx;
          grid[ni] = El.plant; life[ni] = life[idx];
          setPlantData(ni, plantMushroom, stSprout); velY[ni] = 1;
          markProcessed(ni);
          break;
        }
      }
    }
  }

  void _growVine(int x, int y, int idx, int curSize) {
    if (curSize < 12) {
      final directions = <List<int>>[];
      for (int i = 0; i < 5; i++) {
        final d0 = i == 0 ? -1 : i == 1 ? 1 : i == 2 ? -1 : i == 3 ? 1 : 0;
        final d1 = (i == 0 || i == 1 || i == 4) ? -gravityDir : 0;
        final nx = wrapX(x + d0); final ny = y + d1;
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
        if (nearSolid) directions.add([d0, d1]);
      }
      if (directions.isNotEmpty) {
        final d = directions[rng.nextInt(directions.length)];
        final nx = x + d[0]; final ny = y + d[1];
        final ni = ny * gridW + nx;
        grid[ni] = El.plant; life[ni] = life[idx];
        setPlantData(ni, plantVine, stGrowing);
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

    // Convection: hot lava rises through cooler lava
    if (tryConvection(x, y, idx, El.lava)) return;

    life[idx]++;
    final g = gravityDir;

    // Base cooling timeout
    int coolingThreshold = SimTuning.lavaCoolingBase + rng.nextInt(SimTuning.lavaCoolingVar);

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
        coolingThreshold = SimTuning.lavaCoolIsolated + rng.nextInt(SimTuning.lavaCoolIsolatedVar);
      } else if (lavaNeighborCount <= 3) {
        // Partially isolated
        coolingThreshold = SimTuning.lavaCoolPartial + rng.nextInt(SimTuning.lavaCoolPartialVar);
      }
    }

    if (life[idx] > coolingThreshold) {
      grid[idx] = El.stone;
      life[idx] = 0;
      // Newly cooled stone retains heat (glowing stone visual)
      velX[idx] = 4;
      // Latent heat of fusion: solidification releases stored energy.
      // Real magma releases ~4×10⁵ J/kg on crystallization, warming
      // adjacent material and slowing the cooling front (Stefan problem).
      temperature[idx] = 200; // stone starts hot
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final ni = ny * gridW + nx;
          final nt = temperature[ni];
          if (nt < 200) {
            temperature[ni] = (nt + 15).clamp(0, 255);
          }
        }
      }
      markProcessed(idx);
      return;
    }

    // Convection: hot lava rises through cooler lava above
    if (frameCount % 3 == 0) {
      if (tryConvection(x, y, idx, El.lava)) return;
    }

    // Radiant heat: lava warms nearby air cells in a radius
    // Creates visible heat zones and drives convection in adjacent liquids
    if (frameCount % 8 == 0) {
      emitRadiantHeat(x, y, idx, 3, 40);
    }

    // Volcanic gas emission
    final uy = y - g;
    if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
      if (rng.nextInt(SimTuning.lavaSmokeEmit) == 0) {
        grid[uy * gridW + x] = El.smoke;
        life[uy * gridW + x] = 0;
        markProcessed(uy * gridW + x);
      } else if (rng.nextInt(SimTuning.lavaSteamEmit) == 0) {
        grid[uy * gridW + x] = El.steam;
        life[uy * gridW + x] = 0;
        markProcessed(uy * gridW + x);
      }
    }

    // Eruption pressure (enhanced by pressure grid)
    final lavaPressure = pressure[idx];
    final eruptionChance = lavaPressure > 20 ? SimTuning.lavaEruptionPressured : SimTuning.lavaEruptionOpen;
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
      final eruptThresh = lavaPressure > 20 ? SimTuning.lavaEruptThreshHigh : SimTuning.lavaEruptThreshLow;
      if (capDepth >= 2 && lavaBelow >= 3 && rng.nextInt(eruptThresh) == 0) {
        final blastY = y - g * capDepth;
        if (inBoundsY(blastY)) {
          final blastIdx = blastY * gridW + x;
          grid[blastIdx] = El.lava;
          life[blastIdx] = 0;
          markProcessed(blastIdx);
          queueReactionFlash(x, blastY, 255, 200, 50, 8);
        }
        for (int dxI = 0; dxI < 2; dxI++) { final dx = dxI == 0 ? -1 : 1;
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
    if (rng.nextInt(SimTuning.lavaSpatter) == 0 && inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
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
          // Rapid quenching: lava submerged in water (3+ water neighbors)
          // cools too fast for crystals to form, producing volcanic glass
          // (obsidian). This is the real mechanism behind pillow lava at
          // mid-ocean ridges. Surface lava with less water contact cools
          // slowly enough to crystallize into stone.
          int waterNeighborCount = 0;
          for (int wdy = -1; wdy <= 1; wdy++) {
            for (int wdx = -1; wdx <= 1; wdx++) {
              if (wdx == 0 && wdy == 0) continue;
              final wnx = wrapX(x + wdx);
              final wny = y + wdy;
              if (inBoundsY(wny) && grid[wny * gridW + wnx] == El.water) {
                waterNeighborCount++;
              }
            }
          }
          grid[idx] = waterNeighborCount >= 3 ? El.glass : El.stone;
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
            neighbor == El.oil || neighbor == El.wood) && rng.nextInt(SimTuning.lavaIgniteFlammable) == 0) {
          grid[ni] = El.fire; life[ni] = 0; markProcessed(ni);
        }
        if (neighbor == El.snow) {
          grid[ni] = El.water; life[ni] = 100; markProcessed(ni);
        }
        if (neighbor == El.sand && rng.nextInt(SimTuning.lavaSandToGlass) == 0) {
          grid[ni] = El.glass; life[ni] = 0; markProcessed(ni);
          queueReactionFlash(nx, ny, 255, 200, 100, 3);
        }
        // Lava melts metal over time (metal meltPoint=240, lava baseTemp=250)
        if (neighbor == El.metal && rng.nextInt(SimTuning.lavaMeltMetal) == 0) {
          grid[ni] = El.lava; life[ni] = 0; markProcessed(ni);
          queueReactionFlash(nx, ny, 255, 120, 30, 5);
        }
        // Lava dries mud into dirt
        if (neighbor == El.mud && rng.nextInt(SimTuning.lavaDryMud) == 0) {
          grid[ni] = El.dirt; life[ni] = 0; markProcessed(ni);
          queueReactionFlash(nx, ny, 180, 140, 80, 2);
        }
      }
    }

    // Gravity — lava always falls if there's space below.
    final by = y + g;
    if (inBoundsY(by) && isEmptyOrGas(grid[by * gridW + x])) {
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
    // Diagonal fall always allowed (not gated by viscosity)
    final lx1 = wrapX(dl ? x - 1 : x + 1);
    final lx2 = wrapX(dl ? x + 1 : x - 1);
    if (inBoundsY(by) && isEmptyOrGas(grid[by * gridW + lx1])) { swap(idx, by * gridW + lx1); return; }
    if (inBoundsY(by) && isEmptyOrGas(grid[by * gridW + lx2])) { swap(idx, by * gridW + lx2); return; }

    // Temperature-dependent viscosity: real lava viscosity follows
    // η = A·exp(B/T) — exponentially increasing as temperature drops.
    // Basaltic lava at 1200°C: ~100 Pa·s; at 1100°C: ~1000 Pa·s.
    // Hot lava (temp>200) flows at base viscosity; cooling lava (100-200)
    // flows 2x slower; near-solid lava (<100) flows 4x slower.
    final lavaTemp = temperature[idx];
    final baseVisc = elementViscosity[El.lava]; // 4
    final visc = lavaTemp > 200 ? baseVisc
        : (lavaTemp > 100 ? baseVisc * 2 : baseVisc * 4);
    if (frameCount % visc != 0) return;

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

    // Lateral flow: spread 1-2 cells when on solid ground
    if (isEmptyOrGas(grid[y * gridW + lx1])) { swap(idx, y * gridW + lx1); return; }
    if (isEmptyOrGas(grid[y * gridW + lx2])) { swap(idx, y * gridW + lx2); return; }
    // Extended lateral flow for pooling lava
    final lx3 = wrapX(dl ? x - 2 : x + 2);
    final lx4 = wrapX(dl ? x + 2 : x - 2);
    if (grid[y * gridW + lx1] == El.lava && grid[y * gridW + lx3] == El.empty) {
      swap(idx, y * gridW + lx3);
      return;
    }
    if (grid[y * gridW + lx2] == El.lava && grid[y * gridW + lx4] == El.empty) {
      swap(idx, y * gridW + lx4);
    }
  }

  // =========================================================================
  // Snow
  // =========================================================================

  void simSnow(int x, int y, int idx) {
    // Temperature-driven melting (snow -> water)
    if (checkTemperatureReaction(x, y, idx, El.snow)) return;

    // Sublimation: at very high temperatures, snow converts directly to
    // steam (skipping the liquid phase). Real sublimation occurs when
    // vapor pressure exceeds atmospheric at the triple point (~0.01°C,
    // 611 Pa). In our engine, rapid heating past both melt and boil
    // points causes direct solid→gas transition.
    {
      final t = temperature[idx];
      if (t > 200) {
        grid[idx] = El.steam;
        life[idx] = 0;
        markProcessed(idx);
        queueReactionFlash(x, y, 200, 220, 255, 4);
        return;
      }
    }

    // Contact melting: snow adjacent to fire/lava melts. The latent heat
    // of fusion (334 kJ/kg) absorbs the fire's energy, extinguishing it.
    // This prevents the fire from immediately re-vaporizing the meltwater.
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = wrapX(x + dx);
        final ny = y + dy;
        if (!inBoundsY(ny)) continue;
        final ni = ny * gridW + nx;
        final neighbor = grid[ni];
        if (neighbor == El.fire || neighbor == El.lava) {
          if (!isNight || rng.nextBool()) {
            grid[idx] = El.water; life[idx] = 100; markProcessed(idx);
            queueReactionFlash(x, y, 150, 200, 255, 2);
            // Fire consumed by latent heat — extinguish it
            if (neighbor == El.fire) {
              grid[ni] = El.smoke; life[ni] = 0; markProcessed(ni);
            }
            return;
          }
        }
      }
    }

    // Proximity melting: snow within 5 cells of fire/lava melts from
    // radiant heat. Real physics: IR radiation from flames at ~1000°C
    // delivers ~10 kW/m² at 1m distance (Stefan-Boltzmann law), enough
    // to melt snow within seconds. Rate scales with proximity and temp.
    {
      final meltRate = isNight ? 40 : 20;
      if (rng.nextInt(meltRate) == 0) {
        for (int dy = -5; dy <= 5; dy++) {
          for (int dx = -5; dx <= 5; dx++) {
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
    }

    if (rng.nextInt(SimTuning.snowFreezeWater) == 0) {
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

    // Snow compression into ice — needs significant weight (5+ snow above)
    int snowAbove = 0;
    for (int d = 1; d <= 6; d++) {
      final cy = y - gravityDir * d;
      if (!inBoundsY(cy)) break;
      if (grid[cy * gridW + x] == El.snow) { snowAbove++; } else { break; }
    }
    if (snowAbove >= 5) {
      grid[idx] = El.ice; life[idx] = 0; markProcessed(idx); return;
    }

    // Snow falls with velocity accumulation (granular mechanics).
    // Reaches terminal velocity (maxVelocity=2) via drag.
    fallGranular(x, y, idx, El.snow);
    if (grid[idx] != El.snow) return; // fell or displaced

    // Wind-driven horizontal drift while falling
    final by = y + gravityDir;
    if (windForce != 0 && rng.nextInt(SimTuning.snowWindDrift) == 0) {
      final windX = wrapX(x + windForce.sign);
      if (inBoundsY(by) && grid[by * gridW + windX] == El.empty) {
        swap(idx, by * gridW + windX);
        return;
      }
      if (grid[y * gridW + windX] == El.empty) {
        swap(idx, y * gridW + windX);
        return;
      }
    }

    if (grid[idx] == El.snow && rng.nextInt(SimTuning.snowAvalanche) == 0) {
      _avalancheGranular(x, y, idx);
    }
  }

  // =========================================================================
  // Wood
  // =========================================================================

  void simWood(int x, int y, int idx) {
    // Burning wood logic (life > 0 = on fire)
    // Real physics: wood combustion involves surface pyrolysis, charring,
    // and flame spread. Once ignited, fire propagates along the surface
    // at a rate determined by heat flux from the flame to adjacent wood.
    // Flame spread velocity v ≈ 2√(αk/ρcΔT) is typically 0.5-2 mm/s
    // for wood, meaning adjacent cells ignite within seconds.
    // Moisture integration: wood absorbs moisture from the global buffer
    // Wet wood (moisture > 100) resists burning
    final currentMoisture = moisture[idx];
    if (currentMoisture > 50 && life[idx] > 0) {
      // Evaporate moisture when burning
      moisture[idx] = (currentMoisture - 2).clamp(0, 255);
      // Wet wood has a chance to extinguish itself or burn much slower
      if (rng.nextInt(4) == 0) {
        life[idx] = 0; // extinguish
        return;
      }
    }

    if (life[idx] > 0) {
      life[idx]++;

      // Fire spreads to adjacent wood via surface charring.
      // Dry wood ignites fast, wet wood ignites slowly
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final ni = ny * gridW + nx;
          if (grid[ni] == El.wood && life[ni] == 0) {
            final nMoist = moisture[ni];
            final spreadChance = nMoist > 100 ? SimTuning.woodFireSpread * 3 : SimTuning.woodFireSpread;
            if (rng.nextInt(spreadChance) == 0) {
              life[ni] = 1;
            }
          }
        }
      }
      if (life[idx] > SimTuning.woodBurnoutBase + rng.nextInt(SimTuning.woodBurnoutVar)) {
        // Pyrolysis: 40% chance wood becomes charcoal (incomplete combustion)
        grid[idx] = rng.nextInt(SimTuning.woodCharcoalChance) < 2 ? El.charcoal : El.ash;
        life[idx] = 0; velY[idx] = 0; markProcessed(idx);
        final uy = y - gravityDir;
        if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
          grid[uy * gridW + x] = El.smoke; life[uy * gridW + x] = 0;
          markProcessed(uy * gridW + x);
        }
        return;
      }
      // Burning wood still falls — gravity doesn't stop for fire
      final bby = y + gravityDir;
      if (inBoundsY(bby) && grid[bby * gridW + x] == El.empty) {
        swap(idx, bby * gridW + x);
      }
      return;
    }

    // Dry rot: aged wood becomes more flammable (lower ignition threshold)
    // cellAge > 200 = old, dried-out wood. Threshold drops from 190 to ~170.
    final age = cellAge[idx];
    final ignitionThreshold = age > SimTuning.thresholdAgingOld ? 190 - ((age - SimTuning.thresholdAgingOld) >> 2) : 190;

    // Temperature-based auto-ignition (flash point).
    // Real physics: wood has a flash point of ~300°C. Heat conducted from
    // adjacent fire raises the wood's temperature until it auto-ignites.
    // This creates a deterministic fire front driven by thermal diffusion
    // (Fisher-KPP reaction-diffusion), producing the constant propagation
    // velocity v = 2*sqrt(k*α) observed in real fire spread.
    // On our 0-255 scale, fire is 230 and wood base is 128.
    // Ignition threshold ~190 gives enough time for conduction to establish
    // a smooth temperature gradient ahead of the fire front.
    // Aged wood (dry rot) has a lower threshold.
    if (temperature[idx] >= ignitionThreshold) {
      // Auto-ignite: wood reaches flash point from heat conduction
      life[idx] = 1; // Start burning
      return;
    }

    // Anoxic pyrolysis (charcoal production): wood heated above 200
    // without oxygen (no empty neighbors) undergoes slow thermal
    // decomposition into fixed carbon (ash) and volatile gases (smoke).
    // Higher threshold than ignition (200 vs 190) because pyrolysis
    // requires sustained heating. Rate is slow (1/60) since real
    // charcoal production takes hours in a kiln.
    if (temperature[idx] >= 200) {
      int airCount = 0;
      for (int ady = -1; ady <= 1; ady++) {
        for (int adx = -1; adx <= 1; adx++) {
          if (adx == 0 && ady == 0) continue;
          final anx = wrapX(x + adx);
          final any = y + ady;
          if (inBoundsY(any) && grid[any * gridW + anx] == El.empty) airCount++;
        }
      }
      if (airCount == 0 && rng.nextInt(SimTuning.woodAnoxicPyrolysis) == 0) {
        grid[idx] = El.ash; life[idx] = 0; velY[idx] = 0;
        markProcessed(idx);
        return;
      }
    }

    // Pilot flame ignition: wood in direct contact with fire or burning
    // wood catches fire through surface pyrolysis. The flame's convective
    // heat flux (~25 kW/m²) causes rapid surface decomposition without
    // needing the bulk to reach flash point.
    // Pilot flame ignition: fire adjacent to wood surface ignites it
    // through convective heat flux (~25 kW/m²). At this heat flux, wood
    // surface reaches pyrolysis temperature within ~1 second, so ignition
    // should be rapid (50% per frame ≈ 2-frame expected ignition time).
    if (checkAdjacent(x, y, El.fire) && rng.nextBool()) {
      life[idx] = 1; // Start burning from contact
      return;
    }

    // Gravity: wood falls through empty space when unsupported.
    // velY is used for water saturation (0-3), so no momentum tracking.
    final by = y + gravityDir;
    if (inBoundsY(by)) {
      final belowEl = grid[by * gridW + x];
      if (belowEl == El.empty) {
        swap(idx, by * gridW + x);
        return;
      }
    }

    // Water absorption (velY 0-3 = water saturation level)
    if (checkAdjacent(x, y, El.water) && velY[idx] < 3) {
      if (rng.nextInt(SimTuning.woodWaterAbsorb) == 0) {
        velY[idx] = (velY[idx] + 1).clamp(0, 3).toInt();
        removeOneAdjacent(x, y, El.water);
      }
    }

    // Waterlogged wood (velY >= 3) sinks through water via buoyancy exchange
    if (velY[idx] >= 3) {
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

    if (checkAdjacentAny2(x, y, El.fire, El.lava)) {
      if (velY[idx] < 3 || rng.nextInt(SimTuning.woodWetBurn) == 0) {
        life[idx] = 1; velY[idx] = 0;
        queueReactionFlash(x, y, 255, 150, 30, 3);
      }
    }

    // Petrification: waterlogged wood (velY >= 2) near stone slowly turns to stone.
    // Simulates mineral-rich water slowly replacing organic material.
    if (velY[idx] >= 2 && life[idx] == 0 && frameCount % 30 == 0) {
      bool nearStone = false;
      bool nearWater = false;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final n = grid[ny * gridW + nx];
          if (n == El.stone) nearStone = true;
          if (n == El.water) nearWater = true;
        }
      }
      if (nearStone && nearWater && rng.nextInt(SimTuning.woodPetrify) == 0) {
        grid[idx] = El.stone;
        life[idx] = 0;
        velX[idx] = 0;
        velY[idx] = 0;
        markProcessed(idx);
        queueReactionFlash(x, y, 160, 160, 180, 3);
      }
    }
  }

  // =========================================================================
  // Metal
  // =========================================================================

  void simMetal(int x, int y, int idx) {
    // Structural integrity: metal is the strongest structural element.
    // Falls only when completely unsupported AND destabilized.
    final g = gravityDir;
    final by = y + g;
    final belowEmpty = inBoundsY(by) && (grid[by * gridW + x] == El.empty
        || grid[by * gridW + x] == El.water || grid[by * gridW + x] == El.oil);

    if (belowEmpty) {
      // Check ALL 8 neighbors for any structural support
      bool hasAnySupport = false;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (!inBoundsY(ny)) { hasAnySupport = true; continue; } // Edge = support
          final n = grid[ny * gridW + nx];
          if (n == El.stone || n == El.metal || n == El.dirt ||
              n == El.wood || n == El.glass || n == El.ice) {
            hasAnySupport = true;
          }
        }
      }
      // Metal only falls when completely isolated AND with accumulated velocity
      if (!hasAnySupport && velY[idx] > 0) {
        if (fallSolid(x, y, idx, El.metal)) return;
      } else if (!hasAnySupport) {
        // Start accumulating fall velocity slowly (metal resists gravity)
        if (rng.nextInt(SimTuning.metalFallResist) == 0) velY[idx] = 1;
      }
      // With any support, metal holds firm
    } else {
      velY[idx] = 0; // Reset velocity when resting on something
    }

    if (life[idx] >= 200) return;

    // Rusting: metal + water over time = rust (corrosion)
    // Alkaline pH (>180) protects metal — slows corrosion rate
    // Aged metal (cellAge > 250) + moisture = accelerated corrosion
    final metalPH = pH[idx];
    final alkalineProtection = metalPH > 180;
    final metalAge = cellAge[idx];
    final agingFactor = metalAge > 250 && moisture[idx] > 0 ? 3 : 1;
    final baseRustRate = (alkalineProtection ? 1500 : 500) ~/ agingFactor;
    if (checkAdjacent(x, y, El.water) && rng.nextInt(baseRustRate) == 0) {
      grid[idx] = El.rust; life[idx] = 0; markDirty(x, y); return;
    }
    // Salt water accelerates rusting 5x (dissolved salt in adjacent water)
    if (checkAdjacent(x, y, El.water)) {
      // Check for salt water (dissolved salt) or solid salt nearby
      bool saltWater = false;
      for (int dy = -1; dy <= 1 && !saltWater; dy++) {
        for (int dx = -1; dx <= 1 && !saltWater; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx); final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final ni = ny * gridW + nx;
          if (grid[ni] == El.water && dissolvedType[ni] == El.salt) {
            saltWater = true;
          }
          if (grid[ni] == El.salt) saltWater = true;
        }
      }
      if (saltWater && rng.nextInt(alkalineProtection ? 300 : 100) == 0) {
        grid[idx] = El.rust; life[idx] = 0; markDirty(x, y); return;
      }
    }

    // Charged metal attracts nearby metal particles (basic magnetism)
    // High charge on this metal cell pulls loose metal toward it
    {
      final ch = charge[idx];
      if (ch.abs() > 30 && frameCount % 6 == 0) {
        for (int dy = -2; dy <= 2; dy++) {
          for (int dx = -2; dx <= 2; dx++) {
            if (dx == 0 && dy == 0) continue;
            if (dx.abs() + dy.abs() > 3) continue; // Manhattan distance 3
            final nx = wrapX(x + dx); final ny = y + dy;
            if (!inBoundsY(ny)) continue;
            final ni = ny * gridW + nx;
            if (grid[ni] == El.metal) {
              // Check if that metal is unsupported (can move)
              final belowNy = ny + gravityDir;
              final nBelow = inBoundsY(belowNy) ? grid[belowNy * gridW + nx] : 0;
              if (nBelow == El.empty || nBelow == El.water) {
                // Pull toward this cell: find empty cell between them
                final mx = x + (dx > 0 ? -1 : (dx < 0 ? 1 : 0));
                final my = y + (dy > 0 ? -1 : (dy < 0 ? 1 : 0));
                final mxW = wrapX(mx);
                if (inBoundsY(my)) {
                  final mi = my * gridW + mxW;
                  if (grid[mi] == El.empty) {
                    swap(ni, mi);
                    markDirty(nx, ny);
                    markDirty(mxW, my);
                    break;
                  }
                }
              }
            }
          }
        }
      }
    }

    // Heat conduction: metal (heatConductivity=0.9) absorbs and transfers
    // heat from fire/lava. Real metals conduct heat ~100-400 W/(m·K),
    // orders of magnitude faster than stone or wood. velX encodes heat
    // level 0-5, matching the stone heat glow system.
    {
      final heat = velX[idx].clamp(0, 5);

      // Absorb heat from adjacent fire/lava
      if (frameCount % 3 == 0) {
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            final nx = wrapX(x + dx);
            final ny = y + dy;
            if (!inBoundsY(ny)) continue;
            final ni = ny * gridW + nx;
            final neighbor = grid[ni];
            if (neighbor == El.lava && heat < 5) {
              velX[idx] = (heat + 1).clamp(0, 5);
              markDirty(x, y);
            } else if (neighbor == El.fire && heat < 4) {
              velX[idx] = (heat + 1).clamp(0, 4);
              markDirty(x, y);
            }
          }
        }
      }

      // Conduct heat to neighboring metal (chain conduction)
      if (heat > 0 && frameCount % 4 == 0) {
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            final nx = wrapX(x + dx);
            final ny = y + dy;
            if (!inBoundsY(ny)) continue;
            final ni = ny * gridW + nx;
            if (grid[ni] == El.metal) {
              final neighborHeat = velX[ni].clamp(0, 5);
              if (neighborHeat < heat - 1) {
                velX[ni] = neighborHeat + 1;
                markDirty(nx, ny);
              }
            }
          }
        }
      }

      // Hot metal radiates heat to surroundings
      if (heat >= 3 && frameCount % 8 == 0) {
        emitRadiantHeat(x, y, idx, 2, heat * 6);
      }

      // Slow cooling when not adjacent to heat sources
      if (heat > 0 && frameCount % 10 == 0) {
        final nearHeat = checkAdjacentAny2(x, y, El.fire, El.lava);
        if (!nearHeat) {
          velX[idx] = (heat - 1).clamp(0, 5);
          markDirty(x, y);
        }
      }

      // Hot metal ignites adjacent flammable materials
      if (heat >= 4) {
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            final nx = wrapX(x + dx);
            final ny = y + dy;
            if (!inBoundsY(ny)) continue;
            final ni = ny * gridW + nx;
            final neighbor = grid[ni];
            if ((neighbor == El.oil || neighbor == El.plant ||
                neighbor == El.seed) && rng.nextInt(SimTuning.metalHotIgniteRate) == 0) {
              grid[ni] = El.fire; life[ni] = 0; markProcessed(ni);
              queueReactionFlash(nx, ny, 255, 160, 40, 3);
            } else if (neighbor == El.wood && life[ni] == 0 && rng.nextInt(SimTuning.metalHotWoodChar) == 0) {
              life[ni] = 1; // Start wood charring
            }
          }
        }
      }
    }

    if (checkAdjacent(x, y, El.water)) {
      life[idx]++;
      if (life[idx] > 120) {
        grid[idx] = El.dirt; life[idx] = 0; markProcessed(idx); return;
      }
    }

    if (rng.nextInt(SimTuning.metalCondensation) == 0) {
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

    // Thermal buoyancy: smoke rises due to density difference with
    // surrounding air. By Archimedes' principle, buoyancy force
    // F_b = (ρ_air - ρ_smoke) × g × V. Hot smoke (high temp) has
    // lower density and rises vigorously. As smoke cools toward ambient
    // (temp ≈ 128), it loses buoyancy and becomes neutrally buoyant,
    // transitioning from vertical rise to lateral drift — forming the
    // characteristic mushroom shape of real smoke plumes.
    final smokeTemp = temperature[idx];
    final heatExcess = (smokeTemp - 128).clamp(0, 127); // 0 = ambient, 127 = very hot

    // Rise probability: hot smoke rises every frame, cool smoke
    // rises less frequently. At ambient temp, smoke barely rises.
    // heatExcess 0 → rise ~1/4 frames, 40+ → every frame
    final riseChance = heatExcess > 40 ? 1 : (heatExcess > 15 ? 2 : 4);
    final shouldRise = riseChance <= 1 || rng.nextInt(riseChance) == 0;

    // Drift increases as buoyancy decreases (cool smoke spreads laterally)
    // Use local wind field for drift bias
    final localWind = windX2[idx];
    final driftChance = heatExcess > 40 ? 20 : (heatExcess > 15 ? 5 : 3);
    int drift = rng.nextInt(driftChance) == 0 ? (rng.nextBool() ? 1 : -1) : 0;
    if (localWind != 0) {
      final windBias = localWind > 0 ? 1 : -1;
      if (rng.nextInt(SimTuning.smokeLateralDrift) < 2) drift = windBias;
    } else if (windForce != 0) {
      final windBias = windForce > 0 ? 1 : -1;
      if (rng.nextInt(SimTuning.smokeLateralDrift) < 2) drift = windBias;
    }

    if (shouldRise && inBoundsY(uy)) {
      final nx = wrapX(x + drift);
      if (grid[uy * gridW + nx] == El.empty) { swap(idx, uy * gridW + nx); return; }
      if (grid[uy * gridW + x] == El.empty) { swap(idx, uy * gridW + x); return; }
    }
    // Lateral drift when not rising or blocked (cool smoke disperses)
    final hasWind = localWind != 0 || windForce != 0;
    if (!shouldRise || hasWind || rng.nextInt(SimTuning.smokeLateralDrift) == 0) {
      final windDir = localWind != 0 ? localWind : windForce;
      final side = wrapX(windDir != 0
          ? x + (windDir > 0 ? 1 : -1)
          : (rng.nextBool() ? x - 1 : x + 1));
      if (grid[y * gridW + side] == El.empty) {
        swap(idx, y * gridW + side);
      }
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
      if (life[idx] % 2 == 0 && inBoundsY(uy)) {
        // Buoyancy-driven rise: predominantly straight up with rare
        // lateral wobble. Small bubbles (Re < 200) rise in straight
        // paths; wobble only appears at larger Re from vortex shedding.
        final wobble = rng.nextInt(SimTuning.bubbleWobble) == 0 ? (rng.nextBool() ? 1 : -1) : 0;
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
      // Out of water — rise briefly then pop (bubbles can't exist in air)
      if (life[idx] > 1) {
        grid[idx] = El.empty; life[idx] = 0;
        queueReactionFlash(x, y, 130, 200, 240, 2);
        return;
      }
      // Float upward for 1 tick before popping
      if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
        final ni = uy * gridW + x;
        grid[ni] = El.bubble; life[ni] = life[idx];
        grid[idx] = El.empty; life[idx] = 0;
        markProcessed(ni);
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
          if (rng.nextInt(SimTuning.ashLateralDrift) == 0) {
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

    // Granular fall with velocity accumulation. Ash reaches terminal
    // velocity (maxVelocity=2) via Stokes drag, matching the expected
    // constant-velocity free fall for light particles in air.
    fallGranular(x, y, idx, El.ash);
    // Avalanche: spread piles even when not falling
    if (rng.nextInt(SimTuning.ashAvalanche) == 0) {
      _avalancheGranular(x, y, idx);
    }
  }

  // =========================================================================
  // TNT
  // =========================================================================

  void simTNT(int x, int y, int idx) {
    // Thermal detonation: TNT has an auto-ignition temperature of ~240°C.
    // In our system, when temperature exceeds 210, the nitro groups
    // undergo exothermic decomposition without needing a flame source.
    // This models cook-off: ordnance heated by fire eventually detonates
    // without direct flame contact (Chapman-Jouguet theory).
    final tntTemp = temperature[idx];
    if (tntTemp > 210) {
      pendingExplosions.add(Explosion(x, y, calculateTNTRadius(x, y)));
      grid[idx] = El.empty; life[idx] = 0; markProcessed(idx);
      return;
    }

    // Sympathetic detonation: shock waves from nearby explosions
    // can trigger TNT. If any adjacent cell is fire AND has high
    // temperature (indicating it was just created by an explosion),
    // this TNT detonates in the same frame — modeling the detonation
    // wave propagation velocity (~6900 m/s for TNT).
    if (checkAdjacent(x, y, El.fire)) {
      pendingExplosions.add(Explosion(x, y, calculateTNTRadius(x, y)));
      grid[idx] = El.empty; life[idx] = 0; markProcessed(idx);
      return;
    }

    fallGranular(x, y, idx, El.tnt);
  }

  // =========================================================================
  // Advanced Materials (Phase 7)
  // =========================================================================

  void simC4(int x, int y, int idx) {
    // C4 (Composition 4): extremely stable plastic explosive.
    // Real C4 can be burned, shot, dropped — it won't detonate.
    // It ONLY detonates from: a blasting cap (electrical), a shockwave
    // (sympathetic detonation from nearby explosion), or extreme pressure.
    // Detonation velocity: 8,092 m/s — devastatingly powerful.

    final myVolt = voltage[idx].abs();
    final myPres = pressure[idx];
    final myVib = vibration[idx];

    // Electrical detonator: any significant voltage (blasting cap = ~50V)
    final electricTrigger = myVolt > 50;

    // Shockwave from nearby explosion: vibration propagates through ground
    final shockwaveTrigger = myVib > 120;

    // Extreme pressure (another explosion's blast wave)
    final pressureTrigger = myPres > 80;

    // Adjacent C4 that's already detonating (chain detonation)
    bool chainTrigger = false;
    if (!electricTrigger && !shockwaveTrigger && !pressureTrigger) {
      // Only check neighbors if primary triggers failed (saves perf)
      for (int dy = -1; dy <= 1 && !chainTrigger; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final ni = ny * gridW + nx;
          // Fire adjacent to C4 under pressure (shaped charge scenario)
          if (grid[ni] == El.fire && myPres > 20) { chainTrigger = true; break; }
          // Nearby explosion remnant (empty cell with high vibration = just exploded)
          if (vibration[ni] > 200) { chainTrigger = true; break; }
        }
      }
    }

    if (electricTrigger || shockwaveTrigger || pressureTrigger || chainTrigger) {
      // C4 blast is much more powerful than TNT
      pendingExplosions.add(Explosion(x, y, calculateTNTRadius(x, y) + 14));
      grid[idx] = El.empty; life[idx] = 0; markProcessed(idx);
      // Propagate massive vibration for chain detonation of nearby C4
      vibration[idx] = 255;
      vibrationFreq[idx] = 30; // deep boom
      return;
    }

    // C4 is sticky/plastic — stays where placed unless unsupported
    fallSolid(x, y, idx, El.c4);
  }

  void simUranium(int x, int y, int idx) {
    // Uranium generates heat based on the presence of OTHER uranium nearby (critical mass).
    int neighborUraniumCount = 0;
    for (int dy = -2; dy <= 2; dy++) {
      for (int dx = -2; dx <= 2; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = wrapX(x + dx);
        final ny = y + dy;
        if (!inBoundsY(ny)) continue;
        final ni = ny * gridW + nx;
        if (grid[ni] == El.uranium || grid[ni] == El.lava) {
          // Lava counts because it might be melted uranium
          neighborUraniumCount++;
        }
      }
    }

    // If critical mass is reached, dramatically increase temperature.
    if (neighborUraniumCount > 6) {
      int currentTemp = temperature[idx];
      // Runaway thermal reaction
      currentTemp += (neighborUraniumCount * 2);
      if (currentTemp > 255) currentTemp = 255;
      temperature[idx] = currentTemp;
      
      // If extremely hot, emit intense radiation/light
      if (currentTemp > 220 && rng.nextInt(5) == 0) {
        queueReactionFlash(x, y, 100, 255, 100, 4); // Bright green flash
        
        // Radiation damage to nearby organic material
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            final nx = wrapX(x + dx);
            final ny = y + dy;
            if (!inBoundsY(ny)) continue;
            final ni = ny * gridW + nx;
            final ne = grid[ni];
            if (ne > 0 && ne < maxElements) {
              if ((elCategory[ne] & ElCat.organic) != 0) {
                // Irradiate organics: turn them into ash or charcoal
                grid[ni] = rng.nextBool() ? El.ash : El.charcoal;
                markProcessed(ni);
              }
            }
          }
        }
      }
    }
    
    fallSolid(x, y, idx, El.uranium);
  }

  void simLead(int x, int y, int idx) {
    // Lead acts as a dense physical and thermal shield.
    // It doesn't do much actively, but its high heat capacity and low conductivity
    // in element_registry naturally block Uranium's heat and radiation.
    fallSolid(x, y, idx, El.lead);
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
    // Convection: hot mud rises through cold mud
    if (tryConvection(x, y, idx, El.mud)) return;

    // Contact drying: mud adjacent to fire/lava dries. At 1/4 rate because
    // real mud requires sustained heat to evaporate water content (~25%).
    if (rng.nextInt(SimTuning.mudContactDry) == 0 && (checkAdjacentAny2(x, y, El.fire, El.lava))) {
      grid[idx] = El.dirt; life[idx] = 0; markProcessed(idx);
      queueReactionFlash(x, y, 180, 180, 200, 2);
      return;
    }

    // Proximity drying: mud within 3 cells of fire/lava dries from
    // radiant heat evaporating its moisture content.
    if (rng.nextInt(SimTuning.mudProximityDry) == 0) {
      for (int dy = -3; dy <= 3; dy++) {
        for (int dx = -3; dx <= 3; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final n = grid[ny * gridW + nx];
          if (n == El.fire || n == El.lava) {
            grid[idx] = El.dirt; life[idx] = 0; markProcessed(idx);
            queueReactionFlash(x, y, 180, 180, 200, 2);
            return;
          }
        }
      }
    }

    final g = gravityDir;
    final by = y + g;

    // Gravity always applies — mud falls every frame
    if (inBoundsY(by) && isEmptyOrGas(grid[by * gridW + x])) { swap(idx, by * gridW + x); return; }

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
    if (inBoundsY(by) && isEmptyOrGas(grid[by * gridW + mx1])) { swap(idx, by * gridW + mx1); return; }
    if (inBoundsY(by) && isEmptyOrGas(grid[by * gridW + mx2])) { swap(idx, by * gridW + mx2); return; }

    // Viscous lateral spread — only when pressured by adjacent mud/water
    if (frameCount % elementViscosity[El.mud] == 0) {
      bool pressured = false;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (inBoundsY(ny)) {
            final n = grid[ny * gridW + nx];
            if (n == El.mud || n == El.water) { pressured = true; break; }
          }
        }
        if (pressured) break;
      }
      if (pressured) {
        if (isEmptyOrGas(grid[y * gridW + mx1])) { swap(idx, y * gridW + mx1); return; }
        if (isEmptyOrGas(grid[y * gridW + mx2])) { swap(idx, y * gridW + mx2); }
      }
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

    // Underground steam lasts longer — trapped in cave ceilings.
    // Scan upward to detect enclosure (ceiling within 3 cells).
    bool isTrappedUnderground = false;
    for (int scan = 1; scan <= 3; scan++) {
      final sy = y - gravityDir * scan;
      if (!inBoundsY(sy)) break;
      final above = grid[sy * gridW + x];
      if (above == El.stone || above == El.dirt || above == El.metal) {
        isTrappedUnderground = true;
        break;
      }
      if (above != El.empty && above != El.steam && above != El.smoke) break;
    }

    // Steam lifespan follows the Hertz-Knudsen evaporation model:
    // hot steam persists longer (higher vapor pressure supports the phase),
    // while cool steam condenses faster. Open-air steam at 60fps should
    // last 0.5-1.5s (30-90 frames) for realistic wisps.
    // Underground: 80-140 frames — cave humidity lingers visibly.
    final steamTemp = temperature[idx];
    final hotBonus = ((steamTemp - 128).clamp(0, 80)) ~/ 4; // 0-20 extra frames for hot steam
    final steamLife = isTrappedUnderground
        ? (isNight ? 80 + rng.nextInt(40) : 100 + rng.nextInt(40))
        : (isNight ? 25 + rng.nextInt(20) : 30 + rng.nextInt(25)) + hotBonus;

    if (life[idx] > steamLife) {
      // Open-air steam almost always vanishes — no mid-air condensation.
      // Only underground steam can re-condense (dripping cave ceilings).
      if (!atEdge && isTrappedUnderground && rng.nextInt(isNight ? 3 : 5) == 0) {
        grid[idx] = El.water; life[idx] = 100;
      } else {
        grid[idx] = El.empty; life[idx] = 0;
      }
      markProcessed(idx);
      return;
    }
    // Steam at the sky boundary dissipates — but trapped steam (under
    // stone/metal ceiling) persists in enclosed spaces.
    if (atEdge && !isTrappedUnderground) {
      // Adiabatic cooling at altitude: rising steam expands and cools.
      // ~20% condenses to rain (orographic precipitation), rest dissipates.
      if (rng.nextInt(SimTuning.steamAltitudeRain) == 0) {
        grid[idx] = El.water; life[idx] = 100;
        temperature[idx] = 128; // neutral — cooled by expansion
      } else {
        grid[idx] = El.empty; life[idx] = 0;
      }
      markProcessed(idx); return;
    }

    // Rain (altitude condensation): steam in top 8% of grid becomes rain.
    // Adiabatic lapse rate: rising air cools ~6.5°C/km, eventually reaching
    // dew point. Higher altitude = cooler = more condensation.
    final topThreshold = gravityDir == 1
        ? (gridH * 10) ~/ 100
        : gridH - ((gridH * 10) ~/ 100);
    final isAtAltitude = gravityDir == 1 ? y < topThreshold : y > topThreshold;
    if (isAtAltitude && rng.nextInt(isNight ? 400 : 800) == 0) {
      grid[idx] = El.water;
      life[idx] = 100;
      markProcessed(idx);
      return;
    }

    // Deposition (desublimation): gas → solid directly, skipping liquid.
    // The thermodynamic reverse of sublimation. When steam is deeply
    // subcooled (temp < 50) near a cold surface, water vapor deposits
    // as frost/ice crystals. This is how hoarfrost forms on cold
    // mornings and how frost patterns grow on windows. The Gibbs free
    // energy favors direct solid nucleation when ΔT is large enough
    // that the liquid phase is entirely bypassed.
    {
      final st = temperature[idx];
      if (st < 50) {
        // Check for cold solid surfaces (nucleation sites)
        bool coldSurfaceAdjacent = false;
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            final nx = wrapX(x + dx);
            final ny = y + dy;
            if (!inBoundsY(ny)) continue;
            final n = grid[ny * gridW + nx];
            if (n == El.ice || n == El.stone || n == El.metal || n == El.glass) {
              if (temperature[ny * gridW + nx] < 80) {
                coldSurfaceAdjacent = true;
              }
            }
          }
          if (coldSurfaceAdjacent) break;
        }
        if (coldSurfaceAdjacent) {
          // Deep subcooling → deterministic deposition
          if (st < 30 || rng.nextInt(SimTuning.steamDeposition) == 0) {
            grid[idx] = El.ice; life[idx] = 0;
            temperature[idx] = (st + 15).clamp(0, 255); // latent heat release
            markProcessed(idx);
            queueReactionFlash(x, y, 180, 220, 255, 3);
            return;
          }
        }
      }
    }

    // Temperature-driven condensation: steam below the dew point
    // condenses spontaneously. The Clausius-Clapeyron relation shows
    // that saturation vapor pressure drops exponentially with temperature.
    // Below ~100°C (temp≈108 in our scale), steam is supersaturated and
    // condenses. Rate increases with subcooling.
    {
      final st = temperature[idx];
      if (st < 108) {
        final dewSubcool = 108 - st; // how far below dew point
        // Deterministic condensation at deep subcooling
        if (dewSubcool > 20 || rng.nextInt((30 - dewSubcool).clamp(2, 30)) == 0) {
          grid[idx] = El.water; life[idx] = 100; markProcessed(idx); return;
        }
      }
    }

    // Heterogeneous condensation: steam deposits on cold surfaces (ice)
    // when the surface temperature is below the dew point. This is the
    // physical mechanism behind frost formation and steam condensing on
    // cold windows. Rate depends on temperature difference.
    if (checkAdjacent(x, y, El.ice)) {
      // Steam near ice condenses readily — ~75% chance per frame.
      // The ice surface acts as a nucleation site; the large thermal
      // gradient ensures rapid heat extraction from the vapor phase.
      // Condensation releases latent heat (2260 kJ/kg), warming the
      // resulting water well above freezing point.
      if (rng.nextInt(SimTuning.steamIceCondense) != 0) {
        grid[idx] = El.water; life[idx] = 100;
        temperature[idx] = 160; // latent heat of condensation warms the water
        markProcessed(idx); return;
      }
    }

    // Adjacent-water condensation — only meaningful underground or at night.
    // In open air this is extremely rare to prevent steam/water flickering
    // at water surface boundaries.
    final condenseChance = isTrappedUnderground
        ? (isNight ? 100 : 200)
        : (isNight ? 500 : 1000);
    if (rng.nextInt(condenseChance) == 0 && checkAdjacent(x, y, El.water)) {
      grid[idx] = El.water; life[idx] = 100; markProcessed(idx); return;
    }

    // Trapped steam dissipates slowly through cracks
    if (isTrappedUnderground && rng.nextInt(SimTuning.steamTrappedSeep) == 0) {
      // Look for gaps in the ceiling to seep through
      for (int dxI = 0; dxI < 3; dxI++) { final dx = dxI - 1;
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
      for (int dxI = 0; dxI < 2; dxI++) { final dx = dxI == 0 ? 1 : -1;
        final nx = wrapX(x + dx);
        if (grid[y * gridW + nx] == El.empty) {
          swap(idx, y * gridW + nx);
          return;
        }
      }
    }

    // Use local wind field for drift bias
    final localWind = windX2[idx];
    if (inBoundsY(uy)) {
      int drift = rng.nextInt(3) - 1;
      // Wind biases drift direction
      if (localWind != 0 && rng.nextInt(3) < 2) {
        drift = localWind > 0 ? 1 : -1;
      }
      final nx = wrapX(x + drift);
      if (grid[uy * gridW + nx] == El.empty) { swap(idx, uy * gridW + nx); return; }
      if (grid[uy * gridW + x] == El.empty) { swap(idx, uy * gridW + x); return; }
    }
    final windDir = localWind != 0 ? (localWind > 0 ? 1 : -1) : 0;
    final side = wrapX(windDir != 0 ? x + windDir : (rng.nextBool() ? x - 1 : x + 1));
    if (grid[y * gridW + side] == El.empty) { swap(idx, y * gridW + side); }
  }

  // =========================================================================
  // Oil
  // =========================================================================

  void simOil(int x, int y, int idx) {
    // Temperature-driven boiling (oil -> smoke at high temp)
    if (checkTemperatureReaction(x, y, idx, El.oil)) return;

    // Convection: hot oil rises through cold oil
    if (tryConvection(x, y, idx, El.oil)) return;

    // Flash point auto-ignition: oil vapor above its flash point ignites
    // spontaneously. Real oil flash points (200-300°C) are below boil
    // points. In our system, oil heated above 145 (below boilPoint 160)
    // has sufficient vapor concentration for combustion.
    if (temperature[idx] > 145) {
      grid[idx] = El.fire; life[idx] = 0; markProcessed(idx); return;
    }

    if (checkAdjacentAny2(x, y, El.fire, El.lava)) {
      grid[idx] = El.fire; life[idx] = 0; markProcessed(idx); return;
    }

    final by = y + gravityDir;
    final uy = y - gravityDir;

    // Check if water exists below this oil (within 8 cells) — oil should float
    bool waterBelow = false;
    for (int d = 1; d <= 8; d++) {
      final checkY = y + gravityDir * d;
      if (!inBoundsY(checkY)) break;
      final checkEl = grid[checkY * gridW + x];
      if (checkEl == El.water) { waterBelow = true; break; }
      if (checkEl != El.empty && checkEl != El.oil) break;
    }
    // Also check sides for water (oil inside water body)
    if (!waterBelow) {
      final lx = wrapX(x - 1);
      final rx = wrapX(x + 1);
      if (grid[y * gridW + lx] == El.water || grid[y * gridW + rx] == El.water) {
        waterBelow = true;
      }
    }

    // Buoyancy: oil (density 80) rises through water (density 100)
    final clockBit = simClock ? 0x80 : 0;
    if (inBoundsY(uy) && grid[uy * gridW + x] == El.water &&
        (flags[uy * gridW + x] & 0x80) != clockBit) {
      final ui2 = uy * gridW + x;
      final waterMass = life[ui2];
      grid[ui2] = El.oil; life[ui2] = life[idx];
      grid[idx] = El.water; life[idx] = waterMass < 20 ? 100 : waterMass;
      markProcessed(ui2); markProcessed(idx);
      return;
    }

    // Active float: if water is below and above is empty, rise upward
    if (waterBelow && inBoundsY(uy) && isEmptyOrGas(grid[uy * gridW + x])) {
      swap(idx, uy * gridW + x); return;
    }

    // Fall through empty/gas — only when NOT above any water body
    if (inBoundsY(by) && isEmptyOrGas(grid[by * gridW + x])) {
      if (!waterBelow) {
        swap(idx, by * gridW + x); return;
      }
    }

    final dl = rng.nextBool();
    final ox1 = wrapX(dl ? x - 1 : x + 1);
    final ox2 = wrapX(dl ? x + 1 : x - 1);

    // Diagonal fall — only when not above water
    if (!waterBelow && inBoundsY(by)) {
      if (isEmptyOrGas(grid[by * gridW + ox1])) { swap(idx, by * gridW + ox1); return; }
      if (isEmptyOrGas(grid[by * gridW + ox2])) { swap(idx, by * gridW + ox2); return; }
    }

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
    // Only spread when NOT above water (oil floating on water should stay put)
    if (!waterBelow && frameCount % elementViscosity[El.oil] == 0) {
      if (isEmptyOrGas(grid[y * gridW + ox1])) { swap(idx, y * gridW + ox1); return; }
      if (isEmptyOrGas(grid[y * gridW + ox2])) { swap(idx, y * gridW + ox2); }
    }
  }

  // =========================================================================
  // Acid
  // =========================================================================

  void simAcid(int x, int y, int idx) {
    // Convection: hot acid rises through cold acid
    if (tryConvection(x, y, idx, El.acid)) return;

    life[idx]++;

    if (life[idx] > SimTuning.acidLifetimeBase + rng.nextInt(SimTuning.acidLifetimeVar)) {
      grid[idx] = El.empty; life[idx] = 0; return;
    }

    // Selective corrosion: acid preferentially attacks the least resistant
    // neighbor. Real chemistry: reaction kinetics follow Arrhenius rates
    // k = A * exp(-Ea/RT), so lower activation energy (resistance) reactions
    // dominate. Find the most reactive target first.
    int bestNi = -1, bestResist = 999;
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = wrapX(x + dx);
        final ny = y + dy;
        if (!inBoundsY(ny)) continue;
        final ni = ny * gridW + nx;
        final neighbor = grid[ni];
        if (neighbor != El.empty && neighbor != El.water &&
            neighbor != El.fire && neighbor != El.acid && neighbor != El.lava &&
            neighbor != El.smoke && neighbor != El.steam && neighbor != El.bubble) {
          final resistance = neighbor < maxElements ? elementCorrosionResistance[neighbor] : 0;
          if (resistance < bestResist) {
            bestResist = resistance;
            bestNi = ni;
          }
        }
      }
    }
    if (bestNi >= 0) {
      // Arrhenius temperature dependence: k = A·exp(-Ea/RT).
      // Reaction rate roughly doubles every 10°C. On our 0-255 scale,
      // neutral=128. Hot acid (temp>168) reacts ~2x faster; cold acid
      // (temp<88) reacts ~2x slower. This models real acid chemistry
      // where heated acid etches glass/metal much faster.
      final acidTemp = temperature[idx];
      final tempFactor = acidTemp > 168 ? 2 : (acidTemp < 88 ? 0 : 1);
      final baseChance = 6 + (bestResist * 24) ~/ 90;
      final dissolveChance = tempFactor == 2
          ? (baseChance + 1) ~/ 2 // hot: halve the delay
          : (tempFactor == 0 ? baseChance * 2 : baseChance); // cold: double
      if (rng.nextInt(dissolveChance.clamp(1, 255)) == 0) {
        final dissolvedEl = grid[bestNi];
        grid[bestNi] = El.empty; life[bestNi] = 0; markProcessed(bestNi);
        final bnx = bestNi % gridW;
        final bny = bestNi ~/ gridW;
        // Acid sets low pH on the dissolved cell's location
        pH[bestNi] = 30;
        queueReactionFlash(bnx, bny, 60, 230, 60, 4);
        // Hydrogen evolution: acid dissolving metal produces H₂ gas.
        // Real reaction: 2HCl + Fe → FeCl₂ + H₂↑. The hydrogen gas
        // rises as visible bubbles. Only metals trigger this — their
        // electrochemical potential drives the redox half-reaction.
        if (dissolvedEl == El.metal) {
          final bubbleY = bny - gravityDir;
          if (inBoundsY(bubbleY)) {
            final bi = bubbleY * gridW + bnx;
            if (grid[bi] == El.empty || grid[bi] == El.water ||
                grid[bi] == El.acid) {
              grid[bi] = El.bubble; life[bi] = 0; markProcessed(bi);
              queueReactionFlash(bnx, bubbleY, 200, 220, 240, 3);
            }
          }
        }
        // Acid consumed when dissolving very hard materials (metal/glass).
        // Moderate materials age the acid (gradual neutralization).
        if (bestResist >= 80) {
          grid[idx] = El.empty; life[idx] = 0;
          return;
        }
        life[idx] = (life[idx] + 10).clamp(0, 255);
        markDirty(x, y);
        return;
      }
    }

    // Non-corrosion neighbor reactions
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = wrapX(x + dx);
        final ny = y + dy;
        if (!inBoundsY(ny)) continue;
        final ni = ny * gridW + nx;
        final neighbor = grid[ni];

        if (neighbor == El.ant) {
          grid[ni] = El.empty; life[ni] = 0; markProcessed(ni);
        }
        if (neighbor == El.water && rng.nextInt(SimTuning.acidWaterDilute) == 0) {
          grid[idx] = El.water; life[idx] = 100; markProcessed(idx); return;
        }
        if (neighbor == El.ice && rng.nextInt(SimTuning.acidIceMelt) == 0) {
          grid[ni] = El.water; life[ni] = 80; markProcessed(ni);
          queueReactionFlash(nx, ny, 80, 255, 120, 3);
        }
        // Acid melts snow to water. Snow is crystalline ice with high
        // surface area — acid's exothermic dissolution provides latent
        // heat for melting while the acid is partially consumed.
        if (neighbor == El.snow && rng.nextInt(SimTuning.acidSnowMelt) == 0) {
          grid[ni] = El.water; life[ni] = 60; markProcessed(ni);
          queueReactionFlash(nx, ny, 80, 240, 100, 3);
          life[idx] = (life[idx] + 15).clamp(0, 255); // acid ages faster
        }
        if (neighbor == El.lava && rng.nextInt(SimTuning.acidLavaReact) == 0) {
          // Acid + lava: violent reaction producing steam and smoke
          grid[ni] = El.steam; life[ni] = 0; markProcessed(ni);
          grid[idx] = El.smoke; life[idx] = 0; markProcessed(idx);
          queueReactionFlash(nx, ny, 200, 255, 100, 6);
          return;
        }
        if (neighbor == El.water && rng.nextInt(SimTuning.acidWaterBubble) == 0) {
          grid[ni] = El.bubble; life[ni] = 0; markProcessed(ni);
        }
      }
    }

    final by = y + gravityDir;
    if (inBoundsY(by) && isEmptyOrGas(grid[by * gridW + x])) { swap(idx, by * gridW + x); return; }

    final dl = rng.nextBool();
    final acx1 = wrapX(dl ? x - 1 : x + 1);
    final acx2 = wrapX(dl ? x + 1 : x - 1);
    if (inBoundsY(by) && isEmptyOrGas(grid[by * gridW + acx1])) { swap(idx, by * gridW + acx1); return; }
    if (inBoundsY(by) && isEmptyOrGas(grid[by * gridW + acx2])) { swap(idx, by * gridW + acx2); return; }
    if (isEmptyOrGas(grid[y * gridW + acx1])) { swap(idx, y * gridW + acx1); return; }
    if (isEmptyOrGas(grid[y * gridW + acx2])) { swap(idx, y * gridW + acx2); }
  }

  // =========================================================================
  // Stone (heated stone cooling)
  // =========================================================================

  void simStone(int x, int y, int idx) {
    // Temperature-driven melting (stone -> lava at extreme heat)
    if (checkTemperatureReaction(x, y, idx, El.stone)) return;

    // Structural integrity: stone only falls if it lacks solid support.
    // Check below, left, and right for any solid/structural neighbor.
    // If at least one structural neighbor exists, stone holds in place.
    final g = gravityDir;
    final by = y + g;
    // Out of bounds below means grounded (grid edge acts as bedrock)
    final belowEmpty = inBoundsY(by) && (grid[by * gridW + x] == El.empty
        || grid[by * gridW + x] == El.water || grid[by * gridW + x] == El.oil);

    if (belowEmpty) {
      // Check for lateral structural support
      final lx = wrapX(x - 1);
      final rx = wrapX(x + 1);
      final leftSupport = grid[y * gridW + lx];
      final rightSupport = grid[y * gridW + rx];

      // Stone, metal, dirt, wood, glass all provide structural support
      bool hasSupport(int el) =>
          el == El.stone || el == El.metal || el == El.dirt ||
          el == El.wood || el == El.glass || el == El.ice;

      final supported = hasSupport(leftSupport) || hasSupport(rightSupport);

      if (supported) {
        // Check diagonal support too — need at least one solid below-adjacent
        final blx = inBoundsY(by) ? grid[by * gridW + lx] : 0;
        final brx = inBoundsY(by) ? grid[by * gridW + rx] : 0;
        if (hasSupport(blx) || hasSupport(brx)) {
          // Fully supported — don't fall. But if the support structure
          // is thin (only 1 side), there's a small chance of crumbling.
          final bothSides = hasSupport(leftSupport) && hasSupport(rightSupport);
          if (bothSides || rng.nextInt(SimTuning.stoneThinSupport) != 0) {
            // Hold position — structural integrity intact
          } else {
            // Thin support crumbles occasionally
            if (fallSolid(x, y, idx, El.stone)) return;
          }
        } else {
          // Lateral support but no diagonal — stable if both sides support,
          // otherwise weaker structure crumbles occasionally
          final bothSidesLateral = hasSupport(leftSupport) && hasSupport(rightSupport);
          if (!bothSidesLateral && rng.nextInt(SimTuning.stoneNoLateralFall) == 0) {
            if (fallSolid(x, y, idx, El.stone)) return;
          }
        }
      } else {
        // No support at all — fall immediately
        if (fallSolid(x, y, idx, El.stone)) return;
      }
    }

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

    // Blackbody radiation: heated stone radiates thermal energy to
    // surroundings (Stefan-Boltzmann law: q ∝ T⁴). At heat level 3+,
    // stone glows visibly and warms adjacent cells. This creates
    // realistic heat halos around recently solidified lava.
    if (heat >= 3 && frameCount % 12 == 0) {
      emitRadiantHeat(x, y, idx, 2, heat * 5);
    }

    // Slow cooling when not adjacent to heat sources
    if (frameCount % 8 == 0) {
      final nearHeat = checkAdjacentAny2(x, y, El.fire, El.lava);
      if (!nearHeat) {
        velX[idx] = (heat - 1).clamp(0, 5);
        markDirty(x, y);
      }
    }

    // Water weathering: exposed stone near water slowly erodes over time.
    // Surface stone (life[idx] == 0, meaning depth=0) exposed to water weathers.
    // Uses velY to track weathering progress (0-5). At 5, stone crumbles to sand.
    if (life[idx] == 0 && frameCount % 40 == 0 && checkAdjacent(x, y, El.water)) {
      final weathering = velY[idx].clamp(0, 5);
      if (weathering < 5) {
        if (rng.nextInt(SimTuning.stoneWeatherWater) == 0) {
          velY[idx] = (weathering + 1);
          markDirty(x, y);
        }
      } else if (rng.nextInt(SimTuning.stoneWeatherCrumble) == 0) {
        // Fully weathered — crumble to sand
        grid[idx] = El.sand;
        life[idx] = 0;
        velX[idx] = 0;
        velY[idx] = 0;
        markProcessed(idx);
        queueReactionFlash(x, y, 180, 170, 140, 2);
        return;
      }
    }
    // Freeze-thaw weathering (frost wedging): when water in stone pores
    // freezes, it expands ~9% by volume, generating pressures up to
    // 207 MPa — far exceeding the tensile strength of most rocks
    // (5-25 MPa). This accelerates mechanical breakdown when stone
    // alternates between frozen and thawed states. Adjacent ice indicates
    // freezing conditions; temperature fluctuation above freezing indicates
    // thaw cycles. This is the dominant weathering process in alpine and
    // periglacial environments (Matsuoka, 2001).
    if (life[idx] == 0 && frameCount % 30 == 0 && checkAdjacent(x, y, El.ice)) {
      final stoneTemp = temperature[idx];
      // Stone near ice with temperature fluctuation = active freeze-thaw
      // Higher temp near freezing point = more effective (water refreezes)
      if (stoneTemp > 40 && stoneTemp < 140) {
        final weathering = velY[idx].clamp(0, 5);
        if (weathering < 5) {
          // ~3x faster than water weathering alone
          if (rng.nextInt(SimTuning.stoneFrostWeather) == 0) {
            velY[idx] = (weathering + 1);
            markDirty(x, y);
          }
        } else if (rng.nextInt(SimTuning.stoneFrostCrumble) == 0) {
          // Frost-shattered stone breaks to sand/dirt mixture
          grid[idx] = rng.nextBool() ? El.sand : El.dirt;
          life[idx] = 0; velX[idx] = 0; velY[idx] = 0;
          markProcessed(idx);
          queueReactionFlash(x, y, 160, 170, 180, 2);
          return;
        }
      }
    }
    // Weathering resets when stone dries out (no water contact)
    if (life[idx] == 0 && velY[idx] > 0 && !checkAdjacent(x, y, El.water)) {
      if (frameCount % 80 == 0) {
        velY[idx] = (velY[idx] - 1).clamp(0, 5);
        markDirty(x, y);
      }
    }

    // Very hot stone can crack into lava if adjacent to enough lava
    if (heat >= 5 && rng.nextInt(SimTuning.stoneLavaCrack) == 0) {
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

    // Gravity: glass falls when unsupported
    // Check velocity before fall — if it was high and we just landed, shatter
    final preFallVel = velY[idx];
    final fell = fallSolid(x, y, idx, El.glass);
    if (fell) return;
    // Shatter on high-velocity impact: glass breaks into sand
    if (preFallVel > 3) {
      grid[idx] = El.sand;
      life[idx] = 0;
      velY[idx] = 0;
      markProcessed(idx);
      queueReactionFlash(x, y, 200, 220, 255, 4);
      return;
    }

    // Thermal shock shattering: spatial temperature gradient creates
    // differential expansion stress. Real soda-lime glass shatters when
    // σ_th = E·α·ΔT exceeds fracture strength (~50 MPa, ΔT ≈ 150°C).
    // On our 0-255 scale, ~40 units across a glass-neighbor boundary.
    // We measure the max temperature difference between this glass cell
    // and its cardinal neighbors — large gradients cause fracture.
    if (frameCount % 4 == 0) {
      final myTemp = temperature[idx];
      int maxGrad = 0;
      // Cardinal neighbors only (no allocation, unrolled)
      if (y > 0) {
        final d = (myTemp - temperature[idx - gridW]).abs();
        if (d > maxGrad) maxGrad = d;
      }
      if (y < gridH - 1) {
        final d = (myTemp - temperature[idx + gridW]).abs();
        if (d > maxGrad) maxGrad = d;
      }
      {
        final lx = wrapX(x - 1);
        final d = (myTemp - temperature[y * gridW + lx]).abs();
        if (d > maxGrad) maxGrad = d;
      }
      {
        final rx = wrapX(x + 1);
        final d = (myTemp - temperature[y * gridW + rx]).abs();
        if (d > maxGrad) maxGrad = d;
      }
      // Threshold 45: deterministic shatter; 35-44: probabilistic (1/3)
      if (maxGrad > 45 || (maxGrad > 35 && rng.nextInt(SimTuning.glassThermalShatter) == 0)) {
        grid[idx] = El.sand;
        life[idx] = 0;
        velY[idx] = 0;
        markProcessed(idx);
        queueReactionFlash(x, y, 200, 220, 255, 6);
        return;
      }
    }

    // Glass shatters when adjacent to explosions (handled by explosion system)
    // Glass melts back to sand when adjacent to lava for extended time
    if (checkAdjacent(x, y, El.lava)) {
      life[idx]++;
      if (life[idx] > SimTuning.glassLavaMeltBase + rng.nextInt(SimTuning.glassLavaMeltVar)) {
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

  /// Granular avalanche: grains on slopes exceeding the angle of repose
  /// slide downhill. Real sand has a critical angle of ~34° (tan ≈ 0.67).
  /// In a cellular automaton, a 1:1 diagonal (45°) exceeds this, so any
  /// grain supported from below with an empty diagonal-below slides.
  ///
  /// Extended slope detection: if the immediate diagonal is blocked but
  /// a step-down exists 2-3 cells laterally, the grain rolls further —
  /// modeling real granular surface flow where grains roll multiple
  /// diameters downhill on steep slopes.
  void _avalancheGranular(int x, int y, int idx) {
    final g = gravityDir;
    final by = y + g;
    if (!inBoundsY(by) || isEmptyOrGas(grid[by * gridW + x])) return;

    final goLeft = rng.nextBool();
    final dir1 = goLeft ? -1 : 1;
    final dir2 = goLeft ? 1 : -1;

    for (int dirI = 0; dirI < 2; dirI++) { final dir = dirI == 0 ? dir1 : dir2;
      final sx = wrapX(x + dir);

      // Standard avalanche: side empty/gas + diagonal-below empty/gas → slide down.
      // Coulomb friction model: grains on a slope only avalanche when the
      // slope exceeds the static friction angle. A 2/3 probability gate
      // produces an effective angle of repose near 34° (real dry sand).
      if (isEmptyOrGas(grid[y * gridW + sx]) &&
          inBoundsY(by) && isEmptyOrGas(grid[by * gridW + sx])) {
        if (rng.nextInt(SimTuning.avalancheStandard) > 0) {
          swap(idx, by * gridW + sx);
          return;
        }
      }

      // Extended slide: side empty/gas + diagonal-below occupied →
      // check 2 cells out for a step-down (models rolling on slope surface).
      // Rarer than standard avalanche due to higher activation energy.
      if (isEmptyOrGas(grid[y * gridW + sx])) {
        final sx2 = wrapX(x + dir * 2);
        // Roll to side if 2-out diagonal-below is empty/gas
        if (inBoundsY(by) && isEmptyOrGas(grid[by * gridW + sx2]) &&
            isEmptyOrGas(grid[y * gridW + sx2])) {
          if (rng.nextInt(SimTuning.avalancheExtended) == 0) {
            swap(idx, y * gridW + sx);
            return;
          }
        }
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
  /// Wraps horizontally for cylinder topology.
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

        final xStart = cx * 16;
        final xEnd = ((cx + 1) * 16).clamp(0, w);

        for (int y = yStart; y < yEnd; y++) {
          final row = y * w;
          for (int x = xStart; x < xEnd; x++) {
            final i = row + x;
            final xl = row + wrapX(x - 1);
            final xr = row + wrapX(x + 1);
            final fv = pf[i];
            if (fv > 2) {
              final spread = fv >> 3;
              if (spread > 0) {
                if (g[xl] == El.empty) pf[xl] = (pf[xl] + spread).clamp(0, 255);
                if (g[xr] == El.empty) pf[xr] = (pf[xr] + spread).clamp(0, 255);
                if (g[i - w] == El.empty) pf[i - w] = (pf[i - w] + spread).clamp(0, 255);
                if (g[i + w] == El.empty) pf[i + w] = (pf[i + w] + spread).clamp(0, 255);
              }
            }
            final hv = ph[i];
            if (hv > 2) {
              final spread = hv >> 3;
              if (spread > 0) {
                if (g[xl] == El.empty) ph[xl] = (ph[xl] + spread).clamp(0, 255);
                if (g[xr] == El.empty) ph[xr] = (ph[xr] + spread).clamp(0, 255);
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

  @pragma('vm:prefer-inline')
  bool _isUnderground(int x, int y) {
    final g = gravityDir;
    final aboveY = y - g;
    if (!inBoundsY(aboveY)) return false;
    final above = grid[aboveY * gridW + x];
    return above == El.dirt || above == El.mud || above == El.stone ||
        above == El.sand || above == El.ant;
  }

  @pragma('vm:prefer-inline')
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

    final g = gravityDir;
    final by = y + g;
    final uy = y - g;
    final homeX = life[idx];
    final w = gridW;

    // GRAVITY FIRST — always runs, even on odd frames.
    // Ants must fall when unsupported, and fall through other ants.
    if (inBoundsY(by)) {
      final belowEl = grid[by * w + x];
      if (belowEl == El.empty) {
        swap(idx, by * w + x); return;
      }
      // Fall through other ants (prevents blob floating)
      if (belowEl == El.ant && rng.nextInt(SimTuning.antBlobDisperse) == 0) {
        swap(idx, by * w + x); return;
      }
    }

    // Skip complex behavior on odd frames (gravity still ran above)
    if (!isCarrying && frameCount % 2 != 0) return;

    // Acid dissolves ants
    if (checkAdjacent(x, y, El.acid)) {
      grid[idx] = El.empty; life[idx] = 0; velY[idx] = 0; return;
    }

    // Toxic gas: chlorine/fluorine kill on prolonged exposure, trigger flee
    if (checkAdjacentAny2(x, y, El.chlorine, El.fluorine)) {
      _fireAlarm(x, y); // Reuse alarm to scatter nearby ants
      // Stochastic death from toxic exposure (1/30 chance per tick)
      if (rng.nextInt(30) == 0) {
        grid[idx] = El.empty; life[idx] = 0; velY[idx] = 0; return;
      }
      // Try to flee to a non-toxic cell
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx2 = wrapX(x + dx); final ny2 = y + dy;
          if (!inBoundsY(ny2)) continue;
          final ni = ny2 * w + nx2;
          if (grid[ni] == El.empty) {
            swap(idx, ni); return;
          }
        }
      }
    }

    // Fire/lava: flee and alarm
    if (senseDanger(x, y, 1)) {
      final hasFire = checkAdjacentAny2(x, y, El.fire, El.lava);
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
      for (int dirI = 0; dirI < 2; dirI++) { final dir = dirI == 0 ? 1 : -1;
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

    // Density dispersal: when too many ants are packed together, push outward
    if (frameCount % 4 == 0) {
      final nearbyAnts = countNearby(x, y, 2, El.ant);
      if (nearbyAnts >= 6) {
        // Crowded — try to move to any adjacent empty cell
        final disperseDir = rng.nextBool() ? 1 : -1;
        final dx2 = wrapX(x + disperseDir);
        if (grid[y * w + dx2] == El.empty) {
          velX[idx] = disperseDir; swap(idx, y * w + dx2); return;
        }
        if (inBoundsY(uy) && grid[uy * w + dx2] == El.empty) {
          velX[idx] = disperseDir; swap(idx, uy * w + dx2); return;
        }
        // Swap with a neighbor ant to churn the blob
        if (grid[y * w + dx2] == El.ant) {
          velX[idx] = disperseDir; swap(idx, y * w + dx2); return;
        }
      }
    }

    // -- NEAT neural integration: if a colony manages this ant, use brain ---
    if (creatureCallback != null && frameCount % 3 == 0) {
      final decision = creatureCallback!(x, y);
      if (decision.isNotEmpty) {
        final ndx = (decision['dx'] ?? 0.0).toInt().clamp(-1, 1);
        final ndy = (decision['dy'] ?? 0.0).toInt().clamp(-1, 1);
        final wantsPickup = (decision['pickup'] ?? 0.0) > 0.5;
        final wantsDrop = (decision['drop'] ?? 0.0) > 0.5;
        final pheromone = decision['pheromone'] ?? 0.0;

        // Neural-driven movement (with random-walk fallback for untrained brains)
        int mdx = ndx;
        int mdy = ndy;
        if (mdx == 0 && mdy == 0) {
          // Random walk: untrained NEAT outputs near zero, so wander randomly.
          mdx = rng.nextBool() ? 1 : -1;
          mdy = rng.nextInt(3) - 1; // -1, 0, or 1
        }
        bool neuralMoved = false;
        {
          final nx = wrapX(x + mdx);
          final ny = y + mdy;
          if (inBoundsY(ny)) {
            final ti = ny * w + nx;
            final targetEl = grid[ti];
            if (targetEl == El.empty) {
              velX[idx] = mdx;
              swap(idx, ti);
              neuralMoved = true;
            } else if (targetEl == El.ant && rng.nextInt(2) == 0) {
              // Ant-ant swap: ants can walk past each other
              velX[idx] = mdx;
              swap(idx, ti);
              neuralMoved = true;
            } else if (targetEl == El.dirt && rng.nextInt(3) == 0) {
              // Neural-driven digging
              grid[ti] = El.empty;
              life[ti] = 0;
              markDirty(nx, ny);
              swap(idx, ti);
              velY[idx] = antCarrierState;
              neuralMoved = true;
            } else if (mdx != 0 && grid[y * w + nx] == El.empty) {
              velX[idx] = mdx;
              swap(idx, y * w + nx);
              neuralMoved = true;
            } else if (mdx != 0) {
              final hni = y * w + nx;
              if (grid[hni] == El.ant && rng.nextInt(2) == 0) {
                velX[idx] = mdx;
                swap(idx, hni);
                neuralMoved = true;
              } else {
                // Try climbing over 1-cell obstacle
                final climbY = y - g;
                if (inBoundsY(climbY) && grid[climbY * w + nx] == El.empty) {
                  velX[idx] = mdx;
                  swap(idx, climbY * w + nx);
                  neuralMoved = true;
                }
              }
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

        // If neural movement succeeded, skip hardcoded path.
        // If it failed, fall through to let the hardcoded state machine try.
        if (neuralMoved) return;
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
      for (int sdI = 0; sdI < 2; sdI++) { final sd = sdI == 0 ? dir : -dir;
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
      for (int sdI = 0; sdI < 2; sdI++) { final sd = sdI == 0 ? dir : -dir;
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

    if (!foundTarget && rng.nextInt(SimTuning.antExplorerWander) == 0) velY[idx] = antExplorerState;

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

    if (!checkAdjacentAny2(x, y, El.dirt, El.sand)) {
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
      for (int dxI = 0; dxI < 2; dxI++) { final dx = dxI == 0 ? 1 : -1;
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
    final ni = y * w + nx;

    if (grid[ni] == El.empty) {
      velX[idx] = moveDir; swap(idx, ni); return;
    }

    // Ant-ant swap: ants walk past each other (50% chance to prevent jitter)
    if (grid[ni] == El.ant && (flags[ni] & _antBridgeFlag) == 0 && rng.nextInt(2) == 0) {
      velX[idx] = moveDir; swap(idx, ni); return;
    }

    if (inBoundsY(uy) && grid[uy * w + nx] == El.empty) {
      velX[idx] = moveDir; swap(idx, uy * w + nx); return;
    }

    // Bridge over water
    if (grid[ni] == El.water) {
      bool landAhead = false;
      for (int d = 2; d <= 4; d++) {
        final fx = wrapX(x + moveDir * d);
        final fe = grid[y * w + fx];
        if (fe != El.water && fe != El.empty) { landAhead = true; break; }
        if (fe == El.empty) { landAhead = true; break; }
      }
      if (landAhead && rng.nextInt(3) == 0) {
        grid[ni] = El.ant; life[ni] = life[idx]; velX[ni] = moveDir;
        velY[ni] = antExplorerState;
        grid[idx] = El.empty; life[idx] = 0; velX[idx] = 0; velY[idx] = 0;
        markProcessed(ni); markProcessed(idx);
        flags[ni] = flags[ni] | _antBridgeFlag;
        return;
      }
    }

    // Walk on bridge ants
    if (grid[ni] == El.ant &&
        (flags[ni] & _antBridgeFlag) != 0) {
      if (inBoundsY(uy) && grid[uy * w + nx] == El.empty) {
        velX[idx] = moveDir; swap(idx, uy * w + nx); return;
      }
    }

    if (inBoundsY(uy) && grid[uy * w + x] == El.empty) {
      if (grid[ni] != El.empty) {
        swap(idx, uy * w + x); return;
      }
    }

    // Snow slows ants
    if (grid[ni] == El.snow) {
      if (rng.nextInt(3) == 0) { velX[idx] = moveDir; return; }
    }

    velX[idx] = -moveDir;
    if (rng.nextInt(6) == 0) velX[idx] = rng.nextBool() ? 1 : -1;
  }

  // =========================================================================
  // Oxygen — invisible gas, consumed by fire, produced by plants, diffuses
  // =========================================================================
  void simOxygen(int x, int y, int idx) {
    if (checkTemperatureReaction(x, y, idx, El.oxygen)) return;
    // Fire consumes oxygen
    if (checkAdjacent(x, y, El.fire)) {
      grid[idx] = El.empty; life[idx] = 0; markDirty(x, y); return;
    }
    // Dissolve into water slowly
    if (checkAdjacent(x, y, El.water) && rng.nextInt(30) == 0) {
      grid[idx] = El.empty; life[idx] = 0; markDirty(x, y); return;
    }
    // Gas physics: rises through empty or lighter elements, diffuses laterally
    if (tryBuoyancy(x, y, idx, El.oxygen)) return;
    final uy = y - gravityDir;
    if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
      swap(idx, uy * gridW + x); return;
    }
    // Lateral drift
    if (rng.nextInt(2) == 0) {
      final dir = rng.nextBool() ? 1 : -1;
      final nx = wrapX(x + dir);
      if (grid[y * gridW + nx] == El.empty) { swap(idx, y * gridW + nx); }
    }
  }

  // =========================================================================
  // CO2 — heavy gas, sinks, pools in depressions, absorbed by plants
  // =========================================================================
  void simCO2(int x, int y, int idx) {
    if (checkTemperatureReaction(x, y, idx, El.co2)) return;
    // CO2 dissolves in adjacent water (forms carbonic acid, lowers pH)
    if (checkAdjacent(x, y, El.water) && rng.nextInt(8) == 0) {
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx); final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final ni = ny * gridW + nx;
          if (grid[ni] == El.water && concentration[ni] < 200) {
            dissolvedType[ni] = El.co2;
            final newConc = concentration[ni] + 30;
            concentration[ni] = newConc < 200 ? newConc : 200;
            grid[idx] = El.empty; life[idx] = 0; markDirty(x, y);
            markDirty(nx, ny);
            return;
          }
        }
      }
    }
    // Plants absorb CO2
    if (checkAdjacent(x, y, El.plant) && rng.nextInt(20) == 0) {
      grid[idx] = El.empty; life[idx] = 0; markDirty(x, y); return;
    }
    if (checkAdjacent(x, y, El.algae) && rng.nextInt(15) == 0) {
      grid[idx] = El.empty; life[idx] = 0; markDirty(x, y); return;
    }
    // Heavy gas: sinks slowly, spreads laterally
    final g = gravityDir;
    final w = gridW;
    final by = y + g;
    // Sink into empty or displace lighter gases
    if (inBoundsY(by)) {
      final bi = by * w + x;
      final bel = grid[bi];
      if (bel == El.empty) { swap(idx, bi); return; }
      if (bel == El.oxygen || bel == El.steam || bel == El.smoke) {
        swap(idx, bi); return; // CO2 is heavier than these gases
      }
    }
    // Lateral spread
    if (rng.nextInt(3) == 0) {
      final dir = rng.nextBool() ? 1 : -1;
      final nx = wrapX(x + dir);
      final ni = y * w + nx;
      if (grid[ni] == El.empty) { swap(idx, ni); }
    }
  }

  // =========================================================================
  // Fungus — living decomposer, grows on organic matter, needs moisture
  // =========================================================================
  void simFungus(int x, int y, int idx) {
    if (checkTemperatureReaction(x, y, idx, El.fungus)) return;
    final w = gridW;
    // Gravity: fungus falls if not attached to organic matter or solid surface
    if (!checkAdjacentAnyOf(x, y, fungusAttachSet)) {
      final by = y + gravityDir;
      if (inBoundsY(by) && grid[by * w + x] == El.empty) {
        swap(idx, by * w + x); return;
      }
    }
    // Check moisture
    final hasMoisture = checkAdjacent(x, y, El.water) ||
        (checkAdjacent(x, y, El.dirt) && life[idx] > 0);
    if (!hasMoisture) {
      life[idx] = (life[idx] > 0) ? life[idx] - 1 : 0;
      if (life[idx] <= 0 && rng.nextInt(SimTuning.fungusDeathToCompost) == 0) {
        grid[idx] = El.compost; markDirty(x, y); return;
      }
    } else {
      life[idx] = (life[idx] < 80) ? life[idx] + 1 : 80;
    }
    // Bright light inhibits fungal growth
    final fungLum = luminance[idx];
    if (fungLum > 30 && frameCount % 10 == 0) {
      life[idx] = (life[idx] > 0) ? life[idx] - 1 : 0;
    }
    // Growth: spread to adjacent organic matter (only in darkness)
    final fungGrowMod = fungLum > 30 ? 60 : 20; // bright = 3x slower
    if (frameCount % fungGrowMod == 0) {
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx); final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final ni = ny * w + nx;
          final ne = grid[ni];
          if (ne == El.ash && rng.nextInt(SimTuning.fungusAshDecompose) == 0) {
            grid[ni] = El.compost; markDirty(nx, ny);
          } else if (ne == El.wood && rng.nextInt(SimTuning.fungusWoodRot) == 0) {
            grid[ni] = El.fungus; life[ni] = 1; markDirty(nx, ny);
          } else if (ne == El.dirt && rng.nextInt(SimTuning.fungusDirtSpread) == 0 &&
              countNearby(x, y, 2, El.fungus) < 5) {
            grid[ni] = El.fungus; life[ni] = 1; markDirty(nx, ny);
          }
        }
      }
    }
    // Sporulation: mature fungus releases spores
    if (life[idx] > 60 && rng.nextInt(SimTuning.fungusSporulate) == 0) {
      final uy = y - gravityDir;
      if (inBoundsY(uy) && grid[uy * w + x] == El.empty) {
        grid[uy * w + x] = El.spore; life[uy * w + x] = 0;
        markDirty(x, uy);
      }
    }
    // Produce methane during decomposition
    if (rng.nextInt(SimTuning.fungusMethane) == 0 && life[idx] > 30) {
      final uy = y - gravityDir;
      if (inBoundsY(uy) && grid[uy * w + x] == El.empty) {
        grid[uy * w + x] = El.methane; markDirty(x, uy);
      }
    }
  }

  // =========================================================================
  // Spore — ultra-light wind-carried particle, germinates on moist surfaces
  // =========================================================================
  void simSpore(int x, int y, int idx) {
    life[idx]++;
    if (life[idx] > 120) {
      grid[idx] = El.empty; life[idx] = 0; markDirty(x, y); return;
    }
    // Check landing substrate
    final w = gridW;
    final by = y + gravityDir;
    if (inBoundsY(by)) {
      final below = grid[by * w + x];
      if ((below == El.dirt || below == El.compost || below == El.ash || below == El.mud) &&
          checkAdjacent(x, y, El.water)) {
        grid[idx] = El.fungus; life[idx] = 1; markDirty(x, y); return;
      }
    }
    // Ultra-slow fall with wind drift (powder physics, like ash)
    final fallY = y + gravityDir;
    if (inBoundsY(fallY) && grid[fallY * w + x] == El.empty && rng.nextInt(SimTuning.sporeFallRate) == 0) {
      swap(idx, fallY * w + x); return;
    }
    // Lateral drift (wind-sensitive) — use local wind field
    if (rng.nextInt(SimTuning.sporeDriftRate) == 0) {
      final localWind = windX2[idx];
      final dir = localWind != 0 ? (localWind > 0 ? 1 : -1) : (rng.nextBool() ? 1 : -1);
      final nx = wrapX(x + dir);
      if (grid[y * w + nx] == El.empty) { swap(idx, y * w + nx); }
    }
  }

  // =========================================================================
  // Charcoal — energy-dense fuel, burns hotter and longer than wood
  // =========================================================================
  void simCharcoal(int x, int y, int idx) {
    if (checkTemperatureReaction(x, y, idx, El.charcoal)) return;
    // Ignite from adjacent fire/lava or high temperature
    if (checkAdjacentAny2(x, y, El.fire, El.lava) ||
        temperature[idx] > 200) {
      grid[idx] = El.fire;
      life[idx] = 0; // Fire will burn extra long from charcoal heat
      temperature[idx] = 240; // Burns hotter than wood
      markDirty(x, y);
      return;
    }
    if (checkAdjacent(x, y, El.lightning)) {
      grid[idx] = El.fire; temperature[idx] = 240;
      markDirty(x, y); return;
    }
    fallGranular(x, y, idx, El.charcoal);
  }

  // =========================================================================
  // Compost — rich decomposed matter, super-fertilizer for plants
  // =========================================================================
  void simCompost(int x, int y, int idx) {
    if (checkTemperatureReaction(x, y, idx, El.compost)) return;
    // Dry out without moisture
    if (frameCount % 10 == 0) {
      if (!checkAdjacent(x, y, El.water) && life[idx] > 0) {
        life[idx]--;
      } else if (checkAdjacent(x, y, El.water)) {
        life[idx] = (life[idx] < 100) ? life[idx] + 1 : 100;
      }
    }
    // Fully dried: become dirt
    if (life[idx] <= 0 && rng.nextInt(SimTuning.compostDryToDirt) == 0) {
      grid[idx] = El.dirt; markDirty(x, y); return;
    }
    // Nutrient diffusion to adjacent dirt
    if (rng.nextInt(SimTuning.compostNutrient) == 0) {
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx); final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final ni = ny * gridW + nx;
          if (grid[ni] == El.dirt && life[ni] < 50) {
            life[ni] += 5; markDirty(nx, ny); break;
          }
        }
      }
    }
    // Produce methane during active decomposition
    if (life[idx] > 50 && rng.nextInt(SimTuning.compostMethane) == 0) {
      final uy = y - gravityDir;
      if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
        grid[uy * gridW + x] = El.methane; markDirty(x, uy);
      }
    }
    fallGranular(x, y, idx, El.compost);
  }

  // =========================================================================
  // Rust — corroded metal, weak solid that crumbles under weight
  // =========================================================================
  void simRust(int x, int y, int idx) {
    // Acid dissolves rust easily
    if (checkAdjacent(x, y, El.acid)) {
      grid[idx] = El.empty; life[idx] = 0;
      removeOneAdjacent(x, y, El.acid);
      markDirty(x, y); return;
    }
    // Crumble under heavy weight
    if (gravityDir == 1 && y > 0) {
      final above = grid[(y - 1) * gridW + x];
      if (above != El.empty && elementDensity[above] > 180 && rng.nextInt(SimTuning.rustCrumble) == 0) {
        grid[idx] = El.dirt; markDirty(x, y); return;
      }
    }
    // Rust doesn't move — it's a weak solid
  }

  // =========================================================================
  // Methane — explosive gas from decomposition
  // =========================================================================
  void simMethane(int x, int y, int idx) {
    // Explodes on contact with fire, lava, or lightning
    if (checkAdjacentAny3(x, y, El.fire, El.lava, El.lightning)) {
      grid[idx] = El.fire; life[idx] = 0;
      temperature[idx] = 250;
      markDirty(x, y);
      // Chain ignition: nearby methane also ignites
      final w = gridW;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx); final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final ni = ny * w + nx;
          if (grid[ni] == El.methane) {
            grid[ni] = El.fire; life[ni] = 0; temperature[ni] = 240;
            markDirty(nx, ny);
          }
        }
      }
      pendingExplosions.add(Explosion(x, y, 3));
      return;
    }
    // Gas physics: rises (lighter than CO2, heavier than steam)
    final uy = y - gravityDir;
    if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
      swap(idx, uy * gridW + x); return;
    }
    if (rng.nextInt(SimTuning.methaneLateralDrift) == 0) {
      final dir = rng.nextBool() ? 1 : -1;
      final nx = wrapX(x + dir);
      if (grid[y * gridW + nx] == El.empty) { swap(idx, y * gridW + nx); }
    }
  }

  // =========================================================================
  // Salt — soluble crystal, dissolves in water, de-ices, kills plants
  // =========================================================================
  void simSalt(int x, int y, int idx) {
    if (checkTemperatureReaction(x, y, idx, El.salt)) return;
    // Dissolve in water: set dissolvedType + concentration on the water cell
    if (checkAdjacent(x, y, El.water) && rng.nextInt(SimTuning.saltDissolveRate) == 0) {
      // Find the adjacent water cell to dissolve into
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx); final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final ni = ny * gridW + nx;
          if (grid[ni] == El.water && concentration[ni] < 200) {
            // Dissolve: salt enters solution
            dissolvedType[ni] = El.salt;
            final newConc = concentration[ni] + 50;
            concentration[ni] = newConc < 200 ? newConc : 200;
            grid[idx] = El.empty; life[idx] = 0; markDirty(x, y);
            markDirty(nx, ny);
            return;
          }
        }
      }
      // All adjacent water is saturated — don't dissolve
    }
    // De-icing: salt melts adjacent ice even at low temperatures
    if (checkAdjacent(x, y, El.ice) && rng.nextInt(SimTuning.saltDeiceRate) == 0) {
      removeOneAdjacent(x, y, El.ice);
      // Place water where ice was
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          final nx = wrapX(x + dx); final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final ni = ny * gridW + nx;
          if (grid[ni] == El.empty) {
            grid[ni] = El.water; markDirty(nx, ny); break;
          }
        }
      }
    }
    // Salt toxicity: kills adjacent plants slowly
    if (checkAdjacent(x, y, El.plant) && rng.nextInt(SimTuning.saltPlantKill) == 0) {
      removeOneAdjacent(x, y, El.plant);
    }
    fallGranular(x, y, idx, El.salt);
  }

  // =========================================================================
  // Clay — hardens into ceramic (glass) when heated
  // =========================================================================
  void simClay(int x, int y, int idx) {
    if (checkTemperatureReaction(x, y, idx, El.clay)) return;
    // Absorb moisture slowly
    if (checkAdjacent(x, y, El.water) && life[idx] < 50) {
      life[idx]++;
    }
    fallGranular(x, y, idx, El.clay);
  }

  // =========================================================================
  // Algae — aquatic plant, grows in water, produces oxygen bubbles
  // =========================================================================
  void simAlgae(int x, int y, int idx) {
    final w = gridW;
    // Gravity: algae falls when not in/adjacent to water
    if (!checkAdjacent(x, y, El.water)) {
      final by = y + gravityDir;
      if (inBoundsY(by) && grid[by * w + x] == El.empty) {
        swap(idx, by * w + x); return;
      }
    }
    // Must be adjacent to water to survive
    if (!checkAdjacent(x, y, El.water)) {
      life[idx]++;
      if (life[idx] > 30) {
        grid[idx] = El.empty; life[idx] = 0; markDirty(x, y); return;
      }
    } else {
      life[idx] = 0;
    }
    // Growth: spread to adjacent water cells
    if (frameCount % 30 == 0 && rng.nextInt(SimTuning.algaeGrowRate) == 0) {
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx); final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final ni = ny * w + nx;
          if (grid[ni] == El.water && countNearby(x, y, 2, El.algae) < 8) {
            grid[ni] = El.algae; life[ni] = 0; markDirty(nx, ny); break;
          }
        }
      }
    }
    // Oxygen production (as bubbles)
    if (rng.nextInt(SimTuning.algaeO2Rate) == 0) {
      final uy = y - gravityDir;
      if (inBoundsY(uy) && (grid[uy * w + x] == El.water || grid[uy * w + x] == El.empty)) {
        grid[uy * w + x] = El.oxygen; markDirty(x, uy);
      }
    }
    // Absorb CO2
    if (checkAdjacent(x, y, El.co2) && rng.nextInt(SimTuning.algaeCO2Absorb) == 0) {
      removeOneAdjacent(x, y, El.co2);
    }
    // Overpopulation die-off (algae bloom)
    if (countNearby(x, y, 3, El.algae) > SimTuning.algaeBloomThreshold && rng.nextInt(SimTuning.algaeBloomDieoff) == 0) {
      grid[idx] = El.compost; markDirty(x, y); return;
    }
  }

  // =========================================================================
  // Seaweed — aquatic plant, grows in water, fish food, evolves toxicity
  // =========================================================================
  void simSeaweed(int x, int y, int idx) {
    final w = gridW;
    // Must be in or adjacent to water
    if (!checkAdjacent(x, y, El.water) && grid[idx] != El.water) {
      life[idx]++;
      if (life[idx] > 20) {
        grid[idx] = El.empty; life[idx] = 0; markDirty(x, y); return;
      }
    } else {
      if (life[idx] > 0) life[idx]--;
    }

    // Fire/lava destroys seaweed
    if (checkAdjacentAny2(x, y, El.fire, El.lava)) {
      grid[idx] = El.ash; life[idx] = 0; markDirty(x, y); return;
    }

    // Neural colony decisions
    final registry = plantColonies;
    PlantColony? colony;
    double growUpBias = 0.6;
    double growLateral = 0.0;
    double branchProb = 0.03;
    double seedProd = 0.002;
    double toxinProd = 0.0;

    if (registry != null) {
      colony = registry.colonyForCell(idx);
      if (colony != null) {
        final inputs = registry.gatherInputs(this, x, y, idx);
        final out = colony.decide(
          inputs[0], inputs[1], inputs[2], inputs[3],
          inputs[4], inputs[5], inputs[6], inputs[7],
        );
        growUpBias = (out[outGrowUp] + 1.0) * 0.5; // -1..1 -> 0..1
        growLateral = out[outGrowLateral];
        branchProb = (out[outBranch] + 1.0) * 0.05; // 0..0.1
        seedProd = (out[outSeedProduction] + 1.0) * 0.005;
        toxinProd = (out[outToxin] + 1.0) * 0.5;
        // Drift colony toxin level
        colony.toxinLevel = (colony.toxinLevel * 0.99 + toxinProd * 0.01).clamp(0.0, 1.0);
      }
    }

    // Growth: spread into adjacent water cells
    final growRate = plantGrowRate[plantSeaweed];
    if (frameCount % growRate == 0) {
      final curSize = velY[idx].clamp(0, 127).toInt();
      if (curSize < plantMaxH[plantSeaweed]) {
        // Determine growth direction from neural output
        final gy = growUpBias > 0.5 ? y - gravityDir : y + gravityDir;
        final gx = growLateral > 0.3 ? wrapX(x + 1) :
                   growLateral < -0.3 ? wrapX(x - 1) : x;

        // Try primary direction
        if (inBoundsY(gy)) {
          final ni = gy * w + gx;
          if (grid[ni] == El.water) {
            grid[ni] = El.seaweed; life[ni] = 0;
            velY[ni] = (curSize + 1);
            markProcessed(ni);
            markDirty(gx, gy);
            velY[idx] = (curSize + 1);
            if (colony != null && registry != null) {
              registry.addCell(colony, ni);
            }
          }
        }

        // Branching
        if (rng.nextDouble() < branchProb && curSize > 3) {
          final side = rng.nextBool() ? 1 : -1;
          final bx = wrapX(x + side);
          final bi = y * w + bx;
          if (grid[bi] == El.water) {
            grid[bi] = El.seaweed; life[bi] = 0;
            velY[bi] = (curSize);
            markProcessed(bi);
            markDirty(bx, y);
            if (colony != null && registry != null) {
              registry.addCell(colony, bi);
            }
          }
        }
      }
    }

    // Oxygen production
    if (rng.nextInt(SimTuning.seaweedO2Rate) == 0) {
      final uy = y - gravityDir;
      if (inBoundsY(uy) && (grid[uy * w + x] == El.water || grid[uy * w + x] == El.empty)) {
        grid[uy * w + x] = El.oxygen; markDirty(x, uy);
        if (colony != null) colony.oxygenProduced++;
      }
    }

    // CO2 absorption
    if (checkAdjacent(x, y, El.co2) && rng.nextInt(SimTuning.seaweedCO2Absorb) == 0) {
      removeOneAdjacent(x, y, El.co2);
    }

    // Seed production (spores into water)
    if (rng.nextDouble() < seedProd && velY[idx] > 8) {
      for (int dy2 = -1; dy2 <= 1; dy2++) {
        for (int dx2 = -1; dx2 <= 1; dx2++) {
          if (dx2 == 0 && dy2 == 0) continue;
          final sx = wrapX(x + dx2); final sy = y + dy2;
          if (!inBoundsY(sy)) continue;
          final si = sy * w + sx;
          if (grid[si] == El.water) {
            grid[si] = El.seed; life[si] = 0;
            velX[si] = plantSeaweed;
            markDirty(sx, sy);
            if (colony != null) colony.seedsProduced++;
            return;
          }
        }
      }
    }

    // Overpopulation die-off
    if (countNearby(x, y, 3, El.seaweed) > SimTuning.seaweedBloomThreshold && rng.nextInt(SimTuning.seaweedBloomDieoff) == 0) {
      grid[idx] = El.compost; markDirty(x, y);
      if (registry != null) registry.removeCell(idx);
    }
  }

  // =========================================================================
  // Moss — surface plant, grows on rock/stone, minimal light, first colonizer
  // =========================================================================
  void simMoss(int x, int y, int idx) {
    final w = gridW;

    // Must be adjacent to a solid surface (stone, wood, dirt, clay)
    bool onSurface = false;
    for (int dy2 = -1; dy2 <= 1; dy2++) {
      for (int dx2 = -1; dx2 <= 1; dx2++) {
        if (dx2 == 0 && dy2 == 0) continue;
        final nx = wrapX(x + dx2); final ny = y + dy2;
        if (!inBoundsY(ny)) continue;
        final el = grid[ny * w + nx];
        if (el == El.stone || el == El.wood || el == El.dirt || el == El.clay) {
          onSurface = true; break;
        }
      }
      if (onSurface) break;
    }

    if (!onSurface) {
      // Fall when not attached to surface
      fallSolid(x, y, idx, El.moss);
      life[idx]++;
      if (life[idx] > 40) {
        grid[idx] = El.empty; life[idx] = 0; markDirty(x, y); return;
      }
    } else {
      if (life[idx] > 0) life[idx]--;
    }

    // Fire/lava
    if (checkAdjacentAny2(x, y, El.fire, El.lava)) {
      grid[idx] = El.fire; life[idx] = 0; markProcessed(idx); return;
    }

    // Moisture absorption from nearby water
    if (checkAdjacent(x, y, El.water) && frameCount % 10 == 0) {
      moisture[idx] = (moisture[idx] + 5).clamp(0, 255);
    }

    // Neural colony decisions
    final registry = plantColonies;
    double spreadProb = 0.005;

    if (registry != null) {
      final colony = registry.colonyForCell(idx);
      if (colony != null) {
        final inputs = registry.gatherInputs(this, x, y, idx);
        final out = colony.decide(
          inputs[0], inputs[1], inputs[2], inputs[3],
          inputs[4], inputs[5], inputs[6], inputs[7],
        );
        spreadProb = (out[outBranch] + 1.0) * 0.01; // 0..0.02
      }
    }

    // Slow growth along surfaces
    final growRate = plantGrowRate[plantMoss];
    if (frameCount % growRate == 0 && rng.nextDouble() < spreadProb) {
      for (int dy2 = -1; dy2 <= 1; dy2++) {
        for (int dx2 = -1; dx2 <= 1; dx2++) {
          if (dx2 == 0 && dy2 == 0) continue;
          final nx = wrapX(x + dx2); final ny = y + dy2;
          if (!inBoundsY(ny)) continue;
          final ni = ny * w + nx;
          if (grid[ni] != El.empty) continue;
          // Check that target is also adjacent to a solid
          bool targetOnSurface = false;
          for (int sy = -1; sy <= 1; sy++) {
            for (int sx = -1; sx <= 1; sx++) {
              if (sx == 0 && sy == 0) continue;
              final snx = wrapX(nx + sx); final sny = ny + sy;
              if (!inBoundsY(sny)) continue;
              final sel = grid[sny * w + snx];
              if (sel == El.stone || sel == El.wood || sel == El.dirt || sel == El.clay) {
                targetOnSurface = true; break;
              }
            }
            if (targetOnSurface) break;
          }
          if (targetOnSurface && countNearby(nx, ny, 2, El.moss) < 5) {
            grid[ni] = El.moss; life[ni] = 0;
            markProcessed(ni); markDirty(nx, ny);
            if (registry != null) {
              final colony = registry.colonyForCell(idx);
              if (colony != null) registry.addCell(colony, ni);
            }
            return;
          }
        }
      }
    }

    // Oxygen production (slower than plants, even in darkness)
    if (rng.nextInt(SimTuning.mossO2Rate) == 0) {
      final uy = y - gravityDir;
      if (inBoundsY(uy) && grid[uy * w + x] == El.empty) {
        grid[uy * w + x] = El.oxygen; markDirty(x, uy);
      }
    }

    // CO2 absorption
    if (checkAdjacent(x, y, El.co2) && rng.nextInt(SimTuning.mossCO2Absorb) == 0) {
      removeOneAdjacent(x, y, El.co2);
    }
  }

  // =========================================================================
  // Vine (neural) — climbing plant, grows along walls/ceilings, hangs down
  // =========================================================================
  void simNeuralVine(int x, int y, int idx) {
    final w = gridW;

    // Gravity: vine falls if not attached to any surface or other plant
    final hasSupport = checkAdjacentAnyOf(x, y, plantSupportSet);
    if (!hasSupport) {
      final by = y + gravityDir;
      if (inBoundsY(by) && grid[by * w + x] == El.empty) {
        swap(idx, by * w + x); return;
      }
    }

    // Fire/lava/acid
    if (checkAdjacentAny2(x, y, El.fire, El.lava)) {
      grid[idx] = El.fire; life[idx] = 0; markProcessed(idx); return;
    }
    if (checkAdjacent(x, y, El.acid) && rng.nextInt(SimTuning.vineAcidDamage) == 0) {
      grid[idx] = El.empty; life[idx] = 0; markProcessed(idx); return;
    }

    // Hydration
    if (frameCount % 8 == 0) {
      if (checkAdjacent(x, y, El.water) || moisture[idx] > 50) {
        life[idx] = (life[idx] + 1).clamp(0, 100);
      } else {
        life[idx] = (life[idx] - 1).clamp(0, 100);
      }
    }

    // Death from dehydration
    if (life[idx] <= 0) {
      grid[idx] = El.ash; life[idx] = 0;
      final registry = plantColonies;
      if (registry != null) registry.removeCell(idx);
      markDirty(x, y); return;
    }

    // Neural colony decisions
    final registry = plantColonies;
    double growUp = 0.5;
    double growLateral = 0.0;
    double branchProb = 0.02;

    if (registry != null) {
      final colony = registry.colonyForCell(idx);
      if (colony != null) {
        final inputs = registry.gatherInputs(this, x, y, idx);
        final out = colony.decide(
          inputs[0], inputs[1], inputs[2], inputs[3],
          inputs[4], inputs[5], inputs[6], inputs[7],
        );
        growUp = (out[outGrowUp] + 1.0) * 0.5;
        growLateral = out[outGrowLateral];
        branchProb = (out[outBranch] + 1.0) * 0.04;
      }
    }

    // Growth along surfaces
    final growRate = plantGrowRate[plantNeuralVine];
    final curSize = velY[idx].clamp(0, 127).toInt();
    if (frameCount % growRate == 0 && curSize < plantMaxH[plantNeuralVine]) {
      // Build list of valid growth directions near a solid surface
      final directions = <List<int>>[];
      final preferUp = growUp > 0.5;
      final preferDir = growLateral > 0.3 ? 1 : growLateral < -0.3 ? -1 : 0;

      // Prioritize neural-preferred directions
      final allDirs = preferUp
          ? [[-1, -gravityDir], [1, -gravityDir], [0, -gravityDir], [-1, 0], [1, 0], [0, gravityDir]]
          : [[0, gravityDir], [-1, gravityDir], [1, gravityDir], [-1, 0], [1, 0], [0, -gravityDir]];

      for (final d in allDirs) {
        final nx = wrapX(x + d[0]); final ny = y + d[1];
        if (!inBoundsY(ny)) continue;
        if (grid[ny * w + nx] != El.empty) continue;
        // Must be near a solid surface
        bool nearSolid = false;
        for (int sy = -1; sy <= 1; sy++) {
          for (int sx = -1; sx <= 1; sx++) {
            if (sx == 0 && sy == 0) continue;
            final snx = wrapX(nx + sx); final sny = ny + sy;
            if (!inBoundsY(sny)) continue;
            final se = grid[sny * w + snx];
            if (se == El.dirt || se == El.stone || se == El.wood ||
                se == El.metal || se == El.clay) {
              nearSolid = true; break;
            }
          }
          if (nearSolid) break;
        }
        if (nearSolid) {
          // Prefer lateral direction matching neural output
          if (preferDir != 0 && d[0] == preferDir) {
            directions.insert(0, d);
          } else {
            directions.add(d);
          }
        }
      }

      if (directions.isNotEmpty) {
        final d = directions[0]; // take best direction
        final nx = wrapX(x + d[0]); final ny = y + d[1];
        final ni = ny * w + nx;
        grid[ni] = El.vine; life[ni] = life[idx];
        velY[ni] = (curSize + 1); markProcessed(ni); markDirty(nx, ny);
        velY[idx] = (curSize + 1);
        if (registry != null) {
          final colony = registry.colonyForCell(idx);
          if (colony != null) registry.addCell(colony, ni);
        }
      }

      // Branching
      if (rng.nextDouble() < branchProb && curSize > 4 && directions.length > 1) {
        final d = directions[rng.nextInt(directions.length)];
        final nx = wrapX(x + d[0]); final ny = y + d[1];
        final ni = ny * w + nx;
        if (grid[ni] == El.empty) {
          grid[ni] = El.vine; life[ni] = life[idx];
          velY[ni] = (curSize); markProcessed(ni); markDirty(nx, ny);
          if (registry != null) {
            final colony = registry.colonyForCell(idx);
            if (colony != null) registry.addCell(colony, ni);
          }
        }
      }
    }

    // Photosynthesis
    if (luminance[idx] > 30 && frameCount % 20 == 0 && rng.nextInt(SimTuning.vineO2Rate) == 0) {
      final uy = y - gravityDir;
      if (inBoundsY(uy) && grid[uy * w + x] == El.empty) {
        grid[uy * w + x] = El.oxygen; markDirty(x, uy);
      }
    }
  }

  // =========================================================================
  // Flower (neural) — reproducer, produces seeds/pollen, attracts bees
  // =========================================================================
  void simNeuralFlower(int x, int y, int idx) {
    final w = gridW;

    // Gravity: flowers fall if not on soil/dirt/compost/root
    final by = y + gravityDir;
    if (inBoundsY(by)) {
      final below = grid[by * w + x];
      if (below == El.empty) {
        swap(idx, by * w + x); return;
      }
    }

    // Fire/lava
    if (checkAdjacentAny2(x, y, El.fire, El.lava)) {
      grid[idx] = El.fire; life[idx] = 0; markProcessed(idx); return;
    }
    if (checkAdjacent(x, y, El.acid) && rng.nextInt(SimTuning.flowerAcidDamage) == 0) {
      grid[idx] = El.empty; life[idx] = 0; markProcessed(idx); return;
    }

    // Hydration from soil below
    if (frameCount % 6 == 0) {
      bool hasMoisture = false;
      final by = y + gravityDir;
      if (inBoundsY(by)) {
        final bi = by * w + x;
        if (grid[bi] == El.dirt && life[bi] >= 1) hasMoisture = true;
        if (grid[bi] == El.root) hasMoisture = true; // roots supply water
      }
      if (checkAdjacent(x, y, El.water)) hasMoisture = true;
      if (hasMoisture) {
        life[idx] = (life[idx] + 2).clamp(0, 100);
      } else {
        life[idx] = (life[idx] - 1).clamp(0, 100);
      }
    }

    // Death
    if (life[idx] <= 0) {
      grid[idx] = El.ash; life[idx] = 0;
      final registry = plantColonies;
      if (registry != null) registry.removeCell(idx);
      markDirty(x, y); return;
    }

    // Neural colony decisions
    final registry = plantColonies;
    double seedRate = 0.003;
    double resourceAlloc = 0.5;

    if (registry != null) {
      final colony = registry.colonyForCell(idx);
      if (colony != null) {
        final inputs = registry.gatherInputs(this, x, y, idx);
        final out = colony.decide(
          inputs[0], inputs[1], inputs[2], inputs[3],
          inputs[4], inputs[5], inputs[6], inputs[7],
        );
        seedRate = (out[outSeedProduction] + 1.0) * 0.005;
        resourceAlloc = (out[outResourceAlloc] + 1.0) * 0.5;
      }
    }

    // Grow stem upward (small plant)
    final curSize = velY[idx].clamp(0, 127).toInt();
    final growRate = plantGrowRate[plantNeuralFlower];
    if (frameCount % growRate == 0 && curSize < plantMaxH[plantNeuralFlower]) {
      final uy = y - gravityDir;
      if (inBoundsY(uy) && grid[uy * w + x] == El.empty) {
        final ni = uy * w + x;
        grid[ni] = El.flower; life[ni] = life[idx];
        velY[ni] = (curSize + 1); markProcessed(ni); markDirty(x, uy);
        velY[idx] = (curSize + 1);
        if (registry != null) {
          final colony = registry.colonyForCell(idx);
          if (colony != null) registry.addCell(colony, ni);
        }
      }
    }

    // Seed production — neural network controls rate
    if (curSize >= plantMaxH[plantNeuralFlower] - 1 && rng.nextDouble() < seedRate) {
      for (int dy2 = -2; dy2 <= 0; dy2++) {
        for (int dx2 = -1; dx2 <= 1; dx2++) {
          if (dx2 == 0 && dy2 == 0) continue;
          final sx = wrapX(x + dx2); final sy = y + dy2;
          if (!inBoundsY(sy)) continue;
          final si = sy * w + sx;
          if (grid[si] == El.empty) {
            // Wind-assisted seed spread
            final seedX = windForce != 0 && rng.nextBool()
                ? wrapX(sx + windForce.sign) : sx;
            final seedIdx = sy * w + seedX;
            if (grid[seedIdx] == El.empty) {
              grid[seedIdx] = El.seed; life[seedIdx] = 0;
              velX[seedIdx] = plantNeuralFlower;
              markDirty(seedX, sy);
            } else {
              grid[si] = El.seed; life[si] = 0;
              velX[si] = plantNeuralFlower;
              markDirty(sx, sy);
            }
            if (registry != null) {
              final colony = registry.colonyForCell(idx);
              if (colony != null) colony.seedsProduced++;
            }
            return;
          }
        }
      }
    }

    // Photosynthesis
    if (luminance[idx] > 40 && frameCount % 15 == 0 && rng.nextInt(SimTuning.flowerO2Rate) == 0) {
      final uy = y - gravityDir;
      if (inBoundsY(uy) && grid[uy * w + x] == El.empty) {
        grid[uy * w + x] = El.oxygen; markDirty(x, uy);
      }
      if (checkAdjacent(x, y, El.co2)) removeOneAdjacent(x, y, El.co2);
    }

    // Resource allocation: high = grow roots, low = produce more seeds
    if (resourceAlloc > 0.6 && frameCount % 40 == 0 && rng.nextInt(3) == 0) {
      // Try to grow a root below
      final ry = y + gravityDir;
      if (inBoundsY(ry)) {
        final ri = ry * w + x;
        if (grid[ri] == El.dirt) {
          grid[ri] = El.root; life[ri] = life[idx];
          velY[ri] = 1; markProcessed(ri); markDirty(x, ry);
          if (registry != null) {
            final colony = registry.colonyForCell(idx);
            if (colony != null) registry.addCell(colony, ri);
          }
        }
      }
    }
  }

  // =========================================================================
  // Root — underground, grows downward seeking water/nutrients
  // =========================================================================
  void simRoot(int x, int y, int idx) {
    final w = gridW;

    // Fire destroys roots
    if (checkAdjacentAny2(x, y, El.fire, El.lava)) {
      grid[idx] = El.ash; life[idx] = 0; markDirty(x, y);
      final registry = plantColonies;
      if (registry != null) registry.removeCell(idx);
      return;
    }

    // Absorb water from adjacent water cells
    if (frameCount % 8 == 0) {
      if (checkAdjacent(x, y, El.water)) {
        life[idx] = (life[idx] + 3).clamp(0, 100);
        // Also boost moisture in surrounding dirt
        for (int dy2 = -1; dy2 <= 1; dy2++) {
          for (int dx2 = -1; dx2 <= 1; dx2++) {
            if (dx2 == 0 && dy2 == 0) continue;
            final nx = wrapX(x + dx2); final ny = y + dy2;
            if (!inBoundsY(ny)) continue;
            final ni = ny * w + nx;
            if (grid[ni] == El.dirt && life[ni] < 4) {
              life[ni] = (life[ni] + 1).clamp(0, 5);
            }
          }
        }
      } else {
        // Slowly dehydrate without water
        life[idx] = (life[idx] - 1).clamp(0, 100);
      }
    }

    // Death from dehydration
    if (life[idx] <= 0 && frameCount % 20 == 0) {
      grid[idx] = El.dirt; life[idx] = 2;
      final registry = plantColonies;
      if (registry != null) registry.removeCell(idx);
      markDirty(x, y); return;
    }

    // Neural colony decisions
    final registry = plantColonies;
    double growDown = 0.7;
    double growLateral = 0.0;
    double branchProb = 0.02;

    if (registry != null) {
      final colony = registry.colonyForCell(idx);
      if (colony != null) {
        final inputs = registry.gatherInputs(this, x, y, idx);
        final out = colony.decide(
          inputs[0], inputs[1], inputs[2], inputs[3],
          inputs[4], inputs[5], inputs[6], inputs[7],
        );
        // For roots, growUp is inverted: negative = grow deeper
        growDown = (1.0 - (out[outGrowUp] + 1.0) * 0.5); // invert
        growLateral = out[outGrowLateral];
        branchProb = (out[outBranch] + 1.0) * 0.03;
      }
    }

    // Grow downward through dirt, seeking water
    final growRate = plantGrowRate[plantRoot];
    final curSize = velY[idx].clamp(0, 127).toInt();
    if (frameCount % growRate == 0 && curSize < plantMaxH[plantRoot] && growDown > 0.3) {
      // Primary direction: down (growDown controls willingness to extend)
      int gy = y + gravityDir;
      int gx = x;
      if (growLateral > 0.4) {
        gx = wrapX(x + 1);
      } else if (growLateral < -0.4) {
        gx = wrapX(x - 1);
      }

      if (inBoundsY(gy)) {
        final ni = gy * w + gx;
        if (grid[ni] == El.dirt || grid[ni] == El.compost) {
          grid[ni] = El.root; life[ni] = life[idx];
          velY[ni] = (curSize + 1); markProcessed(ni); markDirty(gx, gy);
          velY[idx] = (curSize + 1);
          if (registry != null) {
            final colony = registry.colonyForCell(idx);
            if (colony != null) registry.addCell(colony, ni);
          }
        }
      }

      // Branching roots
      if (rng.nextDouble() < branchProb && curSize > 3) {
        final side = rng.nextBool() ? 1 : -1;
        final bx = wrapX(x + side);
        final bi = y * w + bx;
        if (grid[bi] == El.dirt || grid[bi] == El.compost) {
          grid[bi] = El.root; life[bi] = life[idx];
          velY[bi] = curSize; markProcessed(bi); markDirty(bx, y);
          if (registry != null) {
            final colony = registry.colonyForCell(idx);
            if (colony != null) registry.addCell(colony, bi);
          }
        }
      }
    }
  }

  // =========================================================================
  // Thorn — defensive plant structure, damages creatures
  // =========================================================================
  void simThorn(int x, int y, int idx) {
    // Gravity: thorns fall if not attached to a plant/vine/flower
    if (!checkAdjacentAnyOf(x, y, thornAttachSet)) {
      fallSolid(x, y, idx, El.thorn);
    }
    // Fire destroys thorns
    if (checkAdjacentAny2(x, y, El.fire, El.lava)) {
      grid[idx] = El.fire; life[idx] = 0; markProcessed(idx); return;
    }

    // Damage nearby ants (creatures)
    if (frameCount % 10 == 0) {
      for (int dy2 = -1; dy2 <= 1; dy2++) {
        for (int dx2 = -1; dx2 <= 1; dx2++) {
          if (dx2 == 0 && dy2 == 0) continue;
          final nx = wrapX(x + dx2); final ny = y + dy2;
          if (!inBoundsY(ny)) continue;
          final ni = ny * gridW + nx;
          if (grid[ni] == El.ant) {
            // Damage the ant by reducing its life
            life[ni] = (life[ni] - SimTuning.thornDamage).clamp(0, 255);
            markDirty(nx, ny);
            // Track fitness
            final registry = plantColonies;
            if (registry != null) {
              final colony = registry.colonyForCell(idx);
              if (colony != null) colony.herbivoresDamaged++;
            }
          }
        }
      }
    }

    // Slow decay without a living plant neighbor
    if (frameCount % 30 == 0) {
      bool hasPlant = false;
      for (int dy2 = -1; dy2 <= 1; dy2++) {
        for (int dx2 = -1; dx2 <= 1; dx2++) {
          if (dx2 == 0 && dy2 == 0) continue;
          final nx = wrapX(x + dx2); final ny = y + dy2;
          if (!inBoundsY(ny)) continue;
          final el = grid[ny * gridW + nx];
          if (el == El.plant || el == El.vine || el == El.flower || el == El.root) {
            hasPlant = true; break;
          }
        }
        if (hasPlant) break;
      }
      if (!hasPlant) {
        life[idx]++;
        if (life[idx] > 100) {
          grid[idx] = El.ash; life[idx] = 0; markDirty(x, y);
          final registry = plantColonies;
          if (registry != null) registry.removeCell(idx);
        }
      }
    }
  }

  // =========================================================================
  // Honey — very viscous ant-produced liquid, preserves organic matter
  // =========================================================================
  void simHoney(int x, int y, int idx) {
    if (checkTemperatureReaction(x, y, idx, El.honey)) return;
    // Convection: honey is very viscous, so convect rarely
    if (frameCount % 6 == 0 && tryConvection(x, y, idx, El.honey)) return;
    // Very slow crystallization over long time
    life[idx]++;
    if (life[idx] > SimTuning.honeyCrystallizeLife && rng.nextInt(SimTuning.honeyCrystallize) == 0) {
      grid[idx] = El.sand; life[idx] = 0; markDirty(x, y); return;
    }
    // Viscous liquid physics: falls, spreads very slowly (viscosity 6)
    final g = gravityDir;
    final w = gridW;
    final by = y + g;
    if (inBoundsY(by) && isEmptyOrGas(grid[by * w + x])) {
      swap(idx, by * w + x); return;
    }
    // Very slow lateral spread (viscosity 6 = spread every 6th frame)
    if (frameCount % 6 == 0) {
      final dir = rng.nextBool() ? 1 : -1;
      final nx = wrapX(x + dir);
      if (isEmptyOrGas(grid[y * w + nx])) { swap(idx, y * w + nx); }
    }
  }

  // =========================================================================
  // Hydrogen — lightest gas, rises fast, explosive with oxygen
  // =========================================================================
  void simHydrogen(int x, int y, int idx) {
    // Explosive: H2 + O2 + spark/fire → water + massive heat
    if (checkAdjacentAny3(x, y, El.fire, El.lava, El.lightning)) {
      if (checkAdjacent(x, y, El.oxygen)) {
        grid[idx] = El.steam;
        temperature[idx] = 250;
        removeOneAdjacent(x, y, El.oxygen);
        markDirty(x, y);
        pendingExplosions.add(Explosion(x, y, 2));
        return;
      }
      grid[idx] = El.fire; temperature[idx] = 230;
      markDirty(x, y); return;
    }
    // Lightest gas: rises through ALL heavier gases
    final w = gridW;
    final uy = y - gravityDir;
    if (inBoundsY(uy)) {
      final ui = uy * w + x;
      final above = grid[ui];
      if (above == El.empty || above == El.oxygen || above == El.co2 ||
          above == El.smoke || above == El.steam || above == El.methane) {
        swap(idx, ui); return;
      }
    }
    if (rng.nextInt(SimTuning.hydrogenDrift) == 0) {
      final dir = rng.nextBool() ? 1 : -1;
      final nx = wrapX(x + dir);
      if (grid[y * w + nx] == El.empty) { swap(idx, y * w + nx); }
    }
  }

  // =========================================================================
  // Sulfur — volcanic, burns to toxic smoke, tarnishes metals
  // =========================================================================
  void simSulfur(int x, int y, int idx) {
    if (checkTemperatureReaction(x, y, idx, El.sulfur)) return;
    if ((checkAdjacentAny2(x, y, El.fire, El.lava) ||
        temperature[idx] > 150) && checkAdjacent(x, y, El.oxygen)) {
      grid[idx] = El.fire;
      temperature[idx] = 200;
      final uy = y - gravityDir;
      if (inBoundsY(uy) && grid[uy * gridW + x] == El.empty) {
        grid[uy * gridW + x] = El.smoke;
        markDirty(x, uy);
      }
      markDirty(x, y); return;
    }
    if (rng.nextInt(SimTuning.sulfurTarnishRate) == 0 && checkAdjacent(x, y, El.metal)) {
      life[idx] = (life[idx] + 1).clamp(0, 50);
    }
    fallGranular(x, y, idx, El.sulfur);
  }

  // =========================================================================
  // Copper — best conductor, resists corrosion, slow green patina
  // =========================================================================
  void simCopper(int x, int y, int idx) {
    final g = gravityDir;
    final by = y + g;
    final belowEmpty = inBoundsY(by) && (grid[by * gridW + x] == El.empty
        || grid[by * gridW + x] == El.water);
    if (belowEmpty) {
      bool hasSupport = false;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (!inBoundsY(ny)) { hasSupport = true; continue; }
          final n = grid[ny * gridW + nx];
          if (n == El.stone || n == El.metal || n == El.copper ||
              n == El.wood || n == El.glass || n == El.ice) {
            hasSupport = true;
          }
        }
      }
      if (!hasSupport) {
        fallSolid(x, y, idx, El.copper);
        return;
      }
    }
    if (checkAdjacent(x, y, El.water) && rng.nextInt(SimTuning.copperPatinaBase) == 0) {
      life[idx] = (life[idx] + 1).clamp(0, 100);
    }
    // Copper patina: aged copper (cellAge > 200) develops verdigris
    // which shifts pH toward alkaline (carbonate patina)
    final copperAge = cellAge[idx];
    if (copperAge > 200) {
      // Accelerate patina formation with age
      final patinaRate = 2000 - ((copperAge - 200) * 10); // faster as it ages
      if (rng.nextInt(patinaRate > 50 ? patinaRate : 50) == 0) {
        life[idx] = (life[idx] + 1).clamp(0, 100);
      }
      // Aged copper shifts local pH toward alkaline (copper carbonate)
      if (copperAge > 230 && pH[idx] < 160) {
        pH[idx] = pH[idx] + 1;
      }
    }
    if (checkAdjacent(x, y, El.acid) && rng.nextInt(SimTuning.copperAcidRate) == 0) {
      grid[idx] = El.empty; life[idx] = 0;
      removeOneAdjacent(x, y, El.acid);
      markDirty(x, y);
    }
  }

  // =========================================================================
  // Web — spider silk, sticky, burns instantly, dissolves in water
  // =========================================================================
  void simWeb(int x, int y, int idx) {
    life[idx]++;
    if (checkAdjacentAny2(x, y, El.fire, El.lava)) {
      grid[idx] = El.fire; life[idx] = 0; markDirty(x, y); return;
    }
    if (checkAdjacent(x, y, El.water) && rng.nextInt(SimTuning.webWaterDissolve) == 0) {
      grid[idx] = El.empty; life[idx] = 0; markDirty(x, y); return;
    }
    if (checkAdjacent(x, y, El.acid)) {
      grid[idx] = El.empty; life[idx] = 0; markDirty(x, y); return;
    }
    if (life[idx] > SimTuning.webDecayLife) {
      grid[idx] = El.empty; life[idx] = 0; markDirty(x, y);
    }
  }

  // =========================================================================
  // Alkali Metal — violently reactive with water, soft solid
  // =========================================================================
  void simAlkaliMetal(int x, int y, int idx) {
    final el = grid[idx];
    // Check for water contact — explosive reaction
    if (checkAdjacent(x, y, El.water)) {
      // Scale explosion by reactivity (heavier alkalis = bigger boom)
      final reactivity = elementReactivity[el];
      final radius = 1 + (reactivity ~/ 80); // 1-3 cell radius
      // Remove the alkali metal
      grid[idx] = El.fire; life[idx] = 0;
      temperature[idx] = 230; markDirty(x, y);
      // Consume adjacent water, produce hydrogen
      for (int dy2 = -radius; dy2 <= radius; dy2++) {
        for (int dx2 = -radius; dx2 <= radius; dx2++) {
          final nx = wrapX(x + dx2); final ny = y + dy2;
          if (!inBoundsY(ny)) continue;
          final ni = ny * gridW + nx;
          if (grid[ni] == El.water) {
            if (rng.nextInt(3) == 0) {
              grid[ni] = El.hydrogen; // produce H₂
            } else {
              grid[ni] = El.fire;
              temperature[ni] = 200;
            }
            markDirty(nx, ny);
          }
        }
      }
      queueReactionFlash(x, y, 255, 180, 50, radius * 3);
      return;
    }
    // Fall as granular
    fallGranular(x, y, idx, el);
  }

  // =========================================================================
  // Alkaline Earth Metal — moderate water reaction, flame colors
  // =========================================================================

  /// Simulate alkaline earth metals (Be, Mg, Ca, Sr, Ba).
  /// Radium is dispatched to simRadioactive instead.
  /// All react with water (slower than alkali metals) producing hydrogen.
  /// Each has distinctive fire behavior: Mg burns white, Sr red, Ba green.
  void simAlkalineEarth(int x, int y, int idx) {
    final el = grid[idx];
    final w = gridW;

    // --- Fire contact: element-specific flame colors ---
    // Real chemistry: alkaline earth metal salts produce characteristic
    // flame colors due to electron excitation. Mg burns brilliant white
    // (used in flares), Sr red (fireworks), Ba green (fireworks).
    if (checkAdjacent(x, y, El.fire) || checkAdjacent(x, y, El.lava)) {
      switch (el) {
        case El.magnesium:
          // Mg + O₂ → MgO — brilliant white flash, produces oxide ash
          grid[idx] = El.ash;
          life[idx] = 0;
          temperature[idx] = 240;
          lightR[idx] = 255; lightG[idx] = 255; lightB[idx] = 255;
          markDirty(x, y);
          // Ignite neighbors — magnesium fires spread
          for (int dy2 = -1; dy2 <= 1; dy2++) {
            for (int dx2 = -1; dx2 <= 1; dx2++) {
              if (dx2 == 0 && dy2 == 0) continue;
              final nx = wrapX(x + dx2); final ny = y + dy2;
              if (!inBoundsY(ny)) continue;
              final ni = ny * w + nx;
              if (grid[ni] == El.empty && rng.nextInt(3) == 0) {
                grid[ni] = El.fire; temperature[ni] = 220; markDirty(nx, ny);
              }
            }
          }
          queueReactionFlash(x, y, 255, 255, 255, 6);
          return;
        case El.strontium:
          // Sr flame test: red-orange emission (606 nm)
          lightR[idx] = 255; lightG[idx] = 60; lightB[idx] = 20;
          life[idx] = (life[idx] + 1).clamp(0, 255);
          temperature[idx] = (temperature[idx] + 3).clamp(0, 255);
          markDirty(x, y);
          if (life[idx] > 200) {
            grid[idx] = El.ash; life[idx] = 0; markProcessed(idx);
            queueReactionFlash(x, y, 255, 60, 20, 4);
            return;
          }
        case El.barium:
          // Ba flame test: green emission (524 nm)
          lightR[idx] = 40; lightG[idx] = 255; lightB[idx] = 60;
          life[idx] = (life[idx] + 1).clamp(0, 255);
          temperature[idx] = (temperature[idx] + 3).clamp(0, 255);
          markDirty(x, y);
          if (life[idx] > 200) {
            grid[idx] = El.ash; life[idx] = 0; markProcessed(idx);
            queueReactionFlash(x, y, 40, 255, 60, 4);
            return;
          }
        case El.calcium:
          // Ca flame test: orange-red (622 nm) — less dramatic
          lightR[idx] = 255; lightG[idx] = 100; lightB[idx] = 30;
          life[idx] = (life[idx] + 1).clamp(0, 255);
          temperature[idx] = (temperature[idx] + 2).clamp(0, 255);
          markDirty(x, y);
          if (life[idx] > 220) {
            grid[idx] = El.ash; life[idx] = 0; markProcessed(idx);
            return;
          }
        default:
          // Beryllium: high melt point, doesn't burn easily
          temperature[idx] = (temperature[idx] + 1).clamp(0, 255);
          markDirty(x, y);
      }
    }

    // --- Water reaction: slower than alkali metals ---
    // Real: Mg + 2H₂O → Mg(OH)₂ + H₂↑ (slow at room temp, fast when hot)
    // Ca + 2H₂O → Ca(OH)₂ + H₂↑ (moderate rate)
    // Be barely reacts (passivation layer)
    if (checkAdjacent(x, y, El.water)) {
      final reactivity = elementReactivity[el];
      // Be has very low reactivity (~40), so it almost never reacts
      // Ca/Sr/Ba react moderately, Mg needs heat to react well
      int chance = 200 - reactivity; // lower = more reactive
      if (el == El.magnesium && temperature[idx] < 160) {
        chance += 100; // Mg is slow at room temp, faster when hot
      }
      if (rng.nextInt(chance.clamp(10, 400)) == 0) {
        // Consume one adjacent water cell, produce hydrogen
        for (int dy2 = -1; dy2 <= 1; dy2++) {
          for (int dx2 = -1; dx2 <= 1; dx2++) {
            if (dx2 == 0 && dy2 == 0) continue;
            final nx = wrapX(x + dx2); final ny = y + dy2;
            if (!inBoundsY(ny)) continue;
            final ni = ny * w + nx;
            if (grid[ni] == El.water) {
              grid[ni] = El.hydrogen; markDirty(nx, ny);
              break; // one bubble per tick
            }
          }
        }
        // Slowly consume the metal
        life[idx] = (life[idx] + 1).clamp(0, 255);
        if (life[idx] > 240) {
          grid[idx] = El.stone; // hydroxide precipitate → stone-like
          life[idx] = 0; markProcessed(idx);
          return;
        }
        markDirty(x, y);
      }
    }

    // --- Acid reaction: all alkaline earths dissolve in acid ---
    if (checkAdjacent(x, y, El.acid)) {
      if (rng.nextInt(6) == 0) {
        // Consume acid, produce hydrogen
        for (int dy2 = -1; dy2 <= 1; dy2++) {
          for (int dx2 = -1; dx2 <= 1; dx2++) {
            if (dx2 == 0 && dy2 == 0) continue;
            final nx = wrapX(x + dx2); final ny = y + dy2;
            if (!inBoundsY(ny)) continue;
            final ni = ny * w + nx;
            if (grid[ni] == El.acid) {
              grid[ni] = El.hydrogen; markDirty(nx, ny);
              break;
            }
          }
        }
        grid[idx] = El.salt; life[idx] = 0; markProcessed(idx);
        queueReactionFlash(x, y, 200, 200, 220, 3);
        return;
      }
    }

    // Gravity: fall as solid
    fallSolid(x, y, idx, el);
  }

  // =========================================================================
  // Transition Metal — varied unique behaviors per element
  // =========================================================================

  /// Simulate transition metals with element-specific behaviors.
  /// Gold: never corrodes. Silver: tarnishes. Tungsten: extreme melt point.
  /// Zinc: passivation layer. Platinum: catalyst for adjacent reactions.
  void simTransitionMetal(int x, int y, int idx) {
    final el = grid[idx];
    final w = gridW;

    switch (el) {
      case El.gold:
        // Gold is nearly inert — oxidation stays at 128 (neutral)
        // Real: Au standard electrode potential +1.52V, resists almost everything
        oxidation[idx] = 128;
        // Only melts at very high temp (already in properties: meltPoint 170)
        fallSolid(x, y, idx, El.gold);
        return;

      case El.chromium:
        // Chromium forms a tough Cr₂O₃ passivation layer — the basis of
        // stainless steel. Oxidation rises quickly to ~145 then stops.
        // Real: Cr₂O₃ is only 1-2 nm thick but extremely stable.
        {
          final ox = oxidation[idx];
          if (ox < 145 && frameCount % 12 == 0) {
            oxidation[idx] = ox + 1;
            markDirty(x, y);
          }
          // Cap: once passivated, no further corrosion
          if (ox > 145) oxidation[idx] = 145;
        }
        // Resists acid well (passivation protects it)
        if (checkAdjacent(x, y, El.acid) && rng.nextInt(200) == 0) {
          for (int dy2 = -1; dy2 <= 1; dy2++) {
            for (int dx2 = -1; dx2 <= 1; dx2++) {
              if (dx2 == 0 && dy2 == 0) continue;
              final nx = wrapX(x + dx2); final ny = y + dy2;
              if (!inBoundsY(ny)) continue;
              final ni = ny * w + nx;
              if (grid[ni] == El.acid) {
                grid[ni] = El.empty; markDirty(nx, ny);
                break;
              }
            }
          }
        }
        fallSolid(x, y, idx, El.chromium);
        return;

      case El.silver:
        // Silver tarnishes over time: Ag + H₂S → Ag₂S (black tarnish)
        // Represented by oxidation drifting upward slowly
        if (frameCount % 30 == 0) {
          final ox = oxidation[idx];
          if (ox < 180) {
            oxidation[idx] = ox + 1;
            markDirty(x, y);
          }
        }
        // Sulfur accelerates tarnishing
        if (checkAdjacent(x, y, El.sulfur) && frameCount % 8 == 0) {
          final ox = oxidation[idx];
          if (ox < 200) {
            oxidation[idx] = ox + 3;
            markDirty(x, y);
          }
        }
        fallSolid(x, y, idx, El.silver);
        return;

      case El.tungsten:
        // Tungsten: highest melt point of any element (3422C)
        // In-game: melt point 255, effectively can't melt except in extreme conditions
        // Also extremely hard — resist acid
        if (checkAdjacent(x, y, El.acid)) {
          // Tungsten resists acid — do nothing (very slow dissolution)
          if (rng.nextInt(500) == 0) {
            for (int dy2 = -1; dy2 <= 1; dy2++) {
              for (int dx2 = -1; dx2 <= 1; dx2++) {
                if (dx2 == 0 && dy2 == 0) continue;
                final nx = wrapX(x + dx2); final ny = y + dy2;
                if (!inBoundsY(ny)) continue;
                final ni = ny * w + nx;
                if (grid[ni] == El.acid) {
                  grid[ni] = El.empty; markDirty(nx, ny);
                  break;
                }
              }
            }
          }
        }
        // Oxidation stays very low — tungsten forms thin protective oxide
        if (oxidation[idx] > 140) oxidation[idx] = 140;
        fallSolid(x, y, idx, El.tungsten);
        return;

      case El.zinc:
        // Zinc forms a protective oxide layer then stops corroding
        // Real: Zn + O₂ → ZnO (passivation). Used for galvanizing.
        {
          final ox = oxidation[idx];
          if (ox < 160 && frameCount % 20 == 0) {
            oxidation[idx] = ox + 1; // slow passivation
            markDirty(x, y);
          }
          // Once oxidation reaches ~160, it stabilizes (passivation complete)
        }
        // Acid reaction: Zn + 2HCl → ZnCl₂ + H₂↑
        if (checkAdjacent(x, y, El.acid)) {
          if (rng.nextInt(8) == 0) {
            for (int dy2 = -1; dy2 <= 1; dy2++) {
              for (int dx2 = -1; dx2 <= 1; dx2++) {
                if (dx2 == 0 && dy2 == 0) continue;
                final nx = wrapX(x + dx2); final ny = y + dy2;
                if (!inBoundsY(ny)) continue;
                final ni = ny * w + nx;
                if (grid[ni] == El.acid) {
                  grid[ni] = El.hydrogen; markDirty(nx, ny);
                  break;
                }
              }
            }
            grid[idx] = El.salt; life[idx] = 0; markProcessed(idx);
            queueReactionFlash(x, y, 180, 200, 220, 3);
            return;
          }
        }
        fallSolid(x, y, idx, El.zinc);
        return;

      case El.platinum:
        // Platinum is a powerful catalyst — increases reaction rate of
        // adjacent reactive pairs without being consumed.
        // Real: Pt catalyzes H₂+O₂, hydrogenation, catalytic converters
        oxidation[idx] = 128; // never corrodes (noble metal)
        if (frameCount % 4 == 0) {
          for (int dy2 = -1; dy2 <= 1; dy2++) {
            for (int dx2 = -1; dx2 <= 1; dx2++) {
              if (dx2 == 0 && dy2 == 0) continue;
              final nx = wrapX(x + dx2); final ny = y + dy2;
              if (!inBoundsY(ny)) continue;
              final ni = ny * w + nx;
              final neighbor = grid[ni];
              // Catalyze hydrogen + oxygen → water
              if (neighbor == El.hydrogen && checkAdjacent(nx, ny, El.oxygen)) {
                grid[ni] = El.water; life[ni] = 100; markDirty(nx, ny);
                queueReactionFlash(nx, ny, 200, 220, 255, 2);
              }
              // Catalyze organic decomposition (accelerate compost)
              if (neighbor == El.compost && rng.nextInt(4) == 0) {
                life[ni] = (life[ni] + 5).clamp(0, 255);
                markDirty(nx, ny);
              }
            }
          }
        }
        fallSolid(x, y, idx, El.platinum);
        return;

      default:
        // Generic transition metal: just fall + default oxidation behavior
        fallSolid(x, y, idx, el);
        return;
    }
  }

  // =========================================================================
  // Noble Gas — inert, buoyant, glow when electrically excited
  // =========================================================================

  /// Simulate noble gases (He, Ne, Ar, Kr, Xe). They are chemically inert
  /// but have distinctive physical behaviors:
  /// - Helium: lightest gas, rises fastest, high wind sensitivity
  /// - Neon/Argon/Krypton/Xenon: glow when near electricity (gas discharge)
  /// - Xenon: heaviest stable noble gas, neutrally buoyant, strongest glow
  /// - All: density-stratified buoyancy, lateral diffusion
  void simNobleGas(int x, int y, int idx) {
    final el = grid[idx];
    final w = gridW;
    final g = gravityDir;

    // --- Electrical excitation: noble gases glow in electric fields ---
    // Real physics: gas discharge tubes work by accelerating electrons through
    // the gas. Each noble gas emits a characteristic color when its electrons
    // return to ground state. Voltage threshold varies by gas.
    if (el != El.helium) { // Helium doesn't visibly glow in-game
      bool excited = false;
      for (int dy = -1; dy <= 1 && !excited; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final ni = ny * w + nx;
          final neighbor = grid[ni];
          // Excited by lightning, high voltage, or other excited noble gas
          if (neighbor == El.lightning ||
              (voltage[ni].abs() > 20) ||
              (neighbor == el && lightR[ni] > 0)) {
            excited = true;
            break;
          }
        }
      }
      if (excited) {
        // Each gas has its characteristic emission spectrum
        switch (el) {
          case El.neon:
            lightR[idx] = 255; lightG[idx] = 80; lightB[idx] = 30; // orange-red
          case El.argon:
            lightR[idx] = 160; lightG[idx] = 100; lightB[idx] = 255; // violet
          case El.krypton:
            lightR[idx] = 220; lightG[idx] = 230; lightB[idx] = 255; // white
          case El.xenon:
            lightR[idx] = 120; lightG[idx] = 140; lightB[idx] = 255; // blue-white
          default: break;
        }
        // Excited gas emits light for a few frames then fades
        life[idx] = 20; // excitation timer
      } else if (life[idx] > 0) {
        // Decay excitation
        life[idx]--;
        if (life[idx] == 0) {
          lightR[idx] = 0; lightG[idx] = 0; lightB[idx] = 0;
        }
      }
    }

    // --- Argon shielding: prevents oxidation of adjacent metals ---
    // Real physics: argon is the standard shielding gas in welding (MIG/TIG).
    // It displaces oxygen, preventing oxide formation on hot metal surfaces.
    if (el == El.argon && frameCount % 4 == 0) {
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final ni = ny * w + nx;
          // Push oxidation toward neutral on adjacent metals
          if (grid[ni] == El.metal || grid[ni] == El.copper) {
            final ox = oxidation[ni];
            if (ox > 130) oxidation[ni] = ox - 2;
          }
        }
      }
    }

    // --- Gas movement: buoyancy + drift ---
    final myDensity = elementDensity[el];
    final grav = elementGravity[el];

    // Vertical movement: rise or sink based on gravity
    if (grav < 0) {
      // Rising gas — try to rise through empty or lighter gas
      final uy = y - g;
      if (inBoundsY(uy)) {
        final ui = uy * w + x;
        final aboveEl = grid[ui];
        if (aboveEl == El.empty) {
          // Helium rises 2 cells, others 1
          if (el == El.helium) {
            final uy2 = y - g * 2;
            if (inBoundsY(uy2) && grid[uy2 * w + x] == El.empty) {
              swap(idx, uy2 * w + x);
              return;
            }
          }
          swap(idx, ui);
          return;
        }
        // Buoyancy: rise through heavier gases
        if (elementPhysicsState[aboveEl] == PhysicsState.gas.index &&
            elementDensity[aboveEl] > myDensity) {
          swap(idx, ui);
          return;
        }
      }
    } else if (grav > 0) {
      // Sinking gas (xenon) — fall through empty or displace lighter gas
      if (tryDensityDisplace(x, y, idx, el)) return;
      final by = y + g;
      if (inBoundsY(by) && isEmptyOrGas(grid[by * w + x])) {
        swap(idx, by * w + x);
        return;
      }
    }

    // Lateral diffusion: gases spread sideways randomly
    if (rng.nextInt(2) == 0) {
      final dir = rng.nextBool() ? 1 : -1;
      final nx = wrapX(x + dir);
      final ni = y * w + nx;
      final sideEl = grid[ni];
      if (sideEl == El.empty) {
        swap(idx, ni);
      } else if (elementPhysicsState[sideEl] == PhysicsState.gas.index &&
                 elementDensity[sideEl] > myDensity && rng.nextInt(3) == 0) {
        // Lighter gas displaces heavier gas sideways occasionally
        swap(idx, ni);
      }
    }
  }

  // =========================================================================
  // Halogen Gas — reactive, toxic to organics
  // =========================================================================
  void simHalogenGas(int x, int y, int idx) {
    final w = gridW;
    // React with metals to form salt
    for (int dy2 = -1; dy2 <= 1; dy2++) {
      for (int dx2 = -1; dx2 <= 1; dx2++) {
        if (dx2 == 0 && dy2 == 0) continue;
        final nx = wrapX(x + dx2); final ny = y + dy2;
        if (!inBoundsY(ny)) continue;
        final ni = ny * w + nx;
        final neighbor = grid[ni];
        // Metal + halogen → salt
        if (neighbor == El.metal || neighbor == El.sodium || neighbor == El.aluminum
            || neighbor == El.copper || neighbor == El.zinc) {
          if (rng.nextInt(8) == 0) {
            grid[ni] = El.salt; markDirty(nx, ny);
            grid[idx] = El.empty; markDirty(x, y);
            return;
          }
        }
        // Toxic to organics
        if ((elCategory[neighbor] & ElCat.organic) != 0 && rng.nextInt(10) == 0) {
          grid[ni] = El.empty; markDirty(nx, ny);
        }
      }
    }
    // Rise as gas
    final uy = y - gravityDir;
    if (inBoundsY(uy) && grid[uy * w + x] == El.empty) {
      swap(idx, uy * w + x);
    } else {
      // Spread laterally
      final dir = rng.nextBool() ? 1 : -1;
      final sx = wrapX(x + dir);
      if (grid[y * w + sx] == El.empty) {
        swap(idx, y * w + sx);
      }
    }
  }

  // =========================================================================
  // Radioactive — decay chains, radiation damage, heat generation
  // =========================================================================
  void simRadioactive(int x, int y, int idx) {
    final el = grid[idx];
    final w = gridW;

    // Heat generation from radioactive decay
    if (temperature[idx] < 180) {
      temperature[idx] = (temperature[idx] + 1).clamp(0, 255);
    }
    markDirty(x, y);

    // Radiation damage to adjacent organic elements
    if (frameCount % 10 == 0) {
      for (int dy2 = -2; dy2 <= 2; dy2++) {
        for (int dx2 = -2; dx2 <= 2; dx2++) {
          if (dx2 == 0 && dy2 == 0) continue;
          final nx = wrapX(x + dx2); final ny = y + dy2;
          if (!inBoundsY(ny)) continue;
          final ni = ny * w + nx;
          final neighbor = grid[ni];
          if ((elCategory[neighbor] & ElCat.organic) != 0 && rng.nextInt(20) == 0) {
            grid[ni] = El.ash; life[ni] = 0; markDirty(nx, ny);
          }
        }
      }
    }

    // For non-solid radioactives (radon = gas), handle movement
    if (elementProperties[el].state == PhysicsState.gas) {
      final uy = y - gravityDir;
      if (inBoundsY(uy) && grid[uy * w + x] == El.empty) {
        swap(idx, uy * w + x);
      }
    }
    // Decay is handled by the engine's decayRate/decaysInto system
  }

  // =========================================================================
  // Liquid Metal — mercury, gallium (liquid + metallic properties)
  // =========================================================================
  void simLiquidMetal(int x, int y, int idx) {
    final el = grid[idx];
    final w = gridW;

    // Toxic to organics (mercury)
    if (el == El.mercury && frameCount % 8 == 0) {
      for (int dy2 = -1; dy2 <= 1; dy2++) {
        for (int dx2 = -1; dx2 <= 1; dx2++) {
          if (dx2 == 0 && dy2 == 0) continue;
          final nx = wrapX(x + dx2); final ny = y + dy2;
          if (!inBoundsY(ny)) continue;
          final ni = ny * w + nx;
          if ((elCategory[grid[ni]] & ElCat.organic) != 0 && rng.nextInt(15) == 0) {
            grid[ni] = El.empty; markDirty(nx, ny);
          }
          // Amalgamate with gold/silver
          if ((grid[ni] == El.gold || grid[ni] == El.silver) && rng.nextInt(20) == 0) {
            grid[ni] = El.mercury; markDirty(nx, ny); // absorbs precious metals
          }
        }
      }
    }

    // Liquid behavior: fall + spread
    final by = y + gravityDir;
    if (inBoundsY(by)) {
      final bi = by * w + x;
      if (grid[bi] == El.empty) {
        swap(idx, bi); return;
      }
      // Density displacement
      final belowEl = grid[bi];
      if (elementDensity[el] > elementDensity[belowEl] &&
          elementProperties[belowEl].state == PhysicsState.liquid) {
        swap(idx, bi); return;
      }
    }
    // Lateral spread
    if (frameCount % 2 == 0) {
      final dir = rng.nextBool() ? 1 : -1;
      final sx = wrapX(x + dir);
      if (grid[y * w + sx] == El.empty) {
        swap(idx, y * w + sx);
      }
    }
  }

  // =========================================================================
  // Atmospherics (Phase 7)
  // =========================================================================

  void simVapor(int x, int y, int idx) {
    // Vapor is water in gas phase — lighter than air, rises and condenses.
    // Real physics: water vapor is invisible (steam you see is actually
    // condensed micro-droplets). Vapor condenses when it cools below the
    // dew point, or when it reaches altitude where pressure drops.

    final w = gridW;
    final g = gravityDir;

    // Temperature-driven condensation: cold surfaces turn vapor back to water
    final temp = temperature[idx];
    if (temp < 90) {
      // Below dew point — condense into water droplet
      grid[idx] = El.water;
      life[idx] = 60;
      markProcessed(idx);
      return;
    }

    // Condense on contact with cold solids
    if (frameCount % 3 == 0) {
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = wrapX(x + dx);
          final ny = y + dy;
          if (!inBoundsY(ny)) continue;
          final ni = ny * w + nx;
          final neighbor = grid[ni];
          if (neighbor != El.empty && neighbor != El.vapor && neighbor != El.cloud &&
              elementPhysicsState[neighbor] == PhysicsState.solid.index &&
              temperature[ni] < 100) {
            // Condense on the cold surface
            grid[idx] = El.water;
            life[idx] = 40;
            markProcessed(idx);
            return;
          }
        }
      }
    }

    // High altitude: transform into cloud
    final altitudeThreshold = gravityDir == 1 ? gridH ~/ 5 : gridH - (gridH ~/ 5);
    final isAtAltitude = gravityDir == 1 ? y < altitudeThreshold : y > altitudeThreshold;
    if (isAtAltitude) {
      grid[idx] = El.cloud;
      life[idx] = 0;
      moisture[idx] = 40; // seed cloud with some moisture
      markProcessed(idx);
      return;
    }

    // Rise through empty or lighter gases (buoyancy)
    if (tryBuoyancy(x, y, idx, El.vapor)) return;
    final uy = y - g;
    if (inBoundsY(uy) && isEmptyOrGas(grid[uy * w + x])) {
      swap(idx, uy * w + x);
      return;
    }

    // Lateral drift — vapor diffuses widely
    if (rng.nextInt(2) == 0) {
      final dir = rng.nextBool() ? 1 : -1;
      final nx = wrapX(x + dir);
      final ni = y * w + nx;
      if (isEmptyOrGas(grid[ni])) swap(idx, ni);
    }
  }

  void simCloud(int x, int y, int idx) {
    // Clouds are aggregates of condensed water vapor. They form at altitude,
    // drift with wind as connected masses, accumulate moisture, and
    // precipitate when saturated. Cloud physics:
    // - Nimbus (rain): moisture > 180, produces rain/snow
    // - Cumulus (fair weather): moisture < 120, fluffy and white
    // - Cumulonimbus (storm): moisture > 220, lightning + heavy rain
    final w = gridW;
    final g = gravityDir;
    final moist = moisture[idx];

    // Count cloud neighbors (affects behavior and rendering)
    int cloudNeighbors = 0;
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = wrapX(x + dx);
        final ny = y + dy;
        if (inBoundsY(ny) && grid[ny * w + nx] == El.cloud) cloudNeighbors++;
      }
    }

    // Store neighbor count in life for the renderer to read
    life[idx] = cloudNeighbors;

    // --- Wind drift: entire cloud formation moves together ---
    final localWind = windX2[idx];
    final windDir = localWind != 0 ? (localWind > 0 ? 1 : -1) :
                    (windForce != 0 ? (windForce > 0 ? 1 : -1) : 0);
    if (windDir != 0 && rng.nextInt(3) == 0) {
      final nx = wrapX(x + windDir);
      final ni = y * w + nx;
      if (grid[ni] == El.empty || grid[ni] == El.oxygen) {
        swap(idx, ni);
        return;
      }
    }

    // --- Moisture accumulation ---
    // Larger clouds accumulate faster (more surface area = more condensation)
    if (frameCount % 6 == 0) {
      final rate = cloudNeighbors >= 4 ? 3 : (cloudNeighbors >= 2 ? 2 : 1);
      moisture[idx] = (moist + rate).clamp(0, 255);
    }

    // --- Moisture sharing between adjacent clouds (equalization) ---
    if (frameCount % 8 == 0 && cloudNeighbors > 0) {
      final dir = rng.nextBool() ? 1 : -1;
      final nx = wrapX(x + dir);
      final ni = y * w + nx;
      if (grid[ni] == El.cloud) {
        final nMoist = moisture[ni];
        if ((moist - nMoist).abs() > 10) {
          final avg = (moist + nMoist) ~/ 2;
          moisture[idx] = avg;
          moisture[ni] = avg;
        }
      }
    }

    // --- Precipitation: saturated clouds produce rain or snow ---
    if (moist > 180) {
      // Rain falls from the BOTTOM of the cloud (cell below must not be cloud)
      final by = y + g;
      final isBottom = !inBoundsY(by) || grid[by * w + x] != El.cloud;
      if (isBottom && rng.nextInt(moist > 220 ? 4 : 12) == 0) {
        final t = temperature[idx];
        if (t < 80) {
          // Cold: snow
          if (inBoundsY(by) && isEmptyOrGas(grid[by * w + x])) {
            grid[by * w + x] = El.snow;
            markDirty(x, by);
          }
        } else {
          // Warm: rain
          if (inBoundsY(by) && isEmptyOrGas(grid[by * w + x])) {
            grid[by * w + x] = El.water;
            life[by * w + x] = 60;
            markDirty(x, by);
          }
        }
        moisture[idx] = (moist - 20).clamp(0, 255);
      }

      // Storm clouds (very saturated) can spawn lightning
      if (moist > 230 && rng.nextInt(800) == 0) {
        final ly = y + g * 2;
        if (inBoundsY(ly) && isEmptyOrGas(grid[ly * w + x])) {
          grid[ly * w + x] = El.lightning;
          markDirty(x, ly);
          lightningFlashFrames = 4;
        }
      }
    }

    // --- Cloud growth: vapor and moisture feed expansion ---
    if (rng.nextInt(80) == 0 && cloudNeighbors >= 2) {
      // Grow laterally or vertically to form larger formations
      final dx = rng.nextInt(3) - 1;
      final dy = rng.nextInt(2) == 0 ? 0 : (rng.nextBool() ? -1 : 1);
      final nx = wrapX(x + dx);
      final ny = y + dy;
      if (inBoundsY(ny)) {
        final ni = ny * w + nx;
        final target = grid[ni];
        if (target == El.empty || target == El.oxygen || target == El.vapor) {
          grid[ni] = El.cloud;
          moisture[ni] = moist ~/ 3; // new cells start with less moisture
          life[ni] = 0;
          markDirty(nx, ny);
        }
      }
    }

    // --- Cloud dissipation: isolated cells evaporate ---
    if (cloudNeighbors <= 1 && moist < 40 && rng.nextInt(30) == 0) {
      grid[idx] = El.vapor;
      moisture[idx] = 0;
      markProcessed(idx);
    }

    // --- Buoyancy: clouds stay at altitude, don't fall ---
    // Clouds are lighter than surrounding air. If pushed below
    // their natural altitude, they rise back.
    final altFloor = gravityDir == 1 ? gridH ~/ 3 : gridH * 2 ~/ 3;
    final tooLow = gravityDir == 1 ? y > altFloor : y < altFloor;
    if (tooLow && rng.nextInt(4) == 0) {
      final uy = y - g;
      if (inBoundsY(uy) && isEmptyOrGas(grid[uy * w + x])) {
        swap(idx, uy * w + x);
      }
    }
  }

  void simSilicon(int x, int y, int idx) {
    // Silicon is a semiconductor. Its conductivity is conditional.
    // 1. Thermal conduction: hot silicon conducts electricity (thermistors)
    // 2. Oxidation gate: oxidized silicon conducts (FET logic)
    final t = temperature[idx];
    final ox = oxidation[idx];
    
    if (t > 150 || ox > 200) {
      // It's in a conductive state — allow sparks to pass through
      // By reducing dielectric and increasing electron mobility temporarily
      // However, we can't easily modify global tables here, 
      // so we use the voltage/charge buffers directly.
      if (charge[idx].abs() > 10) {
        conductElectricity(x, y);
      }
    }
    
    // Silicon is a solid, handle its gravity
    fallSolid(x, y, idx, El.silicon);
  }

  // =========================================================================
  // Phosphorus — auto-ignites when adjacent to oxygen/air
  // =========================================================================
  void simPhosphorus(int x, int y, int idx) {
    // Phosphorescence: glow in dark (low luminance)
    if (luminance[idx] < 40) {
      lightR[idx] = 100; lightG[idx] = 255; lightB[idx] = 80; // green glow
    } else {
      lightR[idx] = 0; lightG[idx] = 0; lightB[idx] = 0;
    }

    // White phosphorus auto-ignites in the presence of oxygen
    if (checkAdjacent(x, y, El.oxygen) || checkAdjacent(x, y, El.empty)) {
      // Auto-ignition chance (represents exposure to air)
      if (rng.nextInt(40) == 0) {
        grid[idx] = El.fire; life[idx] = 0;
        temperature[idx] = 220; markDirty(x, y);
        queueReactionFlash(x, y, 255, 255, 200, 4);
        return;
      }
    }
    // Fire contact: instant ignition
    if (checkAdjacent(x, y, El.fire) || checkAdjacent(x, y, El.lava)) {
      grid[idx] = El.fire; life[idx] = 0;
      temperature[idx] = 230; markDirty(x, y);
      return;
    }
    // Spontaneous ignition at high temperature
    if (temperature[idx] > 228) {
      grid[idx] = El.fire; life[idx] = 0;
      temperature[idx] = 230; markDirty(x, y);
      queueReactionFlash(x, y, 255, 255, 150, 3);
      return;
    }
    // Fall as granular
    fallGranular(x, y, idx, El.phosphorus);
  }

  // =========================================================================
  // Post-Transition Metals — Al, Ga, In, Sn, Tl, Bi
  // =========================================================================
  void simPostTransition(int x, int y, int idx) {
    final el = grid[idx];
    final w = gridW;

    // Gallium melts at near body temperature (~29C real, mapped to ~40 above base)
    if (el == El.gallium) {
      if (temperature[idx] > 138) {
        grid[idx] = El.mercury; markDirty(x, y);
        return;
      }
      // Melts from warm neighbors (body heat simulation)
      for (int dy2 = -1; dy2 <= 1; dy2++) {
        for (int dx2 = -1; dx2 <= 1; dx2++) {
          if (dx2 == 0 && dy2 == 0) continue;
          final nx = wrapX(x + dx2); final ny = y + dy2;
          if (!inBoundsY(ny)) continue;
          if (temperature[ny * w + nx] > 140 && grid[ny * w + nx] != El.empty) {
            grid[idx] = El.mercury; markDirty(x, y);
            return;
          }
        }
      }
    }

    // Aluminum: protective oxide layer — oxidation caps at ~150, then stops
    if (el == El.aluminum) {
      final ox = oxidation[idx];
      if (ox < 150 && checkAdjacent(x, y, El.water) && rng.nextInt(200) == 0) {
        oxidation[idx] = (ox + 5).clamp(0, 255);
        markDirty(x, y);
      }
      // Acid dissolves the oxide layer
      if (checkAdjacent(x, y, El.acid) && rng.nextInt(30) == 0) {
        oxidation[idx] = (ox - 20).clamp(0, 255);
        if (ox < 20) {
          grid[idx] = El.empty; markDirty(x, y);
          return;
        }
      }
    }

    // Tin: solder — when hot and adjacent to two metals, bonds them
    if (el == El.tin && temperature[idx] > 178) {
      int metalCount = 0;
      for (int dy2 = -1; dy2 <= 1; dy2++) {
        for (int dx2 = -1; dx2 <= 1; dx2++) {
          if (dx2 == 0 && dy2 == 0) continue;
          final nx = wrapX(x + dx2); final ny = y + dy2;
          if (!inBoundsY(ny)) continue;
          final n = grid[ny * w + nx];
          if (n == El.metal || n == El.copper || n == El.aluminum ||
              n == El.gold || n == El.silver || n == El.zinc) {
            metalCount++;
          }
        }
      }
      if (metalCount >= 2 && rng.nextInt(10) == 0) {
        life[idx] = 255; // marks as "soldered"
        temperature[idx] = 128;
        markDirty(x, y);
      }
    }

    // Bismuth: rainbow oxide tint — cycle oxidation for visual iridescence
    if (el == El.bismuth) {
      if (frameCount % 4 == 0) {
        oxidation[idx] = (oxidation[idx] + 1) % 256;
        markDirty(x, y);
      }
      // Slightly radioactive — very slow damage to adjacent organics
      if (frameCount % 60 == 0) {
        for (int dy2 = -1; dy2 <= 1; dy2++) {
          for (int dx2 = -1; dx2 <= 1; dx2++) {
            if (dx2 == 0 && dy2 == 0) continue;
            final nx = wrapX(x + dx2); final ny = y + dy2;
            if (!inBoundsY(ny)) continue;
            final ni = ny * w + nx;
            if ((elCategory[grid[ni]] & ElCat.organic) != 0 && rng.nextInt(50) == 0) {
              life[ni] = (life[ni] - 1).clamp(0, 255);
              markDirty(nx, ny);
            }
          }
        }
      }
    }

    if (checkTemperatureReaction(x, y, idx, el)) return;
    fallSolid(x, y, idx, el);
  }

  // =========================================================================
  // Metalloids — B, Ge, As, Sb, Te (Si has its own simSilicon)
  // =========================================================================
  void simMetalloid(int x, int y, int idx) {
    final el = grid[idx];
    final w = gridW;

    // Boron: extremely hard, at extreme heat + sand -> borosilicate glass
    if (el == El.boron) {
      if (temperature[idx] > 200) {
        for (int dy2 = -1; dy2 <= 1; dy2++) {
          for (int dx2 = -1; dx2 <= 1; dx2++) {
            if (dx2 == 0 && dy2 == 0) continue;
            final nx = wrapX(x + dx2); final ny = y + dy2;
            if (!inBoundsY(ny)) continue;
            final ni = ny * w + nx;
            if (grid[ni] == El.sand && rng.nextInt(15) == 0) {
              grid[ni] = El.glass; markDirty(nx, ny);
              grid[idx] = El.glass; markDirty(x, y);
              queueReactionFlash(x, y, 200, 255, 200, 3);
              return;
            }
          }
        }
      }
    }

    // Arsenic: toxic to adjacent life, sublimes at high temp
    if (el == El.arsenic) {
      if (frameCount % 6 == 0) {
        for (int dy2 = -1; dy2 <= 1; dy2++) {
          for (int dx2 = -1; dx2 <= 1; dx2++) {
            if (dx2 == 0 && dy2 == 0) continue;
            final nx = wrapX(x + dx2); final ny = y + dy2;
            if (!inBoundsY(ny)) continue;
            final ni = ny * w + nx;
            final neighbor = grid[ni];
            if ((neighbor == El.plant || neighbor == El.seed ||
                neighbor == El.flower || neighbor == El.vine ||
                neighbor == El.ant || neighbor == El.moss ||
                neighbor == El.algae || neighbor == El.fungus) &&
                rng.nextInt(8) == 0) {
              life[ni] = (life[ni] - 3).clamp(0, 255);
              if (life[ni] <= 0) {
                grid[ni] = El.ash; markDirty(nx, ny);
              }
            }
          }
        }
      }
      // Sublimation at high temp (skips liquid phase)
      if (temperature[idx] > 208) {
        grid[idx] = El.smoke; markDirty(x, y);
        return;
      }
    }

    // Antimony: brittle — shatters when hit by high-momentum impact
    if (el == El.antimony) {
      final ay = y - gravityDir;
      if (inBoundsY(ay)) {
        final ai = ay * w + x;
        if (grid[ai] != El.empty && velY[ai] >= 2) {
          grid[idx] = El.empty; markDirty(x, y);
          final fragments = 2 + rng.nextInt(2);
          for (int f = 0; f < fragments; f++) {
            final fx = wrapX(x + rng.nextInt(5) - 2);
            final fy = y + rng.nextInt(2);
            if (inBoundsY(fy)) {
              final fi = fy * w + fx;
              if (grid[fi] == El.empty) {
                grid[fi] = El.antimony; velY[fi] = 1;
                markDirty(fx, fy);
              }
            }
          }
          queueReactionFlash(x, y, 180, 180, 200, 2);
          return;
        }
      }
    }

    // Tellurium: toxic, produces smoke wisps near organics
    if (el == El.tellurium && frameCount % 10 == 0) {
      for (int dy2 = -1; dy2 <= 1; dy2++) {
        for (int dx2 = -1; dx2 <= 1; dx2++) {
          if (dx2 == 0 && dy2 == 0) continue;
          final nx = wrapX(x + dx2); final ny = y + dy2;
          if (!inBoundsY(ny)) continue;
          final ni = ny * w + nx;
          if ((elCategory[grid[ni]] & ElCat.organic) != 0 && rng.nextInt(12) == 0) {
            life[ni] = (life[ni] - 1).clamp(0, 255);
            final wy = y - gravityDir;
            if (inBoundsY(wy) && grid[wy * w + x] == El.empty) {
              grid[wy * w + x] = El.smoke; markDirty(x, wy);
            }
          }
        }
      }
    }

    // Germanium: semiconductor — conducts when hot
    if (el == El.germanium && temperature[idx] > 150 && charge[idx].abs() > 10) {
      conductElectricity(x, y);
    }

    if (checkTemperatureReaction(x, y, idx, el)) return;
    fallSolid(x, y, idx, el);
  }

  // =========================================================================
  // Nitrogen — inert gas, displaces oxygen, extinguishes fire
  // =========================================================================
  void simNitrogen(int x, int y, int idx) {
    final w = gridW;

    // Nitrogen is inert — main interaction is displacing oxygen and smothering fire
    if (frameCount % 3 == 0) {
      for (int dy2 = -1; dy2 <= 1; dy2++) {
        for (int dx2 = -1; dx2 <= 1; dx2++) {
          if (dx2 == 0 && dy2 == 0) continue;
          final nx = wrapX(x + dx2); final ny = y + dy2;
          if (!inBoundsY(ny)) continue;
          final ni = ny * w + nx;
          final neighbor = grid[ni];
          // Displace oxygen
          if (neighbor == El.oxygen && rng.nextInt(6) == 0) {
            swap(idx, ni);
            return;
          }
          // Extinguish fire by consuming adjacent oxygen
          if (neighbor == El.fire) {
            for (int fy = -1; fy <= 1; fy++) {
              for (int fx = -1; fx <= 1; fx++) {
                final ox = wrapX(x + fx); final oy = y + fy;
                if (!inBoundsY(oy)) continue;
                final oi = oy * w + ox;
                if (grid[oi] == El.oxygen && rng.nextInt(4) == 0) {
                  grid[oi] = El.nitrogen; markDirty(ox, oy);
                  grid[ni] = El.smoke; markDirty(nx, ny);
                  return;
                }
              }
            }
          }
        }
      }
    }

    // Rise as gas
    final uy = y - gravityDir;
    if (inBoundsY(uy) && grid[uy * w + x] == El.empty) {
      swap(idx, uy * w + x);
    } else if (rng.nextInt(2) == 0) {
      final dir = rng.nextBool() ? 1 : -1;
      final sx = wrapX(x + dir);
      if (grid[y * w + sx] == El.empty) {
        swap(idx, y * w + sx);
      }
    }
  }

  // =========================================================================
  // Carbon (Diamond) — hardest material, inert solid
  // =========================================================================
  void simCarbon(int x, int y, int idx) {
    fallSolid(x, y, idx, El.carbon);
  }

  // =========================================================================
  // Selenium — photosensitive, conductivity varies with light
  // =========================================================================
  void simSelenium(int x, int y, int idx) {
    final lum = luminance[idx];
    if (lum > 80 && charge[idx].abs() > 5) {
      conductElectricity(x, y);
    }
    if (temperature[idx] > 160) {
      for (int dy2 = -1; dy2 <= 1; dy2++) {
        for (int dx2 = -1; dx2 <= 1; dx2++) {
          if (dx2 == 0 && dy2 == 0) continue;
          final nx = wrapX(x + dx2); final ny = y + dy2;
          if (!inBoundsY(ny)) continue;
          final ni = ny * gridW + nx;
          if ((elCategory[grid[ni]] & ElCat.organic) != 0 && rng.nextInt(15) == 0) {
            life[ni] = (life[ni] - 2).clamp(0, 255);
          }
        }
      }
    }
    if (checkTemperatureReaction(x, y, idx, El.selenium)) return;
    fallSolid(x, y, idx, El.selenium);
  }
}

// ---------------------------------------------------------------------------
// Top-level dispatch function
// ---------------------------------------------------------------------------

///
/// Built-in elements are dispatched via a switch for maximum performance.
/// Custom elements (registered at runtime) are dispatched through the
/// [ElementRegistry.customBehaviors] function table.
void simulateElement(SimulationEngine e, int el, int x, int y, int idx) {
  // Rigid Body Fast-Path: If updateChunks() marked this solid pixel as falling,
  // bypass normal behavior to ensure the chunk falls together cohesively.
  if (e.velY[idx] > 0) {
    if (el == El.wood || el == El.stone || el == El.metal || el == El.glass) {
      final by = y + e.gravityDir;
      if (e.inBoundsY(by) && e.grid[by * e.gridW + x] == El.empty) {
        e.swap(idx, by * e.gridW + x);
        return; // Skip normal simulation for falling chunks
      } else {
        // Hit something, stop chunk momentum
        e.velY[idx] = 0;
      }
    }
  }

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
    case El.oxygen: e.simOxygen(x, y, idx);
    case El.co2: e.simCO2(x, y, idx);
    case El.fungus: e.simFungus(x, y, idx);
    case El.spore: e.simSpore(x, y, idx);
    case El.charcoal: e.simCharcoal(x, y, idx);
    case El.compost: e.simCompost(x, y, idx);
    case El.rust: e.simRust(x, y, idx);
    case El.methane: e.simMethane(x, y, idx);
    case El.salt: e.simSalt(x, y, idx);
    case El.clay: e.simClay(x, y, idx);
    case El.algae: e.simAlgae(x, y, idx);
    case El.honey: e.simHoney(x, y, idx);
    case El.hydrogen: e.simHydrogen(x, y, idx);
    case El.sulfur: e.simSulfur(x, y, idx);
    case El.copper: e.simCopper(x, y, idx);
    case El.web: e.simWeb(x, y, idx);
    case El.seaweed: e.simSeaweed(x, y, idx);
    case El.moss: e.simMoss(x, y, idx);
    case El.vine: e.simNeuralVine(x, y, idx);
    case El.flower: e.simNeuralFlower(x, y, idx);
    case El.root: e.simRoot(x, y, idx);
    case El.thorn: e.simThorn(x, y, idx);
    case El.c4: e.simC4(x, y, idx);
    case El.uranium: e.simUranium(x, y, idx);
    case El.lead: e.simLead(x, y, idx);
    case El.vapor: e.simVapor(x, y, idx);
    case El.cloud: e.simCloud(x, y, idx);
    case El.silicon: e.simSilicon(x, y, idx);
    // -- Periodic Table: Family dispatch --
    // Noble gases: inert with gas discharge glow, density stratification
    case El.helium: case El.neon: case El.argon:
    case El.krypton: case El.xenon:
      e.simNobleGas(x, y, idx);
    case El.radon: e.simRadioactive(x, y, idx);
    case El.lithium: case El.sodium: case El.potassium:
    case El.rubidium: case El.cesium: case El.francium:
      e.simAlkaliMetal(x, y, idx);
    // Alkaline earth metals: moderate water reaction, flame colors
    case El.beryllium: case El.magnesium: case El.calcium:
    case El.strontium: case El.barium:
      e.simAlkalineEarth(x, y, idx);
    // Transition metals with unique behaviors
    case El.gold: case El.silver: case El.tungsten:
    case El.zinc: case El.platinum: case El.chromium:
      e.simTransitionMetal(x, y, idx);
    case El.mercury: e.simLiquidMetal(x, y, idx);
    case El.fluorine: case El.chlorine:
      e.simHalogenGas(x, y, idx);
    case El.phosphorus: e.simPhosphorus(x, y, idx);
    // Post-transition metals
    case El.aluminum: case El.gallium: case El.indium:
    case El.tin: case El.thallium: case El.bismuth:
      e.simPostTransition(x, y, idx);
    // Metalloids (silicon has its own dispatch above)
    case El.boron: case El.germanium: case El.arsenic:
    case El.antimony: case El.tellurium:
      e.simMetalloid(x, y, idx);
    // Nonmetals
    case El.nitrogen: e.simNitrogen(x, y, idx);
    case El.carbon: e.simCarbon(x, y, idx);
    case El.selenium: e.simSelenium(x, y, idx);
    // Actinides / radioactives
    case El.thorium: case El.plutonium:
    case El.radium: case El.americium:
      e.simRadioactive(x, y, idx);
    default:
      // Custom element: look up registered behavior function.
      final fn = ElementRegistry.customBehaviors[el];
      if (fn != null) {
        fn(e, x, y, idx);
      } else {
        // No custom behavior — try data-driven reactions from the registry.
        ReactionRegistry.executeReactions(e, el, x, y, idx);
      }
      // UNIVERSAL GRAVITY: every element obeys gravity unless it's a static
      // solid with structural support, a gas (rises instead), or gravity=0.
      // This prevents ANY element from floating in mid-air.
      final grav = elementGravity[el];
      if (grav != 0) {
        final state = elementProperties[el].state;
        if (state == PhysicsState.granular || state == PhysicsState.powder) {
          e.fallGranular(x, y, idx, el);
        } else if (state == PhysicsState.liquid) {
          // Liquid: fall through empty or gas
          final by = y + e.gravityDir;
          if (e.inBoundsY(by) && e.isEmptyOrGas(e.grid[by * e.gridW + x])) {
            e.swap(idx, by * e.gridW + x);
          }
        } else if (grav < 0) {
          // Gas: rise through empty, buoy through heavier gas
          final uy = y - e.gravityDir;
          if (e.inBoundsY(uy)) {
            final aboveEl = e.grid[uy * e.gridW + x];
            if (aboveEl == El.empty) {
              e.swap(idx, uy * e.gridW + x);
            } else if (elementPhysicsState[aboveEl] == PhysicsState.gas.index &&
                       elementDensity[aboveEl] > elementDensity[el]) {
              e.swap(idx, uy * e.gridW + x);
            }
          }
          // Lateral drift when can't rise
          if (e.grid[idx] == el && e.rng.nextInt(2) == 0) {
            final dir = e.rng.nextBool() ? 1 : -1;
            final nx = e.wrapX(x + dir);
            if (e.grid[y * e.gridW + nx] == El.empty) {
              e.swap(idx, y * e.gridW + nx);
            }
          }
        } else if (grav > 0 && state == PhysicsState.gas) {
          // Heavy gas: sink through empty or lighter gas
          e.tryDensityDisplace(x, y, idx, el);
          if (e.grid[idx] == el) {
            final by = y + e.gravityDir;
            if (e.inBoundsY(by) && e.isEmptyOrGas(e.grid[by * e.gridW + x])) {
              e.swap(idx, by * e.gridW + x);
            }
          }
        }
        // Solids with grav > 0 but no support: fall
        else if (state == PhysicsState.solid || state == PhysicsState.special) {
          e.fallSolid(x, y, idx, el);
        }
      }
  }
}
