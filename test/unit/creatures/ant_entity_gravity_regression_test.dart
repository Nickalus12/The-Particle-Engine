import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/creatures/ant.dart';
import 'package:the_particle_engine/creatures/neat/neat_config.dart';
import 'package:the_particle_engine/creatures/neat/neat_genome.dart';
import 'package:the_particle_engine/creatures/pheromone_system.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

void main() {
  test('queen ant falls when unsupported even on non-move ticks', () {
    ElementRegistry.init();

    final sim = SimulationEngine(gridW: 48, gridH: 32, seed: 99);
    final genome = NeatGenome.seed(
      const NeatConfig(),
      InnovationCounter(),
      Random(1),
    );

    final ant = Ant(
      x: 20,
      y: 6,
      colonyId: 0,
      nestX: 20,
      nestY: 6,
      genomeIndex: 0,
      genome: genome,
      seed: 123,
    )..role = AntRole.queen;

    final food = PheromoneSystem(width: sim.gridW, height: sim.gridH);
    final home = PheromoneSystem(width: sim.gridW, height: sim.gridH);
    final danger = PheromoneSystem(width: sim.gridW, height: sim.gridH);

    final startY = ant.y;
    ant.tick(
      sim: sim,
      foodPheromones: food,
      homePheromones: home,
      dangerPheromones: danger,
      nearbyEnemies: const <Ant>[],
    );

    expect(ant.y, startY + 1,
        reason: 'Unsupported ant entities should always obey gravity.');
  });
}
