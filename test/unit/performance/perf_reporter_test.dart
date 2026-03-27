import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/perf_reporter.dart';

void main() {
  group('PerfReporter', () {
    test('writes structured jsonl payload', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'particle_engine_perf_report_test_',
      );
      addTearDown(() async {
        PerfReporter.overrideReportPathForTesting = null;
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final reportPath = '${tempDir.path}/metrics.jsonl';
      PerfReporter.overrideReportPathForTesting = reportPath;
      await PerfReporter.instance.record(
        suite: 'suite_a',
        scenario: 'scenario_a',
        metrics: <String, num>{'mean_ms': 10.5, 'p95_ms': 15},
        tags: <String, Object?>{'device': 'local'},
      );

      final file = File(reportPath);
      expect(await file.exists(), isTrue);
      final lines = await file.readAsLines();
      expect(lines, hasLength(1));

      final json = jsonDecode(lines.single) as Map<String, dynamic>;
      expect(json['suite'], 'suite_a');
      expect(json['scenario'], 'scenario_a');
      final metrics = json['metrics'] as Map<String, dynamic>;
      expect(metrics['mean_ms'], 10.5);
      expect(metrics['p95_ms'], 15);
      final tags = json['tags'] as Map<String, dynamic>;
      expect(tags['device'], 'local');
      expect(json['timestamp_utc'], isA<String>());
    });
  });
}
