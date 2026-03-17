/// User-adjustable sandbox parameters.
///
/// These are exposed through the settings screen and persisted via
/// [SettingsService]. They control simulation speed, grid size, and
/// visual/audio preferences.
class SandboxConfig {
  SandboxConfig({
    this.simulationSpeed = 1.0,
    this.brushSize = 3,
    this.soundEnabled = true,
    this.hapticsEnabled = true,
    this.showMiniMap = true,
    this.showFps = false,
  });

  /// Multiplier applied to the simulation tick rate (0.25x – 4x).
  double simulationSpeed;

  /// Radius (in cells) of the element brush.
  int brushSize;

  /// Whether sound effects are enabled.
  bool soundEnabled;

  /// Whether haptic feedback fires on interactions.
  bool hapticsEnabled;

  /// Whether the mini-map overlay is visible.
  bool showMiniMap;

  /// Whether the FPS counter is shown.
  bool showFps;
}
