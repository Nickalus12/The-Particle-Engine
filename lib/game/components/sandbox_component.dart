import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/events.dart';

import '../../rendering/gi_post_process.dart';
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
    renderer.viewportY = game.camera.viewfinder.position.y / cellSize;

    renderer.tickMicroParticles();

    renderer.renderPixels();

    if (!_decoding) {
      if (_frameBudgetSkips > 0) {
        _frameBudgetSkips--;
      } else {
        _decoding = true;
        renderer.buildImage().then((image) async {
          final baseImage = image as ui.Image;
          // Run GI post-process pipeline on the base image.
          final GIPostProcess gi = game.sandboxWorld.giPostProcess;
          gi.dayNightT = game.dayNightTransition;
          final processed = await gi.process(baseImage);
          if (processed != baseImage) {
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

    canvas.save();
    canvas.scale(cellSize, cellSize);
    // Draw 3 copies for seamless horizontal wrapping.
    // The camera wraps its X position, so when near the edge the
    // adjacent copy becomes visible through Flame's normal clipping.
    canvas.drawImage(image, ui.Offset(-worldW, 0), _imagePaint);
    canvas.drawImage(image, ui.Offset.zero, _imagePaint);
    canvas.drawImage(image, ui.Offset(worldW, 0), _imagePaint);
    canvas.restore();
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
    // Convert local position to grid coords, wrapping X.
    final rawX = (position.x / cellSize).floor();
    final cx = simulation.wrapX(rawX);
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

    int px = x0;
    int py = y0;
    bool first = true;
    while (true) {
      if (!first) {
        _paintCell(simulation.wrapX(px), py);
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
  }

  /// Paint a single brush stamp at grid position (cx, cy).
  void _paintCell(int cx, int cy) {
    final isEraser = selectedElement == El.eraser || selectedElement == El.empty;
    final paintEl = isEraser ? El.empty : selectedElement;

    final grid = simulation.grid;
    final gridW = simulation.gridW;

    for (var dy = -brushSize; dy <= brushSize; dy++) {
      for (var dx = -brushSize; dx <= brushSize; dx++) {
        if (dx * dx + dy * dy <= brushSize * brushSize) {
          final nx = simulation.wrapX(cx + dx);
          final ny = cy + dy;
          if (simulation.inBoundsY(ny)) {
            final idx = ny * gridW + nx;
            simulation.clearCell(idx);
            grid[idx] = paintEl;
            // Initialize mass from element base mass
            if (paintEl != El.empty) {
              simulation.mass[idx] = elementBaseMass[paintEl];
            }
            // Clock bit: match current simClock so the NEXT step
            // (which flips simClock) will process this cell.
            simulation.flags[idx] = simulation.simClock ? 0x80 : 0;
            simulation.markDirty(nx, ny);
            simulation.unsettleNeighbors(nx, ny);
          }
        }
      }
    }

    // Ant placement: instead of painting a blob of El.ant cells (which creates
    // dozens of grid-based ants that each run neural networks and freeze the game),
    // place a SINGLE colony at the tap position. The colony spawns entity-based
    // ants naturally from its food stores. Much more performant and realistic.
    if (paintEl == El.ant) {
      // Undo the grid painting — don't fill cells with El.ant
      for (var dy2 = -brushSize; dy2 <= brushSize; dy2++) {
        for (var dx2 = -brushSize; dx2 <= brushSize; dx2++) {
          if (dx2 * dx2 + dy2 * dy2 <= brushSize * brushSize) {
            final nx2 = simulation.wrapX(cx + dx2);
            final ny2 = cy + dy2;
            if (simulation.inBoundsY(ny2)) {
              final idx2 = ny2 * gridW + nx2;
              if (grid[idx2] == El.ant) {
                simulation.clearCell(idx2);
              }
            }
          }
        }
      }
      // Find the ground surface below the tap point — colony should land on terrain
      var nestY = cy;
      for (var scanY = cy; scanY < simulation.gridH - 1; scanY++) {
        final belowIdx = (scanY + 1) * gridW + simulation.wrapX(cx);
        final belowEl = grid[belowIdx];
        // Found solid ground: place colony on the surface
        if (belowEl != El.empty && belowEl != El.smoke && belowEl != El.steam &&
            belowEl != El.oxygen && belowEl != El.hydrogen && belowEl != El.co2) {
          nestY = scanY;
          break;
        }
        // Reached bottom of world
        if (scanY == simulation.gridH - 2) {
          nestY = scanY;
        }
      }

      // Clear a small 3x3 area around the colony origin for ant spawning
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
            }
          }
        }
      }
      // Spawn colony at the ground surface position
      final world = game.sandboxWorld;
      world.spawnColony(cxNest, cyNest);
      return; // Don't process further
    }
  }

  (int x, int y) screenToGrid(Vector2 screenPos) {
    final cam = game.camera.viewfinder;
    final worldX = screenPos.x / cam.zoom + cam.position.x;
    final worldY = screenPos.y / cam.zoom + cam.position.y;
    return (
      simulation.wrapX((worldX / cellSize).floor()),
      (worldY / cellSize).floor(),
    );
  }
}
