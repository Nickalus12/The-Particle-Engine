# Isolate Architecture: Simulation Offloading

**Status:** Design Document
**Author:** AI Researcher
**Date:** 2026-03-17
**Purpose:** Move simulation computation off the main (UI) thread to maintain 60fps rendering on mobile with 1000+ neural-brained ants.

---

## 1. Problem Statement

The `SimulationEngine.step()` runs on the main thread. Each step iterates every cell in the grid (320x180 = 57,600 cells), processes element physics, and runs NEAT ant brain forward passes. As ant populations grow to 1000+, each requiring a neural network forward pass plus pathfinding, the simulation tick will exceed the 16ms frame budget at 60fps.

**Current data in SimulationEngine:**
- `grid`: `Uint8List` (57,600 bytes at 320x180)
- `life`: `Uint8List` (57,600 bytes)
- `flags`: `Uint8List` (57,600 bytes)
- `velX`: `Int8List` (57,600 bytes)
- `velY`: `Int8List` (57,600 bytes)
- `pheroFood`: `Uint8List` (57,600 bytes)
- `pheroHome`: `Uint8List` (57,600 bytes)
- `dirtyChunks`/`nextDirtyChunks`: `Uint8List` (~225 bytes each at 20x12 chunks)
- Scalar state: `frameCount`, `gravityDir`, `windForce`, `isNight`, `colonyX/Y`, `rainbowHue`, etc.
- Queues: `pendingExplosions`, `recentExplosions`, `reactionFlashes`

**Total per-frame data:** ~403 KB for a 320x180 grid, ~1.8 MB for a 512x256 grid.

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    MAIN ISOLATE                         │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ Flame Game   │  │  Renderer    │  │  Audio       │  │
│  │ Loop         │  │  Component   │  │  System      │  │
│  │ (60fps)      │  │  (grid draw) │  │              │  │
│  └──────┬───────┘  └──────▲───────┘  └──────────────┘  │
│         │                 │                              │
│         │    ┌────────────┴──────────────┐              │
│         │    │   SimulationBridge        │              │
│         │    │   - Holds render snapshot │              │
│         │    │   - Queues input commands │              │
│         │    │   - Manages isolate comms │              │
│         └────┤                           │              │
│              └────────────┬──────────────┘              │
│                           │                              │
│              SendPort ◄───┼───► ReceivePort              │
└───────────────────────────┼──────────────────────────────┘
                            │
              ══════════════╪══════════════  (isolate boundary)
                            │
┌───────────────────────────┼──────────────────────────────┐
│              ReceivePort ◄┼───► SendPort                 │
│                           │                              │
│  ┌────────────────────────┴─────────────────────────┐   │
│  │          SIMULATION ISOLATE                       │   │
│  │                                                    │   │
│  │  ┌──────────────┐  ┌──────────────┐              │   │
│  │  │ Simulation   │  │ NEAT Colony  │              │   │
│  │  │ Engine       │  │ Manager      │              │   │
│  │  │ (.step())    │  │ (ant brains) │              │   │
│  │  └──────────────┘  └──────────────┘              │   │
│  │                                                    │   │
│  │  ┌──────────────┐  ┌──────────────┐              │   │
│  │  │ Element      │  │ Pheromone    │              │   │
│  │  │ Behaviors    │  │ System       │              │   │
│  │  └──────────────┘  └──────────────┘              │   │
│  │                                                    │   │
│  └──────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
```

### Responsibilities

**Main Isolate:**
- Flame game loop (update/render at 60fps)
- Rendering the grid from the latest snapshot
- Processing user input (taps, drags for element placement)
- Audio playback (triggered by events from simulation)
- UI overlays (HUD, menus, colony inspector)
- Camera control

**Simulation Isolate:**
- `SimulationEngine.step()` execution
- All element behavior simulation (fire, water, sand, etc.)
- NEAT neural network forward passes for all ants
- Pheromone diffusion and decay
- Explosion processing
- Fitness evaluation for NEAT evolution

---

## 3. Data Flow Protocol

### 3.1 Main → Simulation (Input Commands)

The main isolate queues commands and sends them as a batch each frame:

```dart
/// Commands sent from main to simulation isolate.
class SimCommand {
  static const int placeElement = 0;
  static const int clearGrid = 1;
  static const int setGravity = 2;
  static const int setWind = 3;
  static const int shake = 4;
  static const int toggleNight = 5;
  static const int saveSnapshot = 6;
  static const int loadSnapshot = 7;
  static const int resize = 8;
}

