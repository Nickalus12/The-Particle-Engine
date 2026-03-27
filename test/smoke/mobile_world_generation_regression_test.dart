import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/game/particle_engine_game.dart';
import 'package:the_particle_engine/simulation/world_gen/world_config.dart';

Future<void> _waitLoaded(WidgetTester tester, ParticleEngineGame game) async {
  for (int i = 0; i < 260; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (!game.isLoaded) continue;
    if (game.sandboxWorld.isLoaded && game.sandboxWorld.sandboxComponent.isLoaded) {
      return;
    }
  }
  throw StateError('Game failed to load in time.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('world generation preserves runtime grid dimensions', (
    tester,
  ) async {
    final game = ParticleEngineGame(
      worldConfig: WorldConfig.meadow(seed: 7),
      gridWidth: 240,
      gridHeight: 135,
      cellSize: 4.0,
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: GameWidget<ParticleEngineGame>(game: game),
      ),
    );
    await _waitLoaded(tester, game);

    expect(game.sandboxWorld.simulation.gridW, 240);
    expect(game.sandboxWorld.simulation.gridH, 135);
    expect(
      game.sandboxWorld.sandboxComponent.simulation.grid.length,
      240 * 135,
    );
  });
}
