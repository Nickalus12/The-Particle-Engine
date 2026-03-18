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

  // PC6: Sand to Glass
  print('=== PC6: Sand to Glass ===');
  {
    final e = SimulationEngine(gridW: 20, gridH: 20);
    e.grid[10 * e.gridW + 10] = El.sand;
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        e.grid[(10 + dy) * e.gridW + (10 + dx)] = El.lava;
      }
    }
    e.markAllDirty();

    for (int f = 0; f < 200; f++) {
      e.markAllDirty();
      e.step(_simulateElement);
      if (f < 20 || f % 20 == 0) {
        // Find sand and report its temp
        for (int y = 0; y < 20; y++) {
          for (int x = 0; x < 20; x++) {
            if (e.grid[y * e.gridW + x] == El.sand) {
              print('Frame ${f+1}: sand at ($x,$y) temp=${e.temperature[y * e.gridW + x]}');
            }
            if (e.grid[y * e.gridW + x] == El.glass) {
              print('Frame ${f+1}: GLASS at ($x,$y)');
            }
          }
        }
      }
    }
    int glass = 0;
    for (int i = 0; i < e.grid.length; i++) {
      if (e.grid[i] == El.glass) glass++;
    }
    print('Final glass count: $glass');
  }

  // PC5: Freezing Chain
  print('\n=== PC5: Freezing Chain ===');
  {
    final e = SimulationEngine(gridW: 20, gridH: 20);
    for (int x = 10; x < 18; x++) {
      e.grid[10 * e.gridW + x] = El.water;
    }
    e.grid[10 * e.gridW + 9] = El.ice;
    for (int x = 9; x < 19; x++) {
      e.grid[11 * e.gridW + x] = El.stone;
    }
    e.markAllDirty();

    for (int f = 0; f < 100; f++) {
      e.markAllDirty();
      e.step(_simulateElement);
      if (f < 30 || f % 10 == 9) {
        int ice = 0;
        for (int y = 0; y < 20; y++) {
          for (int x = 0; x < 20; x++) {
            if (e.grid[y * e.gridW + x] == El.ice) ice++;
          }
        }
        // Print what's at x=9
        String r10 = '';
        for (int x = 8; x < 19; x++) {
          final el = e.grid[10 * e.gridW + x];
          if (el == El.ice) r10 += 'I';
          else if (el == El.water) r10 += 'W';
          else if (el == El.empty) r10 += '.';
          else if (el == El.stone) r10 += 'S';
          else r10 += '${el}';
        }
        // Also check rows 9 and 12
        String r9 = '';
        for (int x = 8; x < 19; x++) {
          final el = e.grid[9 * e.gridW + x];
          if (el == El.ice) r9 += 'I';
          else if (el == El.water) r9 += 'W';
          else if (el == El.empty) r9 += '.';
          else r9 += '?';
        }
        // Find all ice positions
        String icePos = '';
        for (int y = 0; y < 20; y++) {
          for (int x = 0; x < 20; x++) {
            if (e.grid[y * e.gridW + x] == El.ice) {
              icePos += '($x,$y) ';
            }
          }
        }
        print('Frame ${f+1}: ice=$ice at=$icePos');
      }
    }
  }
}
