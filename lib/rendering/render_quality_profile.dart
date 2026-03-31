enum RenderQualityTier {
  desktopUltra,
  desktopBalanced,
  tabletBalanced,
  phoneBalanced,
  phoneSurvival,
}

enum PostProcessTier { none, lightweight, selective, rich }

class RenderQualityProfile {
  const RenderQualityProfile({
    required this.id,
    required this.qualityTier,
    required this.postProcessTier,
    required this.incrementalRasterization,
    required this.batchCreatureDots,
    required this.creatureTrailInterval,
    required this.giReadbackInterval,
    required this.bloomPasses,
    required this.waterEnabled,
    required this.lightweightToneMapping,
  });

  final String id;
  final RenderQualityTier qualityTier;
  final PostProcessTier postProcessTier;
  final bool incrementalRasterization;
  final bool batchCreatureDots;
  final int creatureTrailInterval;
  final int giReadbackInterval;
  final int bloomPasses;
  final bool waterEnabled;
  final bool lightweightToneMapping;

  static const RenderQualityProfile desktopUltra = RenderQualityProfile(
    id: 'desktop_ultra',
    qualityTier: RenderQualityTier.desktopUltra,
    postProcessTier: PostProcessTier.rich,
    incrementalRasterization: true,
    batchCreatureDots: false,
    creatureTrailInterval: 1,
    giReadbackInterval: 8,
    bloomPasses: 4,
    waterEnabled: true,
    lightweightToneMapping: false,
  );

  static const RenderQualityProfile desktopBalanced = RenderQualityProfile(
    id: 'desktop_balanced',
    qualityTier: RenderQualityTier.desktopBalanced,
    postProcessTier: PostProcessTier.selective,
    incrementalRasterization: true,
    batchCreatureDots: false,
    creatureTrailInterval: 2,
    giReadbackInterval: 10,
    bloomPasses: 3,
    waterEnabled: true,
    lightweightToneMapping: false,
  );

  static const RenderQualityProfile tabletBalanced = RenderQualityProfile(
    id: 'tablet_balanced',
    qualityTier: RenderQualityTier.tabletBalanced,
    postProcessTier: PostProcessTier.selective,
    incrementalRasterization: true,
    batchCreatureDots: true,
    creatureTrailInterval: 3,
    giReadbackInterval: 12,
    bloomPasses: 2,
    waterEnabled: true,
    lightweightToneMapping: true,
  );

  static const RenderQualityProfile phoneBalanced = RenderQualityProfile(
    id: 'phone_balanced',
    qualityTier: RenderQualityTier.phoneBalanced,
    postProcessTier: PostProcessTier.lightweight,
    incrementalRasterization: true,
    batchCreatureDots: true,
    creatureTrailInterval: 4,
    giReadbackInterval: 14,
    bloomPasses: 1,
    waterEnabled: true,
    lightweightToneMapping: true,
  );

  static const RenderQualityProfile phoneSurvival = RenderQualityProfile(
    id: 'phone_survival',
    qualityTier: RenderQualityTier.phoneSurvival,
    postProcessTier: PostProcessTier.none,
    incrementalRasterization: true,
    batchCreatureDots: true,
    creatureTrailInterval: 6,
    giReadbackInterval: 18,
    bloomPasses: 0,
    waterEnabled: false,
    lightweightToneMapping: true,
  );
}

class RenderStageSample {
  const RenderStageSample({
    required this.stage,
    required this.durationMs,
    required this.ran,
    this.details = const <String, Object>{},
  });

  final String stage;
  final double durationMs;
  final bool ran;
  final Map<String, Object> details;

  Map<String, Object> toJson() => <String, Object>{
    'stage': stage,
    'duration_ms': durationMs,
    'ran': ran,
    'details': details,
  };
}

class RenderDirtyRegionSummary {
  const RenderDirtyRegionSummary({
    required this.incrementalEnabled,
    required this.activeDirtyChunks,
    required this.totalChunks,
    required this.dirtyCoverageRatio,
    required this.fullRebuilds,
    required this.incrementalRebuilds,
    required this.lastRebuildReason,
    required this.cacheInvalidations,
    required this.atmosphereCacheRefreshes,
  });

  final bool incrementalEnabled;
  final int activeDirtyChunks;
  final int totalChunks;
  final double dirtyCoverageRatio;
  final int fullRebuilds;
  final int incrementalRebuilds;
  final String lastRebuildReason;
  final int cacheInvalidations;
  final int atmosphereCacheRefreshes;

  Map<String, Object> toJson() => <String, Object>{
    'incremental_enabled': incrementalEnabled,
    'active_dirty_chunks': activeDirtyChunks,
    'total_chunks': totalChunks,
    'dirty_coverage_ratio': dirtyCoverageRatio,
    'full_rebuilds': fullRebuilds,
    'incremental_rebuilds': incrementalRebuilds,
    'last_rebuild_reason': lastRebuildReason,
    'cache_invalidations': cacheInvalidations,
    'atmosphere_cache_refreshes': atmosphereCacheRefreshes,
  };
}

class RenderRuntimeSnapshot {
  const RenderRuntimeSnapshot({
    required this.qualityProfile,
    required this.qualityTier,
    required this.postProcessTier,
    required this.renderPixelPasses,
    required this.imageBuildPasses,
    required this.postProcessPasses,
    required this.skippedFrames,
    required this.wrapCopiesLastFrame,
    required this.frameBudgetSkips,
    required this.creatureBatchPasses,
    required this.creatureDirectPasses,
    required this.stageSamples,
    required this.dirtyRegionSummary,
  });

  final String qualityProfile;
  final String qualityTier;
  final String postProcessTier;
  final int renderPixelPasses;
  final int imageBuildPasses;
  final int postProcessPasses;
  final int skippedFrames;
  final int wrapCopiesLastFrame;
  final int frameBudgetSkips;
  final int creatureBatchPasses;
  final int creatureDirectPasses;
  final List<RenderStageSample> stageSamples;
  final RenderDirtyRegionSummary dirtyRegionSummary;

  Map<String, Object> toJson() => <String, Object>{
    'quality_profile': qualityProfile,
    'quality_tier': qualityTier,
    'post_process_tier': postProcessTier,
    'render_pixel_passes': renderPixelPasses,
    'image_build_passes': imageBuildPasses,
    'post_process_passes': postProcessPasses,
    'render_skipped_frames': skippedFrames,
    'wrap_copies_last_frame': wrapCopiesLastFrame,
    'frame_budget_skips': frameBudgetSkips,
    'creature_batch_passes': creatureBatchPasses,
    'creature_direct_passes': creatureDirectPasses,
    'stage_samples': stageSamples.map((sample) => sample.toJson()).toList(),
    'dirty_region_summary': dirtyRegionSummary.toJson(),
  };
}
