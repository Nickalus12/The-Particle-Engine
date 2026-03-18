import '../lib/simulation/element_registry.dart';
import '../lib/simulation/simulation_engine.dart';
import '../lib/simulation/element_behaviors.dart';
import '../lib/simulation/reactions/reaction_registry.dart';

void _simulateElement(SimulationEngine e, int el, int x, int y, int idx) {
  simulateElement(e, el, x, y, idx);
}

void _step(SimulationEngine e, [int frames = 1]) {
  for (int i = 0; i < frames; i++) {
    e.markAllDirty();
    e.step(_simulateElement);
  }
}

void main() {
  ElementRegistry.init();
  ReactionRegistry.init();
  final e = SimulationEngine(gridW: 30, gridH: 20);

  // Sealed stone box
  for (int x = 3; x <= 27; x++) {
    e.grid[3 * e.gridW + x] = El.stone;
    e.grid[17 * e.gridW + x] = El.stone;
  }
  for (int y = 3; y <= 17; y++) {
    e.grid[y * e.gridW + 3] = El.stone;
    e.grid[y * e.gridW + 27] = El.stone;
  }

  // Left half: hot stone (temp=220)
  for (int y = 4; y <= 16; y++) {
    for (int x = 4; x <= 14; x++) {
      e.grid[y * e.gridW + x] = El.stone;
      e.temperature[y * e.gridW + x] = 220;
    }
  }
  // Right half: cold stone (temp=36)
  for (int y = 4; y <= 16; y++) {
    for (int x = 15; x <= 26; x++) {
      e.grid[y * e.gridW + x] = El.stone;
      e.temperature[y * e.gridW + x] = 36;
    }
  }
  e.markAllDirty();

  // Track total energy across ALL stone cells in the box
  int totalInterior() {
    int sum = 0;
    for (int y = 4; y <= 16; y++) {
      for (int x = 4; x <= 26; x++) {
        sum += e.temperature[y * e.gridW + x];
      }
    }
    return sum;
  }

  int totalAll() {
    int sum = 0;
    for (int y = 3; y <= 17; y++) {
      for (int x = 3; x <= 27; x++) {
        sum += e.temperature[y * e.gridW + x];
      }
    }
    return sum;
  }

  int totalEntireGrid() {
    int sum = 0;
    for (int i = 0; i < e.grid.length; i++) {
      sum += e.temperature[i];
    }
    return sum;
  }

  print('Frame\tInterior\tAll-box\t\tEntire-grid');
  print('0\t${totalInterior()}\t\t${totalAll()}\t\t${totalEntireGrid()}');

  for (int f = 0; f < 600; f++) {
    e.markAllDirty();
    e.step(_simulateElement);
    if (f % 50 == 49) {
      print('${f + 1}\t${totalInterior()}\t\t${totalAll()}\t\t${totalEntireGrid()}');
    }
  }

  // Measure final state
  int minT = 255, maxT = 0;
  double sumT = 0;
  int count = 0;
  for (int y = 5; y <= 15; y++) {
    for (int x = 5; x <= 25; x++) {
      final t = e.temperature[y * e.gridW + x];
      if (t < minT) minT = t;
      if (t > maxT) maxT = t;
      sumT += t;
      count++;
    }
  }
  print('\nMeasured area (y=5-15, x=5-25):');
  print('  avg=${(sumT / count).toStringAsFixed(1)}, range=$minT..$maxT');
  print('  count=$count');
}
