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
  final e = SimulationEngine(gridW: 30, gridH: 50);

  // Tall column (30 cells, x=5..10)
  for (int y = 5; y <= 45; y++) {
    e.grid[y * e.gridW + 4] = El.stone;
    e.grid[y * e.gridW + 11] = El.stone;
  }
  for (int x = 4; x <= 11; x++) {
    e.grid[45 * e.gridW + x] = El.stone;
  }
  for (int y = 15; y <= 44; y++) {
    for (int x = 5; x <= 10; x++) {
      e.grid[y * e.gridW + x] = El.water;
      e.life[y * e.gridW + x] = 100;
    }
  }

  // Short column (10 cells, x=18..23)
  for (int y = 5; y <= 45; y++) {
    e.grid[y * e.gridW + 17] = El.stone;
    e.grid[y * e.gridW + 24] = El.stone;
  }
  for (int x = 17; x <= 24; x++) {
    e.grid[45 * e.gridW + x] = El.stone;
  }
  for (int y = 35; y <= 44; y++) {
    for (int x = 18; x <= 23; x++) {
      e.grid[y * e.gridW + x] = El.water;
      e.life[y * e.gridW + x] = 100;
    }
  }

  e.markAllDirty();

  // Force initial pressure update
  e.updatePressure();
  print('=== BEFORE STEPPING ===');
  print('Pressure at (44,7): ${e.pressure[44 * 30 + 7]}');
  print('Pressure at (44,20): ${e.pressure[44 * 30 + 20]}');

  // Count water in columns before
  int tallWater = 0;
  for (int y = 0; y < 50; y++) {
    if (e.grid[y * 30 + 7] == El.water) tallWater++;
  }
  int shortWater = 0;
  for (int y = 0; y < 50; y++) {
    if (e.grid[y * 30 + 20] == El.water) shortWater++;
  }
  print('Water cells in x=7: $tallWater, x=20: $shortWater');

  _step(e, 20);

  print('\n=== AFTER 20 STEPS ===');
  print('Grid at (44,7): element=${e.grid[44 * 30 + 7]}');
  print('Grid at (44,20): element=${e.grid[44 * 30 + 20]}');
  print('Pressure at (44,7): ${e.pressure[44 * 30 + 7]}');
  print('Pressure at (44,20): ${e.pressure[44 * 30 + 20]}');

  tallWater = 0;
  for (int y = 0; y < 50; y++) {
    if (e.grid[y * 30 + 7] == El.water) tallWater++;
  }
  shortWater = 0;
  for (int y = 0; y < 50; y++) {
    if (e.grid[y * 30 + 20] == El.water) shortWater++;
  }
  print('Water cells in x=7: $tallWater, x=20: $shortWater');

  // Print pressure for every water cell in x=7 column
  print('\nTall column (x=7) after stepping:');
  for (int y = 0; y < 50; y++) {
    final el = e.grid[y * 30 + 7];
    final p = e.pressure[y * 30 + 7];
    if (el != 0) print('  y=$y: el=$el pressure=$p');
  }

  print('\nShort column (x=20) after stepping:');
  for (int y = 0; y < 50; y++) {
    final el = e.grid[y * 30 + 20];
    final p = e.pressure[y * 30 + 20];
    if (el != 0) print('  y=$y: el=$el pressure=$p');
  }

  // Also check total water in entire grid
  int totalWater = 0;
  for (int i = 0; i < e.grid.length; i++) {
    if (e.grid[i] == El.water) totalWater++;
  }
  print('\nTotal water in grid: $totalWater');

  // Check for steam
  int totalSteam = 0;
  for (int i = 0; i < e.grid.length; i++) {
    if (e.grid[i] == El.steam) totalSteam++;
  }
  print('Total steam in grid: $totalSteam');
}
