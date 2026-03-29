import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/events.dart';

import '../../rendering/gi_post_process.dart';
import '../../simulation/element_registry.dart';
import '../../simulation/pixel_renderer.dart';
import '../../simulation/simulation_engine.dart';
import '../particle_engine_game.dart';

class PlacementMetricsSnapshot {
  const PlacementMetricsSnapshot({
    required this.paintStampsTotal,
    required this.cellsModifiedTotal,
    required this.cellsPaintedTotal,
    required this.cellsErasedTotal,
    required this.lineSegmentsTotal,
    required this.linePointsTotal,
    required this.noopStampsTotal,
  });

  final int paintStampsTotal;
  final int cellsModifiedTotal;
  final int cellsPaintedTotal;
  final int cellsErasedTotal;
  final int lineSegmentsTotal;
  final int linePointsTotal;
  final int noopStampsTotal;

  double get cellsPerStamp =>
      paintStampsTotal == 0 ? 0.0 : cellsModifiedTotal / paintStampsTotal;

  Map<String, Object> toJson() => <String, Object>{
    'placement_stamps_total': paintStampsTotal,
    'placement_cells_modified_total': cellsModifiedTotal,
    'placement_cells_painted_total': cellsPaintedTotal,
    'placement_cells_erased_total': cellsErasedTotal,
    'placement_line_segments_total': lineSegmentsTotal,
    'placement_line_points_total': linePointsTotal,
    'placement_noop_stamps_total': noopStampsTotal,
    'placement_cells_per_stamp': cellsPerStamp,
  };
}

class RenderMetricsSnapshot {
  const RenderMetricsSnapshot({
    required this.renderPixelPasses,
    required this.imageBuildPasses,
    required this.postProcessPasses,
    required this.skippedFrames,
    required this.wrapCopiesLastFrame,
    required this.frameBudgetSkips,
  });

  final int renderPixelPasses;
  final int imageBuildPasses;
  final int postProcessPasses;
  final int skippedFrames;
  final int wrapCopiesLastFrame;
  final int frameBudgetSkips;

  Map<String, Object> toJson() => <String, Object>{
    'render_pixel_passes': renderPixelPasses,
    'image_build_passes': imageBuildPasses,
    'post_process_passes': postProcessPasses,
    'render_skipped_frames': skippedFrames,
    'wrap_copies_last_frame': wrapCopiesLastFrame,
    'frame_budget_skips': frameBudgetSkips,
  };
}

