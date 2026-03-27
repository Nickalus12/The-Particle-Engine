import 'dart:convert';
import 'dart:io';

/// Writes structured performance records for local comparison and ingestion.
class PerfReporter {
  PerfReporter._();

  static final PerfReporter instance = PerfReporter._();
  static String? overrideReportPathForTesting;

  String get _reportPath {
    final override = overrideReportPathForTesting;
    if (override != null && override.trim().isNotEmpty) {
      return override;
    }
    final envPath = Platform.environment['PERF_REPORT_PATH'];
    if (envPath != null && envPath.trim().isNotEmpty) {
      return envPath;
    }
    return 'build/perf/perf_metrics.jsonl';
  }

  Future<void> record({
    required String suite,
    required String scenario,
    required Map<String, num> metrics,
    Map<String, Object?> tags = const <String, Object?>{},
  }) async {
    try {
      final file = File(_reportPath);
      await file.parent.create(recursive: true);

      final payload = <String, Object?>{
        'timestamp_utc': DateTime.now().toUtc().toIso8601String(),
        'suite': suite,
        'scenario': scenario,
        'metrics': metrics,
        'tags': tags,
      };
      await file.writeAsString(
        '${jsonEncode(payload)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } on Object catch (err) {
      stderr.writeln('PerfReporter failed to write metric: $err');
    }
  }
}
