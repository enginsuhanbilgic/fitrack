/// Row tile for the History screen.
///
/// Stateless, dark-card aesthetic matching `_ExerciseCard` in `home_screen.dart`
/// for visual continuity. One tap = open the reconstructed SummaryScreen.
library;

import 'package:flutter/material.dart';

import '../core/types.dart';
import '../services/db/session_dtos.dart';

class SessionCard extends StatelessWidget {
  const SessionCard({super.key, required this.summary, required this.onTap});

  final SessionSummary summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: _semanticLabel(),
      button: true,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  _iconFor(summary.exercise),
                  size: 28,
                  color: const Color(0xFF00E676),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        summary.exercise.label,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _dateLabel(summary.startedAt),
                        style: TextStyle(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.54),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          _Chip(
                            icon: Icons.repeat,
                            text:
                                '${summary.totalReps} ${summary.totalReps == 1 ? "rep" : "reps"}',
                          ),
                          const SizedBox(width: 8),
                          _Chip(
                            icon: Icons.timer_outlined,
                            text: _durationLabel(summary.duration),
                          ),
                          if (summary.averageQuality != null) ...[
                            const SizedBox(width: 8),
                            _Chip(
                              icon: Icons.auto_awesome,
                              text:
                                  '${(summary.averageQuality! * 100).round()}%',
                              color: _qualityColor(summary.averageQuality!),
                            ),
                          ],
                        ],
                      ),
                      if (summary.topErrors.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: summary.topErrors
                                .map((e) => _ErrorChip(label: _errorLabel(e)))
                                .toList(),
                          ),
                        ),
                      if (summary.fatigueDetected || summary.asymmetryDetected)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            children: [
                              if (summary.fatigueDetected)
                                _FlagIcon(
                                  icon: Icons.battery_alert,
                                  tooltip: 'Fatigue detected',
                                ),
                              if (summary.asymmetryDetected)
                                _FlagIcon(
                                  icon: Icons.compare_arrows,
                                  tooltip: 'Asymmetry detected',
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.38),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _iconFor(ExerciseType e) => switch (e) {
    ExerciseType.bicepsCurlFront ||
    ExerciseType.bicepsCurlSide ||
    // ignore: deprecated_member_use_from_same_package
    ExerciseType.bicepsCurl => Icons.fitness_center,
    ExerciseType.squat => Icons.airline_seat_legroom_extra,
    ExerciseType.pushUp => Icons.sports_gymnastics,
  };

  /// "Apr 25, 14:32" — locale-agnostic short form. Avoids pulling intl.
  String _dateLabel(DateTime t) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '${months[t.month - 1]} ${t.day}, $hh:$mm';
  }

  String _durationLabel(Duration d) {
    final seconds = d.inSeconds;
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return s == 0 ? '${m}m' : '${m}m ${s}s';
  }

  /// Green ≥ 0.85, amber 0.70–0.85, red < 0.70 (matches summary-screen palette).
  Color _qualityColor(double q) {
    if (q >= 0.85) return const Color(0xFF00E676);
    if (q >= 0.70) return Colors.orangeAccent;
    return Colors.redAccent;
  }

  String _errorLabel(FormError e) => switch (e) {
    FormError.torsoSwing => 'Body Swinging',
    FormError.depthSwing => 'Rocking Forward',
    FormError.shoulderArc => 'Hip Rotation',
    FormError.elbowDrift => 'Elbow Moving Out',
    FormError.elbowRise => 'Elbow Rising Up',
    FormError.shoulderShrug => 'Shoulder Shrug',
    FormError.backLean => 'Leaning Back',
    FormError.shortRomStart => 'Arm Not Extended',
    FormError.shortRomPeak => 'Not Curling Up',
    FormError.eccentricTooFast => 'Lowering Too Fast',
    FormError.concentricTooFast => 'Lifting Too Fast',
    FormError.tempoInconsistent => 'Unsteady Pace',
    FormError.asymmetryLeftLag => 'Left Arm Lagging',
    FormError.asymmetryRightLag => 'Right Arm Lagging',
    FormError.fatigue => 'Fatigue',
    _ => e.name,
  };

  String _semanticLabel() {
    final parts = <String>[
      summary.exercise.label,
      _dateLabel(summary.startedAt),
      '${summary.totalReps} reps',
      _durationLabel(summary.duration),
    ];
    if (summary.averageQuality != null) {
      parts.add('quality ${(summary.averageQuality! * 100).round()} percent');
    }
    if (summary.fatigueDetected) parts.add('fatigue detected');
    if (summary.asymmetryDetected) parts.add('asymmetry detected');
    return parts.join(', ');
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c =
        color ??
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.70);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: c),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(color: c, fontSize: 12)),
      ],
    );
  }
}

class _ErrorChip extends StatelessWidget {
  const _ErrorChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFFFF5252);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.40)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _FlagIcon extends StatelessWidget {
  const _FlagIcon({required this.icon, required this.tooltip});

  final IconData icon;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Icon(icon, size: 14, color: Colors.amberAccent),
      ),
    );
  }
}