/// Lightweight command packet -- no object overhead.
/// Encoded as Int32List: [commandType, param1, param2, param3, ...]
class SimCommandBatch {
  final Int32List commands;  // flat array of encoded commands
  final int count;           // number of commands in batch
}
```

**Element placement** (most common): `[placeElement, x, y, elementType, brushSize]`

Commands are small (< 1 KB per frame typically) so copying overhead is negligible.

### 3.2 Simulation → Main (Render Snapshot)

After each `step()`, the simulation isolate sends back a render-ready snapshot:

```dart
/// Data sent from simulation isolate to main for rendering.
class SimSnapshot {
  // Grid state for rendering
  final Uint8List grid;        // element types (for color lookup)
  final Uint8List life;        // for visual variations (water depth, fire age)

  // Metadata for renderer
  final int frameCount;
  final int rainbowHue;
  final bool isNight;
  final int lightningFlashFrames;

  // Events for audio/particle effects
  final List<ExplosionEvent> explosions;
  final List<ReactionFlash> reactionFlashes;

  // Ant/colony data for UI overlay (colony inspector)
  final int antCount;
  final int colonyX;
  final int colonyY;
  final int colonyGeneration;   // NEAT generation number
  final double colonyFitness;   // best fitness this generation

  // Dirty chunks (so renderer knows what changed)
  final Uint8List dirtyChunks;
}
```

### 3.3 Transfer Strategy

**Option A: Copy (Simple, Safe)**
```dart
// Simulation isolate sends snapshot
sendPort.send(SimSnapshot(
  grid: Uint8List.fromList(engine.grid),  // copy
  life: Uint8List.fromList(engine.life),  // copy
  ...
));
```
- Cost: ~115 KB copy per frame at 320x180 (grid + life)
- At 30 sim fps: ~3.4 MB/sec memory churn
- Acceptable on modern mobile hardware

**Option B: TransferableTypedData (Zero-Copy, Recommended)**
```dart
// Simulation isolate sends snapshot -- zero-copy transfer
final gridTransfer = TransferableTypedData.fromList([engine.grid]);
final lifeTransfer = TransferableTypedData.fromList([engine.life]);

sendPort.send([gridTransfer, lifeTransfer, metadata]);

// IMPORTANT: engine.grid is now invalid in the simulation isolate!
// Must reallocate before next step.
engine.grid = Uint8List(engine.gridW * engine.gridH);
```
- Cost: O(1) transfer -- just moves the memory pointer
- Caveat: The source buffer becomes unusable after transfer
- Requires double-buffering in the simulation isolate

**Option C: Double-Buffer with TransferableTypedData (RECOMMENDED)**
```dart
/// The simulation isolate maintains two sets of buffers.
/// While one is being rendered on the main isolate, the other
/// is being written by the simulation step.

class DoubleBufferedSimulation {
  late Uint8List gridA, gridB;
  late Uint8List lifeA, lifeB;
  bool useA = true;

  Uint8List get activeGrid => useA ? gridA : gridB;
  Uint8List get activeLife => useA ? lifeA : lifeB;

  void step() {
    // Run simulation on active buffers
    engine.grid = activeGrid;
    engine.life = activeLife;
    engine.step(simulateElement);

    // Transfer active buffers to main isolate (zero-copy)
    final gridTransfer = TransferableTypedData.fromList([activeGrid]);
    final lifeTransfer = TransferableTypedData.fromList([activeLife]);
    sendPort.send([gridTransfer, lifeTransfer, metadata]);

    // Swap to other buffer set (already allocated)
    useA = !useA;
    // Note: the "other" buffer still has the PREVIOUS frame's data
    // which is a reasonable starting state for the next simulation step
  }

