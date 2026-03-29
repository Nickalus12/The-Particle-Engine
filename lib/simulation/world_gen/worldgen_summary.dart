class WorldGenStageSummary {
  const WorldGenStageSummary({
    required this.stageName,
    required this.durationMs,
    required this.writes,
    required this.overwrites,
    required this.validationFailures,
  });

  final String stageName;
  final double durationMs;
  final int writes;
  final int overwrites;
  final int validationFailures;

  Map<String, dynamic> toMap() => {
    'stage_name': stageName,
    'duration_ms': durationMs,
    'writes': writes,
    'overwrites': overwrites,
    'validation_failures': validationFailures,
  };
}

class WorldGenTopologySummary {
  const WorldGenTopologySummary({
    required this.preset,
    required this.waterCoverageRatio,
    required this.caveAirRatio,
    required this.surfaceRoughness,
    required this.hazardDensity,
    required this.atmosphereCoverageRatio,
    required this.colonyCount,
  });

  final String preset;
  final double waterCoverageRatio;
  final double caveAirRatio;
  final double surfaceRoughness;
  final double hazardDensity;
  final double atmosphereCoverageRatio;
  final int colonyCount;

  Map<String, dynamic> toMap() => {
    'preset': preset,
    'water_coverage_ratio': waterCoverageRatio,
    'cave_air_ratio': caveAirRatio,
    'surface_roughness': surfaceRoughness,
    'hazard_density': hazardDensity,
    'atmosphere_coverage_ratio': atmosphereCoverageRatio,
    'colony_count': colonyCount,
  };
}

class WorldGenValidationSummary {
  const WorldGenValidationSummary({
    required this.unsupportedFloatingLiquids,
    required this.thermalAnomalies,
    required this.invalidColonyPlacements,
    required this.atmosphereConflicts,
  });

  final int unsupportedFloatingLiquids;
  final int thermalAnomalies;
  final int invalidColonyPlacements;
  final int atmosphereConflicts;

  int get totalFailures =>
      unsupportedFloatingLiquids +
      thermalAnomalies +
      invalidColonyPlacements +
      atmosphereConflicts;

  Map<String, dynamic> toMap() => {
    'unsupported_floating_liquids': unsupportedFloatingLiquids,
    'thermal_anomalies': thermalAnomalies,
    'invalid_colony_placements': invalidColonyPlacements,
    'atmosphere_conflicts': atmosphereConflicts,
    'total_failures': totalFailures,
  };
}

class WorldGenSummary {
  const WorldGenSummary({
    required this.preset,
    required this.heightmap,
    required this.stages,
    required this.topology,
    required this.validation,
  });

  final String preset;
  final List<int> heightmap;
  final List<WorldGenStageSummary> stages;
  final WorldGenTopologySummary topology;
  final WorldGenValidationSummary validation;

  double get totalDurationMs =>
      stages.fold<double>(0.0, (total, stage) => total + stage.durationMs);

  Map<String, dynamic> toMap() => {
    'preset': preset,
    'heightmap': heightmap,
    'total_duration_ms': totalDurationMs,
    'stages': stages.map((stage) => stage.toMap()).toList(),
    'topology': topology.toMap(),
    'validation': validation.toMap(),
  };
}
