import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../core/types.dart';
import '../engine/form_auditor.dart';
import 'session_summary_input.dart';

/// Immutable view of everything the Session Complete page renders, regardless
/// of exercise. The `SummaryScreen` builds a [SessionSummaryInput] from its
/// widget fields and calls [SessionSummaryViewModel.fromInput] once per
/// build to produce one of these. The screen then reads slot data from the
/// fields below and hands them to shared widgets.
///
/// Rationale: the summary is a terminal page (no live updates), so a plain
/// value class is the right primitive. ChangeNotifier would be ritual.
///
/// The VM never imports `screens/` — input comes through the
/// [SessionSummaryInput] DTO. Adding a new exercise is a new private
/// factory in this file plus a switch arm in [fromInput].
@immutable
class SessionSummaryViewModel {
  const SessionSummaryViewModel({
    required this.exerciseLabel,
    required this.qualityPct,
    required this.grade,
    required this.heroSubtitle,
    required this.reps,
    required this.sets,
    required this.duration,
    required this.variantLabels,
    required this.repQualities,
    required this.formIssues,
    required this.formIssueCounts,
    required this.insights,
    required this.formAudit,
  });

  /// Display name of the exercise (e.g. "Biceps Curl (Side)").
  final String exerciseLabel;

  /// Mean form-accuracy percentage (0..100). Null when no quality data.
  final int? qualityPct;

  /// Letter grade derived from [qualityPct]: 'A'..'F' or '—'.
  final String grade;

  /// One-line subtitle under the score.
  final String heroSubtitle;

  final int reps;
  final int sets;
  final Duration duration;

  /// Exercise-variant chips (e.g. ["High-bar", "Tall lifter (+5°)"] for squat).
  /// Empty list when the exercise has no variant axis to surface.
  final List<String> variantLabels;

  /// Per-rep quality scores in 0.0..1.0. May be empty.
  final List<double> repQualities;

  /// Form-error chips to show in the issues card. Already filtered for the
  /// exercise — never includes errors from other exercises.
  final List<FormError> formIssues;

  /// Fire counts per error, for the `×N` badge on chips.
  final Map<FormError, int> formIssueCounts;

  /// Coaching-insight strings, in display order. May be empty.
  final List<String> insights;

  /// Form audit result from [FormAuditor]. Always non-null — the auditor
  /// returns a `notApplicable` recap when it cannot grade the session.
  /// The screen reads this directly; the auditor runs exactly once per
  /// build (in the factory).
  final FormAudit formAudit;

  /// True iff there is anything to render in the form-issues slot. Mirrors
  /// the legacy curl behavior: errors that fired on uncommitted reps are
  /// suppressed because surfacing them without a rep context is misleading.
  bool get hasFormIssues => formIssues.isNotEmpty && reps > 0;

  /// True iff there is anything to render in the insights slot.
  bool get hasInsights => insights.isNotEmpty;

  /// Build a VM from the screen's input DTO. The screen calls this in
  /// `build()` and passes the result into shared widgets.
  factory SessionSummaryViewModel.fromInput(SessionSummaryInput input) {
    if (input.exercise.isCurl) return _fromCurl(input);
    if (input.exercise == ExerciseType.squat) return _fromSquat(input);
    if (input.exercise == ExerciseType.pushUp) return _fromPushUp(input);
    if (input.exercise == ExerciseType.plank) return _fromPlank(input);
    throw StateError('Unhandled exercise: ${input.exercise}');
  }
}

// ── Shared helpers ──────────────────────────────────────────────────────────

String _gradeLabel(double? q) {
  if (q == null) return '—';
  if (q >= 0.90) return 'A';
  if (q >= 0.80) return 'B';
  if (q >= 0.70) return 'C';
  if (q >= 0.60) return 'D';
  return 'F';
}

String _qualitySubtitle(double? q, int totalReps) {
  if (q == null) {
    if (totalReps == 0) {
      return 'No reps were counted — see the coaching tip below.';
    }
    return 'No quality data captured for this session.';
  }
  if (q >= 0.85) return 'Excellent control. Maintain this pace and range.';
  if (q >= 0.70) return 'Good effort. Minor form deductions noted.';
  if (q >= 0.60) return 'Room for improvement. Review the insights below.';
  return 'Several form issues detected. Focus on the coaching tips.';
}

