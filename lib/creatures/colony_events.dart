/// Records notable events in a colony's history.
///
/// These events feed into the UI (notifications, timeline) and help
/// the player understand what their colonies are doing without needing
/// to watch every ant.
///
/// Events are categorized by severity:
/// - **info**: Normal colony activity (food found, ant spawned).
/// - **warning**: Colony under stress (low food, flooding).
/// - **critical**: Existential threat (all foragers dead, nest destroyed).
/// - **milestone**: Achievement (100 ants, first food delivery, etc.).
class ColonyEvents {
  ColonyEvents();

  /// Maximum number of events to keep in memory.
  static const int maxEvents = 200;

  final List<ColonyEvent> _events = [];

  /// All recorded events (newest first).
  List<ColonyEvent> get events => List.unmodifiable(_events);

  /// Most recent event, or null.
  ColonyEvent? get latest => _events.isNotEmpty ? _events.first : null;

  /// Record a new event.
  void record(ColonyEvent event) {
    _events.insert(0, event);
    if (_events.length > maxEvents) {
      _events.removeLast();
    }
  }

  /// Get events of a specific type.
  List<ColonyEvent> ofType(ColonyEventType type) {
    return _events.where((e) => e.type == type).toList();
  }

  /// Get events at or above a severity level.
  List<ColonyEvent> atSeverity(EventSeverity minSeverity) {
    return _events
        .where((e) => e.severity.index >= minSeverity.index)
        .toList();
  }

  /// Events in the last N ticks.
  List<ColonyEvent> recent(int currentTick, int window) {
    return _events
        .where((e) => currentTick - e.tick <= window)
        .toList();
  }

  /// Clear all events.
  void clear() => _events.clear();

  // ---------------------------------------------------------------------------
  // Convenience recorders
  // ---------------------------------------------------------------------------

  void antSpawned(int tick) => record(ColonyEvent(
        tick: tick,
        type: ColonyEventType.antSpawned,
        severity: EventSeverity.info,
        message: 'New ant hatched',
      ));

  void antDied(int tick, String cause) => record(ColonyEvent(
        tick: tick,
        type: ColonyEventType.antDied,
        severity: EventSeverity.info,
        message: 'Ant died: $cause',
      ));

  void foodDelivered(int tick) => record(ColonyEvent(
        tick: tick,
        type: ColonyEventType.foodDelivered,
        severity: EventSeverity.info,
        message: 'Food delivered to nest',
      ));

  void lowFood(int tick, int remaining) => record(ColonyEvent(
        tick: tick,
        type: ColonyEventType.lowFood,
        severity: EventSeverity.warning,
        message: 'Food critically low ($remaining remaining)',
      ));

  void nestFlooded(int tick) => record(ColonyEvent(
        tick: tick,
        type: ColonyEventType.nestFlooded,
        severity: EventSeverity.critical,
        message: 'Nest entrance flooded!',
      ));

  void enemyDetected(int tick, int colonyId) => record(ColonyEvent(
        tick: tick,
        type: ColonyEventType.enemyDetected,
        severity: EventSeverity.warning,
        message: 'Enemy colony #$colonyId detected nearby',
      ));

  void milestonePopulation(int tick, int count) => record(ColonyEvent(
        tick: tick,
        type: ColonyEventType.milestone,
        severity: EventSeverity.milestone,
        message: 'Population reached $count!',
      ));

  void firstFoodDelivery(int tick) => record(ColonyEvent(
        tick: tick,
        type: ColonyEventType.milestone,
        severity: EventSeverity.milestone,
        message: 'First food delivery!',
      ));

  void speciesEvolved(int tick, int speciesCount) => record(ColonyEvent(
        tick: tick,
        type: ColonyEventType.evolution,
        severity: EventSeverity.info,
        message: 'NEAT species count: $speciesCount',
      ));
}

/// A single notable event in a colony's history.
class ColonyEvent {
  const ColonyEvent({
    required this.tick,
    required this.type,
    required this.severity,
    required this.message,
  });

  /// Simulation tick when this event occurred.
  final int tick;

  /// Category of event.
  final ColonyEventType type;

  /// How important this event is.
  final EventSeverity severity;

  /// Human-readable description.
  final String message;
}

/// Categories of colony events.
enum ColonyEventType {
  antSpawned,
  antDied,
  foodDelivered,
  lowFood,
  nestFlooded,
  enemyDetected,
  milestone,
  evolution,
  combat,
  nestExpanded,
}

/// Severity levels for colony events.
enum EventSeverity {
  info,
  warning,
  critical,
  milestone,
}
