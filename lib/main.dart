import 'package:flame/flame.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';


void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to landscape orientation for optimal sandbox experience.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // Hide system UI for immersive gameplay.
  await Flame.device.fullScreen();

  runApp(const ParticleEngineApp());
}
