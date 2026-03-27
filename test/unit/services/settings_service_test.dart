import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:the_particle_engine/models/sandbox_config.dart';
import 'package:the_particle_engine/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsService', () {
    test('loads defaults when no prefs are set', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final service = SettingsService();

      final config = await service.load();

      expect(config.soundEnabled, isTrue);
      expect(config.hapticsEnabled, isTrue);
      expect(config.showFps, isFalse);
      expect(config.simulationSpeed, 1.0);
      expect(config.brushSize, 3);
      expect(config.showMiniMap, isTrue);
    });

    test('save then load roundtrip', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final service = SettingsService();
      final input = SandboxConfig(
        soundEnabled: false,
        hapticsEnabled: false,
        showFps: true,
        simulationSpeed: 2.5,
        brushSize: 7,
        showMiniMap: false,
      );

      await service.save(input);
      final config = await service.load();

      expect(config.soundEnabled, isFalse);
      expect(config.hapticsEnabled, isFalse);
      expect(config.showFps, isTrue);
      expect(config.simulationSpeed, 2.5);
      expect(config.brushSize, 7);
      expect(config.showMiniMap, isFalse);
    });
  });
}
