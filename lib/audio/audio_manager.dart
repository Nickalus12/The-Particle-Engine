import 'dart:convert';

import 'package:flame_audio/flame_audio.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ambient_mixer.dart';
import 'day_night_ambience.dart';
import 'reaction_sounds.dart';
import 'spatial_audio.dart';

/// Centralised audio playback with volume controls, muting, and preference
/// persistence.
///
/// Wraps [FlameAudio] so the rest of the codebase does not depend on the audio
/// package directly. Coordinates sub-systems: [AmbientMixer],
/// [ReactionSounds], [SpatialAudio], and [DayNightAmbience].
class AudioManager {
  AudioManager._();

  static final AudioManager instance = AudioManager._();

  // ── Preferences keys ──────────────────────────────────────────────────
  static const String _keyMuted = 'audio_muted';
  static const String _keyMasterVol = 'audio_master';
  static const String _keySfxVol = 'audio_sfx';
  static const String _keyAmbientVol = 'audio_ambient';

  // ── State ─────────────────────────────────────────────────────────────
  bool _muted = false;
  double _masterVolume = 1.0;
  double _sfxVolume = 1.0;
  double _ambientVolume = 1.0;
  bool _initialised = false;
  final Set<String> _availableAssets = <String>{};

  // ── Sub-systems ───────────────────────────────────────────────────────
  late final AmbientMixer ambientMixer;
  late final ReactionSounds reactionSounds;
  late final SpatialAudio spatialAudio;
  late final DayNightAmbience dayNightAmbience;

  // ── Sound pool ────────────────────────────────────────────────────────
  /// Tracks recently played sounds to avoid overlapping duplicates.
  final Map<String, DateTime> _soundPool = {};
  static const Duration _poolCooldown = Duration(milliseconds: 80);

  // ── Public getters / setters ──────────────────────────────────────────
  bool get isMuted => _muted;
  double get masterVolume => _masterVolume;
  double get sfxVolume => _sfxVolume;
  double get ambientVolume => _ambientVolume;
  bool get isInitialised => _initialised;

  set muted(bool value) {
    _muted = value;
    _persistPreferences();
  }

  set masterVolume(double value) {
    _masterVolume = value.clamp(0.0, 1.0);
    _persistPreferences();
  }

  set sfxVolume(double value) {
    _sfxVolume = value.clamp(0.0, 1.0);
    _persistPreferences();
  }

  set ambientVolume(double value) {
    _ambientVolume = value.clamp(0.0, 1.0);
    _persistPreferences();
  }

  /// Effective volume for one-shot SFX (master * sfx channel).
  double get effectiveSfxVolume => _muted ? 0.0 : _masterVolume * _sfxVolume;

  /// Effective volume for ambient layers (master * ambient channel).
  double get effectiveAmbientVolume =>
      _muted ? 0.0 : _masterVolume * _ambientVolume;

  // ── Lifecycle ─────────────────────────────────────────────────────────

  /// Initialise sub-systems and restore saved preferences.
  Future<void> init() async {
    if (_initialised) return;

    await _loadPreferences();
    await _loadAssetManifest();

    ambientMixer = AmbientMixer(audioManager: this);
    reactionSounds = ReactionSounds(audioManager: this);
    spatialAudio = SpatialAudio();
    dayNightAmbience = DayNightAmbience(audioManager: this);

    _initialised = true;
  }

  /// Release resources. Call when the app exits.
  void dispose() {
    ambientMixer.dispose();
    dayNightAmbience.dispose();
    FlameAudio.bgm.stop();
    _initialised = false;
  }

  // ── Playback helpers ──────────────────────────────────────────────────

  /// Play a one-shot sound effect by [name] (without extension).
  ///
  /// Respects sound pooling so the same sound won't fire more frequently
  /// than [_poolCooldown].
  Future<void> playSfx(String name, {double volumeScale = 1.0}) async {
    if (_muted || effectiveSfxVolume <= 0) return;

    // Sound pooling: prevent spamming the same clip.
    final now = DateTime.now();
    final lastPlayed = _soundPool[name];
    if (lastPlayed != null && now.difference(lastPlayed) < _poolCooldown) {
      return;
    }
    _soundPool[name] = now;

    final vol = (effectiveSfxVolume * volumeScale).clamp(0.0, 1.0);
    final assetPath = 'assets/audio/sfx/$name.wav';
    if (!_availableAssets.contains(assetPath)) return;
    await FlameAudio.play('sfx/$name.wav', volume: vol);
  }

  /// Begin looping background music.
  Future<void> playMusic(String name) async {
    if (_muted) return;
    final assetPath = 'assets/audio/music/$name.mp3';
    if (!_availableAssets.contains(assetPath)) return;
    await FlameAudio.bgm.play('music/$name.mp3', volume: _masterVolume);
  }

  /// Stop all background music.
  void stopMusic() {
    FlameAudio.bgm.stop();
  }

  /// Pause background music (e.g. when app goes to background).
  void pauseMusic() {
    FlameAudio.bgm.pause();
  }

  /// Resume background music.
  void resumeMusic() {
    if (_muted) return;
    FlameAudio.bgm.resume();
  }

  // ── Persistence ───────────────────────────────────────────────────────

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _muted = prefs.getBool(_keyMuted) ?? false;
    _masterVolume = prefs.getDouble(_keyMasterVol) ?? 1.0;
    _sfxVolume = prefs.getDouble(_keySfxVol) ?? 1.0;
    _ambientVolume = prefs.getDouble(_keyAmbientVol) ?? 1.0;
  }

  Future<void> _loadAssetManifest() async {
    try {
      final manifestJson = await rootBundle.loadString('AssetManifest.json');
      final manifest = jsonDecode(manifestJson);
      if (manifest is Map<String, dynamic>) {
        _availableAssets
          ..clear()
          ..addAll(manifest.keys);
      }
    } catch (_) {
      _availableAssets.clear();
    }
  }

  Future<void> _persistPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyMuted, _muted);
    await prefs.setDouble(_keyMasterVol, _masterVolume);
    await prefs.setDouble(_keySfxVol, _sfxVolume);
    await prefs.setDouble(_keyAmbientVol, _ambientVolume);
  }
}