  void receiveReturnedBuffers(Uint8List returnedGrid, Uint8List returnedLife) {
    // Main isolate returns buffers after rendering
    if (useA) { gridB = returnedGrid; lifeB = returnedLife; }
    else      { gridA = returnedGrid; lifeA = returnedLife; }
  }
}
```

**Recommendation:** Use Option C (double-buffer with TransferableTypedData) for production. Use Option A (copy) for initial implementation due to simplicity.

---

## 4. Simulation Tick Rate vs Render Frame Rate

Decouple simulation from rendering:

```
Main Isolate:  60fps render  ─ F1 ─ F2 ─ F3 ─ F4 ─ F5 ─ F6 ─ ...
                               ▲         ▲         ▲
                               │         │         │
Sim Isolate:   30fps sim   ── S1 ────── S2 ────── S3 ────── ...
```

- **Renderer** always draws from the latest snapshot it received
- **Simulation** runs at its own pace (target: 30fps, adjustable)
- If simulation is slow (complex scene), render still runs at 60fps with the last known state
- If simulation is fast, extra snapshots are dropped (backpressure)

### Implementation with flame_isolate:

```dart
class SimulationManager extends Component with FlameIsolate {
  SimSnapshot? latestSnapshot;

  @override
  BackpressureStrategy get backpressureStrategy =>
    ReplaceBackpressureStrategy();  // Always use latest result, drop stale

  @override
  void update(double dt) {
    // Send commands + request next simulation step
    final commands = collectPendingCommands();
    isolate(_runSimStep, commands).then((snapshot) {
      latestSnapshot = snapshot;
    });
  }
}

// Top-level function required by Dart isolates
SimSnapshot _runSimStep(SimCommandBatch commands) {
  // Apply commands
  for (final cmd in commands) { applyCommand(engine, cmd); }
  // Run simulation
  engine.step(simulateElement);
  // Return snapshot
  return SimSnapshot.from(engine);
}
```

### Alternative: Long-Running Isolate (RECOMMENDED)

Rather than using flame_isolate's per-call model, use a persistent background isolate for lower overhead:

```dart
class SimulationIsolateManager {
  late Isolate _isolate;
  late SendPort _commandPort;
  late ReceivePort _resultPort;

  Future<void> spawn() async {
    _resultPort = ReceivePort();
    _isolate = await Isolate.spawn(
      _simulationLoop,
      _resultPort.sendPort,
    );
    _commandPort = await _resultPort.first as SendPort;

    _resultPort.listen((message) {
      if (message is SimSnapshot) {
        _onSnapshotReceived(message);
      }
    });
  }

  void sendCommands(SimCommandBatch batch) {
    _commandPort.send(batch);
  }

