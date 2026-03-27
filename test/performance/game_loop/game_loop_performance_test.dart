@Tags(<String>['performance', 'performance_gate'])
library;

import 'dart:math' as math;

import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/game/particle_engine_game.dart';
import 'package:the_particle_engine/game/sandbox_world.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';

import '../../helpers/perf_reporter.dart';

class _FrameStats {
  _FrameStats(this.samplesMicros) : assert(samplesMicros.isNotEmpty);

  final List<int> samplesMicros;

  double get meanMs =>
      samplesMicros.reduce((a, b) => a + b) / samplesMicros.length / 1000.0;

  double percentileMs(double p) {
    final sorted = List<int>.from(samplesMicros)..sort();
    final idx = ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
    return sorted[idx] / 1000.0;
  }

  double get p95Ms => percentileMs(0.95);
  double get maxMs => samplesMicros.reduce(math.max) / 1000.0;
}

Future<void> _waitForGameLoaded(
  WidgetTester tester,
  ParticleEngineGame game,
) async {
  for (int i = 0; i < 200; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (!game.isLoaded) continue;

    final SandboxWorld world = game.sandboxWorld;
    if (world.isLoaded && world.sandboxComponent.isLoaded) {
      return;
    }
  }
  throw StateError('Game did not finish loading within expected frames.');
}

Future<ParticleEngineGame> _bootGame(
  WidgetTester tester, {
  int gridW = 192,
  int gridH = 108,
}) async {
  ElementRegistry.init();

  final game = ParticleEngineGame(
    isBlankCanvas: true,
    gridWidth: gridW,
    gridHeight: gridH,
    cellSize: 3.0,
  );

  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: GameWidget<ParticleEngineGame>(game: game),
    ),
  );

  await _waitForGameLoaded(tester, game);
  return game;
}

Future<_FrameStats> _measureFrames(
  WidgetTester tester, {
  required int frames,
  Duration step = const Duration(milliseconds: 16),
}) async {
  final samples = <int>[];
  for (int i = 0; i < frames; i++) {
    final sw = Stopwatch()..start();
    await tester.pump(step);
    sw.stop();
    samples.add(sw.elapsedMicroseconds);
  }
  return _FrameStats(samples);
}

void _setCell(SandboxWorld world, int x, int y, int el) {
  final sim = world.simulation;
  final nx = sim.wrapX(x);
  if (!sim.inBoundsY(y)) return;
  final idx = y * sim.gridW + nx;
  sim.clearCell(idx);
  sim.grid[idx] = el;
  sim.mass[idx] = elementBaseMass[el];
  sim.flags[idx] = sim.simClock ? 0 : 0x80;
  sim.markDirty(nx, y);
  sim.unsettleNeighbors(nx, y);
}

void _fillRect(SandboxWorld world, int x0, int y0, int x1, int y1, int el) {
  final minX = math.min(x0, x1);
  final maxX = math.max(x0, x1);
  final minY = math.min(y0, y1);
  final maxY = math.max(y0, y1);
  for (int y = minY; y <= maxY; y++) {
    for (int x = minX; x <= maxX; x++) {
      _setCell(world, x, y, el);
    }
  }
}

void _seedHydrothermalScenario(SandboxWorld world) {
  final sim = world.simulation;
  final w = sim.gridW;
  final h = sim.gridH;

  // Layered terrain + fluids + gas to exercise major loop systems.
  _fillRect(world, 0, h - 14, w - 1, h - 1, El.stone);
  _fillRect(world, 6, h - 40, w - 7, h - 15, El.water);
  _fillRect(world, w ~/ 3, h - 20, (w ~/ 3) + 18, h - 15, El.lava);
  _fillRect(world, w ~/ 2, 8, (w ~/ 2) + 40, 15, El.cloud);
  _fillRect(world, w ~/ 4, 10, (w ~/ 4) + 20, 16, El.vapor);

  sim.windForce = 2;
  sim.markAllDirty();
}

void _stressPaint(SandboxWorld world) {
  final sim = world.simulation;
  final comp = world.sandboxComponent;
  comp.selectedElement = El.water;
  comp.brushSize = 4;

  // Deterministic zig-zag paint pattern across the world.
  for (int i = 0; i < 220; i++) {
    final x = (i * 7) % (sim.gridW * comp.cellSize).toInt();
    final yGrid = (10 + (i * 13) % (sim.gridH - 20));
    final y = (yGrid * comp.cellSize).toInt();
    comp.paintAt(Vector2(x.toDouble(), y.toDouble()));
  }
}

void _expectFrameBudget(
  _FrameStats stats, {
  required String label,
  required double maxMeanMs,
  required double maxP95Ms,
}) {
  expect(
    stats.meanMs,
    lessThan(maxMeanMs),
    reason:
        '$label mean ${stats.meanMs.toStringAsFixed(2)}ms exceeded ${maxMeanMs.toStringAsFixed(2)}ms',
  );
  expect(
    stats.p95Ms,
    lessThan(maxP95Ms),
    reason:
        '$label p95 ${stats.p95Ms.toStringAsFixed(2)}ms exceeded ${maxP95Ms.toStringAsFixed(2)}ms',
  );
}

