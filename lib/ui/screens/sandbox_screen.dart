import 'package:flame/game.dart';
import 'package:flutter/material.dart';

import '../../game/particle_engine_game.dart';
import '../../models/game_state.dart';
import '../../simulation/world_gen/world_config.dart';
import '../theme/colors.dart';

/// Hosts the [GameWidget] with Flame's overlay system for the two-state HUD.
///
/// All HUD elements (element palette, toolbar, minimap, colony inspector,
/// observation hint, back button) are registered as Flame overlays via
/// [ParticleEngineGame.overlayBuilders] and managed through
/// [game.overlays.add/remove].
///
/// Two modes:
/// - **Observation mode**: near-zero UI (observation hint + back button).
/// - **Creation mode**: full toolkit (palette + toolbar + minimap).
///
/// Mode transitions are driven by [ParticleEngineGame.enterCreationMode] and
/// [ParticleEngineGame.exitCreationMode], keeping all overlay management
/// within Flame's overlay system.
///
/// Accepts optional parameters for world creation or loading:
/// - [worldConfig] + [isBlankCanvas] — create a new world (procedural or blank)
/// - [loadState] — restore a previously saved world
/// - Neither — starts with a default blank world
class SandboxScreen extends StatefulWidget {
  const SandboxScreen({
    super.key,
    this.worldConfig,
    this.worldName,
    this.isBlankCanvas = false,
    this.loadState,
  });

  /// Configuration for procedural world generation (null = blank/default).
  final WorldConfig? worldConfig;

  /// User-provided world name (for save metadata).
  final String? worldName;

  /// Whether to generate a blank canvas instead of procedural terrain.
  final bool isBlankCanvas;

  /// Previously saved state to restore (takes precedence over worldConfig).
  final GameState? loadState;

  @override
  State<SandboxScreen> createState() => _SandboxScreenState();
}

class _SandboxScreenState extends State<SandboxScreen> {
  late final ParticleEngineGame _game;

  @override
  void initState() {
    super.initState();
    _game = ParticleEngineGame(
      worldConfig: widget.loadState == null ? widget.worldConfig : null,
      isBlankCanvas: widget.isBlankCanvas,
      loadState: widget.loadState,
      worldName: widget.worldName,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Listener(
        onPointerDown: _game.onPointerDown,
        onPointerMove: _game.onPointerMove,
        onPointerUp: _game.onPointerUp,
        child: GameWidget<ParticleEngineGame>(
          game: _game,
          overlayBuilderMap: ParticleEngineGame.overlayBuilders,
          // Start in observation mode: show hint and back button.
          initialActiveOverlays: const [
            ParticleEngineGame.overlayObservationHint,
            ParticleEngineGame.overlayBackButton,
          ],
        ),
      ),
    );
  }
}
