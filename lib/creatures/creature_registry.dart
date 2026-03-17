import '../simulation/simulation_engine.dart';
import 'ant.dart';
import 'colony.dart';

/// Tracks all living creature colonies and ticks them each frame.
///
/// New colonies are added when the player places a "colony" element in the
/// sandbox. Dead colonies (population == 0 && food == 0 after grace period)
/// are pruned automatically.
///
/// The registry owns the colony list and serves as the main entry point for
/// the creature simulation subsystem.
///
/// ## Performance model
///
/// Each colony caps neural network forward passes at 50 per tick. With
/// 4 colonies that's 200 forward passes per tick, well within the ~0.5ms
/// budget for 1000 ants at 30fps. The registry distributes colony ticks
/// evenly across frames to avoid spikes.
class CreatureRegistry {
  final List<Colony> _colonies = [];
  int _nextColonyId = 0;

  /// All currently active colonies.
  List<Colony> get colonies => List.unmodifiable(_colonies);

  /// Total living ants across all colonies.
  int get totalAnts {
    int count = 0;
    for (final colony in _colonies) {
      count += colony.population;
    }
    return count;
  }

  /// Spawn a new colony at the given grid position.
  ///
  /// Grid dimensions are passed through so that pheromone systems are
  /// allocated at the correct size.
  Colony spawn(int x, int y, {int? seed, int gridW = 320, int gridH = 180}) {
    final colony = Colony(
      originX: x,
      originY: y,
      id: _nextColonyId++,
      gridW: gridW,
      gridH: gridH,
      seed: seed,
    );
    _colonies.add(colony);
    return colony;
  }

  /// Advance all colonies by one tick.
  void tick(SimulationEngine sim) {
    // Pass the full colony list so each colony can detect enemies.
    for (final colony in _colonies) {
      colony.tick(sim, _colonies);
    }

    // Prune dead colonies.
    _colonies.removeWhere((c) => !c.isAlive);
  }

  /// Find all ants from all colonies near a given position.
  /// Useful for rendering and hit-testing.
  List<Ant> antsNear(int x, int y, int radius) {
    final result = <Ant>[];
    for (final colony in _colonies) {
      for (final ant in colony.ants) {
        if (!ant.alive) continue;
        final dx = (ant.x - x).abs();
        final dy = (ant.y - y).abs();
        if (dx <= radius && dy <= radius) {
          result.add(ant);
        }
      }
    }
    return result;
  }

  /// Get the colony at a specific position (if any).
  Colony? colonyAt(int x, int y) {
    for (final colony in _colonies) {
      if (colony.originX == x && colony.originY == y) return colony;
    }
    return null;
  }

  /// Find the colony a specific ant belongs to.
  Colony? colonyForAnt(Ant ant) {
    for (final colony in _colonies) {
      if (colony.id == ant.colonyId) return colony;
    }
    return null;
  }

  /// Remove a colony by ID.
  void removeColony(int colonyId) {
    final colony = _colonies.where((c) => c.id == colonyId).firstOrNull;
    if (colony != null) {
      colony.exterminate();
      _colonies.remove(colony);
    }
  }

  /// Clear all colonies.
  void clear() {
    for (final colony in _colonies) {
      colony.exterminate();
    }
    _colonies.clear();
  }

  /// Get all living ants across all colonies (for rendering).
  Iterable<Ant> get allAnts sync* {
    for (final colony in _colonies) {
      for (final ant in colony.ants) {
        if (ant.alive) yield ant;
      }
    }
  }
}
