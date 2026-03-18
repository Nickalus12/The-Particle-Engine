import '../lib/simulation/simulation_engine.dart';
import '../lib/simulation/element_registry.dart';
import '../lib/simulation/element_behaviors.dart';

void _simulateElement(SimulationEngine e, int el, int x, int y, int idx) {
  simulateElement(e, el, x, y, idx);
}

void main() {
  ElementRegistry.init();
  final e = SimulationEngine(gridW: 20, gridH: 40);
  e.markAllDirty();
  
  for (int y = 10; y < 35; y++) {
    for (int x = 5; x < 15; x++) {
      e.grid[y * 20 + x] = El.water;
    }
  }
  for (int x = 4; x < 16; x++) e.grid[35 * 20 + x] = El.stone;
  for (int x = 7; x < 13; x++) e.grid[5 * 20 + x] = El.sand;
  
  for (int frame = 0; frame < 60; frame++) {
    e.markAllDirty();
    e.step(_simulateElement);
    
    if (frame % 10 == 9) {
      int sandCount = 0, sandBottom = 0;
      for (int i = 0; i < e.grid.length; i++) {
        if (e.grid[i] == El.sand) sandCount++;
      }
      for (int y = 30; y < 36; y++) {
        for (int x = 4; x < 16; x++) {
          if (e.grid[y * 20 + x] == El.sand) sandBottom++;
        }
      }
      print('F${frame+1}: totalSand=$sandCount sandNearBottom=$sandBottom');
    }
  }
}
