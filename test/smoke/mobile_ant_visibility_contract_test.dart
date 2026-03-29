import 'package:flame/game.dart';
import 'package:flame/components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/game/particle_engine_game.dart';
import 'package:the_particle_engine/game/sandbox_world.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';

Future<void> _waitLoaded(WidgetTester tester, ParticleEngineGame game) async {
  for (int i = 0; i < 260; i++) {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mobile colony placement renders visible ants after warmup', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final game = await _boot(tester);
    final SandboxWorld world = game.sandboxWorld;
    final sandbox = world.sandboxComponent;
    sandbox.selectedElement = El.ant;

    final viewport = game.camera.viewport.size;
    final tap = Offset(viewport.x / 2, viewport.y / 2);
    sandbox.paintAtScreen(Vector2(tap.dx, tap.dy));

    for (int i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final snapshot = world.captureCreatureRuntimeSnapshot().toJson();
    expect(snapshot['colony_count'], greaterThanOrEqualTo(1));
    expect(snapshot['creature_population_alive'], greaterThan(0));
    expect(snapshot['creature_population_rendered'], greaterThan(0));
  });
}
