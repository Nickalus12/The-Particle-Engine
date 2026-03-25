import 'dart:async' as async_lib;

import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/effects.dart';
import 'package:flame/events.dart' hide PointerMoveEvent;
import 'package:flame/game.dart';
import 'package:flutter/foundation.dart' show kIsWeb, TargetPlatform, defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/game_state.dart';
import '../simulation/world_gen/world_config.dart';
import '../ui/widgets/colony_inspector.dart';
import '../ui/widgets/element_palette.dart';
import '../ui/widgets/hud_icon_badge.dart';
import '../ui/widgets/periodic_table_overlay.dart';
import '../ui/widgets/mini_map.dart';
import '../ui/widgets/tool_bar.dart';
import 'sandbox_world.dart';

/// Top-level [FlameGame] subclass that wires together the simulation world,
/// camera, overlays, and input routing.
///
/// The game is configured with a fixed-resolution camera so that the pixel grid
/// appears sharp at any device DPI. Flutter widget overlays (palette, toolbar,
/// mini-map) are registered in [onLoad] and toggled at runtime through the
/// [overlays] API.
///
/// Camera controls:
/// - Two-finger pinch to zoom (with smooth momentum and min/max bounds)
/// - Two-finger drag to pan
/// - Double-tap to reset camera view (smooth via Flame MoveEffect)
/// - Single-finger drag is forwarded to the sandbox for element placement
///
/// All animations use Flame's Effects system rather than manual lerp loops.
class ParticleEngineGame extends FlameGame
    with ScaleDetector, DoubleTapDetector, ScrollDetector, KeyboardEvents {
  ParticleEngineGame({
    this.worldConfig,
    this.isBlankCanvas = false,
    this.loadState,
    this.worldName,
    this.gridWidth = 320,
    this.gridHeight = 180,
    this.cellSize = 4.0,
  }) : super(
          // MaxViewport fills the entire window. Wrapping copies fill extra width.
          camera: CameraComponent(),
          world: SandboxWorld(),
        );

  /// Grid dimensions (passed through to the simulation engine).
  final int gridWidth;
  final int gridHeight;

  /// Logical pixels per grid cell.
  final double cellSize;

  /// Computed world width in game coordinates.
  double get cameraWidth => gridWidth * cellSize;

  /// Computed world height in game coordinates.
  double get cameraHeight => gridHeight * cellSize;

  /// Configuration for procedural world generation (null = default).
  final WorldConfig? worldConfig;

  /// Whether to generate a blank canvas.
  final bool isBlankCanvas;

  /// Previously saved state to restore (takes precedence over worldConfig).
  final GameState? loadState;

  /// User-provided world name (for save metadata).
  final String? worldName;

  /// Typed accessor for the sandbox world.
  SandboxWorld get sandboxWorld => world as SandboxWorld;

  /// Notifier for the bottom bar visibility (observed by SandboxScreen layout).
  final ValueNotifier<bool> showBottomBar = ValueNotifier<bool>(false);

  // -- Camera configuration ---------------------------------------------------

  /// Base zoom level: scales the world height to fill the screen vertically.
  /// Computed from the actual window size in [onGameResize].
  double _baseZoom = 1.0;

  @override
  Color backgroundColor() => const Color(0xFF4888C8);

  /// Minimum zoom — world fills the screen at this level.
  double get minZoom => _baseZoom;

  /// Maximum zoom — close enough to see individual cells clearly.
  double get maxZoom => _baseZoom * 6.0;

  /// Default zoom level.
  double get defaultZoom => _baseZoom;

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    // Fit the world height to the screen so the full vertical extent
    // (sky to ground) is always visible. Horizontal wrapping seamlessly
    // fills any extra width — on a 16:9 monitor this is an exact fit.
    final newBase = size.y / cameraHeight;
    if ((_baseZoom - newBase).abs() > 0.001) {
      final wasBase = camera.viewfinder.zoom <= _baseZoom + 0.01;
      _baseZoom = newBase;
      if (wasBase) {
        camera.viewfinder.zoom = _baseZoom;
      } else {
        camera.viewfinder.zoom =
            camera.viewfinder.zoom.clamp(minZoom, maxZoom);
      }
    }
  }

  // -- Day/night cycle --------------------------------------------------------

  /// Whether the world is currently in night mode.
  bool isNight = false;

  /// Progress of day/night transition (0.0 = day, 1.0 = night).
  double dayNightTransition = 0.0;

  /// The active day/night transition effect, if any.
  _DayNightEffect? _dayNightEffect;

  // -- Camera state -----------------------------------------------------------

  late double _startZoom;
  int _pointerCount = 0;

  /// Whether a right/middle mouse button drag is in progress for panning.
  bool _isPanning = false;
  Vector2 _lastPanPosition = Vector2.zero();

  /// Whether this is a desktop platform (mouse-based input).
  bool get isDesktop {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  // ---------------------------------------------------------------------------
  // Game loop — keep camera bounded every frame
  // ---------------------------------------------------------------------------

  @override
  void update(double dt) {
    super.update(dt);
    // Clamp every frame so zoom/move effects can never leave the world visible.
    clampCameraPosition();
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  Future<void> onLoad() async {
    await super.onLoad();

    camera.viewfinder.anchor = Anchor.center;
    camera.viewfinder.position = Vector2(cameraWidth / 2, cameraHeight / 2);
    camera.viewfinder.zoom = _baseZoom;

    // On desktop, start in creation mode so the HUD is visible immediately.
    if (isDesktop) {
      // Delay slightly so overlays are registered first.
      Future.delayed(const Duration(milliseconds: 100), enterCreationMode);
    }
  }

  // Fixed resolution camera handles window resizing automatically.

  @override
  void onRemove() {
    _autoHideTimer?.cancel();
    _dayNightEffect?.removeFromParent();
    super.onRemove();
  }

  // ---------------------------------------------------------------------------
  // Day/night cycle — uses Flame Effect for smooth transition
  // ---------------------------------------------------------------------------

  /// Toggle between day and night with a smooth Flame Effect transition.
  void toggleDayNight() {
    isNight = !isNight;
    final target = isNight ? 1.0 : 0.0;
    if (sandboxWorld.isMounted) {
      sandboxWorld.simulation.isNight = isNight;
    }

    // Remove any in-progress transition.
    _dayNightEffect?.removeFromParent();

    _dayNightEffect = _DayNightEffect(
      from: dayNightTransition,
      to: target,
      onUpdate: (value) => dayNightTransition = value,
    );
    add(_dayNightEffect!);
  }

  // ---------------------------------------------------------------------------
  // Camera controls — pinch-to-zoom and two-finger pan
  // ---------------------------------------------------------------------------

  @override
  void onScaleStart(ScaleStartInfo info) {
    _startZoom = camera.viewfinder.zoom;
    _pointerCount = info.pointerCount;
    // Single finger: forward to sandbox for painting
    if (_pointerCount == 1) {
      sandboxWorld.sandboxComponent.colonySpawnedThisGesture = false;
      _paintFromScreenPosition(info.raw.focalPoint);
    }
  }

  @override
  void onScaleUpdate(ScaleUpdateInfo info) {
    if (_pointerCount < 2) {
      // Single finger: forward continuous drag to sandbox for painting
      _paintFromScreenPosition(info.raw.focalPoint);
      return;
    }

    final currentScale = info.scale.global;
    if (!currentScale.isIdentity()) {
      // Pinch zoom.
      camera.viewfinder.zoom =
          (_startZoom * currentScale.y).clamp(minZoom, maxZoom);
    } else {
      // Two-finger pan.
      final delta = (info.delta.global..negate()) / camera.viewfinder.zoom;
      camera.moveBy(delta);
    }
    clampCameraPosition();
  }

  @override
  void onScaleEnd(ScaleEndInfo info) {
    if (_pointerCount == 1) {
      enterCreationMode();
      // Reset paint interpolation state
      sandboxWorld.sandboxComponent.lastPaintX = null;
      sandboxWorld.sandboxComponent.lastPaintY = null;
    }
    _pointerCount = 0;
  }

  /// Convert a screen-space position to world coordinates and paint.
  void _paintFromScreenPosition(Offset screenPos) {
    // Convert screen position to world coordinates via the camera
    final worldPos = camera.viewfinder.transform.globalToLocal(
      Vector2(screenPos.dx, screenPos.dy),
    );
    sandboxWorld.sandboxComponent.paintAt(worldPos);
  }

  // ---------------------------------------------------------------------------
  // Double-tap to reset camera — uses Flame MoveEffect for smooth animation
  // ---------------------------------------------------------------------------

  @override
  void onDoubleTap() {
    // Smooth camera reset to world center using Flame Effects.
    camera.viewfinder.add(
      MoveEffect.to(
        Vector2(cameraWidth / 2, cameraHeight / 2),
        EffectController(duration: 0.3, curve: Curves.easeOut),
      ),
    );

    // Smooth zoom reset via a custom zoom effect.
    _animateZoomTo(defaultZoom, duration: 0.3);
  }

  /// Animate zoom to a target value using Flame's effect system.
  void _animateZoomTo(double targetZoom, {double duration = 0.3}) {
    final startZoom = camera.viewfinder.zoom;
    final zoomEffect = _ZoomEffect(
      from: startZoom,
      to: targetZoom,
      duration: duration,
      viewfinder: camera.viewfinder,
    );
    add(zoomEffect);
  }

  // ---------------------------------------------------------------------------
  // Mouse wheel zoom (desktop)
  // ---------------------------------------------------------------------------

  @override
  void onScroll(PointerScrollInfo info) {
    final scrollDelta = info.scrollDelta.global.y;
    const zoomSensitivity = 0.05;

    if (scrollDelta != 0) {
      final oldZoom = camera.viewfinder.zoom;
      final zoomChange = scrollDelta > 0 ? -zoomSensitivity : zoomSensitivity;
      final newZoom =
          (oldZoom + zoomChange * oldZoom).clamp(minZoom, maxZoom);

      // Zoom toward the mouse cursor position for a natural feel.
      // Convert the screen-space cursor position to world coordinates before
      // and after the zoom change, then shift the camera by the difference.
      final cursorScreen = info.eventPosition.global;
      final viewportSize = camera.viewport.size;

      // Cursor offset from viewport center in screen pixels.
      final offsetX = cursorScreen.x - viewportSize.x / 2;
      final offsetY = cursorScreen.y - viewportSize.y / 2;

      // World-space position under cursor before zoom.
      final worldBeforeX = camera.viewfinder.position.x + offsetX / oldZoom;
      final worldBeforeY = camera.viewfinder.position.y + offsetY / oldZoom;

      camera.viewfinder.zoom = newZoom;

      // World-space position under cursor after zoom (same screen point).
      final worldAfterX = camera.viewfinder.position.x + offsetX / newZoom;
      final worldAfterY = camera.viewfinder.position.y + offsetY / newZoom;

      // Shift camera so the world point under the cursor stays put.
      camera.viewfinder.position += Vector2(
        worldBeforeX - worldAfterX,
        worldBeforeY - worldAfterY,
      );

      clampCameraPosition();
    }
  }

  // ---------------------------------------------------------------------------
  // Right-click / middle-click drag to pan (desktop)
  // ---------------------------------------------------------------------------

  /// Handle pointer down for right/middle button panning.
  void onPointerDown(PointerDownEvent event) {
    if (event.buttons == kSecondaryMouseButton ||
        event.buttons == kMiddleMouseButton) {
      _isPanning = true;
      _lastPanPosition = Vector2(event.position.dx, event.position.dy);
    }
  }

  /// Handle pointer move for right/middle button panning.
  void onPointerMove(PointerMoveEvent event) {
    if (_isPanning) {
      final current = Vector2(event.position.dx, event.position.dy);
      final delta = (_lastPanPosition - current) / camera.viewfinder.zoom;
      camera.viewfinder.position += delta;
      _lastPanPosition = current;
      clampCameraPosition();
    }
  }

  /// Handle pointer up to end panning.
  void onPointerUp(PointerUpEvent event) {
    _isPanning = false;
  }

  // ---------------------------------------------------------------------------
  // Keyboard controls (desktop) — arrow keys to pan, +/- to zoom
  // ---------------------------------------------------------------------------

  @override
  KeyEventResult onKeyEvent(
    KeyEvent event,
    Set<LogicalKeyboardKey> keysPressed,
  ) {
    const panSpeed = 10.0;

    if (keysPressed.contains(LogicalKeyboardKey.arrowLeft)) {
      camera.viewfinder.position += Vector2(-panSpeed / camera.viewfinder.zoom, 0);
      clampCameraPosition();
    }
    if (keysPressed.contains(LogicalKeyboardKey.arrowRight)) {
      camera.viewfinder.position += Vector2(panSpeed / camera.viewfinder.zoom, 0);
      clampCameraPosition();
    }
    if (keysPressed.contains(LogicalKeyboardKey.arrowUp)) {
      camera.viewfinder.position += Vector2(0, -panSpeed / camera.viewfinder.zoom);
      clampCameraPosition();
    }
    if (keysPressed.contains(LogicalKeyboardKey.arrowDown)) {
      camera.viewfinder.position += Vector2(0, panSpeed / camera.viewfinder.zoom);
      clampCameraPosition();
    }

    return KeyEventResult.ignored;
  }

  // ---------------------------------------------------------------------------
  // World boundary clamping
  // ---------------------------------------------------------------------------

  /// Keep the camera bounded.
  /// Horizontal: always wraps — the 3-copy rendering fills any extra width.
  /// Vertical: always clamped (no vertical wrapping — ground/sky are fixed).
  void clampCameraPosition() {
    final zoom = camera.viewfinder.zoom;
    final halfH = cameraHeight / (2.0 * zoom);

    final pos = camera.viewfinder.position;

    // -- Horizontal: always wrap for seamless scrolling --
    double x = pos.x % cameraWidth;
    if (x < 0) x += cameraWidth;

    // -- Vertical (always clamped) --
    final minY = halfH;
    final maxY = cameraHeight - halfH;
    double y = pos.y;
    y = minY < maxY ? y.clamp(minY, maxY) : cameraHeight / 2;

    camera.viewfinder.position = Vector2(x, y);
  }

  // ---------------------------------------------------------------------------
  // Overlay keys
  // ---------------------------------------------------------------------------

  static const String overlayPalette = 'element_palette';
  static const String overlayBottomBar = 'element_bottom_bar';
  static const String overlayToolbar = 'tool_bar';
  static const String overlayMiniMap = 'mini_map';
  static const String overlayColonyInspector = 'colony_inspector';
  static const String overlayObservationHint = 'observation_hint';
  static const String overlayBackButton = 'back_button';
  static const String overlayPeriodicTable = 'periodic_table';

  /// All creation-mode overlays shown/hidden as a group.
  /// Note: overlayBottomBar is managed via showBottomBar notifier, not overlays.
  static const List<String> _creationOverlays = [
    overlayToolbar,
  ];

  // ---------------------------------------------------------------------------
  // Two-state HUD mode (observation ↔ creation)
  // ---------------------------------------------------------------------------

  /// Whether the HUD is in creation mode (true) or observation mode (false).
  bool isCreationMode = false;

  /// Auto-hide timer that returns to observation mode after inactivity.
  /// Only used on mobile — desktop keeps the HUD always visible.
  async_lib.Timer? _autoHideTimer;

  /// Duration before auto-hiding the HUD (mobile only).
  static const _autoHideDuration = Duration(seconds: 8);

  /// Enter creation mode — show all HUD overlays via Flame's overlay system.
  void enterCreationMode() {
    if (isCreationMode) {
      _resetAutoHideTimer();
      return;
    }
    isCreationMode = true;
    overlays.remove(overlayObservationHint);
    for (final key in _creationOverlays) {
      overlays.add(key);
    }
    showBottomBar.value = true;
    _resetAutoHideTimer();
  }

  /// Exit creation mode — hide HUD overlays, show observation hint.
  void exitCreationMode() {
    if (!isCreationMode) return;
    _autoHideTimer?.cancel();
    isCreationMode = false;
    for (final key in _creationOverlays) {
      overlays.remove(key);
    }
    showBottomBar.value = false;
    overlays.add(overlayObservationHint);
  }

  /// Reset the auto-hide timer (called on any HUD interaction).
  void notifyHudInteraction() {
    _resetAutoHideTimer();
  }

  void _resetAutoHideTimer() {
    // Desktop: no auto-hide — HUD is always visible.
    if (isDesktop) return;
    _autoHideTimer?.cancel();
    _autoHideTimer = async_lib.Timer(_autoHideDuration, exitCreationMode);
  }

  /// Show the colony inspector overlay for a given colony.
  void showColonyInspector() {
    overlays.add(overlayColonyInspector);
    notifyHudInteraction();
  }

  /// Hide the colony inspector overlay.
  void hideColonyInspector() {
    overlays.remove(overlayColonyInspector);
  }

  // ---------------------------------------------------------------------------
  // Overlay builder map — registered on the GameWidget
  // ---------------------------------------------------------------------------

  /// All Flutter widget overlays for the sandbox.
  ///
  /// Each builder receives the game instance, giving overlays direct access
  /// to game state without needing HasGameRef or external state management.
  static Map<String, OverlayWidgetBuilder<ParticleEngineGame>> get
      overlayBuilders => {
            overlayPalette: (context, game) => ElementPalette(
                  game: game,
                  onInteraction: game.notifyHudInteraction,
                ),
            overlayToolbar: (context, game) => ToolBar(
                  game: game,
                  onInteraction: game.notifyHudInteraction,
                ),
            overlayMiniMap: (context, game) => MiniMap(
                  simulation: game.sandboxWorld.simulation,
                  isVisible: true,
                ),
            overlayColonyInspector: (context, game) {
              final colonies =
                  game.sandboxWorld.creatures.colonies;
              if (colonies.isEmpty) return const SizedBox.shrink();
              return ColonyInspector(
                colony: colonies.first,
                onClose: game.hideColonyInspector,
              );
            },
            overlayObservationHint: (context, game) =>
                _ObservationHintOverlay(game: game),
            overlayBackButton: (context, game) =>
                _BackButtonOverlay(game: game),
            overlayPeriodicTable: (context, game) =>
                PeriodicTableOverlay(
                  game: game,
                  onClose: () => game.overlays.remove(overlayPeriodicTable),
                ),
          };
}

// =============================================================================
// Flame Effect components for smooth transitions
// =============================================================================

/// A Flame [Component] that drives a smooth zoom transition on the viewfinder.
///
/// Uses [EffectController] for duration/curve, keeping the animation within
/// Flame's effect system rather than manual lerp in update().
class _ZoomEffect extends Component {
  _ZoomEffect({
    required this.from,
    required this.to,
    required double duration,
    required this.viewfinder,
  }) : _controller = EffectController(
          duration: duration,
          curve: Curves.easeOut,
        );

  final double from;
  final double to;
  final Viewfinder viewfinder;
  final EffectController _controller;

  @override
  void update(double dt) {
    super.update(dt);
    _controller.advance(dt);
    viewfinder.zoom = from + (to - from) * _controller.progress;
    if (_controller.completed) {
      viewfinder.zoom = to;
      removeFromParent();
    }
  }
}

/// A Flame [Component] that drives the day/night transition value.
///
/// Replaces the manual lerp loop in update() with a proper Flame effect that
/// self-removes when complete.
class _DayNightEffect extends Component {
  _DayNightEffect({
    required this.from,
    required this.to,
    required this.onUpdate,
  }) : _controller = EffectController(
          duration: 1.0,
          curve: Curves.easeInOut,
        );

  final double from;
  final double to;
  final void Function(double value) onUpdate;
  final EffectController _controller;

  @override
  void update(double dt) {
    super.update(dt);
    _controller.advance(dt);
    final value = from + (to - from) * _controller.progress;
    onUpdate(value);
    if (_controller.completed) {
      onUpdate(to);
      removeFromParent();
    }
  }
}

// =============================================================================
// Overlay widgets used by the game's overlay system
// =============================================================================

/// Floating action button in observation mode that invites the user to enter
/// creation mode. Much more discoverable than the old breathing glow bar.
class _ObservationHintOverlay extends StatefulWidget {
  const _ObservationHintOverlay({required this.game});
  final ParticleEngineGame game;

  @override
  State<_ObservationHintOverlay> createState() =>
      _ObservationHintOverlayState();
}

class _ObservationHintOverlayState extends State<_ObservationHintOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 24,
      right: 16,
      child: AnimatedBuilder(
        animation: _pulseAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: 0.96 + (_pulseAnimation.value * 0.08),
            child: HudIconBadge(
              icon: Icons.brush_rounded,
              onTap: widget.game.enterCreationMode,
              tooltip: 'Enter creation mode',
              accent: const Color(0xFFE94560),
              motif: HudBadgeMotif.pulse,
              active: true,
              size: 58,
              iconSize: 24,
            ),
          );
        },
      ),
    );
  }
}

/// Always-visible back/close button overlay — large enough for touch (48dp).
class _BackButtonOverlay extends StatefulWidget {
  const _BackButtonOverlay({required this.game});
  final ParticleEngineGame game;

  @override
  State<_BackButtonOverlay> createState() => _BackButtonOverlayState();
}

class _BackButtonOverlayState extends State<_BackButtonOverlay> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 12,
      right: 12,
      child: SafeArea(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          cursor: SystemMouseCursors.click,
          child: Opacity(
            opacity: _hovered ? 1.0 : 0.88,
            child: HudIconBadge(
              icon: Icons.close_rounded,
              onTap: () => Navigator.of(context).maybePop(),
              tooltip: 'Back',
              accent: const Color(0xFFAAB7D8),
              motif: HudBadgeMotif.orbit,
              size: 46,
              iconSize: 20,
            ),
          ),
        ),
      ),
    );
  }
}
