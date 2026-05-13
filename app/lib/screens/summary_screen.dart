import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../core/constants.dart';
import '../core/rom_thresholds.dart';
import '../core/theme.dart';
import '../core/types.dart';
import '../core/squat_rom_defaults.dart';
import '../engine/curl/curl_rom_profile.dart';
import '../engine/form_auditor.dart';
import '../engine/push_up/push_up_rom_profile.dart';
import '../engine/squat/squat_rom_profile.dart';
import '../services/db/session_dtos.dart';
import '../view_models/session_summary_input.dart';
import '../view_models/session_summary_view_model.dart';
import '../widgets/summary/summary_actions.dart';
import '../widgets/summary/summary_form_issues_card.dart';
import '../widgets/summary/summary_hero.dart';
import '../widgets/summary/summary_insights_card.dart';
import '../widgets/summary/summary_stats_grid.dart';
import '../widgets/summary/summary_variant_chips.dart';

class SummaryScreen extends StatefulWidget {
  final ExerciseType exercise;
  final int totalReps;
  final int totalSets;
  final Duration sessionDuration;
  final double? averageQuality;
  final CurlCameraView detectedView;
  final List<double> repQualities;
  final bool fatigueDetected;
  final bool asymmetryDetected;
  final int eccentricTooFastCount;
  final Set<FormError> errorsTriggered;

  /// How many times each error fired this session. Used to show "×N" counts
  /// on the Form Issues chips. Empty for live sessions that don't supply counts.
  final Map<FormError, int> errorCounts;

  /// Per-rep detail for the curl session (optional — non-curl or pre-plumbing
  /// flows pass empty). Populates the "Details" panel.
  final List<CurlRepRecord> curlRepRecords;

  /// Snapshot of all `(side, view)` buckets the engine knows about at summary
  /// time. Filtered to touched-this-session + any fully-calibrated bucket on
  /// the caller side — summary just renders what it gets.
  final List<CurlProfileBucketSummary> curlBucketSummaries;

  /// _Removed 2026-05-13:_ DTW reference rep scoring was replaced by the
  /// Strict-Mode Recap card. The Form Match Card no longer exists.

  /// Squat variant the session ran with. Used in the squat header chip.
  final SquatVariant squatVariant;

  /// True if the session ran with the "Tall lifter" toggle on. Surfaces as
  /// a small chip in the squat summary header.
  final bool squatLongFemurLifter;

  /// Per-rep squat metrics (lean / knee-shift / heel-lift ratios).
  /// Index-aligned with the rep order. Empty for non-squat sessions or
  /// reconstructed (history) squat sessions where ratios aren't persisted.
  final List<SquatRepMetrics> squatRepMetrics;

  /// Per-rep biceps side-view metrics — lean, shoulder arc, elbow drift,
  /// back lean, shrug, elbow rise. Index-aligned with the rep order.
  /// Empty for front curl, squat, push-up, and reconstructed sessions
  /// predating schema v5.
  final List<BicepsSideRepMetrics> bicepsSideRepMetrics;

  /// Personal curl ROM profile in effect — drives the Form Audit's Tier-1
  /// (per-bucket personalized) ROM bar. Null when the user has no curl
  /// calibration data or the session isn't a curl session.
  final CurlRomProfile? curlProfile;

  /// Personal push-up ROM profile in effect — drives the Form Audit's
  /// Tier-1 personalized push-up depth / start gates. Null when uncalibrated.
  final PushUpRomProfile? pushUpProfile;

  /// Personal squat ROM profile in effect — drives the Form Audit's Tier-1
  /// per-rep depth gate (real `minKneeAngle` comparison, replacing the
  /// pre-Part-4 `quality < 0.85` proxy). Null when the user has no squat
  /// calibration data or this isn't a squat session. Reconstructed history
  /// sessions also pass null — live bucket state isn't persisted.
  final SquatRomProfile? squatProfile;

  /// Auto-calibrator's session-end thresholds, if it accumulated viable
  /// state. Form Audit's Tier-2 fallback for curl when no calibrated
  /// `(side, view)` bucket exists.
  final RomThresholds? autoCalSnapshot;

  /// Squat auto-calibrator's session-end thresholds — Tier-2 fallback for
  /// the squat audit. Null when fewer than 2 viable reps were observed
  /// this session or when this isn't a squat session.
  final SquatRomThresholdSet? squatAutoCalSnapshot;

  /// Session sensitivity — drives form-error thresholds in the audit and
  /// the cold-start fallback ROM gates.
  final FeedbackSensitivity feedbackSensitivity;

  /// Per-rep concentric duration in milliseconds. NULL elements are reps
  /// with no captured tempo (rare — abandoned reps; or non-curl live
  /// sessions where the live VM doesn't surface duration). Drives the
  /// summary's TEMPO stat (`avg of non-null / 1000`, formatted "X.Xs").
  final List<int?> repConcentricMs;

  /// Per-rep depth as a fraction (0.0–1.0) of the user's reference range.
  /// Reference range is the calibrated bucket's peak ROM when available
  /// (curl, live path); otherwise the session's max ROM (fallback /
  /// reconstructed path). NULL elements are reps with no usable angles.
  /// Drives the summary's DEPTH stat (`avg of non-null × 100%`).
  final List<double?> repDepthPercents;

  const SummaryScreen({
    super.key,
    required this.exercise,
    required this.totalReps,
    required this.totalSets,
    required this.sessionDuration,
    this.averageQuality,
    this.detectedView = CurlCameraView.unknown,
    this.repQualities = const [],
    this.fatigueDetected = false,
    this.asymmetryDetected = false,
    this.eccentricTooFastCount = 0,
    this.errorsTriggered = const {},
    this.errorCounts = const {},
    this.curlRepRecords = const [],
    this.curlBucketSummaries = const [],
    this.squatVariant = SquatVariant.bodyweight,
    this.squatLongFemurLifter = false,
    this.squatRepMetrics = const [],
    this.bicepsSideRepMetrics = const [],
    this.curlProfile,
    this.pushUpProfile,
    this.squatProfile,
    this.autoCalSnapshot,
    this.squatAutoCalSnapshot,
    this.feedbackSensitivity = FeedbackSensitivity.medium,
    this.repConcentricMs = const [],
    this.repDepthPercents = const [],
  });

