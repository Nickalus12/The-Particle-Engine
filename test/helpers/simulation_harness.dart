import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/reactions/reaction_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

SimulationEngine makeEngine({int w = 64, int h = 64, int seed = 42}) {
  ElementRegistry.init();
  ReactionRegistry.init();
  return SimulationEngine(gridW: w, gridH: h, seed: seed);
}

int idx(SimulationEngine e, int x, int y) => y * e.gridW + x;

void setCell(SimulationEngine e, int x, int y, int el) {
  final i = idx(e, x, y);
  e.clearCell(i);
  e.grid[i] = el;
  e.mass[i] = elementBaseMass[el];
  e.flags[i] = e.simClock ? 0 : 0x80;
  e.markDirty(x, y);
  e.unsettleNeighbors(x, y);
}

int countEl(SimulationEngine e, int el) {
  int count = 0;
  for (int i = 0; i < e.grid.length; i++) {
    if (e.grid[i] == el) count++;
  }
  return count;
}
