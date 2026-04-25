/// Top-level History list.
///
/// Accessible from the AppBar history icon on [HomeScreen]. Shows a horizontally
/// scrollable row of exercise-filter chips above a [ListView.builder] of past
/// sessions (newest first). Tap a row → [HistoryDetailLoader] which resolves
/// the full [SessionDetail] and hands it to `SummaryScreen.fromSession`.
///
/// State:
///  - `loading && empty`   → centered spinner
///  - `error != null`      → error panel with retry
///  - `sessions.isEmpty`   → empty-state message
///  - else                 → list
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/types.dart';
import '../services/app_services.dart';
import '../view_models/history_view_model.dart';
import '../widgets/session_card.dart';
import 'history_detail_loader.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  HistoryViewModel? _vm;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_vm == null) {
      final repo = AppServicesScope.of(context).sessionRepository;
      _vm = HistoryViewModel(repository: repo)..load();
    }
  }

  @override
  void dispose() {
    _vm?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = _vm;
    if (vm == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return ChangeNotifierProvider<HistoryViewModel>.value(
      value: vm,
      child: Scaffold(
        appBar: AppBar(title: const Text('History')),
        body: Consumer<HistoryViewModel>(
          builder: (_, vm, _) => Column(
            children: [
              _FilterRow(
                selected: vm.filter,
                onChanged: (next) => vm.setFilter(next),
              ),
              const Divider(height: 1, color: Colors.white12),
              Expanded(child: _Body(vm: vm)),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({required this.selected, required this.onChanged});

  final ExerciseType? selected;
  final ValueChanged<ExerciseType?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          _Chip(
            label: 'All',
            selected: selected == null,
            onTap: () => onChanged(null),
          ),
          const SizedBox(width: 8),
          for (final type in ExerciseType.values) ...[
            _Chip(
              label: type.label,
              selected: selected == type,
              onTap: () => onChanged(type),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: const Color(0xFF00E676).withValues(alpha: 0.20),
      labelStyle: TextStyle(
        color: selected ? const Color(0xFF00E676) : Colors.white70,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: selected ? const Color(0xFF00E676) : Colors.white24,
        ),
      ),
      backgroundColor: const Color(0xFF1E1E1E),
    );
  }
}

class _Body extends StatefulWidget {
  const _Body({required this.vm});

  final HistoryViewModel vm;

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController()..addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 200) {
      widget.vm.loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    if (vm.loading && vm.sessions.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (vm.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                color: Colors.redAccent,
                size: 40,
              ),
              const SizedBox(height: 12),
              const Text(
                "Couldn't load history.",
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
              const SizedBox(height: 6),
              Text(
                '${vm.error}',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              TextButton(onPressed: vm.load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (vm.sessions.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.history_edu, size: 48, color: Colors.white24),
              SizedBox(height: 12),
              Text(
                'No workouts yet — finish one to see it here.',
                style: TextStyle(color: Colors.white54, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    // +1 for the footer sentinel/spinner row.
    final itemCount = vm.sessions.length + 1;

    return RefreshIndicator(
      onRefresh: vm.load,
      child: ListView.separated(
        controller: _scrollController,
        padding: const EdgeInsets.all(12),
        itemCount: itemCount,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          if (i == vm.sessions.length) {
            return _ListFooter(
              loadingMore: vm.loadingMore,
              hasMore: vm.hasMore,
            );
          }
          final s = vm.sessions[i];
          // Dismissible wraps the card so swipe-to-delete operates at the
          // list-item level (the session id keys the dismiss animation).
          // Confirmation dialog matches the destructive-button idiom from
          // SettingsScreen._confirmReset — red action, no-undo language.
          return Dismissible(
            key: ValueKey<int>(s.id),
            direction: DismissDirection.endToStart,
            background: const SizedBox.shrink(),
            secondaryBackground: const _DeleteSwipeBackground(),
            confirmDismiss: (_) => _confirmDelete(context),
            onDismissed: (_) => vm.deleteSession(s.id),
            child: SessionCard(
              summary: s,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => HistoryDetailLoader(sessionId: s.id),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete session?'),
        content: const Text(
          'This permanently removes the session and all its reps. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}

class _ListFooter extends StatelessWidget {
  const _ListFooter({required this.loadingMore, required this.hasMore});

  final bool loadingMore;
  final bool hasMore;

  @override
  Widget build(BuildContext context) {
    if (loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (!hasMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            'End of history',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

/// The red trailing-edge surface revealed during a left-swipe. Stateless;
/// a sibling of the SessionCard inside Dismissible.secondaryBackground.
class _DeleteSwipeBackground extends StatelessWidget {
  const _DeleteSwipeBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.delete_outline, color: Colors.white, size: 22),
          SizedBox(width: 8),
          Text(
            'Delete',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