  /// Rebuild a SummaryScreen from a persisted [SessionDetail] — used by the
  /// History screen's reopen path. Widget tree is untouched; only the data
  /// source changes. Bucket summaries are live-only state (engine ring-buffer
  /// counters don't persist across sessions), so the Details panel's bucket
  /// block collapses on reconstructed sessions — acceptable per plan.
  ///
  /// Squat-specific live state (variant, long-femur toggle, per-rep ratios)
  /// also doesn't persist in v1 — the reconstructed squat summary shows
  /// everything except the per-rep ratio strip.
  factory SummaryScreen.fromSession(SessionDetail d, {Key? key}) {
    final s = d.summary;
    // Curl rep records: only curl rows produce a non-null CurlRepRecord
    // (their `side`/`view`/`source` are NULL on squat and push-up rows, so
    // `toCurlRepRecord` returns null and the whereType filters them out).
    // Push-up reps are reconstructed separately below via a minimal-angle
    // `CurlRepRecord` so the push-up audit path can read minAngle/maxAngle.
    final isPushUp = s.exercise == ExerciseType.pushUp;
    final curlRecords = isPushUp
        ? _reconstructPushUpRepRecords(d)
        : d.reps
              .map((r) => r.toCurlRepRecord())
              .whereType<CurlRepRecord>()
              .toList(growable: false);
    final qualities = d.reps
        .map((r) => r.quality ?? 0.0)
        .toList(growable: false);
    final concentricMs = d.reps
        .map((r) => r.concentricMs)
        .toList(growable: false);
    // Squat per-rep metrics: reconstruct from the persisted squat columns
    // (schema v3 onward for lean/knee-shift/heel-lift, v9 for the
    // min/maxKneeAngle pair). Pre-v3 rows produce an empty list, which the
    // squat audit downgrades to a `notApplicable` recap with a clear reason.
    final isSquat = s.exercise == ExerciseType.squat;
    final squatMetrics = isSquat
        ? d.reps
              .where(
                (r) =>
                    r.squatLeanDeg != null ||
                    r.squatKneeShiftRatio != null ||
                    r.squatHeelLiftRatio != null ||
                    r.squatMinKneeAngle != null ||
                    r.squatMaxKneeAngle != null,
              )
              .map(
                (r) => SquatRepMetrics(
                  repIndex: r.repIndex,
                  quality: r.quality,
                  leanDeg: r.squatLeanDeg,
                  kneeShiftRatio: r.squatKneeShiftRatio,
                  heelLiftRatio: r.squatHeelLiftRatio,
                  minKneeAngle: r.squatMinKneeAngle,
                  maxKneeAngle: r.squatMaxKneeAngle,
                ),
              )
              .toList(growable: false)
        : const <SquatRepMetrics>[];
    // Squat variant: persisted per rep (`squat_variant` column). All rows
    // in a session share the same value, so the first non-null one wins.
    // Pre-v3 rows have null → defaults to bodyweight, which is the same
    // fallback the constructor uses.
    final squatVariant = isSquat
        ? d.reps
                  .firstWhere(
                    (r) => r.squatVariant != null,
                    orElse: () => const RepRow(repIndex: 0),
                  )
                  .squatVariant ??
              SquatVariant.bodyweight
        : SquatVariant.bodyweight;
    // Reconstructed depth: normalize per-rep ROM to the session's max ROM.
    // The calibrated-bucket path used live isn't available here (bucket
    // state isn't persisted), so session-best is the honest fallback —
    // identical to the cold-start branch in `_computeLiveRepDepthPercents`.
    final romPerRep = d.reps
        .map((r) {
          final mn = r.minAngle;
          final mx = r.maxAngle;
          if (mn == null || mx == null) return null;
          final rom = mx - mn;
          return rom > 0 ? rom : null;
        })
        .toList(growable: false);
    final sessionMaxRom = romPerRep.fold<double>(
      0,
      (a, b) => (b != null && b > a) ? b : a,
    );
    final depthPercents = romPerRep
        .map<double?>((rom) {
          if (rom == null || sessionMaxRom <= 0) return null;
          return (rom / sessionMaxRom).clamp(0.0, 1.0);
        })
        .toList(growable: false);
    // Side-view per-rep averages — available for bicepsCurlSide sessions
    // written on schema v5+ builds. Returns empty for all other exercises
    // and pre-v5 rows (all 7 fields will be null → empty list after filter).
    final bicepsSideMetrics = d.reps
        .where(
          (r) =>
              r.bicepsLeanDeg != null ||
              r.bicepsShoulderDriftRatio != null ||
              r.bicepsElbowDriftRatio != null ||
              r.bicepsBackLeanDeg != null ||
              r.bicepsShrugRatio != null ||
              r.bicepsElbowRiseRatio != null,
        )
        .map(
          (r) => BicepsSideRepMetrics(
            repIndex: r.repIndex,
            leanDeg: r.bicepsLeanDeg,
            shoulderDriftRatio: r.bicepsShoulderDriftRatio,
            elbowDriftRatio: r.bicepsElbowDriftRatio,
            backLeanDeg: r.bicepsBackLeanDeg,
            elbowDriftSigned: r.bicepsElbowDriftSigned,
            shrugRatio: r.bicepsShrugRatio,
            elbowRiseRatio: r.bicepsElbowRiseRatio,
          ),
        )
        .toList(growable: false);
    return SummaryScreen(
      key: key,
      exercise: s.exercise,
      totalReps: s.totalReps,
      totalSets: s.totalSets,
      sessionDuration: s.duration,
      averageQuality: s.averageQuality,
      detectedView: s.detectedView ?? CurlCameraView.unknown,
      repQualities: qualities,
      fatigueDetected: s.fatigueDetected,
      asymmetryDetected: s.asymmetryDetected,
      eccentricTooFastCount: d.eccentricTooFastCount,
      errorsTriggered: d.formErrors.keys.toSet(),
      errorCounts: d.formErrors,
      curlRepRecords: curlRecords,
      repConcentricMs: concentricMs,
      repDepthPercents: depthPercents,
      bicepsSideRepMetrics: bicepsSideMetrics,
      squatRepMetrics: squatMetrics,
      squatVariant: squatVariant,
      // Bucket summaries are live-only state; no persisted source exists.
      // `squatLongFemurLifter`, `squatProfile`, `squatAutoCalSnapshot`,
      // `curlProfile`, `autoCalSnapshot`, `pushUpProfile`, and
      // `feedbackSensitivity` are also live-only or live-loaded; reconstructed
      // sessions fall back to the constructor defaults and the audit's Tier 3
      // cold-start grading path.
    );
  }

  /// Build minimal-angle [CurlRepRecord]s for a reconstructed push-up
  /// session. The push-up audit (`FormAuditor.auditPushUp`) only inspects
  /// `minAngle` / `maxAngle` — `side` / `view` / `source` are not
  /// meaningful for push-up, so sentinel values are used. Rows without
  /// both angles are skipped (the audit can't grade them).
  static List<CurlRepRecord> _reconstructPushUpRepRecords(SessionDetail d) {
    final out = <CurlRepRecord>[];
    for (final r in d.reps) {
      final mn = r.minAngle;
      final mx = r.maxAngle;
      if (mn == null || mx == null) continue;
      out.add(
        CurlRepRecord(
          repIndex: r.repIndex,
          side: ProfileSide.right,
          view: CurlCameraView.unknown,
          minAngle: mn,
          maxAngle: mx,
          source: ThresholdSource.global,
          bucketUpdated: false,
          rejectedOutlier: false,
        ),
      );
    }
    return List.unmodifiable(out);
  }

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  bool _detailsExpanded = false;

