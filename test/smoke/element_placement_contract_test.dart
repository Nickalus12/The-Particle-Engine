import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/game/components/sandbox_component.dart';
import 'package:the_particle_engine/game/particle_engine_game.dart';
import 'package:the_particle_engine/game/sandbox_world.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';

Future<void> _waitLoaded(WidgetTester tester, ParticleEngineGame game) async {
  for (int i = 0; i < 220; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (!game.isLoaded) continue;
    final world = game.sandboxWorld;
    if (world.isLoaded && world.sandboxComponent.isLoaded) return;
  }
  throw StateError('Game failed to load in time.');
}

Future<ParticleEngineGame> _boot(WidgetTester tester) async {
  ElementRegistry.init();
  final game = ParticleEngineGame(
    isBlankCanvas: true,
    gridWidth: 96,
    gridHeight: 64,
    cellSize: 4.0,
  );
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: GameWidget<ParticleEngineGame>(game: game),
    ),
  );
  await _waitLoaded(tester, game);
  return game;
}

Iterable<(int x, int y)> _brushCells(
  SandboxWorld world,
  int cx,
  int cy,
  int radius,
) sync* {
  final r2 = radius * radius;
  for (int dy = -radius; dy <= radius; dy++) {
    for (int dx = -radius; dx <= radius; dx++) {
      if (dx * dx + dy * dy > r2) continue;
      final nx = world.simulation.wrapX(cx + dx);
      final ny = cy + dy;
      if (!world.simulation.inBoundsY(ny)) continue;
      yield (x: nx, y: ny);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('placement initializes mass and eraser clears same brush area', (
    tester,
  ) async {
    final game = await _boot(tester);
    final SandboxWorld world = game.sandboxWorld;
    final SandboxComponent sandbox = world.sandboxComponent;
    final sim = world.simulation;

    sandbox.selectedElement = El.water;
    sandbox.brushSize = 2;
    sandbox.lastPaintX = null;
    sandbox.lastPaintY = null;

    final viewport = game.camera.viewport.size;
    final tap = Vector2(viewport.x / 2, viewport.y / 2);
    final center = sandbox.viewportToGrid(tap);
    final cells = _brushCells(world, center.$1, center.$2, sandbox.brushSize);

    sandbox.paintAtScreen(tap);
    await tester.pump(const Duration(milliseconds: 16));

    int waterCount = 0;
    for (final cell in cells) {
      final idx = cell.y * sim.gridW + cell.x;
      if (sim.grid[idx] == El.water) {
        waterCount++;
        expect(
          sim.mass[idx],
          elementBaseMass[El.water],
          reason: 'Placed water cell should get base mass initialization.',
        );
      }
    }
    expect(waterCount, greaterThan(0));
    final placedMetrics = sandbox.capturePlacementMetrics();
    expect(placedMetrics.paintStampsTotal, greaterThan(0));
    expect(placedMetrics.cellsModifiedTotal, greaterThan(0));
    expect(placedMetrics.cellsPaintedTotal, greaterThan(0));

    sandbox.selectedElement = El.eraser;
    sandbox.lastPaintX = null;
    sandbox.lastPaintY = null;
    sandbox.paintAtScreen(tap);
    await tester.pump(const Duration(milliseconds: 16));

    for (final cell in _brushCells(
      world,
      center.$1,
      center.$2,
      sandbox.brushSize,
    )) {
      final idx = cell.y * sim.gridW + cell.x;
      expect(sim.grid[idx], El.empty);
    }
    final erasedMetrics = sandbox.capturePlacementMetrics();
    expect(erasedMetrics.cellsErasedTotal, greaterThan(0));
    expect(
      erasedMetrics.cellsModifiedTotal,
      greaterThan(placedMetrics.cellsModifiedTotal),
    );
  });

  testWidgets('drag interpolation paints continuous horizontal line', (
    tester,
  ) async {
    final game = await _boot(tester);
    final SandboxComponent sandbox = game.sandboxWorld.sandboxComponent;
    final sim = game.sandboxWorld.simulation;

    sandbox.selectedElement = El.sand;
    sandbox.brushSize = 1;
    sandbox.lastPaintX = null;
    sandbox.lastPaintY = null;

    final startGridX = 12;
    final endGridX = 26;
    final y = 18;
    sandbox.paintAt(
      Vector2(startGridX * sandbox.cellSize, y * sandbox.cellSize),
    );
    sandbox.paintAt(Vector2(endGridX * sandbox.cellSize, y * sandbox.cellSize));
    await tester.pump(const Duration(milliseconds: 16));

    for (int x = startGridX; x <= endGridX; x++) {
      final idx = y * sim.gridW + sim.wrapX(x);
      expect(
        sim.grid[idx],
        El.sand,
        reason: 'Interpolated drag should not leave gaps at x=$x.',
      );
    }
    final metrics = sandbox.capturePlacementMetrics();
    expect(metrics.lineSegmentsTotal, greaterThan(0));
    expect(metrics.linePointsTotal, greaterThan(0));
  });
}
