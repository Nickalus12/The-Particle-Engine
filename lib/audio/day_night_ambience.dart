import 'audio_manager.dart';

/// Manages day/night ambient sound crossfading.
///
/// Maintains two ambient layers — a warm daytime tone and a cooler nighttime
/// atmosphere (crickets, etc.) — and crossfades between them over the same
/// 60-frame transition the visual system uses.
///
/// When the camera is underground the day/night layers are replaced with an
/// underground ambience.
class DayNightAmbience {
  DayNightAmbience({required AudioManager audioManager})
      : _audio = audioManager;

  final AudioManager _audio;

  // ── State ─────────────────────────────────────────────────────────────
  bool _isNight = false;
  bool _isUnderground = false;

  /// Current blend: 0.0 = full day, 1.0 = full night.
  double _blend = 0.0;

  /// Underground blend: 0.0 = surface, 1.0 = full underground.
  double _undergroundBlend = 0.0;

  /// Number of frames for a full transition.
  static const int _transitionFrames = 60;

  /// Blend delta per frame.
  static const double _blendStep = 1.0 / _transitionFrames;

  // ── Assets ────────────────────────────────────────────────────────────
  static const String _dayAsset = 'ambient/day_ambience.wav';
  static const String _nightAsset = 'ambient/night_ambience.wav';
  static const String _undergroundAsset = 'ambient/underground.wav';

  // ── Public API ────────────────────────────────────────────────────────

  /// Set the time-of-day state. The crossfade happens gradually.
  set isNight(bool value) => _isNight = value;

  /// Set underground state. Overrides day/night when active.
  set isUnderground(bool value) => _isUnderground = value;

  /// Call every frame to advance crossfade interpolation.
  void update() {
    // Day/night blend.
    final dayNightTarget = _isNight ? 1.0 : 0.0;
    if (_blend < dayNightTarget) {
      _blend = (_blend + _blendStep).clamp(0.0, 1.0);
    } else if (_blend > dayNightTarget) {
      _blend = (_blend - _blendStep).clamp(0.0, 1.0);
    }

    // Underground blend.
    final ugTarget = _isUnderground ? 1.0 : 0.0;
    if (_undergroundBlend < ugTarget) {
      _undergroundBlend = (_undergroundBlend + _blendStep).clamp(0.0, 1.0);
    } else if (_undergroundBlend > ugTarget) {
      _undergroundBlend = (_undergroundBlend - _blendStep).clamp(0.0, 1.0);
    }
  }

  /// Returns the effective volumes for each ambient layer.
  ///
  /// When underground, day/night volumes are suppressed and replaced by the
  /// underground layer.
  ({double day, double night, double underground}) get volumes {
    final masterAmbient = _audio.effectiveAmbientVolume;
    final surfaceFactor = 1.0 - _undergroundBlend;

    return (
      day: (1.0 - _blend) * surfaceFactor * masterAmbient,
      night: _blend * surfaceFactor * masterAmbient,
      underground: _undergroundBlend * masterAmbient,
    );
  }

  /// Asset paths for the three layers (for the game shell to manage playback).
  static const dayAsset = _dayAsset;
  static const nightAsset = _nightAsset;
  static const undergroundAsset = _undergroundAsset;

  void dispose() {
    // Nothing to release — audio resources are managed by the game shell.
  }
}
