# Task Plan: Physics + Worldgen + Optuna Improvement Plan

## Goal
Implement a large mobile-performance and rendering optimization pass that improves frame pacing, reduces overdraw and unnecessary render work, strengthens mobile-focused runtime controls, and expands performance/testing coverage without changing the game's core UX.

## Current Phase
Phase 2

## Phases

### Phase 1: Requirements & Discovery
- [x] Understand user intent
- [x] Identify constraints and requirements
- [x] Document findings in findings.md
- **Status:** complete

### Phase 2: Planning & Structure
- [x] Define technical approach
- [x] Identify first implementation slice
- [x] Document decisions with rationale
- **Status:** complete

### Phase 3: Implementation
- [x] Add physics phase scheduling + telemetry contracts
- [x] Add worldgen staged summary + validation artifacts
- [x] Extend perf pipeline, OTLP export, and quality scoring
- [x] Add/update tests for contracts and scoring
- **Status:** complete

### Phase 4: Testing & Verification
- [x] Run format/analyze/tests on changed areas
- [x] Record command evidence in progress.md
- [x] Fix any issues found
- **Status:** complete

### Phase 5: Delivery
- [ ] Review touched files and remaining gaps
- [ ] Summarize implemented slice and follow-up opportunities
- [ ] Deliver to user with evidence-based status
- **Status:** in_progress

### Phase 6: Optuna Systemization
- [x] Replace duplicated search spaces with manifest-driven surfaces
- [x] Add scheduler-focused Optuna variables and runtime wiring
- [x] Add search-space metadata (`step`, `log`, profile-aware selection)
- [x] Persist study/trial-config Optuna metadata for downstream tooling
- [x] Extend contract tests for profile/search-space behavior
- **Status:** complete

### Phase 7: Optuna-to-Quality Integration
- [x] Add profile-aware benchmark weighting and Optuna metadata ingestion
- [x] Persist Optuna context into performance run artifacts and quality context
- [x] Export bounded Optuna labels through OTLP metrics
- [x] Add/update contract tests for benchmark, perf pipeline, quality pipeline, and OTLP export
- **Status:** complete

### Phase 8: Mobile Rendering Performance Pass
- [x] Audit current render path and mobile runtime controls
- [x] Reduce draw cost/overdraw in sandbox and creature rendering
- [x] Add mobile-focused perf telemetry and regression tests
- [x] Verify with analyze/tests and document remaining hotspots
- **Status:** complete

### Phase 9: Enjoyment Layer
- [x] Surface live sandbox status and short-term goals
- [x] Expose colony events through a player-facing world feed
- [x] Keep the new UX mobile-safe and non-blocking
- [x] Add smoke coverage for the new enjoyment overlay
- **Status:** complete

### Phase 10: Hazard Storytelling
- [ ] Surface non-colony world events such as ignition, flooding, cave instability, and runaway reactions
- [ ] Add a world-level event aggregator so the feed can mix colony and environmental events coherently
- [ ] Add bounded telemetry/artifacts for high-severity world events
- [ ] Add smoke/contract coverage for event aggregation and presentation
- **Status:** pending

### Phase 11: Preset Identity and Scenarios
- [ ] Add preset-specific objective sets for `meadow`, `canyon`, `island`, `underground`, and `random`
- [ ] Add distinct “story prompts” and survival guidance per preset
- [ ] Tune world-specific challenge pressure so presets feel mechanically different, not just visually different
- [ ] Add regression tests for preset objective selection and scenario text
- **Status:** pending

### Phase 12: Colony Focus and Selection
- [ ] Add proper colony selection instead of always showing the first colony in the inspector/feed
- [ ] Sync selected-colony focus between inspector, event feed emphasis, and any future minimap/director interactions
- [ ] Add mobile-safe affordances for focusing a colony without blocking painting
- [ ] Add smoke tests for colony selection and inspector targeting
- **Status:** pending

### Phase 13: Smart Mobile UX
- [ ] Add a compact/expanded enjoyment overlay mode for smaller devices
- [ ] Add contextual quick actions such as `Inspect Colony`, `Enter Creation`, and `Observe`
- [ ] Reserve viewport-safe HUD regions explicitly in hit-testing so future UI additions cannot regress painting
- [ ] Add end-to-end mobile HUD stress tests for overlay density and gesture safety
- **Status:** pending

### Phase 14: Delight and Discovery
- [ ] Add a discovery log/codex for first-seen reactions, species behavior, and milestone events
- [ ] Add more expressive spectacle hooks for major events with restrained, performant visuals
- [ ] Add session recap/history summaries so worlds feel persistent across runs
- [ ] Add tests for discovery unlocks and session-history generation
- **Status:** pending

## Key Questions
1. What is the smallest implementation slice that materially advances the whole plan without destabilizing the engine? (Phase telemetry + worldgen summaries + pipeline/quality hooks)
2. Where can we add observability contracts with minimal gameplay risk? (new typed snapshots/artifacts and additive metrics)
3. Which parts need true refactors now versus safe wrappers around current behavior? (step cadence and worldgen generation pipeline get wrappers first)

## Decisions Made
| Decision | Rationale |
|----------|-----------|
| Start with additive telemetry/summaries instead of a full engine rewrite | Delivers measurable value quickly and lowers regression risk |
| Keep current preset UX unchanged | Matches user plan and avoids product-surface churn |
| Extend existing performance/quality pipeline artifacts rather than replacing them | Preserves current CI/Grafana foundation |
| Treat phase scheduling as centralized config before deeper behavior extraction | Creates a stable seam for later refactors |
| Use manifest-backed Optuna surfaces with profile filtering instead of duplicated per-script search spaces | Keeps local/cloud optimizers aligned and easier to evolve |
| Persist Optuna metadata into trial configs/studies | Makes downstream debugging, benchmarking, and telemetry attribution tractable |
| Let benchmark scoring weights vary by Optuna profile (`balanced`, `mobile`, `exploratory`) | Makes benchmark totals reflect optimization intent instead of forcing one static worldview |
| Teach perf/quality ingestion to discover `trial_config.json` automatically | Keeps run attribution low-friction in CI and research workflows |
| Prioritize render-path optimizations before deeper simulation changes in this pass | The user asked specifically for mobile performance and rendering, and these are likely the most visible wins |
| Follow the enjoyment layer with hazard storytelling and preset identity work | The new overlay becomes much more valuable when it reflects world drama and scenario-specific goals |
| Treat colony selection as a product feature, not just an inspector bugfix | Many enjoyment features become dramatically more useful once the player can intentionally focus a colony |

## Errors Encountered
| Error | Attempt | Resolution |
|-------|---------|------------|
| `rg` unavailable in environment | 1 | Used PowerShell `Get-ChildItem`/`Select-String` and direct file reads instead |
| `python` unavailable in environment | 1 | Deferred Python test execution; continue with code changes and Dart-side verification |
| Dart test output truncated to runner header | 1 | Use command exit behavior where available and report limitation explicitly |
| Direct shell `dart` invocation broken even though Dart MCP tools work | 1 | Use Dart MCP format/analyze instead of shell execution |

## Notes
- Re-read this file before making structural changes.
- Keep edits additive where possible for this first slice.
- Do not claim verification success without fresh command evidence.
