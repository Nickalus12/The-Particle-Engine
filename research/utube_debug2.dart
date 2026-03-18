import 'dart:io';

import '../lib/simulation/element_registry.dart';
import '../lib/simulation/simulation_engine.dart';
import '../lib/simulation/element_behaviors.dart';
import '../lib/simulation/reactions/reaction_registry.dart';

void _simulateElement(SimulationEngine e, int el, int x, int y, int idx) {
  final custom = ElementRegistry.customBehaviors[el];
  if (custom != null) { custom(e, x, y, idx); return; }
  switch (el) {
    case El.sand: e.simSand(x, y, idx);
    case El.water: e.simWater(x, y, idx);
    case El.stone: e.simStone(x, y, idx);
    case El.oil: e.simOil(x, y, idx);
    case El.fire: e.simFire(x, y, idx);
    case El.smoke: e.simSmoke(x, y, idx);
    case El.steam: e.simSteam(x, y, idx);
  }
}

SimulationEngine _createEngine(int w, int h) {
  ElementRegistry.init();
  ReactionRegistry.init();
  final engine = SimulationEngine(gridW: w, gridH: h);
  engine.markAllDirty();
  return engine;
}

void main() {
  // Minimal U-tube: 2 columns connected at bottom
  final e = _createEngine(10, 20);

  // Left wall at x=1, right wall at x=8
  // Middle wall at x=4-5 from y=0 to y=13 (open at y=14..18)
  // Bottom at y=19

  for (int y = 0; y < 20; y++) {
    e.grid[y * e.gridW + 0] = El.stone; // left wall
    e.grid[y * e.gridW + 9] = El.stone; // right wall
  }
  for (int x = 0; x < 10; x++) {
    e.grid[19 * e.gridW + x] = El.stone; // floor
  }
  // Middle wall from y=0 to y=13
  for (int y = 0; y <= 13; y++) {
    e.grid[y * e.gridW + 4] = El.stone;
    e.grid[y * e.gridW + 5] = El.stone;
  }

  // Fill left arm with water (x=1..3, y=5..18)
  for (int y = 5; y <= 18; y++) {
    for (int x = 1; x <= 3; x++) {
      e.grid[y * e.gridW + x] = El.water;
      e.life[y * e.gridW + x] = 100;
    }
  }

  // Fill right arm with oil (x=6..8, y=5..18)
  for (int y = 5; y <= 18; y++) {
    for (int x = 6; x <= 8; x++) {
      e.grid[y * e.gridW + x] = El.oil;
    }
  }

  // Fill connector with water (x=4..5, y=14..18)
  for (int y = 14; y <= 18; y++) {
    for (int x = 4; x <= 5; x++) {
      e.grid[y * e.gridW + x] = El.water;
      e.life[y * e.gridW + x] = 100;
    }
  }

  e.markAllDirty();

  // Print initial grid
  stdout.writeln('Initial:');
  for (int y = 0; y < 20; y++) {
    final sb = StringBuffer();
    for (int x = 0; x < 10; x++) {
      final el = e.grid[y * 10 + x];
      sb.write(el == El.water ? 'W' : el == El.oil ? 'O' : el == El.stone ? '#' : '.');
    }
    stdout.writeln('  $y: ${sb.toString()}');
  }

  for (int frame = 10; frame <= 100; frame += 10) {
    for (int i = 0; i < 10; i++) {
      e.markAllDirty();
      e.step(_simulateElement);
    }

    // Count
    int leftW = 0, leftO = 0, rightW = 0, rightO = 0, connW = 0, connO = 0;
    for (int y = 0; y < 20; y++) {
      for (int x = 1; x <= 3; x++) {
        if (e.grid[y * 10 + x] == El.water) leftW++;
        if (e.grid[y * 10 + x] == El.oil) leftO++;
      }
      for (int x = 6; x <= 8; x++) {
        if (e.grid[y * 10 + x] == El.water) rightW++;
        if (e.grid[y * 10 + x] == El.oil) rightO++;
      }
      for (int x = 4; x <= 5; x++) {
        if (e.grid[y * 10 + x] == El.water) connW++;
        if (e.grid[y * 10 + x] == El.oil) connO++;
      }
    }
    stdout.writeln('f=$frame left:W=$leftW,O=$leftO  conn:W=$connW,O=$connO  right:W=$rightW,O=$rightO');
  }

  // Print final grid
  stdout.writeln('Final:');
  for (int y = 0; y < 20; y++) {
    final sb = StringBuffer();
    for (int x = 0; x < 10; x++) {
      final el = e.grid[y * 10 + x];
      sb.write(el == El.water ? 'W' : el == El.oil ? 'O' : el == El.stone ? '#' : '.');
    }
    stdout.writeln('  $y: ${sb.toString()}');
  }
}
