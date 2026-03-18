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
  final e = SimulationEngine(gridW: 30, gridH: 30);

  for (int x = 5; x < 25; x++) {
    e.grid[20 * e.gridW + x] = El.water;
    e.grid[21 * e.gridW + x] = El.lava;
    e.grid[22 * e.gridW + x] = El.lava;
  }
  e.markAllDirty();

  for (int f = 0; f < 80; f++) {
    e.markAllDirty();
    e.step(_simulateElement);

    int steam = 0, lava = 0, stone = 0, water = 0;
    int ventCandidates = 0;
    for (int y = 0; y < 30; y++) {
      for (int x = 0; x < 30; x++) {
        final i = y * e.gridW + x;
        if (e.grid[i] == El.steam) steam++;
        if (e.grid[i] == El.water) water++;
        if (e.grid[i] == El.stone) stone++;
        if (e.grid[i] == El.lava) {
          lava++;
          final uy = y - 1;
          if (uy >= 0 && e.grid[uy * e.gridW + x] == El.stone && e.temperature[i] > 140) {
            final uy2 = uy - 1;
            if (uy2 >= 0 && e.grid[uy2 * e.gridW + x] == El.empty) {
              ventCandidates++;
            }
          }
        }
      }
    }

    if (f < 5 || f % 10 == 9 || f == 79) {
      print('Frame ${f+1}: steam=$steam water=$water lava=$lava stone=$stone vent=$ventCandidates');
    }

    // Print grid at key frames
    if (f == 4 || f == 29 || f == 79) {
      for (int y = 18; y < 30; y++) {
        String row = 'y$y: ';
        for (int x = 3; x < 27; x++) {
          final el = e.grid[y * e.gridW + x];
          if (el == El.empty) row += '. ';
          else if (el == El.lava) row += 'L ';
          else if (el == El.stone) row += 'R ';
          else if (el == El.steam) row += 'S ';
          else if (el == El.water) row += 'W ';
          else if (el == El.fire) row += 'F ';
          else if (el == El.smoke) row += '~ ';
          else row += '? ';
        }
        print(row);
      }
    }
  }
}
