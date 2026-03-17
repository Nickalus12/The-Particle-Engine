import 'dart:math';

/// Provides position-based audio scaling.
///
/// Takes the camera position, zoom level, and an event's world position to
/// produce a volume multiplier and a stereo pan value. This is an
/// approximation — not true 3D audio — but enough to convey spatial presence.
class SpatialAudio {
  /// Current camera centre in world coordinates (set each frame).
  double cameraX = 0;
  double cameraY = 0;

  /// Screen width in world units (set each frame).
  double viewportWidth = 1;

  /// Current zoom level (1.0 = default). Higher = zoomed in.
  double zoom = 1.0;

  /// Update camera state. Call once per frame.
  void updateCamera({
    required double cameraX,
    required double cameraY,
    required double viewportWidth,
    required double zoom,
  }) {
    this.cameraX = cameraX;
    this.cameraY = cameraY;
    this.viewportWidth = viewportWidth;
    this.zoom = zoom;
  }

  /// Compute a volume multiplier (0.0–1.0) for a sound at [worldX], [worldY].
  ///
  /// Sounds near the camera centre are louder; sounds far away fade.
  /// Zooming in increases perceived volume (closer view → louder).
  double volumeAt(double worldX, double worldY) {
    final dx = worldX - cameraX;
    final dy = worldY - cameraY;
    final distance = sqrt(dx * dx + dy * dy);

    // Audible radius scales inversely with zoom (zoomed in = smaller area but
    // louder sounds within it).
    final audibleRadius = viewportWidth / zoom;
    if (audibleRadius <= 0) return 0.0;

    // Linear falloff from 1.0 at centre to 0.0 at the audible edge.
    final normalised = (distance / audibleRadius).clamp(0.0, 1.0);
    final volume = 1.0 - normalised;

    // Boost slightly when zoomed in.
    final zoomBoost = (zoom / 2.0).clamp(0.5, 1.5);
    return (volume * zoomBoost).clamp(0.0, 1.0);
  }

  /// Compute a stereo pan value (-1.0 left … 0.0 centre … 1.0 right) for a
  /// sound at [worldX].
  double panAt(double worldX) {
    if (viewportWidth <= 0) return 0.0;
    final dx = worldX - cameraX;
    // Map position relative to viewport half-width.
    return (dx / (viewportWidth * 0.5)).clamp(-1.0, 1.0);
  }
}