double? _meanRepQuality({
  required int totalReps,
  required List<double> repQualities,
  required double? averageQuality,
}) {
  if (totalReps == 0) return null;
  if (repQualities.isEmpty) return averageQuality;
  final nonZero = repQualities.where((q) => q > 0).toList();
  if (nonZero.isEmpty) return null;
  return nonZero.reduce((a, b) => a + b) / nonZero.length;
}

int? _qualityPct(double? quality) =>
    quality == null ? null : (quality * 100).round();

/// Final fallback insight: emitted by every exercise when no other coaching
/// line fired and quality is below the "Excellent" tier.
void _appendFallbackInsight(List<String> insights, SessionSummaryInput input) {
  if (insights.isNotEmpty) return;
  if (input.averageQuality != null && input.averageQuality! >= 0.85) {
    insights.add('Great session! Keep this tempo and range of motion.');
  } else {
    insights.add(
      'Review the form issues above and focus on one correction at a time.',
    );
  }
}

// ── Curl factory ────────────────────────────────────────────────────────────

SessionSummaryViewModel _fromCurl(SessionSummaryInput input) {
  final quality = _meanRepQuality(
    totalReps: input.totalReps,
    repQualities: input.repQualities,
    averageQuality: input.averageQuality,
  );

  // Curl-side form errors that are surfaced in the issues card. Excludes
  // exercise-specific errors that belong to squat/push-up.
  const curlExcluded = <FormError>{
    FormError.squatDepth,
    FormError.trunkTibia,
    FormError.hipSag,
    FormError.pushUpShortRom,
    FormError.excessiveForwardLean,
    FormError.heelLift,
    FormError.forwardKneeShift,
    FormError.hipLead,
    // Defense-in-depth: other exercises' tempo/fatigue enums (2026-05-16)
    // can never appear in a curl session (one exercise per session), but
    // the existing convention explicitly excludes cross-exercise errors —
    // keep that invariant intact so a future shared-session path can't leak
    // squat/push-up tempo onto the curl issues card. Curl's OWN tempo
    // errors (eccentricTooFast/concentricTooFast/tempoInconsistent/
    // fatigue) are deliberately NOT excluded — they still surface here.
    FormError.squatEccentricTooFast,
    FormError.squatConcentricTooFast,
    FormError.squatTempoInconsistent,
    FormError.squatFatigue,
    FormError.pushUpEccentricTooFast,
    FormError.pushUpConcentricTooFast,
    FormError.pushUpTempoInconsistent,
    FormError.pushUpFatigue,
  };
  final issues = input.errorsTriggered
      .where((e) => !curlExcluded.contains(e))
      .toList();

  final audit = const FormAuditor().auditCurl(
    curlRepRecords: input.curlRepRecords,
    bicepsSideRepMetrics: input.bicepsSideRepMetrics,
    view: input.detectedView,
    fatigueDetected: input.fatigueDetected,
    asymmetryDetected: input.asymmetryDetected,
    curlProfile: input.curlProfile,
    autoCalSnapshot: input.autoCalSnapshot,
    sensitivity: input.feedbackSensitivity,
  );

  return SessionSummaryViewModel(
    exerciseLabel: input.exercise.label,
    qualityPct: _qualityPct(quality),
    grade: _gradeLabel(quality),
    heroSubtitle: _qualitySubtitle(quality, input.totalReps),
    reps: input.totalReps,
    sets: input.totalSets,
    duration: input.sessionDuration,
    variantLabels: const [],
    repQualities: input.repQualities,
    formIssues: issues,
    formIssueCounts: input.errorCounts,
    insights: _curlInsights(input),
    formAudit: audit,
  );
}

