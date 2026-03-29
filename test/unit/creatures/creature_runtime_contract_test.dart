import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/creatures/creature_registry.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

void _seedGround(SimulationEngine sim, int groundY) {
  for (int x = 0; x < sim.gridW; x++) {
    final idx = groundY * sim.gridW + x;
    sim.grid[idx] = El.stone;
    sim.life[idx] = 1;
  }
}

void main() {
  test(
    'registry runtime snapshot captures spawn, visibility and death accounting',
    () {
      ElementRegistry.init();
      final sim = SimulationEngine(gridW: 96, gridH: 64, seed: 42);
      _seedGround(sim, 44);

      final registry = CreatureRegistry();
      final colony = registry.spawn(
        40,
        43,
        gridW: sim.gridW,
        gridH: sim.gridH,
        seed: 7,
        rng: sim.rng,
      );

      // Visibility failure contract should trigger when a colony has population
      // but renderer reports no visible ants for a sustained tick window.
      for (int i = 0; i < 50; i++) {
        registry.reportRenderedCounts(<int, int>{});
        registry.tick(sim);
      }

      // Recover visibility and run additional ticks.
      registry.reportRenderedCounts(<int, int>{colony.id: colony.population});
      for (int i = 0; i < 20; i++) {
        registry.tick(sim);
      }

      final snapshot = registry.runtimeSnapshot().toJson();
      expect(snapshot['colony_count'], greaterThanOrEqualTo(1));
      expect(snapshot['creature_spawn_attempted'], greaterThan(0));
      expect(snapshot['creature_spawn_succeeded'], greaterThan(0));
      expect(snapshot['creature_visibility_failures'], greaterThanOrEqualTo(1));
      expect(snapshot['creature_population_alive'], greaterThan(0));

      final deathCauses = snapshot['death_causes'] as Map<String, int>;
      final deathsFromMap = deathCauses.values.fold<int>(0, (a, b) => a + b);
      expect(deathsFromMap, equals(colony.totalDied));
    },
  );
}
