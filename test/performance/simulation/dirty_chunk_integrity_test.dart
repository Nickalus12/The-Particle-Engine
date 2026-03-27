@Tags(<String>['performance', 'performance_gate'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/element_behaviors.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/reactions/reaction_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

import '../../helpers/perf_reporter.dart';

SimulationEngine _engine({int seed = 1}) {
  ElementRegistry.init();
  ReactionRegistry.init();
  return SimulationEngine(gridW: 64, gridH: 64, seed: seed);
}

int _countDirty(List<int> chunks) {
  int c = 0;
  for (int i = 0; i < chunks.length; i++) {
    if (chunks[i] != 0) c++;
  }
  return c;
}

Future<void> _metric(String scenario, Map<String, num> metrics) {
  return PerfReporter.instance.record(
    suite: 'physics_integrity',
    scenario: scenario,
    metrics: metrics,
  );
}

void main() {
  test('dirty chunk boundary propagation marks neighboring chunks', () async {
    final e = _engine(seed: 9001);
    e.nextDirtyChunks.fillRange(0, e.nextDirtyChunks.length, 0);

    // (15,15) is exactly on chunk boundary for 16x16 chunking.
    e.markDirty(15, 15);
    final dirtyCount = _countDirty(e.nextDirtyChunks);
    expect(dirtyCount, greaterThanOrEqualTo(4));

    await _metric('dirty_chunk_boundary_propagation', <String, num>{
      'dirty_chunks_marked': dirtyCount,
      'chunk_cols': e.chunkCols,
      'chunk_rows': e.chunkRows,
    });
  });

  test('dirty chunk activity decays for static empty worlds', () async {
    final e = _engine(seed: 42);
    e.clear();
    e.markAllDirty();

    final initial = _countDirty(e.dirtyChunks);
    for (int i = 0; i < 4; i++) {
      e.step(simulateElement);
    }
    final stabilized = _countDirty(e.dirtyChunks);

    expect(initial, greaterThan(0));
    expect(stabilized, lessThan(initial));
    expect(stabilized, lessThanOrEqualTo(4));

    await _metric('dirty_chunk_decay_static_world', <String, num>{
      'initial_dirty_chunks': initial,
      'stabilized_dirty_chunks': stabilized,
    });
  });
}
