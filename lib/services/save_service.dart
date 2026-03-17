import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/game_state.dart';

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

/// Persists and restores [GameState] snapshots to local files.
///
/// Supports multiple save slots, each stored as a pair of files:
///   - `save_<slot>.json`  — full world snapshot (grid + colonies + genomes)
///   - `save_<slot>.meta`  — lightweight metadata for the slot selector UI
///
/// Uses [path_provider] for the app's documents directory. Save data is
/// compressed using RLE in [GameState.toJson] and written as UTF-8 JSON.
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

  /// Cached save directory path.
  String? _saveDirPath;

  // ── Directory management ──────────────────────────────────────────────

  /// Get or create the save directory.
  Future<Directory> _getSaveDir() async {
    if (_saveDirPath != null) {
      return Directory(_saveDirPath!);
    }
    final appDir = await getApplicationDocumentsDirectory();
    final saveDir = Directory('${appDir.path}/particle_engine_saves');
    if (!await saveDir.exists()) {
      await saveDir.create(recursive: true);
    }
    _saveDirPath = saveDir.path;
    return saveDir;
  }

  File _slotFile(String dirPath, int slot) =>
      File('$dirPath/save_$slot.json');

  File _metaFile(String dirPath, int slot) =>
      File('$dirPath/save_$slot.meta');

  // ── Save ──────────────────────────────────────────────────────────────

  /// Save [state] to the given [slot] with an optional [name].
  ///
  /// Writes both the full snapshot and a lightweight metadata file.
  Future<void> save(GameState state, {int slot = 0, String? name}) async {
    final dir = await _getSaveDir();
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
    await _metaFile(dir.path, slot)
        .writeAsString(jsonEncode(meta.toJson()));

    // Write the full snapshot.
    final json = jsonEncode(state.toJson());
    final dataFile = _slotFile(dir.path, slot);
    await dataFile.writeAsString(json);

    // Update meta with actual file size.
    final fileSize = await dataFile.length();
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
    await _metaFile(dir.path, slot)
        .writeAsString(jsonEncode(metaWithSize.toJson()));
  }

  // ── Load ──────────────────────────────────────────────────────────────

  /// Load a [GameState] from the given [slot], or `null` if none exists.
  Future<GameState?> load(int slot) async {
    final dir = await _getSaveDir();
    final dataFile = _slotFile(dir.path, slot);

    if (!await dataFile.exists()) return null;

    final json = jsonDecode(await dataFile.readAsString())
        as Map<String, dynamic>;
    return GameState.fromJson(json);
  }

  // ── Slot metadata ─────────────────────────────────────────────────────

  /// List metadata for all occupied save slots.
  ///
  /// Returns a list of up to [maxSlots] entries. Empty slots are omitted.
  Future<List<SaveSlotMeta>> listSlots() async {
    final dir = await _getSaveDir();
    final results = <SaveSlotMeta>[];

    for (var slot = 0; slot < maxSlots; slot++) {
      final metaFile = _metaFile(dir.path, slot);
      if (!await metaFile.exists()) continue;

      try {
        final json = jsonDecode(await metaFile.readAsString())
            as Map<String, dynamic>;
        final dataFile = _slotFile(dir.path, slot);
        final fileSize =
            await dataFile.exists() ? await dataFile.length() : 0;
        results.add(
            SaveSlotMeta.fromJson(json, fileSizeBytes: fileSize));
      } catch (_) {
        // Corrupted meta — skip.
      }
    }

    return results;
  }

  /// Check whether a slot has save data.
  Future<bool> slotExists(int slot) async {
    final dir = await _getSaveDir();
    return _slotFile(dir.path, slot).exists();
  }

  // ── Delete ────────────────────────────────────────────────────────────

  /// Delete the save in [slot].
  Future<void> delete(int slot) async {
    final dir = await _getSaveDir();
    final dataFile = _slotFile(dir.path, slot);
    final metaFile = _metaFile(dir.path, slot);
    if (await dataFile.exists()) await dataFile.delete();
    if (await metaFile.exists()) await metaFile.delete();
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
