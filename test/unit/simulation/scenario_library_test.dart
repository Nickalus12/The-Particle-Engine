import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/reactions/reaction_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

import '../../helpers/scenario_dsl.dart';

SimulationEngine _engine() {
  ElementRegistry.init();
  ReactionRegistry.init();
  return SimulationEngine(gridW: 96, gridH: 64, seed: 42);
}

int _count(SimulationEngine e, int el) {
  int c = 0;
  for (int i = 0; i < e.grid.length; i++) {
    if (e.grid[i] == el) c++;
  }
  return c;
}

void main() {
  test('scenario library presets place expected core elements', () {
    final e = _engine();
    ScenarioLibrary.subsystemConflict().apply(e);
    expect(_count(e, El.water), greaterThan(0));
    expect(_count(e, El.lava), greaterThan(0));
    expect(_count(e, El.cloud), greaterThan(0));
  });

  test('condensation stress preset seeds gas fields', () {
    final e = _engine();
    ScenarioLibrary.condensationStress().apply(e);
    expect(_count(e, El.vapor) + _count(e, El.steam), greaterThan(0));
  });
}
