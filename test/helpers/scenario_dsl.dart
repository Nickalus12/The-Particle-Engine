import 'dart:math';

import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

typedef ScenarioSpecMap = Map<String, Object?>;

class ScenarioOperation {
  const ScenarioOperation._({
    required this.kind,
    required this.element,
    this.x0 = 0,
    this.y0 = 0,
    this.x1 = 0,
    this.y1 = 0,
    this.chance = 100,
  });

  factory ScenarioOperation.fillRect({
    required int element,
    required int x0,
    required int y0,
    required int x1,
    required int y1,
  }) {
    return ScenarioOperation._(
      kind: 'fill_rect',
      element: element,
      x0: x0,
      y0: y0,
      x1: x1,
      y1: y1,
    );
  }

  factory ScenarioOperation.sprinkle({
    required int element,
    required int x0,
    required int y0,
    required int x1,
    required int y1,
    required int chance,
  }) {
    return ScenarioOperation._(
      kind: 'sprinkle',
      element: element,
      x0: x0,
      y0: y0,
      x1: x1,
      y1: y1,
      chance: chance,
    );
  }

  final String kind;
  final int element;
  final int x0;
  final int y0;
  final int x1;
  final int y1;
  final int chance;
}

class ScenarioSpec {
  ScenarioSpec({
    required this.width,
    required this.height,
    required this.operations,
    this.windForce = 0,
    this.gravityDir = 1,
  });

  factory ScenarioSpec.fromMap(ScenarioSpecMap map) {
    final width = (map['width'] as int?) ?? 96;
    final height = (map['height'] as int?) ?? 64;
    final windForce = (map['wind_force'] as int?) ?? 0;
    final gravityDir = (map['gravity_dir'] as int?) ?? 1;
    final opsRaw = (map['ops'] as List<Object?>?) ?? const <Object?>[];
    final operations = <ScenarioOperation>[];
    for (final raw in opsRaw) {
      if (raw is! Map<String, Object?>) continue;
      final type = raw['type'] as String? ?? '';
      final element = raw['el'] as int? ?? El.empty;
      final x0 = raw['x0'] as int? ?? 0;
      final y0 = raw['y0'] as int? ?? 0;
      final x1 = raw['x1'] as int? ?? x0;
      final y1 = raw['y1'] as int? ?? y0;
      if (type == 'fill_rect') {
        operations.add(
          ScenarioOperation.fillRect(
            element: element,
            x0: x0,
            y0: y0,
            x1: x1,
            y1: y1,
          ),
        );
      } else if (type == 'sprinkle') {
        operations.add(
          ScenarioOperation.sprinkle(
            element: element,
            x0: x0,
            y0: y0,
            x1: x1,
            y1: y1,
            chance: (raw['chance'] as int?) ?? 20,
          ),
        );
      }
    }
    return ScenarioSpec(
      width: width,
      height: height,
      windForce: windForce,
      gravityDir: gravityDir,
      operations: operations,
    );
  }

  final int width;
  final int height;
  final int windForce;
  final int gravityDir;
  final List<ScenarioOperation> operations;

  void apply(SimulationEngine engine, {Random? random}) {
    final r = random ?? Random(1);
    engine.windForce = windForce;
    engine.gravityDir = gravityDir;
    for (final op in operations) {
      final minX = min(op.x0, op.x1).clamp(0, engine.gridW - 1);
      final maxX = max(op.x0, op.x1).clamp(0, engine.gridW - 1);
      final minY = min(op.y0, op.y1).clamp(0, engine.gridH - 1);
      final maxY = max(op.y0, op.y1).clamp(0, engine.gridH - 1);
      for (int y = minY; y <= maxY; y++) {
        for (int x = minX; x <= maxX; x++) {
          if (op.kind == 'sprinkle') {
            final chance = op.chance.clamp(1, 100);
            if (r.nextInt(100) >= chance) continue;
          }
          final idx = y * engine.gridW + x;
          engine.clearCell(idx);
          engine.grid[idx] = op.element;
          engine.mass[idx] = elementBaseMass[op.element];
          engine.flags[idx] = engine.simClock ? 0 : 0x80;
          engine.markDirty(x, y);
          engine.unsettleNeighbors(x, y);
        }
      }
    }
    engine.markAllDirty();
  }
}

class ScenarioLibrary {
  const ScenarioLibrary._();

