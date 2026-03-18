import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/events.dart';

import '../../simulation/element_registry.dart';
import '../../simulation/pixel_renderer.dart';
import '../../simulation/simulation_engine.dart';
import '../particle_engine_game.dart';

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

  final ui.Paint _imagePaint = ui.Paint()
    ..filterQuality = ui.FilterQuality.none;

  int _frameBudgetSkips = 0;

  final Stopwatch _updateStopwatch = Stopwatch();

  /// Last grid position painted at, for Bresenham line interpolation.
  int? _lastPaintX;
  int? _lastPaintY;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    renderer = PixelRenderer(simulation);
    renderer.init();
    renderer.generateStars();
  }

  // ---------------------------------------------------------------------------
  // Update — render pixels and decode to image
  // ---------------------------------------------------------------------------

  @override
  void update(double dt) {
    super.update(dt);
    _updateStopwatch.reset();
    _updateStopwatch.start();

    renderer.dayNightT = game.dayNightTransition;

    renderer.tickMicroParticles();

    renderer.renderPixels();

    if (!_decoding) {
      if (_frameBudgetSkips > 0) {
        _frameBudgetSkips--;
      } else {
        _decoding = true;
        renderer.buildImage().then((image) {
          _gridImage?.dispose();
          _gridImage = image;
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
  // Rendering — single drawImage call
  // ---------------------------------------------------------------------------

  @override
  void render(ui.Canvas canvas) {
    final image = _gridImage;
    if (image == null) return;

    canvas.save();
    canvas.scale(cellSize, cellSize);
    canvas.drawImage(image, ui.Offset.zero, _imagePaint);
    canvas.restore();
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
    _lastPaintX = null;
    _lastPaintY = null;
    paintAt(event.localPosition);
  }

  @override
  void onDragStart(DragStartEvent event) {
    super.onDragStart(event);
    _lastPaintX = null;
    _lastPaintY = null;
    paintAt(event.localPosition);
  }

  @override
  void onDragUpdate(DragUpdateEvent event) {
    paintAt(event.localEndPosition);
  }

  @override
  void onDragEnd(DragEndEvent event) {
    super.onDragEnd(event);
    _lastPaintX = null;
    _lastPaintY = null;
  }

  void paintAt(Vector2 position) {
    final cx = (position.x / cellSize).floor();
    final cy = (position.y / cellSize).floor();

    // Bresenham line from last paint position to current for gap-free strokes.
    if (_lastPaintX != null && _lastPaintY != null) {
      final x0 = _lastPaintX!;
      final y0 = _lastPaintY!;
      if (x0 != cx || y0 != cy) {
        _paintLine(x0, y0, cx, cy);
        _lastPaintX = cx;
        _lastPaintY = cy;
        return;
      }
    }

    _paintCell(cx, cy);
    _lastPaintX = cx;
    _lastPaintY = cy;
  }

  /// Paint along a Bresenham line from (x0,y0) to (x1,y1), skipping (x0,y0)
  /// since it was already painted on the previous event.
  void _paintLine(int x0, int y0, int x1, int y1) {
    int dx = (x1 - x0).abs();
    int dy = -(y1 - y0).abs();
    int sx = x0 < x1 ? 1 : -1;
    int sy = y0 < y1 ? 1 : -1;
    int err = dx + dy;

    int px = x0;
    int py = y0;
    bool first = true;
    while (true) {
      if (!first) {
        _paintCell(px, py);
      }
      first = false;
      if (px == x1 && py == y1) break;
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
  }

  /// Paint a single brush stamp at grid position (cx, cy).
  void _paintCell(int cx, int cy) {
    final isEraser = selectedElement == El.eraser || selectedElement == El.empty;
    final paintEl = isEraser ? El.empty : selectedElement;

    final grid = simulation.grid;
    final life = simulation.life;
    final velX = simulation.velX;
    final velY = simulation.velY;
    final flags = simulation.flags;
    final gridW = simulation.gridW;

    for (var dy = -brushSize; dy <= brushSize; dy++) {
      for (var dx = -brushSize; dx <= brushSize; dx++) {
        if (dx * dx + dy * dy <= brushSize * brushSize) {
          final nx = simulation.wrapX(cx + dx);
          final ny = cy + dy;
          if (simulation.inBoundsY(ny)) {
            final idx = ny * gridW + nx;
            grid[idx] = paintEl;
            life[idx] = 0;
            velX[idx] = 0;
            velY[idx] = 0;
            simulation.temperature[idx] = 128; // neutral temp
            flags[idx] = simulation.simClock ? 0 : 0x80;
            simulation.markDirty(nx, ny);
            simulation.unsettleNeighbors(nx, ny);
          }
        }
      }
    }
  }

  (int x, int y) screenToGrid(Vector2 screenPos) {
    final cam = game.camera.viewfinder;
    final worldX = screenPos.x / cam.zoom + cam.position.x;
    final worldY = screenPos.y / cam.zoom + cam.position.y;
    return (
      (worldX / cellSize).floor(),
      (worldY / cellSize).floor(),
    );
  }
}
