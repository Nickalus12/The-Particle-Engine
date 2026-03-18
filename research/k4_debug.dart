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
  final e = SimulationEngine(gridW: 20, gridH: 60);

  for (int y = 3; y < 8; y++) {
    e.grid[y * e.gridW + 10] = El.sand;
  }
  e.markAllDirty();

  for (int f = 0; f < 30; f++) {
    e.markAllDirty();
    e.step(_simulateElement);

    // Find all sand positions
    List<String> positions = [];
    for (int y = 0; y < 60; y++) {
      for (int x = 0; x < 20; x++) {
        if (e.grid[y * e.gridW + x] == El.sand) {
          positions.add('($x,$y)');
        }
      }
    }
    if (f < 10 || f == 29) {
      print('Frame ${f+1}: ${positions.join(' ')}');
    }
  }
}
