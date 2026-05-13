import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Form Accuracy hero — the canonical top block of every exercise's Session
/// Complete page.
///
/// **Cardless / glass design (2026-05-13):** Rendered without a surrounding
/// surface card or border — title, score, grade, and subtitle sit directly on
/// the page background with generous vertical padding, so the score reads as
/// the page hero rather than another walled-off card. A barely-there frosted
/// halo behind the number adds depth without re-introducing a card edge.
///
/// **AI labeling removed:** the prior "AI FORM ACCURACY" pill was dropped per
/// product direction; the score speaks for itself and the exercise label
/// already provides context.
class SummaryHero extends StatelessWidget {
  const SummaryHero({
    super.key,
    required this.qualityPct,
    required this.grade,
    required this.subtitle,
    required this.exerciseLabel,
  });

  /// Mean form accuracy as a 0-100 integer percent, or null when no quality
  /// data was captured (zero-rep session, or analyzer skipped grading).
  final int? qualityPct;

  /// Letter grade derived from `qualityPct` — 'A'..'F' or '—' when null.
  final String grade;

  /// One-line qualitative coaching cue, e.g. "Excellent control."
  final String subtitle;

  /// Exercise display name shown above the score. Used as a Semantics header
  /// so screen readers announce the page identity before the metric.
  final String exerciseLabel;

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 16),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Frosted halo behind the score. Very subtle — replaces the old
          // card surface without re-walling the content.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 0.85,
                    colors: [ft.cyan.withAlpha(0x14), ft.cyan.withAlpha(0x00)],
                  ),
                ),
              ),
            ),
          ),
          Column(
            children: [
              Semantics(
                header: true,
                child: Text(
                  exerciseLabel,
                  style: TextStyle(
                    color: ft.textStrong,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'FORM ACCURACY',
                style: TextStyle(
                  color: ft.textDim,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    qualityPct != null ? '$qualityPct' : '—',
                    style: TextStyle(
                      fontSize: 88,
                      fontWeight: FontWeight.w700,
                      color: ft.textStrong,
                      height: 1,
                      letterSpacing: -4,
                    ),
                  ),
                  if (qualityPct != null)
                    Text(
                      '%',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        color: ft.cyan,
                      ),
                    ),
                  if (qualityPct != null) ...[
                    const SizedBox(width: 10),
                    // Grade pill kept — it's a compact glyph, not a card.
                    // The translucent cyan fill reads as glass not surface.
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: ft.cyan.withAlpha(0x1A),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: ft.cyan.withAlpha(0x55)),
                      ),
                      child: Text(
                        grade,
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                          color: ft.cyan,
                          height: 1,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              Text(
                subtitle,
                style: TextStyle(color: ft.textDim, fontSize: 13, height: 1.4),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
