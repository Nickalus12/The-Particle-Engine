/// Manages a per-cell pheromone intensity map for ant navigation.
///
/// Ants deposit pheromones as they travel; the values decay over time. Other
/// ants read the gradient to find paths toward food or the nest. Different
/// pheromone channels (food, home, danger) are represented by separate
/// instances.
///
/// Grid dimensions default to 320x180 to match the standard SimulationEngine
/// size, but can be overridden. Reads outside bounds return 0.0 silently.
class PheromoneSystem {
  PheromoneSystem({this.width = 320, this.height = 180})
      : _intensity = List<double>.filled(width * height, 0.0);

  final int width;
  final int height;

  /// Intensity per cell — 0.0 means no signal.
  final List<double> _intensity;

  /// Deposit [amount] of pheromone at ([x],[y]).
  void deposit(int x, int y, double amount) {
    if (x < 0 || x >= width || y < 0 || y >= height) return;
    final idx = y * width + x;
    _intensity[idx] = (_intensity[idx] + amount).clamp(0.0, 1.0);
  }

  /// Read the pheromone level at ([x],[y]).
  double read(int x, int y) {
    if (x < 0 || x >= width || y < 0 || y >= height) return 0.0;
    return _intensity[y * width + x];
  }

  /// Decay all pheromones by a fixed fraction each tick.
  void decay() {
    for (var i = 0; i < _intensity.length; i++) {
      _intensity[i] *= 0.995;
      if (_intensity[i] < 0.001) _intensity[i] = 0.0;
    }
  }

  /// Clear the entire pheromone map.
  void clear() {
    _intensity.fillRange(0, _intensity.length, 0.0);
  }
}
