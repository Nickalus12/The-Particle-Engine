import 'dart:convert';

import '../models/game_state.dart';
import 'save_storage_stub.dart'
    if (dart.library.io) 'save_storage_io.dart' as save_storage;

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

  factory SaveSlotMeta.fromJson(Map<String, dynamic> json,
      {int fileSizeBytes = 0}) {
    return SaveSlotMeta(
      slot: json['slot'] as int,
      name: json['name'] as String? ?? 'Untitled',
      savedAt: DateTime.tryParse(json['savedAt'] as String? ?? '') ??
          DateTime.now(),
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

  /// Auto-save interval in frames (default ~60s at 60fps).
  static const int autoSaveIntervalFrames = 3600;

  /// Frame counter for auto-save throttling.
  int _framesSinceAutoSave = 0;

  /// Whether auto-save is enabled.
  bool autoSaveEnabled = true;

  final save_storage.SaveStorage _storage = save_storage.createSaveStorage();

  String _slotFileName(int slot) => 'save_$slot.json';

  String _metaFileName(int slot) => 'save_$slot.meta';

  // ── Save ──────────────────────────────────────────────────────────────

  /// Save [state] to the given [slot] with an optional [name].
  ///
  /// Writes both the full snapshot and a lightweight metadata file.
  Future<void> save(GameState state, {int slot = 0, String? name}) async {
    final saveName = name ?? 'Save ${slot == autoSaveSlot ? "(Auto)" : slot}';

    // Write metadata first (quick, so UI updates fast).
    final meta = SaveSlotMeta(
      slot: slot,
      name: saveName,
      savedAt: DateTime.now(),
      gridW: state.gridW,
      gridH: state.gridH,
      frameCount: state.frameCount,
      colonyCount: state.colonies.length,
      fileSizeBytes: 0, // Updated after writing the data file.
    );
    await _storage.write(_metaFileName(slot), jsonEncode(meta.toJson()));

    // Write the full snapshot.
    final json = jsonEncode(state.toJson());
    await _storage.write(_slotFileName(slot), json);

    // Update meta with actual file size.
    final fileSize = await _storage.length(_slotFileName(slot));
    final metaWithSize = SaveSlotMeta(
      slot: meta.slot,
      name: meta.name,
      savedAt: meta.savedAt,
      gridW: meta.gridW,
      gridH: meta.gridH,
      frameCount: meta.frameCount,
      colonyCount: meta.colonyCount,
      fileSizeBytes: fileSize,
    );
    await _storage.write(_metaFileName(slot), jsonEncode(metaWithSize.toJson()));
  }

  // ── Load ──────────────────────────────────────────────────────────────

  /// Load a [GameState] from the given [slot], or `null` if none exists.
  Future<GameState?> load(int slot) async {
    final raw = await _storage.read(_slotFileName(slot));
    if (raw == null) return null;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return GameState.fromJson(json);
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

  /// Delete all saves.
  Future<void> deleteAll() async {
    for (var slot = 0; slot < maxSlots; slot++) {
      await delete(slot);
    }
  }

  // ── Auto-save ─────────────────────────────────────────────────────────

  /// Call every frame. When the interval is reached and [autoSaveEnabled] is
  /// true, triggers a save to [autoSaveSlot] and returns true.
  ///
  /// The caller provides a [stateProvider] callback so the state is only
  /// captured when actually saving (avoids allocation every frame).
  Future<bool> tickAutoSave(GameState Function() stateProvider) async {
    if (!autoSaveEnabled) return false;

    _framesSinceAutoSave++;
    if (_framesSinceAutoSave < autoSaveIntervalFrames) return false;

    _framesSinceAutoSave = 0;
    final state = stateProvider();
    await save(state, slot: autoSaveSlot, name: 'Auto-save');
    return true;
  }

  /// Reset the auto-save timer (e.g. after a manual save).
  void resetAutoSaveTimer() {
    _framesSinceAutoSave = 0;
  }
}
