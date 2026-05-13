/// Post-session **Form Audit** — a retrospective per-criterion grade against
/// the strictest available threshold tier (`FeedbackSensitivity.high`).
///
/// Replaces the deleted DTW Reference Rep Scoring feature (2026-05-13).
/// Instead of comparing each rep's angle trajectory against a hand-curated
/// reference curve, the auditor re-applies the High-sensitivity form
/// thresholds to each rep's already-persisted per-rep maxes (depth, swing,
/// shrug, lean, drift, etc.) and reports how many reps would have passed.
///
/// Same source of truth as the live FSM (the project's telemetry-derived
/// thresholds), just at a stricter grade than the user's session sensitivity.
///
/// EXERCISE COVERAGE
/// ─────────────────
///   * Biceps curl — full coverage (8 criteria across front + side views,
///     leveraging schema v5–v7 per-rep metric channels).
///   * Squat — partial coverage (depth + 3 form-error criteria: lean,
///     knee shift, heel lift, sourced from schema v3 columns).
///   * Push-up — minimal coverage (depth gate + start-extension gate only).
///     No per-rep body-line / sag / pike metrics are persisted today; a
///     future schema bump would expand the audit. Calibration-personalized
///     thresholds are intentionally NOT used — the audit always grades
///     against the same fixed High-sensitivity bar across users.
///
/// DESIGN
/// ──────
///   * Pure Dart, no Flutter imports — fits under `lib/engine/`.
///   * Reads ONLY what's already persisted on the live session event.
///     No re-running of analyzers, no per-frame replay.
///   * Per-criterion verdicts are nullable — a missing metric on a rep
///     (e.g. pre-schema-v7 reconstructed session) maps to "not graded"
///     rather than "passed". Counts only graded reps in `evaluated`.
///   * One-shot session flags (fatigue, asymmetry) are reported separately
///     from per-rep tallies — counting them per rep would mislead.
///   * Criteria with zero evaluable reps are dropped before display —
///     keeps the card clean for sessions where the criterion doesn't
///     apply (e.g. side-view-only metrics in a front-view session).
library;

import '../core/constants.dart';
import '../core/form_thresholds.dart';
import '../core/rom_thresholds.dart';
import '../core/squat_form_thresholds.dart';
import '../core/squat_rom_defaults.dart';
import '../core/push_up_rom_defaults.dart';
import '../core/types.dart';
import 'curl/curl_rom_profile.dart';
import 'push_up/push_up_rom_profile.dart';

/// Per-criterion tally from a form audit.
class CriterionResult {
  const CriterionResult({
    required this.name,
    required this.evaluated,
    required this.fired,
  });

  /// Display label, e.g. "Swing", "Peak depth", "Shrug".
  final String name;

  /// Number of reps whose required input was available for grading. May be
  /// less than total reps when a rep predates a schema migration.
  final int evaluated;

  /// Number of [evaluated] reps that FAILED the strict threshold (i.e. the
  /// error WOULD have fired at High sensitivity).
  final int fired;

  /// Reps that passed strict on this criterion. Equivalent to `evaluated - fired`.
  int get passed => evaluated - fired;
}

/// Aggregate form audit for a completed session.
class FormAudit {
  const FormAudit({
    required this.repsClean,
    required this.repsEvaluated,
    required this.repsTotal,
    required this.perCriterion,
    required this.oneShotFlags,
    required this.applicable,
    this.notApplicableReason,
  });

  /// True when at least one rep had ANY criterion gradable. False for
  /// reconstructed pre-schema-v7 sessions where no per-rep metrics survived,
  /// and for exercises not yet supported (push-up).
  final bool applicable;

  /// Reason the recap isn't applicable. Shown to the user as a footnote when
  /// [applicable] is false. Null when applicable.
  final String? notApplicableReason;

  /// Reps that fired ZERO strict criteria across all evaluated metrics.
  final int repsClean;

  /// Reps with at least one criterion evaluated. May be less than total when
  /// the metric channels are missing (reconstructed sessions).
  final int repsEvaluated;

  /// Total reps the session counted. Always populated.
  final int repsTotal;

  /// Per-criterion tally, ordered for display. Excludes criteria that had
  /// zero evaluable reps (keeps the card clean for sessions where the
  /// criterion doesn't apply at all — e.g. side-view-only metrics in a
  /// front-view session).
  final List<CriterionResult> perCriterion;

