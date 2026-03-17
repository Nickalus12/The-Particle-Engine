import '../../simulation/element_registry.dart';
import '../../simulation/simulation_engine.dart';
import '../ant_terrain.dart';

/// Builder behaviour heuristics for ants with the builder role.
///
/// Builders modify the physical terrain to benefit the colony:
/// - Carve nest chambers underground.
/// - Build bridges over water/gaps.
/// - Create walls to redirect water flow away from the nest.
class BuilderBehavior {
  BuilderBehavior._();

  /// Suggest a build/dig action for a builder at (x, y).
  static BuildAction? suggestAction(
    SimulationEngine sim,
    int x,
    int y,
    int nestX,
    int nestY,
  ) {
    final distToNest = (x - nestX).abs() + (y - nestY).abs();

    if (distToNest <= 15) {
      return _suggestNestAction(sim, x, y, nestX, nestY);
    }

    return _suggestPathAction(sim, x, y);
  }

  static BuildAction? _suggestNestAction(
    SimulationEngine sim,
    int x,
    int y,
    int nestX,
    int nestY,
  ) {
    if (AntTerrain.isUnderground(sim, x, y)) {
      for (final (dx, dy) in const [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
        final nx = sim.wrapX(x + dx);
        final ny = y + dy;
        if (!sim.inBoundsY(ny)) continue;
        if (AntTerrain.canDig(sim.grid[ny * sim.gridW + nx])) {
          if (ny < y && _wouldCauseCaveIn(sim, nx, ny)) continue;
          return BuildAction(
            type: BuildActionType.dig,
            targetX: nx,
            targetY: ny,
          );
        }
      }
    }

    if (y + 1 < sim.gridH && sim.grid[(y + 1) * sim.gridW + x] == El.empty) {
      final belowNest = y > nestY;
      if (belowNest) {
        return BuildAction(
          type: BuildActionType.build,
          targetX: x,
          targetY: y + 1,
        );
      }
    }

    return null;
  }

  static bool _wouldCauseCaveIn(SimulationEngine sim, int x, int y) {
    int solidAbove = 0;
    for (var cy = y - 1; cy >= y - 3 && cy >= 0; cy--) {
      if (!sim.inBoundsY(cy)) break;
      final el = sim.grid[cy * sim.gridW + x];
      if (el == El.sand || el == El.dirt) {
        solidAbove++;
      } else {
        break;
      }
    }
    return solidAbove >= 2;
  }

  static BuildAction? _suggestPathAction(
    SimulationEngine sim,
    int x,
    int y,
  ) {
    if (y + 1 < sim.gridH && sim.grid[(y + 1) * sim.gridW + x] == El.empty) {
      return BuildAction(
        type: BuildActionType.build,
        targetX: x,
        targetY: y + 1,
      );
    }

    for (final dx in const [1, -1]) {
      final nx = sim.wrapX(x + dx);
      if (sim.inBoundsY(y) && AntTerrain.canDig(sim.grid[y * sim.gridW + nx])) {
        return BuildAction(
          type: BuildActionType.dig,
          targetX: nx,
          targetY: y,
        );
      }
    }

    return null;
  }

  /// Score how useful it would be to have a builder at this location.
  static double buildUtility(SimulationEngine sim, int x, int y) {
    final diggable = AntTerrain.diggableSurroundings(sim, x, y);
    final underground = AntTerrain.isUnderground(sim, x, y);
    double score = diggable * 0.25;
    if (underground) score += 0.5;
    return score.clamp(0.0, 1.0);
  }
}

enum BuildActionType { dig, build }

class BuildAction {
  const BuildAction({
    required this.type,
    required this.targetX,
    required this.targetY,
  });

  final BuildActionType type;
  final int targetX;
  final int targetY;
}