List<String> _curlInsights(SessionSummaryInput input) {
  final insights = <String>[];

  if (input.totalReps == 0) {
    insights.add(
      'No reps were counted. Make sure your full arm — shoulder, '
      'elbow, and wrist — stays in frame throughout the curl. Try '
      'stepping back from the camera or rotating to landscape.',
    );
    return insights;
  }

  if (input.eccentricTooFastCount > input.totalReps * 0.5) {
    insights.add(
      'You rushed the lowering phase on most reps. Try a 2-second '
      'count on the way down.',
    );
  } else if (input.eccentricTooFastCount > 0) {
    insights.add(
      'You rushed the lowering on ${input.eccentricTooFastCount} rep(s). '
      'Slow, controlled lowering builds more muscle.',
    );
  }

  if (input.fatigueDetected) {
    insights.add(
      'Fatigue detected mid-session. Consider shorter sets with full '
      'recovery between them.',
    );
  }

  if (input.asymmetryDetected) {
    insights.add(
      'Your arms showed uneven range. Focus on matching both sides for '
      'balanced development.',
    );
  }

  // Side-view specific coaching — only fires when metrics were recorded.
  // Camera-frame → user-frame flip: sideLeft = camera's left = user's RIGHT
  // arm (front-camera mirroring). Falls back to generic "arm" when unknown.
  final armLabel = switch (input.detectedView) {
    CurlCameraView.sideLeft => 'right arm',
    CurlCameraView.sideRight => 'left arm',
    _ => 'arm',
  };

  double? avg(double? Function(BicepsSideRepMetrics) pick) {
    final vals = input.bicepsSideRepMetrics
        .map(pick)
        .whereType<double>()
        .toList();
    if (vals.isEmpty) return null;
    return vals.reduce((a, b) => a + b) / vals.length;
  }

  final avgElbowRise = avg((r) => r.elbowRiseRatio);
  if (avgElbowRise != null && avgElbowRise > kElbowRiseThreshold) {
    insights.add(
      'Your elbow rose on your $armLabel during the curl. Keep it pinned '
      'to your side — lifting it shifts load away from the bicep.',
    );
  }

  final avgBackLean = avg((r) => r.backLeanDeg);
  if (avgBackLean != null && avgBackLean > kBackLeanThresholdDeg) {
    insights.add(
      'You leaned back to complete the $armLabel curl. Reduce the weight '
      'and keep your torso upright throughout.',
    );
  }

  final avgShrug = avg((r) => r.shrugRatio);
  if (avgShrug != null && avgShrug > kShrugThreshold) {
    insights.add(
      'Your $armLabel shoulder shrugged on most reps. Depress your '
      'shoulder blade before curling to isolate the bicep.',
    );
  }

  _appendFallbackInsight(insights, input);
  return insights;
}

// ── Squat factory ───────────────────────────────────────────────────────────

SessionSummaryViewModel _fromSquat(SessionSummaryInput input) {
  final quality = _meanRepQuality(
    totalReps: input.totalReps,
    repQualities: input.repQualities,
    averageQuality: input.averageQuality,
  );

  // Variant chips: squat-only. Always include the variant label;
  // tall-lifter chip is opt-in.
  final variantLabels = <String>[
    input.squatVariant.label,
    if (input.squatLongFemurLifter) 'Tall lifter (+5°)',
  ];

  // Squat form-error whitelist. Legacy trunkTibia is rendered separately by
  // the curl-only legacy subhead and is intentionally excluded here.
  const squatErrors = <FormError>{
    FormError.excessiveForwardLean,
    FormError.heelLift,
    FormError.forwardKneeShift,
    FormError.squatDepth,
    // Tempo/fatigue (2026-05-16, curl-parity). Surfaced on the issues card
    // like heelLift/squatDepth — they carry a TTS cue AND a real
    // training-quality signal (unlike the cue-only noKneeFlexion /
    // kneeLedDescent which stay intentionally off the card).
    FormError.squatEccentricTooFast,
    FormError.squatConcentricTooFast,
    FormError.squatTempoInconsistent,
    FormError.squatFatigue,
  };
  final issues = input.errorsTriggered.where(squatErrors.contains).toList();

  final audit = const FormAuditor().auditSquat(
    squatRepMetrics: input.squatRepMetrics,
    variant: input.squatVariant,
    longFemurLifter: input.squatLongFemurLifter,
    fatigueDetected: input.fatigueDetected,
    squatProfile: input.squatProfile,
    autoCalSnapshot: input.squatAutoCalSnapshot,
    sensitivity: input.feedbackSensitivity,
    hipLeadFireCount: input.errorCounts[FormError.hipLead] ?? 0,
  );

  return SessionSummaryViewModel(
    exerciseLabel: input.exercise.label,
    qualityPct: _qualityPct(quality),
    grade: _gradeLabel(quality),
    heroSubtitle: _qualitySubtitle(quality, input.totalReps),
    reps: input.totalReps,
    sets: input.totalSets,
    duration: input.sessionDuration,
    variantLabels: variantLabels,
    repQualities: input.repQualities,
    formIssues: issues,
    formIssueCounts: input.errorCounts,
    insights: _squatInsights(input),
    formAudit: audit,
  );
}