  static ScenarioSpec spillBasin({int width = 96, int height = 64}) {
    return ScenarioSpec(
      width: width,
      height: height,
      operations: <ScenarioOperation>[
        ScenarioOperation.fillRect(
          element: El.stone,
          x0: 0,
          y0: height - 8,
          x1: width - 1,
          y1: height - 1,
        ),
        ScenarioOperation.fillRect(
          element: El.stone,
          x0: 22,
          y0: height - 30,
          x1: 24,
          y1: height - 9,
        ),
        ScenarioOperation.fillRect(
          element: El.stone,
          x0: 72,
          y0: height - 30,
          x1: 74,
          y1: height - 9,
        ),
        ScenarioOperation.fillRect(
          element: El.water,
          x0: 30,
          y0: 8,
          x1: 66,
          y1: 18,
        ),
      ],
    );
  }

  static ScenarioSpec pressureLock({int width = 96, int height = 64}) {
    return ScenarioSpec(
      width: width,
      height: height,
      operations: <ScenarioOperation>[
        ScenarioOperation.fillRect(
          element: El.stone,
          x0: 0,
          y0: height - 6,
          x1: width - 1,
          y1: height - 1,
        ),
        ScenarioOperation.fillRect(
          element: El.stone,
          x0: 10,
          y0: 18,
          x1: 12,
          y1: height - 7,
        ),
        ScenarioOperation.fillRect(
          element: El.stone,
          x0: width - 13,
          y0: 18,
          x1: width - 11,
          y1: height - 7,
        ),
        ScenarioOperation.fillRect(
          element: El.water,
          x0: 13,
          y0: 8,
          x1: width - 14,
          y1: height - 25,
        ),
      ],
    );
  }

  static ScenarioSpec cloudChamber({int width = 96, int height = 64}) {
    return ScenarioSpec(
      width: width,
      height: height,
      windForce: 1,
      operations: <ScenarioOperation>[
        ScenarioOperation.fillRect(
          element: El.cloud,
          x0: 18,
          y0: 8,
          x1: 78,
          y1: 14,
        ),
        ScenarioOperation.sprinkle(
          element: El.vapor,
          x0: 15,
          y0: 15,
          x1: 80,
          y1: 26,
          chance: 35,
        ),
      ],
    );
  }

  static ScenarioSpec condensationStress({int width = 96, int height = 64}) {
    return ScenarioSpec(
      width: width,
      height: height,
      operations: <ScenarioOperation>[
        ScenarioOperation.fillRect(
          element: El.stone,
          x0: 0,
          y0: 0,
          x1: width - 1,
          y1: 1,
        ),
        ScenarioOperation.sprinkle(
          element: El.vapor,
          x0: 6,
          y0: 2,
          x1: width - 7,
          y1: 24,
          chance: 45,
        ),
        ScenarioOperation.sprinkle(
          element: El.steam,
          x0: 6,
          y0: 25,
          x1: width - 7,
          y1: 40,
          chance: 25,
        ),
      ],
    );
  }

  static ScenarioSpec antColonyDrop({int width = 96, int height = 64}) {
    return ScenarioSpec(
      width: width,
      height: height,
      operations: <ScenarioOperation>[
        ScenarioOperation.fillRect(
          element: El.stone,
          x0: 0,
          y0: height - 8,
          x1: width - 1,
          y1: height - 1,
        ),
        ScenarioOperation.fillRect(
          element: El.dirt,
          x0: 20,
          y0: height - 20,
          x1: 76,
          y1: height - 9,
        ),
      ],
    );
  }

  static ScenarioSpec subsystemConflict({int width = 96, int height = 64}) {
    return ScenarioSpec(
      width: width,
      height: height,
      windForce: 2,
      operations: <ScenarioOperation>[
        ScenarioOperation.fillRect(
          element: El.stone,
          x0: 0,
          y0: height - 7,
          x1: width - 1,
          y1: height - 1,
        ),
        ScenarioOperation.fillRect(
          element: El.lava,
          x0: 8,
          y0: height - 14,
          x1: 24,
          y1: height - 8,
        ),
        ScenarioOperation.fillRect(
          element: El.water,
          x0: 34,
          y0: height - 28,
          x1: 72,
          y1: height - 17,
        ),
        ScenarioOperation.sprinkle(
          element: El.cloud,
          x0: 30,
          y0: 6,
          x1: 86,
          y1: 14,
          chance: 55,
        ),
      ],
    );
  }
}