  static void _simulationLoop(SendPort mainPort) {
    final receivePort = ReceivePort();
    mainPort.send(receivePort.sendPort);

    final engine = SimulationEngine();
    // ... initialize engine ...

    receivePort.listen((message) {
      if (message is SimCommandBatch) {
        // Apply commands
        for (final cmd in message.commands) {
          applyCommand(engine, cmd);
        }
        // Step simulation
        engine.step(simulateElement);
        // Send snapshot back
        mainPort.send(SimSnapshot.from(engine));
      }
    });
  }
}
```

**Why a persistent isolate is better than flame_isolate for us:**
- flame_isolate creates a new isolate per component (wasteful for one simulation)
- A persistent isolate keeps the `SimulationEngine` alive across frames (no re-initialization)
- Lower per-frame overhead (no isolate spawn/teardown)
- We control the communication protocol exactly
- flame_isolate is better for fire-and-forget computations, not continuous simulation loops

---

## 5. What Crosses the Isolate Boundary

### Main → Sim (per frame, < 1 KB typically)

| Data | Type | Size | Notes |
|------|------|------|-------|
| Element placement commands | Int32List | ~20-100 bytes | x, y, type, brush size |
| Physics changes | int | 4-8 bytes | gravity, wind |
| Control signals | int | 4 bytes | pause, resume, shake |

### Sim → Main (per sim tick, ~120-200 KB at 320x180)

| Data | Type | Size | Transfer Method |
|------|------|------|----------------|
| `grid` | Uint8List | 57,600 bytes | TransferableTypedData |
| `life` | Uint8List | 57,600 bytes | TransferableTypedData |
| `dirtyChunks` | Uint8List | ~225 bytes | Copy (tiny) |
| Explosions | List | ~100 bytes | Copy |
| Reaction flashes | List | ~200 bytes | Copy |
| Scalars | Map | ~100 bytes | Copy |
| Ant/colony stats | Map | ~200 bytes | Copy |

**Optimization: Only send dirty data.** If dirty chunks cover 30% of the grid, we could send only changed regions. However, the complexity may not be worth it -- 115 KB is small enough for TransferableTypedData zero-copy.

### What does NOT cross the boundary

| Data | Stays In | Reason |
|------|----------|--------|
| `flags` array | Simulation isolate | Internal bookkeeping only |
| `velX`/`velY` arrays | Simulation isolate | Internal physics state |
| `pheroFood`/`pheroHome` | Simulation isolate | AI-internal, not rendered directly |
| NEAT genomes/networks | Simulation isolate | AI-internal |
| Random state | Simulation isolate | Non-determinism is fine |
| Chunk dirty tracking | Simulation isolate | Renderer uses its own dirty tracking |

Exception: `pheroFood`/`pheroHome` may need to cross the boundary IF we want to visualize pheromone trails. In that case, send them as additional TransferableTypedData buffers (~115 KB extra).

---

## 6. Handling 1-Frame Latency

With isolate communication, there is an inherent 1-frame delay:

```
Frame N:   User places sand at (100, 50)
           → Command sent to simulation isolate
Frame N+1: Simulation processes the command, runs step()
           → Snapshot sent back to main isolate
Frame N+2: Renderer displays the sand at (100, 50)
```

**Total latency: 2 frames (~33ms at 60fps)**

### Mitigation Strategies:

**1. Optimistic Local Preview (RECOMMENDED)**
```dart
// Main isolate immediately draws a "ghost" of the placed element
void onElementPlaced(int x, int y, int elementType) {
  // Send command to simulation isolate
  sendCommand(SimCommand.placeElement, x, y, elementType);

  // Immediately mark the cell in the local render buffer
  // (will be overwritten by next snapshot from simulation)
  localPreviewOverlay[y * gridW + x] = elementType;
}

// When snapshot arrives, clear preview overlay
void onSnapshotReceived(SimSnapshot snapshot) {
  latestSnapshot = snapshot;
  localPreviewOverlay.fillRange(0, localPreviewOverlay.length, 0);
}
```

This gives instant visual feedback while the simulation catches up.

**2. Extrapolation (for smooth motion)**
For ants and falling particles, interpolate positions between snapshots:
```dart
// Store previous and current snapshot
SimSnapshot? prevSnapshot;
SimSnapshot? currSnapshot;
double interpolationT = 0.0;

void render(Canvas canvas) {
  // Blend between previous and current ant positions
  // for smooth motion even at 30fps sim rate
  interpolationT += dt * simTickRate;
  for (final ant in currSnapshot.ants) {
    final prevPos = findAntInPrev(ant.id);
    final renderPos = Vector2.lerp(prevPos, ant.pos, interpolationT);
    drawAnt(canvas, renderPos);
  }
}
```

**3. Accept It**
At 30fps simulation, 33ms latency is barely perceptible for a sandbox game. Most players won't notice. The optimistic preview for element placement is the only critical mitigation.

---

## 7. Integration with Flame's Game Loop

```dart
class ParticleEngineGame extends FlameGame {
  late SimulationIsolateManager simManager;
  late GridRendererComponent gridRenderer;
  SimSnapshot? currentSnapshot;

