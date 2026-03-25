import 'package:flame/game.dart';
import 'package:flutter/material.dart';

import '../../game/particle_engine_game.dart';
import '../../models/game_state.dart';
import '../../simulation/world_gen/world_config.dart';
import '../theme/colors.dart';
import '../widgets/element_bottom_bar.dart';

/// Hosts the [GameWidget] with the element bar integrated into the layout.
///
/// The bottom bar sits BELOW the game viewport in a Column, so it never
/// covers the simulation grid. Other HUD elements (toolbar, minimap, colony
/// inspector, observation hint, back button) remain as Flame overlays.
///
/// Two modes:
/// - **Observation mode**: near-zero UI (observation hint + back button).
/// - **Creation mode**: full toolkit (bottom bar + toolbar + minimap).
///
/// The bottom bar visibility is driven by [ParticleEngineGame.showBottomBar].
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
        child: Column(
          children: [
            // Game viewport fills available space above the bottom bar.
            Expanded(
              child: GameWidget<ParticleEngineGame>(
                game: _game,
                overlayBuilderMap: ParticleEngineGame.overlayBuilders,
                initialActiveOverlays: const [
                  ParticleEngineGame.overlayObservationHint,
                  ParticleEngineGame.overlayBackButton,
                ],
              ),
            ),
            // Bottom bar slides in/out below the game, never overlapping.
            ValueListenableBuilder<bool>(
              valueListenable: _game.showBottomBar,
              builder: (context, visible, _) {
                return AnimatedSlide(
                  offset: visible ? Offset.zero : const Offset(0, 1),
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  child: visible
                      ? ElementBottomBar(
                          game: _game,
                          onInteraction: _game.notifyHudInteraction,
                        )
                      : const SizedBox.shrink(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
