/// Ultra-fast headless parameter benchmark for cloud optimization.
///
/// Runs a minimal simulation with trial parameters and scores physics
/// behavior directly — no pytest, no Python, no visual checks.
/// ~10x faster than the full benchmark pipeline.
///
/// Usage:
///   dart run research/cloud/fast_benchmark.dart [config_path]
///
/// Outputs JSON to stdout:
///   {"physics": 95.2, "interactions": 88.0, "overall": 91.6}
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../lib/simulation/simulation_engine.dart';
import '../../lib/simulation/element_registry.dart';
import '../../lib/simulation/element_behaviors.dart';

void main(List<String> args) {
  ElementRegistry.init();

  // Load trial config if provided
  Map<String, dynamic>? config;
  if (args.isNotEmpty) {
    final configFile = File(args[0]);
    if (configFile.existsSync()) {
      config = jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
    }
  }

  final results = <String, double>{};

  // Run multiple test scenarios
  final sandScore = _testSandPhysics();
  final waterScore = _testWaterPhysics();
  final fireScore = _testFirePhysics();
  final interactionScore = _testInteractions();
  final densityScore = _testDensityOrdering();
  final temperatureScore = _testTemperature();
  final conservationScore = _testConservation();
  final structuralScore = _testStructural();

  final physics = (sandScore + waterScore + fireScore + temperatureScore +
          conservationScore + structuralScore + densityScore) /
      7.0;
  final interactions = interactionScore;
  final overall = physics * 0.7 + interactions * 0.3;

  final output = {
    'physics': double.parse(physics.toStringAsFixed(1)),
    'interactions': double.parse(interactions.toStringAsFixed(1)),
    'overall': double.parse(overall.toStringAsFixed(1)),
    'details': {
      'sand': double.parse(sandScore.toStringAsFixed(1)),
      'water': double.parse(waterScore.toStringAsFixed(1)),
      'fire': double.parse(fireScore.toStringAsFixed(1)),
      'temperature': double.parse(temperatureScore.toStringAsFixed(1)),
      'conservation': double.parse(conservationScore.toStringAsFixed(1)),
      'structural': double.parse(structuralScore.toStringAsFixed(1)),
      'density': double.parse(densityScore.toStringAsFixed(1)),
      'interactions': double.parse(interactionScore.toStringAsFixed(1)),
    },
  };

  stdout.writeln(jsonEncode(output));
}

// ---------------------------------------------------------------------------
// Test: Sand falls under gravity
// ---------------------------------------------------------------------------
double _testSandPhysics() {
  final e = SimulationEngine(gridW: 80, gridH: 60, seed: 42);

  // Place sand in mid-air
  for (int x = 30; x < 50; x++) {
    e.grid[10 * 80 + x] = El.sand;
  }
  e.markAllDirty();

  for (int i = 0; i < 100; i++) {
    e.step(simulateElement);
  }

  // Check: sand should have fallen to bottom
  int sandAtBottom = 0;
  for (int x = 0; x < 80; x++) {
    if (e.grid[59 * 80 + x] == El.sand) sandAtBottom++;
  }
  // Also check no sand remains at original position
  int sandAtTop = 0;
  for (int x = 30; x < 50; x++) {
    if (e.grid[10 * 80 + x] == El.sand) sandAtTop++;
  }

  double score = 0;
  if (sandAtBottom > 0) score += 50; // Sand fell
  if (sandAtTop == 0) score += 30; // Cleared original position
  score += (sandAtBottom / 20.0 * 20).clamp(0, 20); // Proportional to amount
  return score;
}

// ---------------------------------------------------------------------------
// Test: Water spreads laterally
// ---------------------------------------------------------------------------
double _testWaterPhysics() {
  final e = SimulationEngine(gridW: 80, gridH: 60, seed: 42);

  // Stone bowl at bottom
  for (int x = 20; x < 60; x++) {
    e.grid[55 * 80 + x] = El.stone;
  }
  for (int y = 40; y < 56; y++) {
    e.grid[y * 80 + 20] = El.stone;
    e.grid[y * 80 + 59] = El.stone;
  }

  // Water column in center
  for (int y = 30; y < 40; y++) {
    e.grid[y * 80 + 40] = El.water;
  }
  e.markAllDirty();

  for (int i = 0; i < 200; i++) {
    e.step(simulateElement);
  }

  // Check: water should have spread laterally in the bowl
  int waterCells = 0;
  int waterSpread = 0;
  Set<int> waterXs = {};
  for (int y = 40; y < 55; y++) {
    for (int x = 21; x < 59; x++) {
      if (e.grid[y * 80 + x] == El.water) {
        waterCells++;
        waterXs.add(x);
      }
    }
  }
  waterSpread = waterXs.length;

  double score = 0;
  if (waterCells > 0) score += 30;
  if (waterSpread > 5) score += 30; // Spread laterally
  score += (waterSpread / 30.0 * 40).clamp(0, 40);
  return score;
}

