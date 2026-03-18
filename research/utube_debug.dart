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

void _step(SimulationEngine e, [int frames = 1]) {
  for (int i = 0; i < frames; i++) {
    e.markAllDirty();
    e.step(_simulateElement);
  }
}

void main() {
  final e = _createEngine(50, 50);

  // U-tube setup (from the test)
  for (int y = 5; y <= 45; y++) {
    e.grid[y * e.gridW + 4] = El.stone;
    e.grid[y * e.gridW + 16] = El.stone;
  }
  for (int y = 5; y <= 45; y++) {
    e.grid[y * e.gridW + 29] = El.stone;
    e.grid[y * e.gridW + 41] = El.stone;
  }
  for (int x = 4; x <= 41; x++) {
    e.grid[45 * e.gridW + x] = El.stone;
  }
  for (int y = 5; y <= 38; y++) {
    e.grid[y * e.gridW + 16] = El.stone;
    e.grid[y * e.gridW + 29] = El.stone;
  }
  for (int y = 39; y <= 44; y++) {
    for (int x = 16; x <= 29; x++) {
      e.grid[y * e.gridW + x] = El.empty;
    }
  }
  for (int y = 15; y <= 44; y++) {
    for (int x = 5; x <= 15; x++) {
      e.grid[y * e.gridW + x] = El.water;
      e.life[y * e.gridW + x] = 100;
    }
  }
  for (int y = 15; y <= 44; y++) {
    for (int x = 30; x <= 40; x++) {
      e.grid[y * e.gridW + x] = El.oil;
    }
  }
  for (int y = 39; y <= 44; y++) {
    for (int x = 16; x <= 29; x++) {
      e.grid[y * e.gridW + x] = El.water;
      e.life[y * e.gridW + x] = 100;
    }
  }

  e.markAllDirty();

  // Print initial state at key positions
  stdout.writeln('Initial: boundary x=29-31 at y=38..40');
  for (int y = 38; y <= 40; y++) {
    for (int x = 28; x <= 31; x++) {
      final el = e.grid[y * e.gridW + x];
      final name = el == El.water ? 'W' : el == El.oil ? 'O' : el == El.stone ? 'S' : el == El.empty ? '.' : '?';
      stdout.write('($x,$y)=$name ');
    }
    stdout.writeln();
  }

  // Run and observe
  for (int frame = 50; frame <= 500; frame += 50) {
    _step(e, 50);

    int waterLevel = 45, oilLevel = 45;
    for (int y = 5; y < 45; y++) {
      for (int x = 5; x <= 15; x++) {
        if (e.grid[y * e.gridW + x] == El.water && y < waterLevel) waterLevel = y;
      }
      for (int x = 30; x <= 40; x++) {
        if (e.grid[y * e.gridW + x] == El.oil && y < oilLevel) oilLevel = y;
      }
    }
    final waterH = 45 - waterLevel;
    final oilH = 45 - oilLevel;

    // Count water and oil in each arm
    int leftWater = 0, leftOil = 0, rightWater = 0, rightOil = 0;
    for (int y = 5; y <= 44; y++) {
      for (int x = 5; x <= 15; x++) {
        if (e.grid[y * e.gridW + x] == El.water) leftWater++;
        if (e.grid[y * e.gridW + x] == El.oil) leftOil++;
      }
      for (int x = 30; x <= 40; x++) {
        if (e.grid[y * e.gridW + x] == El.water) rightWater++;
        if (e.grid[y * e.gridW + x] == El.oil) rightOil++;
      }
    }
    stdout.writeln('f=$frame waterH=$waterH oilH=$oilH | left: W=$leftWater O=$leftOil | right: W=$rightWater O=$rightOil');
  }
}
