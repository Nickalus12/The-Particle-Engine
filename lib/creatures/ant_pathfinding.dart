import 'dart:math';

import '../simulation/element_registry.dart';
import '../simulation/simulation_engine.dart';

/// Lightweight pathfinding and terrain analysis for ants.
///
/// Full A* is too expensive for hundreds of ants each tick. Instead we use
/// gradient-based steering: the neural network outputs a desired direction,
/// and this module adjusts it based on terrain obstacles within a short
/// look-ahead distance.
class AntPathfinding {
  AntPathfinding._();

  /// Find the best passable cell in the desired direction.
  static (int, int)? findBestMove(
    SimulationEngine sim,
    int fromX,
    int fromY,
    int desiredDx,
    int desiredDy,
  ) {
    final candidates = _moveCandidates(desiredDx, desiredDy);

    for (final (cdx, cdy) in candidates) {
      final tx = sim.wrapX(fromX + cdx);
      final ty = fromY + cdy;
      if (!sim.inBoundsY(ty)) continue;

      if (_canWalkThrough(sim.grid[ty * sim.gridW + tx])) {
        if (_hasGround(sim, tx, ty)) {
          return (tx, ty);
        }
      }
    }

    return null;
  }

  static List<(int, int)> _moveCandidates(int dx, int dy) {
    final candidates = <(int, int)>[];

    if (dx != 0 || dy != 0) candidates.add((dx, dy));

    if (dx != 0 && dy != 0) {
      candidates.add((dx, 0));
      candidates.add((0, dy));
    } else if (dx != 0) {
      candidates.add((dx, -1));
      candidates.add((dx, 1));
    } else if (dy != 0) {
      candidates.add((-1, dy));
      candidates.add((1, dy));
    }

    for (var mdy = -1; mdy <= 1; mdy++) {
      for (var mdx = -1; mdx <= 1; mdx++) {
        if (mdx == 0 && mdy == 0) continue;
        final pair = (mdx, mdy);
        if (!candidates.contains(pair)) candidates.add(pair);
      }
    }

    return candidates;
  }

  static bool _canWalkThrough(int elType) {
    return elType == El.empty ||
        elType == El.water ||
        elType == El.smoke ||
        elType == El.steam;
  }

  static bool _hasGround(SimulationEngine sim, int x, int y) {
    if (y >= sim.gridH - 1) return true;
    final below = sim.grid[(y + 1) * sim.gridW + x];
    return below != El.empty && below != El.smoke && below != El.steam;
  }

  /// Scan the surrounding area and return a "terrain quality" score.
  static double terrainQuality(SimulationEngine sim, int x, int y, int radius) {
    int passable = 0;
    int total = 0;

    for (var dy = -radius; dy <= radius; dy++) {
      for (var dx = -radius; dx <= radius; dx++) {
        final nx = sim.wrapX(x + dx);
        final ny = y + dy;
        if (!sim.inBoundsY(ny)) continue;
        total++;
        if (_canWalkThrough(sim.grid[ny * sim.gridW + nx])) passable++;
      }
    }

    return total > 0 ? passable / total : 0.0;
  }

  /// Find the nearest food element within a given radius.
  static (int, int, int)? findNearestFood(
    SimulationEngine sim,
    int fromX,
    int fromY,
    int radius,
  ) {
    int? bestX, bestY;
    int bestDist = radius * 2 + 1;
    final w = sim.gridW;
    final g = sim.grid;

    for (var dy = -radius; dy <= radius; dy++) {
      for (var dx = -radius; dx <= radius; dx++) {
        final nx = sim.wrapX(fromX + dx);
        final ny = fromY + dy;
        if (!sim.inBoundsY(ny)) continue;
        final el = g[ny * w + nx];
        if (el != El.empty && el < maxElements &&
            (elCategory[el] & ElCat.organic != 0) &&
            (elCategory[el] & ElCat.flammable != 0)) {
          final dist = dx.abs() + dy.abs();
          if (dist < bestDist) {
            bestX = nx;
            bestY = ny;
            bestDist = dist;
          }
        }
      }
    }

    if (bestX != null && bestY != null) {
      return (bestX, bestY, bestDist);
    }
    return null;
  }

  /// Check if a straight-line path between two points is mostly clear.
  static double pathClearance(
    SimulationEngine sim,
    int x1,
    int y1,
    int x2,
    int y2,
  ) {
    final dx = (x2 - x1).abs();
    final dy = (y2 - y1).abs();
    final steps = max(dx, dy);
    if (steps == 0) return 1.0;

    int passable = 0;
    for (var i = 0; i <= steps; i++) {
      final t = steps > 0 ? i / steps : 0.0;
      final px = x1 + ((x2 - x1) * t).round();
      final py = y1 + ((y2 - y1) * t).round();
      if (sim.inBoundsY(py) && _canWalkThrough(sim.grid[py * sim.gridW + sim.wrapX(px)])) {
        passable++;
      }
    }

    return passable / (steps + 1);
  }
}
