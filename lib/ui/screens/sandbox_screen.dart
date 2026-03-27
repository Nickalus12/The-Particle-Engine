import 'package:flame/game.dart';
import 'package:flutter/material.dart';

import '../../game/particle_engine_game.dart';
import '../../game/runtime/sandbox_runtime_profile.dart';
import '../../models/game_state.dart';
import '../../simulation/world_gen/world_config.dart';
import '../theme/colors.dart';
import '../widgets/element_bottom_bar.dart';
import '../widgets/tool_bar.dart';

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
  final GlobalKey _gameViewportKey = GlobalKey();
  final GlobalKey _bottomBarKey = GlobalKey();
  final GlobalKey _toolBarKey = GlobalKey();
  ParticleEngineGame? _game;
  int _activeTouchPointers = 0;
  bool _mobilePaintGestureActive = false;
  Offset? _lastPaintGlobalPosition;
  int _lastPaintMicros = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _game ??= _buildGame(MediaQuery.sizeOf(context));
  }

  ParticleEngineGame _buildGame(Size viewportSize) {
    final profile = SandboxRuntimeProfile.resolve(
      viewportSize: viewportSize,
      loadState: widget.loadState,
    );
    final config = widget.loadState == null && widget.worldConfig != null
        ? widget.worldConfig!.copyWith(
            width: profile.gridWidth,
            height: profile.gridHeight,
          )
        : null;
    final game = ParticleEngineGame(
      worldConfig: config,
      isBlankCanvas: widget.isBlankCanvas,
      loadState: widget.loadState,
      worldName: widget.worldName,
      viewportGlobalToLocal: _toViewportLocal,
      gridWidth: profile.gridWidth,
      gridHeight: profile.gridHeight,
      cellSize: profile.cellSize,
    );
    assert(() {
      debugPrint(
        'Sandbox runtime profile: ${profile.gridWidth}x${profile.gridHeight}'
        ' @ ${profile.cellSize.toStringAsFixed(1)}px'
        ' loadState=${widget.loadState != null}'
        ' blank=${widget.isBlankCanvas}',
      );
      return true;
    }());
    return game;
  }

  Offset _toViewportLocal(Offset globalPosition) {
    final context = _gameViewportKey.currentContext;
    final renderObject = context?.findRenderObject();
    if (renderObject is RenderBox) {
      return renderObject.globalToLocal(globalPosition);
    }
    return globalPosition;
  }

  void _beginMobilePaint(Offset globalPosition) {
    final game = _game;
    if (game == null || game.isDesktop || !game.isCreationMode) return;
    final sandbox = game.sandboxWorld.sandboxComponent;
    sandbox.lastPaintX = null;
    sandbox.lastPaintY = null;
    sandbox.colonySpawnedThisGesture = false;
    final local = _toViewportLocal(globalPosition);
    sandbox.paintAtScreen(Vector2(local.dx, local.dy));
  }

  void _updateMobilePaint(Offset globalPosition) {
    final game = _game;
    if (game == null || game.isDesktop || !game.isCreationMode) return;
    final local = _toViewportLocal(globalPosition);
    game.sandboxWorld.sandboxComponent.paintAtScreen(
      Vector2(local.dx, local.dy),
    );
  }

  void _endMobilePaint() {
    final game = _game;
    if (game == null || game.isDesktop) return;
    final sandbox = game.sandboxWorld.sandboxComponent;
    sandbox.lastPaintX = null;
    sandbox.lastPaintY = null;
    sandbox.colonySpawnedThisGesture = false;
    _mobilePaintGestureActive = false;
    _lastPaintGlobalPosition = null;
    _lastPaintMicros = 0;
  }

  bool _isInsideWidgetRect(GlobalKey key, Offset globalPosition) {
    final context = key.currentContext;
    final renderObject = context?.findRenderObject();
    if (renderObject is! RenderBox) {
      return false;
    }
    final topLeft = renderObject.localToGlobal(Offset.zero);
    final rect = topLeft & renderObject.size;
    return rect.contains(globalPosition);
  }

  bool _isHudInteractionPoint(Offset globalPosition) {
    return _isInsideWidgetRect(_bottomBarKey, globalPosition) ||
        _isInsideWidgetRect(_toolBarKey, globalPosition);
  }

  void _onMobilePointerDown(PointerDownEvent event) {
    final game = _game;
    if (game == null || game.isDesktop || !game.isCreationMode) return;
    _activeTouchPointers++;
    if (_activeTouchPointers == 1) {
      if (_isHudInteractionPoint(event.position)) {
        _mobilePaintGestureActive = false;
        _lastPaintGlobalPosition = null;
        _lastPaintMicros = 0;
        return;
      }
      _mobilePaintGestureActive = true;
      _lastPaintGlobalPosition = event.position;
      _lastPaintMicros = DateTime.now().microsecondsSinceEpoch;
      _beginMobilePaint(event.position);
    } else {
      _endMobilePaint();
    }
  }

  void _onMobilePointerMove(PointerMoveEvent event) {
    final game = _game;
    if (game == null || game.isDesktop || !game.isCreationMode) return;
    if (_activeTouchPointers == 1 && _mobilePaintGestureActive) {
      if (_isHudInteractionPoint(event.position)) {
        return;
      }
      final nowMicros = DateTime.now().microsecondsSinceEpoch;
      final lastPos = _lastPaintGlobalPosition;
      const minIntervalMicros = 16000; // ~60Hz max paint updates on mobile.
      if (lastPos != null) {
        final dx = event.position.dx - lastPos.dx;
        final dy = event.position.dy - lastPos.dy;
        final movedSq = dx * dx + dy * dy;
        final elapsed = nowMicros - _lastPaintMicros;
        if (movedSq < 1.0 && elapsed < minIntervalMicros) {
          return;
        }
      }
      _lastPaintGlobalPosition = event.position;
      _lastPaintMicros = nowMicros;
      _updateMobilePaint(event.position);
    }
  }

  void _onMobilePointerUp() {
    if (_activeTouchPointers > 0) {
      _activeTouchPointers--;
    }
    if (_activeTouchPointers == 0) {
      _endMobilePaint();
    }
  }

  @override
  Widget build(BuildContext context) {
    final game = _game;
    if (game == null) {
      return const Scaffold(
        backgroundColor: AppColors.background,
        body: SizedBox.shrink(),
      );
    }
    final media = MediaQuery.of(context);
    final bottomBarReserve = ElementBottomBar.estimatedHeightFor(media);

    return Scaffold(
      key: const ValueKey('sandbox_screen'),
      backgroundColor: AppColors.background,
      body: Listener(
        onPointerDown: game.onPointerDown,
        onPointerMove: game.onPointerMove,
        onPointerUp: game.onPointerUp,
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              key: _gameViewportKey,
              child: GameWidget<ParticleEngineGame>(
                game: game,
                overlayBuilderMap: ParticleEngineGame.overlayBuilders,
                initialActiveOverlays: const [
                  ParticleEngineGame.overlayObservationHint,
                  ParticleEngineGame.overlayBackButton,
                ],
              ),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: game.showBottomBar,
              builder: (context, visible, _) {
                if (game.isDesktop) {
                  return const SizedBox.shrink();
                }
                return Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !visible,
                    child: Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: _onMobilePointerDown,
                      onPointerMove: _onMobilePointerMove,
                      onPointerUp: (_) => _onMobilePointerUp(),
                      onPointerCancel: (_) => _onMobilePointerUp(),
                    ),
                  ),
                );
              },
            ),
            ValueListenableBuilder<bool>(
              valueListenable: game.showBottomBar,
              builder: (context, visible, _) {
                return Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    ignoring: !visible,
                    child: AnimatedSlide(
                      offset: visible ? Offset.zero : const Offset(0, 1),
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutCubic,
                      child: visible
                          ? ElementBottomBar(
                              key: _bottomBarKey,
                              game: game,
                              onInteraction: game.notifyHudInteraction,
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                );
              },
            ),
            ValueListenableBuilder<bool>(
              valueListenable: game.showBottomBar,
              builder: (context, visible, _) {
                return Positioned(
                  left: 0,
                  top: 0,
                  bottom: visible ? bottomBarReserve : 0,
                  child: IgnorePointer(
                    ignoring: !visible,
                    child: AnimatedOpacity(
                      opacity: visible ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      child: SizedBox(
                        key: _toolBarKey,
                        width: 120,
                        child: visible
                            ? ToolBar(
                                game: game,
                                onInteraction: game.notifyHudInteraction,
                                reservedBottom: bottomBarReserve,
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
