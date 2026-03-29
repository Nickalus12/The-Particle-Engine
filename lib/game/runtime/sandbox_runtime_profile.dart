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
    required this.mobileRenderInterval,
    required this.mobilePostProcessInterval,
    required this.mobileCreatureDetail,
  });

  final int gridWidth;
  final int gridHeight;
  final double cellSize;
  final int mobileRenderInterval;
  final int mobilePostProcessInterval;
  final bool mobileCreatureDetail;

  static const SandboxRuntimeProfile desktop = SandboxRuntimeProfile(
    gridWidth: 320,
    gridHeight: 180,
    cellSize: 4.0,
    mobileRenderInterval: 1,
    mobilePostProcessInterval: 1,
    mobileCreatureDetail: true,
  );

  static const SandboxRuntimeProfile tablet = SandboxRuntimeProfile(
    gridWidth: 256,
    gridHeight: 144,
    cellSize: 4.0,
    mobileRenderInterval: 2,
    mobilePostProcessInterval: 4,
    mobileCreatureDetail: false,
  );

  static const SandboxRuntimeProfile phone = SandboxRuntimeProfile(
    gridWidth: 208,
    gridHeight: 117,
    cellSize: 4.0,
    mobileRenderInterval: 3,
    mobilePostProcessInterval: 6,
    mobileCreatureDetail: false,
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
