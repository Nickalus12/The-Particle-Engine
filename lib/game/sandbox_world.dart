import 'dart:async';

import 'package:flame/components.dart';
import 'package:flutter/foundation.dart';

import '../creatures/ant.dart';
import '../creatures/creature_registry.dart';
import '../models/game_state.dart';
import '../rendering/gi_post_process.dart';
import '../rendering/render_quality_profile.dart';
import '../services/save_service.dart';
import '../simulation/element_behaviors.dart';
import '../simulation/element_registry.dart';
import '../simulation/plant_colony.dart';
import '../simulation/reactions/reaction_registry.dart';
import '../simulation/simulation_engine.dart';
import '../simulation/world_gen/world_config.dart';
import '../utils/math_helpers.dart';
import '../simulation/world_gen/world_generator.dart';
import 'components/creature_renderer.dart';
import 'components/background_component.dart';
import 'components/effects/reaction_effect_system.dart';
import 'components/effects/reaction_particles.dart';
import 'components/pheromone_renderer.dart';
import 'components/sandbox_component.dart';
import 'particle_engine_game.dart';

/// The Flame [World] that owns the simulation and all renderable components.
///
/// On load it creates:
/// 1. [BackgroundComponent]  — dynamic sky gradient behind the grid.
/// 2. [SandboxComponent]     — renders the live pixel grid every frame.
/// 3. [PheromoneRenderer]    — optional pheromone trail overlay.
/// 4. [CreatureRenderer]     — renders all living creatures on top.
///
/// The [SimulationEngine] runs the cellular-automaton rules and exposes the
/// current grid state that [SandboxComponent] reads during [render].
/// The [CreatureRegistry] ticks all colonies and their ants each frame.
class SandboxWorld extends World with HasGameReference<ParticleEngineGame> {
  late final SimulationEngine simulation;
  late final CreatureRegistry creatures;
  late final PlantColonyRegistry plantColonies;
  late final SandboxComponent sandboxComponent;
  late final BackgroundComponent backgroundComponent;
  late final CreatureRenderer creatureRenderer;
  late final PheromoneRenderer pheromoneRenderer;
  late final ReactionEffectSystem reactionEffects;
  late final GIPostProcess giPostProcess;
  final SaveService _saveService = SaveService();
  bool _autoSaveInFlight = false;

  /// Whether simulation is paused.
  bool paused = false;

  /// Frame timing instrumentation (microseconds, rolling averages).
  /// Enable with [showFrameTiming] for performance profiling.
  bool showFrameTiming = false;
  int _timingChemistry = 0;
  int _timingElectricity = 0;
  int _timingLight = 0;
  int _timingLuminance = 0;
  int _timingStep = 0;
  int _timingCreatures = 0;
  int _timingTotal = 0;
  int _timingSampleCount = 0;
  final Stopwatch _perfWatch = Stopwatch();

  /// Get the latest frame timing report as a formatted string.
  String get frameTimingReport {
    if (_timingSampleCount == 0) return 'No timing data';
    final n = _timingSampleCount;
    return 'Frame budget (avg over $n frames):\n'
        '  Chemistry:   ${(_timingChemistry / n / 1000).toStringAsFixed(1)}ms\n'
        '  Electricity: ${(_timingElectricity / n / 1000).toStringAsFixed(1)}ms\n'
        '  LightEmit:   ${(_timingLight / n / 1000).toStringAsFixed(1)}ms\n'
        '  Luminance:   ${(_timingLuminance / n / 1000).toStringAsFixed(1)}ms\n'
        '  Step:        ${(_timingStep / n / 1000).toStringAsFixed(1)}ms\n'
        '  Creatures:   ${(_timingCreatures / n / 1000).toStringAsFixed(1)}ms\n'
        '  TOTAL:       ${(_timingTotal / n / 1000).toStringAsFixed(1)}ms\n'
        '  Budget:      33.3ms (30fps)';
  }

  /// Reset accumulated timing data.
  void resetFrameTiming() {
    _timingChemistry = 0;
    _timingElectricity = 0;
    _timingLight = 0;
    _timingLuminance = 0;
    _timingStep = 0;
    _timingCreatures = 0;
    _timingTotal = 0;
    _timingSampleCount = 0;
  }

  /// Element behavior callback.
  void Function(SimulationEngine, int, int, int, int) elementBehavior =
      simulateElement;

  /// Accumulated time for fixed-rate simulation stepping.
  double _simAccumulator = 0.0;

  /// Target simulation rate: ~30 steps per second.
  static const double _simInterval = 1.0 / 30.0;

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    final loadStopwatch = Stopwatch()..start();

