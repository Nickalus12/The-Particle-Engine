import 'dart:convert';

import '../models/game_state.dart';
import 'save_storage_stub.dart'
    if (dart.library.io) 'save_storage_io.dart'
    as save_storage;

abstract class SaveStorageAdapter {
  Future<void> write(String name, String value);
  Future<void> writeAtomic(String name, String value);
  Future<String?> read(String name);
  Future<bool> exists(String name);
  Future<int> length(String name);
  Future<void> delete(String name);
}

class PlatformSaveStorageAdapter implements SaveStorageAdapter {
  PlatformSaveStorageAdapter([save_storage.SaveStorage? storage])
    : _storage = storage ?? save_storage.createSaveStorage();

  final save_storage.SaveStorage _storage;

  @override
  Future<void> write(String name, String value) => _storage.write(name, value);

  @override
  Future<void> writeAtomic(String name, String value) =>
      _storage.writeAtomic(name, value);

  @override
  Future<String?> read(String name) => _storage.read(name);

  @override
  Future<bool> exists(String name) => _storage.exists(name);

  @override
  Future<int> length(String name) => _storage.length(name);

  @override
  Future<void> delete(String name) => _storage.delete(name);
}

/// Metadata for a save slot, shown in the load screen before the full
/// snapshot is deserialised.
class SaveSlotMeta {
  SaveSlotMeta({
    required this.slot,
    required this.name,
    required this.savedAt,
    required this.gridW,
    required this.gridH,
    required this.frameCount,
    required this.colonyCount,
    required this.fileSizeBytes,
  });

  /// Slot index (0-based).
  final int slot;

  /// User-provided or auto-generated save name.
  final String name;

  /// Timestamp of the save.
  final DateTime savedAt;

  /// Grid dimensions at the time of save.
  final int gridW;
  final int gridH;

  /// Frame count (used to show elapsed time).
  final int frameCount;

  /// Number of colonies.
  final int colonyCount;

  /// Approximate file size on disk.
  final int fileSizeBytes;

  Map<String, dynamic> toJson() => {
    'slot': slot,
    'name': name,
    'savedAt': savedAt.toIso8601String(),
    'gridW': gridW,
    'gridH': gridH,
    'frameCount': frameCount,
    'colonyCount': colonyCount,
  };

  factory SaveSlotMeta.fromJson(
    Map<String, dynamic> json, {
    int fileSizeBytes = 0,
  }) {
    return SaveSlotMeta(
      slot: json['slot'] as int,
      name: json['name'] as String? ?? 'Untitled',
      savedAt:
          DateTime.tryParse(json['savedAt'] as String? ?? '') ?? DateTime.now(),
      gridW: json['gridW'] as int? ?? 0,
      gridH: json['gridH'] as int? ?? 0,
      frameCount: json['frameCount'] as int? ?? 0,
      colonyCount: json['colonyCount'] as int? ?? 0,
      fileSizeBytes: fileSizeBytes,
    );
  }
}

/// Persists and restores [GameState] snapshots to local storage.
///
/// Supports multiple save slots, each stored as a pair of files:
///   - `save_<slot>.json`  — full world snapshot (grid + colonies + genomes)
///   - `save_<slot>.meta`  — lightweight metadata for the slot selector UI
///
/// The storage backend is selected per platform:
/// - IO platforms use app documents files.
/// - Non-IO platforms fall back to preferences-backed string storage.
///
/// Save data is compressed using RLE in [GameState.toJson] and written as
/// UTF-8 JSON.
class SaveService {
  /// Maximum number of save slots.
  static const int maxSlots = 5;

  /// Auto-save slot index (reserved, always slot 0).
  static const int autoSaveSlot = 0;

  /// Auto-save interval.
  static const Duration autoSaveInterval = Duration(minutes: 1);

  /// Elapsed seconds since last auto-save.
  double _elapsedAutoSaveSeconds = 0;

  /// Whether auto-save is enabled.
  bool autoSaveEnabled = true;

  double get autoSaveProgress {
    final progress = _elapsedAutoSaveSeconds / autoSaveInterval.inSeconds;
    return progress.clamp(0.0, 1.0);
  }

  SaveService({SaveStorageAdapter? storage, DateTime Function()? now})
    : _storage = storage ?? PlatformSaveStorageAdapter(),
      _now = now ?? DateTime.now;

  final SaveStorageAdapter _storage;
  final DateTime Function() _now;

  String _slotFileName(int slot) => 'save_$slot.json';

  String _metaFileName(int slot) => 'save_$slot.meta';

  // ── Save ──────────────────────────────────────────────────────────────

