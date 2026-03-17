import 'dart:math';

import '../simulation/element_registry.dart';
import 'audio_manager.dart';

/// An individual ambient sound layer that fades smoothly toward a target
/// volume.
class _AmbientLayer {
  _AmbientLayer({required this.assetName});

  final String assetName;
  double currentVolume = 0.0;
  double targetVolume = 0.0;

  /// Smoothly step [currentVolume] toward [targetVolume].
  void smoothStep(double lerpFactor) {
    currentVolume += (targetVolume - currentVolume) * lerpFactor;
    // Snap to zero when very quiet.
    if (currentVolume < 0.005) currentVolume = 0.0;
  }
}

/// Dynamically mixes ambient sound layers based on element counts visible in
/// the simulation.
///
/// Each element type maps to an ambient sound (water flow, fire crackle, etc.)
/// whose volume scales proportionally with the count of that element on screen.
/// Layers crossfade smoothly — never popping in/out.
class AmbientMixer {
  AmbientMixer({required AudioManager audioManager})
      : _audio = audioManager;

  final AudioManager _audio;

  /// Maximum concurrent ambient layers to limit CPU/memory.
  static const int _maxConcurrentLayers = 8;

  /// How many frames between updates (throttle).
  static const int _updateInterval = 10;
  int _frameCounter = 0;

  /// Lerp factor per update tick — controls fade speed.
  static const double _lerpFactor = 0.08;

  // ── Layer definitions ─────────────────────────────────────────────────
  final Map<String, _AmbientLayer> _layers = {
    'water': _AmbientLayer(assetName: 'ambient/water_flow.wav'),
    'fire': _AmbientLayer(assetName: 'ambient/fire_crackle.wav'),
    'lava': _AmbientLayer(assetName: 'ambient/lava_rumble.wav'),
    'wind': _AmbientLayer(assetName: 'ambient/wind.wav'),
    'ants': _AmbientLayer(assetName: 'ambient/ants_chittering.wav'),
    'underground': _AmbientLayer(assetName: 'ambient/underground.wav'),
  };

  /// Whether the camera is currently underground (set externally).
  bool _isUnderground = false;
  set isUnderground(bool value) => _isUnderground = value;

  /// Whether the wind system is active (set externally).
  bool _windActive = false;
  set windActive(bool value) => _windActive = value;

  /// Update ambient volumes based on current element counts.
  ///
  /// [elementCounts] maps element type int constants (from [El]) to counts.
  /// Should be called every frame; internally throttled to
  /// [_updateInterval] frames.
  void update(Map<int, int> elementCounts) {
    _frameCounter++;
    if (_frameCounter < _updateInterval) return;
    _frameCounter = 0;

    // Compute target volumes from element counts.
    _layers['water']!.targetVolume = _countToVolume(
      elementCounts[El.water] ?? 0, 50,
    );
    _layers['fire']!.targetVolume = _countToVolume(
      elementCounts[El.fire] ?? 0, 30,
    );
    _layers['lava']!.targetVolume = _countToVolume(
      elementCounts[El.lava] ?? 0, 20,
    );
    _layers['wind']!.targetVolume = _windActive ? 0.5 : 0.0;
    _layers['underground']!.targetVolume = _isUnderground ? 0.6 : 0.0;

    // Smooth-step all layers.
    for (final layer in _layers.values) {
      layer.smoothStep(_lerpFactor);
    }
  }

  /// Set ant count directly (ants are tracked separately).
  void setAntCount(int count) {
    _layers['ants']!.targetVolume = _countToVolume(count, 40);
  }

  /// Convert an element [count] to a 0.0–1.0 volume, reaching full at
  /// [fullAt] elements.
  double _countToVolume(int count, int fullAt) {
    if (count <= 0) return 0.0;
    return min(count / fullAt, 1.0);
  }

  /// Returns the current effective volume for each layer, sorted by
  /// loudest first, capped at [_maxConcurrentLayers].
  Map<String, double> getActiveVolumes() {
    final entries = _layers.entries
        .where((e) => e.value.currentVolume > 0)
        .toList()
      ..sort((a, b) => b.value.currentVolume.compareTo(a.value.currentVolume));

    final capped = entries.take(_maxConcurrentLayers);
    final masterAmbient = _audio.effectiveAmbientVolume;

    return {
      for (final e in capped)
        e.key: (e.value.currentVolume * masterAmbient).clamp(0.0, 1.0),
    };
  }

  /// Release all audio resources.
  void dispose() {
    for (final layer in _layers.values) {
      layer.currentVolume = 0;
      layer.targetVolume = 0;
    }
  }
}