  /// "Accuracy by rep" header collapse state. Collapsed by default so the
  /// form-audit card opens lighter; tapping the header expands the list.
  bool _accuracyByRepExpanded = false;

  /// Index (0-based) of the currently-expanded per-rep row inside the
  /// accuracy-by-rep list, or null when no row is expanded. Single-expand
  /// behavior keeps the card compact even on 20-rep sessions.
  int? _expandedRepIndex;

  ExerciseType get exercise => widget.exercise;
  int get totalReps => widget.totalReps;
  int get totalSets => widget.totalSets;
  Duration get sessionDuration => widget.sessionDuration;
  double? get averageQuality => widget.averageQuality;
  CurlCameraView get detectedView => widget.detectedView;
  List<double> get repQualities => widget.repQualities;
  bool get fatigueDetected => widget.fatigueDetected;
  bool get asymmetryDetected => widget.asymmetryDetected;
  int get eccentricTooFastCount => widget.eccentricTooFastCount;
  Set<FormError> get errorsTriggered => widget.errorsTriggered;
  Map<FormError, int> get errorCounts => widget.errorCounts;
  List<CurlRepRecord> get curlRepRecords => widget.curlRepRecords;
  List<CurlProfileBucketSummary> get curlBucketSummaries =>
      widget.curlBucketSummaries;
  List<int?> get repConcentricMs => widget.repConcentricMs;
  List<double?> get repDepthPercents => widget.repDepthPercents;

  Color _qualityColor(double? q) {
    if (q == null) return const Color(0xFF9E9E9E);
    if (q >= 0.80) return const Color(0xFF00E676); // green
    if (q >= 0.60) return const Color(0xFFFFB300); // amber
    return const Color(0xFFFF5252); // red
  }

  /// Tier color for a 0..1 score, matching the form-audit pass-rate ramp:
  /// ≥0.80 → accent (green), ≥0.50 → cyan, else red. Used by the dual-stat
  /// header so the Form Accuracy and Clean Reps tiles can independently pick
  /// their tier instead of inheriting the pass-rate color.
  Color _tierColor(double v, FiTrackColors ft) {
    if (v >= 0.80) return ft.accent;
    if (v >= 0.50) return ft.cyan;
    return FiTrackTheme.red;
  }

