import 'dart:ui';

import 'package:flutter/material.dart';

import '../../services/save_service.dart';
import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';
import '../widgets/back_button.dart' show GlassBackButton;
import '../widgets/dialog_button.dart';
import 'sandbox_screen.dart';

/// Load screen: displays saved world slots as premium glassmorphic cards.
///
/// Tap to load a world, long-press to delete with confirmation dialog.
/// Landscape layout, dark premium theme with slot metadata display.
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
      await Navigator.of(context).push(
        PageRouteBuilder(
          pageBuilder: (context, _, _) => SandboxScreen(loadState: state),
          transitionsBuilder: (context, anim, _, child) {
            return FadeTransition(
              opacity: anim,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.96, end: 1.0).animate(
                  CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
                ),
                child: child,
              ),
            );
          },
          transitionDuration: ParticleTheme.normalDuration,
        ),
      );
      // Reset on return.
      if (mounted) {
        setState(() => _loadingSlot = null);
        _loadSlots();
      }
    } else if (mounted) {
      setState(() => _loadingSlot = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.surface,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ParticleTheme.radiusSmall),
          ),
          content: Text(
            'Failed to load world',
            style: AppTypography.body.copyWith(color: AppColors.danger),
          ),
        ),
      );
    }
  }

  Future<void> _confirmDelete(SaveSlotMeta meta) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _DeleteDialog(name: meta.name),
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
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    GlassBackButton(
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 16),
                    Text('Load World', style: AppTypography.heading),
                    const Spacer(),
                    if (_slots != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.glass,
                          borderRadius: BorderRadius.circular(
                            ParticleTheme.radiusSmall,
                          ),
                          border: Border.all(
                            color: AppColors.glassBorder,
                            width: 0.5,
                          ),
                        ),
                        child: Text(
                          '${_slots!.length} / ${SaveService.maxSlots} slots',
                          style: AppTypography.caption.copyWith(
                            color: AppColors.textDim,
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // Content
              Expanded(
                child: _loading
                    ? Center(child: _LoadingIndicator())
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

// =============================================================================
// Loading indicator
// =============================================================================

class _LoadingIndicator extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            color: AppColors.primary.withValues(alpha: 0.6),
            strokeWidth: 2,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Loading saves...',
          style: AppTypography.caption.copyWith(color: AppColors.textDim),
        ),
      ],
    );
  }
}

