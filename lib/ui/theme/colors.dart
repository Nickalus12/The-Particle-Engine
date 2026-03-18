import 'dart:ui';

/// Palette constants used across all UI widgets.
///
/// Named semantically so the theme stays consistent even if exact hex values
/// change later. Designed for a premium dark indie game feel.
class AppColors {
  AppColors._();

  // -- Backgrounds ------------------------------------------------------------
  static const Color background = Color(0xFF0A0A0F);
  static const Color surface = Color(0xFF151520);
  static const Color surfaceLight = Color(0xFF1E1E2E);
  static const Color surfaceBright = Color(0xFF2A2A3D);

  // -- Accents ----------------------------------------------------------------
  static const Color primary = Color(0xFFE94560);
  static const Color primaryDim = Color(0x99E94560);
  static const Color secondary = Color(0xFF0F3460);
  static const Color accent = Color(0xFF7C3AED);
  static const Color accentGlow = Color(0x407C3AED);

  // -- Element categories -----------------------------------------------------
  static const Color categorySolids = Color(0xFFF59E0B);
  static const Color categoryLiquids = Color(0xFF3B82F6);
  static const Color categoryEnergy = Color(0xFFEF4444);
  static const Color categoryLife = Color(0xFF10B981);
  static const Color categoryTools = Color(0xFF8B5CF6);

  // -- Text -------------------------------------------------------------------
  static const Color textPrimary = Color(0xFFF0F0F5);
  static const Color textSecondary = Color(0xFF8888A0);
  static const Color textDim = Color(0xFF555570);

  // -- Status -----------------------------------------------------------------
  static const Color success = Color(0xFF10B981);
  static const Color warning = Color(0xFFF59E0B);
  static const Color danger = Color(0xFFEF4444);

  // -- Glass / overlay --------------------------------------------------------
  static const Color glass = Color(0x55101020);
  static const Color glassBorder = Color(0x55FFFFFF);
  static const Color glassHeavy = Color(0x66000000);
  static const Color scrim = Color(0x99000000);
}
