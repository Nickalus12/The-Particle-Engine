import 'dart:convert';
import 'dart:io';

import 'package:the_particle_engine/simulation/element_behaviors.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

import 'behavior_signature.dart';

class ReplayInput {
  const ReplayInput({
    required this.tick,
    required this.op,
    required this.x,
    required this.y,
    required this.element,
  });

  final int tick;
  final String op;
  final int x;
  final int y;
  final int element;

  Map<String, Object> toJson() => <String, Object>{
    'tick': tick,
    'op': op,
    'x': x,
    'y': y,
    'element': element,
  };
}

class ReplayContract {
  const ReplayContract({
    required this.scenarioId,
    required this.seed,
    required this.tickCount,
    required this.inputStream,
    required this.stateHashSeries,
    required this.behaviorSignature,
  });

  final String scenarioId;
  final int seed;
  final int tickCount;
  final List<ReplayInput> inputStream;
  final List<int> stateHashSeries;
  final BehaviorSignature behaviorSignature;

  Map<String, Object?> toJson() => <String, Object?>{
    'scenario_id': scenarioId,
    'seed': seed,
    'tick_count': tickCount,
    'input_stream': inputStream.map((ReplayInput e) => e.toJson()).toList(),
    'state_hash_series': stateHashSeries,
    'behavior_signature': behaviorSignature.toMetrics(),
  };
}

int computeEngineStateHash(SimulationEngine e) {
  int h = 0x811C9DC5;
  for (int i = 0; i < e.grid.length; i++) {
    h ^= e.grid[i];
    h = (h * 0x01000193) & 0x7fffffff;
    h ^= e.moisture[i];
    h = (h * 0x01000193) & 0x7fffffff;
    h ^= e.temperature[i];
    h = (h * 0x01000193) & 0x7fffffff;
    h ^= e.hydroMomentumV2[i];
    h = (h * 0x01000193) & 0x7fffffff;
    h ^= e.hydroTurbulenceV2[i];
    h = (h * 0x01000193) & 0x7fffffff;
  }
  h ^= e.frameCount;
  return h & 0x7fffffff;
}

ReplayContract captureReplayContract({
  required SimulationEngine engine,
  required String scenarioId,
  required int seed,
  required int ticks,
  List<ReplayInput> inputStream = const <ReplayInput>[],
  int hashEvery = 8,
}) {
  final hashes = <int>[];
  for (int t = 0; t < ticks; t++) {
    engine.step(simulateElement);
    if (t % hashEvery == 0 || t == ticks - 1) {
      hashes.add(computeEngineStateHash(engine));
    }
  }
  return ReplayContract(
    scenarioId: scenarioId,
    seed: seed,
    tickCount: ticks,
    inputStream: inputStream,
    stateHashSeries: hashes,
    behaviorSignature: captureBehaviorSignature(engine),
  );
}

Future<void> writeReplayContractJson(
  ReplayContract contract, {
  required String path,
}) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(
    jsonEncode(contract.toJson()),
    mode: FileMode.write,
    flush: true,
  );
}