// =============================================================================
// Slot grid
// =============================================================================

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
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxCross = constraints.maxWidth >= 1200
            ? 320.0
            : constraints.maxWidth >= 800
            ? 300.0
            : 420.0;
        return GridView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: maxCross,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.65,
          ),
          itemCount: slots.length,
          itemBuilder: (context, index) {
            final meta = slots[index];
            return _SlotCard(
              meta: meta,
              isLoading: loadingSlot == meta.slot,
              onTap: () => onLoad(meta.slot),
              onLongPress: () => onDelete(meta),
            );
          },
        );
      },
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
  bool _hovered = false;

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

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
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
            borderRadius: BorderRadius.circular(ParticleTheme.radiusMedium),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: AnimatedContainer(
                duration: ParticleTheme.fastDuration,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _hovered
                      ? AppColors.glass.withValues(alpha: 0.15)
                      : AppColors.glass,
                  borderRadius: BorderRadius.circular(
                    ParticleTheme.radiusMedium,
                  ),
                  border: Border.all(
                    color: _hovered
                        ? AppColors.glassBorder.withValues(alpha: 0.4)
                        : AppColors.glassBorder,
                    width: 0.5,
                  ),
                  boxShadow: _hovered
                      ? [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.06),
                            blurRadius: 20,
                          ),
                        ]
                      : null,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title row
                    Row(
                      children: [
                        // World icon
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: isAutoSave
                                ? AppColors.accent.withValues(alpha: 0.12)
                                : AppColors.surfaceLight,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isAutoSave
                                  ? AppColors.accent.withValues(alpha: 0.25)
                                  : Colors.white.withValues(alpha: 0.06),
                              width: 0.5,
                            ),
                          ),
                          child: Icon(
                            isAutoSave
                                ? Icons.auto_mode_rounded
                                : Icons.public_rounded,
                            size: 16,
                            color: isAutoSave
                                ? AppColors.accent
                                : AppColors.textDim,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                meta.name,
                                style: AppTypography.subheading.copyWith(
                                  fontSize: 13,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (isAutoSave)
                                Text(
                                  'AUTO SAVE',
                                  style: AppTypography.caption.copyWith(
                                    color: AppColors.accent,
                                    fontSize: 8,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 1.5,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (widget.isLoading)
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.primary.withValues(alpha: 0.7),
                            ),
                          ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // Divider
                    Container(
                      height: 0.5,
                      color: AppColors.glassBorder.withValues(alpha: 0.15),
                    ),

                    const SizedBox(height: 10),

                    // Metadata grid
                    Row(
                      children: [
                        Expanded(
                          child: _MetaRow(
                            icon: Icons.access_time_rounded,
                            text: _formatDate(meta.savedAt),
                          ),
                        ),
                        Expanded(
                          child: _MetaRow(
                            icon: Icons.grid_on_rounded,
                            text: '${meta.gridW}x${meta.gridH}',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        if (meta.colonyCount > 0)
                          Expanded(
                            child: _MetaRow(
                              icon: Icons.bug_report_rounded,
                              text:
                                  '${meta.colonyCount} ${meta.colonyCount == 1 ? "colony" : "colonies"}',
                            ),
                          ),
                        Expanded(
                          child: _MetaRow(
                            icon: Icons.storage_rounded,
                            text: _formatBytes(meta.fileSizeBytes),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 10),

                    // Action hint
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Tap to load',
                          style: AppTypography.caption.copyWith(
                            color: _hovered
                                ? AppColors.primary.withValues(alpha: 0.6)
                                : AppColors.textDim.withValues(alpha: 0.4),
                            fontSize: 9,
                          ),
                        ),
                        Text(
                          'Hold to delete',
                          style: AppTypography.caption.copyWith(
                            color: AppColors.textDim.withValues(alpha: 0.3),
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
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
        Icon(icon, size: 11, color: AppColors.textDim),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            style: AppTypography.caption.copyWith(
              color: AppColors.textSecondary,
              fontSize: 10,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Delete confirmation dialog (glassmorphic)
// =============================================================================

class _DeleteDialog extends StatelessWidget {
  const _DeleteDialog({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    return Dialog(
      backgroundColor: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ParticleTheme.radiusMedium),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            width: (screenW - 32).clamp(260.0, 360.0),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(ParticleTheme.radiusMedium),
              border: Border.all(color: AppColors.glassBorder, width: 0.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 30,
                ),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: AppColors.danger.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                          color: AppColors.danger,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Delete World',
                          style: AppTypography.subheading,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Delete "$name"? This cannot be undone.',
                    style: AppTypography.body.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      DialogButton(
                        label: 'Cancel',
                        onTap: () => Navigator.of(context).pop(false),
                      ),
                      DialogButton(
                        label: 'Delete',
                        color: AppColors.danger,
                        onTap: () => Navigator.of(context).pop(true),
                      ),
                    ],
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

// =============================================================================
// Empty state with encouraging message
// =============================================================================

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.surfaceLight.withValues(alpha: 0.5),
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.glassBorder, width: 0.5),
              ),
              child: Icon(
                Icons.public_off_rounded,
                size: 32,
                color: AppColors.textDim.withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'No saved worlds yet',
              style: AppTypography.subheading.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Create a new world and your saves will appear here.',
              textAlign: TextAlign.center,
              style: AppTypography.body.copyWith(color: AppColors.textDim),
            ),
            const SizedBox(height: 24),
            Icon(
              Icons.arrow_back_rounded,
              size: 16,
              color: AppColors.textDim.withValues(alpha: 0.3),
            ),
          ],
        ),
      ),
    );
  }
}
