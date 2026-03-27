import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/models/game_state.dart';
import 'package:the_particle_engine/services/save_service.dart';

class InMemorySaveStorage implements SaveStorageAdapter {
  final Map<String, String> files = <String, String>{};

  @override
  Future<void> delete(String name) async {
    files.remove(name);
  }

  @override
  Future<bool> exists(String name) async => files.containsKey(name);

  @override
  Future<int> length(String name) async => files[name]?.length ?? 0;

  @override
  Future<String?> read(String name) async => files[name];

  @override
  Future<void> write(String name, String value) async {
    files[name] = value;
  }

  @override
  Future<void> writeAtomic(String name, String value) async {
    files[name] = value;
  }
}

class FailingMetaStorage extends InMemorySaveStorage {
  @override
  Future<void> writeAtomic(String name, String value) async {
    if (name.endsWith('.meta')) {
      throw StateError('meta write failed');
    }
    await super.writeAtomic(name, value);
  }
}

GameState _state({int frame = 10}) {
  const w = 8;
  const h = 8;
  final total = w * h;
  final grid = Uint8List(total);
  grid[0] = 1;
  return GameState(
    gridW: w,
    gridH: h,
    grid: grid,
    life: Uint8List(total),
    velX: Int8List(total),
    velY: Int8List(total),
    frameCount: frame,
  );
}

void main() {
  group('SaveService', () {
    test('save/load roundtrip works with in-memory storage', () async {
      final storage = InMemorySaveStorage();
      final service = SaveService(storage: storage);

      await service.save(_state(frame: 99), slot: 1, name: 'Test');
      final loaded = await service.load(1);

      expect(loaded, isNotNull);
      expect(loaded!.frameCount, 99);
      expect(loaded.gridW, 8);
      expect(loaded.grid[0], 1);
    });

    test('load returns null for corrupted payload', () async {
      final storage = InMemorySaveStorage();
      final service = SaveService(storage: storage);
      await storage.writeAtomic('save_2.json', '{not-json}');

      final loaded = await service.load(2);
      expect(loaded, isNull);
    });

    test('payload is persisted even if metadata write fails', () async {
      final storage = FailingMetaStorage();
      final service = SaveService(storage: storage);

      await expectLater(
        service.save(_state(), slot: 3, name: 'Atomic'),
        throwsA(isA<StateError>()),
      );

      expect(await storage.exists('save_3.json'), isTrue);
    });

    test('auto-save uses elapsed time and ignores paused frames', () async {
      final storage = InMemorySaveStorage();
      final service = SaveService(storage: storage);

      final savedWhilePaused = await service.tickAutoSave(
        dtSeconds: 120,
        paused: true,
        stateProvider: _state,
      );
      expect(savedWhilePaused, isFalse);
      expect(await storage.exists('save_0.json'), isFalse);

      final notYet = await service.tickAutoSave(
        dtSeconds: 30,
        paused: false,
        stateProvider: _state,
      );
      expect(notYet, isFalse);

      final now = await service.tickAutoSave(
        dtSeconds: 30,
        paused: false,
        stateProvider: _state,
      );
      expect(now, isTrue);
      expect(await storage.exists('save_0.json'), isTrue);
    });
  });
}
