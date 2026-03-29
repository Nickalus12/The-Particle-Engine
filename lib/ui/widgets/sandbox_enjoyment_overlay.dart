import 'dart:async';

import 'package:flutter/material.dart';

import '../../creatures/colony.dart';
import '../../creatures/colony_events.dart';
import '../../game/particle_engine_game.dart';
import '../theme/colors.dart';

class SandboxEnjoymentOverlay extends StatefulWidget {
  const SandboxEnjoymentOverlay({
    super.key,
    required this.game,
    this.bottomInset = 0,
  });

  final ParticleEngineGame game;
  final double bottomInset;

  @override
  State<SandboxEnjoymentOverlay> createState() =>
      _SandboxEnjoymentOverlayState();
}

class _SandboxEnjoymentOverlayState extends State<SandboxEnjoymentOverlay> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    if (!game.isLoaded || !game.sandboxWorld.isMounted) {
      return const SizedBox.shrink();
    }

    final colonies = game.sandboxWorld.creatures.colonies;
    final creatureSnapshot = game.sandboxWorld.captureCreatureRuntimeSnapshot();
    final placement = game.sandboxWorld.capturePlacementMetricsSnapshot();
    final totalAnts = game.sandboxWorld.creatures.totalAnts;
    final autosaveProgress = game.sandboxWorld.autoSaveProgress;
    final worldLabel = _worldLabel(game);
    final objectives = _buildObjectives(
      game: game,
      colonies: colonies,
      totalAnts: totalAnts,
      placementCells: placement.cellsModifiedTotal,
    );
    final events = _collectEvents(colonies);

    return IgnorePointer(
      ignoring: true,
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 12, 12, widget.bottomInset + 12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 900;
              final columnWidth = compact ? constraints.maxWidth : 340.0;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StatusStrip(
                    key: const ValueKey('sandbox_status_strip'),
                    worldLabel: worldLabel,
                    totalAnts: totalAnts,
                    colonyCount: colonies.length,
                    autosaveProgress: autosaveProgress,
                    isCreationMode: game.isCreationMode,
                    visibleCreatures: creatureSnapshot.populationRendered,
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: compact
                        ? Alignment.topCenter
                        : Alignment.topRight,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: columnWidth),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _ObjectivesPanel(
                            key: const ValueKey('sandbox_objectives_panel'),
                            objectives: objectives,
                          ),
                          const SizedBox(height: 10),
                          _EventFeed(
                            key: const ValueKey('sandbox_event_feed'),
                            events: events,
                            hasColonies: colonies.isNotEmpty,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  List<_OverlayObjective> _buildObjectives({
    required ParticleEngineGame game,
    required List<Colony> colonies,
    required int totalAnts,
    required int placementCells,
  }) {
    final stableColony = colonies.any(
      (colony) => colony.healthState == ColonyHealthState.stable,
    );
    final activeFoodChain = colonies.any(
      (colony) => colony.foodStored >= 24 || colony.antsCarryingFood > 0,
    );
    final largeColony = colonies.any((colony) => colony.population >= 5);

    final objectives = <_OverlayObjective>[
      _OverlayObjective(
        label: 'Found a colony',
        hint: colonies.isEmpty
            ? 'Paint an ant colony into safe terrain.'
            : 'A living colony is active in this world.',
        complete: colonies.isNotEmpty,
      ),
      _OverlayObjective(
        label: 'Shape the terrain',
        hint: placementCells < 60
            ? 'Carve dirt, add water, or create a nest basin.'
            : 'The terrain is ready for more complex reactions.',
        complete: placementCells >= 60,
        progressLabel: '$placementCells / 60 cells',
      ),
      _OverlayObjective(
        label: 'Feed the nest',
        hint: activeFoodChain
            ? 'Food is moving through the colony.'
            : 'Seed nearby organics so foragers can return with resources.',
        complete: activeFoodChain,
      ),
      _OverlayObjective(
        label: 'Grow to 5 ants',
        hint: largeColony
            ? 'The colony has enough workers to sustain itself.'
            : 'Protect the queen and keep food available.',
        complete: largeColony,
        progressLabel: '${totalAnts.clamp(0, 5)} / 5 ants',
      ),
      _OverlayObjective(
        label: 'Stabilize the colony',
        hint: stableColony
            ? 'Population, food, and queen state are holding.'
            : 'Avoid queen loss and prevent starvation.',
        complete: stableColony,
      ),
      _OverlayObjective(
        label: 'Observe the ecosystem',
        hint: game.isCreationMode
            ? 'Exit creation mode to watch the world run on its own.'
            : 'Stay in observation mode and watch the systems evolve.',
        complete: !game.isCreationMode,
      ),
    ];

    objectives.sort((a, b) {
      if (a.complete == b.complete) {
        return a.label.compareTo(b.label);
      }
      return a.complete ? 1 : -1;
    });
    return objectives.take(4).toList(growable: false);
  }

  List<_OverlayEvent> _collectEvents(List<Colony> colonies) {
    final entries = <_OverlayEvent>[];
    for (final colony in colonies) {
      for (final event in colony.events.events) {
        entries.add(
          _OverlayEvent(
            colonyId: colony.id,
            tick: event.tick,
            message: event.message,
            severity: event.severity,
          ),
        );
      }
    }
    entries.sort((a, b) => b.tick.compareTo(a.tick));
    return entries.take(5).toList(growable: false);
  }

  String _worldLabel(ParticleEngineGame game) {
    if (game.loadState != null) {
      return game.worldName?.trim().isNotEmpty == true
          ? game.worldName!.trim()
          : 'Resumed world';
    }
    if (game.isBlankCanvas) {
      return 'Blank canvas';
    }
    if (game.worldName?.trim().isNotEmpty == true) {
      return game.worldName!.trim();
    }
    return 'Generated world';
  }
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({
    super.key,
    required this.worldLabel,
    required this.totalAnts,
    required this.colonyCount,
    required this.autosaveProgress,
    required this.isCreationMode,
    required this.visibleCreatures,
  });

  final String worldLabel;
  final int totalAnts;
  final int colonyCount;
  final double autosaveProgress;
  final bool isCreationMode;
  final int visibleCreatures;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('sandbox_enjoyment_overlay'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.panelDark,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.glassBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x44000000),
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _StatusChip(
            icon: Icons.public_rounded,
            label: worldLabel,
            accent: AppColors.categoryLiquids,
          ),
          _StatusChip(
            icon: Icons.hive_rounded,
            label: '$colonyCount colonies',
            accent: AppColors.categoryLife,
          ),
          _StatusChip(
            icon: Icons.pest_control_rounded,
            label: '$totalAnts ants',
            accent: AppColors.primary,
          ),
          _StatusChip(
            icon: Icons.visibility_rounded,
            label: '$visibleCreatures visible',
            accent: AppColors.accent,
          ),
          _StatusChip(
            icon: isCreationMode
                ? Icons.brush_rounded
                : Icons.remove_red_eye_rounded,
            label: isCreationMode ? 'Creation mode' : 'Observation mode',
            accent: isCreationMode ? AppColors.warning : AppColors.secondary,
          ),
          _StatusChip(
            icon: Icons.save_rounded,
            label: 'Autosave ${(autosaveProgress * 100).round()}%',
            accent: AppColors.success,
          ),
        ],
      ),
    );
  }
}