class SandboxComponent extends PositionComponent
    with TapCallbacks, DragCallbacks, HasGameReference<ParticleEngineGame> {
  SandboxComponent({required this.simulation, this.cellSize = 2.0})
    : super(
        size: Vector2(
          simulation.gridW.toDouble() * cellSize,
          simulation.gridH.toDouble() * cellSize,
        ),
        position: Vector2.zero(),
      );

  final SimulationEngine simulation;

  late final PixelRenderer renderer;

  final double cellSize;

  int selectedElement = El.sand;

  int brushSize = 3;

  ui.Image? _gridImage;

  bool _decoding = false;
  int _postProcessFrameCounter = 0;

  final ui.Paint _imagePaint = ui.Paint()
    ..filterQuality = ui.FilterQuality.none;

  int _frameBudgetSkips = 0;
  int _mobileRenderFrameCounter = 0;
  int _renderPixelPasses = 0;
  int _imageBuildPasses = 0;
  int _postProcessPasses = 0;
  int _renderSkippedFrames = 0;
  int _wrapCopiesLastFrame = 1;

  final Stopwatch _updateStopwatch = Stopwatch();

  /// Last grid position painted at, for Bresenham line interpolation.
  int? lastPaintX;
  int? lastPaintY;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    renderer = PixelRenderer(simulation);
    renderer.init();
    renderer.generateStars();
    if (!game.isDesktop) {
      renderer.enableGlow = false;
      renderer.enableMicroParticles = false;
      renderer.glowUpdateInterval = game.mobileRenderInterval <= 2 ? 8 : 10;
      renderer.atmosphereCacheInterval = game.isCreationMode ? 12 : 10;
    }
  }

  // ---------------------------------------------------------------------------
  // Update — render pixels and decode to image
  // ---------------------------------------------------------------------------

  @override
  void update(double dt) {
    super.update(dt);
    _updateStopwatch.reset();
    _updateStopwatch.start();

    final shouldRenderFrame = _shouldRenderThisFrame();
    if (!shouldRenderFrame) {
      _renderSkippedFrames++;
      _updateStopwatch.stop();
      return;
    }

    renderer.dayNightT = game.dayNightTransition;
    renderer.viewportY = game.camera.viewfinder.position.y / cellSize;

    if (game.isDesktop || game.mobileCreatureDetail) {
      renderer.tickMicroParticles();
    }

    renderer.renderPixels();
    _renderPixelPasses++;

    if (!_decoding) {
      if (_frameBudgetSkips > 0) {
        _frameBudgetSkips--;
      } else {
        _decoding = true;
        _imageBuildPasses++;
        renderer.buildImage().then((image) async {
          final baseImage = image as ui.Image;
          final shouldRunPostProcess = _shouldRunPostProcess();
          ui.Image processed = baseImage;
          if (shouldRunPostProcess) {
            // Run GI post-process pipeline on the base image.
            final GIPostProcess gi = game.sandboxWorld.giPostProcess;
            if (gi.enabled) {
              gi.dayNightT = game.dayNightTransition;
              processed = await gi.process(baseImage);
              _postProcessPasses++;
            }
          }
          if (!identical(processed, baseImage)) {
            baseImage.dispose();
          }
          _gridImage?.dispose();
          _gridImage = processed;
          _decoding = false;
        });
      }
    }

    _updateStopwatch.stop();
    if (_updateStopwatch.elapsedMilliseconds > 12) {
      _frameBudgetSkips = 1;
    }
  }

  // ---------------------------------------------------------------------------
  // Rendering — draw world image with wrap copies for seamless scrolling
  // ---------------------------------------------------------------------------

  @override
  void render(ui.Canvas canvas) {
    final image = _gridImage;
    if (image == null) return;

    final worldW = simulation.gridW.toDouble();
    final worldCopies = _visibleWrapCopies();
    _wrapCopiesLastFrame = worldCopies.length;

    canvas.save();
    canvas.scale(cellSize, cellSize);
    for (final copyOffset in worldCopies) {
      canvas.drawImage(image, ui.Offset(copyOffset * worldW, 0), _imagePaint);
    }
    canvas.restore();
  }

  List<double> _visibleWrapCopies() {
    final cam = game.camera.viewfinder;
    final viewportWidthWorld =
        game.camera.viewport.size.x / cam.zoom / cellSize;
    final halfViewport = viewportWidthWorld / 2.0;
    final worldW = simulation.gridW.toDouble();
    final viewLeft = (cam.position.x / cellSize) - halfViewport;
    final viewRight = (cam.position.x / cellSize) + halfViewport;
    final copies = <double>[0.0];
    if (viewLeft < 0.0) {
      copies.insert(0, -1.0);
    }
    if (viewRight > worldW) {
      copies.add(1.0);
    }
    return copies;
  }

  /// Override containsLocalPoint so taps/drags are accepted across
  /// the full 3x render area (one world-width on each side).
  @override
  bool containsLocalPoint(Vector2 point) {
    final worldW = simulation.gridW.toDouble() * cellSize;
    return point.x >= -worldW &&
        point.x < worldW * 2 &&
        point.y >= 0 &&
        point.y < simulation.gridH.toDouble() * cellSize;
  }

  // ---------------------------------------------------------------------------
  // Cleanup
  // ---------------------------------------------------------------------------

  @override
  void onRemove() {
    _gridImage?.dispose();
    _gridImage = null;
    super.onRemove();
  }

  // ---------------------------------------------------------------------------
  // Input — paint elements into the grid (single-finger only)
  // ---------------------------------------------------------------------------

  @override
  void onTapDown(TapDownEvent event) {
    if (!game.isDesktop) return;
    lastPaintX = null;
    lastPaintY = null;
    colonySpawnedThisGesture = false;
    paintAtScreen(event.canvasPosition);
  }

  bool _shouldRunPostProcess() {
    if (game.isDesktop && game.mobilePostProcessInterval <= 1) {
      return true;
    }
    final baseInterval = game.mobilePostProcessInterval < 1
        ? 1
        : game.mobilePostProcessInterval;
    final interval = game.isCreationMode ? baseInterval + 2 : baseInterval;
    final shouldRun = _postProcessFrameCounter % interval == 0;
    _postProcessFrameCounter++;
    return shouldRun;
  }

  bool _shouldRenderThisFrame() {
    if (game.isDesktop && game.mobileRenderInterval <= 1) {
      return true;
    }
    final interval = game.mobileRenderInterval < 1
        ? 1
        : game.mobileRenderInterval;
    final activeInterval = game.isCreationMode ? interval : interval - 1;
    final safeInterval = activeInterval < 1 ? 1 : activeInterval;
    final shouldRun = _mobileRenderFrameCounter % safeInterval == 0;
    _mobileRenderFrameCounter++;
    return shouldRun;
  }

  @override
  void onDragStart(DragStartEvent event) {
    super.onDragStart(event);
    if (!game.isDesktop) return;
    lastPaintX = null;
    lastPaintY = null;
    colonySpawnedThisGesture = false;
    paintAtScreen(event.canvasPosition);
  }

  @override
  void onDragUpdate(DragUpdateEvent event) {
    if (!game.isDesktop) return;
    paintAtScreen(event.canvasEndPosition);
  }

  @override
  void onDragEnd(DragEndEvent event) {
    super.onDragEnd(event);
    if (!game.isDesktop) return;
    lastPaintX = null;
    lastPaintY = null;
    colonySpawnedThisGesture = false;
  }

  /// Paint using screen/canvas-space coordinates (camera aware).
  void paintAtScreen(Vector2 screenPosition) {
    final (cx, cy) = viewportToGrid(screenPosition);
    _paintGridAt(cx, cy);
  }

  /// Paint using world-space coordinates.
  void paintAt(Vector2 position) {
    // Convert world position to grid coords, wrapping X.
    final rawX = (position.x / cellSize).floor();
    final cx = simulation.wrapX(rawX);
    final cy = (position.y / cellSize).floor();
    _paintGridAt(cx, cy);
  }

  /// Paint at grid coordinates, with interpolation from prior gesture point.
  void _paintGridAt(int cx, int cy) {
    _paintStampsTotal++;
    // Bresenham line from last paint position to current for gap-free strokes.
    if (lastPaintX != null && lastPaintY != null) {
      final x0 = lastPaintX!;
      final y0 = lastPaintY!;
      if (x0 != cx || y0 != cy) {
        final modified = _paintLine(x0, y0, cx, cy);
        if (modified) {
          renderer.invalidateAtmosphereCaches();
        } else {
          _noopStampsTotal++;
        }
        lastPaintX = cx;
        lastPaintY = cy;
        return;
      }
    }

    final modified = _paintCell(cx, cy);
    if (modified) {
      renderer.invalidateAtmosphereCaches();
    } else {
      _noopStampsTotal++;
    }
    lastPaintX = cx;
    lastPaintY = cy;
  }

  /// Paint along a Bresenham line from (x0,y0) to (x1,y1), skipping (x0,y0)
  /// since it was already painted on the previous event.
  bool _paintLine(int x0, int y0, int x1, int y1) {
    _lineSegmentsTotal++;
    final w = simulation.gridW;
    int rawDx = x1 - x0;
    // Shortest path across wrap boundary
    if (rawDx.abs() > w ~/ 2) {
      rawDx += rawDx > 0 ? -w : w;
    }
    final actualX1 = x0 + rawDx;

    int dx = rawDx.abs();
    int dy = -(y1 - y0).abs();
    int sx = rawDx >= 0 ? 1 : -1;
    int sy = y0 < y1 ? 1 : -1;
    int err = dx + dy;
    bool modified = false;

    int px = x0;
    int py = y0;
    bool first = true;
    while (true) {
      if (!first) {
        _linePointsTotal++;
        modified = _paintCell(simulation.wrapX(px), py) || modified;
      }
      first = false;
      if (px == actualX1 && py == y1) break;
      final e2 = 2 * err;
      if (e2 >= dy) {
        err += dy;
        px += sx;
      }
      if (e2 <= dx) {
        err += dx;
        py += sy;
      }
    }
    return modified;
  }

  /// Whether a colony was already spawned during this drag gesture.
  /// Prevents click-and-hold from spawning dozens of colonies.
  bool colonySpawnedThisGesture = false;

  static final Map<int, List<(int dx, int dy)>> _brushOffsetCache =
      <int, List<(int dx, int dy)>>{};
  int _paintStampsTotal = 0;
  int _cellsModifiedTotal = 0;
  int _cellsPaintedTotal = 0;
  int _cellsErasedTotal = 0;
  int _lineSegmentsTotal = 0;
  int _linePointsTotal = 0;
  int _noopStampsTotal = 0;

  /// Paint a single brush stamp at grid position (cx, cy).
  bool _paintCell(int cx, int cy) {
    final isEraser =
        selectedElement == El.eraser || selectedElement == El.empty;
    final paintEl = isEraser ? El.empty : selectedElement;

    final grid = simulation.grid;
    final gridW = simulation.gridW;
    bool modified = false;

    if (paintEl == El.ant) {
      // Ants are entity-based. Avoid painting/clearing a large temporary blob
      // on every drag update before spawning the colony.
      if (colonySpawnedThisGesture) return false;
      colonySpawnedThisGesture = true;

      var nestY = cy;
      for (var scanY = cy; scanY < simulation.gridH - 1; scanY++) {
        final belowIdx = (scanY + 1) * gridW + simulation.wrapX(cx);
        final belowEl = grid[belowIdx];
        if (!simulation.isEmptyOrGas(belowEl)) {
          nestY = scanY;
          break;
        }
        if (scanY == simulation.gridH - 2) {
          nestY = scanY;
        }
      }

      final cxNest = cx;
      final cyNest = nestY;
      for (var dy2 = -1; dy2 <= 1; dy2++) {
        for (var dx2 = -1; dx2 <= 1; dx2++) {
          final nx2 = simulation.wrapX(cxNest + dx2);
          final ny2 = cyNest + dy2;
          if (simulation.inBoundsY(ny2)) {
            final idx2 = ny2 * gridW + nx2;
            if (grid[idx2] != El.empty) {
              simulation.clearCell(idx2);
              simulation.unsettleNeighbors(nx2, ny2);
              modified = true;
            }
          }
        }
      }
      final world = game.sandboxWorld;
      world.spawnColony(cxNest, cyNest);
      return modified;
    }

    var modifiedCells = 0;
    var paintedCells = 0;
    var erasedCells = 0;
    for (final (dx: dx, dy: dy) in _offsetsForBrush(brushSize)) {
      final nx = simulation.wrapX(cx + dx);
      final ny = cy + dy;
      if (!simulation.inBoundsY(ny)) continue;

      final idx = ny * gridW + nx;
      final existingEl = grid[idx];
      if (existingEl == paintEl) {
        continue;
      }
      if (paintEl == El.empty && existingEl == El.empty) {
        continue;
      }
      simulation.clearCell(idx);
      grid[idx] = paintEl;
      // Initialize mass from element base mass
      if (paintEl != El.empty) {
        simulation.mass[idx] = elementBaseMass[paintEl];
      }
      // Clock bit: set OPPOSITE of current simClock. markDirty
      // writes to nextDirtyChunks which becomes dirtyChunks after
      // TWO step() swaps. By then simClock has flipped twice,
      // returning to the current value. The opposite bit ensures
      // the cell won't match currentClockBit when finally processed.
      simulation.flags[idx] = simulation.simClock ? 0 : 0x80;
      simulation.markDirty(nx, ny);
      simulation.unsettleNeighbors(nx, ny);
      modified = true;
      modifiedCells++;
      if (paintEl == El.empty) {
        erasedCells++;
      } else {
        paintedCells++;
      }
    }
    if (modifiedCells > 0) {
      _cellsModifiedTotal += modifiedCells;
      _cellsPaintedTotal += paintedCells;
      _cellsErasedTotal += erasedCells;
    }
    return modified;
  }

  List<(int dx, int dy)> _offsetsForBrush(int radius) {
    final safeRadius = radius < 1 ? 1 : radius;
    return _brushOffsetCache.putIfAbsent(safeRadius, () {
      final offsets = <(int dx, int dy)>[];
      final r2 = safeRadius * safeRadius;
      for (var dy = -safeRadius; dy <= safeRadius; dy++) {
        for (var dx = -safeRadius; dx <= safeRadius; dx++) {
          if (dx * dx + dy * dy <= r2) {
            offsets.add((dx: dx, dy: dy));
          }
        }
      }
      return offsets;
    });
  }

  (int x, int y) viewportToGrid(Vector2 viewportPos) {
    final cam = game.camera.viewfinder;
    final viewportSize = game.camera.viewport.size;
    final worldX =
        cam.position.x + (viewportPos.x - viewportSize.x / 2) / cam.zoom;
    final worldY =
        cam.position.y + (viewportPos.y - viewportSize.y / 2) / cam.zoom;
    return (
      simulation.wrapX((worldX / cellSize).floor()),
      (worldY / cellSize).floor(),
    );
  }

  /// Backward-compatible alias while tests and callers migrate to the
  /// viewport-local naming used by the mobile input contract.
  (int x, int y) screenToGrid(Vector2 screenPos) => viewportToGrid(screenPos);

  void resetPlacementMetrics() {
    _paintStampsTotal = 0;
    _cellsModifiedTotal = 0;
    _cellsPaintedTotal = 0;
    _cellsErasedTotal = 0;
    _lineSegmentsTotal = 0;
    _linePointsTotal = 0;
    _noopStampsTotal = 0;
  }

  PlacementMetricsSnapshot capturePlacementMetrics() =>
      PlacementMetricsSnapshot(
        paintStampsTotal: _paintStampsTotal,
        cellsModifiedTotal: _cellsModifiedTotal,
        cellsPaintedTotal: _cellsPaintedTotal,
        cellsErasedTotal: _cellsErasedTotal,
        lineSegmentsTotal: _lineSegmentsTotal,
        linePointsTotal: _linePointsTotal,
        noopStampsTotal: _noopStampsTotal,
      );

  RenderMetricsSnapshot captureRenderMetrics() => RenderMetricsSnapshot(
    renderPixelPasses: _renderPixelPasses,
    imageBuildPasses: _imageBuildPasses,
    postProcessPasses: _postProcessPasses,
    skippedFrames: _renderSkippedFrames,
    wrapCopiesLastFrame: _wrapCopiesLastFrame,
    frameBudgetSkips: _frameBudgetSkips,
  );
}
