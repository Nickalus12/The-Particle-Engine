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
  _OverlayEvent? _latestEvent;
  int _lastEventTick = -1;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) {
        _checkForNewEvents();
        setState(() {});
      }
    });
  }

  void _checkForNewEvents() {
    final colonies = widget.game.sandboxWorld.creatures.colonies;
    _OverlayEvent? newest;
    for (final colony in colonies) {
      for (final event in colony.events.events) {
        if (event.tick > _lastEventTick) {
          if (newest == null || event.tick > newest.tick) {
            newest = _OverlayEvent(
              colonyId: colony.id,
              tick: event.tick,
              message: event.message,
              severity: event.severity,
            );
          }
        }
      }
    }
    if (newest != null) {
      _latestEvent = newest;
      _lastEventTick = newest.tick;
    }
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
    final totalAnts = game.sandboxWorld.creatures.totalAnts;
    final placement = game.sandboxWorld.capturePlacementMetricsSnapshot();
    final objectives = _buildObjectives(
      game: game,
      colonies: colonies,
      totalAnts: totalAnts,
      placementCells: placement.cellsModifiedTotal,
    );
    final completedCount = objectives.where((o) => o.complete).length;

    return IgnorePointer(
      ignoring: true,
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 12, 12, widget.bottomInset + 12),
          child: Stack(
            children: [
              // Compact status pill — top-left, away from back button
              Positioned(
                top: 0,
                left: 0,
                child: _CompactStatusPill(
                  worldLabel: _worldLabel(game),
                  isCreationMode: game.isCreationMode,
                  totalAnts: totalAnts,
                  colonyCount: colonies.length,
                ),
              ),
              // Goals progress — small indicator below status pill
              if (objectives.isNotEmpty)
                Positioned(
                  top: 40,
                  left: 0,
                  child: _GoalsIndicator(
                    completed: completedCount,
                    total: objectives.length,
                  ),
                ),
              // Event toast — bottom-left, fades in/out for latest event
              if (_latestEvent != null)
                Positioned(
                  bottom: 0,
                  left: 0,
                  child: _EventToast(event: _latestEvent!),
                ),
            ],
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

    return [
      _OverlayObjective(
        label: 'Found a colony',
        complete: colonies.isNotEmpty,
      ),
      _OverlayObjective(
        label: 'Shape terrain',
        complete: placementCells >= 60,
      ),
      _OverlayObjective(
        label: 'Feed the nest',
        complete: activeFoodChain,
      ),
      _OverlayObjective(
        label: 'Grow to 5 ants',
        complete: largeColony,
      ),
      _OverlayObjective(
        label: 'Stabilize colony',
        complete: stableColony,
      ),
      _OverlayObjective(
        label: 'Observe ecosystem',
        complete: !game.isCreationMode,
      ),
    ];
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

/// Tiny status pill showing world name + mode. Sits in top-left.
class _CompactStatusPill extends StatelessWidget {
  const _CompactStatusPill({
    required this.worldLabel,
    required this.isCreationMode,
    required this.totalAnts,
    required this.colonyCount,
  });

  final String worldLabel;
  final bool isCreationMode;
  final int totalAnts;
  final int colonyCount;

  @override
  Widget build(BuildContext context) {
    final modeColor =
        isCreationMode ? AppColors.warning : AppColors.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xAA0A0A14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: modeColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            worldLabel,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (colonyCount > 0) ...[
            const SizedBox(width: 8),
            Text(
              '$totalAnts ants',
              style: TextStyle(
                color: AppColors.textSecondary.withValues(alpha: 0.7),
                fontSize: 10,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Small progress dot-row showing goal completion.
class _GoalsIndicator extends StatelessWidget {
  const _GoalsIndicator({required this.completed, required this.total});

  final int completed;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0x880A0A14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < total; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: i < completed
                    ? AppColors.success
                    : AppColors.textSecondary.withValues(alpha: 0.3),
                shape: BoxShape.circle,
              ),
            ),
          ],
          const SizedBox(width: 6),
          Text(
            '$completed/$total',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 9,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small toast that shows the latest colony event, bottom-left.
class _EventToast extends StatelessWidget {
  const _EventToast({required this.event});

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
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xAA0A0A14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: accent),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              event.message,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
                height: 1.2,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _OverlayObjective {
  const _OverlayObjective({required this.label, required this.complete});

  final String label;
  final bool complete;
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
