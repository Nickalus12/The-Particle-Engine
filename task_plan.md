# Task Plan

## Goal
Improve the main menu simulation/animation further and overhaul procedural world generation so worlds have stronger terrain composition, hydrology structure, and more visually coherent biome identity.

## Phases
- [completed] Inspect current world generation, world creation flow, and menu showcase dependencies.
- [completed] Design upgraded terrain/worldgen model and identify safe code changes.
- [completed] Implement world generation improvements.
- [completed] Implement additional main menu showcase improvements tied to the new worldgen feel.
- [completed] Add or expand tests for worldgen/menu behavior.
- [completed] Run analysis/tests and summarize outcomes.

## Errors Encountered
| Error | Attempt | Resolution |
|-------|---------|------------|
| `home_screen.dart` left partially written from previous turn | 1 | Replaced file fully and re-verified with analysis/tests before proceeding |
| Worldgen verification failed because valid lakes/oceans were being stripped by `_removeFloatingWater` | 1 | Reworked cleanup to only remove unsupported narrow water strands instead of deleting supported water bodies |
