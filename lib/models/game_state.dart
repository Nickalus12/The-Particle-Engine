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
    this.flags,
    this.temperature,
    this.pressure,
    this.pheroFood,
    this.pheroHome,
    this.charge,
    this.oxidation,
    this.moisture,
    this.support,
    this.voltage,
    this.sparkTimer,
    this.lightR,
    this.lightG,
    this.lightB,
    this.pH,
    this.dissolvedType,
    this.concentration,
    this.windX2,
    this.windY2,
    this.stress,
    this.vibration,
    this.vibrationFreq,
    this.mass,
    this.luminance,
    this.momentum,
    this.cellAge,
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

  final Uint8List? flags;
  final Uint8List? temperature;
  final Uint8List? pressure;
  final Uint8List? pheroFood;
  final Uint8List? pheroHome;
  final Int8List? charge;
  final Uint8List? oxidation;
  final Uint8List? moisture;
  final Uint8List? support;
  final Int8List? voltage;
  final Uint8List? sparkTimer;
  final Uint8List? lightR;
  final Uint8List? lightG;
  final Uint8List? lightB;
  final Uint8List? pH;
  final Uint8List? dissolvedType;
  final Uint8List? concentration;
  final Int8List? windX2;
  final Int8List? windY2;
  final Uint8List? stress;
  final Uint8List? vibration;
  final Uint8List? vibrationFreq;
  final Uint8List? mass;
  final Uint8List? luminance;
  final Uint8List? momentum;
  final Uint8List? cellAge;

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
      flags: Uint8List.fromList(engine.flags),
      temperature: Uint8List.fromList(engine.temperature),
      pressure: Uint8List.fromList(engine.pressure),
      pheroFood: Uint8List.fromList(engine.pheroFood),
      pheroHome: Uint8List.fromList(engine.pheroHome),
      charge: Int8List.fromList(engine.charge),
      oxidation: Uint8List.fromList(engine.oxidation),
      moisture: Uint8List.fromList(engine.moisture),
      support: Uint8List.fromList(engine.support),
      voltage: Int8List.fromList(engine.voltage),
      sparkTimer: Uint8List.fromList(engine.sparkTimer),
      lightR: Uint8List.fromList(engine.lightR),
      lightG: Uint8List.fromList(engine.lightG),
      lightB: Uint8List.fromList(engine.lightB),
      pH: Uint8List.fromList(engine.pH),
      dissolvedType: Uint8List.fromList(engine.dissolvedType),
      concentration: Uint8List.fromList(engine.concentration),
      windX2: Int8List.fromList(engine.windX2),
      windY2: Int8List.fromList(engine.windY2),
      stress: Uint8List.fromList(engine.stress),
      vibration: Uint8List.fromList(engine.vibration),
      vibrationFreq: Uint8List.fromList(engine.vibrationFreq),
      mass: Uint8List.fromList(engine.mass),
      luminance: Uint8List.fromList(engine.luminance),
      momentum: Uint8List.fromList(engine.momentum),
      cellAge: Uint8List.fromList(engine.cellAge),
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
    _restoreUint8(engine.flags, flags);
    _restoreUint8(engine.temperature, temperature);
    _restoreUint8(engine.pressure, pressure);
    _restoreUint8(engine.pheroFood, pheroFood);
    _restoreUint8(engine.pheroHome, pheroHome);
    _restoreInt8(engine.charge, charge);
    _restoreUint8(engine.oxidation, oxidation);
    _restoreUint8(engine.moisture, moisture);
    _restoreUint8(engine.support, support);
    _restoreInt8(engine.voltage, voltage);
    _restoreUint8(engine.sparkTimer, sparkTimer);
    _restoreUint8(engine.lightR, lightR);
    _restoreUint8(engine.lightG, lightG);
    _restoreUint8(engine.lightB, lightB);
    _restoreUint8(engine.pH, pH);
    _restoreUint8(engine.dissolvedType, dissolvedType);
    _restoreUint8(engine.concentration, concentration);
    _restoreInt8(engine.windX2, windX2);
    _restoreInt8(engine.windY2, windY2);
    _restoreUint8(engine.stress, stress);
    _restoreUint8(engine.vibration, vibration);
    _restoreUint8(engine.vibrationFreq, vibrationFreq);
    _restoreUint8(engine.mass, mass);
    _restoreUint8(engine.luminance, luminance);
    _restoreUint8(engine.momentum, momentum);
    _restoreUint8(engine.cellAge, cellAge);
    engine.frameCount = frameCount;
    engine.gravityDir = gravityDir;
    engine.windForce = windForce;
    engine.isNight = isNight;
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
      if (flags != null) 'flags': _rleEncode(flags!),
      if (temperature != null) 'temperature': _rleEncode(temperature!),
      if (pressure != null) 'pressure': _rleEncode(pressure!),
      if (pheroFood != null) 'pheroFood': _rleEncode(pheroFood!),
      if (pheroHome != null) 'pheroHome': _rleEncode(pheroHome!),
      if (charge != null) 'charge': _int8ToIntList(charge!),
      if (oxidation != null) 'oxidation': _rleEncode(oxidation!),
      if (moisture != null) 'moisture': _rleEncode(moisture!),
      if (support != null) 'support': _rleEncode(support!),
      if (voltage != null) 'voltage': _int8ToIntList(voltage!),
      if (sparkTimer != null) 'sparkTimer': _rleEncode(sparkTimer!),
      if (lightR != null) 'lightR': _rleEncode(lightR!),
      if (lightG != null) 'lightG': _rleEncode(lightG!),
      if (lightB != null) 'lightB': _rleEncode(lightB!),
      if (pH != null) 'pH': _rleEncode(pH!),
      if (dissolvedType != null) 'dissolvedType': _rleEncode(dissolvedType!),
      if (concentration != null) 'concentration': _rleEncode(concentration!),
      if (windX2 != null) 'windX2': _int8ToIntList(windX2!),
      if (windY2 != null) 'windY2': _int8ToIntList(windY2!),
      if (stress != null) 'stress': _rleEncode(stress!),
      if (vibration != null) 'vibration': _rleEncode(vibration!),
      if (vibrationFreq != null) 'vibrationFreq': _rleEncode(vibrationFreq!),
      if (mass != null) 'mass': _rleEncode(mass!),
      if (luminance != null) 'luminance': _rleEncode(luminance!),
      if (momentum != null) 'momentum': _rleEncode(momentum!),
      if (cellAge != null) 'cellAge': _rleEncode(cellAge!),
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
      flags: _decodeOptionalUint8(json['flags'], totalCells),
      temperature: _decodeOptionalUint8(json['temperature'], totalCells),
      pressure: _decodeOptionalUint8(json['pressure'], totalCells),
      pheroFood: _decodeOptionalUint8(json['pheroFood'], totalCells),
      pheroHome: _decodeOptionalUint8(json['pheroHome'], totalCells),
      charge: _decodeOptionalInt8(json['charge'], totalCells),
      oxidation: _decodeOptionalUint8(json['oxidation'], totalCells),
      moisture: _decodeOptionalUint8(json['moisture'], totalCells),
      support: _decodeOptionalUint8(json['support'], totalCells),
      voltage: _decodeOptionalInt8(json['voltage'], totalCells),
      sparkTimer: _decodeOptionalUint8(json['sparkTimer'], totalCells),
      lightR: _decodeOptionalUint8(json['lightR'], totalCells),
      lightG: _decodeOptionalUint8(json['lightG'], totalCells),
      lightB: _decodeOptionalUint8(json['lightB'], totalCells),
      pH: _decodeOptionalUint8(json['pH'], totalCells),
      dissolvedType: _decodeOptionalUint8(json['dissolvedType'], totalCells),
      concentration: _decodeOptionalUint8(json['concentration'], totalCells),
      windX2: _decodeOptionalInt8(json['windX2'], totalCells),
      windY2: _decodeOptionalInt8(json['windY2'], totalCells),
      stress: _decodeOptionalUint8(json['stress'], totalCells),
      vibration: _decodeOptionalUint8(json['vibration'], totalCells),
      vibrationFreq: _decodeOptionalUint8(json['vibrationFreq'], totalCells),
      mass: _decodeOptionalUint8(json['mass'], totalCells),
      luminance: _decodeOptionalUint8(json['luminance'], totalCells),
      momentum: _decodeOptionalUint8(json['momentum'], totalCells),
      cellAge: _decodeOptionalUint8(json['cellAge'], totalCells),
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
      final value = (encoded[i] as int).clamp(0, 255).toInt();
      final count = encoded[i + 1] as int;
      final end = (offset + count).clamp(0, expectedLength).toInt();
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
      result[i] = (data[i] as int).clamp(-128, 127).toInt();
    }
    return result;
  }

  static Uint8List? _decodeOptionalUint8(dynamic encoded, int expectedLength) {
    if (encoded is! List) return null;
    return _rleDecode(encoded, expectedLength);
  }

  static Int8List? _decodeOptionalInt8(dynamic data, int expectedLength) {
    if (data is! List) return null;
    return _intListToInt8(data, expectedLength);
  }

  static void _restoreUint8(Uint8List target, Uint8List? source) {
    if (source == null) return;
    target.setAll(0, source);
  }

  static void _restoreInt8(Int8List target, Int8List? source) {
    if (source == null) return;
    target.setAll(0, source);
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
    required this.species,
    required this.originX,
    required this.originY,
    required this.foodStored,
    required this.ageTicks,
    required this.totalSpawned,
    required this.totalDied,
    required this.ants,
    required this.genomes,
    required this.nestChambers,
    this.eggsCount = 0,
    this.larvaeCount = 0,
    this.larvaeFood = 0,
    this.isOrphaned = false,
    this.orphanTicks = 0,
  });

  final int id;
  final String species;
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
  int eggsCount;
  int larvaeCount;
  int larvaeFood;
  bool isOrphaned;
  int orphanTicks;

  CreatureSpecies get speciesEnum {
    try {
      return CreatureSpecies.values.byName(species);
    } catch (_) {
      return CreatureSpecies.ant;
    }
  }

  /// Capture from a live colony.
  factory ColonySnapshot.fromColony(Colony colony) {
    return ColonySnapshot(
      id: colony.id,
      species: colony.species.name,
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
      eggsCount: colony.eggsCount,
      larvaeCount: colony.larvaeCount,
      larvaeFood: colony.larvaeFood,
      isOrphaned: colony.isOrphaned,
      orphanTicks: colony.orphanTicks,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'species': species,
      'originX': originX,
      'originY': originY,
      'foodStored': foodStored,
      'ageTicks': ageTicks,
      'totalSpawned': totalSpawned,
      'totalDied': totalDied,
      'ants': ants.map((a) => a.toJson()).toList(),
      'genomes': genomes.map((g) => g.toJson()).toList(),
      'nestChambers': nestChambers,
      'eggsCount': eggsCount,
      'larvaeCount': larvaeCount,
      'larvaeFood': larvaeFood,
      'isOrphaned': isOrphaned,
      'orphanTicks': orphanTicks,
    };
  }

  factory ColonySnapshot.fromJson(Map<String, dynamic> json) {
    return ColonySnapshot(
      id: json['id'] as int,
      species: json['species'] as String? ?? CreatureSpecies.ant.name,
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
      eggsCount: json['eggsCount'] as int? ?? 0,
      larvaeCount: json['larvaeCount'] as int? ?? 0,
      larvaeFood: json['larvaeFood'] as int? ?? 0,
      isOrphaned: json['isOrphaned'] as bool? ?? false,
      orphanTicks: json['orphanTicks'] as int? ?? 0,
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
    required this.carriedFoodType,
    required this.carryingDirt,
    required this.role,
  });

  final int x;
  final int y;
  final int genomeIndex;
  final double energy;
  final int age;
  final bool carryingFood;
  final int carriedFoodType;
  final bool carryingDirt;
  final String role;

  AntRole get roleEnum {
    try {
      return AntRole.values.byName(role);
    } catch (_) {
      return AntRole.worker;
    }
  }

  factory AntSnapshot.fromAnt(Ant ant) {
    return AntSnapshot(
      x: ant.x,
      y: ant.y,
      genomeIndex: ant.genomeIndex,
      energy: ant.energy,
      age: ant.age,
      carryingFood: ant.carryingFood,
      carriedFoodType: ant.carriedFoodType,
      carryingDirt: ant.carryingDirt,
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
        'cft': carriedFoodType,
        'cd': carryingDirt,
        'role': role,
      };

  factory AntSnapshot.fromJson(Map<String, dynamic> json) => AntSnapshot(
        x: json['x'] as int,
        y: json['y'] as int,
        genomeIndex: json['gi'] as int,
        energy: (json['e'] as num).toDouble(),
        age: json['age'] as int? ?? 0,
        carryingFood: json['cf'] as bool? ?? false,
        carriedFoodType: json['cft'] as int? ?? 0,
        carryingDirt: json['cd'] as bool? ?? false,
        role: json['role'] as String? ?? 'explorer',
      );
}
