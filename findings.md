# Findings

- `home_screen.dart` has already been rebuilt into a cinematic live-sim menu and currently analyzes/tests clean.
- Current world generation code lives under `lib/simulation/world_gen/` with `world_config.dart`, `terrain_generator.dart`, `feature_placer.dart`, and `world_generator.dart` as core files.
- The generator was still mostly preset detection from scalar thresholds plus post-placement heuristics; hydrology was fragmented between depression fill, meadow streams, island ocean fill, canyon river, and waterfall passes.
- `SandboxWorld` already respects runtime grid dimensions by `copyWith(width,height)` before generation, so the right place to improve shape/composition is the worldgen pipeline itself.
- There was almost no direct test coverage for world generation behavior beyond a smoke test that dimensions are preserved.
- The previous `_removeFloatingWater` cleanup removed valid lakes and island oceans because it treated any water above the terrain column as invalid. The cleanup now preserves connected bodies and only strips unsupported narrow strands.
- Terrain generation now includes basin-friendly height synthesis, smoothing, hydrology basin carving, and slope/wetness-aware soil layering.
- Water placement now adds connected river corridors and shoreline refinement, and vegetation respects slope/fertility better.