  /// Per-rep detail panel for the expanded "Accuracy by rep" row. Pulls from
  /// whichever exercise's per-rep telemetry is present:
  ///   • [curlRepRecords]      → ROM (min/max angle), side label, rejected flag
  ///   • [widget.repConcentricMs] → concentric tempo in seconds
  ///   • [widget.bicepsSideRepMetrics] → curl-side lean / shoulder-drift /
  ///     elbow-drift / back-lean peaks
  ///   • [widget.squatRepMetrics] → squat lean / knee-shift / heel-lift
  ///
  /// Rows are emitted only when the corresponding field is present, so a
  /// front-curl rep shows fewer rows than a side-curl rep and a push-up rep
  /// shows just the basics. Returns null when nothing extra is available.
  Widget? _buildRepDetails(BuildContext context, int repIndex) {
    final theme = Theme.of(context);
    final rows = <Widget>[];

    // ROM — curl + push-up both reuse CurlRepRecord, so this works for both.
    if (repIndex < curlRepRecords.length) {
      final r = curlRepRecords[repIndex];
      rows.add(
        _RepDetailRow(
          label: 'ROM',
          value:
              '${r.maxAngle.toStringAsFixed(0)}° → '
              '${r.minAngle.toStringAsFixed(0)}°  '
              '(Δ ${r.romDegrees.toStringAsFixed(0)}°)',
        ),
      );
      if (exercise.isCurl) {
        rows.add(
          _RepDetailRow(
            label: 'Arm',
            value: r.side == ProfileSide.left ? 'Left' : 'Right',
          ),
        );
      }
      if (r.rejectedOutlier) {
        rows.add(
          _RepDetailRow(
            label: 'Status',
            value: 'Rejected outlier',
            valueColor: const Color(0xFFFFB300),
          ),
        );
      }
    }

    // Tempo
    if (repIndex < widget.repConcentricMs.length) {
      final ms = widget.repConcentricMs[repIndex];
      if (ms != null) {
        rows.add(
          _RepDetailRow(
            label: 'Tempo',
            value: '${(ms / 1000).toStringAsFixed(1)} s concentric',
          ),
        );
      }
    }

    // Depth (live curl + squat path populates this; reconstructed sessions
    // pad with nulls).
    if (repIndex < widget.repDepthPercents.length) {
      final d = widget.repDepthPercents[repIndex];
      if (d != null) {
        rows.add(
          _RepDetailRow(
            label: 'Depth',
            value: '${(d * 100).round()}% of reference',
          ),
        );
      }
    }

    // Curl-side peaks
    if (repIndex < widget.bicepsSideRepMetrics.length) {
      final m = widget.bicepsSideRepMetrics[repIndex];
      if (m.leanDeg != null) {
        rows.add(
          _RepDetailRow(
            label: 'Trunk lean',
            value: '${m.leanDeg!.toStringAsFixed(1)}°',
          ),
        );
      }
      if (m.shoulderDriftRatio != null) {
        rows.add(
          _RepDetailRow(
            label: 'Shoulder arc',
            value: m.shoulderDriftRatio!.toStringAsFixed(3),
          ),
        );
      }
      if (m.elbowDriftRatio != null) {
        rows.add(
          _RepDetailRow(
            label: 'Elbow drift',
            value: m.elbowDriftRatio!.toStringAsFixed(3),
          ),
        );
      }
      if (m.backLeanDeg != null) {
        rows.add(
          _RepDetailRow(
            label: 'Back lean',
            value: '${m.backLeanDeg!.toStringAsFixed(1)}°',
          ),
        );
      }
    }

    // Squat peaks. All three fields are nullable on SquatRepMetrics — emit
    // a row only when the engine actually captured the value (pre-schema-v3
    // sessions, or reps with missing landmarks, write null).
    if (repIndex < widget.squatRepMetrics.length) {
      final m = widget.squatRepMetrics[repIndex];
      if (m.leanDeg != null) {
        rows.add(
          _RepDetailRow(
            label: 'Trunk lean',
            value: '${m.leanDeg!.toStringAsFixed(1)}°',
          ),
        );
      }
      if (m.kneeShiftRatio != null) {
        rows.add(
          _RepDetailRow(
            label: 'Knee shift',
            value: m.kneeShiftRatio!.toStringAsFixed(3),
          ),
        );
      }
      if (m.heelLiftRatio != null) {
        rows.add(
          _RepDetailRow(
            label: 'Heel lift',
            value: m.heelLiftRatio!.toStringAsFixed(3),
          ),
        );
      }
    }

    if (rows.isEmpty) {
      return Text(
        'No per-rep details captured.',
        style: TextStyle(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
          fontSize: 11,
          fontStyle: FontStyle.italic,
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  // _buildInsights, _avgSideMetric, _formatDuration removed 2026-05-13 —
  // insights logic moved to [SessionSummaryViewModel] in `view_models/`,
  // duration formatting moved to [SummaryStatsGrid] in `widgets/summary/`.

  /// Human-readable label for the camera view.
  ///
  /// **User-frame, not camera-frame.** `CurlCameraView.sideLeft` /
  /// `sideRight` are camera-coordinate enums — they describe which side
  /// of the camera frame the user occupies. Front-camera mirroring
  /// inverts this: when the user's PHYSICAL left arm is being tracked,
  /// it appears on the camera's RIGHT side, so the engine sees
  /// `CurlCameraView.sideRight`. The label flips that back so users
  /// see their own body's left/right, not the mirrored camera view.
  /// Matches the home-screen Side picker, which is also user-frame.
  String _viewLabel(CurlCameraView v) => switch (v) {
    CurlCameraView.front => 'Front view',
    CurlCameraView.sideLeft => 'Side view · Right',
    CurlCameraView.sideRight => 'Side view · Left',
    CurlCameraView.unknown => 'Unknown',
  };

  String _errorLabel(FormError err) => switch (err) {
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

  /// 5-tier knee-shift bucket label (plan flow-decision plan-time #1).
  /// Tooltip shows the raw ratio for transparency.
  String _kneeShiftBucket(double ratio) {
    if (ratio < 0.10) return 'Low';
    if (ratio < 0.20) return 'Moderate';
    if (ratio < 0.30) return 'Notable';
    if (ratio < 0.40) return 'High';
    return 'Very high';
  }

  // ── Details panel helpers ──────────────────────────────

  String _shortViewLabel(CurlCameraView v) => switch (v) {
    CurlCameraView.front => 'Front',
    CurlCameraView.sideLeft => 'Side · L',
    CurlCameraView.sideRight => 'Side · R',
    CurlCameraView.unknown => '—',
  };

  String _sideLabel(ProfileSide s) =>
      s == ProfileSide.left ? 'Left arm' : 'Right arm';

  String _sourceLabel(ThresholdSource s) => switch (s) {
    ThresholdSource.calibrated => 'Calibrated',
    ThresholdSource.autoCalibrated => 'Auto-calibrated',
    ThresholdSource.warmup => 'Warmup',
    ThresholdSource.global => 'Generic',
  };

  Color _sourceColor(ThresholdSource s) => switch (s) {
    ThresholdSource.calibrated => const Color(0xFF00E676),
    ThresholdSource.autoCalibrated => const Color(0xFF64B5F6),
    ThresholdSource.warmup => const Color(0xFFFFB300),
    ThresholdSource.global => const Color(0xFF9E9E9E),
  };

  void _showShareSheet() {
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _ShareCard(
        exercise: exercise,
        totalReps: totalReps,
        sessionDuration: sessionDuration,
        averageQuality: averageQuality,
      ),
    );
  }

  /// Form Audit card. Replaces the deleted DTW Form Match Card.
  /// Re-grades the session's reps using **Path B-permissive tier priority**
  /// (2026-05-13): each rep is graded against the most personalized ROM bar
  /// available — calibrated profile bucket → auto-cal snapshot → cold-start
  /// with the user's sensitivity. Form-error thresholds use the user's
  /// session sensitivity (not always-high). See [FormAuditor.auditCurl]
  /// doc-block for the full priority chain rationale.
  ///
  /// Default-on for all exercises (curl / squat / push-up). Coverage varies
  /// by exercise — see [FormAuditor] doc-block for what each path grades.
  /// Renders the Form Audit card from a pre-built [FormAudit]. The audit
  /// is constructed once by [SessionSummaryViewModel] and reused here — do
  /// NOT re-run `FormAuditor` inside this method.
  Widget _buildFormAuditCard(BuildContext context, FormAudit audit) {
    final theme = Theme.of(context);
    final recap = audit;

    final ft = FiTrackColors.of(context);
    final pct = recap.repsEvaluated == 0 ? 0 : (recap.passRate * 100).round();
    final quality = _meanRepQuality();
    final qualityPct = quality == null ? 0 : (quality * 100).round();
    final color = recap.passRate >= 0.80
        ? ft.accent
        : recap.passRate >= 0.50
        ? ft.cyan
        : FiTrackTheme.red;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.verified_outlined, color: color, size: 20),
              const SizedBox(width: 8),
              Text(
                'Form audit',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (recap.applicable) ...[
            // Dual-stat header: Form Accuracy + Clean Reps share the same
            // typography & color rules so neither reads as the "real" score.
            // Color rules: each stat picks its own tier color from its own
            // percentage, so a session that's mechanically clean (high clean%)
            // but jittery (low accuracy%) is honestly conveyed.
            _FormAuditDualStat(
              accuracyPct: qualityPct,
              accuracyColor: _tierColor(qualityPct / 100.0, ft),
              cleanPct: pct,
              cleanColor: color,
            ),
            const SizedBox(height: 8),
            Text(
              '${recap.repsClean} / ${recap.repsEvaluated} reps · '
              '${recap.perCriterion.length} criteria',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 16),
            for (final c in recap.perCriterion)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        c.name,
                        style: TextStyle(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.85,
                          ),
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Text(
                      '${c.passed} / ${c.evaluated}',
                      style: TextStyle(
                        color: c.fired == 0
                            ? ft.accent
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.85,
                              ),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            if (recap.oneShotFlags.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final f in recap.oneShotFlags)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.flag_outlined,
                        size: 14,
                        color: Colors.orangeAccent,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        f,
                        style: const TextStyle(
                          color: Colors.orangeAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            if (repQualities.isNotEmpty) ...[
              const SizedBox(height: 20),
              // Collapsible section header. Tapping toggles the rep list.
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(
                  () => _accuracyByRepExpanded = !_accuracyByRepExpanded,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'ACCURACY BY REP',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.0,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.4,
                            ),
                          ),
                        ),
                      ),
                      Text(
                        '${repQualities.length} reps',
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        _accuracyByRepExpanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 18,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.54,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_accuracyByRepExpanded) ...[
                const SizedBox(height: 8),
                Column(
                  children: repQualities.asMap().entries.map((entry) {
                    final i = entry.key;
                    final repQuality = entry.value;
                    final isExpanded = _expandedRepIndex == i;
                    return _RepAccuracyTile(
                      repIndex: i,
                      repQuality: repQuality,
                      barColor: _qualityColor(repQuality),
                      expanded: isExpanded,
                      onTap: () => setState(
                        () => _expandedRepIndex = isExpanded ? null : i,
                      ),
                      details: isExpanded ? _buildRepDetails(context, i) : null,
                    );
                  }).toList(),
                ),
              ],
            ],
          ] else
            Text(
              recap.notApplicableReason ??
                  'Strict recap not available for this session.',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
                fontSize: 13,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDetailsCard(BuildContext context) {
    final theme = Theme.of(context);
    final rejected = curlRepRecords.where((r) => r.rejectedOutlier).length;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header toggle row.
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => setState(() => _detailsExpanded = !_detailsExpanded),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  const Icon(
                    Icons.insights_rounded,
                    color: Color(0xFF64B5F6),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Details',
                      style: TextStyle(
                        color: theme.colorScheme.onSurface,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (rejected > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        '$rejected outlier${rejected == 1 ? '' : 's'}',
                        style: const TextStyle(
                          color: Color(0xFFFFB300),
                          fontSize: 11,
                        ),
                      ),
                    ),
                  Icon(
                    _detailsExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
                  ),
                ],
              ),
            ),
          ),
          if (_detailsExpanded) ...[
            Divider(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
              height: 1,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildThresholdSourceRow(context),
                  const SizedBox(height: 20),
                  _buildPerArmRow(context),
                  const SizedBox(height: 20),
                  _buildBucketList(context),
                  // Merged 2026-05-13: the previously-separate "Side-View
                  // Form" card now lives as a sub-section here so curl-side
                  // sessions don't double up surrounding card chrome.
                  if (widget.bicepsSideRepMetrics.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    _buildSideViewSection(context),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildThresholdSourceRow(BuildContext context) {
    final theme = Theme.of(context);
    final counts = <ThresholdSource, int>{};
    for (final r in curlRepRecords) {
      counts[r.source] = (counts[r.source] ?? 0) + 1;
    }
    final total = counts.values.fold<int>(0, (a, b) => a + b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Threshold source (per rep)',
          style: TextStyle(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 8),
        if (total == 0)
          Text(
            'No reps recorded this session.',
            style: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.38),
              fontSize: 12,
            ),
          )
        else
          Column(
            children: ThresholdSource.values
                .where((s) => (counts[s] ?? 0) > 0)
                .map((s) {
                  final n = counts[s]!;
                  final pct = (n / total).clamp(0.0, 1.0);
                  final color = _sourceColor(s);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 110,
                          child: Text(
                            _sourceLabel(s),
                            style: TextStyle(color: color, fontSize: 12),
                          ),
                        ),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (ctx, constraints) => Stack(
                              children: [
                                Container(
                                  width: constraints.maxWidth,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.06),
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                ),
                                Container(
                                  width: constraints.maxWidth * pct,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: color,
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 36,
                          child: Text(
                            '$n',
                            textAlign: TextAlign.right,
                            style: TextStyle(color: color, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  );
                })
                .toList(),
          ),
      ],
    );
  }

  Widget _buildPerArmRow(BuildContext context) {
    final theme = Theme.of(context);
    final byArm = <ProfileSide, List<CurlRepRecord>>{
      ProfileSide.left: [],
      ProfileSide.right: [],
    };
    for (final r in curlRepRecords) {
      byArm[r.side]!.add(r);
    }

    double avgRom(List<CurlRepRecord> list) => list.isEmpty
        ? 0
        : list.map((r) => r.romDegrees).reduce((a, b) => a + b) / list.length;
    double avgPeak(List<CurlRepRecord> list) => list.isEmpty
        ? 0
        : list.map((r) => r.minAngle).reduce((a, b) => a + b) / list.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Per-arm breakdown',
          style: TextStyle(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _PerArmTile(
                label: 'Left arm',
                reps: byArm[ProfileSide.left]!.length,
                avgRom: avgRom(byArm[ProfileSide.left]!),
                avgPeak: avgPeak(byArm[ProfileSide.left]!),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _PerArmTile(
                label: 'Right arm',
                reps: byArm[ProfileSide.right]!.length,
                avgRom: avgRom(byArm[ProfileSide.right]!),
                avgPeak: avgPeak(byArm[ProfileSide.right]!),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBucketList(BuildContext context) {
    final theme = Theme.of(context);
    if (curlBucketSummaries.isEmpty) {
      return Text(
        'No bucket data yet.',
        style: TextStyle(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.38),
          fontSize: 12,
        ),
      );
    }
    final sorted = [...curlBucketSummaries]
      ..sort((a, b) {
        final sideCmp = a.side.index.compareTo(b.side.index);
        if (sideCmp != 0) return sideCmp;
        return a.view.index.compareTo(b.view.index);
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Profile buckets touched',
          style: TextStyle(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 8),
        ...sorted.map((b) => _buildBucketRow(b, context)),
      ],
    );
  }

  Widget _buildBucketRow(CurlProfileBucketSummary b, BuildContext context) {
    final theme = Theme.of(context);
    final color = b.isCalibrated
        ? const Color(0xFF00E676)
        : b.sampleCount > 0
        ? const Color(0xFFFFB300)
        : const Color(0xFF9E9E9E);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${_sideLabel(b.side)} · ${_shortViewLabel(b.view)}',
                    style: TextStyle(
                      color: theme.colorScheme.onSurface,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (b.sessionReps > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '+${b.sessionReps} this set',
                      style: TextStyle(color: color, fontSize: 10),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                _BucketStat(
                  label: 'Peak',
                  value: '${b.observedMinAngle.toStringAsFixed(1)}°',
                ),
                const SizedBox(width: 16),
                _BucketStat(
                  label: 'Rest',
                  value: '${b.observedMaxAngle.toStringAsFixed(1)}°',
                ),
                const SizedBox(width: 16),
                _BucketStat(
                  label: 'ROM',
                  value: '${b.romDegrees.toStringAsFixed(1)}°',
                ),
                const SizedBox(width: 16),
                _BucketStat(label: 'Samples', value: '${b.sampleCount}'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Builds a [SessionSummaryInput] from this screen's widget fields. Kept
  /// as a private helper so the `build()` method reads as pure layout and
  /// the DTO ↔ widget mapping has a single owner.
  SessionSummaryInput _buildVmInput() => SessionSummaryInput(
    exercise: widget.exercise,
    totalReps: widget.totalReps,
    totalSets: widget.totalSets,
    sessionDuration: widget.sessionDuration,
    averageQuality: widget.averageQuality,
    detectedView: widget.detectedView,
    repQualities: widget.repQualities,
    fatigueDetected: widget.fatigueDetected,
    asymmetryDetected: widget.asymmetryDetected,
    eccentricTooFastCount: widget.eccentricTooFastCount,
    errorsTriggered: widget.errorsTriggered,
    errorCounts: widget.errorCounts,
    curlRepRecords: widget.curlRepRecords,
    squatVariant: widget.squatVariant,
    squatLongFemurLifter: widget.squatLongFemurLifter,
    squatRepMetrics: widget.squatRepMetrics,
    bicepsSideRepMetrics: widget.bicepsSideRepMetrics,
    curlProfile: widget.curlProfile,
    pushUpProfile: widget.pushUpProfile,
    squatProfile: widget.squatProfile,
    autoCalSnapshot: widget.autoCalSnapshot,
    squatAutoCalSnapshot: widget.squatAutoCalSnapshot,
    feedbackSensitivity: widget.feedbackSensitivity,
  );

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final vm = SessionSummaryViewModel.fromInput(_buildVmInput());
    return Scaffold(
      backgroundColor: ft.bg,
      // Design top bar: close (left) · SESSION COMPLETE (center) · share (right)
      appBar: AppBar(
        backgroundColor: isDark
            ? const Color(0xD90A0A0A)
            : const Color(0xEBF3F2EE),
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: Icon(Icons.close, color: ft.textStrong),
          onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
          tooltip: 'Done',
        ),
        title: Text(
          'SESSION COMPLETE',
          style: TextStyle(
            color: ft.textStrong,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(Icons.ios_share, color: ft.textStrong),
            onPressed: _showShareSheet,
            tooltip: 'Share',
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SummaryHero(
                qualityPct: vm.qualityPct,
                grade: vm.grade,
                subtitle: vm.heroSubtitle,
                exerciseLabel: vm.exerciseLabel,
              ),
              const SizedBox(height: 12),
              SummaryStatsGrid(
                reps: vm.reps,
                sets: vm.sets,
                duration: vm.duration,
              ),
              if (vm.variantLabels.isNotEmpty) ...[
                const SizedBox(height: 12),
                SummaryVariantChips(labels: vm.variantLabels),
              ],
              const SizedBox(height: 16),
              _buildFormAuditCard(context, vm.formAudit),
              if (vm.hasFormIssues) ...[
                const SizedBox(height: 16),
                SummaryFormIssuesCard(
                  errors: vm.formIssues,
                  errorCounts: vm.formIssueCounts,
                ),
              ],
              // Squat-only legacy subhead — pre-rebuild sessions carrying
              // FormError.trunkTibia. Out-of-band from the unified slot order
              // because it is intentionally surfaced as legacy/deprecated.
              if (exercise == ExerciseType.squat &&
                  errorsTriggered.contains(FormError.trunkTibia)) ...[
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Form check (legacy)',
                    style: TextStyle(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.60),
                      fontSize: 13,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
                _buildLegacyTrunkTibiaRow(context),
              ],
              // Squat-only per-rep ratio strip — live sessions only.
              if (exercise == ExerciseType.squat &&
                  widget.squatRepMetrics.isNotEmpty) ...[
                const SizedBox(height: 16),
                _buildSquatRatioStrip(context),
              ],
              if (vm.hasInsights) ...[
                const SizedBox(height: 16),
                SummaryInsightsCard(insights: vm.insights),
              ],
              // Curl-only details panel — rep records, bucket summaries, OR
              // (post-merge 2026-05-13) side-view metrics. Widened guard so
              // a side-view-only session still renders the card with just
              // the merged side-view sub-section.
              if (exercise.isCurl &&
                  (curlRepRecords.isNotEmpty ||
                      curlBucketSummaries.isNotEmpty ||
                      widget.bicepsSideRepMetrics.isNotEmpty)) ...[
                const SizedBox(height: 16),
                _buildDetailsCard(context),
              ],
              // Side-view per-rep averages now live inside the Details card
              // (merged 2026-05-13 — see _buildSideViewSection). The previous
              // standalone _buildBicepsSideRatioStrip block was removed here.
              // Curl-only camera-view chip.
              if (exercise.isCurl &&
                  detectedView != CurlCameraView.unknown) ...[
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _CameraViewChip(label: _viewLabel(detectedView)),
                ),
              ],
              const SizedBox(height: 24),
              const SummaryActions(),
            ],
          ),
        ),
      ),
    );
  }

  /// Squat summary — mirrors the curl card style (hero header + stats +
  /// quality + form issues + insights) with squat-specific extras: variant
  /// chip, tall-lifter chip, per-rep ratio strip, knee-shift bucket label,
  /// and the conditional "Form check (legacy)" subhead for sessions that
  /// were saved before the rebuild.
  // _buildSquatSummary / _buildCurlSummary / _buildSimpleSummary removed
  // 2026-05-13 — replaced by the unified `build()` body that consumes
  // [SessionSummaryViewModel] and renders the shared `widgets/summary/*`
  // surface for every exercise.

  /// Mean of the per-rep qualities. Falls back to `averageQuality` (which
  /// may also be null on early-WP5 sessions).
  ///
  /// Returns null when no reps were recorded — the analyzer's default
  /// `averageQuality = 1.0` is meaningless on a zero-rep session and
  /// previously surfaced as "100% form quality" in the UI even though
  /// the user never curled. Zero reps → no quality data, period.
  double? _meanRepQuality() {
    if (totalReps == 0) return null;
    if (repQualities.isEmpty) return averageQuality;
    final nonZero = repQualities.where((q) => q > 0).toList();
    if (nonZero.isEmpty) return null;
    return nonZero.reduce((a, b) => a + b) / nonZero.length;
  }

  // _buildQualityCard and _buildSquatFormIssuesCard removed 2026-05-13 —
  // replaced by [SummaryHero] and [SummaryFormIssuesCard] in
  // `widgets/summary/`.

  Widget _buildSquatRatioStrip(BuildContext context) {
    final theme = Theme.of(context);
    final m = widget.squatRepMetrics;
    // Reduce to per-rep peak readings — sparse rendering of all reps would
    // overwhelm; the user wants the overall trend at a glance.
    double? avg(double? Function(SquatRepMetrics) pick) {
      final vals = m.map(pick).whereType<double>().toList();
      if (vals.isEmpty) return null;
      return vals.reduce((a, b) => a + b) / vals.length;
    }

    final avgLean = avg((r) => r.leanDeg);
    final avgKneeShift = avg((r) => r.kneeShiftRatio);
    final avgHeelLift = avg((r) => r.heelLiftRatio);

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
                Icons.insights_rounded,
                color: Color(0xFF64B5F6),
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'Per-Rep Averages',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (avgLean != null)
            _RatioRow(
              label: 'Forward lean',
              value: '${avgLean.toStringAsFixed(1)}°',
            ),
          if (avgKneeShift != null)
            _RatioRow(
              label: 'Knee shift',
              value:
                  '${_kneeShiftBucket(avgKneeShift)} '
                  '(${avgKneeShift.toStringAsFixed(2)})',
              tooltip:
                  'Raw ratio (knee_x − ankle_x) / femur_len: '
                  '${avgKneeShift.toStringAsFixed(3)}',
            ),
          if (avgHeelLift != null)
            _RatioRow(
              label: 'Heel lift',
              value: avgHeelLift.toStringAsFixed(3),
            ),
        ],
      ),
    );
  }

  /// Side-view biceps form averages, rendered as a sub-section inside
  /// [_buildDetailsCard]. Returns the bare column — no card chrome — because
  /// the parent already provides the rounded surface + padding. Caller gates
  /// on `bicepsSideRepMetrics.isNotEmpty` so this only runs on side-view
  /// curl sessions.
  Widget _buildSideViewSection(BuildContext context) {
    final theme = Theme.of(context);
    final m = widget.bicepsSideRepMetrics;

    double? avg(double? Function(BicepsSideRepMetrics) pick) {
      final vals = m.map(pick).whereType<double>().toList();
      if (vals.isEmpty) return null;
      return vals.reduce((a, b) => a + b) / vals.length;
    }

    final avgLean = avg((r) => r.leanDeg);
    final avgShoulderArc = avg((r) => r.shoulderDriftRatio);
    final avgElbowDrift = avg((r) => r.elbowDriftRatio);
    final avgBackLean = avg((r) => r.backLeanDeg);
    final avgShrug = avg((r) => r.shrugRatio);
    final avgElbowRise = avg((r) => r.elbowRiseRatio);

    if ([
      avgLean,
      avgShoulderArc,
      avgElbowDrift,
      avgBackLean,
      avgShrug,
      avgElbowRise,
    ].every((v) => v == null)) {
      return const SizedBox.shrink();
    }

    final viewLabel = switch (detectedView) {
      CurlCameraView.sideLeft => 'Side view · Right',
      CurlCameraView.sideRight => 'Side view · Left',
      _ => 'Side view',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Side-view form — $viewLabel',
          style: TextStyle(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 8),
        if (avgLean != null)
          _SideMetricRow(
            label: 'Trunk lean',
            value: avgLean,
            threshold: kTorsoLeanThresholdDeg,
            unit: '°',
          ),
        if (avgShoulderArc != null)
          _SideMetricRow(
            label: 'Shoulder arc',
            value: avgShoulderArc,
            threshold: kSwingThreshold,
            unit: '',
          ),
        if (avgElbowDrift != null)
          _SideMetricRow(
            label: 'Elbow drift',
            value: avgElbowDrift,
            threshold: kDriftThreshold,
            unit: '',
          ),
        if (avgBackLean != null)
          _SideMetricRow(
            label: 'Back lean',
            value: avgBackLean,
            threshold: kBackLeanThresholdDeg,
            unit: '°',
          ),
        if (avgShrug != null)
          _SideMetricRow(
            label: 'Shoulder shrug',
            value: avgShrug,
            threshold: kShrugThreshold,
            unit: '',
          ),
        if (avgElbowRise != null)
          _SideMetricRow(
            label: 'Elbow rise',
            value: avgElbowRise,
            threshold: kElbowRiseThreshold,
            unit: '',
          ),
      ],
    );
  }

  Widget _buildLegacyTrunkTibiaRow(BuildContext context) {
    final theme = Theme.of(context);
    // The caller only renders this widget when `errorsTriggered` contains
    // `FormError.trunkTibia` (squat summary, line guarded by `hasLegacy`).
    // No per-rep count is plumbed through to the summary in v1, so this row
    // signals presence only — matches the chip behavior elsewhere on the
    // screen.
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(
            Icons.history,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorLabel(FormError.trunkTibia),
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// _StatChip and _StatRow removed 2026-05-13 — replaced by [SummaryStatsGrid]
// in `widgets/summary/`.

/// Form-audit dual-stat header. Shows Form Accuracy and Clean Reps side-by-
/// side with matching typography, so neither percentage reads as more
/// authoritative than the other. Each stat picks its own tier color from its
/// own value (see `_SummaryScreenState._tierColor`).
class _FormAuditDualStat extends StatelessWidget {
  const _FormAuditDualStat({
    required this.accuracyPct,
    required this.accuracyColor,
    required this.cleanPct,
    required this.cleanColor,
  });

  final int accuracyPct;
  final Color accuracyColor;
  final int cleanPct;
  final Color cleanColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _FormAuditStat(
            value: accuracyPct,
            color: accuracyColor,
            caption: 'FORM\nACCURACY',
          ),
        ),
        Expanded(
          child: _FormAuditStat(
            value: cleanPct,
            color: cleanColor,
            caption: 'CLEAN\nREPS',
          ),
        ),
      ],
    );
  }
}

class _FormAuditStat extends StatelessWidget {
  const _FormAuditStat({
    required this.value,
    required this.color,
    required this.caption,
  });

  final int value;
  final Color color;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '$value',
              style: TextStyle(
                fontSize: 48,
                fontWeight: FontWeight.bold,
                color: color,
                height: 1,
                letterSpacing: -1.5,
              ),
            ),
            Text(
              '%',
              style: TextStyle(
                fontSize: 22,
                color: color.withValues(alpha: 0.7),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          caption,
          style: TextStyle(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            height: 1.2,
          ),
        ),
      ],
    );
  }
}

