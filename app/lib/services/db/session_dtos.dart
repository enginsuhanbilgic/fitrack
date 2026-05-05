/// Plain value types used by [SessionRepository] reads.
///
/// Immutable; passed from repo → ViewModel → UI without mutation. Enum-valued
/// columns are deserialised via `Enum.values.byName(...)` — TEXT column stores
/// `enum.name`, never `enum.index` (per plan's serialization contract).
library;

import '../../core/types.dart';

/// Low-detail view used by the History list (PR3). One row per completed
/// session; no per-rep data.
class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.exercise,
    required this.startedAt,
    required this.duration,
    required this.totalReps,
    required this.totalSets,
    required this.fatigueDetected,
    required this.asymmetryDetected,
    this.averageQuality,
    this.detectedView,
    this.topErrors = const [],
  });

  final int id;
  final ExerciseType exercise;
  final DateTime startedAt;
  final Duration duration;
  final int totalReps;
  final int totalSets;
  final double? averageQuality;
  final CurlCameraView? detectedView;
  final bool fatigueDetected;
  final bool asymmetryDetected;

  /// Up to 3 most-frequent form errors in this session, sorted by count desc.
  /// Empty when the session had no form errors or for pre-WP6 rows.
  final List<FormError> topErrors;
}

/// Full detail view for the reconstructed SummaryScreen (PR3). Wraps the
/// summary with per-rep rows + aggregated form errors.
class SessionDetail {
  const SessionDetail({
    required this.summary,
    required this.eccentricTooFastCount,
    required this.reps,
    required this.formErrors,
  });

  final SessionSummary summary;
  final int eccentricTooFastCount;
  final List<RepRow> reps;
  final Map<FormError, int> formErrors;
}

/// One `reps` table row in value form. Curl-specific fields are nullable —
/// squat/push-up leave them NULL. Squat-specific fields are likewise NULL on
/// curl/push-up rows.
class RepRow {
  const RepRow({
    required this.repIndex,
    this.quality,
    this.minAngle,
    this.maxAngle,
    this.side,
    this.view,
    this.source,
    this.bucketUpdated,
    this.rejectedOutlier,
    this.concentricMs,
    this.dtwSimilarity,
    this.squatLeanDeg,
    this.squatKneeShiftRatio,
    this.squatHeelLiftRatio,
    this.squatVariant,
    this.bicepsLeanDeg,
    this.bicepsShoulderDriftRatio,
    this.bicepsElbowDriftRatio,
    this.bicepsBackLeanDeg,
    this.bicepsElbowDriftSigned,
    this.bicepsShrugRatio,
    this.bicepsElbowRiseRatio,
  });

  final int repIndex;
  final double? quality;
  final double? minAngle;
  final double? maxAngle;
  final ProfileSide? side;
  final CurlCameraView? view;
  final ThresholdSource? source;
  final bool? bucketUpdated;
  final bool? rejectedOutlier;

  /// Populated only on WP5.4+. NULL on rows written by WP5.2/WP5.3 builds.
  final int? concentricMs;

  /// DTW similarity score 0.0–1.0 vs reference rep. NULL when scoring was
  /// disabled or session predates T5.3.
  final double? dtwSimilarity;

  // ── Squat-only per-rep metrics (schema v3) ──
  /// Peak forward-lean angle (degrees, signed positive) for this rep. Computed
  /// by `SquatFormAnalyzer._signedLeanDeg`. NULL on non-squat rows AND on
  /// squat rows written by builds older than schema v3.
  final double? squatLeanDeg;

  /// Peak knee-shift ratio for this rep — `(knee_x − ankle_x) / femur_len`.
  /// Informational metric; same NULL semantics as `squatLeanDeg`.
  final double? squatKneeShiftRatio;

  /// Peak heel-lift ratio for this rep — `(foot_index_y − heel_y) / leg_len`.
  /// Same NULL semantics.
  final double? squatHeelLiftRatio;

  /// `SquatVariant.name` for the variant the session ran with. NULL on
  /// non-squat rows AND on squat rows written before schema v3.
  final SquatVariant? squatVariant;

  // ── Biceps side-view per-rep metrics (schema v5) ──
  /// Peak forward-trunk-lean delta (degrees) for this rep — analyzer's
  /// `_maxLeanDeltaDeg`. NULL on non-side-view rows AND on side-view rows
  /// written by builds older than schema v5.
  final double? bicepsLeanDeg;

  /// Peak shoulder-arc displacement ratio (`disp / torso_len` in
  /// hip-relative coords) — analyzer's `_maxShoulderArcRatio`. Same NULL
  /// semantics as [bicepsLeanDeg].
  final double? bicepsShoulderDriftRatio;

  /// Peak absolute torso-perpendicular elbow-offset ratio — analyzer's
  /// `_maxDriftRatio` after the PR 2 metric switch. Same NULL semantics.
  final double? bicepsElbowDriftRatio;

  /// Peak back-lean (hyperextension) degrees — analyzer's
  /// `_maxBackLeanDeg`. Same NULL semantics.
  final double? bicepsBackLeanDeg;

  /// Signed elbow-drift ratio captured at the frame where the absolute
  /// magnitude (`bicepsElbowDriftRatio`) peaked. Drives the retune
  /// pipeline's split between forward-elbow and back-elbow cheats. Same
  /// NULL semantics as the four other biceps columns.
  final double? bicepsElbowDriftSigned;

  /// Peak shoulder-shrug ratio — schema v6. NULL on non-side-view rows and
  /// pre-v6 rows.
  final double? bicepsShrugRatio;

  /// Peak elbow-rise ratio — schema v6. NULL on non-side-view rows and
  /// pre-v6 rows.
  final double? bicepsElbowRiseRatio;

  /// Rebuild a [CurlRepRecord] when every curl-specific field is present;
  /// return null for squat/push-up rows (PR3 uses `.whereType<CurlRepRecord>()`
  /// to filter those out when feeding `SummaryScreen.fromSession`).
  CurlRepRecord? toCurlRepRecord() {
    final s = side;
    final v = view;
    final src = source;
    final bu = bucketUpdated;
    final ro = rejectedOutlier;
    final mn = minAngle;
    final mx = maxAngle;
    if (s == null ||
        v == null ||
        src == null ||
        bu == null ||
        ro == null ||
        mn == null ||
        mx == null) {
      return null;
    }
    return CurlRepRecord(
      repIndex: repIndex,
      side: s,
      view: v,
      minAngle: mn,
      maxAngle: mx,
      source: src,
      bucketUpdated: bu,
      rejectedOutlier: ro,
    );
  }
}
