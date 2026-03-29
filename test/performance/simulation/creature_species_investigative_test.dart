@Tags(<String>['performance', 'performance_gate', 'investigative'])
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/creatures/ant.dart';
import 'package:the_particle_engine/creatures/creature_registry.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/reactions/reaction_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

import '../../helpers/perf_reporter.dart';

SimulationEngine _makeEngine() {
  ElementRegistry.init();
  ReactionRegistry.init();
  return SimulationEngine(gridW: 144, gridH: 88, seed: 404);
}

void _seedMixedHabitat(SimulationEngine sim) {
  final groundY = sim.gridH - 16;
  for (int x = 0; x < sim.gridW; x++) {
    final idx = groundY * sim.gridW + x;
    sim.grid[idx] = El.dirt;
    sim.life[idx] = 1;
  }
  for (int y = groundY - 12; y < groundY - 2; y++) {
    for (int x = sim.gridW ~/ 2; x < sim.gridW - 8; x++) {
      final idx = y * sim.gridW + x;
      sim.grid[idx] = El.water;
    }
  }
}

Future<void> _recordSpeciesScenario({
  required String scenario,
  required CreatureSpecies species,
  required int x,
  required int y,
  required SimulationEngine sim,
}) async {
  final registry = CreatureRegistry();
  final colony = registry.spawn(
    x,
    y,
    species: species,
    gridW: sim.gridW,
    gridH: sim.gridH,
    seed: 11,
    rng: Random(11),
  );
  int peak = 0;
  for (int i = 0; i < 220; i++) {
    registry.reportRenderedCounts(<int, int>{colony.id: colony.population});
    registry.tick(sim);
    peak = max(peak, colony.population);
  }
  final snapshot = registry.runtimeSnapshot();
  await PerfReporter.instance.record(
    suite: 'creature_investigative',
    scenario: scenario,
    metrics: <String, num>{
      'creature_population_alive': snapshot.populationAlive,
      'creature_population_peak': peak,
      'creature_spawn_success_rate': snapshot.spawnSuccessRate,
      'creature_visibility_failures': snapshot.visibilityFailures,
      'creature_queen_alive_ratio': snapshot.queenAliveRatio,
    },
    tags: <String, Object?>{
      'species': species.name,
      'device_class': 'desktop',
      'profile_hint': 'investigative',
    },
  );
  expect(snapshot.populationAlive, greaterThan(0));
}

void main() {
  test(
    'worm and fish investigative spawn lanes produce sustained populations',
    () async {
      final sim = _makeEngine();
      _seedMixedHabitat(sim);

      await _recordSpeciesScenario(
        scenario: 'worm_spawn_habitat_lane',
        species: CreatureSpecies.worm,
        x: sim.gridW ~/ 3,
        y: sim.gridH - 18,
        sim: sim,
      );
      await _recordSpeciesScenario(
        scenario: 'fish_spawn_habitat_lane',
        species: CreatureSpecies.fish,
        x: sim.gridW - 20,
        y: sim.gridH - 24,
        sim: sim,
      );
    },
  );
}
