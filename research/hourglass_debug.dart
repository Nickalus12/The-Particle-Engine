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

int _measureHourglassFlow(int openingWidth) {
  final e = _createEngine(30, 50);
  for (int y = 5; y <= 45; y++) {
    e.grid[y * e.gridW + 5] = El.stone;
    e.grid[y * e.gridW + 25] = El.stone;
  }
  for (int x = 5; x <= 25; x++) {
    e.grid[25 * e.gridW + x] = El.stone;
  }
  final center = 15;
  for (int ox = center; ox < center + openingWidth; ox++) {
    e.grid[25 * e.gridW + ox] = El.empty;
  }
  for (int y = 6; y <= 24; y++) {
    for (int x = 6; x <= 24; x++) {
      e.grid[y * e.gridW + x] = El.sand;
    }
  }
  e.markAllDirty();

  for (int frame = 10; frame <= 100; frame += 10) {
    _step(e, 10);
    int bottomSand = 0;
    for (int y = 26; y <= 44; y++) {
      for (int x = 6; x <= 24; x++) {
        if (e.grid[y * e.gridW + x] == El.sand) bottomSand++;
      }
    }
    int topSand = 0;
    for (int y = 6; y <= 24; y++) {
      for (int x = 6; x <= 24; x++) {
        if (e.grid[y * e.gridW + x] == El.sand) topSand++;
      }
    }
    stdout.writeln('  width=$openingWidth frame=$frame top=$topSand bottom=$bottomSand');
  }

  int bottomSand = 0;
  for (int y = 26; y <= 44; y++) {
    for (int x = 6; x <= 24; x++) {
      if (e.grid[y * e.gridW + x] == El.sand) bottomSand++;
    }
  }
  return bottomSand;
}

void main() {
  stdout.writeln('=== 1-cell opening ===');
  final f1 = _measureHourglassFlow(1);
  stdout.writeln('=== 3-cell opening ===');
  final f3 = _measureHourglassFlow(3);
  stdout.writeln('Result: 1-cell=$f1, 3-cell=$f3');
}
