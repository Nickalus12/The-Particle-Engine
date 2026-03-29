import 'package:flame/game.dart';
import 'package:flame/components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/game/particle_engine_game.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/ui/screens/sandbox_screen.dart';

Future<void> _waitForHud(WidgetTester tester) async {
  for (int i = 0; i < 260; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (find.byIcon(Icons.brush_rounded).evaluate().isNotEmpty) return;
  }
  throw StateError('HUD did not become interactive in time.');
}

ParticleEngineGame _game(WidgetTester tester) {
  final finder = find.byWidgetPredicate(
    (widget) => widget is GameWidget<ParticleEngineGame>,
  );
  return tester.widget<GameWidget<ParticleEngineGame>>(finder).game!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('HUD visible still allows painting in open viewport regions', (
    tester,
  ) async {
    ElementRegistry.init();
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(home: SandboxScreen(isBlankCanvas: true)),
    );
    await _waitForHud(tester);

    // Enter creation mode so HUD is visible.
    await tester.tap(find.byIcon(Icons.brush_rounded));
    await tester.pump(const Duration(milliseconds: 350));

    final game = _game(tester);
    final sim = game.sandboxWorld.simulation;
    final viewportRect = tester.getRect(
      find.byWidgetPredicate((w) => w is GameWidget<ParticleEngineGame>),
    );

    // Choose a point away from left toolbar and bottom bar.
    final targetPoint = Offset(
      viewportRect.left + viewportRect.width * 0.72,
      viewportRect.top + viewportRect.height * 0.38,
    );
    final local = game.viewportGlobalToLocal?.call(targetPoint) ?? targetPoint;
    final grid = game.sandboxWorld.sandboxComponent.viewportToGrid(
      Vector2(local.dx, local.dy),
    );
    final idx = grid.$2 * sim.gridW + grid.$1;
    final before = sim.grid[idx];

    await tester.tapAt(targetPoint);
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      sim.grid[idx],
      isNot(before),
      reason: 'HUD must not block painting in non-HUD viewport regions.',
    );
  });
}
