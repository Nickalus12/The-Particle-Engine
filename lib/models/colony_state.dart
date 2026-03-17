/// Serializable snapshot of a colony's state for save/load.
///
/// The live colony state now lives directly on [Colony]. This class
/// is retained for serialization (save games) and for the colony inspector UI.
class ColonyState {
  ColonyState({
    required this.originX,
    required this.originY,
    this.population = 0,
    this.foodStored = 0,
    this.ageTicks = 0,
    this.totalSpawned = 0,
    this.totalDied = 0,
    this.averageFitness = 0.0,
    this.averageAge = 0.0,
    this.speciesCount = 0,
    this.antsCarryingFood = 0,
  });

  /// Grid X of the colony's nest entrance.
  final int originX;

  /// Grid Y of the colony's nest entrance.
  final int originY;

  /// Current number of living ants.
  int population;

  /// Banked food units — ants deposit foraged food here.
  int foodStored;

  /// Number of simulation ticks this colony has survived.
  int ageTicks;

  /// Total ants ever spawned.
  int totalSpawned;

  /// Total ants that have died.
  int totalDied;

  /// Average fitness of living ants.
  double averageFitness;

  /// Average age of living ants.
  double averageAge;

  /// Number of NEAT species in this colony's gene pool.
  int speciesCount;

  /// How many ants are currently carrying food.
  int antsCarryingFood;

  /// Whether the colony is still alive.
  bool get isAlive => population > 0 || foodStored > 0;

  /// Serialize to JSON-compatible map.
  Map<String, dynamic> toJson() => {
        'originX': originX,
        'originY': originY,
        'population': population,
        'foodStored': foodStored,
        'ageTicks': ageTicks,
        'totalSpawned': totalSpawned,
        'totalDied': totalDied,
        'averageFitness': averageFitness,
        'averageAge': averageAge,
        'speciesCount': speciesCount,
        'antsCarryingFood': antsCarryingFood,
      };

  /// Deserialize from JSON-compatible map.
  factory ColonyState.fromJson(Map<String, dynamic> json) => ColonyState(
        originX: json['originX'] as int,
        originY: json['originY'] as int,
        population: json['population'] as int? ?? 0,
        foodStored: json['foodStored'] as int? ?? 0,
        ageTicks: json['ageTicks'] as int? ?? 0,
        totalSpawned: json['totalSpawned'] as int? ?? 0,
        totalDied: json['totalDied'] as int? ?? 0,
        averageFitness: (json['averageFitness'] as num?)?.toDouble() ?? 0.0,
        averageAge: (json['averageAge'] as num?)?.toDouble() ?? 0.0,
        speciesCount: json['speciesCount'] as int? ?? 0,
        antsCarryingFood: json['antsCarryingFood'] as int? ?? 0,
      );

  /// Create a snapshot from a live colony.
  factory ColonyState.fromColony(dynamic colony) {
    // Uses dynamic to avoid circular import with Colony.
    return ColonyState(
      originX: colony.originX as int,
      originY: colony.originY as int,
      population: colony.population as int,
      foodStored: colony.foodStored as int,
      ageTicks: colony.ageTicks as int,
      totalSpawned: colony.totalSpawned as int,
      totalDied: colony.totalDied as int,
      averageFitness: colony.averageAntFitness as double,
      averageAge: colony.averageAntAge as double,
      speciesCount: colony.evolution.speciesCount as int,
      antsCarryingFood: colony.antsCarryingFood as int,
    );
  }
}