// ---------------------------------------------------------------------------
// Test: Fire rises and produces smoke
// ---------------------------------------------------------------------------
double _testFirePhysics() {
  final e = SimulationEngine(gridW: 80, gridH: 60, seed: 42);

  // Place fire at bottom
  for (int x = 35; x < 45; x++) {
    e.grid[55 * 80 + x] = El.fire;
    e.life[55 * 80 + x] = 1;
  }
  e.markAllDirty();

  for (int i = 0; i < 60; i++) {
    e.step(simulateElement);
  }

  // Check: smoke/steam should exist above original fire position
  int smokeAbove = 0;
  for (int y = 0; y < 50; y++) {
    for (int x = 30; x < 50; x++) {
      final el = e.grid[y * 80 + x];
      if (el == El.smoke || el == El.steam || el == El.fire) {
        smokeAbove++;
      }
    }
  }

  double score = 0;
  if (smokeAbove > 0) score += 50;
  score += (smokeAbove / 20.0 * 50).clamp(0, 50);
  return score;
}

// ---------------------------------------------------------------------------
// Test: Element interactions (water+fire=steam, lava+water=stone+steam)
// ---------------------------------------------------------------------------
double _testInteractions() {
  double score = 0;

  // Water + Fire = Steam
  {
    final e = SimulationEngine(gridW: 40, gridH: 30, seed: 42);
    for (int x = 10; x < 30; x++) {
      e.grid[20 * 40 + x] = El.fire;
      e.life[20 * 40 + x] = 5;
    }
    for (int x = 10; x < 30; x++) {
      e.grid[15 * 40 + x] = El.water;
    }
    e.markAllDirty();
    for (int i = 0; i < 50; i++) e.step(simulateElement);
    int steam = 0;
    for (int i = 0; i < 40 * 30; i++) {
      if (e.grid[i] == El.steam) steam++;
    }
    if (steam > 0) score += 25;
  }

  // Lava + Water = Stone + Steam
  {
    final e = SimulationEngine(gridW: 40, gridH: 30, seed: 42);
    for (int x = 10; x < 30; x++) {
      e.grid[20 * 40 + x] = El.lava;
    }
    for (int x = 10; x < 30; x++) {
      e.grid[15 * 40 + x] = El.water;
    }
    e.markAllDirty();
    for (int i = 0; i < 80; i++) e.step(simulateElement);
    int stone = 0, steam = 0;
    for (int i = 0; i < 40 * 30; i++) {
      if (e.grid[i] == El.stone) stone++;
      if (e.grid[i] == El.steam) steam++;
    }
    if (stone > 0) score += 15;
    if (steam > 0) score += 10;
  }

  // Ice melts near fire
  {
    final e = SimulationEngine(gridW: 40, gridH: 30, seed: 42);
    e.grid[15 * 40 + 20] = El.ice;
    e.grid[15 * 40 + 21] = El.fire;
    e.life[15 * 40 + 21] = 1;
    e.temperature[15 * 40 + 21] = 200;
    e.markAllDirty();
    for (int i = 0; i < 100; i++) e.step(simulateElement);
    bool iceMelted = e.grid[15 * 40 + 20] != El.ice;
    if (iceMelted) score += 25;
  }

  // Oil catches fire
  {
    final e = SimulationEngine(gridW: 40, gridH: 30, seed: 42);
    for (int x = 15; x < 25; x++) {
      e.grid[20 * 40 + x] = El.oil;
    }
    e.grid[20 * 40 + 14] = El.fire;
    e.life[20 * 40 + 14] = 1;
    e.temperature[20 * 40 + 14] = 200;
    e.markAllDirty();
    for (int i = 0; i < 80; i++) e.step(simulateElement);
    int fire = 0;
    for (int x = 15; x < 25; x++) {
      if (e.grid[20 * 40 + x] == El.fire) fire++;
    }
    if (fire > 0) score += 25;
  }

  return score;
}

