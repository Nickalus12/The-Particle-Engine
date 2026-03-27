# Mobile Automation

## Entry points

- Normal app:
  - `lib/main.dart`
- Integration-test app bootstrap:
  - `integration_test/driver_main.dart`
- Flutter Driver extension bootstrap:
  - `lib/flutter_driver_main.dart`

## Integration test command

Run the mobile integration suite with Flutter's integration runner:

```powershell
flutter test integration_test/mobile_navigation_test.dart -d <device-id>
```

For a full app-driven lane:

```powershell
flutter drive `
  --driver integration_test/driver_main.dart `
  --target integration_test/mobile_navigation_test.dart `
  -d <device-id>
```

## Flutter Driver command

Run the app with the dedicated driver extension target:

```powershell
flutter run -d <device-id> -t lib/flutter_driver_main.dart
```

This target enables `enableFlutterDriverExtension()` before bootstrapping the
app. It is intended for direct device-driving tools that require the legacy
Flutter Driver extension channel.

## Stable automation keys

- Home create button:
  - `home_create_button`
- Home load button:
  - `home_load_button`
- Home settings button:
  - `home_settings_button`
- World create button:
  - `world_create_button`
- Sandbox screen:
  - `sandbox_screen`
