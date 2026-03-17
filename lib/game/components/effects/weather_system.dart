import 'dart:math';

import 'package:flame/components.dart';

import '../../../simulation/element_registry.dart';
import '../../../simulation/simulation_engine.dart';

/// Spawns weather-driven particles (rain, sandstorm) at the top of the grid.
///
/// When active, each tick has a configurable probability of injecting an
/// element into a random column at row 0. The intensity is ramped up/down
/// smoothly so weather transitions feel natural.
class WeatherSystem extends Component {
  WeatherSystem({required this.simulation});

  final SimulationEngine simulation;

  /// The element dropped by the current weather (e.g. [El.water] for rain).
  int weatherElement = El.water;

  /// 0.0 = clear skies, 1.0 = maximum intensity.
  double intensity = 0.0;

  /// Whether the weather system is actively spawning particles.
  bool isActive = false;

  final Random _rng = Random();

  @override
  void update(double dt) {
    super.update(dt);
    if (!isActive || intensity <= 0) return;

    // Number of drops per tick scales with intensity.
    final drops = (intensity * 10).ceil();
    for (var i = 0; i < drops; i++) {
      if (_rng.nextDouble() < intensity) {
        final x = _rng.nextInt(simulation.gridW);
        final idx = x; // row 0: y=0, so idx = x
        if (simulation.grid[idx] == El.empty) {
          simulation.grid[idx] = weatherElement;
          simulation.life[idx] = 0;
          simulation.markDirty(x, 0);
        }
      }
    }
  }
}
