import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';

import '../../helpers/scenario_dsl.dart';
import '../../helpers/simulation_harness.dart';

void main() {
  group('Scenario DSL', () {
    test('applies fill and sprinkle operations deterministically', () {
      final spec = ScenarioSpec.fromMap(<String, Object?>{
        'width': 32,
        'height': 24,
        'wind_force': 2,
        'ops': <Object?>[
          <String, Object?>{
            'type': 'fill_rect',
            'el': El.stone,
            'x0': 0,
            'y0': 20,
            'x1': 31,
            'y1': 23,
          },
          <String, Object?>{
            'type': 'sprinkle',
            'el': El.water,
            'x0': 0,
            'y0': 10,
            'x1': 31,
            'y1': 19,
            'chance': 20,
          },
        ],
      });
      final a = makeEngine(w: 32, h: 24, seed: 10);
      final b = makeEngine(w: 32, h: 24, seed: 10);
      spec.apply(a);
      spec.apply(b);

      expect(a.windForce, 2);
      expect(b.windForce, 2);
      expect(countEl(a, El.stone), 32 * 4);
      expect(countEl(a, El.water), countEl(b, El.water));
    });
  });
}
