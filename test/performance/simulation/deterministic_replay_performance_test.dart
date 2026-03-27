@Tags(<String>['performance', 'performance_gate'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/reactions/reaction_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

import '../../helpers/deterministic_replay.dart';
import '../../helpers/perf_reporter.dart';
import '../../helpers/scenario_dsl.dart';

SimulationEngine _engine(int seed) {
  ElementRegistry.init();
  ReactionRegistry.init();
  return SimulationEngine(gridW: 96, gridH: 64, seed: seed);
}

Future<void> _metric(String scenario, Map<String, num> metrics) {
  return PerfReporter.instance.record(
    suite: 'physics_integrity',
    scenario: scenario,
    metrics: metrics,
  );
}

void main() {
  test('deterministic replay parity for fixed seed scenarios', () async {
    final spec = ScenarioLibrary.spillBasin();

    final a = _engine(777);
    spec.apply(a);
    final ra = captureReplayContract(
      engine: a,
      scenarioId: 'spill_basin_replay',
      seed: 777,
      ticks: 240,
    );

    final b = _engine(777);
    spec.apply(b);
    final rb = captureReplayContract(
      engine: b,
      scenarioId: 'spill_basin_replay',
      seed: 777,
      ticks: 240,
    );

    expect(ra.stateHashSeries, equals(rb.stateHashSeries));
    expect(
      ra.behaviorSignature.gridHash,
      equals(rb.behaviorSignature.gridHash),
    );
    await _metric('deterministic_replay_parity', <String, num>{
      'hash_points': ra.stateHashSeries.length,
      'final_hash': ra.stateHashSeries.last,
    });
  });

  test('replay diverges on different seeds', () async {
    final spec = ScenarioLibrary.subsystemConflict();

    final a = _engine(901);
    spec.apply(a);
    final ra = captureReplayContract(
      engine: a,
      scenarioId: 'subsystem_conflict_seed_a',
      seed: 901,
      ticks: 220,
    );

    final b = _engine(902);
    spec.apply(b);
    final rb = captureReplayContract(
      engine: b,
      scenarioId: 'subsystem_conflict_seed_b',
      seed: 902,
      ticks: 220,
    );

    expect(ra.stateHashSeries.last, isNot(equals(rb.stateHashSeries.last)));
    await _metric('deterministic_replay_seed_sensitivity', <String, num>{
      'final_hash_a': ra.stateHashSeries.last,
      'final_hash_b': rb.stateHashSeries.last,
    });
  });
}
