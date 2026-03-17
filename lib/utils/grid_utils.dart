/// Helpers for converting between grid coordinates and flat-array indices.
///
/// All methods now take grid dimensions explicitly rather than reading from
/// a static [Constants] class.  Prefer using [SimulationEngine.inBounds] and
/// direct index math instead of this utility where possible.
class GridUtils {
  GridUtils._();

  /// Convert a 2-D grid coordinate to a flat index.
  static int toIndex(int x, int y, int gridW) => y * gridW + x;

  /// Extract the X component from a flat index.
  static int toX(int index, int gridW) => index % gridW;

  /// Extract the Y component from a flat index.
  static int toY(int index, int gridW) => index ~/ gridW;

  /// Whether [x],[y] falls inside a grid of the given dimensions.
  static bool inBounds(int x, int y, int gridW, int gridH) =>
      x >= 0 && x < gridW && y >= 0 && y < gridH;
}
