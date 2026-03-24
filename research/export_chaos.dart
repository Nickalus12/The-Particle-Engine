// ignore_for_file: avoid_print
/// Chaos scenario exporter for fuzz/stress testing.
///
/// Reads a scenario from research/chaos_scenario.json, places elements
/// on a blank grid, runs the simulation, and exports grid + temperature
/// + velocity data for Python chaos tests to verify invariants.
///
/// Scenario JSON format:
/// {
///   "placements": [{"x": 10, "y": 20, "el": 1}, ...],
///   "frames": 100
/// }
///
/// Outputs:
///   - research/chaos_grid.bin    Raw grid element IDs (320*180 bytes)
///   - research/chaos_temp.bin    Raw temperature values (320*180 bytes)
///   - research/chaos_velx.bin    Raw velX values (320*180 signed bytes)
///   - research/chaos_vely.bin    Raw velY values (320*180 signed bytes)
///   - research/chaos_meta.json   Dimensions, frame count, element map
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:the_particle_engine/simulation/simulation_engine.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/element_behaviors.dart';

void main(List<String> args) {
  ElementRegistry.init();

  // Read scenario
  final scenarioFile = File('research/chaos_scenario.json');
  if (!scenarioFile.existsSync()) {
    stderr.writeln('Error: research/chaos_scenario.json not found');
    exit(1);
  }
  final scenario = jsonDecode(scenarioFile.readAsStringSync()) as Map<String, dynamic>;
  final placements = (scenario['placements'] as List)
      .cast<Map<String, dynamic>>();
  final frames = (scenario['frames'] as int?) ?? 100;

  // Create engine with blank grid
  final engine = SimulationEngine(gridW: 320, gridH: 180);
  final w = engine.gridW;

  // Place elements from scenario
  for (final p in placements) {
    final x = (p['x'] as int).clamp(0, engine.gridW - 1);
    final y = (p['y'] as int).clamp(0, engine.gridH - 1);
    final el = (p['el'] as int).clamp(0, maxElements - 1);
    final idx = y * w + x;
    engine.grid[idx] = el;

    // Set base temperature for the element
    if (el < maxElements) {
      engine.temperature[idx] = elementBaseTemp[el];
    }
  }

  engine.markAllDirty();

  // Run simulation
  for (int i = 0; i < frames; i++) {
    engine.step(simulateElement);
  }

  // Export grid
  File('research/chaos_grid.bin').writeAsBytesSync(engine.grid);

  // Export temperature
  File('research/chaos_temp.bin').writeAsBytesSync(engine.temperature);

  // Export velocities (Int8List -> Uint8List view for writing)
  File('research/chaos_velx.bin').writeAsBytesSync(
    Uint8List.view(engine.velX.buffer),
  );
  File('research/chaos_vely.bin').writeAsBytesSync(
    Uint8List.view(engine.velY.buffer),
  );

  // Export metadata
  final meta = <String, dynamic>{
    'width': 320,
    'height': 180,
    'frames': frames,
    'placements_count': placements.length,
    'elements': <String, int>{
      for (int i = 0; i < El.count; i++) elementNames[i]: i,
    },
  };
  File('research/chaos_meta.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(meta));

  print('Chaos export: grid=${engine.grid.length} bytes, '
      'temp=${engine.temperature.length} bytes, frames=$frames');
}
