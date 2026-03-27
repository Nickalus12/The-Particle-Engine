import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

void main() {
  test('SimulationEngine initializes without error', () {
    final engine = SimulationEngine(gridW: 64, gridH: 64);
    expect(engine.gridW, 64);
    expect(engine.gridH, 64);
  });
}
