import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Exercise-variant chip row (e.g. "High-bar", "Tall lifter (+5°)" for squat).
///
/// These chips document the audit's *assumptions*, not just decoration — for
/// squat, they reveal which threshold profile was applied. Removing them is
/// removing the audit's footnote, so they are rendered unconditionally when
/// any label is present.
///
/// Renders `SizedBox.shrink()` when [labels] is empty so callers can include
/// this widget in their build tree without conditional gating.
class SummaryVariantChips extends StatelessWidget {
  const SummaryVariantChips({super.key, required this.labels});

  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) return const SizedBox.shrink();
    final ft = FiTrackColors.of(context);
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final label in labels)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: ft.surface3,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: ft.stroke),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: ft.textDim,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}
