import 'dart:math';

import 'package:flame/components.dart';
import 'package:flame/events.dart';

import '../game/components/sandbox_component.dart';
import '../simulation/element_registry.dart';

/// Translates raw input events into sandbox actions (paint, erase, inspect).
///
/// This component sits in the world alongside [SandboxComponent] and delegates
/// processed events to the sandbox. It owns the concept of "current tool"
/// (brush, eraser, picker) and brush size.
///
/// Supports multiple brush modes:
/// - Circle brush (sizes 1, 3, 5)
/// - Line mode (Bresenham algorithm)
/// - Spray mode (40% random fill)
///
/// Also manages an undo system (10 snapshots deep) and long-press burst
/// placement.
class SandboxInputHandler extends Component with TapCallbacks, DragCallbacks {
  SandboxInputHandler({required this.sandbox});

  final SandboxComponent sandbox;

  /// The tool currently selected: paint, erase, or pick.
  SandboxTool activeTool = SandboxTool.paint;

  /// Element used when [activeTool] is [SandboxTool.paint].
  /// Uses int element IDs from [El].
  int brushElement = El.sand;

  /// Current brush mode.
  BrushMode brushMode = BrushMode.circle;

  /// Current brush size (radius in grid cells). Valid: 1, 3, 5.
  int brushSize = 3;

  /// Last drawn grid position, used for Bresenham line mode.
  (int, int)? _lastGridPos;

  /// Whether a long press is active (burst placement).
  bool _burstActive = false;
  Vector2? _burstPosition;

  // -- Undo system ------------------------------------------------------------

  static const int _maxUndoSnapshots = 10;
  final List<Map<String, dynamic>> _undoStack = [];

  final Random _rng = Random();

  /// Cell size derived from the sandbox component.
  double get _cellSize => sandbox.cellSize;

  // ---------------------------------------------------------------------------
  // Brush size cycling
  // ---------------------------------------------------------------------------

  /// Cycle brush size between 1, 3, and 5.
  void cycleBrushSize() {
    brushSize = switch (brushSize) {
      1 => 3,
      3 => 5,
      _ => 1,
    };
    sandbox.brushSize = brushSize;
  }

  // ---------------------------------------------------------------------------
  // Undo
  // ---------------------------------------------------------------------------

  /// Save a snapshot of the current grid state for undo.
  void saveUndoSnapshot() {
    if (_undoStack.length >= _maxUndoSnapshots) {
      _undoStack.removeAt(0);
    }
    _undoStack.add(sandbox.simulation.captureSnapshot());
  }

