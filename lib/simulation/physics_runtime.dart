enum SimulationPhaseGroup {
  movementGravity,
  chemistryPhaseChange,
  electricityLightMoisture,
  structuralStress,
  entityCreatureEffects,
}

class SimulationPhaseSchedule {
  const SimulationPhaseSchedule({
    required this.key,
    required this.group,
    required this.cadence,
    this.enabled = true,
  });

  final String key;
  final SimulationPhaseGroup group;
  final int cadence;
  final bool enabled;

  bool runsOnFrame(int frameCount) {
    if (!enabled) {
      return false;
    }
    if (cadence <= 1) {
      return true;
    }
    return frameCount % cadence == 0;
  }

  Map<String, dynamic> toMap() => {
    'key': key,
    'group': group.name,
    'cadence': cadence,
    'enabled': enabled,
  };
}

class SimulationPhaseScheduler {
  SimulationPhaseScheduler({Map<String, SimulationPhaseSchedule>? schedules})
    : schedules = schedules ?? _defaultSchedules();

  final Map<String, SimulationPhaseSchedule> schedules;

  static Map<String, SimulationPhaseSchedule> _defaultSchedules() => {
    'apply_wind': const SimulationPhaseSchedule(
      key: 'apply_wind',
      group: SimulationPhaseGroup.movementGravity,
      cadence: 2,
    ),
    'update_temperature': const SimulationPhaseSchedule(
      key: 'update_temperature',
      group: SimulationPhaseGroup.chemistryPhaseChange,
      cadence: 3,
    ),
    'update_pressure': const SimulationPhaseSchedule(
      key: 'update_pressure',
      group: SimulationPhaseGroup.chemistryPhaseChange,
      cadence: 4,
    ),
    'update_ph_charge': const SimulationPhaseSchedule(
      key: 'update_ph_charge',
      group: SimulationPhaseGroup.electricityLightMoisture,
      cadence: 4,
    ),
    'update_vibration': const SimulationPhaseSchedule(
      key: 'update_vibration',
      group: SimulationPhaseGroup.structuralStress,
      cadence: 2,
    ),
    'update_stress': const SimulationPhaseSchedule(
      key: 'update_stress',
      group: SimulationPhaseGroup.structuralStress,
      cadence: 4,
    ),
    'update_support': const SimulationPhaseSchedule(
      key: 'update_support',
      group: SimulationPhaseGroup.structuralStress,
      cadence: 2,
    ),
    'update_wind_field': const SimulationPhaseSchedule(
      key: 'update_wind_field',
      group: SimulationPhaseGroup.electricityLightMoisture,
      cadence: 30,
    ),
    'grid_slice_processing': const SimulationPhaseSchedule(
      key: 'grid_slice_processing',
      group: SimulationPhaseGroup.movementGravity,
      cadence: 1,
    ),
  };

  bool shouldRun(String key, int frameCount) =>
      schedules[key]?.runsOnFrame(frameCount) ?? false;

  Map<String, dynamic> toMap() => {
    for (final entry in schedules.entries) entry.key: entry.value.toMap(),
  };
}

class SimulationPhaseSample {
  const SimulationPhaseSample({
    required this.key,
    required this.group,
    required this.ran,
    required this.durationMs,
    required this.cellsVisited,
    required this.cellsChanged,
    required this.dirtyChunksVisited,
    required this.dirtyChunksSkipped,
  });

  final String key;
  final String group;
  final bool ran;
  final double durationMs;
  final int cellsVisited;
  final int cellsChanged;
  final int dirtyChunksVisited;
  final int dirtyChunksSkipped;

  Map<String, dynamic> toMap() => {
    'key': key,
    'group': group,
    'ran': ran,
    'duration_ms': durationMs,
    'cells_visited': cellsVisited,
    'cells_changed': cellsChanged,
    'dirty_chunks_visited': dirtyChunksVisited,
    'dirty_chunks_skipped': dirtyChunksSkipped,
  };
}

class PhysicsRuntimeSnapshot {
  const PhysicsRuntimeSnapshot({
    required this.frame,
    required this.parallelUpdateEnabled,
    required this.numSlices,
    required this.activeDirtyChunksBefore,
    required this.activeDirtyChunksAfter,
    required this.dirtyChunkAmplificationRatio,
    required this.phaseSamples,
    required this.scheduler,
  });

  factory PhysicsRuntimeSnapshot.empty() => PhysicsRuntimeSnapshot(
    frame: 0,
    parallelUpdateEnabled: false,
    numSlices: 1,
    activeDirtyChunksBefore: 0,
    activeDirtyChunksAfter: 0,
    dirtyChunkAmplificationRatio: 0.0,
    phaseSamples: const [],
    scheduler: const {},
  );

  final int frame;
  final bool parallelUpdateEnabled;
  final int numSlices;
  final int activeDirtyChunksBefore;
  final int activeDirtyChunksAfter;
  final double dirtyChunkAmplificationRatio;
  final List<SimulationPhaseSample> phaseSamples;
  final Map<String, dynamic> scheduler;

  Map<String, dynamic> toMap() => {
    'frame': frame,
    'parallel_update_enabled': parallelUpdateEnabled,
    'num_slices': numSlices,
    'active_dirty_chunks_before': activeDirtyChunksBefore,
    'active_dirty_chunks_after': activeDirtyChunksAfter,
    'dirty_chunk_amplification_ratio': dirtyChunkAmplificationRatio,
    'phase_samples': phaseSamples.map((sample) => sample.toMap()).toList(),
    'scheduler': scheduler,
  };
}