    // Grid dimensions flow from the game instance.
    final gridW = game.gridWidth;
    final gridH = game.gridHeight;
    final cellSize = game.cellSize;

    simulation = SimulationEngine(gridW: gridW, gridH: gridH);
    MathHelpers.init(simulation.rng);
    creatures = CreatureRegistry();
    plantColonies = PlantColonyRegistry();
    ElementRegistry.init();
    ReactionRegistry.init();

    // Wire creature callback so cell-based ants can query NEAT brains.
    simulation.creatureCallback = (int x, int y) {
      return creatures.queryAntDecision(simulation, x, y) ?? {};
    };

    // Wire plant colony registry for neural plant growth.
    plantColonies.ensureSize(gridW * gridH);
    simulation.plantColonies = plantColonies;

    // Populate the world based on game configuration.
    if (game.loadState != null) {
      // Restore from saved state.
      game.loadState!.restoreInto(simulation);
      creatures.restoreFromSnapshots(
        game.loadState!.colonies,
        gridW: simulation.gridW,
        gridH: simulation.gridH,
      );
    } else if (!game.isBlankCanvas && game.worldConfig != null) {
      // Generate procedural world from config.
      final runtimeConfig = game.worldConfig!.copyWith(
        width: gridW,
        height: gridH,
      );
      final gridData = WorldGenerator.generate(runtimeConfig);
      gridData.loadIntoEngine(simulation);
    } else if (!game.isBlankCanvas && game.worldConfig == null) {
      // Default: generate a meadow world.
      final defaultConfig = WorldConfig.meadow(width: gridW, height: gridH);
      final gridData = WorldGenerator.generate(defaultConfig);
      gridData.loadIntoEngine(simulation);
    }
    // else: blank canvas — grid stays empty.

    game.isNight = simulation.isNight;
    game.dayNightTransition = simulation.isNight ? 1.0 : 0.0;

    // Propagate cell size to particle effects system.
    ReactionParticles.cellSize = cellSize;

    creatureRenderer = CreatureRenderer(
      registry: creatures,
      simulation: simulation,
      cellSize: cellSize,
    );
    pheromoneRenderer = PheromoneRenderer(registry: creatures);
    backgroundComponent = BackgroundComponent(
      gridWidth: gridW,
      gridHeight: gridH,
      cellSize: cellSize,
    );

    giPostProcess = GIPostProcess(
      simulation: simulation,
      enabled:
          game.renderQualityProfile.postProcessTier != PostProcessTier.none,
    )..configureForProfile(game.renderQualityProfile);

    await addAll([
      backgroundComponent..priority = 0,
      sandboxComponent = SandboxComponent(
        simulation: simulation,
        cellSize: cellSize,
      )..priority = 1,
      pheromoneRenderer..priority = 2,
      creatureRenderer..priority = 3,
      reactionEffects = ReactionEffectSystem(simulation: simulation)
        ..priority = 4,
      giPostProcess..priority = 5,
    ]);