  /// Restore the most recent undo snapshot.
  bool undo() {
    if (_undoStack.isEmpty) return false;
    final snapshot = _undoStack.removeLast();
    sandbox.simulation.restoreSnapshot(snapshot);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Input handling
  // ---------------------------------------------------------------------------

  @override
  void onTapDown(TapDownEvent event) {
    saveUndoSnapshot();
    _lastGridPos = null;
    _handleInput(event.localPosition);
  }

  @override
  void onDragStart(DragStartEvent event) {
    super.onDragStart(event);
    saveUndoSnapshot();
    _lastGridPos = null;
  }

  @override
  void onDragUpdate(DragUpdateEvent event) {
    super.onDragUpdate(event);
    _handleInput(event.localStartPosition + event.localDelta);
  }

  @override
  void onDragEnd(DragEndEvent event) {
    super.onDragEnd(event);
    _lastGridPos = null;
    _burstActive = false;
    _burstPosition = null;
  }

  @override
  void update(double dt) {
    super.update(dt);

    // Burst placement: continuously paint while long-press is held.
    if (_burstActive && _burstPosition != null) {
      _applyBrush(_burstPosition!);
    }
  }

  /// Start burst mode at a position (called on long press).
  void startBurst(Vector2 position) {
    _burstActive = true;
    _burstPosition = position;
    saveUndoSnapshot();
  }

  /// Stop burst mode.
  void stopBurst() {
    _burstActive = false;
    _burstPosition = null;
  }

  void _handleInput(Vector2 position) {
    switch (activeTool) {
      case SandboxTool.paint:
        sandbox.selectedElement = brushElement;
        _applyBrush(position);
      case SandboxTool.erase:
        sandbox.selectedElement = El.empty;
        _applyBrush(position);
      case SandboxTool.pick:
        // Read the element under the cursor.
        break;
    }
  }

  void _applyBrush(Vector2 position) {
    final cx = (position.x / _cellSize).floor();
    final cy = (position.y / _cellSize).floor();

    switch (brushMode) {
      case BrushMode.circle:
        _paintCircle(cx, cy);
      case BrushMode.line:
        _paintLine(cx, cy);
      case BrushMode.spray:
        _paintSpray(cx, cy);
    }
  }

  /// Resolve the eraser sentinel to El.empty.
  int _resolveElement(int element) =>
      (element == El.eraser) ? El.empty : element;

  /// Set a single cell, resetting all auxiliary data.
  void _setCell(int nx, int ny, int element) {
    final sim = sandbox.simulation;
    nx = sim.wrapX(nx);
    if (!sim.inBoundsY(ny)) return;
    final idx = ny * sim.gridW + nx;
    sim.grid[idx] = element;
    sim.life[idx] = 0;
    sim.velX[idx] = 0;
    sim.velY[idx] = 0;
    sim.flags[idx] = 0;
    sim.markDirty(nx, ny);
    sim.unsettleNeighbors(nx, ny);
  }

  /// Circle brush: paint all cells within radius.
  void _paintCircle(int cx, int cy) {
    final element = _resolveElement(sandbox.selectedElement);
    for (var dy = -brushSize; dy <= brushSize; dy++) {
      for (var dx = -brushSize; dx <= brushSize; dx++) {
        if (dx * dx + dy * dy <= brushSize * brushSize) {
          _setCell(cx + dx, cy + dy, element);
        }
      }
    }
    _lastGridPos = (cx, cy);
  }

  /// Line mode using Bresenham's algorithm between last and current position.
  void _paintLine(int cx, int cy) {
    final element = _resolveElement(sandbox.selectedElement);

    if (_lastGridPos == null) {
      _setCell(cx, cy, element);
      _lastGridPos = (cx, cy);
      return;
    }

    final (lx, ly) = _lastGridPos!;
    _bresenham(lx, ly, cx, cy, (x, y) {
      _setCell(x, y, element);
    });
    _lastGridPos = (cx, cy);
  }

  /// Spray mode: 40% random fill within brush radius.
  void _paintSpray(int cx, int cy) {
    final element = _resolveElement(sandbox.selectedElement);
    for (var dy = -brushSize; dy <= brushSize; dy++) {
      for (var dx = -brushSize; dx <= brushSize; dx++) {
        if (dx * dx + dy * dy <= brushSize * brushSize) {
          if (_rng.nextDouble() < 0.4) {
            _setCell(cx + dx, cy + dy, element);
          }
        }
      }
    }
    _lastGridPos = (cx, cy);
  }

  /// Bresenham line algorithm.
  static void _bresenham(
    int x0,
    int y0,
    int x1,
    int y1,
    void Function(int x, int y) plot,
  ) {
    var dx = (x1 - x0).abs();
    var dy = -(y1 - y0).abs();
    final sx = x0 < x1 ? 1 : -1;
    final sy = y0 < y1 ? 1 : -1;
    var err = dx + dy;

    var x = x0;
    var y = y0;

    while (true) {
      plot(x, y);
      if (x == x1 && y == y1) break;
      final e2 = 2 * err;
      if (e2 >= dy) {
        if (x == x1) break;
        err += dy;
        x += sx;
      }
      if (e2 <= dx) {
        if (y == y1) break;
        err += dx;
        y += sy;
      }
    }
  }
}

/// Available interaction tools.
enum SandboxTool { paint, erase, pick }

/// Available brush modes.
enum BrushMode { circle, line, spray }
