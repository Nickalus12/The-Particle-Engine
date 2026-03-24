import 'dart:ui';

import 'package:flutter/material.dart';

import 'colors.dart';

/// Provides the [ThemeData] and design helpers for The Particle Engine.
///
/// Dark theme with glassmorphism helpers, standardized animation curves,
/// and consistent border radii for a premium indie game feel.
class ParticleTheme {
  ParticleTheme._();

  // ---------------------------------------------------------------------------
  // Theme data
  // ---------------------------------------------------------------------------

  static ThemeData get dark => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.primary,
          secondary: AppColors.accent,
          surface: AppColors.surface,
          onSurface: AppColors.textPrimary,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
        ),
        iconTheme: const IconThemeData(
          color: AppColors.textPrimary,
          size: 20,
        ),
        textTheme: const TextTheme(
          headlineLarge: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w800,
            fontSize: 32,
            letterSpacing: 2.0,
          ),
          headlineMedium: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 22,
          ),
          bodyMedium: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13,
          ),
          labelMedium: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 11,
            letterSpacing: 0.8,
          ),
        ),
        sliderTheme: SliderThemeData(
          activeTrackColor: AppColors.primary,
          inactiveTrackColor: AppColors.surfaceLight,
          thumbColor: AppColors.primary,
          overlayColor: AppColors.primaryDim,
          trackHeight: 3,
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected)
                  ? AppColors.primary
                  : AppColors.textDim),
          trackColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected)
                  ? AppColors.primaryDim
                  : AppColors.surfaceLight),
        ),
      );

  // ---------------------------------------------------------------------------
  // Animation constants
  // ---------------------------------------------------------------------------

  static const Duration fastDuration = Duration(milliseconds: 150);
  static const Duration normalDuration = Duration(milliseconds: 300);
  static const Duration slowDuration = Duration(milliseconds: 500);

  static const Curve defaultCurve = Curves.easeOutCubic;
  static const Curve bounceCurve = Curves.elasticOut;
  static const Curve smoothCurve = Curves.easeInOutCubic;

  // ---------------------------------------------------------------------------
  // Border radii
  // ---------------------------------------------------------------------------

  static const double radiusSmall = 8.0;
  static const double radiusMedium = 12.0;
  static const double radiusLarge = 20.0;
  static const double radiusXLarge = 28.0;

  // ---------------------------------------------------------------------------
  // Glassmorphism helpers
  // ---------------------------------------------------------------------------

  /// Creates a frosted glass decoration for panels and cards.
  static BoxDecoration glassDecoration({
    double borderRadius = radiusMedium,
    Color? color,
    double borderOpacity = 0.12,
  }) {
    return BoxDecoration(
      color: color ?? AppColors.glass,
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(
        color: Colors.white.withValues(alpha: borderOpacity),
        width: 0.5,
      ),
      boxShadow: const [
        BoxShadow(
          color: Color(0x30000000),
          blurRadius: 24,
          offset: Offset(0, 4),
        ),
      ],
    );
  }

  /// Creates a frosted glass clip with [BackdropFilter] blur.
  static Widget glassPanel({
    required Widget child,
    double borderRadius = radiusMedium,
    double blurAmount = 20.0,
    EdgeInsetsGeometry? padding,
    EdgeInsetsGeometry? margin,
  }) {
    return Container(
      margin: margin,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: blurAmount,
            sigmaY: blurAmount,
          ),
          child: Container(
            padding: padding,
            decoration: glassDecoration(borderRadius: borderRadius),
            child: child,
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Glow effects
  // ---------------------------------------------------------------------------

  /// Creates a glow shadow for highlighted elements.
  static List<BoxShadow> glowShadow(Color color, {double spread = 0}) {
    return [
      BoxShadow(
        color: color.withValues(alpha: 0.4),
        blurRadius: 12,
        spreadRadius: spread,
      ),
      BoxShadow(
        color: color.withValues(alpha: 0.15),
        blurRadius: 24,
        spreadRadius: spread + 2,
      ),
    ];
  }
}
