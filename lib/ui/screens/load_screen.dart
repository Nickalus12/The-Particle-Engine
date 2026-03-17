import 'dart:ui';

import 'package:flutter/material.dart';

import '../../services/save_service.dart';
import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';
import 'sandbox_screen.dart';

/// Load screen: displays saved world slots as a grid.
///
/// Tap to load a world, long-press to delete with confirmation dialog.
/// Landscape layout, dark premium theme. Shows slot metadata (name, date,
/// grid dimensions, colony count, file size).
class LoadScreen extends StatefulWidget {
  const LoadScreen({super.key});

  @override
  State<LoadScreen> createState() => _LoadScreenState();
}

class _LoadScreenState extends State<LoadScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final Animation<double> _contentFade;

  final SaveService _saveService = SaveService();
  List<SaveSlotMeta>? _slots;
  bool _loading = true;
  int? _loadingSlot;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: ParticleTheme.normalDuration,
    )..forward();
    _contentFade = CurvedAnimation(
      parent: _fadeController,
      curve: ParticleTheme.defaultCurve,
    );
    _loadSlots();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  Future<void> _loadSlots() async {
    final slots = await _saveService.listSlots();
    if (mounted) {
      setState(() {
        _slots = slots;
        _loading = false;
      });
    }
  }

  Future<void> _loadWorld(int slot) async {
    if (_loadingSlot != null) return;
    setState(() => _loadingSlot = slot);

    final state = await _saveService.load(slot);
    if (state != null && mounted) {
      Navigator.of(context).push(
        PageRouteBuilder(
          pageBuilder: (context, _, _) => SandboxScreen(loadState: state),
          transitionsBuilder: (context, anim, _, child) =>
              FadeTransition(opacity: anim, child: child),
          transitionDuration: ParticleTheme.normalDuration,
        ),
      );
    } else if (mounted) {
      setState(() => _loadingSlot = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to load world')),
      );
    }
  }

  Future<void> _confirmDelete(SaveSlotMeta meta) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ParticleTheme.radiusMedium),
        ),
        title: Text(
          'Delete World',
          style: AppTypography.subheading,
        ),
        content: Text(
          'Delete "${meta.name}"? This cannot be undone.',
          style: AppTypography.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'Cancel',
              style: AppTypography.button
                  .copyWith(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Delete',
              style:
                  AppTypography.button.copyWith(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await _saveService.delete(meta.slot);
      _loadSlots();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: FadeTransition(
          opacity: _contentFade,
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    _BackButton(
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 16),
                    Text('Load World', style: AppTypography.heading),
                    const Spacer(),
                    if (_slots != null)
                      Text(
                        '${_slots!.length} / ${SaveService.maxSlots} slots',
                        style: AppTypography.caption.copyWith(
                          color: AppColors.textDim,
                        ),
                      ),
                  ],
                ),
              ),

              // Content
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: AppColors.primary,
                          strokeWidth: 2,
                        ),
                      )
                    : _slots == null || _slots!.isEmpty
                        ? _EmptyState()
                        : _SlotGrid(
                            slots: _slots!,
                            loadingSlot: _loadingSlot,
                            onLoad: _loadWorld,
                            onDelete: _confirmDelete,
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Slot grid
// ═══════════════════════════════════════════════════════════════════════════

class _SlotGrid extends StatelessWidget {
  const _SlotGrid({
    required this.slots,
    required this.loadingSlot,
    required this.onLoad,
    required this.onDelete,
  });

  final List<SaveSlotMeta> slots;
  final int? loadingSlot;
  final ValueChanged<int> onLoad;
  final ValueChanged<SaveSlotMeta> onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: slots.map((meta) {
          return _SlotCard(
            meta: meta,
            isLoading: loadingSlot == meta.slot,
            onTap: () => onLoad(meta.slot),
            onLongPress: () => onDelete(meta),
          );
        }).toList(),
      ),
    );
  }
}

class _SlotCard extends StatefulWidget {
  const _SlotCard({
    required this.meta,
    required this.isLoading,
    required this.onTap,
    required this.onLongPress,
  });

  final SaveSlotMeta meta;
  final bool isLoading;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<_SlotCard> createState() => _SlotCardState();
}

class _SlotCardState extends State<_SlotCard> {
  bool _pressed = false;

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final meta = widget.meta;
    final isAutoSave = meta.slot == SaveService.autoSaveSlot;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: ParticleTheme.fastDuration,
        child: ClipRRect(
          borderRadius:
              BorderRadius.circular(ParticleTheme.radiusMedium),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              width: 220,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.glass,
                borderRadius:
                    BorderRadius.circular(ParticleTheme.radiusMedium),
                border: Border.all(
                  color: AppColors.glassBorder,
                  width: 0.5,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title row
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          meta.name,
                          style: AppTypography.subheading,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isAutoSave)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color:
                                AppColors.accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'AUTO',
                            style: AppTypography.caption.copyWith(
                              color: AppColors.accent,
                              fontSize: 8,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      if (widget.isLoading)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.primary,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Metadata
                  _MetaRow(
                    icon: Icons.access_time_rounded,
                    text: _formatDate(meta.savedAt),
                  ),
                  const SizedBox(height: 4),
                  _MetaRow(
                    icon: Icons.grid_on_rounded,
                    text: '${meta.gridW} x ${meta.gridH}',
                  ),
                  if (meta.colonyCount > 0) ...[
                    const SizedBox(height: 4),
                    _MetaRow(
                      icon: Icons.bug_report_rounded,
                      text:
                          '${meta.colonyCount} ${meta.colonyCount == 1 ? "colony" : "colonies"}',
                    ),
                  ],
                  const SizedBox(height: 4),
                  _MetaRow(
                    icon: Icons.storage_rounded,
                    text: _formatBytes(meta.fileSizeBytes),
                  ),

                  const SizedBox(height: 8),

                  // Hint
                  Text(
                    'Tap to load  /  Hold to delete',
                    style: AppTypography.caption.copyWith(
                      color: AppColors.textDim.withValues(alpha: 0.5),
                      fontSize: 9,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 12, color: AppColors.textDim),
        const SizedBox(width: 6),
        Text(
          text,
          style: AppTypography.caption.copyWith(
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Empty state
// ═══════════════════════════════════════════════════════════════════════════

class _BackButton extends StatefulWidget {
  const _BackButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_BackButton> createState() => _BackButtonState();
}

class _BackButtonState extends State<_BackButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: ParticleTheme.fastDuration,
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: _hovered
                ? AppColors.glass.withValues(alpha: 0.3)
                : AppColors.glass,
            shape: BoxShape.circle,
            border: Border.all(
              color: _hovered
                  ? AppColors.glassBorder.withValues(alpha: 0.4)
                  : AppColors.glassBorder,
              width: 0.5,
            ),
          ),
          child: Icon(
            Icons.arrow_back_rounded,
            size: 18,
            color: _hovered ? AppColors.textPrimary : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.folder_off_rounded,
            size: 48,
            color: AppColors.textDim.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            'No saved worlds',
            style: AppTypography.subheading.copyWith(
              color: AppColors.textDim,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create a new world to get started.',
            style: AppTypography.body.copyWith(
              color: AppColors.textDim,
            ),
          ),
        ],
      ),
    );
  }
}
