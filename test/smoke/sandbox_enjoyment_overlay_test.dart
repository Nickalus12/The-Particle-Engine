import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/game/particle_engine_game.dart';
import 'package:the_particle_engine/ui/screens/sandbox_screen.dart';

Future<void> _waitForSandboxReady(WidgetTester tester) async {
  for (int i = 0; i < 260; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (find
        .byKey(const ValueKey('sandbox_enjoyment_overlay'))
        .evaluate()
        .isNotEmpty) {
      return;
    }
  }
  throw StateError('Sandbox enjoyment overlay did not appear in time.');
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

  testWidgets('sandbox enjoyment overlay renders status, goals, and feed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(home: SandboxScreen(isBlankCanvas: true)),
    );

    await _waitForSandboxReady(tester);

    expect(find.byKey(const ValueKey('sandbox_status_strip')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sandbox_objectives_panel')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('sandbox_event_feed')), findsOneWidget);
    expect(find.text('Active Goals'), findsOneWidget);
    expect(find.text('World Feed'), findsOneWidget);
  });

  testWidgets('sandbox enjoyment overlay reflects colony milestones', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(home: SandboxScreen(isBlankCanvas: true)),
    );

    await _waitForSandboxReady(tester);
    final game = _gameFromWidgetTree(tester);

    game.sandboxWorld.spawnColony(20, 20);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.text('1 colonies'), findsOneWidget);
    expect(find.textContaining('Colony 1'), findsWidgets);
    expect(find.textContaining('Queen established'), findsOneWidget);
  });
}