Future<void> _recordStats(
  String scenario,
  _FrameStats stats, {
  Map<String, Object?> tags = const <String, Object?>{},
}) async {
  await PerfReporter.instance.record(
    suite: 'game_loop',
    scenario: scenario,
    metrics: <String, num>{
      'mean_ms': stats.meanMs,
      'p95_ms': stats.p95Ms,
      'max_ms': stats.maxMs,
      'samples': stats.samplesMicros.length,
    },
    tags: tags,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Level2 Loop Performance', () {
    testWidgets('idle loop remains within baseline frame budget', (
      tester,
    ) async {
      final game = await _bootGame(tester);

      // Warm up loading, shader prep, and caches.
      await _measureFrames(tester, frames: 60);

      final stats = await _measureFrames(tester, frames: 180);
      _expectFrameBudget(
        stats,
        label: 'Idle loop',
        maxMeanMs: 12.0,
        maxP95Ms: 20.0,
      );
      await _recordStats('idle_loop', stats);

      await tester.pumpWidget(const SizedBox.shrink());
      game.pauseEngine();
    });

    testWidgets('hydrothermal stress scenario stays within adaptive budget', (
      tester,
    ) async {
      final game = await _bootGame(tester);

      await _measureFrames(tester, frames: 40);
      final baseline = await _measureFrames(tester, frames: 120);

      _seedHydrothermalScenario(game.sandboxWorld);
      await _measureFrames(tester, frames: 30);
      final stress = await _measureFrames(tester, frames: 160);

      final allowedMean = math.max(20.0, baseline.meanMs * 5.0 + 4.0);
      final allowedP95 = math.max(52.0, baseline.p95Ms * 7.0 + 10.0);

      _expectFrameBudget(
        stress,
        label: 'Hydrothermal stress',
        maxMeanMs: allowedMean,
        maxP95Ms: allowedP95,
      );
      await _recordStats(
        'hydrothermal_stress',
        stress,
        tags: <String, Object?>{
          'allowed_mean_ms': allowedMean,
          'allowed_p95_ms': allowedP95,
          'baseline_mean_ms': baseline.meanMs,
          'baseline_p95_ms': baseline.p95Ms,
        },
      );

      await tester.pumpWidget(const SizedBox.shrink());
      game.pauseEngine();
    });

    testWidgets('heavy brush placement does not destabilize frame pacing', (
      tester,
    ) async {
      final game = await _bootGame(tester);

      _seedHydrothermalScenario(game.sandboxWorld);
      await _measureFrames(tester, frames: 40);

      final prePaint = await _measureFrames(tester, frames: 100);

      _stressPaint(game.sandboxWorld);
      await _measureFrames(tester, frames: 20);
      final postPaint = await _measureFrames(tester, frames: 140);

      // Placement can cost more, but should remain bounded.
      expect(
        postPaint.meanMs,
        lessThan(math.max(24.0, prePaint.meanMs * 3.5 + 3.0)),
        reason:
            'Post-paint mean ${postPaint.meanMs.toStringAsFixed(2)}ms was too high',
      );
      expect(
        postPaint.p95Ms,
        lessThan(math.max(34.0, prePaint.p95Ms * 3.5 + 5.0)),
        reason:
            'Post-paint p95 ${postPaint.p95Ms.toStringAsFixed(2)}ms was too high',
      );
      await _recordStats(
        'brush_placement_stress',
        postPaint,
        tags: <String, Object?>{
          'prepaint_mean_ms': prePaint.meanMs,
          'prepaint_p95_ms': prePaint.p95Ms,
        },
      );

      await tester.pumpWidget(const SizedBox.shrink());
      game.pauseEngine();
    });

    testWidgets(
      'world timing instrumentation captures and reports stage timings',
      (tester) async {
        final game = await _bootGame(tester);
        final world = game.sandboxWorld;
        world.showFrameTiming = true;
        world.resetFrameTiming();

        _seedHydrothermalScenario(world);
        await _measureFrames(tester, frames: 120);

        final report = world.frameTimingReport;
        expect(report, contains('Chemistry:'));
        expect(report, contains('Electricity:'));
        expect(report, contains('LightEmit:'));
        expect(report, contains('Luminance:'));
        expect(report, contains('Step:'));
        expect(report, contains('Creatures:'));
        expect(report, contains('TOTAL:'));
        await PerfReporter.instance.record(
          suite: 'game_loop',
          scenario: 'timing_instrumentation_report',
          metrics: <String, num>{'report_length_chars': report.length},
        );

        await tester.pumpWidget(const SizedBox.shrink());
        game.pauseEngine();
      },
    );

    testWidgets('long run frame budget guard catches runaway performance', (
      tester,
    ) async {
      final game = await _bootGame(tester);
      _seedHydrothermalScenario(game.sandboxWorld);
      _stressPaint(game.sandboxWorld);

      await _measureFrames(tester, frames: 60);
      final stats = await _measureFrames(tester, frames: 300);

      _expectFrameBudget(
        stats,
        label: 'Long-run mixed stress',
        maxMeanMs: 24.0,
        maxP95Ms: 56.0,
      );
      expect(
        stats.maxMs,
        lessThan(100.0),
        reason: 'Detected a single extreme frame spike (${stats.maxMs}ms)',
      );
      await _recordStats('long_run_mixed_stress', stats);

      await tester.pumpWidget(const SizedBox.shrink());
      game.pauseEngine();
    });
  });
}
