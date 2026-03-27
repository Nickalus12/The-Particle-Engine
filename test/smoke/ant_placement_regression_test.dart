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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ant placement follows camera-aware screen coordinate mapping',
      (tester) async {
    final game = await _boot(tester);
    final SandboxWorld world = game.sandboxWorld;
    final SandboxComponent sandbox = world.sandboxComponent;

    // Move camera to force coordinate conversion path.
    game.camera.viewfinder.position.x = 120;
    game.camera.viewfinder.position.y = 32;
    game.camera.viewfinder.zoom = 2.0;

    sandbox.selectedElement = El.ant;
    sandbox.brushSize = 2;

    final viewport = game.camera.viewport.size;
    final tap = Offset(viewport.x / 2, viewport.y / 2);
    final expected = sandbox.viewportToGrid(Vector2(tap.dx, tap.dy));
    final groundY = (expected.$2 + 10).clamp(2, game.gridHeight - 2);
    final groundIdx = groundY * world.simulation.gridW + expected.$1;
    world.simulation.grid[groundIdx] = El.stone;

    sandbox.paintAtScreen(Vector2(tap.dx, tap.dy));
    await tester.pump(const Duration(milliseconds: 16));

    expect(world.creatures.colonies.isNotEmpty, isTrue,
        reason: 'Placing ant should spawn a colony.');
    final colony = world.creatures.colonies.first;
    expect(colony.originX, expected.$1,
        reason:
            'Colony X should match camera-aware screen->grid conversion.');
    expect(colony.originY, groundY - 1,
        reason: 'Colony should settle directly above deterministic ground.');
  });

  testWidgets('viewport center resolves to the camera focus cell', (tester) async {
    final game = await _boot(tester);
    final sandbox = game.sandboxWorld.sandboxComponent;

    game.camera.viewfinder.position = Vector2(80, 48);
    game.camera.viewfinder.zoom = 2.0;

    final viewport = game.camera.viewport.size;
    final centerCell = sandbox.viewportToGrid(
      Vector2(viewport.x / 2, viewport.y / 2),
    );

    expect(centerCell.$1, 20);
    expect(centerCell.$2, 12);
  });
}
