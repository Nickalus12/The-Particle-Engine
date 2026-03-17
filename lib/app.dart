import 'package:flutter/material.dart';

import 'ui/screens/splash_screen.dart';
import 'ui/theme/particle_theme.dart';

/// Root widget for The Particle Engine application.
///
/// Sets up theming and top-level navigation. The app launches into
/// [SplashScreen] which initializes services, then routes to
/// [IntroScreen] (first launch) or [HomeScreen] (returning player).
class ParticleEngineApp extends StatelessWidget {
  const ParticleEngineApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'The Particle Engine',
      debugShowCheckedModeBanner: false,
      theme: ParticleTheme.dark,
      home: const SplashScreen(),
    );
  }
}
