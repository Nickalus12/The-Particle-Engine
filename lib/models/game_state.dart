import 'dart:typed_data';

import '../creatures/ant.dart';
import '../creatures/colony.dart';
import '../creatures/neat/neat_genome.dart';
import '../simulation/simulation_engine.dart';

/// Serialisable snapshot of the entire sandbox world.
///
/// Captures the simulation grid (with per-cell auxiliary data), all living
/// colonies and their ants (including NEAT genomes), pheromone grids, tick
/// count, and day/night state.
///
/// [SaveService] converts this to/from JSON for persistence. The grid uses
/// run-length encoding to avoid serialising vast runs of empty cells.
class GameState {
  GameState({
    required this.gridW,
    required this.gridH,
    required this.grid,
    required this.life,
    required this.velX,
    required this.velY,
    this.frameCount = 0,
    this.gravityDir = 1,
    this.windForce = 0,
    this.isNight = false,
    this.colonies = const [],
  });

  /// Width of the simulation grid.
  final int gridW;

  /// Height of the simulation grid.
  final int gridH;

  /// Element type per cell (byte value from [El]).
  final Uint8List grid;

  /// Per-cell lifetime / state counter.
  final Uint8List life;

  /// Per-cell horizontal velocity.
  final Int8List velX;

  /// Per-cell vertical velocity.
  final Int8List velY;

  /// Number of simulation frames elapsed.
  int frameCount;

  /// Gravity direction: 1 = down, -1 = up.
  int gravityDir;

  /// Wind force: -3..+3.
  int windForce;

  /// Whether it's currently night.
  bool isNight;

  /// Serialised colony snapshots.
  final List<ColonySnapshot> colonies;

  /// Whether the simulation is currently running (transient, not saved).
  bool isPaused = false;

  // ── Capture from live engine ─────────────────────────────────────────

  /// Create a GameState from a live [SimulationEngine] and colony list.
  factory GameState.capture(
    SimulationEngine engine,
    List<Colony> colonies,
  ) {
    return GameState(
      gridW: engine.gridW,
      gridH: engine.gridH,
      grid: Uint8List.fromList(engine.grid),
      life: Uint8List.fromList(engine.life),
      velX: Int8List.fromList(engine.velX),
      velY: Int8List.fromList(engine.velY),
      frameCount: engine.frameCount,
      gravityDir: engine.gravityDir,
      windForce: engine.windForce,
      isNight: engine.isNight,
      colonies: colonies.map((c) => ColonySnapshot.fromColony(c)).toList(),
    );
  }

  /// Restore this state into a live engine. Returns the colony snapshots
  /// for the caller to reconstruct [Colony] objects.
  void restoreInto(SimulationEngine engine) {
    if (engine.gridW != gridW || engine.gridH != gridH) {
      engine.init(gridW, gridH);
    }
    engine.grid.setAll(0, grid);
    engine.life.setAll(0, life);
    engine.velX.setAll(0, velX);
    engine.velY.setAll(0, velY);
    engine.frameCount = frameCount;
    engine.gravityDir = gravityDir;
    engine.windForce = windForce;
    engine.isNight = isNight;
    engine.pheroFood.fillRange(0, engine.pheroFood.length, 0);
    engine.pheroHome.fillRange(0, engine.pheroHome.length, 0);
    engine.markAllDirty();
  }

  // ── Serialisation ────────────────────────────────────────────────────

  /// Encode to a JSON-compatible map.
  ///
  /// The grid uses run-length encoding: consecutive runs of the same byte
  /// value are stored as [value, count] pairs rather than individual bytes.
  Map<String, dynamic> toJson() {
    return {
      'gridW': gridW,
      'gridH': gridH,
      'grid': _rleEncode(grid),
      'life': _rleEncode(life),
      'velX': _int8ToIntList(velX),
      'velY': _int8ToIntList(velY),
      'frameCount': frameCount,
      'gravityDir': gravityDir,
      'windForce': windForce,
      'isNight': isNight,
      'colonies': colonies.map((c) => c.toJson()).toList(),
    };
  }

