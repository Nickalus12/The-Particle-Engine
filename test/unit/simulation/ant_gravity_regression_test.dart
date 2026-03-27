import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/element_behaviors.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/reactions/reaction_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

void main() {
  test('ant obeys gravity when unsupported', () {
    ElementRegistry.init();
    ReactionRegistry.init();
    final e = SimulationEngine(gridW: 48, gridH: 32, seed: 7);

    const startX = 20;
    const startY = 8;
    final startIdx = startY * e.gridW + startX;
    e.grid[startIdx] = El.ant;
    e.mass[startIdx] = elementBaseMass[El.ant];
    e.flags[startIdx] = e.simClock ? 0 : 0x80;
    e.markDirty(startX, startY);
    e.markAllDirty();

    for (int i = 0; i < 6; i++) {
      e.step(simulateElement);
    }

    int foundY = -1;
    for (int y = 0; y < e.gridH; y++) {
      if (e.grid[y * e.gridW + startX] == El.ant) {
        foundY = y;
        break;
      }
    }
    expect(foundY, greaterThan(startY),
        reason: 'Unsupported ant should fall under gravity.');
  });
}
