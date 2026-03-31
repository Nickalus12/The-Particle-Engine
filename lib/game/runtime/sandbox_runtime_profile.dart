import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../../models/game_state.dart';
import '../../rendering/render_quality_profile.dart';

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
    required this.renderQualityProfile,
  });

  final int gridWidth;
  final int gridHeight;
  final double cellSize;
  final int mobileRenderInterval;
  final int mobilePostProcessInterval;
  final bool mobileCreatureDetail;
  final RenderQualityProfile renderQualityProfile;

  static const SandboxRuntimeProfile desktop = SandboxRuntimeProfile(
    gridWidth: 320,
    gridHeight: 180,
    cellSize: 4.0,
    mobileRenderInterval: 1,
    mobilePostProcessInterval: 1,
    mobileCreatureDetail: true,
    renderQualityProfile: RenderQualityProfile.desktopUltra,
  );

  static const SandboxRuntimeProfile tablet = SandboxRuntimeProfile(
    gridWidth: 256,
    gridHeight: 144,
    cellSize: 4.0,
    mobileRenderInterval: 2,
    mobilePostProcessInterval: 4,
    mobileCreatureDetail: false,
    renderQualityProfile: RenderQualityProfile.tabletBalanced,
  );

  static const SandboxRuntimeProfile phone = SandboxRuntimeProfile(
    gridWidth: 208,
    gridHeight: 117,
    cellSize: 4.0,
    mobileRenderInterval: 3,
    mobilePostProcessInterval: 6,
    mobileCreatureDetail: false,
    renderQualityProfile: RenderQualityProfile.phoneBalanced,
  );

  static const SandboxRuntimeProfile phoneSurvival = SandboxRuntimeProfile(
    gridWidth: 184,
    gridHeight: 104,
    cellSize: 4.0,
    mobileRenderInterval: 4,
    mobilePostProcessInterval: 8,
    mobileCreatureDetail: false,
    renderQualityProfile: RenderQualityProfile.phoneSurvival,
  );

  /// Resolve the runtime profile for the current device class.
  ///
  /// Saved games keep their serialized grid dimensions so load fidelity is not
  /// changed by profile heuristics.
  static SandboxRuntimeProfile resolve({
    required Size viewportSize,
    GameState? loadState,
  }) {
    final handheldDefault = _isHandheldPlatform
        ? (viewportSize.shortestSide >= 700
              ? tablet
              : (viewportSize.shortestSide < 380 ? phoneSurvival : phone))
        : desktop;
    if (loadState != null) {
      return SandboxRuntimeProfile(
        gridWidth: loadState.gridW,
        gridHeight: loadState.gridH,
        cellSize: 4.0,
        mobileRenderInterval: handheldDefault.mobileRenderInterval,
        mobilePostProcessInterval: handheldDefault.mobilePostProcessInterval,
        mobileCreatureDetail: handheldDefault.mobileCreatureDetail,
        renderQualityProfile: handheldDefault.renderQualityProfile,
      );
    }

    if (!_isHandheldPlatform) {
      return desktop;
    }

    if (viewportSize.shortestSide >= 700) {
      return tablet;
    }
    if (viewportSize.shortestSide < 380) {
      return phoneSurvival;
    }
    return phone;
  }

  static bool get _isHandheldPlatform {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }
}
