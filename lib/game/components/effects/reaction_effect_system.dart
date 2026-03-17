import 'package:flame/components.dart';

import '../../../simulation/simulation_engine.dart';
import '../../particle_engine_game.dart';
import 'reaction_particles.dart';
import 'screen_effects.dart';

/// Consumes [SimulationEngine.reactionFlashes] and
/// [SimulationEngine.recentExplosions] each frame, spawning the corresponding
/// Flame [ParticleSystemComponent] effects into the game world.
///
/// This component is added to [SandboxWorld] so it participates in the normal
/// Flame update loop. It reads the queues, spawns effects, and clears them.
class ReactionEffectSystem extends Component
    with HasGameReference<ParticleEngineGame> {
  ReactionEffectSystem({required this.simulation});

  final SimulationEngine simulation;

  /// Throttle: max effects spawned per frame to avoid particle storms.
  static const int _maxFlashesPerFrame = 8;
  static const int _maxExplosionsPerFrame = 3;

  @override
  void update(double dt) {
    super.update(dt);
    _processFlashes();
    _processExplosions();
  }

  void _processFlashes() {
    final flashes = simulation.reactionFlashes;
    if (flashes.isEmpty) return;

    final count = flashes.length.clamp(0, _maxFlashesPerFrame);
    for (var i = 0; i < count; i++) {
      final data = flashes[i];
      // data format: [x, y, r, g, b, count]
      final effect = ReactionParticles.fromFlashData(
        data[0],
        data[1],
        data[2],
        data[3],
        data[4],
        data[5],
      );
      parent?.add(effect);
    }
    flashes.clear();
  }

  void _processExplosions() {
    final explosions = simulation.recentExplosions;
    if (explosions.isEmpty) return;

    final count = explosions.length.clamp(0, _maxExplosionsPerFrame);
    for (var i = 0; i < count; i++) {
      final exp = explosions[i];

      // Spawn radial particle burst.
      final burst = ReactionParticles.explosionBurst(exp.x, exp.y, exp.radius);
      parent?.add(burst);

      // Screen shake scaled to explosion radius.
      ScreenShake.apply(
        game.camera.viewfinder,
        intensity: (exp.radius * 0.5).clamp(1.0, 8.0),
        duration: 0.2 + exp.radius * 0.02,
      );

      // Camera bump away from blast center.
      final cellSize = ReactionParticles.cellSize;
      ExplosionBump.apply(
        game.camera.viewfinder,
        blastX: exp.x * cellSize + cellSize / 2,
        blastY: exp.y * cellSize + cellSize / 2,
        strength: (exp.radius * 0.3).clamp(2.0, 6.0),
      );

      // Lightning flash for large explosions.
      if (exp.radius >= 6) {
        game.camera.viewport.add(
          LightningFlash(
            screenSize: Vector2(game.cameraWidth, game.cameraHeight),
          ),
        );
      }
    }
    // Note: explosions are cleared by the simulation engine at the start
    // of the next step(), so we don't clear them here.
  }
}
