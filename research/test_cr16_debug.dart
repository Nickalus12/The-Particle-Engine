import '../lib/simulation/simulation_engine.dart';
import '../lib/simulation/element_registry.dart';
import '../lib/simulation/element_behaviors.dart';

void _simulateElement(SimulationEngine e, int el, int x, int y, int idx) {
  simulateElement(e, el, x, y, idx);
}

void main() {
  ElementRegistry.init();
  final e = SimulationEngine(gridW: 10, gridH: 10);
  e.markAllDirty();
  
  for (int x = 0; x < 10; x++) {
    e.grid[x] = El.stone;
    e.grid[9 * 10 + x] = El.stone;
  }
  for (int y = 0; y < 10; y++) {
    e.grid[y * 10] = El.stone;
    e.grid[y * 10 + 9] = El.stone;
  }
  e.grid[5 * 10 + 4] = El.sand;
  e.grid[5 * 10 + 5] = El.water;
  
  for (int frame = 0; frame < 20; frame++) {
    e.markAllDirty();
    e.step(_simulateElement);
    
    // Print grid row by row
    if (frame < 3 || frame == 19) {
      print('Frame ${frame+1}:');
      for (int y = 0; y < 10; y++) {
        final row = StringBuffer();
        for (int x = 0; x < 10; x++) {
          final el = e.grid[y * 10 + x];
          final c = el == El.stone ? '#' : el == El.sand ? 'S' : el == El.water ? 'W' : el == El.mud ? 'M' : el == El.empty ? '.' : '?';
          row.write(c);
        }
        print('  $row');
      }
    }
  }
}
