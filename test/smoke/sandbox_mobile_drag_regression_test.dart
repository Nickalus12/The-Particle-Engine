import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/game/particle_engine_game.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/world_gen/world_config.dart';
import 'package:the_particle_engine/ui/screens/sandbox_screen.dart';

Future<void> _waitForSandboxReady(WidgetTester tester) async {
  for (int i = 0; i < 260; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (find.byIcon(Icons.brush_rounded).evaluate().isNotEmpty) {
      return;
    }
  }
  throw StateError('Sandbox screen did not load in time.');
}

ParticleEngineGame _gameFromWidgetTree(WidgetTester tester) {
  final finder = find.byWidgetPredicate(
    (widget) => widget is GameWidget<ParticleEngineGame>,
  );
  final widget = tester.widget<GameWidget<ParticleEngineGame>>(finder);
  return widget.game!;
}

int _countFilledCells(ParticleEngineGame game) {
  int count = 0;
  final grid = game.sandboxWorld.simulation.grid;
  for (final el in grid) {
    if (el != El.empty) {
      count++;
    }
  }
  return count;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mobile hud touches do not leak into world painting', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: SandboxScreen(isBlankCanvas: true),
      ),
    );

    await _waitForSandboxReady(tester);
    await tester.tap(find.byIcon(Icons.brush_rounded));
    await tester.pump(const Duration(milliseconds: 350));

    final game = _gameFromWidgetTree(tester);
    expect(_countFilledCells(game), 0);

    final toolbarRect =
        tester.getRect(find.byKey(const ValueKey('tool_bar_container')));
    await tester.tapAt(toolbarRect.center);
    await tester.pump(const Duration(milliseconds: 120));

    expect(
      _countFilledCells(game),
      0,
      reason: 'Touching toolbar must not create painted cells in the world.',
    );
  });

  testWidgets('mobile drag paints a continuous stroke in world space', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: SandboxScreen(isBlankCanvas: true),
      ),
    );

    await _waitForSandboxReady(tester);
    await tester.tap(find.byIcon(Icons.brush_rounded));
    await tester.pump(const Duration(milliseconds: 350));

    final game = _gameFromWidgetTree(tester);
    final viewportRect = tester.getRect(
      find.byWidgetPredicate((widget) => widget is GameWidget<ParticleEngineGame>),
    );
    final bottomBarRect =
        tester.getRect(find.byKey(const ValueKey('element_bottom_bar_container')));

    final paintY = (viewportRect.center.dy + bottomBarRect.top) / 2;
    final start = Offset(viewportRect.left + 28, paintY);
    final end = Offset(viewportRect.right - 28, paintY);

    final gesture = await tester.startGesture(start);
    for (int i = 1; i <= 20; i++) {
      final t = i / 20.0;
      final point = Offset.lerp(start, end, t)!;
      await gesture.moveTo(point);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 120));

    final sim = game.sandboxWorld.simulation;
    final sandbox = game.sandboxWorld.sandboxComponent;

    final checkpoints = <double>[0.15, 0.35, 0.55, 0.75, 0.9];
    for (final t in checkpoints) {
      final point = Offset.lerp(start, end, t)!;
      final local = point - viewportRect.topLeft;
      final (x, y) = sandbox.viewportToGrid(Vector2(local.dx, local.dy));
      final idx = y * sim.gridW + x;
      expect(
        sim.grid[idx],
        isNot(El.empty),
        reason: 'Expected painted stroke coverage at t=$t.',
      );
    }
  });

  testWidgets('mobile generated world still accepts drag paint input', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: SandboxScreen(
          worldConfig: WorldConfig.meadow(seed: 99),
        ),
      ),
    );

    await _waitForSandboxReady(tester);
    await tester.tap(find.byIcon(Icons.brush_rounded));
    await tester.pump(const Duration(milliseconds: 450));

    final game = _gameFromWidgetTree(tester);
    final beforeFilled = _countFilledCells(game);
    final viewportRect = tester.getRect(
      find.byWidgetPredicate((widget) => widget is GameWidget<ParticleEngineGame>),
    );

    final start = Offset(viewportRect.left + 24, viewportRect.top + 120);
    final end = Offset(viewportRect.right - 24, viewportRect.top + 140);

    final gesture = await tester.startGesture(start);
    for (int i = 1; i <= 16; i++) {
      final t = i / 16.0;
      await gesture.moveTo(Offset.lerp(start, end, t)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 150));

    final afterFilled = _countFilledCells(game);
    expect(
      afterFilled,
      greaterThan(beforeFilled + 15),
      reason: 'World generation mode must remain paintable during drag input.',
    );
  });

  testWidgets('mobile paint still works in left lane below toolbar controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: SandboxScreen(isBlankCanvas: true),
      ),
    );

    await _waitForSandboxReady(tester);
    await tester.tap(find.byIcon(Icons.brush_rounded));
    await tester.pump(const Duration(milliseconds: 350));

    final game = _gameFromWidgetTree(tester);
    final sim = game.sandboxWorld.simulation;
    final sandbox = game.sandboxWorld.sandboxComponent;
    final viewportRect = tester.getRect(
      find.byWidgetPredicate((widget) => widget is GameWidget<ParticleEngineGame>),
    );
    final toolbarRect =
        tester.getRect(find.byKey(const ValueKey('tool_bar_container')));
    final bottomBarRect =
        tester.getRect(find.byKey(const ValueKey('element_bottom_bar_container')));

    final tapPoint = Offset(
      toolbarRect.center.dx,
      (toolbarRect.bottom + bottomBarRect.top) / 2,
    );

    await tester.tapAt(tapPoint);
    await tester.pump(const Duration(milliseconds: 120));

    final local = tapPoint - viewportRect.topLeft;
    final (x, y) = sandbox.viewportToGrid(Vector2(local.dx, local.dy));
    final idx = y * sim.gridW + x;
    expect(
      sim.grid[idx],
      isNot(El.empty),
      reason:
          'Touching below toolbar controls should still reach world painting.',
    );
  });
}
