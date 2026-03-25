import 'package:shared_preferences/shared_preferences.dart';

import '../models/sandbox_config.dart';

/// Reads and writes user preferences via [SharedPreferences].
class SettingsService {
  static const String _keySound = 'pref_sound';
  static const String _keyHaptics = 'pref_haptics';
  static const String _keyFps = 'pref_fps';
  static const String _keySpeed = 'pref_speed';
  static const String _keyBrush = 'pref_brush';
  static const String _keyMiniMap = 'pref_minimap';

  /// Load persisted settings into a [SandboxConfig].
  Future<SandboxConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return SandboxConfig(
      soundEnabled: prefs.getBool(_keySound) ?? true,
      hapticsEnabled: prefs.getBool(_keyHaptics) ?? true,
      showFps: prefs.getBool(_keyFps) ?? false,
      simulationSpeed: (prefs.getDouble(_keySpeed) ?? 1.0).clamp(0.25, 4.0),
      brushSize: (prefs.getInt(_keyBrush) ?? 3).clamp(1, 10),
      showMiniMap: prefs.getBool(_keyMiniMap) ?? true,
    );
  }

  /// Persist the given [config].
  Future<void> save(SandboxConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySound, config.soundEnabled);
    await prefs.setBool(_keyHaptics, config.hapticsEnabled);
    await prefs.setBool(_keyFps, config.showFps);
    await prefs.setDouble(_keySpeed, config.simulationSpeed);
    await prefs.setInt(_keyBrush, config.brushSize);
    await prefs.setBool(_keyMiniMap, config.showMiniMap);
  }
}