List<String> _squatInsights(SessionSummaryInput input) {
  final insights = <String>[];

  if (input.totalReps == 0) {
    insights.add(
      'No reps were counted. Make sure your full body — hips, knees, '
      'and feet — is in frame and the camera has a clear side angle.',
    );
    return insights;
  }

  if (input.errorsTriggered.contains(FormError.squatDepth)) {
    insights.add(
      'Some reps did not reach full depth. Sit your hips back and aim to '
      'break parallel — thighs at or below horizontal.',
    );
  }

  if (input.errorsTriggered.contains(FormError.excessiveForwardLean)) {
    insights.add(
      'Your torso leaned forward on some reps. Keep your chest up and '
      'drive through the heels to maintain a vertical bar path.',
    );
  }

  if (input.errorsTriggered.contains(FormError.heelLift)) {
    insights.add(
      'Your heels lifted on some reps. Push the floor away through the '
      'whole foot — heels stay planted from start to lockout.',
    );
  }

  if (input.errorsTriggered.contains(FormError.forwardKneeShift)) {
    insights.add(
      'Your knees shifted forward past your toes on some reps. Sit back '
      'into the squat first; the knees track over the mid-foot, not in '
      'front of it.',
    );
  }

  if (input.fatigueDetected) {
    insights.add(
      'Fatigue detected mid-session. Drop a set or reduce the load to '
      'maintain form rather than letting depth degrade.',
    );
  }

  // Tempo / fatigue (2026-05-16, curl-parity). Driven off the
  // `errorsTriggered` set — the channel the new per-exercise enums flow
  // through (squat's `fatigueDetected` snapshot bool is curl-shaped and
  // does not carry `squatFatigue`, so it's checked separately here).
  if (input.errorsTriggered.contains(FormError.squatEccentricTooFast)) {
    insights.add(
      'You dropped into some squats too quickly. Control the descent — '
      'a 2-3 second lowering builds strength and protects the knees.',
    );
  }
  if (input.errorsTriggered.contains(FormError.squatConcentricTooFast)) {
    insights.add(
      'Some drives out of the bottom were rushed. Push the floor away '
      'with intent, but stay controlled — no bouncing out of the hole.',
    );
  }
  if (input.errorsTriggered.contains(FormError.squatTempoInconsistent)) {
    insights.add(
      'Your rep tempo varied widely. A steady, repeatable cadence is a '
      'better strength signal than alternating slow and fast reps.',
    );
  }
  if (input.errorsTriggered.contains(FormError.squatFatigue)) {
    insights.add(
      'Your ascent slowed across the set — a fatigue signature. End the '
      'set while form is clean rather than grinding slow reps.',
    );
  }

  _appendFallbackInsight(insights, input);
  return insights;
}

// ── Push-up factory ─────────────────────────────────────────────────────────

SessionSummaryViewModel _fromPushUp(SessionSummaryInput input) {
  final quality = _meanRepQuality(
    totalReps: input.totalReps,
    repQualities: input.repQualities,
    averageQuality: input.averageQuality,
  );

  // Only push-up errors land in the issues card. The four tempo/fatigue
  // enums (2026-05-16, curl-parity) are push-up-scoped and belong here so
  // the issues card count stays consistent with the coaching insights
  // below.
  const pushUpErrors = <FormError>{
    FormError.hipSag,
    FormError.pushUpShortRom,
    FormError.pushUpEccentricTooFast,
    FormError.pushUpConcentricTooFast,
    FormError.pushUpTempoInconsistent,
    FormError.pushUpFatigue,
  };
  final issues = input.errorsTriggered.where(pushUpErrors.contains).toList();

  final audit = const FormAuditor().auditPushUp(
    repRecords: input.curlRepRecords,
    fatigueDetected: input.fatigueDetected,
    pushUpProfile: input.pushUpProfile,
    sensitivity: input.feedbackSensitivity,
  );

  return SessionSummaryViewModel(
    exerciseLabel: input.exercise.label,
    qualityPct: _qualityPct(quality),
    grade: _gradeLabel(quality),
    heroSubtitle: _qualitySubtitle(quality, input.totalReps),
    reps: input.totalReps,
    sets: input.totalSets,
    duration: input.sessionDuration,
    variantLabels: const [],
    repQualities: input.repQualities,
    formIssues: issues,
    formIssueCounts: input.errorCounts,
    insights: _pushUpInsights(input),
    formAudit: audit,
  );
}