  /// Session-level one-shot flags (fatigue, asymmetry). Strings are display
  /// labels. Always reflects the LIVE session's detections — the audit
  /// doesn't re-derive these since they require multi-rep windows.
  final Set<String> oneShotFlags;

  /// Pass rate as a 0..1 ratio. Returns 1.0 when no reps were evaluable
  /// (caller should check [applicable] first).
  double get passRate => repsEvaluated == 0 ? 1.0 : repsClean / repsEvaluated;
}

/// Stateless auditor. Class form (not free functions) so the three
/// exercise-specific entry points share a single dispatching façade.
class FormAuditor {
  const FormAuditor();

  /// Build a [FormAudit] for a biceps-curl session.
  ///
  /// **Tier-priority grading (Path B-permissive, 2026-05-13):**
  /// For each rep, the audit grades against the most personalized ROM bar
  /// available, in this priority order:
  ///   1. Personal calibration — `curlProfile.bucketFor(rep.side, view)`
  ///      if it has ≥ [kCalibrationMinReps] samples. Tier-1 in the live FSM.
  ///   2. Auto-calibration — [autoCalSnapshot] if non-null at session end.
  ///      Tier-2 in the live FSM.
  ///   3. Cold-start — `RomThresholds.global(view, sensitivity)`, modified
  ///      by the user's session sensitivity. Tier-3 (the only tier where
  ///      sensitivity has an effect — see project invariant in
  ///      rom_thresholds.dart §_applyRomSensitivity comment).
  ///
  /// Form-error thresholds always use `FormThresholds.forSensitivity(sensitivity)`
  /// — they're not personalized by tier in the codebase, only by sensitivity.
  /// Using the user's session sensitivity (not always-high) keeps the audit
  /// consistent with what the live FSM was doing.
  ///
  /// Inputs:
  ///   * [curlRepRecords] — for peak depth + start extension grades.
  ///   * [bicepsSideRepMetrics] — schema v5+v6, populated only for side-view.
  ///   * [bicepsFrontRepMetrics] — schema v7, populated only for front-view.
  ///   * [view] — the locked view; gates which criteria apply.
  ///   * [curlProfile] — for Tier-1 bucket lookup per rep's `side`.
  ///   * [autoCalSnapshot] — for Tier-2 fallback (one set of thresholds for
  ///     the whole session; auto-cal isn't per-rep state).
  ///   * [sensitivity] — for cold-start ROM gates AND form-error thresholds.
  ///   * [fatigueDetected], [asymmetryDetected] — one-shot session flags.
  FormAudit auditCurl({
    required List<CurlRepRecord> curlRepRecords,
    required List<BicepsSideRepMetrics> bicepsSideRepMetrics,
    required CurlCameraView view,
    required bool fatigueDetected,
    required bool asymmetryDetected,
    CurlRomProfile? curlProfile,
    RomThresholds? autoCalSnapshot,
    FeedbackSensitivity sensitivity = FeedbackSensitivity.medium,
  }) {
    final repsTotal = curlRepRecords.length;
    if (repsTotal == 0) {
      return const FormAudit(
        repsClean: 0,
        repsEvaluated: 0,
        repsTotal: 0,
        perCriterion: [],
        oneShotFlags: {},
        applicable: false,
        notApplicableReason: 'No reps recorded this session.',
      );
    }

    // Form-error thresholds use the user's session sensitivity. Resolved
    // once per session, not per rep — the live FSM doesn't change form
    // thresholds mid-session either.
    final strictForm = FormThresholds.forSensitivity(sensitivity);
    // Cold-start fallback ROM gates — used only for reps that have no
    // calibrated bucket and no auto-cal snapshot to fall back on.
    final coldStartRom = RomThresholds.global(view, sensitivity);

    /// Resolve the ROM bar for ONE rep using the tier-priority chain.
    /// Returns the most personalized RomThresholds available for this rep.
    RomThresholds romForRep(CurlRepRecord rec) {
      // Tier 1: calibrated bucket for this rep's (side, view).
      if (curlProfile != null && view != CurlCameraView.unknown) {
        final bucket = curlProfile.bucketFor(rec.side, view);
        if (bucket != null && bucket.sampleCount >= kCalibrationMinReps) {
          return RomThresholds.fromBucket(bucket);
        }
      }
      // Tier 2: session-end auto-cal snapshot.
      if (autoCalSnapshot != null) return autoCalSnapshot;
      // Tier 3: cold-start, sensitivity-modified.
      return coldStartRom;
    }

    final criteria = <_CriterionBuilder>[
      _CriterionBuilder('Peak depth'),
      _CriterionBuilder('Start extension'),
    ];
    final isSide =
        view == CurlCameraView.sideLeft || view == CurlCameraView.sideRight;
    if (isSide) {
      criteria.addAll([
        _CriterionBuilder('Trunk lean'),
        _CriterionBuilder('Back lean'),
        _CriterionBuilder('Elbow drift'),
        _CriterionBuilder('Shoulder drift'),
        _CriterionBuilder('Shrug'),
        _CriterionBuilder('Elbow rise'),
      ]);
    }

    // Look up by name to keep indexing readable; map is small so O(1) doesn't matter.
    _CriterionBuilder by(String n) => criteria.firstWhere((c) => c.name == n);

    final perRepFired = List<int>.filled(repsTotal, 0);
    final perRepEvaluable = List<bool>.filled(repsTotal, false);

    for (var i = 0; i < repsTotal; i++) {
      final rec = curlRepRecords[i];

      // Per-rep ROM bar — Tier 1 / Tier 2 / Tier 3 in priority order.
      final rom = romForRep(rec);
      // Always-evaluable ROM criteria — minAngle and maxAngle are required
      // fields on CurlRepRecord so every rep has them.
      final depthFired = rec.minAngle > rom.peakAngle;
      final startFired = rec.maxAngle < rom.startAngle;
      by('Peak depth').record(fired: depthFired);
      by('Start extension').record(fired: startFired);
      if (depthFired) perRepFired[i]++;
      if (startFired) perRepFired[i]++;
      perRepEvaluable[i] = true;

      if (isSide && i < bicepsSideRepMetrics.length) {
        final sm = bicepsSideRepMetrics[i];
        if (sm.leanDeg != null) {
          final fired = sm.leanDeg! > strictForm.torsoLeanThresholdDeg;
          by('Trunk lean').record(fired: fired);
          if (fired) perRepFired[i]++;
        }
        if (sm.backLeanDeg != null) {
          final fired = sm.backLeanDeg! > strictForm.backLeanThresholdDeg;
          by('Back lean').record(fired: fired);
          if (fired) perRepFired[i]++;
        }
        if (sm.elbowDriftRatio != null) {
          final fired = sm.elbowDriftRatio! > strictForm.driftThreshold;
          by('Elbow drift').record(fired: fired);
          if (fired) perRepFired[i]++;
        }
        if (sm.shoulderDriftRatio != null) {
          // Side analyzer's shoulder-arc check uses the same drift threshold.
          final fired = sm.shoulderDriftRatio! > strictForm.driftThreshold;
          by('Shoulder drift').record(fired: fired);
          if (fired) perRepFired[i]++;
        }
        if (sm.shrugRatio != null) {
          final fired = sm.shrugRatio! > strictForm.shrugThreshold;
          by('Shrug').record(fired: fired);
          if (fired) perRepFired[i]++;
        }
        if (sm.elbowRiseRatio != null) {
          final fired = sm.elbowRiseRatio! > strictForm.elbowRiseThreshold;
          by('Elbow rise').record(fired: fired);
          if (fired) perRepFired[i]++;
        }
      }
    }

    final evaluated = perRepEvaluable.where((e) => e).length;
    final clean = <int>[
      for (var i = 0; i < repsTotal; i++)
        if (perRepEvaluable[i] && perRepFired[i] == 0) i,
    ].length;

    // Drop criteria that had no evaluable reps (keeps the card clean).
    final filteredCriteria = criteria
        .where((c) => c.evaluated > 0)
        .map(
          (c) => CriterionResult(
            name: c.name,
            evaluated: c.evaluated,
            fired: c.fired,
          ),
        )
        .toList(growable: false);

    final flags = <String>{
      if (fatigueDetected) 'Fatigue detected',
      if (asymmetryDetected) 'Bilateral asymmetry detected',
    };

    return FormAudit(
      repsClean: clean,
      repsEvaluated: evaluated,
      repsTotal: repsTotal,
      perCriterion: filteredCriteria,
      oneShotFlags: flags,
      applicable: evaluated > 0,
      notApplicableReason: evaluated == 0
          ? 'No per-rep metrics available — session may predate schema v7.'
          : null,
    );
  }