  /// Save [state] to the given [slot] with an optional [name].
  ///
  /// Writes both the full snapshot and a lightweight metadata file.
  Future<void> save(GameState state, {int slot = 0, String? name}) async {
    final saveName = name ?? 'Save ${slot == autoSaveSlot ? "(Auto)" : slot}';

    // Write the full snapshot atomically first so metadata never points
    // to a partial/corrupt payload.
    final json = jsonEncode(state.toJson());
    await _storage.writeAtomic(_slotFileName(slot), json);

    // Then write metadata with actual file size.
    final fileSize = await _storage.length(_slotFileName(slot));
    final meta = SaveSlotMeta(
      slot: slot,
      name: saveName,
      savedAt: _now(),
      gridW: state.gridW,
      gridH: state.gridH,
      frameCount: state.frameCount,
      colonyCount: state.colonies.length,
      fileSizeBytes: fileSize,
    );
    await _storage.writeAtomic(_metaFileName(slot), jsonEncode(meta.toJson()));
  }

  // ── Load ──────────────────────────────────────────────────────────────

  /// Load a [GameState] from the given [slot], or `null` if none exists.
  Future<GameState?> load(int slot) async {
    final raw = await _storage.read(_slotFileName(slot));
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return GameState.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  // ── Slot metadata ─────────────────────────────────────────────────────

  /// List metadata for all occupied save slots.
  ///
  /// Returns a list of up to [maxSlots] entries. Empty slots are omitted.
  Future<List<SaveSlotMeta>> listSlots() async {
    final results = <SaveSlotMeta>[];

    for (var slot = 0; slot < maxSlots; slot++) {
      final rawMeta = await _storage.read(_metaFileName(slot));
      if (rawMeta == null) continue;

      try {
        final json = jsonDecode(rawMeta) as Map<String, dynamic>;
        final fileSize = await _storage.length(_slotFileName(slot));
        results.add(SaveSlotMeta.fromJson(json, fileSizeBytes: fileSize));
      } catch (_) {
        // Corrupted meta — skip.
      }
    }

    return results;
  }

  /// Check whether a slot has save data.
  Future<bool> slotExists(int slot) async {
    return _storage.exists(_slotFileName(slot));
  }

  // ── Delete ────────────────────────────────────────────────────────────

  /// Delete the save in [slot].
  Future<void> delete(int slot) async {
    await _storage.delete(_slotFileName(slot));
    await _storage.delete(_metaFileName(slot));
  }

  /// Rename the save metadata in [slot].
  ///
  /// Throws [StateError] when metadata is missing/corrupted or [newName] is empty.
  Future<void> renameSlot(int slot, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) {
      throw StateError('Save name cannot be empty');
    }

    final rawMeta = await _storage.read(_metaFileName(slot));
    if (rawMeta == null) {
      throw StateError('Save metadata not found for slot $slot');
    }

    final json = jsonDecode(rawMeta) as Map<String, dynamic>;
    final fileSize = await _storage.length(_slotFileName(slot));
    final existing = SaveSlotMeta.fromJson(json, fileSizeBytes: fileSize);
    final updated = SaveSlotMeta(
      slot: existing.slot,
      name: trimmed,
      savedAt: existing.savedAt,
      gridW: existing.gridW,
      gridH: existing.gridH,
      frameCount: existing.frameCount,
      colonyCount: existing.colonyCount,
      fileSizeBytes: existing.fileSizeBytes,
    );
    await _storage.writeAtomic(
      _metaFileName(slot),
      jsonEncode(updated.toJson()),
    );
  }

  /// Delete all saves.
  Future<void> deleteAll() async {
    for (var slot = 0; slot < maxSlots; slot++) {
      await delete(slot);
    }
  }

  // ── Auto-save ─────────────────────────────────────────────────────────

  /// Call from the game loop with frame delta seconds.
  ///
  /// Auto-save only accrues while not paused.
  ///
  /// The caller provides a [stateProvider] callback so the state is only
  /// captured when actually saving (avoids allocation every frame).
  Future<bool> tickAutoSave({
    required double dtSeconds,
    required bool paused,
    required GameState Function() stateProvider,
  }) async {
    if (!autoSaveEnabled || paused) return false;

    _elapsedAutoSaveSeconds += dtSeconds;
    if (_elapsedAutoSaveSeconds < autoSaveInterval.inSeconds) return false;

    _elapsedAutoSaveSeconds = 0;
    final state = stateProvider();
    await save(state, slot: autoSaveSlot, name: 'Auto-save');
    return true;
  }

  /// Reset the auto-save timer (e.g. after a manual save).
  void resetAutoSaveTimer() {
    _elapsedAutoSaveSeconds = 0;
  }
}