List<String> _pushUpInsights(SessionSummaryInput input) {
  final insights = <String>[];

  if (input.totalReps == 0) {
    insights.add(
      'No reps were counted. Make sure your full body — head, hips, '
      'and feet — is in frame and the camera has a clear side angle.',
    );
    return insights;
  }

  if (input.errorsTriggered.contains(FormError.hipSag)) {
    insights.add(
      'Your hips dropped on some reps. Engage your core and form a '
      'straight line from shoulders to ankles throughout the push-up.',
    );
  }

  if (input.errorsTriggered.contains(FormError.pushUpShortRom)) {
    insights.add(
      'Some reps did not reach full depth. Lower until your chest is '
      'close to the floor with your elbows at roughly 90°.',
    );
  }

  if (input.fatigueDetected) {
    insights.add(
      'Fatigue detected mid-session. Drop to your knees to maintain '
      'form rather than letting reps degrade.',
    );
  }

  // Tempo / fatigue (2026-05-16, curl-parity). Driven off `errorsTriggered`
  // — the channel the per-exercise push-up tempo enums flow through.
  if (input.errorsTriggered.contains(FormError.pushUpEccentricTooFast)) {
    insights.add(
      'You dropped into some push-ups too quickly. Control the descent — '
      'a slow, deliberate lowering builds more pressing strength.',
    );
  }
  if (input.errorsTriggered.contains(FormError.pushUpConcentricTooFast)) {
    insights.add(
      'Some presses were rushed. Drive up with intent but stay controlled '
      'through the full range — no snapping the elbows.',
    );
  }
  if (input.errorsTriggered.contains(FormError.pushUpTempoInconsistent)) {
    insights.add(
      'Your rep tempo varied widely. A steady cadence is a better strength '
      'and endurance signal than alternating slow and fast reps.',
    );
  }
  if (input.errorsTriggered.contains(FormError.pushUpFatigue)) {
    insights.add(
      'Your press slowed across the set — a fatigue signature. Stop while '
      'form is clean rather than grinding slow reps.',
    );
  }

  _appendFallbackInsight(insights, input);
  return insights;
}

SessionSummaryViewModel _fromPlank(SessionSummaryInput input) {
  final quality = input.repQualities.isNotEmpty
      ? input.repQualities.reduce((a, b) => a + b) / input.repQualities.length
      : input.averageQuality;

  const plankErrors = <FormError>{
    FormError.plankArmAngle,
    FormError.plankBodyLine,
  };
  final issues = input.errorsTriggered.where(plankErrors.contains).toList();

  final audit = const FormAuditor().auditPlank(
    holdSeconds: input.totalReps,
    errorCounts: input.errorCounts,
  );

  return SessionSummaryViewModel(
    exerciseLabel: input.exercise.label,
    qualityPct: _qualityPct(quality),
    grade: _gradeLabel(quality),
    heroSubtitle: _plankQualitySubtitle(quality, input.totalReps),
    reps: input.totalReps,
    sets: input.totalSets,
    duration: input.sessionDuration,
    variantLabels: const [],
    repQualities: input.repQualities,
    formIssues: issues,
    formIssueCounts: input.errorCounts,
    insights: _plankInsights(input),
    formAudit: audit,
  );
}

String _plankQualitySubtitle(double? q, int holdSeconds) {
  if (holdSeconds == 0) {
    return 'No clean hold seconds were recorded.';
  }
  if (q == null) return 'No quality data captured for this hold.';
  if (q >= 0.85) return 'Strong hold. Keep that straight body line.';
  if (q >= 0.70) return 'Good hold. A few posture breaks were detected.';
  return 'Form broke during the hold. Review the cues below.';
}

List<String> _plankInsights(SessionSummaryInput input) {
  final insights = <String>[];

  if (input.totalReps == 0) {
    insights.add(
      'No clean plank time was counted. Set the phone to a side view a few '
      'meters away so shoulders, elbows, hips, and ankles stay visible.',
    );
    return insights;
  }

  if (input.errorsTriggered.contains(FormError.plankArmAngle)) {
    insights.add(
      'Your support position drifted. Keep elbows close to 90 degrees and '
      'stack shoulders over elbows.',
    );
  }
  if (input.errorsTriggered.contains(FormError.plankBodyLine)) {
    insights.add(
      'Your back or hips moved out of line. Brace your core and keep a '
      'straight line from shoulders through hips to ankles.',
    );
  }

  if (insights.isEmpty) {
    insights.add('Clean plank hold. Add time gradually while preserving form.');
  }
  return insights;
}
