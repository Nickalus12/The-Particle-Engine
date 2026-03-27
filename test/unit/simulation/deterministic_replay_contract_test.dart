import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/reactions/reaction_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

import '../../helpers/deterministic_replay.dart';
import '../../helpers/scenario_dsl.dart';

SimulationEngine _engine(int seed) {
  ElementRegistry.init();
  ReactionRegistry.init();
  return SimulationEngine(gridW: 64, gridH: 48, seed: seed);
}

void main() {
  test('replay contract emits required fields and hash series', () {
    final e = _engine(123);
    ScenarioLibrary.spillBasin(width: 64, height: 48).apply(e);
    final replay = captureReplayContract(
      engine: e,
      scenarioId: 'spill_basin_contract',
      seed: 123,
      ticks: 120,
      hashEvery: 10,
    );

    final json = replay.toJson();
    expect(json['scenario_id'], 'spill_basin_contract');
    expect(json['seed'], 123);
    expect(json['tick_count'], 120);
    expect((json['state_hash_series'] as List<Object?>).isNotEmpty, isTrue);
    expect(json['behavior_signature'], isA<Map<String, num>>());
  });
}
