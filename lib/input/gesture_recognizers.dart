/// Gesture recognition for the sandbox.
///
/// The primary input separation (single-finger draw vs two-finger camera)
/// is handled by Flame's built-in [ScaleDetector] mixin on
/// [ParticleEngineGame]. The game's [onScaleUpdate] checks
/// [ScaleStartInfo.pointerCount] to distinguish between drawing (1 finger)
/// and camera control (2 fingers).
///
/// Flame's component-level [TapCallbacks] and [DragCallbacks] on
/// [SandboxComponent] handle single-finger element placement, while the
/// game-level [ScaleDetector] handles two-finger zoom and pan.
///
/// This file provides configuration constants and utility for gesture
/// thresholds used by the Flame input system.
library;

/// Gesture routing constants used by the game's ScaleDetector and
/// component-level callbacks.
class GestureConfig {
  GestureConfig._();

  /// Minimum number of pointers required for camera gestures.
  static const int cameraPointerThreshold = 2;

  /// Minimum pinch scale delta to register as a zoom (vs noise).
  static const double minZoomDelta = 0.01;

  /// Minimum drag distance (in logical pixels) to register as a pan.
  static const double minPanDistance = 2.0;
}