/// One row in the Accuracy-by-Rep list. Tap toggles per-rep detail panel.
class _RepAccuracyTile extends StatelessWidget {
  const _RepAccuracyTile({
    required this.repIndex,
    required this.repQuality,
    required this.barColor,
    required this.expanded,
    required this.onTap,
    required this.details,
  });

  final int repIndex;
  final double repQuality;
  final Color barColor;
  final bool expanded;
  final VoidCallback onTap;
  final Widget? details;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repNum = repIndex + 1;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: expanded
            ? theme.colorScheme.onSurface.withValues(alpha: 0.04)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Column(
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 32,
                      child: Text(
                        'R$repNum',
                        style: TextStyle(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.54,
                          ),
                          fontSize: 12,
                        ),
                        textAlign: TextAlign.right,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (ctx, constraints) => Stack(
                          children: [
                            Container(
                              width: constraints.maxWidth,
                              height: 10,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.07,
                                ),
                                borderRadius: BorderRadius.circular(5),
                              ),
                            ),
                            Container(
                              width: constraints.maxWidth * repQuality,
                              height: 10,
                              decoration: BoxDecoration(
                                color: barColor,
                                borderRadius: BorderRadius.circular(5),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 56,
                      child: Text(
                        '${(repQuality * 100).round()}%',
                        style: TextStyle(
                          color: barColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.right,
                      ),
                    ),
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 16,
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.38,
                      ),
                    ),
                  ],
                ),
                if (expanded && details != null) ...[
                  const SizedBox(height: 8),
                  Padding(
                    // Indent under the bar so the details visually attach to
                    // the rep row, not the card edge.
                    padding: const EdgeInsets.fromLTRB(40, 4, 0, 4),
                    child: details,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Single label/value row inside an expanded rep's detail panel.
class _RepDetailRow extends StatelessWidget {
  const _RepDetailRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color:
                    valueColor ??
                    theme.colorScheme.onSurface.withValues(alpha: 0.85),
                fontSize: 12,
                fontWeight: FontWeight.w500,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PerArmTile extends StatelessWidget {
  final String label;
  final int reps;
  final double avgRom;
  final double avgPeak;

  const _PerArmTile({
    required this.label,
    required this.reps,
    required this.avgRom,
    required this.avgPeak,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: theme.colorScheme.onSurface,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$reps rep${reps == 1 ? '' : 's'}',
            style: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          if (reps > 0) ...[
            Text(
              'Avg ROM: ${avgRom.toStringAsFixed(1)}°',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
                fontSize: 11,
              ),
            ),
            Text(
              'Avg peak: ${avgPeak.toStringAsFixed(1)}°',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
                fontSize: 11,
              ),
            ),
          ] else
            Text(
              'Not used',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.38),
                fontSize: 11,
              ),
            ),
        ],
      ),
    );
  }
}