class _ObjectivesPanel extends StatelessWidget {
  const _ObjectivesPanel({super.key, required this.objectives});

  final List<_OverlayObjective> objectives;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xF01A1522), Color(0xE60E1A1F)],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Active Goals',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Short, readable objectives that turn the sandbox into a story.',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
          for (final objective in objectives) ...[
            _ObjectiveTile(objective: objective),
            if (objective != objectives.last) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _EventFeed extends StatelessWidget {
  const _EventFeed({
    super.key,
    required this.events,
    required this.hasColonies,
  });

  final List<_OverlayEvent> events;
  final bool hasColonies;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        color: const Color(0xE10D1119),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'World Feed',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            hasColonies
                ? 'Recent colony milestones and warnings.'
                : 'Place a colony to begin recording notable events.',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
          if (events.isEmpty)
            const _EmptyFeedHint()
          else
            for (final event in events) ...[
              _EventTile(event: event),
              if (event != events.last) const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.icon,
    required this.label,
    required this.accent,
  });

  final IconData icon;
  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: accent),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ObjectiveTile extends StatelessWidget {
  const _ObjectiveTile({required this.objective});

  final _OverlayObjective objective;

  @override
  Widget build(BuildContext context) {
    final accent = objective.complete ? AppColors.success : AppColors.warning;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x44151E22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.26)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            objective.complete
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded,
            color: accent,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  objective.label,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  objective.hint,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
                if (objective.progressLabel != null) ...[
                  const SizedBox(height: 5),
                  Text(
                    objective.progressLabel!,
                    style: TextStyle(
                      color: accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final _OverlayEvent event;

  @override
  Widget build(BuildContext context) {
    final accent = switch (event.severity) {
      EventSeverity.info => AppColors.categoryLiquids,
      EventSeverity.warning => AppColors.warning,
      EventSeverity.critical => AppColors.danger,
      EventSeverity.milestone => AppColors.success,
    };
    final icon = switch (event.severity) {
      EventSeverity.info => Icons.waves_rounded,
      EventSeverity.warning => Icons.warning_amber_rounded,
      EventSeverity.critical => Icons.priority_high_rounded,
      EventSeverity.milestone => Icons.emoji_events_rounded,
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x3F0D1520),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.24)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Colony ${event.colonyId + 1}',
                  style: TextStyle(
                    color: accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  event.message,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyFeedHint extends StatelessWidget {
  const _EmptyFeedHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x33131A22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: const Text(
        'No live events yet. Once a colony is placed, this feed will call out food delivery, population growth, warnings, and stabilization.',
        style: TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12,
          height: 1.35,
        ),
      ),
    );
  }
}

class _OverlayObjective {
  const _OverlayObjective({
    required this.label,
    required this.hint,
    required this.complete,
    this.progressLabel,
  });

  final String label;
  final String hint;
  final bool complete;
  final String? progressLabel;
}

class _OverlayEvent {
  const _OverlayEvent({
    required this.colonyId,
    required this.tick,
    required this.message,
    required this.severity,
  });

  final int colonyId;
  final int tick;
  final String message;
  final EventSeverity severity;
}