    loadStopwatch.stop();
    assert(() {
      debugPrint(
        'SandboxWorld loaded ${simulation.gridW}x${simulation.gridH}'
        ' in ${loadStopwatch.elapsedMilliseconds}ms'
        ' loadState=${game.loadState != null}'
        ' generated=${!game.isBlankCanvas}',
      );
      return true;
    }());
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!paused) {
      _simAccumulator += dt;
      final mobileCreationMode = !game.isDesktop && game.isCreationMode;
      final mobileDevice = !game.isDesktop;
      final chemistryInterval = mobileCreationMode ? 5 : (mobileDevice ? 4 : 3);
      final electricityInterval = mobileCreationMode
          ? 8
          : (mobileDevice ? 6 : 4);
      final lightInterval = mobileCreationMode ? 8 : (mobileDevice ? 6 : 4);
      final luminanceInterval = mobileCreationMode
          ? 12
          : (mobileDevice ? 10 : 8);
      final moistureInterval = mobileCreationMode
          ? 12
          : (mobileDevice ? 10 : 8);
      final maxSimStepsPerFrame = mobileCreationMode
          ? 1
          : (mobileDevice ? 2 : 3);
      // Run at fixed ~30fps rate regardless of render framerate.
      // Process multiple simulation steps when needed so physics speed stays
      // consistent even on slower devices.
      var simSteps = 0;
      while (_simAccumulator >= _simInterval &&
          simSteps < maxSimStepsPerFrame) {
        final timing = showFrameTiming;
        if (timing) _perfWatch.start();

        // Chemistry + age pass cadence is adaptive on mobile creation mode.
        if (simulation.frameCount % chemistryInterval == 0) {
          if (timing) _perfWatch.reset();
          simulation.runChemistryPass();
          simulation.updateCellAge();
          if (timing) _timingChemistry += _perfWatch.elapsedMicroseconds;
        }
        // Electricity pass cadence is adaptive on mobile creation mode.
        if (simulation.frameCount % electricityInterval == 0) {
          if (timing) _perfWatch.reset();
          simulation.runElectricityPass();
          if (timing) _timingElectricity += _perfWatch.elapsedMicroseconds;
        }
        // Light emission cadence is adaptive on mobile creation mode.
        if (simulation.frameCount % lightInterval == 0) {
          if (timing) _perfWatch.reset();
          simulation.updateLightEmission();
          if (timing) _timingLight += _perfWatch.elapsedMicroseconds;
        }
        // Luminance cadence is adaptive on mobile creation mode.
        if (simulation.frameCount % luminanceInterval == 0) {
          if (timing) _perfWatch.reset();
          simulation.updateLuminance();
          if (timing) _timingLuminance += _perfWatch.elapsedMicroseconds;
        }
        // Moisture wicking: capillary action through porous materials
        if (simulation.frameCount % moistureInterval == 0) {
          simulation.updateMoisture();
        }

        if (timing) _perfWatch.reset();
        simulation.step(elementBehavior);
        if (timing) _timingStep += _perfWatch.elapsedMicroseconds;

        if (timing) _perfWatch.reset();
        creatures.tick(simulation);
        if (timing) _timingCreatures += _perfWatch.elapsedMicroseconds;

        // Plant colony neural evolution tick
        if (simulation.frameCount % 2 == 0) {
          plantColonies.tick();
        }
        // Pheromone system for ant AI (extension methods on SimulationEngine)
        if (simulation.colonyX >= 0) {
          if (simulation.frameCount % 8 == 0) simulation.evaporatePheromones();
          if (simulation.frameCount % 4 == 0) simulation.diffusePheromones();
          if (simulation.frameCount % 16 == 0) {
            simulation.updateColonyCentroid();
          }
        }

        if (timing) {
          _perfWatch.stop();
          _timingTotal += _perfWatch.elapsedMicroseconds;
          _perfWatch.reset();
          _timingSampleCount++;
        }

        _simAccumulator -= _simInterval;
        simSteps++;
      }
      // Prevent spiral of death if frames are very slow.
      if (_simAccumulator > _simInterval * maxSimStepsPerFrame) {
        _simAccumulator = _simInterval * maxSimStepsPerFrame;
      }
    }

    if (!_autoSaveInFlight) {
      _autoSaveInFlight = true;
      unawaited(
        _saveService
            .tickAutoSave(
              dtSeconds: dt,
              paused: paused,
              stateProvider: captureGameState,
            )
            .whenComplete(() {
              _autoSaveInFlight = false;
            }),
      );
    }
  }

  /// Spawn a new colony at the given grid position.
  void spawnColony(
    int x,
    int y, {
    CreatureSpecies species = CreatureSpecies.ant,
  }) {
    creatures.spawn(
      x,
      y,
      species: species,
      gridW: simulation.gridW,
      gridH: simulation.gridH,
      rng: simulation.rng,
    );
  }

  /// Toggle pheromone visualization.
  void togglePheromoneView() {
    pheromoneRenderer.enabled = !pheromoneRenderer.enabled;
  }

  GameState captureGameState() =>
      GameState.capture(simulation, creatures.colonies);

  void clearWorld() {
    simulation.clear();
    simulation.frameCount = 0;
    simulation.gravityDir = 1;
    simulation.windForce = 0;
    simulation.isNight = false;
    creatures.clear();
    plantColonies.clear();
    game.isNight = false;
    game.dayNightTransition = 0.0;
  }

  Future<void> saveCurrentWorld({required int slot, String? name}) async {
    await _saveService.save(captureGameState(), slot: slot, name: name);
    _saveService.resetAutoSaveTimer();
  }

  bool get autoSaveEnabled => _saveService.autoSaveEnabled;

  double get autoSaveProgress => _saveService.autoSaveProgress;

  CreatureRuntimeSnapshot captureCreatureRuntimeSnapshot() =>
      creatures.runtimeSnapshot();

  PlacementMetricsSnapshot capturePlacementMetricsSnapshot() =>
      sandboxComponent.capturePlacementMetrics();

  RenderRuntimeSnapshot captureRenderMetricsSnapshot() =>
      sandboxComponent.captureRenderMetrics();
}
