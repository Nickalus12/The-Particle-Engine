import '../lib/simulation/element_registry.dart';
import '../lib/simulation/simulation_engine.dart';
import '../lib/simulation/element_behaviors.dart';
import '../lib/simulation/reactions/reaction_registry.dart';

void _simulateElement(SimulationEngine e, int el, int x, int y, int idx) {
  simulateElement(e, el, x, y, idx);
}

void main() {
  ElementRegistry.init();
  ReactionRegistry.init();
  final e = SimulationEngine(gridW: 40, gridH: 50);

  // Stone floor
  for (int x = 0; x < 40; x++) {
    e.grid[45 * e.gridW + x] = El.stone;
  }

  // Narrow stone shelf at y=25 (x=15..25)
  for (int x = 15; x <= 25; x++) {
    e.grid[25 * e.gridW + x] = El.stone;
  }

  // Sand piled on shelf (y=10..24, x=16..24)
  for (int y = 10; y <= 24; y++) {
    for (int x = 16; x <= 24; x++) {
      e.grid[y * e.gridW + x] = El.sand;
    }
  }

  e.markAllDirty();
  for (int i = 0; i < 10; i++) {
    e.markAllDirty();
    e.step(_simulateElement);
  }

  // Remove shelf
  for (int x = 15; x <= 25; x++) {
    e.grid[25 * e.gridW + x] = El.empty;
  }
  e.markAllDirty();

  // Count sand positions per frame
  for (int frame = 0; frame < 60; frame++) {
    e.markAllDirty();
    e.step(_simulateElement);

    int highCount = 0;
    int highestY = 50;
    int totalSand = 0;
    for (int y = 0; y < 50; y++) {
      for (int x = 0; x < 40; x++) {
        if (e.grid[y * e.gridW + x] == El.sand) {
          totalSand++;
          if (y <= 35) highCount++;
          if (y < highestY) highestY = y;
        }
      }
    }
    if (highCount > 0 && highCount <= 5) {
      // Print positions of stuck grains
      for (int y = 0; y <= 35; y++) {
        for (int x = 0; x < 40; x++) {
          if (e.grid[y * e.gridW + x] == El.sand) {
            final jammed = e.velX[y * e.gridW + x] == 127;
            print('  Frame ${frame+1}: sand at ($x,$y) velY=${e.velY[y*e.gridW+x]} velX=${e.velX[y*e.gridW+x]} jammed=$jammed');
          }
        }
      }
    }
    if (highCount == 0) {
      print('All sand below y=35 at frame ${frame + 1}');
      break;
    }
    if (frame == 59 && highCount > 0) {
      print('STUCK after 60 frames: $highCount grains above y=35');
    }
  }
}
