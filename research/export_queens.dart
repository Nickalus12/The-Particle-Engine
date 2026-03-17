/// Seed queen exporter for the NEAT autoresearch loop.
///
/// When an experiment produces a champion genome significantly better than
/// baseline, this module exports it as a "seed queen" JSON file that can
/// be loaded into new colonies to bootstrap evolution.
///
/// Seed queens are stored in `assets/seed_queens/` and can be loaded
/// at colony creation time instead of starting from random minimal genomes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:the_particle_engine/creatures/neat/neat_genome.dart';

/// Export a champion genome as a seed queen.
///
/// Saves to `assets/seed_queens/{environment}_{seed}_{fitness}.json`
/// with full genome data and metadata.
void exportSeedQueen({
  required Map<String, dynamic> genome,
  required String environment,
  required int seed,
  required double fitness,
  required double complexity,
}) {
  final dir = Directory('assets/seed_queens');
  if (!dir.existsSync()) dir.createSync(recursive: true);

  final fitnessStr = fitness.toStringAsFixed(1).replaceAll('.', '_');
  final filename = '${environment}_s${seed}_f$fitnessStr.json';
  final file = File('${dir.path}/$filename');

  final data = {
    'metadata': {
      'environment': environment,
      'seed': seed,
      'fitness': fitness,
      'complexity': complexity,
      'exported_at': DateTime.now().toIso8601String(),
      'version': '1.0',
    },
    'genome': genome,
  };

  file.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(data),
  );
  stdout.writeln('  Exported seed queen: ${file.path}');
}

/// Load a seed queen genome from a JSON file.
///
/// Returns the deserialized [NeatGenome] ready to be inserted into a
/// population.
NeatGenome loadSeedQueen(String filepath) {
  final file = File(filepath);
  if (!file.existsSync()) {
    throw FileSystemException('Seed queen not found', filepath);
  }

  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final genomeData = json['genome'] as Map<String, dynamic>;
  return NeatGenome.fromJson(genomeData);
}

/// List all available seed queens with their metadata.
List<Map<String, dynamic>> listSeedQueens() {
  final dir = Directory('assets/seed_queens');
  if (!dir.existsSync()) return [];

  final queens = <Map<String, dynamic>>[];
  for (final file in dir.listSync().whereType<File>()) {
    if (!file.path.endsWith('.json')) continue;
    if (file.path.endsWith('.gitkeep')) continue;

    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final metadata = json['metadata'] as Map<String, dynamic>;
      queens.add({
        'file': file.path,
        ...metadata,
      });
    } catch (_) {
      // Skip malformed files.
    }
  }

  // Sort by fitness descending.
  queens.sort((a, b) =>
      ((b['fitness'] as num?) ?? 0).compareTo((a['fitness'] as num?) ?? 0));

  return queens;
}

/// Find the best seed queen for a given environment.
///
/// Returns the filepath of the highest-fitness queen for that environment,
/// or null if none exists.
String? bestQueenFor(String environment) {
  final queens = listSeedQueens();
  for (final q in queens) {
    if (q['environment'] == environment) {
      return q['file'] as String;
    }
  }
  return null;
}
