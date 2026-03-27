import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/simulation_engine.dart';

class VisualArtifact {
  const VisualArtifact({
    required this.runId,
    required this.scenario,
    required this.frame,
    required this.imagePath,
    required this.diffPath,
    required this.ssim,
    required this.psnr,
    required this.diffRatio,
    required this.passed,
  });

  final String runId;
  final String scenario;
  final int frame;
  final String imagePath;
  final String diffPath;
  final double ssim;
  final double psnr;
  final double diffRatio;
  final bool passed;

  Map<String, Object?> toJson() => <String, Object?>{
    'run_id': runId,
    'scenario': scenario,
    'frame': frame,
    'image_path': imagePath,
    'diff_path': diffPath,
    'ssim': ssim,
    'psnr': psnr,
    'diff_ratio': diffRatio,
    'pass': passed,
  };
}

class VisualReporter {
  VisualReporter._();
  static final VisualReporter instance = VisualReporter._();

  String get _reportPath {
    final env = Platform.environment['PERF_VISUAL_REPORT_PATH'];
    if (env != null && env.trim().isNotEmpty) {
      return env;
    }
    return 'build/perf/visual_artifacts.jsonl';
  }

  Future<void> record(VisualArtifact artifact) async {
    final file = File(_reportPath);
    await file.parent.create(recursive: true);
    final payload = <String, Object?>{
      ...artifact.toJson(),
      'timestamp_utc': DateTime.now().toUtc().toIso8601String(),
    };
    await file.writeAsString(
      '${jsonEncode(payload)}\n',
      mode: FileMode.append,
      flush: true,
    );
  }
}

List<int> renderGridRgb(SimulationEngine e) {
  final out = List<int>.filled(e.grid.length * 3, 0, growable: false);
  for (int i = 0; i < e.grid.length; i++) {
    final el = e.grid[i];
    int r = 0, g = 0, b = 0;
    switch (el) {
      case El.water:
        r = 40;
        g = 100;
        b = 220;
      case El.cloud:
        r = 220;
        g = 230;
        b = 240;
      case El.vapor:
      case El.steam:
        r = 180;
        g = 190;
        b = 210;
      case El.lava:
        r = 240;
        g = 90;
        b = 30;
      case El.stone:
        r = 80;
        g = 80;
        b = 90;
      case El.dirt:
        r = 110;
        g = 80;
        b = 52;
      default:
        final t = e.temperature[i];
        r = (t ~/ 3).clamp(0, 255);
        g = (t ~/ 3).clamp(0, 255);
        b = (t ~/ 2).clamp(0, 255);
    }
    final o = i * 3;
    out[o] = r;
    out[o + 1] = g;
    out[o + 2] = b;
  }
  return out;
}

Future<void> writePpm({
  required String path,
  required int width,
  required int height,
  required List<int> rgb,
}) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final header = 'P3\n$width $height\n255\n';
  final body = StringBuffer();
  for (int i = 0; i < rgb.length; i += 3) {
    body.writeln('${rgb[i]} ${rgb[i + 1]} ${rgb[i + 2]}');
  }
  await file.writeAsString('$header$body', flush: true);
}

Future<void> writeDiffPpm({
  required String path,
  required int width,
  required int height,
  required List<int> a,
  required List<int> b,
}) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final header = 'P3\n$width $height\n255\n';
  final body = StringBuffer();
  for (int i = 0; i < a.length; i += 3) {
    final dr = (a[i] - b[i]).abs();
    final dg = (a[i + 1] - b[i + 1]).abs();
    final db = (a[i + 2] - b[i + 2]).abs();
    body.writeln('$dr $dg $db');
  }
  await file.writeAsString('$header$body', flush: true);
}

({double ssim, double psnr, double diffRatio}) compareRgb(
  List<int> a,
  List<int> b,
) {
  if (a.length != b.length || a.isEmpty) {
    return (ssim: 0.0, psnr: 0.0, diffRatio: 1.0);
  }
  double mse = 0.0;
  int changed = 0;
  for (int i = 0; i < a.length; i++) {
    final d = a[i] - b[i];
    if (d != 0) changed++;
    mse += d * d;
  }
  mse /= a.length;
  final psnr = mse <= 0.0 ? 99.0 : 10.0 * (log(255.0 * 255.0 / mse) / ln10);
  final diffRatio = changed / a.length;
  // Lightweight SSIM proxy from normalized RMSE.
  final rmse = sqrt(mse) / 255.0;
  final ssim = (1.0 - rmse).clamp(0.0, 1.0);
  return (ssim: ssim, psnr: psnr, diffRatio: diffRatio);
}
