import 'dart:collection';

import 'colony.dart';

/// Records and analyzes colony performance over time.
///
/// Maintains a rolling window of snapshots that capture population,
/// food, fitness, and other metrics at regular intervals. This data
/// feeds the colony inspector UI and helps evaluate evolutionary progress.
///
/// Snapshots are taken every [snapshotInterval] ticks and the buffer
/// holds at most [maxSnapshots] entries (~5 minutes of history at 60fps
/// with default settings).
class ColonyStats {
  ColonyStats({
    this.snapshotInterval = 60,
    this.maxSnapshots = 300,
  });

  /// Ticks between snapshots.
  final int snapshotInterval;

  /// Maximum number of snapshots to keep in memory.
  final int maxSnapshots;

  /// Rolling buffer of stat snapshots.
  final Queue<ColonySnapshot> _snapshots = Queue();

  /// All recorded snapshots (oldest first).
  Iterable<ColonySnapshot> get snapshots => _snapshots;

  /// Most recent snapshot, or null if none recorded yet.
  ColonySnapshot? get latest => _snapshots.isNotEmpty ? _snapshots.last : null;

  /// Oldest snapshot in the buffer.
  ColonySnapshot? get oldest => _snapshots.isNotEmpty ? _snapshots.first : null;

  /// Record a snapshot from the current colony state.
  void record(Colony colony) {
    if (colony.ageTicks % snapshotInterval != 0) return;

    final snapshot = ColonySnapshot(
      tick: colony.ageTicks,
      population: colony.population,
      foodStored: colony.foodStored,
      totalSpawned: colony.totalSpawned,
      totalDied: colony.totalDied,
      averageFitness: colony.averageAntFitness,
      averageAge: colony.averageAntAge,
      speciesCount: colony.evolution.speciesCount,
      averageComplexity: colony.evolution.averageComplexity,
      antsCarryingFood: colony.antsCarryingFood,
    );

    _snapshots.addLast(snapshot);
    while (_snapshots.length > maxSnapshots) {
      _snapshots.removeFirst();
    }
  }

  /// Clear all recorded snapshots.
  void clear() => _snapshots.clear();

  // ---------------------------------------------------------------------------
  // Derived metrics
  // ---------------------------------------------------------------------------

  /// Population trend over the last N snapshots.
  /// Returns positive for growing, negative for declining.
  double populationTrend({int window = 10}) {
    return _trend((s) => s.population.toDouble(), window: window);
  }

  /// Food trend over the last N snapshots.
  double foodTrend({int window = 10}) {
    return _trend((s) => s.foodStored.toDouble(), window: window);
  }

  /// Fitness trend over the last N snapshots.
  double fitnessTrend({int window = 10}) {
    return _trend((s) => s.averageFitness, window: window);
  }

  /// Peak population ever recorded.
  int get peakPopulation {
    int peak = 0;
    for (final s in _snapshots) {
      if (s.population > peak) peak = s.population;
    }
    return peak;
  }

  /// Peak food ever stored.
  int get peakFood {
    int peak = 0;
    for (final s in _snapshots) {
      if (s.foodStored > peak) peak = s.foodStored;
    }
    return peak;
  }

  /// Average population over all snapshots.
  double get averagePopulation {
    if (_snapshots.isEmpty) return 0.0;
    double sum = 0;
    for (final s in _snapshots) {
      sum += s.population;
    }
    return sum / _snapshots.length;
  }

  /// Survival rate (1 - deaths/spawns).
  double get survivalRate {
    final latest = this.latest;
    if (latest == null || latest.totalSpawned == 0) return 1.0;
    return 1.0 - (latest.totalDied / latest.totalSpawned);
  }

  /// Compute trend (slope) of a metric over the last N snapshots.
  double _trend(
    double Function(ColonySnapshot) extract, {
    required int window,
  }) {
    if (_snapshots.length < 2) return 0.0;

    final recent = _snapshots.toList();
    final start = recent.length > window ? recent.length - window : 0;
    final slice = recent.sublist(start);

    if (slice.length < 2) return 0.0;

    final first = extract(slice.first);
    final last = extract(slice.last);
    return last - first;
  }
}

/// A point-in-time snapshot of colony metrics.
class ColonySnapshot {
  const ColonySnapshot({
    required this.tick,
    required this.population,
    required this.foodStored,
    required this.totalSpawned,
    required this.totalDied,
    required this.averageFitness,
    required this.averageAge,
    required this.speciesCount,
    required this.averageComplexity,
    required this.antsCarryingFood,
  });

  final int tick;
  final int population;
  final int foodStored;
  final int totalSpawned;
  final int totalDied;
  final double averageFitness;
  final double averageAge;
  final int speciesCount;
  final double averageComplexity;
  final int antsCarryingFood;
}
