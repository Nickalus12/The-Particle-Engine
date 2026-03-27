import 'dart:ui';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/game/runtime/sandbox_runtime_profile.dart';
import 'package:the_particle_engine/models/game_state.dart';

void main() {
  test('saved states preserve their serialized grid dimensions', () {
    final state = GameState(
      gridW: 192,
      gridH: 108,
      grid: Uint8List(192 * 108),
      life: Uint8List(192 * 108),
      velX: Int8List(192 * 108),
      velY: Int8List(192 * 108),
    );

    final profile = SandboxRuntimeProfile.resolve(
      viewportSize: const Size(390, 844),
      loadState: state,
    );

    expect(profile.gridWidth, 192);
    expect(profile.gridHeight, 108);
    expect(profile.cellSize, 4.0);
  });

  test('handheld profiles stay below desktop simulation size', () {
    final profile = SandboxRuntimeProfile.resolve(
      viewportSize: const Size(390, 844),
    );

    expect(profile.gridWidth, lessThanOrEqualTo(320));
    expect(profile.gridHeight, lessThanOrEqualTo(180));
  });
}
