/// Base class for all evaluation environments.
///
/// An environment defines:
/// - A world layout (via [WorldConfig] or custom grid setup).
/// - Where to place the colony.
/// - Any additional grid modifications (food placement, hazards, etc.).
/// - Metadata (name, difficulty).
///
/// Implementations must be deterministic: same config -> same world.
library;

import 'package:the_particle_engine/simulation/simulation_engine.dart';
import 'package:the_particle_engine/simulation/world_gen/world_config.dart';

/// Difficulty rating for an evaluation environment.
enum Difficulty { easy, medium, hard }

/// Abstract base for evaluation environments.
abstract class Environment {
  /// Human-readable environment name.
  String get name;

  /// Difficulty rating.
  Difficulty get difficulty;

  /// World generation config.
  WorldConfig get worldConfig;

  /// Whether to use a blank world instead of procedural generation.
  bool get useBlankWorld => false;

  /// Colony origin position (x, y) on walkable ground.
  (int, int) get colonyOrigin;

  /// Additional colony positions for multi-colony environments.
  /// Empty by default.
  List<(int, int)> get extraColonies => const [];

  /// Called after world generation to apply environment-specific
  /// grid modifications (e.g. placing food, adding hazards).
  ///
  /// Override this to customize the world beyond what WorldConfig provides.
  void modifyGrid(SimulationEngine engine) {}

  /// Minimum food count that should be within [foodRadius] of the nest.
  /// Used for validation only.
  int get minimumFoodNearNest => 5;

  /// Radius around nest to check for minimum food.
  int get foodRadius => 30;
}
