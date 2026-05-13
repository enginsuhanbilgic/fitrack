import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Three-column Time / Reps / Sets grid shown directly under [SummaryHero] on
/// every Session Complete page.
///
/// Replaces three pre-unification widgets: `_StatChip` (squat), `_StatRow`
/// (push-up), and the `_SummaryStatCard` + `_SetsChip` pair (curl). The card
/// styling matches `_SummaryStatCard` since that was the canonical curl
/// treatment.
class SummaryStatsGrid extends StatelessWidget {
  const SummaryStatsGrid({
    super.key,
    required this.reps,
    required this.sets,
    required this.duration,
  });

  final int reps;
  final int sets;
  final Duration duration;

  static String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StatTile(
            icon: Icons.schedule_outlined,
            label: 'TIME',
            value: _formatDuration(duration),
            semanticLabel: 'Time: ${_formatDuration(duration)}',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatTile(
            icon: Icons.repeat_rounded,
            label: 'REPS',
            value: '$reps',
            semanticLabel: 'Reps: $reps',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatTile(
            icon: Icons.layers_rounded,
            label: 'SETS',
            value: '$sets',
            semanticLabel: 'Sets: $sets',
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.semanticLabel,
  });

  final IconData icon;
  final String label;
  final String value;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return Semantics(
      label: semanticLabel,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: ft.surface1,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: ft.stroke),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(icon, color: ft.textDim, size: 14),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: ft.textDim,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: TextStyle(
                color: ft.textStrong,
                fontSize: 26,
                fontWeight: FontWeight.w700,
                letterSpacing: -1,
                height: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
