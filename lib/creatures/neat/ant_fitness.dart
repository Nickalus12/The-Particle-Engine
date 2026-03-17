/// Fitness evaluation for ant genomes.
///
/// Fitness is accumulated during an ant's lifetime based on behaviours
/// that contribute to colony survival. This creates the selection pressure
/// that drives evolution toward useful ant behaviours.
///
/// ## Fitness Components
///
/// | Behaviour | Reward | Rationale |
/// |-----------|--------|-----------|
/// | Forage food | +10 | Core survival |
/// | Deliver food to nest | +25 | Completes the foraging loop |
/// | Explore new territory | +1 per unique cell | Expands colony awareness |
/// | Survive (per tick) | +0.01 | Baseline for longevity |
/// | Deposit useful pheromone | +0.5 | Aids other colony members |
/// | Defend nest from threat | +15 | Colony protection |
/// | Die (any cause) | -5 | Mild penalty for fragility |
/// | Idle (no movement) | -0.1 per tick | Penalise inaction |
///
/// The fitness function is deliberately simple — complex emergent behaviour
/// should arise from simple rewards, not from hand-engineered fitness
/// landscapes.
class AntFitness {
  AntFitness();

  double _score = 0.0;
  int _idleTicks = 0;
  int _visitedCells = 0;
  final Set<int> _visited = {};

  /// Current accumulated fitness.
  double get score => _score;

  /// Record that the ant survived one tick.
  void tickSurvived() {
    _score += 0.01;
  }

  /// Record that the ant moved to a new cell.
  void moved(int x, int y) {
    _idleTicks = 0;
    final key = y * 10000 + x; // cheap unique key
    if (_visited.add(key)) {
      _visitedCells++;
      _score += 1.0; // Exploration bonus.
    }
  }

  /// Record that the ant stayed in the same place.
  void idled() {
    _idleTicks++;
    _score -= 0.1;
  }

  /// Record that the ant picked up food.
  void foraged() {
    _score += 10.0;
  }

  /// Record that the ant delivered food to the nest.
  void deliveredFood() {
    _score += 25.0;
  }

  /// Record that the ant deposited pheromone that another ant followed.
  void usefulPheromone() {
    _score += 0.5;
  }

  /// Record that the ant defended the nest.
  void defended() {
    _score += 15.0;
  }

  /// Record that the ant died.
  void died() {
    _score -= 5.0;
  }

  /// Number of unique cells this ant has visited.
  int get exploredCells => _visitedCells;

  /// Consecutive ticks without movement.
  int get consecutiveIdleTicks => _idleTicks;

  /// Reset for a new lifetime.
  void reset() {
    _score = 0.0;
    _idleTicks = 0;
    _visitedCells = 0;
    _visited.clear();
  }
}
