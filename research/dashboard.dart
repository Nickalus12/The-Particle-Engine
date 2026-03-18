/// Autoresearch Results Dashboard
///
/// Reads engine_results.tsv and prints a summary of experiment history,
/// improvement trajectory, and current best metrics.
///
/// Run: dart run research/dashboard.dart
library;

import 'dart:io';

void main() {
  final file = File('research/engine_results.tsv');
  if (!file.existsSync()) {
    print('No results file found. Run the benchmark first.');
    return;
  }

  final lines = file.readAsLinesSync();
  if (lines.length < 2) {
    print('No experiments recorded yet.');
    return;
  }

  // Parse header
  final header = lines[0].split('\t');
  final idIdx = header.indexOf('id');
  final descIdx = header.indexOf('description');
  final fpsIdx = header.indexOf('fps');
  final physIdx = header.indexOf('physics');
  final visIdx = header.indexOf('visuals');
  final keptIdx = header.indexOf('kept');
  final fileIdx = header.indexOf('file');
  final tsIdx = header.indexOf('timestamp');

  final experiments = <Map<String, dynamic>>[];

  for (int i = 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final parts = line.split('\t');
    if (parts.length < header.length) continue;

    experiments.add({
      'id': parts[idIdx],
      'description': descIdx >= 0 && descIdx < parts.length ? parts[descIdx] : '',
      'fps': double.tryParse(parts[fpsIdx]) ?? 0,
      'physics': double.tryParse(parts[physIdx]) ?? 0,
      'visuals': double.tryParse(parts[visIdx]) ?? 0,
      'kept': keptIdx >= 0 && keptIdx < parts.length
          ? parts[keptIdx].toLowerCase().contains('yes') || parts[keptIdx].toLowerCase().contains('true')
          : false,
      'file': fileIdx >= 0 && fileIdx < parts.length ? parts[fileIdx] : '',
      'timestamp': tsIdx >= 0 && tsIdx < parts.length ? parts[tsIdx] : '',
    });
  }

  if (experiments.isEmpty) {
    print('No experiments parsed.');
    return;
  }

  // Compute stats
  final total = experiments.length;
  final kept = experiments.where((e) => e['kept'] == true).length;
  final discarded = total - kept;
  final keepRate = total > 0 ? (kept / total * 100).toStringAsFixed(1) : '0';

  // Current best (last kept experiment, or last overall)
  final keptExps = experiments.where((e) => e['kept'] == true).toList();
  final best = keptExps.isNotEmpty ? keptExps.last : experiments.last;

  // First baseline
  final baseline = experiments.first;

  // Improvement trajectory
  double bestFps = 0, bestPhysics = 0, bestVisuals = 0;
  double worstFps = double.infinity, worstPhysics = double.infinity, worstVisuals = double.infinity;
  for (final e in experiments) {
    final fps = (e['fps'] as double);
    final phys = (e['physics'] as double);
    final vis = (e['visuals'] as double);
    if (fps > bestFps) bestFps = fps;
    if (phys > bestPhysics) bestPhysics = phys;
    if (vis > bestVisuals) bestVisuals = vis;
    if (fps < worstFps) worstFps = fps;
    if (phys < worstPhysics) worstPhysics = phys;
    if (vis < worstVisuals) worstVisuals = vis;
  }

  // Per-file change counts
  final fileCounts = <String, int>{};
  final fileKepts = <String, int>{};
  for (final e in experiments) {
    final f = e['file'] as String;
    if (f.isEmpty || f == '-') continue;
    fileCounts[f] = (fileCounts[f] ?? 0) + 1;
    if (e['kept'] == true) fileKepts[f] = (fileKepts[f] ?? 0) + 1;
  }

  // Print dashboard
  print('');
  print('╔══════════════════════════════════════════════════════════════╗');
  print('║          THE PARTICLE ENGINE — AUTORESEARCH DASHBOARD       ║');
  print('╚══════════════════════════════════════════════════════════════╝');
  print('');
  print('  Total experiments:  $total');
  print('  Kept:               $kept ($keepRate%)');
  print('  Discarded:          $discarded');
  print('');
  print('  ┌─────────────┬──────────┬──────────┬──────────┐');
  print('  │  Metric     │ Baseline │ Current  │ Best     │');
  print('  ├─────────────┼──────────┼──────────┼──────────┤');
  print('  │  FPS        │ ${_pad(baseline['fps'])} │ ${_pad(best['fps'])} │ ${_pad(bestFps)} │');
  print('  │  Physics    │ ${_pad(baseline['physics'])} │ ${_pad(best['physics'])} │ ${_pad(bestPhysics)} │');
  print('  │  Visuals    │ ${_pad(baseline['visuals'])} │ ${_pad(best['visuals'])} │ ${_pad(bestVisuals)} │');
  print('  └─────────────┴──────────┴──────────┴──────────┘');
  print('');

  // Improvement deltas
  final fpsDelta = (best['fps'] as double) - (baseline['fps'] as double);
  final physDelta = (best['physics'] as double) - (baseline['physics'] as double);
  final visDelta = (best['visuals'] as double) - (baseline['visuals'] as double);
  print('  Improvement from baseline:');
  print('    FPS:     ${fpsDelta >= 0 ? '+' : ''}${fpsDelta.toStringAsFixed(1)}');
  print('    Physics: ${physDelta >= 0 ? '+' : ''}${physDelta.toStringAsFixed(0)}');
  print('    Visuals: ${visDelta >= 0 ? '+' : ''}${visDelta.toStringAsFixed(0)}');
  print('');

  // File breakdown
  if (fileCounts.isNotEmpty) {
    print('  Changes by file:');
    final sorted = fileCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final entry in sorted) {
      final keptCount = fileKepts[entry.key] ?? 0;
      final shortName = entry.key.split('/').last;
      print('    $shortName: ${entry.value} experiments ($keptCount kept)');
    }
    print('');
  }

  // Recent experiments (last 10)
  print('  Recent experiments:');
  final recent = experiments.length > 10
      ? experiments.sublist(experiments.length - 10)
      : experiments;
  for (final e in recent) {
    final status = e['kept'] == true ? '✓' : '✗';
    final desc = (e['description'] as String).length > 45
        ? '${(e['description'] as String).substring(0, 45)}...'
        : e['description'];
    print('    $status #${e['id']}  fps=${_pad(e['fps'])} phys=${_pad(e['physics'])} vis=${_pad(e['visuals'])}  $desc');
  }
  print('');
}

String _pad(dynamic val) {
  if (val is double) {
    return val.toStringAsFixed(1).padLeft(6);
  }
  return val.toString().padLeft(6);
}
