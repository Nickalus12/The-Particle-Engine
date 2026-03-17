import '../simulation/element_registry.dart';
import '../simulation/simulation_engine.dart';
import '../utils/math_helpers.dart';

/// Handles ant interactions with the physical terrain.
///
/// Ants can dig through soft materials (dirt, sand), build structures
/// (place dirt to create bridges/chambers), and interact with the
/// cellular automaton simulation.
class AntTerrain {
  AntTerrain._();

  // ---------------------------------------------------------------------------
  // Digging
  // ---------------------------------------------------------------------------

  /// Materials that ants can dig through.
  static bool canDig(int elType) {
    return elType == El.dirt || elType == El.sand || elType == El.mud;
  }

  /// Try to dig a cell adjacent to the ant. Returns true if successful.
  static bool tryDig(
    SimulationEngine sim,
    int antX,
    int antY,
    int targetX,
    int targetY,
  ) {
    targetX = sim.wrapX(targetX);
    if (!sim.inBoundsY(targetY)) return false;

    final idx = targetY * sim.gridW + targetX;
    final element = sim.grid[idx];
    if (!canDig(element)) return false;

    // Digging chance: sand 80%, dirt 50%, mud 60%.
    final chance = element == El.sand ? 0.80 : (element == El.mud ? 0.60 : 0.50);
    if (!MathHelpers.chance(chance)) return false;

    sim.grid[idx] = El.empty;
    sim.life[idx] = 0;
    sim.markDirty(targetX, targetY);
    return true;
  }

  /// Dig toward a target direction.
  static bool digToward(
    SimulationEngine sim,
    int antX,
    int antY,
    int dx,
    int dy,
  ) {
    final targetX = antX + dx;
    final targetY = antY + dy;

    if (tryDig(sim, antX, antY, targetX, targetY)) return true;

    // If going horizontal and blocked, try digging one cell up too.
    if (dy == 0 && dx != 0) {
      return tryDig(sim, antX, antY, targetX, antY - 1);
    }

    return false;
  }

  // ---------------------------------------------------------------------------
  // Building
  // ---------------------------------------------------------------------------

  /// Try to place a dirt block adjacent to the ant.
  static bool tryBuild(
    SimulationEngine sim,
    int antX,
    int antY,
    int targetX,
    int targetY,
  ) {
    targetX = sim.wrapX(targetX);
    if (!sim.inBoundsY(targetY)) return false;

    final idx = targetY * sim.gridW + targetX;
    if (sim.grid[idx] != El.empty) return false;

    sim.grid[idx] = El.dirt;
    sim.life[idx] = 0;
    sim.markDirty(targetX, targetY);
    return true;
  }

  /// Build a floor below the ant.
  static bool buildFloor(SimulationEngine sim, int antX, int antY) {
    return tryBuild(sim, antX, antY, antX, antY + 1);
  }

  /// Build a wall next to the ant.
  static bool buildWall(SimulationEngine sim, int antX, int antY, int dx) {
    return tryBuild(sim, antX, antY, antX + dx, antY);
  }

  // ---------------------------------------------------------------------------
  // Terrain queries
  // ---------------------------------------------------------------------------

  /// Count how many diggable cells surround a position.
  static int diggableSurroundings(SimulationEngine sim, int x, int y) {
    int count = 0;
    for (final (dx, dy) in const [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
      final nx = sim.wrapX(x + dx);
      final ny = y + dy;
      if (sim.inBoundsY(ny) && canDig(sim.grid[ny * sim.gridW + nx])) {
        count++;
      }
    }
    return count;
  }

  /// Whether the ant is underground (surrounded by solid on 3+ sides).
  static bool isUnderground(SimulationEngine sim, int x, int y) {
    int solidCount = 0;
    for (final (dx, dy) in const [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
      final nx = sim.wrapX(x + dx);
      final ny = y + dy;
      if (!sim.inBoundsY(ny)) {
        solidCount++;
        continue;
      }
      final el = sim.grid[ny * sim.gridW + nx];
      if (el != El.empty && el != El.water && el != El.smoke && el != El.steam) {
        solidCount++;
      }
    }
    return solidCount >= 3;
  }

  /// Whether there's open sky above a position.
  static bool hasSkyAbove(SimulationEngine sim, int x, int y) {
    int emptyCount = 0;
    for (var checkY = y - 1; checkY >= 0 && checkY >= y - 10; checkY--) {
      if (!sim.inBoundsY(checkY)) break;
      if (sim.grid[checkY * sim.gridW + x] == El.empty) {
        emptyCount++;
      } else {
        break;
      }
    }
    return emptyCount >= 5;
  }

  /// Find the ground level at a given X coordinate.
  static int groundLevel(SimulationEngine sim, int x) {
    for (var y = 0; y < sim.gridH; y++) {
      if (!sim.inBoundsY(y)) continue;
      final el = sim.grid[y * sim.gridW + x];
      if (el != El.empty && el != El.water && el != El.smoke && el != El.steam) {
        return y;
      }
    }
    return sim.gridH;
  }
}