  /// Decode from a JSON-compatible map.
  factory GameState.fromJson(Map<String, dynamic> json) {
    final gridW = json['gridW'] as int;
    final gridH = json['gridH'] as int;
    final totalCells = gridW * gridH;

    return GameState(
      gridW: gridW,
      gridH: gridH,
      grid: _rleDecode(json['grid'] as List, totalCells),
      life: _rleDecode(json['life'] as List, totalCells),
      velX: _intListToInt8(json['velX'] as List, totalCells),
      velY: _intListToInt8(json['velY'] as List, totalCells),
      frameCount: json['frameCount'] as int? ?? 0,
      gravityDir: json['gravityDir'] as int? ?? 1,
      windForce: json['windForce'] as int? ?? 0,
      isNight: json['isNight'] as bool? ?? false,
      colonies: (json['colonies'] as List?)
              ?.map((c) =>
                  ColonySnapshot.fromJson(c as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  // ── RLE helpers ──────────────────────────────────────────────────────

  /// Run-length encode a [Uint8List] into [value, count, value, count, …].
  static List<int> _rleEncode(Uint8List data) {
    if (data.isEmpty) return [];
    final result = <int>[];
    int current = data[0];
    int count = 1;
    for (var i = 1; i < data.length; i++) {
      if (data[i] == current && count < 65535) {
        count++;
      } else {
        result.add(current);
        result.add(count);
        current = data[i];
        count = 1;
      }
    }
    result.add(current);
    result.add(count);
    return result;
  }

  /// Decode an RLE-encoded list back into a [Uint8List].
  static Uint8List _rleDecode(List encoded, int expectedLength) {
    final result = Uint8List(expectedLength);
    var offset = 0;
    for (var i = 0; i < encoded.length - 1; i += 2) {
      final value = (encoded[i] as int).clamp(0, 255);
      final count = encoded[i + 1] as int;
      final end = (offset + count).clamp(0, expectedLength);
      for (var j = offset; j < end; j++) {
        result[j] = value;
      }
      offset = end;
    }
    return result;
  }

  /// Convert [Int8List] to plain [List<int>] for JSON.
  static List<int> _int8ToIntList(Int8List data) {
    return List<int>.from(data);
  }

  /// Convert plain [List] back to [Int8List].
  static Int8List _intListToInt8(List data, int expectedLength) {
    final result = Int8List(expectedLength);
    for (var i = 0; i < data.length && i < expectedLength; i++) {
      result[i] = (data[i] as int).clamp(-128, 127);
    }
    return result;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Colony snapshot
// ═══════════════════════════════════════════════════════════════════════════

/// Serialisable snapshot of a single colony, including all living ants and
/// their NEAT genomes.
class ColonySnapshot {
  ColonySnapshot({
    required this.id,
    required this.originX,
    required this.originY,
    required this.foodStored,
    required this.ageTicks,
    required this.totalSpawned,
    required this.totalDied,
    required this.ants,
    required this.genomes,
    required this.nestChambers,
  });

  final int id;
  final int originX;
  final int originY;
  int foodStored;
  int ageTicks;
  int totalSpawned;
  int totalDied;
  final List<AntSnapshot> ants;

  /// All genomes in the NEAT population (the full gene pool).
  final List<NeatGenome> genomes;

  /// Nest chamber grid indices.
  final List<int> nestChambers;

  /// Capture from a live colony.
  factory ColonySnapshot.fromColony(Colony colony) {
    return ColonySnapshot(
      id: colony.id,
      originX: colony.originX,
      originY: colony.originY,
      foodStored: colony.foodStored,
      ageTicks: colony.ageTicks,
      totalSpawned: colony.totalSpawned,
      totalDied: colony.totalDied,
      ants: colony.ants
          .where((a) => a.alive)
          .map((a) => AntSnapshot.fromAnt(a))
          .toList(),
      genomes: colony.evolution.population.genomes
          .map((g) => g.copy())
          .toList(),
      nestChambers: colony.nestChambers.toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'originX': originX,
      'originY': originY,
      'foodStored': foodStored,
      'ageTicks': ageTicks,
      'totalSpawned': totalSpawned,
      'totalDied': totalDied,
      'ants': ants.map((a) => a.toJson()).toList(),
      'genomes': genomes.map((g) => g.toJson()).toList(),
      'nestChambers': nestChambers,
    };
  }

  factory ColonySnapshot.fromJson(Map<String, dynamic> json) {
    return ColonySnapshot(
      id: json['id'] as int,
      originX: json['originX'] as int,
      originY: json['originY'] as int,
      foodStored: json['foodStored'] as int? ?? 0,
      ageTicks: json['ageTicks'] as int? ?? 0,
      totalSpawned: json['totalSpawned'] as int? ?? 0,
      totalDied: json['totalDied'] as int? ?? 0,
      ants: (json['ants'] as List?)
              ?.map((a) => AntSnapshot.fromJson(a as Map<String, dynamic>))
              .toList() ??
          [],
      genomes: (json['genomes'] as List?)
              ?.map(
                  (g) => NeatGenome.fromJson(g as Map<String, dynamic>))
              .toList() ??
          [],
      nestChambers: (json['nestChambers'] as List?)
              ?.map((e) => e as int)
              .toList() ??
          [],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Ant snapshot (living ants only — dead ants are not saved)
// ═══════════════════════════════════════════════════════════════════════════

/// Serialisable snapshot of a single living ant.
///
/// Ant memory (brain activations, recent path history) is ephemeral and dies
/// with the save. Only persistent state (position, energy, role, genome
/// index) is preserved.
class AntSnapshot {
  AntSnapshot({
    required this.x,
    required this.y,
    required this.genomeIndex,
    required this.energy,
    required this.age,
    required this.carryingFood,
    required this.role,
  });

  final int x;
  final int y;
  final int genomeIndex;
  final double energy;
  final int age;
  final bool carryingFood;
  final String role;

  factory AntSnapshot.fromAnt(Ant ant) {
    return AntSnapshot(
      x: ant.x,
      y: ant.y,
      genomeIndex: ant.genomeIndex,
      energy: ant.energy,
      age: ant.age,
      carryingFood: ant.carryingFood,
      role: ant.role.name,
    );
  }

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        'gi': genomeIndex,
        'e': energy,
        'age': age,
        'cf': carryingFood,
        'role': role,
      };

  factory AntSnapshot.fromJson(Map<String, dynamic> json) => AntSnapshot(
        x: json['x'] as int,
        y: json['y'] as int,
        genomeIndex: json['gi'] as int,
        energy: (json['e'] as num).toDouble(),
        age: json['age'] as int? ?? 0,
        carryingFood: json['cf'] as bool? ?? false,
        role: json['role'] as String? ?? 'explorer',
      );
}
