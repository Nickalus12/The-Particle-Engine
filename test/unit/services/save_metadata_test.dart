import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/services/save_service.dart';

class _MemStorage implements SaveStorageAdapter {
  final Map<String, String> data = <String, String>{};

  @override
  Future<void> delete(String name) async {
    data.remove(name);
  }

  @override
  Future<bool> exists(String name) async => data.containsKey(name);

  @override
  Future<int> length(String name) async => (data[name] ?? '').length;

  @override
  Future<String?> read(String name) async => data[name];

  @override
  Future<void> write(String name, String value) async {
    data[name] = value;
  }

  @override
  Future<void> writeAtomic(String name, String value) async {
    data[name] = value;
  }
}

void main() {
  group('SaveSlotMeta', () {
    test('toJson/fromJson roundtrip preserves key fields', () {
      final now = DateTime.utc(2026, 1, 2, 3, 4, 5);
      final meta = SaveSlotMeta(
        slot: 2,
        name: 'World Alpha',
        savedAt: now,
        gridW: 320,
        gridH: 180,
        frameCount: 1234,
        colonyCount: 5,
        fileSizeBytes: 4096,
      );

      final decoded = SaveSlotMeta.fromJson(meta.toJson(), fileSizeBytes: 4096);

      expect(decoded.slot, 2);
      expect(decoded.name, 'World Alpha');
      expect(decoded.savedAt.toUtc(), now);
      expect(decoded.gridW, 320);
      expect(decoded.gridH, 180);
      expect(decoded.frameCount, 1234);
      expect(decoded.colonyCount, 5);
      expect(decoded.fileSizeBytes, 4096);
    });

    test('fromJson falls back safely for malformed payload', () {
      final decoded = SaveSlotMeta.fromJson(<String, dynamic>{
        'slot': 1,
        'savedAt': 'bad-date',
      });

      expect(decoded.slot, 1);
      expect(decoded.name, 'Untitled');
      expect(decoded.gridW, 0);
      expect(decoded.gridH, 0);
      expect(decoded.frameCount, 0);
      expect(decoded.colonyCount, 0);
      expect(decoded.fileSizeBytes, 0);
    });
  });

  group('SaveService Slot Ops', () {
    test('slotExists reflects payload presence', () async {
      final storage = _MemStorage();
      final service = SaveService(storage: storage);

      expect(await service.slotExists(0), isFalse);
      await storage.write('save_0.json', '{}');
      expect(await service.slotExists(0), isTrue);
    });

    test('deleteAll removes payload and metadata for all slots', () async {
      final storage = _MemStorage();
      final service = SaveService(storage: storage);

      for (int slot = 0; slot < SaveService.maxSlots; slot++) {
        await storage.write('save_$slot.json', '{"slot":$slot}');
        await storage.write('save_$slot.meta', '{"slot":$slot}');
      }

      await service.deleteAll();

      expect(storage.data, isEmpty);
    });
  });
}
