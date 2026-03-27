import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/game/particle_engine_game.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mobile sandbox screen can paint into the world', (tester) async {
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
    final targetX = sim.gridW ~/ 2;
    final targetY = sim.gridH ~/ 2;
    final idx = targetY * sim.gridW + targetX;

    expect(sim.grid[idx], El.empty);

    final viewportFinder = find.byWidgetPredicate(
      (widget) => widget is GameWidget<ParticleEngineGame>,
    );
    final viewportRect = tester.getRect(viewportFinder);
    final tapPoint = viewportRect.center;

    await tester.tapAt(tapPoint);
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      sim.grid[idx],
      isNot(El.empty),
      reason: 'A tap in the center of the sandbox should paint a cell.',
    );
  });
}
