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

class _Body extends StatelessWidget {
  const _Body({required this.vm});

  final HistoryViewModel vm;

  @override
  Widget build(BuildContext context) {
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
              Text(
                "Couldn't load history.",
                style: const TextStyle(color: Colors.white, fontSize: 16),
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
    return RefreshIndicator(
      onRefresh: vm.load,
      child: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: vm.sessions.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          final s = vm.sessions[i];
          return SessionCard(
            summary: s,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => HistoryDetailLoader(sessionId: s.id),
              ),
            ),
          );
        },
      ),
    );
  }
}