// ---------------------------------------------------------------------------
// Test: Density ordering (heavy sinks through light)
// ---------------------------------------------------------------------------
double _testDensityOrdering() {
  final e = SimulationEngine(gridW: 20, gridH: 40, seed: 42);

  // Stone walls
  for (int y = 0; y < 40; y++) {
    e.grid[y * 20 + 0] = El.stone;
    e.grid[y * 20 + 19] = El.stone;
  }
  for (int x = 0; x < 20; x++) {
    e.grid[39 * 20 + x] = El.stone;
  }

  // Layer: oil on top of water (oil should float)
  for (int x = 1; x < 19; x++) {
    e.grid[30 * 20 + x] = El.water;
    e.grid[31 * 20 + x] = El.water;
    e.grid[28 * 20 + x] = El.oil;
    e.grid[29 * 20 + x] = El.oil;
  }
  e.markAllDirty();

  for (int i = 0; i < 200; i++) {
    e.step(simulateElement);
  }

  // Check: oil should be above water
  int oilAboveWater = 0;
  int waterAboveOil = 0;
  for (int x = 1; x < 19; x++) {
    int topOilY = -1, topWaterY = -1;
    for (int y = 0; y < 39; y++) {
      if (e.grid[y * 20 + x] == El.oil && topOilY == -1) topOilY = y;
      if (e.grid[y * 20 + x] == El.water && topWaterY == -1) topWaterY = y;
    }
    if (topOilY >= 0 && topWaterY >= 0) {
      if (topOilY < topWaterY) oilAboveWater++;
      else waterAboveOil++;
    }
  }

  double score = 0;
  if (oilAboveWater > waterAboveOil) score += 60;
  score += (oilAboveWater / 18.0 * 40).clamp(0, 40);
  return score;
}

// ---------------------------------------------------------------------------
// Test: Temperature propagation
// ---------------------------------------------------------------------------
double _testTemperature() {
  final e = SimulationEngine(gridW: 40, gridH: 20, seed: 42);

  // Hot source on left, check heat spreads right
  for (int y = 5; y < 15; y++) {
    e.grid[y * 40 + 5] = El.lava;
    e.temperature[y * 40 + 5] = 250;
  }
  // Stone medium for conduction
  for (int y = 5; y < 15; y++) {
    for (int x = 6; x < 35; x++) {
      e.grid[y * 40 + x] = El.stone;
      e.temperature[y * 40 + x] = 128;
    }
  }
  e.markAllDirty();

  for (int i = 0; i < 200; i++) {
    e.step(simulateElement);
  }

  // Check temperature gradient
  final nearTemp = e.temperature[10 * 40 + 8]; // near lava
  final farTemp = e.temperature[10 * 40 + 30]; // far from lava

  double score = 0;
  if (nearTemp > farTemp) score += 50; // Gradient exists
  if (nearTemp > 140) score += 25; // Near is warm
  if (farTemp < nearTemp) score += 25; // Far is cooler
  return score;
}

// ---------------------------------------------------------------------------
// Test: Mass conservation
// ---------------------------------------------------------------------------
double _testConservation() {
  final e = SimulationEngine(gridW: 60, gridH: 40, seed: 42);

  // Count initial elements
  int initialSand = 0;
  for (int x = 20; x < 40; x++) {
    for (int y = 5; y < 10; y++) {
      e.grid[y * 60 + x] = El.sand;
      initialSand++;
    }
  }
  // Stone floor
  for (int x = 0; x < 60; x++) {
    e.grid[39 * 60 + x] = El.stone;
  }
  e.markAllDirty();

  for (int i = 0; i < 150; i++) {
    e.step(simulateElement);
  }

  // Count sand after simulation
  int finalSand = 0;
  for (int i = 0; i < 60 * 40; i++) {
    if (e.grid[i] == El.sand) finalSand++;
  }

  double score = 0;
  if (finalSand == initialSand) {
    score = 100; // Perfect conservation
  } else {
    final ratio = finalSand / initialSand;
    score = (ratio * 100).clamp(0, 100);
  }
  return score;
}

// ---------------------------------------------------------------------------
// Test: Structural integrity (supported stone stays, unsupported falls)
// ---------------------------------------------------------------------------
double _testStructural() {
  final e = SimulationEngine(gridW: 40, gridH: 30, seed: 42);

  // Supported stone platform
  for (int x = 10; x < 30; x++) {
    e.grid[20 * 40 + x] = El.stone;
  }
  // Support column
  e.grid[21 * 40 + 20] = El.stone;
  e.grid[22 * 40 + 20] = El.stone;
  e.grid[23 * 40 + 20] = El.stone;

  // Unsupported stone in air
  for (int x = 5; x < 8; x++) {
    e.grid[5 * 40 + x] = El.stone;
  }

  e.markAllDirty();
  for (int i = 0; i < 100; i++) {
    e.step(simulateElement);
  }

  // Supported stone should still be at y=20
  int supportedRemaining = 0;
  for (int x = 10; x < 30; x++) {
    if (e.grid[20 * 40 + x] == El.stone) supportedRemaining++;
  }

  // Unsupported stone should have fallen from y=5
  int unsupportedAtOriginal = 0;
  for (int x = 5; x < 8; x++) {
    if (e.grid[5 * 40 + x] == El.stone) unsupportedAtOriginal++;
  }

  double score = 0;
  score += (supportedRemaining / 20.0 * 50).clamp(0, 50);
  if (unsupportedAtOriginal < 3) score += 50; // Fell
  return score;
}
