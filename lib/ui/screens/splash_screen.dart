import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../audio/audio_manager.dart';
import '../../simulation/element_registry.dart';
import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';
import 'home_screen.dart';
import 'intro_screen.dart';

/// Splash/loading screen shown while the app initializes.
///
/// Displays the game title with a subtle loading indicator while
/// [AudioManager] and other services initialize. Once ready, transitions
/// to [IntroScreen] (first launch) or [HomeScreen] (returning player).
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final Animation<double> _titleFade;
  late final Animation<double> _loaderFade;

  static const String _hasSeenIntroKey = 'has_seen_intro';

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _titleFade = CurvedAnimation(
      parent: _fadeController,
      curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
    );
    _loaderFade = CurvedAnimation(
      parent: _fadeController,
      curve: const Interval(0.4, 1.0, curve: Curves.easeOut),
    );
    _fadeController.forward();
    _initialize();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    // Initialize services in parallel.
    final results = await Future.wait([
      _initServices(),
      // Minimum display time so the splash doesn't flash.
      Future.delayed(const Duration(milliseconds: 1500)),
    ]);

    if (!mounted) return;

    final hasSeenIntro = results[0] as bool;

    // Fade out, then navigate.
    await _fadeController.reverse();
    if (!mounted) return;

    final destination =
        hasSeenIntro ? const HomeScreen() : const IntroScreen();

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, _, _) => destination,
        transitionsBuilder: (context, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: ParticleTheme.slowDuration,
      ),
    );
  }

  /// Initialize all app services. Returns whether intro has been seen.
  Future<bool> _initServices() async {
    // Initialize element registry.
    ElementRegistry.init();

    // Initialize audio.
    await AudioManager.instance.init();

    // Check if user has seen the intro.
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_hasSeenIntroKey) ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Title
            FadeTransition(
              opacity: _titleFade,
              child: Column(
                children: [
                  Text(
                    'THE',
                    style: AppTypography.label.copyWith(
                      fontSize: 10,
                      letterSpacing: 6.0,
                      color: AppColors.textDim,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ShaderMask(
                    shaderCallback: (bounds) => const LinearGradient(
                      colors: [AppColors.primary, AppColors.accent],
                    ).createShader(bounds),
                    child: Text(
                      'PARTICLE ENGINE',
                      style: AppTypography.title.copyWith(
                        fontSize: 28,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 40),

            // Loading indicator
            FadeTransition(
              opacity: _loaderFade,
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(
                    AppColors.primary.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
