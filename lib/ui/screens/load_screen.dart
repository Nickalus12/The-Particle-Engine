import 'dart:ui';

import 'package:flutter/material.dart';

import '../../services/save_service.dart';
import '../theme/colors.dart';
import '../theme/particle_theme.dart';
import '../theme/typography.dart';
import '../widgets/back_button.dart' show GlassBackButton;
import '../widgets/dialog_button.dart';
import 'sandbox_screen.dart';
import 'world_create_screen.dart';

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
  String _query = '';
  _SlotSortMode _sortMode = _SlotSortMode.recent;
  bool _showAutoOnly = false;
  bool _showColoniesOnly = false;

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

  Future<void> _confirmRename(SaveSlotMeta meta) async {
    final renamed = await showDialog<String>(
      context: context,
      builder: (context) => _RenameDialog(initialName: meta.name),
    );
    if (renamed == null || renamed.trim().isEmpty || !mounted) return;

    try {
      await _saveService.renameSlot(meta.slot, renamed);
      _loadSlots();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.surface,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ParticleTheme.radiusSmall),
          ),
          content: Text(
            'Failed to rename world',
            style: AppTypography.body.copyWith(color: AppColors.danger),
          ),
        ),
      );
    }
  }

  void _openCreateWorld() {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, _, _) => const WorldCreateScreen(),
        transitionsBuilder: (context, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: ParticleTheme.normalDuration,
      ),
    );
  }

  List<SaveSlotMeta> _visibleSlots() {
    final slots = _slots;
    if (slots == null) return const [];

    final filtered = slots.where((slot) {
      if (_showAutoOnly && slot.slot != SaveService.autoSaveSlot) {
        return false;
      }
      if (_showColoniesOnly && slot.colonyCount <= 0) {
        return false;
      }
      final query = _query.trim().toLowerCase();
      if (query.isEmpty) return true;
      return slot.name.toLowerCase().contains(query);
    }).toList();

    filtered.sort((a, b) {
      switch (_sortMode) {
        case _SlotSortMode.recent:
          return b.savedAt.compareTo(a.savedAt);
        case _SlotSortMode.name:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case _SlotSortMode.size:
          return b.fileSizeBytes.compareTo(a.fileSizeBytes);
        case _SlotSortMode.colonies:
          return b.colonyCount.compareTo(a.colonyCount);
      }
    });

    return filtered;
  }

  String _formatRelative(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final visibleSlots = _visibleSlots();

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
                    : Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
                            child: _SelectionControls(
                              query: _query,
                              sortMode: _sortMode,
                              showAutoOnly: _showAutoOnly,
                              showColoniesOnly: _showColoniesOnly,
                              onQueryChanged: (value) =>
                                  setState(() => _query = value),
                              onSortChanged: (mode) =>
                                  setState(() => _sortMode = mode),
                              onToggleAutoOnly: () => setState(
                                () => _showAutoOnly = !_showAutoOnly,
                              ),
                              onToggleColoniesOnly: () => setState(
                                () => _showColoniesOnly = !_showColoniesOnly,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                            child: _SelectionSummaryStrip(
                              visibleCount: visibleSlots.length,
                              totalCount: _slots!.length,
                              totalColonies: visibleSlots.fold<int>(
                                0,
                                (sum, slot) => sum + slot.colonyCount,
                              ),
                              newestLabel: visibleSlots.isEmpty
                                  ? 'n/a'
                                  : _formatRelative(
                                      visibleSlots
                                          .map((slot) => slot.savedAt)
                                          .reduce(
                                            (a, b) => a.isAfter(b) ? a : b,
                                          ),
                                    ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                            child: _SelectionQuickActions(
                              canLoadLatest: visibleSlots.isNotEmpty,
                              onLoadLatest: visibleSlots.isEmpty
                                  ? null
                                  : () => _loadWorld(visibleSlots.first.slot),
                              onCreateWorld: _openCreateWorld,
                              onClearSearch: () => setState(() => _query = ''),
                            ),
                          ),
                          Expanded(
                            child: visibleSlots.isEmpty
                                ? _NoSlotMatchState(
                                    onReset: () => setState(() {
                                      _query = '';
                                      _showAutoOnly = false;
                                      _showColoniesOnly = false;
                                      _sortMode = _SlotSortMode.recent;
                                    }),
                                  )
                                : _SlotGrid(
                                    slots: visibleSlots,
                                    loadingSlot: _loadingSlot,
                                    onLoad: _loadWorld,
                                    onDelete: _confirmDelete,
                                    onRename: _confirmRename,
                                  ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _SlotSortMode { recent, name, size, colonies }

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

class _SelectionControls extends StatelessWidget {
  const _SelectionControls({
    required this.query,
    required this.sortMode,
    required this.showAutoOnly,
    required this.showColoniesOnly,
    required this.onQueryChanged,
    required this.onSortChanged,
    required this.onToggleAutoOnly,
    required this.onToggleColoniesOnly,
  });

  final String query;
  final _SlotSortMode sortMode;
  final bool showAutoOnly;
  final bool showColoniesOnly;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<_SlotSortMode> onSortChanged;
  final VoidCallback onToggleAutoOnly;
  final VoidCallback onToggleColoniesOnly;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          key: const ValueKey('load_search_field_shell'),
          decoration: BoxDecoration(
            color: AppColors.glass,
            borderRadius: BorderRadius.circular(ParticleTheme.radiusSmall),
            border: Border.all(color: AppColors.glassBorder, width: 0.5),
          ),
          child: TextField(
            key: const ValueKey('load_search_field'),
            onChanged: onQueryChanged,
            style: AppTypography.body.copyWith(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: 'Search worlds...',
              hintStyle: AppTypography.caption.copyWith(
                color: AppColors.textDim,
              ),
              prefixIcon: const Icon(
                Icons.search_rounded,
                size: 16,
                color: AppColors.textDim,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 12,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _FilterChipButton(
              key: const ValueKey('load_sort_recent_chip'),
              label: 'Recent',
              active: sortMode == _SlotSortMode.recent,
              onTap: () => onSortChanged(_SlotSortMode.recent),
            ),
            _FilterChipButton(
              key: const ValueKey('load_sort_name_chip'),
              label: 'Name',
              active: sortMode == _SlotSortMode.name,
              onTap: () => onSortChanged(_SlotSortMode.name),
            ),
            _FilterChipButton(
              key: const ValueKey('load_sort_size_chip'),
              label: 'Size',
              active: sortMode == _SlotSortMode.size,
              onTap: () => onSortChanged(_SlotSortMode.size),
            ),
            _FilterChipButton(
              key: const ValueKey('load_sort_colonies_chip'),
              label: 'Colonies',
              active: sortMode == _SlotSortMode.colonies,
              onTap: () => onSortChanged(_SlotSortMode.colonies),
            ),
            _FilterChipButton(
              key: const ValueKey('load_filter_auto_chip'),
              label: 'Auto',
              active: showAutoOnly,
              onTap: onToggleAutoOnly,
            ),
            _FilterChipButton(
              key: const ValueKey('load_filter_colonies_chip'),
              label: 'Colonies',
              active: showColoniesOnly,
              onTap: onToggleColoniesOnly,
            ),
          ],
        ),
      ],
    );
  }
}

class _SelectionQuickActions extends StatelessWidget {
  const _SelectionQuickActions({
    required this.canLoadLatest,
    required this.onLoadLatest,
    required this.onCreateWorld,
    required this.onClearSearch,
  });

  final bool canLoadLatest;
  final VoidCallback? onLoadLatest;
  final VoidCallback onCreateWorld;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _QuickActionButton(
          key: const ValueKey('load_quick_latest_button'),
          label: 'Load Latest',
          icon: Icons.play_arrow_rounded,
          enabled: canLoadLatest,
          onTap: onLoadLatest,
        ),
        _QuickActionButton(
          key: const ValueKey('load_quick_create_button'),
          label: 'Create World',
          icon: Icons.add_circle_outline_rounded,
          onTap: onCreateWorld,
        ),
        _QuickActionButton(
          key: const ValueKey('load_quick_clear_button'),
          label: 'Clear Search',
          icon: Icons.cleaning_services_rounded,
          onTap: onClearSearch,
        ),
      ],
    );
  }
}

class _QuickActionButton extends StatelessWidget {
  const _QuickActionButton({
    super.key,
    required this.label,
    required this.icon,
    this.enabled = true,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: enabled ? onTap : null,
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: AppColors.glass,
              border: Border.all(color: AppColors.glassBorder, width: 0.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: AppColors.primary),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: AppTypography.caption.copyWith(
                    color: AppColors.textSecondary,
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectionSummaryStrip extends StatelessWidget {
  const _SelectionSummaryStrip({
    required this.visibleCount,
    required this.totalCount,
    required this.totalColonies,
    required this.newestLabel,
  });

  final int visibleCount;
  final int totalCount;
  final int totalColonies;
  final String newestLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('load_selection_summary_strip'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.glass,
        borderRadius: BorderRadius.circular(ParticleTheme.radiusSmall),
        border: Border.all(color: AppColors.glassBorder, width: 0.5),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        children: [
          _SummaryCell(label: 'Showing', value: '$visibleCount / $totalCount'),
          _SummaryCell(label: 'Colonies', value: '$totalColonies'),
          _SummaryCell(label: 'Newest', value: newestLabel),
        ],
      ),
    );
  }
}

class _SummaryCell extends StatelessWidget {
  const _SummaryCell({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label: ',
          style: AppTypography.caption.copyWith(
            color: AppColors.textDim,
            fontSize: 10.5,
          ),
        ),
        Text(
          value,
          style: AppTypography.caption.copyWith(
            color: AppColors.textSecondary,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _FilterChipButton extends StatelessWidget {
  const _FilterChipButton({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: active
                ? AppColors.primary.withValues(alpha: 0.18)
                : AppColors.glass,
            border: Border.all(
              color: active
                  ? AppColors.primary.withValues(alpha: 0.5)
                  : AppColors.glassBorder,
              width: 0.5,
            ),
          ),
          child: Text(
            label,
            style: AppTypography.caption.copyWith(
              color: active ? AppColors.primary : AppColors.textSecondary,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
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
    required this.onRename,
  });

  final List<SaveSlotMeta> slots;
  final int? loadingSlot;
  final ValueChanged<int> onLoad;
  final ValueChanged<SaveSlotMeta> onDelete;
  final ValueChanged<SaveSlotMeta> onRename;

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
              onDeleteTap: () => onDelete(meta),
              onRenameTap: () => onRename(meta),
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
    required this.onDeleteTap,
    required this.onRenameTap,
  });

  final SaveSlotMeta meta;
  final bool isLoading;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDeleteTap;
  final VoidCallback onRenameTap;

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
                          )
                        else ...[
                          IconButton(
                            key: ValueKey('load_rename_icon_slot_${meta.slot}'),
                            onPressed: widget.onRenameTap,
                            tooltip: 'Rename world',
                            iconSize: 16,
                            splashRadius: 18,
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              Icons.edit_outlined,
                              color: AppColors.primary.withValues(alpha: 0.75),
                            ),
                          ),
                          IconButton(
                            key: ValueKey('load_delete_icon_slot_${meta.slot}'),
                            onPressed: widget.onDeleteTap,
                            tooltip: 'Delete world',
                            iconSize: 16,
                            splashRadius: 18,
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              Icons.delete_outline_rounded,
                              color: AppColors.danger.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
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
                          '#${meta.slot}',
                          style: AppTypography.caption.copyWith(
                            color: AppColors.textDim.withValues(alpha: 0.35),
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

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

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
            width: (screenW - 32).clamp(260.0, 380.0),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(ParticleTheme.radiusMedium),
              border: Border.all(color: AppColors.glassBorder, width: 0.5),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Rename World', style: AppTypography.subheading),
                const SizedBox(height: 12),
                Container(
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
                  child: TextField(
                    key: const ValueKey('load_rename_text_field'),
                    controller: _controller,
                    autofocus: true,
                    maxLength: 48,
                    style: AppTypography.body.copyWith(
                      color: AppColors.textPrimary,
                    ),
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: 'World name',
                      hintStyle: AppTypography.caption.copyWith(
                        color: AppColors.textDim,
                      ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    DialogButton(
                      label: 'Cancel',
                      onTap: () => Navigator.of(context).pop(),
                    ),
                    DialogButton(
                      label: 'Save',
                      color: AppColors.primary,
                      onTap: () =>
                          Navigator.of(context).pop(_controller.text.trim()),
                    ),
                  ],
                ),
              ],
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

class _NoSlotMatchState extends StatelessWidget {
  const _NoSlotMatchState({required this.onReset});

  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.filter_alt_off_rounded,
              color: AppColors.textDim.withValues(alpha: 0.5),
              size: 30,
            ),
            const SizedBox(height: 10),
            Text(
              'No worlds match these filters',
              style: AppTypography.subheading.copyWith(
                color: AppColors.textSecondary,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Try clearing your search or turning off filters.',
              textAlign: TextAlign.center,
              style: AppTypography.body.copyWith(
                color: AppColors.textDim,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 14),
            TextButton(
              key: const ValueKey('load_reset_filters_button'),
              onPressed: onReset,
              child: Text(
                'Reset filters',
                style: AppTypography.caption.copyWith(color: AppColors.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