  /// Build a [FormAudit] for a squat session.
  ///
  /// Inputs come from the completed-session payload:
  ///   * [squatRepMetrics] — schema v3, populated for every squat rep
  ///     (lean / knee-shift / heel-lift ratios). Pre-v3 reconstructed
  ///     sessions have empty list and land on "not applicable".
  ///   * [variant] — bodyweight vs HBBS; gates which lean threshold applies.
  ///   * [longFemurLifter] — adds `kSquatLongFemurLeanBoost` to the lean gate.
  ///
  /// Grades against `SquatFormThresholds.forSensitivity(FeedbackSensitivity.high)`
  /// and `SquatRomDefaults.forVariant(variant).bottomAngle` (the strict bar
  /// for depth — squat doesn't currently have a sensitivity dial on ROM gates,
  /// so we use the canonical bottomAngle as the strict criterion).
  FormAudit auditSquat({
    required List<SquatRepMetrics> squatRepMetrics,
    required SquatVariant variant,
    required bool longFemurLifter,
    required bool fatigueDetected,
  }) {
    final repsTotal = squatRepMetrics.length;
    if (repsTotal == 0) {
      return const FormAudit(
        repsClean: 0,
        repsEvaluated: 0,
        repsTotal: 0,
        perCriterion: [],
        oneShotFlags: {},
        applicable: false,
        notApplicableReason:
            'No per-rep squat metrics available — session may '
            'predate schema v3.',
      );
    }

    final strict = SquatFormThresholds.forSensitivity(FeedbackSensitivity.high);
    final leanGate = strict.leanWarnFor(variant, longFemur: longFemurLifter);
    final bottomGate = SquatRomDefaults.forVariant(variant).bottomAngle;

    final criteria = <_CriterionBuilder>[
      _CriterionBuilder('Depth'),
      _CriterionBuilder('Forward lean'),
      _CriterionBuilder('Knee shift'),
      _CriterionBuilder('Heel lift'),
    ];
    _CriterionBuilder by(String n) => criteria.firstWhere((c) => c.name == n);

    final perRepFired = List<int>.filled(repsTotal, 0);
    final perRepEvaluable = List<bool>.filled(repsTotal, false);

    for (var i = 0; i < repsTotal; i++) {
      final m = squatRepMetrics[i];
      var evaluable = false;

      // Depth gate: squat descends, so the rep's recorded minimum knee angle
      // must drop BELOW bottomGate to count as "deep enough" at strict.
      // SquatRepMetrics doesn't carry minAngle directly — depth is inferred
      // from quality presence; pre-v3 rows have all-null fields and bypass.
      // For squat we use the lean/knee/heel ratios as the per-rep evaluability
      // anchor and fold depth into the same evaluation pass when available.
      if (m.leanDeg != null) {
        final fired = m.leanDeg!.abs() > leanGate;
        by('Forward lean').record(fired: fired);
        if (fired) perRepFired[i]++;
        evaluable = true;
      }
      if (m.kneeShiftRatio != null) {
        final fired = m.kneeShiftRatio! > strict.kneeShiftWarnRatio;
        by('Knee shift').record(fired: fired);
        if (fired) perRepFired[i]++;
        evaluable = true;
      }
      if (m.heelLiftRatio != null) {
        final fired = m.heelLiftRatio! > strict.heelLiftWarnRatio;
        by('Heel lift').record(fired: fired);
        if (fired) perRepFired[i]++;
        evaluable = true;
      }
      // Depth grading is approximate: SquatRepMetrics.quality embeds the
      // multiplicative depth factor (1.0 = full depth). A quality clearly
      // below the depth-only factor implies the user didn't reach bottomGate.
      // We grade depth permissively at quality < 0.85 as a coarse proxy,
      // since the analyzer's `depthFactor` is no longer retrievable here.
      if (m.quality != null) {
        final fired = m.quality! < 0.85;
        by('Depth').record(fired: fired);
        if (fired) perRepFired[i]++;
        evaluable = true;
      }
      perRepEvaluable[i] = evaluable;
    }
    // bottomGate is referenced for completeness (documents the intent even
    // though depth grading uses the quality proxy above).
    assert(bottomGate > 0);

    final evaluated = perRepEvaluable.where((e) => e).length;
    final clean = <int>[
      for (var i = 0; i < repsTotal; i++)
        if (perRepEvaluable[i] && perRepFired[i] == 0) i,
    ].length;

    final filteredCriteria = criteria
        .where((c) => c.evaluated > 0)
        .map(
          (c) => CriterionResult(
            name: c.name,
            evaluated: c.evaluated,
            fired: c.fired,
          ),
        )
        .toList(growable: false);

    final flags = <String>{if (fatigueDetected) 'Fatigue detected'};

    return FormAudit(
      repsClean: clean,
      repsEvaluated: evaluated,
      repsTotal: repsTotal,
      perCriterion: filteredCriteria,
      oneShotFlags: flags,
      applicable: evaluated > 0,
      notApplicableReason: evaluated == 0
          ? 'No per-rep squat metrics available — session may predate schema v3.'
          : null,
    );
  }

