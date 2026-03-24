import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

import 'neat/neat_genome.dart';

/// Pre-trained genome library loaded from QDax-evolved behavioral archives.
///
/// Each species has 20 diverse genomes spanning different behavioral niches
/// (e.g., surface sweepers vs deep burrowers for worms). When a creature
/// spawns, [pickGenome] selects a random brain from the pool and applies
/// slight weight perturbation for individuality.
///
/// Genomes are loaded lazily on first request per species.
class GenomeLibrary {
  GenomeLibrary._();
  static final GenomeLibrary instance = GenomeLibrary._();

  final Map<String, List<NeatGenome>> _libraries = {};
  final Random _rng = Random();

  /// Available species with trained brains.
  static const List<String> availableSpecies = [
    'worm', 'ant', 'beetle', 'fish', 'bee', 'firefly',
  ];

  /// Load genomes for a species from the asset bundle.
  /// Returns the number of genomes loaded.
  Future<int> loadSpecies(String species) async {
    if (_libraries.containsKey(species)) return _libraries[species]!.length;

    try {
      final jsonStr = await rootBundle.loadString(
        'assets/genomes/${species}_brains.json',
      );
      final List<dynamic> genomeList = jsonDecode(jsonStr) as List<dynamic>;

      final genomes = <NeatGenome>[];
      for (final data in genomeList) {
        if (data is Map<String, dynamic>) {
          try {
            genomes.add(NeatGenome.fromJson(data));
          } catch (_) {
            // Skip malformed genomes
          }
        }
      }

      _libraries[species] = genomes;
      return genomes.length;
    } catch (_) {
      _libraries[species] = [];
      return 0;
    }
  }

  /// Load all available species.
  Future<void> loadAll() async {
    for (final species in availableSpecies) {
      await loadSpecies(species);
    }
  }

  /// Pick a random genome from the library for a species.
  /// Applies slight weight perturbation (±5%) for individuality.
  /// Returns null if no genomes are loaded for this species.
  NeatGenome? pickGenome(String species, {double perturbation = 0.05}) {
    final lib = _libraries[species];
    if (lib == null || lib.isEmpty) return null;

    // Pick random genome from the diverse pool
    final base = lib[_rng.nextInt(lib.length)];

    // Apply weight perturbation for individuality
    if (perturbation > 0) {
      final mutated = base.copy();
      for (final conn in mutated.connections.values) {
        conn.weight += (_rng.nextDouble() * 2 - 1) * perturbation * conn.weight.abs().clamp(0.1, 10.0);
      }
      // Perturb behavior vector by ±2% for individual visual variation
      final bv = mutated.behaviorVector;
      if (bv != null) {
        for (var i = 0; i < bv.length; i++) {
          bv[i] += (_rng.nextDouble() * 2 - 1) * 0.02;
          bv[i] = bv[i].clamp(0.0, 1.0);
        }
      }
      return mutated;
    }

    return base.copy();
  }

  /// Get the number of loaded genomes for a species.
  int genomeCount(String species) => _libraries[species]?.length ?? 0;

  /// Whether any genomes are loaded for a species.
  bool hasGenomes(String species) => genomeCount(species) > 0;
}
