import 'package:flame/components.dart';

import '../creatures/creature_registry.dart';
import '../simulation/element_behaviors.dart';
import '../simulation/element_registry.dart';
import '../simulation/reactions/reaction_registry.dart';
import '../simulation/simulation_engine.dart';
import '../simulation/world_gen/world_config.dart';
import '../simulation/world_gen/world_generator.dart';
import 'components/ant_renderer.dart';
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
/// 4. [AntRenderer]          — renders all living ants on top.
///
/// The [SimulationEngine] runs the cellular-automaton rules and exposes the
/// current grid state that [SandboxComponent] reads during [render].
/// The [CreatureRegistry] ticks all colonies and their ants each frame.
class SandboxWorld extends World with HasGameReference<ParticleEngineGame> {
  late final SimulationEngine simulation;
  late final CreatureRegistry creatures;
  late final SandboxComponent sandboxComponent;
  late final BackgroundComponent backgroundComponent;
  late final AntRenderer antRenderer;
  late final PheromoneRenderer pheromoneRenderer;
  late final ReactionEffectSystem reactionEffects;

  /// Whether simulation is paused.
  bool paused = false;

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

    // Grid dimensions flow from the game instance.
    final gridW = game.gridWidth;
    final gridH = game.gridHeight;
    final cellSize = game.cellSize;

    simulation = SimulationEngine(gridW: gridW, gridH: gridH);
    creatures = CreatureRegistry();
    ElementRegistry.init();
    ReactionRegistry.init();

    // Populate the world based on game configuration.
    if (game.loadState != null) {
      // Restore from saved state.
      game.loadState!.restoreInto(simulation);
    } else if (!game.isBlankCanvas && game.worldConfig != null) {
      // Generate procedural world from config.
      final gridData = WorldGenerator.generate(game.worldConfig!);
      gridData.loadIntoEngine(simulation);
    } else if (!game.isBlankCanvas && game.worldConfig == null) {
      // Default: generate a meadow world.
      final defaultConfig = WorldConfig.meadow(
        width: gridW,
        height: gridH,
      );
      final gridData = WorldGenerator.generate(defaultConfig);
      gridData.loadIntoEngine(simulation);
    }
    // else: blank canvas — grid stays empty.

    // Propagate cell size to particle effects system.
    ReactionParticles.cellSize = cellSize;

    antRenderer = AntRenderer(registry: creatures);
    pheromoneRenderer = PheromoneRenderer(registry: creatures);
    backgroundComponent = BackgroundComponent(
      gridWidth: gridW,
      gridHeight: gridH,
      cellSize: cellSize,
    );

    await addAll([
      backgroundComponent..priority = 0,
      sandboxComponent = SandboxComponent(
        simulation: simulation,
        cellSize: cellSize,
      )..priority = 1,
      pheromoneRenderer..priority = 2,
      antRenderer..priority = 3,
      reactionEffects = ReactionEffectSystem(simulation: simulation)
        ..priority = 4,
    ]);
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!paused) {
      _simAccumulator += dt;
      // Run at fixed ~30fps rate regardless of render framerate.
      if (_simAccumulator >= _simInterval) {
        simulation.step(elementBehavior);
        creatures.tick(simulation);
        _simAccumulator -= _simInterval;
        // Prevent spiral of death if frames are very slow.
        if (_simAccumulator > _simInterval * 3) {
          _simAccumulator = 0;
        }
      }
    }
  }

  /// Spawn a new colony at the given grid position.
  void spawnColony(int x, int y) {
    creatures.spawn(
      x, y,
      gridW: simulation.gridW,
      gridH: simulation.gridH,
    );
  }

  /// Toggle pheromone visualization.
  void togglePheromoneView() {
    pheromoneRenderer.enabled = !pheromoneRenderer.enabled;
  }
}