  @override
  Future<void> onLoad() async {
    // Spawn the simulation isolate
    simManager = SimulationIsolateManager();
    await simManager.spawn();

    // Listen for snapshots
    simManager.onSnapshot = (snapshot) {
      currentSnapshot = snapshot;
      gridRenderer.updateFromSnapshot(snapshot);

      // Trigger audio events
      for (final explosion in snapshot.explosions) {
        audioSystem.playExplosion(explosion.x, explosion.y);
      }
    };

    // Add grid renderer as Flame component
    gridRenderer = GridRendererComponent();
    world.add(gridRenderer);
  }

  @override
  void update(double dt) {
    super.update(dt);

    // Flush any pending commands to the simulation isolate
    final commands = inputHandler.flushCommands();
    if (commands.isNotEmpty) {
      simManager.sendCommands(commands);
    }

    // Request next sim step (if not already in flight)
    simManager.requestStep();
  }

  @override
  void onRemove() {
    simManager.dispose();
    super.onRemove();
  }
}
```

### TimerComponent for Simulation Tick Requests

Instead of requesting a sim step every render frame, use a TimerComponent at the desired sim rate:

```dart
class SimTickTimer extends TimerComponent {
  final SimulationIsolateManager simManager;

  SimTickTimer(this.simManager) : super(
    period: 1.0 / 30.0,  // 30 simulation fps
    repeat: true,
    onTick: () => simManager.requestStep(),
  );
}
```

---

## 8. Performance Expectations

### Current (Main Thread)

| Operation | Estimated Time | % of 16ms Budget |
|-----------|---------------|-------------------|
| Grid iteration (57,600 cells) | ~2-4ms | 12-25% |
| Element physics (active cells) | ~2-6ms | 12-37% |
| Ant brain forward pass (100 ants) | ~1-2ms | 6-12% |
| Ant brain forward pass (1000 ants) | ~10-20ms | 62-125% (**OVER BUDGET**) |
| Pheromone diffusion | ~0.5-1ms | 3-6% |
| Grid rendering | ~3-5ms | 18-31% |
| Flame overhead (input, audio, UI) | ~1-2ms | 6-12% |

**At 1000 ants: total ~20-38ms per frame. Unplayable jank.**

### With Isolate Offloading

**Main Isolate (render only):**

| Operation | Estimated Time | % of 16ms Budget |
|-----------|---------------|-------------------|
| Grid rendering from snapshot | ~3-5ms | 18-31% |
| Flame overhead (input, audio, UI) | ~1-2ms | 6-12% |
| Snapshot receive + swap | ~0.1ms | <1% |
| Particle effects (Flame) | ~1-2ms | 6-12% |
| **Total** | **~5-9ms** | **31-56%** |

**Simulation Isolate (computation only):**

| Operation | Estimated Time | Notes |
|-----------|---------------|-------|
| Grid iteration + physics | ~4-10ms | Scales with active cells |
| 1000 ant brain forward passes | ~10-20ms | NEAT networks are tiny |
| Pheromone diffusion | ~0.5-1ms | |
| Snapshot preparation | ~0.2ms | |
| **Total** | **~15-31ms** | Runs at own pace |

**Result:** Main isolate comfortably renders at 60fps. Simulation runs at 30-60fps depending on complexity. If simulation is slow, rendering still stays smooth -- the world just updates less frequently.

**Frame budget saved on main thread: ~60-75%**

### TransferableTypedData vs Copy Benchmarks (estimated)

| Grid Size | Copy Time | TransferableTypedData Time | Savings |
|-----------|-----------|---------------------------|---------|
| 320x180 (115 KB) | ~0.3-0.5ms | ~0.01ms | 30-50x |
| 512x256 (262 KB) | ~0.7-1.0ms | ~0.01ms | 70-100x |
| 1024x512 (1 MB) | ~2-3ms | ~0.01ms | 200-300x |

TransferableTypedData is clearly worth using for grids above 100 KB.

---

## 9. Migration Path

### Phase 1: Abstract the Interface (NOW)
- Create `SimulationBridge` abstract class with `sendCommand()` and `onSnapshot` callback
- Implement `DirectSimulationBridge` that calls `engine.step()` synchronously (current behavior)
- All game code talks to the bridge, not the engine directly
- **Zero risk, pure refactor**

### Phase 2: Implement Isolate Bridge (WHEN NEEDED)
- Create `IsolateSimulationBridge extends SimulationBridge`
- Spawns persistent isolate, handles SendPort/ReceivePort
- Uses copy-based transfer initially
- Add optimistic preview for element placement
- **Feature flag:** `useIsolate: true/false` in game settings

### Phase 3: Optimize Transfer (WHEN PROFILING SHOWS NEED)
- Switch to TransferableTypedData with double-buffering
- Only send dirty regions if full-grid transfer becomes a bottleneck
- Add snapshot interpolation for smooth ant movement
- Profile on low-end devices (target: Snapdragon 600 series)

### Phase 4: Multi-Isolate (FUTURE, IF NEEDED)
- Separate NEAT evolution (generational evaluation) into a third isolate
- Main isolate: render
- Sim isolate: physics + ant behavior (using current-gen brains)
- Evolution isolate: evaluate fitness, breed next generation, send updated genomes to sim isolate
- Only needed if NEAT evolution itself becomes a bottleneck

---

## 10. flame_isolate vs Custom Isolate

### When to Use flame_isolate:
- Quick prototyping
- Fire-and-forget computations (pathfinding queries, world generation)
- When you want Flame to manage isolate lifecycle automatically

### When to Use Custom Persistent Isolate (OUR CASE):
- Continuous simulation loop that maintains state across frames
- Complex bidirectional communication protocol
- Need control over backpressure and timing
- SimulationEngine has significant state that shouldn't be reconstructed each frame

### Hybrid Approach:
- Use **custom persistent isolate** for the main simulation loop
- Use **flame_isolate** for one-off heavy computations:
  - World generation (`FlameIsolate` on the WorldGenerator component)
  - Save/load serialization
  - NEAT genome import/export

---

## 11. Key Risks and Considerations

1. **No shared memory in Dart isolates.** Every piece of data must be explicitly sent. Design the snapshot to be minimal.

2. **TransferableTypedData invalidates the source.** Must use double-buffering to avoid accessing freed memory.

3. **Isolate startup cost.** Spawning an isolate takes ~50-200ms. Do it during loading screen, not during gameplay.

4. **Debugging complexity.** Isolate errors don't show in the main thread's stack trace. Use structured error handling with try/catch in the isolate and send errors back as messages.

5. **Hot reload limitations.** Dart hot reload doesn't update code in spawned isolates. Must kill and respawn the isolate during development.

6. **Platform differences.** Web (dart2js) does not support isolates -- falls back to Web Workers with different semantics. For web builds, use `DirectSimulationBridge` (synchronous) or `compute()`.

7. **Random state.** Each isolate has its own `Random` instance. Simulation randomness won't be reproducible across isolate boundaries (acceptable for our use case).

---

## 12. Summary

| Aspect | Decision |
|--------|----------|
| Architecture | Persistent background isolate for simulation |
| Transfer method | TransferableTypedData with double-buffering (Phase 3), copy initially (Phase 2) |
| Sim rate | 30fps independent of render rate |
| Latency mitigation | Optimistic local preview for element placement |
| Package | Custom isolate management, flame_isolate for one-off tasks |
| Migration | Abstraction layer first, isolate behind feature flag |
| When to implement | When ant count exceeds ~200 on target hardware, or when profiling shows main thread > 14ms |