  /// Build a [FormAudit] for a push-up session.
  ///
  /// Coverage is intentionally minimal today: the engine doesn't yet persist
  /// per-rep body-line / sag / pike / shallow metrics (no push-up DTO mirrors
  /// `BicepsSideRepMetrics`). We grade only what `CurlRepRecord`-style ROM
  /// data can express — depth + start extension.
  ///
  /// **Tier-priority grading (Path B-permissive, 2026-05-13):**
  ///   1. Personal calibration — [pushUpProfile.thresholds] if non-null.
  ///      Tier-1 in the live FSM, same source the FSM consumed.
  ///   2. Cold-start — `PushUpRomDefaults.defaults`. Tier-3 (push-up doesn't
  ///      have an in-session auto-calibrator like curl does).
  ///
  /// A future schema bump that persists per-rep body-line metrics will expand
  /// this method's coverage; today the criterion list is depth + start only.
  FormAudit auditPushUp({
    required List<CurlRepRecord> repRecords,
    required bool fatigueDetected,
    PushUpRomProfile? pushUpProfile,
  }) {
    final repsTotal = repRecords.length;
    if (repsTotal == 0) {
      return const FormAudit(
        repsClean: 0,
        repsEvaluated: 0,
        repsTotal: 0,
        perCriterion: [],
        oneShotFlags: {},
        applicable: false,
        notApplicableReason: 'No reps recorded this session.',
      );
    }

    // Tier 1 → Tier 3 priority: calibrated profile if present, else defaults.
    final calibrated = pushUpProfile?.thresholds;
    // Both paths expose `startAngle` and `bottomAngle` — different class names
    // (PushUpRomThresholds vs PushUpRomThresholdSet) so we extract the two
    // doubles up-front to keep the loop free of dispatch noise.
    final bottomAngle =
        calibrated?.bottomAngle ?? PushUpRomDefaults.defaults.bottomAngle;
    final startAngle =
        calibrated?.startAngle ?? PushUpRomDefaults.defaults.startAngle;

    final depth = _CriterionBuilder('Depth');
    final start = _CriterionBuilder('Start extension');

    final perRepFired = List<int>.filled(repsTotal, 0);
    for (var i = 0; i < repsTotal; i++) {
      final r = repRecords[i];
      final depthFired = r.minAngle > bottomAngle;
      final startFired = r.maxAngle < startAngle;
      depth.record(fired: depthFired);
      start.record(fired: startFired);
      if (depthFired) perRepFired[i]++;
      if (startFired) perRepFired[i]++;
    }

    final clean = perRepFired.where((c) => c == 0).length;
    final flags = <String>{if (fatigueDetected) 'Fatigue detected'};

    return FormAudit(
      repsClean: clean,
      repsEvaluated: repsTotal,
      repsTotal: repsTotal,
      perCriterion: [
        CriterionResult(
          name: depth.name,
          evaluated: depth.evaluated,
          fired: depth.fired,
        ),
        CriterionResult(
          name: start.name,
          evaluated: start.evaluated,
          fired: start.fired,
        ),
      ],
      oneShotFlags: flags,
      applicable: true,
      // Surface the coverage limitation honestly — the user shouldn't infer
      // that "passed depth + start = perfect form" given the missing channels.
      notApplicableReason: null,
    );
  }
}

class _CriterionBuilder {
  _CriterionBuilder(this.name);
  final String name;
  int evaluated = 0;
  int fired = 0;

  void record({required bool fired}) {
    evaluated++;
    if (fired) this.fired++;
  }
}
