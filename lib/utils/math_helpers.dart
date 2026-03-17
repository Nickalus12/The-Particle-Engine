import 'dart:math';

/// Lightweight math utilities used throughout the simulation.
class MathHelpers {
  MathHelpers._();

  static final Random _rng = Random();

  /// Returns a random integer in the range \[0, max).
  static int randomInt(int max) => _rng.nextInt(max);

  /// Returns a random double in \[0.0, 1.0).
  static double randomDouble() => _rng.nextDouble();

  /// Returns `true` with a probability of [chance] (0.0 – 1.0).
  static bool chance(double chance) => _rng.nextDouble() < chance;

  /// Linearly interpolate between [a] and [b] by [t].
  static double lerp(double a, double b, double t) => a + (b - a) * t;

  /// Clamp [value] into \[min, max\].
  static double clamp(double value, double min, double max) =>
      value < min ? min : (value > max ? max : value);

  /// Clamp an integer [value] into \[min, max\].
  static int clampInt(int value, int min, int max) =>
      value < min ? min : (value > max ? max : value);

  /// Manhattan distance between two grid cells.
  static int manhattan(int x1, int y1, int x2, int y2) =>
      (x1 - x2).abs() + (y1 - y2).abs();
}