// _MiniChip removed 2026-05-13 — replaced by [SummaryVariantChips] in
// `widgets/summary/`.

/// Single row in the squat per-rep ratio strip. Optional tooltip surfaces
/// the raw ratio when the bucket label hides it.
class _RatioRow extends StatelessWidget {
  const _RatioRow({required this.label, required this.value, this.tooltip});

  final String label;
  final String value;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.60),
                fontSize: 13,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: theme.colorScheme.onSurface,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (tooltip != null) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: tooltip!,
              child: Icon(
                Icons.info_outline,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.38),
                size: 14,
              ),
            ),
          ],
        ],
      ),
    );
    return row;
  }
}

class _SideMetricRow extends StatelessWidget {
  const _SideMetricRow({
    required this.label,
    required this.value,
    required this.threshold,
    required this.unit,
  });

  final String label;
  final double value;
  final double threshold;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ratio = value / threshold;
    final (badge, badgeColor) = ratio <= 1.0
        ? ('OK', const Color(0xFF4CAF50))
        : ratio <= 1.5
        ? ('Elevated', const Color(0xFFFFA726))
        : ('High', const Color(0xFFEF5350));

    final displayValue = unit == '°'
        ? '${value.toStringAsFixed(1)}°'
        : value.toStringAsFixed(2);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.60),
                fontSize: 13,
              ),
            ),
          ),
          Text(
            displayValue,
            style: TextStyle(
              color: theme.colorScheme.onSurface,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: badgeColor.withValues(alpha: 0.40)),
            ),
            child: Text(
              badge,
              style: TextStyle(
                color: badgeColor,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BucketStat extends StatelessWidget {
  final String label;
  final String value;

  const _BucketStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.38),
            fontSize: 10,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: theme.colorScheme.onSurface,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

// _RepStat removed 2026-05-13 — was dead code prior to the refactor.

class _ShareCard extends StatelessWidget {
  const _ShareCard({
    required this.exercise,
    required this.totalReps,
    required this.sessionDuration,
    required this.averageQuality,
  });

  final ExerciseType exercise;
  final int totalReps;
  final Duration sessionDuration;
  final double? averageQuality;

  String _fmtDuration() {
    final m = sessionDuration.inMinutes;
    final s = sessionDuration.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    return '${m}m ${s}s';
  }

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    final quality = averageQuality;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The shareable card preview
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [ft.bg, ft.surface2],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'FITRACK',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  fontStyle: FontStyle.italic,
                  color: ft.accent,
                  letterSpacing: -0.18,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                exercise.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.32,
                  color: ft.cyan,
                ),
              ),
              const SizedBox(height: 6),
              if (quality != null)
                Text(
                  '${(quality * 100).round()}%',
                  style: TextStyle(
                    fontSize: 56,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -2.24,
                    color: ft.accent,
                    height: 1,
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                'AI Form Accuracy',
                style: TextStyle(fontSize: 14, color: ft.textDim),
              ),
              const SizedBox(height: 16),
              Divider(color: ft.stroke, height: 1),
              const SizedBox(height: 12),
              Row(
                children: [
                  _ShareStat(label: 'Time', value: _fmtDuration()),
                  const SizedBox(width: 20),
                  _ShareStat(label: 'Reps', value: '$totalReps'),
                  if (quality != null) ...[
                    const SizedBox(width: 20),
                    _ShareStat(
                      label: 'Form',
                      value: '${(quality * 100).round()}%',
                      color: ft.cyan,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        // Action row
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: ft.stroke)),
          ),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('Close'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: ft.textPrimary,
                    side: BorderSide(color: ft.stroke),
                    backgroundColor: ft.surface3,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () async {
                    final lines = [
                      '🏋️ FiTrack — ${exercise.label}',
                      ?quality != null
                          ? '${(quality * 100).round()}% form accuracy'
                          : null,
                      'Reps: $totalReps  •  Time: ${_fmtDuration()}',
                    ];
                    await Share.share(
                      lines.join('\n'),
                      subject: 'My FiTrack ${exercise.label} session',
                    );
                    if (context.mounted) Navigator.pop(context);
                  },
                  icon: const Icon(Icons.ios_share, size: 16),
                  label: const Text('SHARE'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ft.accent,
                    foregroundColor: ft.accentOn,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ShareStat extends StatelessWidget {
  const _ShareStat({
    required this.label,
    required this.value,
    this.color = Colors.white,
  });
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0,
            color: ft.textMuted,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.72,
            color: color,
          ),
        ),
      ],
    );
  }
}

// _AiAccuracyHero, _SummaryStatCard, _SetsChip removed 2026-05-13 —
// replaced by [SummaryHero] and [SummaryStatsGrid] in `widgets/summary/`.

/// Curl-only camera-view chip rendered at the bottom of the summary on
/// sessions where the engine identified a side. Kept private to this file
/// because no other screen surfaces a camera view in the same shape.
class _CameraViewChip extends StatelessWidget {
  const _CameraViewChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.videocam_outlined,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.38),
            size: 14,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.38),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
