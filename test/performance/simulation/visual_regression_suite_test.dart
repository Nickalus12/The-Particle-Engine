@Tags(<String>['performance', 'performance_gate'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:the_particle_engine/simulation/element_behaviors.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/reactions/reaction_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

import '../../helpers/perf_reporter.dart';
import '../../helpers/scenario_dsl.dart';
import '../../helpers/visual_regression.dart';

SimulationEngine _engine(int seed) {
  ElementRegistry.init();
  ReactionRegistry.init();
  return SimulationEngine(gridW: 96, gridH: 64, seed: seed);
}

void _step(SimulationEngine e, int ticks) {
  for (int i = 0; i < ticks; i++) {
    e.step(simulateElement);
  }
}

Future<void> _metric(String scenario, Map<String, num> metrics) {
  return PerfReporter.instance.record(
    suite: 'visual_regression',
    scenario: scenario,
    metrics: metrics,
  );
}

void main() {
  test(
    'visual regression metrics remain within threshold for fixed scenario',
    () async {
      final runId = DateTime.now().toUtc().toIso8601String().replaceAll(
        ':',
        '',
      );
      final baseDir = Directory('build/perf/visual')
        ..createSync(recursive: true);
      final baselinePath = '${baseDir.path}/cloud_chamber_baseline.ppm';
      final currentPath = '${baseDir.path}/cloud_chamber_current.ppm';
      final diffPath = '${baseDir.path}/cloud_chamber_diff.ppm';

      final base = _engine(1401);
      ScenarioLibrary.cloudChamber().apply(base);
      _step(base, 180);
      final baseRgb = renderGridRgb(base);

      final cur = _engine(1401);
      ScenarioLibrary.cloudChamber().apply(cur);
      _step(cur, 180);
      final curRgb = renderGridRgb(cur);

      await writePpm(
        path: baselinePath,
        width: base.gridW,
        height: base.gridH,
        rgb: baseRgb,
      );
      await writePpm(
        path: currentPath,
        width: cur.gridW,
        height: cur.gridH,
        rgb: curRgb,
      );
      await writeDiffPpm(
        path: diffPath,
        width: cur.gridW,
        height: cur.gridH,
        a: baseRgb,
        b: curRgb,
      );

      final cmp = compareRgb(baseRgb, curRgb);
      final pass =
          cmp.ssim >= 0.98 && cmp.psnr >= 35.0 && cmp.diffRatio <= 0.02;

      await VisualReporter.instance.record(
        VisualArtifact(
          runId: runId,
          scenario: 'cloud_chamber_visual',
          frame: cur.frameCount,
          imagePath: currentPath,
          diffPath: diffPath,
          ssim: cmp.ssim,
          psnr: cmp.psnr,
          diffRatio: cmp.diffRatio,
          passed: pass,
        ),
      );
      await _metric('visual_regression_cloud_chamber', <String, num>{
        'ssim': cmp.ssim,
        'psnr': cmp.psnr,
        'diff_ratio': cmp.diffRatio,
        'pass': pass ? 1 : 0,
      });

      expect(pass, isTrue);
    },
  );
}
