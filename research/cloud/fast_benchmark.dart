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

import 'package:the_particle_engine/simulation/simulation_engine.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/element_behaviors.dart';

void main(List<String> args) {
  ElementRegistry.init();

  // Load trial config if provided and apply to element properties
  Map<String, dynamic>? config;
  if (args.isNotEmpty) {
    final configFile = File(args[0]);
    if (configFile.existsSync()) {
      config = jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
      _applyTrialConfig(config);
    }
  }

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
// Test: Sand physics — fall speed + pile spreading
// Sensitive to: sand_density, sand_gravity
// ---------------------------------------------------------------------------
double _testSandPhysics() {
  final e = SimulationEngine(gridW: 80, gridH: 60, seed: 42);

  // Place a 20-wide row of sand at y=10
  for (int x = 30; x < 50; x++) {
    e.grid[10 * 80 + x] = El.sand;
  }
  // Stone floor
  for (int x = 0; x < 80; x++) {
    e.grid[59 * 80 + x] = El.stone;
  }
  e.markAllDirty();

  // Measure how many frames until the first sand reaches the floor (y=58)
  int framesToReach = -1;
  for (int i = 0; i < 100; i++) {
    e.step(simulateElement);
    if (framesToReach == -1) {
      for (int x = 0; x < 80; x++) {
        if (e.grid[58 * 80 + x] == El.sand) {
          framesToReach = i + 1;
          break;
        }
      }
    }
  }

  // After 100 steps, measure pile shape
  // Count sand at each x to measure spread width
  int totalSand = 0;
  int minSandX = 80, maxSandX = 0;
  final sandPerX = List<int>.filled(80, 0);
  for (int y = 0; y < 60; y++) {
    for (int x = 0; x < 80; x++) {
      if (e.grid[y * 80 + x] == El.sand) {
        totalSand++;
        sandPerX[x]++;
        if (x < minSandX) minSandX = x;
        if (x > maxSandX) maxSandX = x;
      }
    }
  }

  // No sand left at original row = it all moved
  int sandAtOrigin = 0;
  for (int x = 30; x < 50; x++) {
    if (e.grid[10 * 80 + x] == El.sand) sandAtOrigin++;
  }

  double score = 0.0;

  // Fall speed score (30 pts): faster fall = better. Ideal ~20-30 frames.
  // framesToReach of -1 means it never reached = 0 pts.
  if (framesToReach > 0) {
    // Best possible: ~15 frames (high gravity+density). Worst reasonable: ~60.
    // Score linearly: 30 pts at 15 frames, 0 pts at 60+ frames.
    score += (30.0 * (1.0 - ((framesToReach - 15).clamp(0, 45) / 45.0)));
  }

  // Cleared origin (20 pts): proportional to how much moved away
  score += 20.0 * (1.0 - sandAtOrigin / 20.0);

  // Pile spread (25 pts): sand should form a pile wider than 20 (diagonal spreading)
  // but not TOO wide. Ideal spread: 24-35 cells wide.
  final spreadWidth = (maxSandX - minSandX + 1).clamp(0, 80);
  if (spreadWidth >= 20) {
    // Wider than the original 20 = diagonal spreading works
    // Peak at ~30 wide, tapering off above 50
    final idealDist = (spreadWidth - 30).abs();
    score += 25.0 * (1.0 - (idealDist / 30.0).clamp(0.0, 1.0));
  }

  // Conservation (25 pts): all 20 sand cells should still exist
  score += 25.0 * (totalSand / 20.0).clamp(0.0, 1.0);

  return score.clamp(0.0, 100.0);
}

// ---------------------------------------------------------------------------
// Test: Water physics — spread rate + evenness in container
// Sensitive to: water_density, water_gravity, water_surface_tension, oil_viscosity
// ---------------------------------------------------------------------------
double _testWaterPhysics() {
  final e = SimulationEngine(gridW: 80, gridH: 60, seed: 42);

  // Stone bowl: floor at y=55, walls at x=20 and x=59
  for (int x = 20; x < 60; x++) {
    e.grid[55 * 80 + x] = El.stone;
  }
  for (int y = 40; y < 56; y++) {
    e.grid[y * 80 + 20] = El.stone;
    e.grid[y * 80 + 59] = El.stone;
  }

  // Water column in center: 10 cells tall at x=40
  final initialWater = 10;
  for (int y = 30; y < 40; y++) {
    e.grid[y * 80 + 40] = El.water;
  }
  e.markAllDirty();

  // Run 50 steps to measure spread rate
  int waterSpreadAt50 = 0;
  for (int i = 0; i < 50; i++) {
    e.step(simulateElement);
  }
  Set<int> waterXsEarly = {};
  for (int y = 40; y < 55; y++) {
    for (int x = 21; x < 59; x++) {
      if (e.grid[y * 80 + x] == El.water) waterXsEarly.add(x);
    }
  }
  waterSpreadAt50 = waterXsEarly.length;

  // Run another 150 steps (200 total)
  for (int i = 0; i < 150; i++) {
    e.step(simulateElement);
  }

  // Measure final water distribution in the bowl
  int totalWater = 0;
  Set<int> waterXsFinal = {};
  final waterPerX = List<int>.filled(80, 0);
  for (int y = 40; y < 55; y++) {
    for (int x = 21; x < 59; x++) {
      if (e.grid[y * 80 + x] == El.water) {
        totalWater++;
        waterXsFinal.add(x);
        waterPerX[x]++;
      }
    }
  }

  double score = 0.0;

  // Spread rate at frame 50 (25 pts): more unique X columns = faster spread
  // Ideal: 15-30 columns by frame 50. Low viscosity = faster.
  score += 25.0 * (waterSpreadAt50 / 30.0).clamp(0.0, 1.0);

  // Final spread (25 pts): should cover most of the 38-wide bowl
  final finalSpread = waterXsFinal.length;
  score += 25.0 * (finalSpread / 38.0).clamp(0.0, 1.0);

  // Evenness (25 pts): water should settle to roughly equal depth across X
  // Compute coefficient of variation among non-zero columns
  if (waterXsFinal.isNotEmpty) {
    final occupiedCounts = <int>[];
    for (int x = 21; x < 59; x++) {
      if (waterPerX[x] > 0) occupiedCounts.add(waterPerX[x]);
    }
    if (occupiedCounts.length > 1) {
      final mean = occupiedCounts.reduce((a, b) => a + b) / occupiedCounts.length;
      final variance = occupiedCounts.map((c) => (c - mean) * (c - mean))
          .reduce((a, b) => a + b) / occupiedCounts.length;
      final cv = mean > 0 ? sqrt(variance) / mean : 1.0;
      // CV of 0 = perfectly even = 25 pts. CV of 1+ = very uneven = 0 pts.
      score += 25.0 * (1.0 - cv.clamp(0.0, 1.0));
    }
  }

  // Conservation (25 pts): water should be conserved (allowing steam loss)
  score += 25.0 * (totalWater / initialWater.toDouble()).clamp(0.0, 1.0);

  return score.clamp(0.0, 100.0);
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

  // Count smoke/steam above original fire position and measure max height
  int smokeAbove = 0;
  int highestSmoke = 60;
  for (int y = 0; y < 50; y++) {
    for (int x = 30; x < 50; x++) {
      final el = e.grid[y * 80 + x];
      if (el == El.smoke || el == El.steam || el == El.fire) {
        smokeAbove++;
        if (y < highestSmoke) highestSmoke = y;
      }
    }
  }

  double score = 0;
  // Smoke production (50 pts)
  score += (smokeAbove / 20.0 * 50).clamp(0.0, 50.0);
  // Rise height (50 pts): smoke should rise high
  if (highestSmoke < 50) {
    score += 50.0 * ((50 - highestSmoke) / 50.0).clamp(0.0, 1.0);
  }
  return score.clamp(0.0, 100.0);
}

// ---------------------------------------------------------------------------
// Test: Element interactions — reaction rates and product quantities
// Sensitive to: water_boil_point, water_freeze_point, ice_melt_point,
//               sand_melt_point, temperature thresholds
// ---------------------------------------------------------------------------
double _testInteractions() {
  double score = 0;

  // Water + Fire = Steam: measure steam production QUANTITY + timing
  {
    final e = SimulationEngine(gridW: 40, gridH: 30, seed: 42);
    for (int x = 10; x < 30; x++) {
      e.grid[20 * 40 + x] = El.fire;
      e.life[20 * 40 + x] = 5;
      e.temperature[20 * 40 + x] = 230;
    }
    for (int x = 10; x < 30; x++) {
      e.grid[15 * 40 + x] = El.water;
    }
    e.markAllDirty();

    int steamAt25 = 0;
    for (int i = 0; i < 50; i++) {
      e.step(simulateElement);
      if (i == 24) {
        for (int j = 0; j < 40 * 30; j++) {
          if (e.grid[j] == El.steam) steamAt25++;
        }
      }
    }
    int steamFinal = 0;
    for (int j = 0; j < 40 * 30; j++) {
      if (e.grid[j] == El.steam) steamFinal++;
    }
    // Early reaction speed (12.5 pts): how much steam by frame 25
    score += 12.5 * (steamAt25 / 15.0).clamp(0.0, 1.0);
    // Final quantity (12.5 pts): total steam produced
    score += 12.5 * (steamFinal / 20.0).clamp(0.0, 1.0);
  }

  // Lava + Water = Stone + Steam: measure product quantities
  {
    final e = SimulationEngine(gridW: 40, gridH: 30, seed: 42);
    for (int x = 10; x < 30; x++) {
      e.grid[20 * 40 + x] = El.lava;
      e.temperature[20 * 40 + x] = 250;
    }
    for (int x = 10; x < 30; x++) {
      e.grid[15 * 40 + x] = El.water;
    }
    e.markAllDirty();
    for (int i = 0; i < 80; i++) { e.step(simulateElement); }
    int stone = 0, steam = 0;
    for (int i = 0; i < 40 * 30; i++) {
      if (e.grid[i] == El.stone) stone++;
      if (e.grid[i] == El.steam) steam++;
    }
    // Stone production (12.5 pts)
    score += 12.5 * (stone / 15.0).clamp(0.0, 1.0);
    // Steam byproduct (12.5 pts)
    score += 12.5 * (steam / 10.0).clamp(0.0, 1.0);
  }

  // Ice melts near fire: measure melt speed
  {
    final e = SimulationEngine(gridW: 40, gridH: 30, seed: 42);
    // Place a 5-wide ice block next to fire
    for (int x = 18; x < 23; x++) {
      e.grid[15 * 40 + x] = El.ice;
    }
    e.grid[15 * 40 + 23] = El.fire;
    e.life[15 * 40 + 23] = 1;
    e.temperature[15 * 40 + 23] = 200;
    e.markAllDirty();

    int frameMelted = -1;
    for (int i = 0; i < 100; i++) {
      e.step(simulateElement);
      if (frameMelted == -1) {
        int iceLeft = 0;
        for (int x = 18; x < 23; x++) {
          if (e.grid[15 * 40 + x] == El.ice) iceLeft++;
        }
        if (iceLeft == 0) frameMelted = i + 1;
      }
    }
    // Count remaining ice
    int iceRemaining = 0;
    for (int x = 18; x < 23; x++) {
      if (e.grid[15 * 40 + x] == El.ice) iceRemaining++;
    }
    // Melt completeness (15 pts)
    score += 15.0 * (1.0 - iceRemaining / 5.0);
    // Melt speed bonus (10 pts): faster = better
    if (frameMelted > 0) {
      score += 10.0 * (1.0 - (frameMelted / 100.0).clamp(0.0, 1.0));
    }
  }

  // Oil catches fire: measure fire spread
  {
    final e = SimulationEngine(gridW: 40, gridH: 30, seed: 42);
    for (int x = 15; x < 25; x++) {
      e.grid[20 * 40 + x] = El.oil;
    }
    e.grid[20 * 40 + 14] = El.fire;
    e.life[20 * 40 + 14] = 1;
    e.temperature[20 * 40 + 14] = 200;
    e.markAllDirty();
    for (int i = 0; i < 80; i++) { e.step(simulateElement); }
    int fire = 0, smoke = 0;
    for (int i = 0; i < 40 * 30; i++) {
      if (e.grid[i] == El.fire) fire++;
      if (e.grid[i] == El.smoke) smoke++;
    }
    // Fire spread (12.5 pts)
    score += 12.5 * (fire / 8.0).clamp(0.0, 1.0);
    // Smoke produced from burning oil (12.5 pts)
    score += 12.5 * (smoke / 10.0).clamp(0.0, 1.0);
  }

  return score.clamp(0.0, 100.0);
}

// ---------------------------------------------------------------------------
// Test: Density ordering — multi-element column separates by density
// Sensitive to: sand_density, water_density, oil_density, lava_density
// ---------------------------------------------------------------------------
double _testDensityOrdering() {
  final e = SimulationEngine(gridW: 20, gridH: 40, seed: 42);

  // Stone walls and floor
  for (int y = 0; y < 40; y++) {
    e.grid[y * 20 + 0] = El.stone;
    e.grid[y * 20 + 19] = El.stone;
  }
  for (int x = 0; x < 20; x++) {
    e.grid[39 * 20 + x] = El.stone;
  }

  // Place elements in WRONG density order (light at bottom, heavy at top)
  // This forces the simulation to sort them by density.
  // From top: lava (heavy), sand (medium-heavy), water (medium), oil (light)
  for (int x = 1; x < 19; x++) {
    e.grid[15 * 20 + x] = El.oil;    // lightest - placed high
    e.grid[20 * 20 + x] = El.water;  // medium
    e.grid[25 * 20 + x] = El.sand;   // heavy
    e.grid[10 * 20 + x] = El.lava;   // heaviest - placed at top
  }
  e.markAllDirty();

  for (int i = 0; i < 200; i++) {
    e.step(simulateElement);
  }

  // Read the current densities from the lookup tables (affected by params)
  final lavaDens = elementDensity[El.lava];
  final sandDens = elementDensity[El.sand];
  final waterDens = elementDensity[El.water];
  final oilDens = elementDensity[El.oil];

  // Build expected order: heaviest should be at the bottom (highest y)
  final densityMap = {
    El.lava: lavaDens,
    El.sand: sandDens,
    El.water: waterDens,
    El.oil: oilDens,
  };

  // For each column, check pairwise ordering: heavier elements should be lower
  int correctPairs = 0;
  int totalPairs = 0;

  for (int x = 1; x < 19; x++) {
    // Collect all non-stone, non-empty cells in this column with their y
    final cells = <({int el, int y})>[];
    for (int y = 0; y < 39; y++) {
      final el = e.grid[y * 20 + x];
      if (densityMap.containsKey(el)) {
        cells.add((el: el, y: y));
      }
    }
    // Check all pairs: for any two cells, the denser one should be lower (higher y)
    for (int i = 0; i < cells.length; i++) {
      for (int j = i + 1; j < cells.length; j++) {
        final a = cells[i], b = cells[j];
        if (densityMap[a.el]! == densityMap[b.el]!) continue; // same density, skip
        totalPairs++;
        // a has lower y (higher position). If a is lighter, that's correct.
        if (densityMap[a.el]! < densityMap[b.el]!) {
          correctPairs++;
        }
      }
    }
  }

  // Also measure vertical center-of-mass for each element type
  // Heavier elements should have higher average y
  final ySum = <int, double>{};
  final yCount = <int, int>{};
  for (final el in [El.lava, El.sand, El.water, El.oil]) {
    ySum[el] = 0.0;
    yCount[el] = 0;
  }
  for (int y = 0; y < 39; y++) {
    for (int x = 1; x < 19; x++) {
      final el = e.grid[y * 20 + x];
      if (ySum.containsKey(el)) {
        ySum[el] = ySum[el]! + y;
        yCount[el] = yCount[el]! + 1;
      }
    }
  }

  // Compute center of mass for each
  final avgY = <int, double>{};
  for (final el in [El.lava, El.sand, El.water, El.oil]) {
    avgY[el] = yCount[el]! > 0 ? ySum[el]! / yCount[el]! : 0.0;
  }

  // Sort elements by density (ascending) and check that avgY is also ascending
  final sortedByDensity = [El.oil, El.water, El.sand, El.lava];
  sortedByDensity.sort((a, b) => densityMap[a]!.compareTo(densityMap[b]!));

  int comCorrectPairs = 0;
  int comTotalPairs = 0;
  for (int i = 0; i < sortedByDensity.length; i++) {
    for (int j = i + 1; j < sortedByDensity.length; j++) {
      final lighter = sortedByDensity[i];
      final heavier = sortedByDensity[j];
      if (avgY[lighter]! > 0 && avgY[heavier]! > 0) {
        comTotalPairs++;
        if (avgY[heavier]! > avgY[lighter]!) comCorrectPairs++;
      }
    }
  }

  double score = 0.0;

  // Pairwise cell ordering (60 pts)
  if (totalPairs > 0) {
    score += 60.0 * (correctPairs / totalPairs.toDouble());
  }

  // Center-of-mass ordering (40 pts)
  if (comTotalPairs > 0) {
    score += 40.0 * (comCorrectPairs / comTotalPairs.toDouble());
  }

  return score.clamp(0.0, 100.0);
}

// ---------------------------------------------------------------------------
// Test: Temperature propagation — heat transfer distance + phase changes
// Sensitive to: water_boil_point, water_freeze_point, ice_melt_point,
//               lava temperature interaction
// ---------------------------------------------------------------------------
double _testTemperature() {
  final e = SimulationEngine(gridW: 60, gridH: 20, seed: 42);

  // Lava heat source on left
  for (int y = 5; y < 15; y++) {
    e.grid[y * 60 + 5] = El.lava;
    e.temperature[y * 60 + 5] = 250;
  }
  // Water medium for conduction (water boils/phase-changes based on thresholds)
  for (int y = 5; y < 15; y++) {
    for (int x = 6; x < 50; x++) {
      e.grid[y * 60 + x] = El.water;
      e.temperature[y * 60 + x] = 128;
    }
  }
  e.markAllDirty();

  for (int i = 0; i < 200; i++) {
    e.step(simulateElement);
  }

  // Measure temperature at multiple distances from lava source
  final sampleY = 10;
  final temps = <double>[];
  for (int x = 7; x < 50; x += 3) {
    temps.add(e.temperature[sampleY * 60 + x].toDouble());
  }

  // Count steam produced (phase change indicator)
  int steamCount = 0;
  for (int y = 0; y < 20; y++) {
    for (int x = 0; x < 60; x++) {
      if (e.grid[y * 60 + x] == El.steam) steamCount++;
    }
  }

  // Measure how far heat penetrated: find the farthest x with temp > 135
  int heatReach = 0;
  for (int x = 6; x < 50; x++) {
    if (e.temperature[sampleY * 60 + x] > 135) heatReach = x - 6;
  }

  double score = 0.0;

  // Temperature gradient exists (20 pts): near lava should be hotter than far
  if (temps.length >= 2) {
    final nearTemp = temps.first;
    final farTemp = temps.last;
    if (nearTemp > farTemp) {
      // Bigger gradient = better heat modeling
      final gradientStrength = ((nearTemp - farTemp) / 128.0).clamp(0.0, 1.0);
      score += 20.0 * gradientStrength;
    }
  }

  // Heat propagation distance (30 pts): how far did heat travel
  // Ideal: 15-30 cells of reach
  score += 30.0 * (heatReach / 30.0).clamp(0.0, 1.0);

  // Steam production from boiling water (30 pts)
  // The boil_point parameter directly controls how much steam is produced
  score += 30.0 * (steamCount / 30.0).clamp(0.0, 1.0);

  // Monotonic gradient (20 pts): temperature should decrease with distance
  if (temps.length >= 3) {
    int monotonicCount = 0;
    for (int i = 1; i < temps.length; i++) {
      if (temps[i] <= temps[i - 1]) monotonicCount++;
    }
    score += 20.0 * (monotonicCount / (temps.length - 1));
  }

  return score.clamp(0.0, 100.0);
}

// ---------------------------------------------------------------------------
// Test: Mass conservation — element count stability over time
// Sensitive to: all parameters (bugs in any element can cause mass drift)
// ---------------------------------------------------------------------------
double _testConservation() {
  final e = SimulationEngine(gridW: 60, gridH: 40, seed: 42);

  // Place sand block + stone floor (non-reactive setup for pure conservation)
  int initialSand = 0;
  for (int x = 20; x < 40; x++) {
    for (int y = 5; y < 10; y++) {
      e.grid[y * 60 + x] = El.sand;
      initialSand++;
    }
  }
  // Add water in a stone bowl to test liquid conservation too
  for (int x = 5; x < 18; x++) {
    e.grid[35 * 60 + x] = El.stone; // floor
  }
  e.grid[30 * 60 + 5] = El.stone;  // left wall
  e.grid[31 * 60 + 5] = El.stone;
  e.grid[32 * 60 + 5] = El.stone;
  e.grid[33 * 60 + 5] = El.stone;
  e.grid[34 * 60 + 5] = El.stone;
  e.grid[30 * 60 + 17] = El.stone; // right wall
  e.grid[31 * 60 + 17] = El.stone;
  e.grid[32 * 60 + 17] = El.stone;
  e.grid[33 * 60 + 17] = El.stone;
  e.grid[34 * 60 + 17] = El.stone;
  int initialWater = 0;
  for (int x = 6; x < 17; x++) {
    for (int y = 32; y < 35; y++) {
      e.grid[y * 60 + x] = El.water;
      initialWater++;
    }
  }
  // Stone floor for sand
  for (int x = 0; x < 60; x++) {
    e.grid[39 * 60 + x] = El.stone;
  }
  e.markAllDirty();

  for (int i = 0; i < 300; i++) {
    e.step(simulateElement);
  }

  // Count sand and water after simulation
  int finalSand = 0;
  int finalWater = 0;
  for (int i = 0; i < 60 * 40; i++) {
    if (e.grid[i] == El.sand) finalSand++;
    if (e.grid[i] == El.water) finalWater++;
  }

  // Sand conservation (50 pts)
  final sandDrift = (finalSand - initialSand).abs() / initialSand.toDouble();
  final sandScore = 50.0 * (1.0 - sandDrift.clamp(0.0, 1.0));

  // Water conservation (50 pts) — allow some steam loss but penalize heavy loss
  final waterRatio = initialWater > 0 ? finalWater / initialWater.toDouble() : 1.0;
  // Perfect = 1.0, tolerate down to 0.7 gracefully
  final waterScore = 50.0 * waterRatio.clamp(0.0, 1.0);

  return (sandScore + waterScore).clamp(0.0, 100.0);
}

// ---------------------------------------------------------------------------
// Test: Structural — heavy elements sink through lighter ones
// Sensitive to: sand_density, water_density, stone_density, metal_density
// ---------------------------------------------------------------------------
double _testStructural() {
  final e = SimulationEngine(gridW: 40, gridH: 40, seed: 42);

  // Stone floor
  for (int x = 0; x < 40; x++) {
    e.grid[39 * 40 + x] = El.stone;
  }

  // Test 1: Sand should sink through water
  // Water layer at y=25..30, sand block on top at y=20..24
  for (int x = 5; x < 15; x++) {
    for (int y = 25; y < 31; y++) {
      e.grid[y * 40 + x] = El.water;
    }
    for (int y = 20; y < 25; y++) {
      e.grid[y * 40 + x] = El.sand;
    }
  }

  // Test 2: Oil should float on water
  // Water at y=25..30, oil at y=31..34 (oil below water — should swap)
  for (int x = 22; x < 32; x++) {
    for (int y = 25; y < 31; y++) {
      e.grid[y * 40 + x] = El.water;
    }
    for (int y = 31; y < 35; y++) {
      e.grid[y * 40 + x] = El.oil;
    }
  }

  e.markAllDirty();

  for (int i = 0; i < 200; i++) {
    e.step(simulateElement);
  }

  double score = 0.0;

  // Test 1 scoring: sand's average Y should be > water's average Y in left section
  double sandAvgY = 0, waterAvgY = 0;
  int sandCount = 0, waterCount = 0;
  for (int y = 0; y < 39; y++) {
    for (int x = 5; x < 15; x++) {
      final el = e.grid[y * 40 + x];
      if (el == El.sand) { sandAvgY += y; sandCount++; }
      if (el == El.water) { waterAvgY += y; waterCount++; }
    }
  }
  if (sandCount > 0 && waterCount > 0) {
    sandAvgY /= sandCount;
    waterAvgY /= waterCount;
    // Sand should have higher avgY (lower in grid) than water
    if (sandAvgY > waterAvgY) {
      final separation = (sandAvgY - waterAvgY) / 10.0; // normalize
      score += 50.0 * separation.clamp(0.0, 1.0);
    }
  }

  // Test 2 scoring: oil's average Y should be < water's average Y in right section
  double oilAvgY = 0, water2AvgY = 0;
  int oilCount = 0, water2Count = 0;
  for (int y = 0; y < 39; y++) {
    for (int x = 22; x < 32; x++) {
      final el = e.grid[y * 40 + x];
      if (el == El.oil) { oilAvgY += y; oilCount++; }
      if (el == El.water) { water2AvgY += y; water2Count++; }
    }
  }
  if (oilCount > 0 && water2Count > 0) {
    oilAvgY /= oilCount;
    water2AvgY /= water2Count;
    // Oil should have lower avgY (higher in grid) than water
    if (water2AvgY > oilAvgY) {
      final separation = (water2AvgY - oilAvgY) / 10.0;
      score += 50.0 * separation.clamp(0.0, 1.0);
    }
  }

  return score.clamp(0.0, 100.0);
}

// ---------------------------------------------------------------------------
// Apply trial config parameters to element registry lookup tables
// ---------------------------------------------------------------------------
void _applyTrialConfig(Map<String, dynamic> config) {
  final params = config['params'] as Map<String, dynamic>? ?? config;

  // Helper to read int param
  int p(String key, int fallback) =>
      (params[key] as num?)?.toInt() ?? fallback;

  // Densities
  elementDensity[El.sand] = p('sand_density', elementDensity[El.sand]);
  elementDensity[El.water] = p('water_density', elementDensity[El.water]);
  elementDensity[El.oil] = p('oil_density', elementDensity[El.oil]);
  elementDensity[El.stone] = p('stone_density', elementDensity[El.stone]);
  elementDensity[El.metal] = p('metal_density', elementDensity[El.metal]);
  elementDensity[El.ice] = p('ice_density', elementDensity[El.ice]);
  elementDensity[El.wood] = p('wood_density', elementDensity[El.wood]);
  elementDensity[El.dirt] = p('dirt_density', elementDensity[El.dirt]);
  elementDensity[El.lava] = p('lava_density', elementDensity[El.lava]);

  // Gravity
  elementGravity[El.sand] = p('sand_gravity', elementGravity[El.sand]);
  elementGravity[El.water] = p('water_gravity', elementGravity[El.water]);

  // Viscosity
  elementViscosity[El.oil] = p('oil_viscosity', elementViscosity[El.oil]);
  elementViscosity[El.mud] = p('mud_viscosity', elementViscosity[El.mud]);
  elementViscosity[El.lava] = p('lava_viscosity', elementViscosity[El.lava]);

  // Surface tension
  if (params.containsKey('water_surface_tension')) {
    elementSurfaceTension[El.water] = p('water_surface_tension', elementSurfaceTension[El.water]);
  }
  if (params.containsKey('oil_surface_tension')) {
    elementSurfaceTension[El.oil] = p('oil_surface_tension', elementSurfaceTension[El.oil]);
  }
  if (params.containsKey('acid_surface_tension')) {
    elementSurfaceTension[El.acid] = p('acid_surface_tension', elementSurfaceTension[El.acid]);
  }
}
