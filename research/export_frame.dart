/// Headless simulation frame exporter for Python test suite.
///
/// Runs the simulation for N frames, renders pixels, then writes:
///   - research/frame.rgba     Raw RGBA pixel buffer (320*180*4 bytes)
///   - research/grid.bin       Raw grid element IDs (320*180 bytes)
///   - research/frame_meta.json  Dimensions, frame count, element name map
///
/// Usage:
///   dart run research/export_frame.dart [frames]
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../lib/simulation/simulation_engine.dart';
import '../lib/simulation/element_registry.dart';
import '../lib/simulation/element_behaviors.dart';
import '../lib/simulation/pixel_renderer.dart';

void main(List<String> args) {
  final frames = args.isNotEmpty ? int.parse(args[0]) : 100;
  ElementRegistry.init();

  final engine = SimulationEngine(gridW: 320, gridH: 180);
  final renderer = PixelRenderer(engine);
  renderer.init();
  renderer.generateStars();

  _fillTestWorld(engine);

  for (int i = 0; i < frames; i++) {
    engine.step(simulateElement);
  }

  renderer.renderPixels();

  File('research/frame.rgba').writeAsBytesSync(renderer.pixels);
  File('research/grid.bin').writeAsBytesSync(engine.grid);

  final meta = <String, dynamic>{
    'width': 320,
    'height': 180,
    'frames': frames,
    'elements': <String, int>{
      for (int i = 0; i < El.count; i++) elementNames[i]: i,
    },
  };
  File('research/frame_meta.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(meta));

  print(
      'Exported: frame.rgba (${renderer.pixels.length} bytes), grid.bin, frame_meta.json');
}

/// Populate grid with a representative test world (matches engine_benchmark).
void _fillTestWorld(SimulationEngine e) {
  final rng = Random(42);
  final w = e.gridW;
  final h = e.gridH;

  // Ground: stone base with dirt on top
  for (int x = 0; x < w; x++) {
    final groundY = (h * 0.55 + (10 * (0.5 + 0.5 * (x / w)))).round();
    for (int y = groundY; y < h; y++) {
      e.grid[y * w + x] = y < groundY + 3 ? El.dirt : El.stone;
    }
    if (rng.nextInt(20) == 0 && groundY > 10) {
      for (int ty = 1; ty <= 4; ty++) {
        if (groundY - ty >= 0) e.grid[(groundY - ty) * w + x] = El.wood;
      }
    }
  }

  // Water pool
  for (int y = (h * 0.5).round(); y < (h * 0.55).round(); y++) {
    for (int x = (w * 0.3).round(); x < (w * 0.5).round(); x++) {
      if (e.grid[y * w + x] == El.empty) {
        e.grid[y * w + x] = El.water;
        e.life[y * w + x] = 100;
      }
    }
  }

  // Lava pocket underground
  for (int y = (h * 0.8).round(); y < (h * 0.85).round(); y++) {
    for (int x = (w * 0.6).round(); x < (w * 0.7).round(); x++) {
      e.grid[y * w + x] = El.lava;
    }
  }

  // Sand
  for (int x = (w * 0.1).round(); x < (w * 0.25).round(); x++) {
    final groundY = (h * 0.55 + (10 * (0.5 + 0.5 * (x / w)))).round();
    if (groundY > 2) {
      e.grid[(groundY - 1) * w + x] = El.sand;
      e.grid[(groundY - 2) * w + x] = El.sand;
    }
  }

  // Ice and snow
  for (int x = (w * 0.8).round(); x < (w * 0.9).round(); x++) {
    final groundY = (h * 0.55 + (10 * (0.5 + 0.5 * (x / w)))).round();
    if (groundY > 2) {
      e.grid[(groundY - 1) * w + x] = El.snow;
      e.grid[(groundY - 2) * w + x] = El.ice;
    }
  }

  // Steam
  for (int i = 0; i < 5; i++) {
    final x = rng.nextInt(w);
    final y = rng.nextInt(h ~/ 3);
    if (e.grid[y * w + x] == El.empty) {
      e.grid[y * w + x] = El.steam;
    }
  }

  // Metal beams
  for (int y = (h * 0.5).round(); y < (h * 0.55).round(); y++) {
    final x = (w * 0.55).round();
    e.grid[y * w + x] = El.metal;
  }

  // Oil patch
  for (int x = (w * 0.7).round(); x < (w * 0.75).round(); x++) {
    final groundY = (h * 0.55 + (10 * (0.5 + 0.5 * (x / w)))).round();
    if (groundY > 1) {
      e.grid[(groundY - 1) * w + x] = El.oil;
    }
  }

  // Glass
  for (int x = (w * 0.5).round(); x < (w * 0.52).round(); x++) {
    final groundY = (h * 0.55 + (10 * (0.5 + 0.5 * (x / w)))).round();
    if (groundY > 1) {
      e.grid[(groundY - 1) * w + x] = El.glass;
    }
  }

  // Plants on surface (grass type=1, stage=sprout=0 -> green)
  for (int x = (w * 0.35).round(); x < (w * 0.45).round(); x++) {
    final groundY = (h * 0.55 + (10 * (0.5 + 0.5 * (x / w)))).round();
    if (groundY > 3) {
      for (int ty = 1; ty <= 3; ty++) {
        final py = groundY - ty;
        if (py >= 0) {
          final pidx = py * w + x;
          e.grid[pidx] = El.plant;
          // Set plant type=grass(1), stage=mature(2) -> deep green
          e.velX[pidx] = (2 << 4) | 1; // stage=mature, type=grass
          e.life[pidx] = 200; // plenty of moisture to survive
        }
      }
    }
  }

  // Cave pocket underground (empty cells below ground surface)
  for (int y = (h * 0.65).round(); y < (h * 0.72).round(); y++) {
    for (int x = (w * 0.15).round(); x < (w * 0.25).round(); x++) {
      e.grid[y * w + x] = El.empty;
    }
  }

  // Mud patch
  for (int x = (w * 0.25).round(); x < (w * 0.3).round(); x++) {
    final groundY = (h * 0.55 + (10 * (0.5 + 0.5 * (x / w)))).round();
    if (groundY > 1) {
      e.grid[(groundY - 1) * w + x] = El.mud;
      e.grid[groundY * w + x] = El.mud;
    }
  }

  e.markAllDirty();
}
