import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../../models/game_state.dart';

/// Runtime sizing profile for the sandbox.
///
/// Mobile runs need a smaller simulation envelope than desktop to keep world
/// generation and steady-state simulation inside an acceptable budget.
class SandboxRuntimeProfile {
  const SandboxRuntimeProfile({
    required this.gridWidth,
    required this.gridHeight,
    required this.cellSize,
  });

  final int gridWidth;
  final int gridHeight;
  final double cellSize;

  static const SandboxRuntimeProfile desktop = SandboxRuntimeProfile(
    gridWidth: 320,
    gridHeight: 180,
    cellSize: 4.0,
  );

  static const SandboxRuntimeProfile tablet = SandboxRuntimeProfile(
    gridWidth: 288,
    gridHeight: 162,
    cellSize: 4.0,
  );

  static const SandboxRuntimeProfile phone = SandboxRuntimeProfile(
    gridWidth: 240,
    gridHeight: 135,
    cellSize: 4.0,
  );

  /// Resolve the runtime profile for the current device class.
  ///
  /// Saved games keep their serialized grid dimensions so load fidelity is not
  /// changed by profile heuristics.
  static SandboxRuntimeProfile resolve({
    required Size viewportSize,
    GameState? loadState,
  }) {
    if (loadState != null) {
      return SandboxRuntimeProfile(
        gridWidth: loadState.gridW,
        gridHeight: loadState.gridH,
        cellSize: 4.0,
      );
    }

    if (!_isHandheldPlatform) {
      return desktop;
    }

    final shortestSide = viewportSize.shortestSide;
    if (shortestSide >= 700) {
      return tablet;
    }
    return phone;
  }

  static bool get _isHandheldPlatform {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }
}
