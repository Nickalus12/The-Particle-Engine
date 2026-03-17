import 'dart:math';

import 'audio_manager.dart';

/// The type of reaction that occurred, used to select the correct sound.
enum ReactionType {
  steam,       // water + fire
  sizzle,      // lava + water
  explosion,   // TNT
  lightning,   // lightning strike
  acid,        // acid dissolving
  glass,       // sand + lightning → glass
  fireSpread,  // fire spreading
  plantGrow,   // plant growing
  antBorn,     // ant hatching
  colonyFound, // colony established
}

/// Triggers one-shot sound effects for element reactions with cooldowns and
/// random pitch variation for natural-sounding audio.
class ReactionSounds {
  ReactionSounds({required AudioManager audioManager})
      : _audio = audioManager;

  final AudioManager _audio;
  final Random _rng = Random();

  /// Minimum time between plays of the same reaction sound.
  static const Duration _cooldown = Duration(milliseconds: 300);

  /// Tracks the last time each reaction sound was triggered.
  final Map<ReactionType, DateTime> _lastPlayed = {};

  /// Asset file name (without path prefix or extension) per reaction.
  static const Map<ReactionType, String> _assets = {
    ReactionType.steam: 'reaction_steam',
    ReactionType.sizzle: 'reaction_sizzle',
    ReactionType.explosion: 'reaction_explosion',
    ReactionType.lightning: 'reaction_lightning',
    ReactionType.acid: 'reaction_acid',
    ReactionType.glass: 'reaction_glass',
    ReactionType.fireSpread: 'fire_spread',
    ReactionType.plantGrow: 'plant_grow',
    ReactionType.antBorn: 'ant_born',
    ReactionType.colonyFound: 'colony_fanfare',
  };

  /// Base volume per reaction (some are naturally quieter).
  static const Map<ReactionType, double> _baseVolumes = {
    ReactionType.steam: 0.6,
    ReactionType.sizzle: 0.8,
    ReactionType.explosion: 1.0,
    ReactionType.lightning: 0.9,
    ReactionType.acid: 0.5,
    ReactionType.glass: 0.4,
    ReactionType.fireSpread: 0.5,
    ReactionType.plantGrow: 0.3,
    ReactionType.antBorn: 0.25,
    ReactionType.colonyFound: 0.7,
  };

  /// Trigger a reaction sound.
  ///
  /// Respects per-reaction cooldowns and adds slight random pitch variation.
  /// [spatialVolume] is an optional multiplier from [SpatialAudio] (0.0–1.0).
  void play(ReactionType type, {double spatialVolume = 1.0}) {
    final now = DateTime.now();
    final last = _lastPlayed[type];
    if (last != null && now.difference(last) < _cooldown) return;
    _lastPlayed[type] = now;

    final asset = _assets[type];
    if (asset == null) return;

    final baseVol = _baseVolumes[type] ?? 0.5;
    // Random pitch variation ±5 % — simulated via slight volume wobble since
    // flame_audio does not expose pitch control directly.
    final variation = 0.95 + _rng.nextDouble() * 0.10;
    final vol = baseVol * spatialVolume * variation;

    _audio.playSfx(asset, volumeScale: vol);
  }

  /// Convenience: trigger placement sound.
  void playPlacement() {
    _audio.playSfx('place_element', volumeScale: 0.4);
  }
}
