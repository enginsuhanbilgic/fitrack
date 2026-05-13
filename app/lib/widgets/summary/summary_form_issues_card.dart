import 'package:flutter/material.dart';

import '../../core/types.dart';

/// Unified form-issues chip wrap.
///
/// Replaces the curl-specific inline block in `_buildCurlSummary` and the
/// `_buildSquatFormIssuesCard` helper — both rendered the same chip layout
/// with subtly divergent styling. This widget is the canonical version.
class SummaryFormIssuesCard extends StatelessWidget {
  const SummaryFormIssuesCard({
    super.key,
    required this.errors,
    this.errorCounts = const {},
  });

  /// Errors to render. Caller is responsible for filtering by exercise.
  final List<FormError> errors;

  /// Optional fire counts to show as a `×N` badge on chips. Counts of ≤1
  /// suppress the badge.
  final Map<FormError, int> errorCounts;

  @override
  Widget build(BuildContext context) {
    if (errors.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: Color(0xFFFFB300),
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'Form Issues Detected',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final err in errors) _chip(err)],
          ),
        ],
      ),
    );
  }

  Widget _chip(FormError err) {
    // forwardKneeShift uses a dimmer amber (informational, no TTS) per the
    // in-workout highlight palette; everything else is red.
    final chipColor = err == FormError.forwardKneeShift
        ? const Color(0xFFFFA726)
        : const Color(0xFFFF5252);
    final count = errorCounts[err] ?? 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: chipColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: chipColor.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_iconFor(err), color: chipColor, size: 14),
          const SizedBox(width: 6),
          Text(
            _labelFor(err),
            style: TextStyle(color: chipColor, fontSize: 13),
          ),
          if (count > 1) ...[
            const SizedBox(width: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: chipColor.withValues(alpha: 0.20),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '×$count',
                style: TextStyle(
                  color: chipColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

IconData _iconFor(FormError err) => switch (err) {
  FormError.torsoSwing => Icons.swap_horiz,
  FormError.depthSwing => Icons.zoom_in_map,
  FormError.shoulderArc => Icons.sync,
  FormError.elbowDrift => Icons.open_with,
  FormError.elbowRise => Icons.arrow_upward_rounded,
  FormError.shoulderShrug => Icons.upload_rounded,
  FormError.backLean => Icons.undo,
  FormError.shortRomStart => Icons.unfold_more,
  FormError.shortRomPeak => Icons.compress,
  FormError.eccentricTooFast => Icons.fast_forward_rounded,
  FormError.concentricTooFast => Icons.rocket_launch,
  FormError.tempoInconsistent => Icons.shuffle,
  FormError.asymmetryLeftLag => Icons.balance,
  FormError.asymmetryRightLag => Icons.balance,
  FormError.fatigue => Icons.battery_alert,
  FormError.squatDepth => Icons.unfold_less,
  FormError.excessiveForwardLean => Icons.architecture,
  FormError.heelLift => Icons.vertical_align_bottom,
  FormError.forwardKneeShift => Icons.compare_arrows_rounded,
  FormError.hipSag => Icons.straighten_rounded,
  FormError.pushUpShortRom => Icons.unfold_less,
  _ => Icons.error_outline,
};

String _labelFor(FormError err) => switch (err) {
  FormError.torsoSwing => 'Body Swinging',
  FormError.depthSwing => 'Rocking Toward Camera',
  FormError.shoulderArc => 'Hip Rotation',
  FormError.elbowDrift => 'Elbow Moving Out',
  FormError.elbowRise => 'Elbow Rising Up',
  FormError.shoulderShrug => 'Shoulder Shrug',
  FormError.backLean => 'Leaning Back',
  FormError.shortRomStart => 'Arm Not Fully Extended',
  FormError.shortRomPeak => 'Not Curling All the Way Up',
  FormError.eccentricTooFast => 'Lowering Too Fast',
  FormError.concentricTooFast => 'Lifting Too Fast',
  FormError.tempoInconsistent => 'Unsteady Pace',
  FormError.asymmetryLeftLag => 'Left Arm Lagging',
  FormError.asymmetryRightLag => 'Right Arm Lagging',
  FormError.fatigue => 'Fatigue',
  FormError.squatDepth => 'Shallow Depth',
  FormError.excessiveForwardLean => 'Excessive Forward Lean',
  FormError.heelLift => 'Heel Lift',
  FormError.forwardKneeShift => 'Forward Knee Shift',
  FormError.hipSag => 'Body Line Lost',
  FormError.pushUpShortRom => 'Shallow Push-up',
  FormError.trunkTibia => 'Trunk-Tibia (legacy)',
  FormError.hipLead => 'Hip Lead',
};
