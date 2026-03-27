import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';

import '../../helpers/behavior_signature.dart';
import '../../helpers/simulation_harness.dart';

void main() {
  group('Behavior Signature', () {
    test('captures deterministic signature fields', () {
      final e = makeEngine(w: 24, h: 24, seed: 99);
      for (int x = 4; x < 20; x++) {
        setCell(e, x, 5, El.cloud);
        if (x % 2 == 0) setCell(e, x, 16, El.water);
      }
      final sig = captureBehaviorSignature(e);
      expect(sig.cloudCells, greaterThan(0));
      expect(sig.hydroCells, greaterThan(sig.cloudCells));
      expect(sig.maxCloudCluster, greaterThan(5));
      expect(sig.gridHash, greaterThan(0));
    });
  });
}
