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

  // Wood block
  for (int y = 10; y < 15; y++) {
    for (int x = 10; x < 15; x++) {
      e.grid[y * e.gridW + x] = El.wood;
    }
  }
  // Fire next to wood
  e.grid[10 * e.gridW + 9] = El.fire;
  e.markAllDirty();

  for (int f = 0; f < 200; f++) {
    e.markAllDirty();
    e.step(_simulateElement);
    if (f < 5 || f % 10 == 9) {
      // Track fire and wood
      int fire = 0, wood = 0, burning = 0, ash = 0;
      for (int i = 0; i < e.grid.length; i++) {
        if (e.grid[i] == El.fire) fire++;
        if (e.grid[i] == El.wood) {
          wood++;
          if (e.life[i] > 0) burning++;
        }
        if (e.grid[i] == El.ash) ash++;
      }
      // Wood temperature at edge
      final el1010 = e.grid[10 * e.gridW + 10];
      int woodTemp = el1010 == El.wood ? e.temperature[10 * e.gridW + 10] : -1;
      final life1010 = e.life[10 * e.gridW + 10];
      // Find fire positions
      String firePos = '';
      for (int y = 0; y < 30; y++) {
        for (int x = 0; x < 30; x++) {
          if (e.grid[y * e.gridW + x] == El.fire) firePos += '($x,$y) ';
        }
      }
      if (f < 5) {
        // Print 5x5 grid showing element type at wood block area
        for (int gy = 9; gy <= 15; gy++) {
          String row = 'y$gy: ';
          for (int gx = 9; gx <= 15; gx++) {
            final el = e.grid[gy * e.gridW + gx];
            final lf = e.life[gy * e.gridW + gx];
            if (el == El.wood && lf > 0) row += 'B ';
            else if (el == El.wood) row += 'W ';
            else if (el == El.fire) row += 'F ';
            else if (el == El.ash) row += 'A ';
            else if (el == El.empty) row += '. ';
            else if (el == El.smoke) row += 'S ';
            else row += '? ';
          }
          print(row);
        }
        print('Frame ${f+1}: fire=$fire wood=$wood burning=$burning ash=$ash');
        print('');
      }
      if (f % 10 == 9 || f == 199) print('Frame ${f+1}: fire=$fire wood=$wood burning=$burning ash=$ash');
    }
  }
}
