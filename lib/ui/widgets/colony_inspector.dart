import 'dart:math';

import 'package:flutter/material.dart';

import '../../creatures/ant.dart';
import '../../creatures/colony.dart';
import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';
import 'hud_icon_badge.dart';

/// Slide-in panel showing colony details when tapping on an ant colony.
///
/// Displays colony name, ant count, personality traits (role distribution),
/// food stores, territory size, and a simple neural activity visualization.
/// Slides in from the left side with glassmorphism styling.
class ColonyInspector extends StatefulWidget {
  const ColonyInspector({
    super.key,
    required this.colony,
    this.onClose,
  });

  final Colony colony;
  final VoidCallback? onClose;

  @override
  State<ColonyInspector> createState() => _ColonyInspectorState();
}

class _ColonyInspectorState extends State<ColonyInspector>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slideController;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      vsync: this,
      duration: ParticleTheme.normalDuration,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(-1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: ParticleTheme.defaultCurve,
    ));
    _fadeAnimation = CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOut,
    );
    _slideController.forward();
  }

  @override
  void dispose() {
    _slideController.dispose();
    super.dispose();
  }

  void _close() async {
    await _slideController.reverse();
    widget.onClose?.call();
  }

  /// Format tick count into human-readable time.
  String _formatAge(int ticks) {
    final seconds = ticks ~/ 60;
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    final remainSeconds = seconds % 60;
    return '${minutes}m ${remainSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    final colony = widget.colony;
    final roles = colony.roleDistribution;
    final accent = colony.isAlive ? AppColors.categoryLife : AppColors.danger;

    return SlideTransition(
      position: _slideAnimation,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 130, top: 40, bottom: 40),
            child: ParticleTheme.atmosphericPanel(
              accent: accent,
              borderRadius: ParticleTheme.radiusLarge,
              blurAmount: 24,
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: 246,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Colony ${colony.id + 1}',
                                  style: AppTypography.heading.copyWith(
                                    fontSize: 18,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  colony.isAlive
                                      ? 'Active hive intelligence'
                                      : 'Dormant colony record',
                                  style: AppTypography.caption.copyWith(
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          HudIconBadge(
                            icon: Icons.close_rounded,
                            onTap: _close,
                            tooltip: 'Close colony inspector',
                            accent: accent,
                            motif: HudBadgeMotif.orbit,
                            size: 36,
                            iconSize: 18,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _InfoChip(
                            label: colony.isAlive ? 'Alive' : 'Collapsed',
                            accent: accent,
                            icon: colony.isAlive
                                ? Icons.bolt_rounded
                                : Icons.pause_circle_rounded,
                          ),
                          _InfoChip(
                            label: colony.hasQueen ? 'Queenline' : 'Queen lost',
                            accent: colony.hasQueen
                                ? AppColors.categoryEnergy
                                : AppColors.danger,
                            icon: Icons.stars_rounded,
                          ),
                          _InfoChip(
                            label: '${colony.population} ants',
                            accent: AppColors.categoryLife,
                            icon: Icons.groups_rounded,
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                        // Core stats
                        _StatRow(
                          icon: Icons.groups_rounded,
                          label: 'Population',
                          value: '${colony.population}',
                        ),
                        _StatRow(
                          icon: Icons.restaurant_rounded,
                          label: 'Food Stores',
                          value: '${colony.foodStored}',
                          valueColor: colony.foodStored < 10
                              ? AppColors.danger
                              : null,
                        ),
                        _StatRow(
                          icon: Icons.schedule_rounded,
                          label: 'Age',
                          value: _formatAge(colony.ageTicks),
                        ),
                        _StatRow(
                          icon: Icons.local_shipping_rounded,
                          label: 'Carrying Food',
                          value: '${colony.antsCarryingFood}',
                        ),
                        _StatRow(
                          icon: Icons.terrain_rounded,
                          label: 'Territory',
                          value: '${colony.nestChambers.length} cells',
                        ),
                        _StatRow(
                          icon: Icons.place_rounded,
                          label: 'Nest',
                          value: '(${colony.originX}, ${colony.originY})',
                        ),

                        const SizedBox(height: 12),

                        // Lifetime stats
                        _SectionLabel('LIFETIME'),
                        const SizedBox(height: 6),
                        _StatRow(
                          icon: Icons.add_circle_outline_rounded,
                          label: 'Spawned',
                          value: '${colony.totalSpawned}',
                        ),
                        _StatRow(
                          icon: Icons.remove_circle_outline_rounded,
                          label: 'Died',
                          value: '${colony.totalDied}',
                        ),

                        const SizedBox(height: 12),

                        // Queen & Brood
                        _SectionLabel('QUEEN & BROOD'),
                        const SizedBox(height: 6),
                        _StatRow(
                          icon: Icons.stars_rounded,
                          label: 'Queen',
                          value: colony.hasQueen
                              ? 'Alive'
                              : (colony.isOrphaned ? 'Dead (Orphaned)' : 'None'),
                        ),
                        _StatRow(
                          icon: Icons.egg_rounded,
                          label: 'Eggs',
                          value: '${colony.eggsCount}',
                        ),
                        _StatRow(
                          icon: Icons.bug_report_rounded,
                          label: 'Larvae',
                          value: '${colony.larvaeCount}',
                        ),

                        const SizedBox(height: 12),

                        // Role distribution
                        _SectionLabel('CASTES'),
                        const SizedBox(height: 8),
                        _RoleBar(
                          role: 'Queen',
                          count: roles[AntRole.queen] ?? 0,
                          total: colony.population,
                          color: AppColors.categoryEnergy,
                        ),
                        _RoleBar(
                          role: 'Worker',
                          count: roles[AntRole.worker] ?? 0,
                          total: colony.population,
                          color: AppColors.categoryLife,
                        ),
                        _RoleBar(
                          role: 'Soldier',
                          count: roles[AntRole.soldier] ?? 0,
                          total: colony.population,
                          color: AppColors.categoryEnergy,
                        ),
                        _RoleBar(
                          role: 'Nurse',
                          count: roles[AntRole.nurse] ?? 0,
                          total: colony.population,
                          color: AppColors.categoryLiquids,
                        ),
                        _RoleBar(
                          role: 'Scout',
                          count: roles[AntRole.scout] ?? 0,
                          total: colony.population,
                          color: AppColors.categorySolids,
                        ),

                        const SizedBox(height: 12),

                        // Evolution stats
                        _SectionLabel('EVOLUTION'),
                        const SizedBox(height: 6),
                        _StatRow(
                          icon: Icons.hub_rounded,
                          label: 'Species',
                          value: '${colony.evolution.speciesCount}',
                        ),
                        _StatRow(
                          icon: Icons.fitness_center_rounded,
                          label: 'Avg Fitness',
                          value: colony.averageAntFitness.toStringAsFixed(1),
                        ),
                        _StatRow(
                          icon: Icons.account_tree_rounded,
                          label: 'Avg Complexity',
                          value: colony.evolution.averageComplexity
                              .toStringAsFixed(1),
                        ),

                        const SizedBox(height: 12),

                        // Neural activity indicator
                        _SectionLabel('NEURAL ACTIVITY'),
                        const SizedBox(height: 8),
                        _NeuralActivityWidget(colony: colony),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.label,
    required this.accent,
    required this.icon,
  });

  final String label;
  final Color accent;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        gradient: LinearGradient(
          colors: [
            accent.withValues(alpha: 0.22),
            const Color(0xFF0C111B).withValues(alpha: 0.82),
          ],
        ),
        border: Border.all(
          color: accent.withValues(alpha: 0.28),
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: accent),
          const SizedBox(width: 6),
          Text(
            label,
            style: AppTypography.caption.copyWith(
              color: AppColors.textPrimary,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppTypography.label.copyWith(
        color: AppColors.textDim,
        fontSize: 9,
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppColors.textDim),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, style: AppTypography.caption),
          ),
          Text(
            value,
            style: AppTypography.label.copyWith(
              color: valueColor ?? AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _RoleBar extends StatelessWidget {
  const _RoleBar({
    required this.role,
    required this.count,
    required this.total,
    required this.color,
  });

  final String role;
  final int count;
  final int total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final fraction = total > 0 ? count / total : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                role,
                style: AppTypography.caption.copyWith(
                  color: color,
                  fontSize: 9,
                ),
              ),
              const Spacer(),
              Text(
                '$count',
                style: AppTypography.caption.copyWith(
                  color: AppColors.textPrimary,
                  fontSize: 9,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 3,
              backgroundColor: AppColors.surfaceLight,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Animated pulsing nodes representing neural activity.
class _NeuralActivityWidget extends StatefulWidget {
  const _NeuralActivityWidget({required this.colony});
  final Colony colony;

  @override
  State<_NeuralActivityWidget> createState() => _NeuralActivityWidgetState();
}

class _NeuralActivityWidgetState extends State<_NeuralActivityWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          return CustomPaint(
            size: const Size(double.infinity, 32),
            painter: _NeuralPainter(
              activity: _pulseController.value,
              nodeCount: min(widget.colony.population, 12),
            ),
          );
        },
      ),
    );
  }
}

class _NeuralPainter extends CustomPainter {
  _NeuralPainter({required this.activity, required this.nodeCount});

  final double activity;
  final int nodeCount;

  @override
  void paint(Canvas canvas, Size size) {
    if (nodeCount == 0) return;
    final rng = Random(42);
    final nodes = <Offset>[];

    for (var i = 0; i < nodeCount; i++) {
      nodes.add(Offset(
        rng.nextDouble() * size.width,
        rng.nextDouble() * size.height,
      ));
    }

    // Draw connections.
    final linePaint = Paint()
      ..color = AppColors.accent.withValues(alpha: 0.15 + activity * 0.15)
      ..strokeWidth = 0.5;
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        final dist = (nodes[i] - nodes[j]).distance;
        if (dist < size.width * 0.5) {
          canvas.drawLine(nodes[i], nodes[j], linePaint);
        }
      }
    }

    // Draw nodes with pulsing glow.
    for (var i = 0; i < nodes.length; i++) {
      final pulse = sin(activity * pi * 2 + i * 0.5) * 0.5 + 0.5;
      final radius = 2.0 + pulse * 2.0;
      final nodePaint = Paint()
        ..color = AppColors.accent.withValues(alpha: 0.4 + pulse * 0.4);
      canvas.drawCircle(nodes[i], radius, nodePaint);

      final glowPaint = Paint()
        ..color = AppColors.accent.withValues(alpha: pulse * 0.2)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawCircle(nodes[i], radius + 2, glowPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _NeuralPainter old) =>
      activity != old.activity || nodeCount != old.nodeCount;
}
