import 'package:flutter/material.dart';

import 'simulation/world_gen/world_config.dart';
import 'ui/screens/sandbox_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const _MobileDiagnosticsApp(),
  );
}

class _MobileDiagnosticsApp extends StatelessWidget {
  const _MobileDiagnosticsApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SandboxScreen(
        worldConfig: WorldConfig.meadow(seed: 1337),
        worldName: 'Mobile Diagnostics',
      ),
    );
  }
}
