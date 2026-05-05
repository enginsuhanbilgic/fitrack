import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../core/constants.dart';
import '../core/theme.dart';
import '../core/types.dart';
import '../services/db/session_dtos.dart';

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

  /// Per-rep DTW similarity scores (0.0–1.0). Empty or all-null = card hidden.
  final List<double?> dtwSimilarities;

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
    this.dtwSimilarities = const [],
    this.squatVariant = SquatVariant.bodyweight,
    this.squatLongFemurLifter = false,
    this.squatRepMetrics = const [],
    this.bicepsSideRepMetrics = const [],
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
    final curlRecords = d.reps
        .map((r) => r.toCurlRepRecord())
        .whereType<CurlRepRecord>()
        .toList(growable: false);
    final qualities = d.reps
        .map((r) => r.quality ?? 0.0)
        .toList(growable: false);
    final concentricMs = d.reps
        .map((r) => r.concentricMs)
        .toList(growable: false);
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
      dtwSimilarities: d.reps
          .map((r) => r.dtwSimilarity)
          .toList(growable: false),
      repConcentricMs: concentricMs,
      repDepthPercents: depthPercents,
      bicepsSideRepMetrics: bicepsSideMetrics,
      // Bucket summaries are live-only state; no persisted source exists.
      // Squat per-rep ratios are also live-only; reconstructed sessions
      // pass an empty list and the per-rep strip collapses gracefully.
    );
  }

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  bool _detailsExpanded = false;

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
  List<double?> get dtwSimilarities => widget.dtwSimilarities;
  List<int?> get repConcentricMs => widget.repConcentricMs;
  List<double?> get repDepthPercents => widget.repDepthPercents;

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Color _qualityColor(double? q) {
    if (q == null) return const Color(0xFF9E9E9E);
    if (q >= 0.80) return const Color(0xFF00E676); // green
    if (q >= 0.60) return const Color(0xFFFFB300); // amber
    return const Color(0xFFFF5252); // red
  }

  String _gradeLabel(double? q) {
    if (q == null) return '—';
    if (q >= 0.90) return 'A';
    if (q >= 0.80) return 'B';
    if (q >= 0.70) return 'C';
    if (q >= 0.60) return 'D';
    return 'F';
  }

  String _qualitySubtitle(double? q) {
    if (q == null) {
      // Distinguish "no reps committed" (the common case — bad framing,
      // ML Kit lost landmarks, FSM never armed) from "reps committed
      // but no quality computed" (rare — diagnostic mode short-circuits
      // before _curlRepRecords populates). The first is actionable for
      // the user; the second is an internal-state edge case.
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

  double? _avgSideMetric(double? Function(BicepsSideRepMetrics) pick) {
    final vals = widget.bicepsSideRepMetrics
        .map(pick)
        .whereType<double>()
        .toList();
    if (vals.isEmpty) return null;
    return vals.reduce((a, b) => a + b) / vals.length;
  }

  List<String> _buildInsights() {
    final insights = <String>[];

    // No-rep sessions get a single clear message and skip every other
    // template. Fixes the prior contradiction where a 0-rep session
    // showed "Form Issues Detected" + "Great session!" simultaneously
    // because the cheerful template fired on `errorsTriggered.isEmpty`
    // without checking whether any rep actually counted. Frame-level
    // errors can fire on partial rep attempts that never committed,
    // and `errorsTriggered` accumulates them — so a 0-rep session can
    // still have non-empty errors.
    if (totalReps == 0) {
      insights.add(
        'No reps were counted. Make sure your full arm — shoulder, '
        'elbow, and wrist — stays in frame throughout the curl. Try '
        'stepping back from the camera or rotating to landscape.',
      );
      return insights;
    }

    if (eccentricTooFastCount > totalReps * 0.5) {
      insights.add(
        'You rushed the lowering phase on most reps. Try a 2-second count on the way down.',
      );
    } else if (eccentricTooFastCount > 0) {
      insights.add(
        'You rushed the lowering on $eccentricTooFastCount rep(s). Slow, controlled lowering builds more muscle.',
      );
    }

    if (fatigueDetected) {
      insights.add(
        'Fatigue detected mid-session. Consider shorter sets with full recovery between them.',
      );
    }

    if (asymmetryDetected) {
      insights.add(
        'Your arms showed uneven range. Focus on matching both sides for balanced development.',
      );
    }

    // Side-view specific coaching — only fires when metrics were recorded.
    // Camera-frame → user-frame flip: sideLeft = camera's left = user's RIGHT
    // arm (front-camera mirroring). Falls back to generic "arm" when unknown.
    final armLabel = switch (detectedView) {
      CurlCameraView.sideLeft => 'right arm',
      CurlCameraView.sideRight => 'left arm',
      _ => 'arm',
    };

    final avgElbowRise = _avgSideMetric((r) => r.elbowRiseRatio);
    if (avgElbowRise != null && avgElbowRise > kElbowRiseThreshold) {
      insights.add(
        'Your elbow rose on your $armLabel during the curl. Keep it pinned '
        'to your side — lifting it shifts load away from the bicep.',
      );
    }

    final avgShoulderArc = _avgSideMetric((r) => r.shoulderDriftRatio);
    if (avgShoulderArc != null && avgShoulderArc > kSwingThreshold) {
      insights.add(
        'You swung your $armLabel shoulder into the lift. Start each rep '
        'with the elbow still and use only forearm flexion.',
      );
    }

    final avgBackLean = _avgSideMetric((r) => r.backLeanDeg);
    if (avgBackLean != null && avgBackLean > kBackLeanThresholdDeg) {
      insights.add(
        'You leaned back to complete the $armLabel curl. Reduce the weight '
        'and keep your torso upright throughout.',
      );
    }

    final avgShrug = _avgSideMetric((r) => r.shrugRatio);
    if (avgShrug != null && avgShrug > kShrugThreshold) {
      insights.add(
        'Your $armLabel shoulder shrugged on most reps. Depress your '
        'shoulder blade before curling to isolate the bicep.',
      );
    }

    if (errorsTriggered.isEmpty ||
        averageQuality != null && averageQuality! >= 0.85) {
      insights.add('Great session! Keep this tempo and range of motion.');
    }

    if (insights.isEmpty) {
      if (averageQuality != null && averageQuality! >= 0.85) {
        insights.add('Great session! Keep this tempo and range of motion.');
      } else {
        insights.add(
          'Review the form issues above and focus on one correction at a time.',
        );
      }
    }

    return insights;
  }

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

  IconData _errorIcon(FormError err) => switch (err) {
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
    _ => Icons.error_outline,
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
    FormError.trunkTibia => 'Trunk-Tibia (legacy)',
    _ => err.name,
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

  Widget _buildRepAccuracyCard(BuildContext context) {
    final theme = Theme.of(context);
    final ft = FiTrackColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'ACCURACY BY REP',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
                ),
              ),
              Text(
                'Set $totalSets · ${exercise.label}',
                style: TextStyle(
                  fontSize: 10,
                  color: ft.accent,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Bar chart
          SizedBox(
            height: 80,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(repQualities.length, (i) {
                final v = repQualities[i];
                final dtw = i < dtwSimilarities.length
                    ? dtwSimilarities[i]
                    : null;
                final Color barColor = v >= 0.95
                    ? ft.accent
                    : v >= 0.80
                    ? ft.cyan
                    : FiTrackTheme.red;
                return Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      // DTW badge above bar — only shown when score exists.
                      if (dtw != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            '${(dtw * 100).round()}',
                            style: TextStyle(
                              fontSize: 7,
                              fontWeight: FontWeight.w700,
                              color: dtw >= 0.80
                                  ? ft.accent
                                  : dtw >= 0.60
                                  ? Colors.orangeAccent
                                  : FiTrackTheme.red,
                            ),
                          ),
                        ),
                      Flexible(
                        child: FractionallySizedBox(
                          heightFactor: v.clamp(0.0, 1.0),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 2),
                            decoration: BoxDecoration(
                              color: barColor,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${i + 1}',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.54,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 12),
          // Footer stats row
          Divider(color: theme.colorScheme.outlineVariant, height: 1),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _RepStat(
                label: 'Best',
                value:
                    '${(repQualities.reduce((a, b) => a > b ? a : b) * 100).round()}%',
                color: ft.accent,
              ),
              _RepStat(
                label: 'Avg',
                value:
                    '${((repQualities.reduce((a, b) => a + b) / repQualities.length) * 100).round()}%',
              ),
              _RepStat(label: 'Tempo', value: _avgTempoLabel()),
              _RepStat(label: 'Depth', value: _avgDepthLabel(), color: ft.cyan),
            ],
          ),
        ],
      ),
    );
  }

  /// Average concentric duration across reps that captured one. Returns
  /// `'—'` when no rep has a tempo (cold-start non-curl live session, or
  /// pre-WP5.4 reconstructed sessions where `concentricMs` was NULL).
  String _avgTempoLabel() {
    final tempos = repConcentricMs.whereType<int>().where((ms) => ms > 0);
    if (tempos.isEmpty) return '—';
    final avgMs = tempos.reduce((a, b) => a + b) / tempos.length;
    return '${(avgMs / 1000).toStringAsFixed(1)}s';
  }

  /// Average per-rep depth as a percentage. `'—'` when no rep had usable
  /// angles to compute depth (e.g. squat live sessions today, or all
  /// reconstructed reps with NULL min/max).
  String _avgDepthLabel() {
    final depths = repDepthPercents.whereType<double>();
    if (depths.isEmpty) return '—';
    final avg = depths.reduce((a, b) => a + b) / depths.length;
    return '${(avg * 100).round()}%';
  }

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

  Widget _buildFormMatchCard(BuildContext context) {
    final theme = Theme.of(context);
    final scores = dtwSimilarities.whereType<double>().toList();
    final avg = scores.reduce((a, b) => a + b) / scores.length;
    final pct = (avg * 100).round();
    final color = avg >= 0.80
        ? const Color(0xFF00E676)
        : avg >= 0.60
        ? const Color(0xFFFFB300)
        : const Color(0xFFFF5252);
    final subtitle = avg >= 0.85
        ? 'Your reps closely match the reference technique.'
        : avg >= 0.70
        ? 'Good alignment with reference form. A few deviations noted.'
        : avg >= 0.55
        ? 'Moderate match. Focus on the full range and tempo.'
        : 'Low match. Review technique and consider recalibrating.';

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
              Icon(Icons.compare_arrows_rounded, color: color, size: 20),
              const SizedBox(width: 8),
              Text(
                'Form Match (Beta)',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$pct',
                style: TextStyle(
                  fontSize: 56,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
              Text(
                '%',
                style: TextStyle(
                  fontSize: 24,
                  color: color.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
              fontSize: 14,
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

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
        child: switch (exercise) {
          ExerciseType.bicepsCurlFront ||
          ExerciseType.bicepsCurlSide ||
          // ignore: deprecated_member_use_from_same_package
          ExerciseType.bicepsCurl => _buildCurlSummary(context),
          ExerciseType.squat => _buildSquatSummary(context),
          ExerciseType.pushUp => _buildSimpleSummary(context),
        },
      ),
    );
  }

  /// Squat summary — mirrors the curl card style (hero header + stats +
  /// quality + form issues + insights) with squat-specific extras: variant
  /// chip, tall-lifter chip, per-rep ratio strip, knee-shift bucket label,
  /// and the conditional "Form check (legacy)" subhead for sessions that
  /// were saved before the rebuild.
  Widget _buildSquatSummary(BuildContext context) {
    final theme = Theme.of(context);
    final quality = _meanRepQuality();
    final qualityColor = _qualityColor(quality);
    final insights = _buildInsights();
    final hasLegacy = errorsTriggered.contains(FormError.trunkTibia);
    // The new squat error set, in display order. Drives the "Form Issues"
    // chip wrap. trunkTibia is rendered separately under a legacy subhead.
    const newSquatErrors = <FormError>{
      FormError.excessiveForwardLean,
      FormError.heelLift,
      FormError.forwardKneeShift,
      FormError.squatDepth,
    };
    final activeNew = errorsTriggered.where(newSquatErrors.contains).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Hero header
          Center(
            child: Column(
              children: [
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: qualityColor.withValues(alpha: 0.15),
                  ),
                  child: Icon(
                    Icons.check_circle_rounded,
                    color: qualityColor,
                    size: 64,
                  ),
                ),
                const SizedBox(height: 16),
                Semantics(
                  header: true,
                  child: Text(
                    exercise.label,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _MiniChip(label: widget.squatVariant.label),
                    if (widget.squatLongFemurLifter)
                      const _MiniChip(label: 'Tall lifter (+5°)'),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Stats Row
          Row(
            children: [
              Expanded(
                child: _StatChip(
                  icon: Icons.repeat,
                  label: 'REPS',
                  value: '$totalReps',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatChip(
                  icon: Icons.layers,
                  label: 'SETS',
                  value: '$totalSets',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatChip(
                  icon: Icons.timer,
                  label: 'TIME',
                  value: _formatDuration(sessionDuration),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Quality Card — always displayed (shows quality or "No reps recorded")
          _buildQualityCard(quality, qualityColor, context),
          const SizedBox(height: 16),

          // Per-rep quality strip
          if (repQualities.isNotEmpty) ...[
            _buildRepQualityStrip(context),
            const SizedBox(height: 16),
          ],

          // Form Issues Card (new squat errors)
          if (activeNew.isNotEmpty) ...[
            _buildSquatFormIssuesCard(activeNew, context),
            const SizedBox(height: 16),
          ],

          // Per-rep ratio strip — squat-only, live sessions only.
          if (widget.squatRepMetrics.isNotEmpty) ...[
            _buildSquatRatioStrip(context),
            const SizedBox(height: 16),
          ],

          // Legacy Form Check subhead — renders only when ≥1 trunkTibia row
          // exists (sessions saved before the Squat Master Rebuild).
          if (hasLegacy) ...[
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: Text(
                'Form check (legacy)',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.60),
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
            _buildLegacyTrunkTibiaRow(context),
            const SizedBox(height: 16),
          ],

          // Coaching Insights
          Container(
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
                      Icons.lightbulb_outline_rounded,
                      color: Color(0xFF00E676),
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Coaching Insights',
                      style: TextStyle(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.54,
                        ),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: insights.map((insight) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 4,
                            height: 4,
                            margin: const EdgeInsets.only(top: 6),
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(0xFF00E676),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              insight,
                              style: TextStyle(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.70,
                                ),
                                fontSize: 14,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),

          // Done button
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E676),
                foregroundColor: theme.colorScheme.onPrimary,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () =>
                  Navigator.of(context).popUntil((route) => route.isFirst),
              child: const Text(
                'Done',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

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

  Widget _buildQualityCard(
    double? quality,
    Color qualityColor,
    BuildContext context,
  ) {
    final theme = Theme.of(context);
    final ft = FiTrackColors.of(context);
    final hasData = totalReps > 0 && quality != null;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border(
          left: BorderSide(color: ft.cyan, width: 4),
          top: BorderSide(color: ft.stroke),
          right: BorderSide(color: ft.stroke),
          bottom: BorderSide(color: ft.stroke),
        ),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.videocam_rounded, color: ft.cyan, size: 18),
              const SizedBox(width: 8),
              Text(
                'AI FORM ACCURACY',
                style: TextStyle(
                  color: ft.cyan,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (hasData)
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${(quality * 100).round()}',
                  style: TextStyle(
                    fontSize: 84,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    height: 1,
                  ),
                ),
                Text(
                  '%',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                    color: ft.cyan,
                    height: 1,
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: qualityColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: qualityColor.withValues(alpha: 0.50),
                    ),
                  ),
                  child: Text(
                    _gradeLabel(quality),
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      color: qualityColor,
                      height: 1,
                    ),
                  ),
                ),
              ],
            )
          else
            Text(
              'No reps recorded',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
                fontSize: 14,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRepQualityStrip(BuildContext context) {
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
              Icon(
                Icons.bar_chart_rounded,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'Rep Quality',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Column(
            children: repQualities.asMap().entries.map((entry) {
              final repNum = entry.key + 1;
              final repQuality = entry.value;
              final barColor = _qualityColor(repQuality);
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 28,
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
                              height: 14,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.07,
                                ),
                                borderRadius: BorderRadius.circular(7),
                              ),
                            ),
                            Container(
                              width: constraints.maxWidth * repQuality,
                              height: 14,
                              decoration: BoxDecoration(
                                color: barColor,
                                borderRadius: BorderRadius.circular(7),
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
                        '${(repQuality * 100).round()}%',
                        style: TextStyle(color: barColor, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildSquatFormIssuesCard(List<FormError> errs, BuildContext context) {
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
            children: errs.map((err) {
              // forwardKneeShift uses a dimmer color (no TTS, informational
              // only) — matches the in-workout highlight palette.
              final chipColor = err == FormError.forwardKneeShift
                  ? const Color(0xFFFFA726)
                  : const Color(0xFFFF5252);
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: chipColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: chipColor.withValues(alpha: 0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_errorIcon(err), color: chipColor, size: 14),
                    const SizedBox(width: 6),
                    Text(
                      _errorLabel(err),
                      style: TextStyle(color: chipColor, fontSize: 13),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

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

  Widget _buildBicepsSideRatioStrip(BuildContext context) {
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
              Expanded(
                child: Text(
                  'Side-View Form — $viewLabel',
                  style: TextStyle(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
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
      ),
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

  Widget _buildCurlSummary(BuildContext context) {
    final ft = FiTrackColors.of(context);
    final theme = Theme.of(context);
    final quality = _meanRepQuality();
    final insights = _buildInsights();
    final qualityPct = quality != null ? (quality * 100).round() : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // [1] AI Form Accuracy hero — cyan-bordered card with radial glow
          _AiAccuracyHero(
            qualityPct: qualityPct,
            grade: _gradeLabel(quality),
            subtitle: _qualitySubtitle(quality),
            ft: ft,
          ),
          const SizedBox(height: 12),

          // [2] Time + Reps two-column grid
          Row(
            children: [
              Expanded(
                child: _SummaryStatCard(
                  icon: Icons.schedule_outlined,
                  label: 'Time',
                  value: _formatDuration(sessionDuration),
                  ft: ft,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _SummaryStatCard(
                  icon: Icons.repeat_rounded,
                  label: 'Total Reps',
                  value: '$totalReps',
                  ft: ft,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // [3] Sets chip (small, below the grid)
          Align(
            alignment: Alignment.centerLeft,
            child: _SetsChip(sets: totalSets, ft: ft),
          ),
          const SizedBox(height: 16),

          // [3.5] Form Match Card (DTW scoring — opt-in, hidden when no scores)
          if (dtwSimilarities.any((s) => s != null)) ...[
            _buildFormMatchCard(context),
            const SizedBox(height: 16),
          ],

          // [4] Accuracy by Rep bar chart
          if (repQualities.isNotEmpty) ...[
            _buildRepAccuracyCard(context),
            const SizedBox(height: 16),
          ],

          // [5] Form Analysis Card — hidden when no reps committed.
          // Frame-level errors (`elbowRise`, `torsoSwing`, etc.) can fire
          // during partial rep attempts that abort back to IDLE before
          // committing, leaving `errorsTriggered` non-empty even when
          // `totalReps == 0`. Showing those errors with no rep context
          // is misleading: the user has nothing to compare them against
          // and no way to act on them. The "no reps" insight from
          // `_buildInsights()` covers the actual problem (framing).
          if (errorsTriggered.isNotEmpty && totalReps > 0) ...[
            Container(
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
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.54,
                          ),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: errorsTriggered
                        .where(
                          (err) => ![
                            FormError.squatDepth,
                            FormError.trunkTibia,
                            FormError.hipSag,
                            FormError.pushUpShortRom,
                          ].contains(err),
                        )
                        .map((err) {
                          final chipColor = const Color(0xFFFF5252);
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: chipColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: chipColor.withValues(alpha: 0.5),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _errorIcon(err),
                                  color: chipColor,
                                  size: 14,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  _errorLabel(err),
                                  style: TextStyle(
                                    color: chipColor,
                                    fontSize: 13,
                                  ),
                                ),
                                if ((errorCounts[err] ?? 0) > 1) ...[
                                  const SizedBox(width: 5),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: chipColor.withValues(alpha: 0.20),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      '×${errorCounts[err]}',
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
                        })
                        .toList(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // [6] Insights Card
          Container(
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
                      Icons.lightbulb_outline_rounded,
                      color: Color(0xFF00E676),
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Coaching Insights',
                      style: TextStyle(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.54,
                        ),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: insights.asMap().entries.map((entry) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 4,
                            height: 4,
                            margin: const EdgeInsets.only(top: 6),
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(0xFF00E676),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              entry.value,
                              style: TextStyle(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.70,
                                ),
                                fontSize: 14,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // [6.5] Details panel — per-bucket / per-arm / threshold sources.
          if (curlRepRecords.isNotEmpty || curlBucketSummaries.isNotEmpty) ...[
            _buildDetailsCard(context),
            const SizedBox(height: 16),
          ],

          // [6.6] Side-view per-rep averages — only for bicepsCurlSide sessions
          if (widget.bicepsSideRepMetrics.isNotEmpty) ...[
            _buildBicepsSideRatioStrip(context),
            const SizedBox(height: 16),
          ],

          // [7] Camera View Chip
          if (detectedView != CurlCameraView.unknown)
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
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
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.38,
                      ),
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _viewLabel(detectedView),
                      style: TextStyle(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.38,
                        ),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 32),

          // Done Button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E676),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () =>
                  Navigator.of(context).popUntil((route) => route.isFirst),
              child: const Text(
                'Done',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSimpleSummary(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(
            Icons.check_circle_outline,
            color: Color(0xFF00E676),
            size: 96,
          ),
          const SizedBox(height: 24),
          Text(
            exercise.label,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 48),
          _StatRow(label: 'Reps', value: '$totalReps'),
          const SizedBox(height: 16),
          _StatRow(label: 'Sets', value: '$totalSets'),
          const SizedBox(height: 16),
          _StatRow(label: 'Duration', value: _formatDuration(sessionDuration)),
          const Spacer(),
          ElevatedButton(
            onPressed: () =>
                Navigator.of(context).popUntil((route) => route.isFirst),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 18),
            ),
            child: const Text(
              'Done',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: const Color(0xFF00E676), size: 20),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
              fontSize: 11,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;

  const _StatRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    // Single Semantics wrapper so the row announces as one coherent unit
    // ("Reps: 12") instead of "Reps" and "12" as separate, spatially-distant
    // reads which is how `mainAxisAlignment: spaceBetween` would otherwise
    // present to a screen reader.
    final theme = Theme.of(context);
    return Semantics(
      label: '$label: $value',
      excludeSemantics: true,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
              fontSize: 18,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: theme.colorScheme.onSurface,
              fontSize: 24,
              fontWeight: FontWeight.w600,
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

/// Small inline pill used in the squat header (variant + tall-lifter chip).
class _MiniChip extends StatelessWidget {
  const _MiniChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
          fontSize: 12,
        ),
      ),
    );
  }
}

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

class _RepStat extends StatelessWidget {
  const _RepStat({required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resolvedColor = color ?? theme.colorScheme.onSurface;
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.64,
            color: resolvedColor,
          ),
        ),
      ],
    );
  }
}

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

// ── Design "Subtle" summary new widgets ────────────────────────────────────

/// AI Form Accuracy hero card — cyan left-border, radial glow, large number.
class _AiAccuracyHero extends StatelessWidget {
  const _AiAccuracyHero({
    required this.qualityPct,
    required this.grade,
    required this.subtitle,
    required this.ft,
  });

  final int? qualityPct;
  final String grade;
  final String subtitle;
  final FiTrackColors ft;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: ft.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(color: ft.cyan, width: 3),
          top: BorderSide(color: ft.stroke),
          right: BorderSide(color: ft.stroke),
          bottom: BorderSide(color: ft.stroke),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // Radial glow from top-centre
          Positioned(
            top: -40,
            left: 0,
            right: 0,
            child: Container(
              height: 140,
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.topCenter,
                  radius: 1.0,
                  colors: [ft.cyan.withAlpha(0x20), ft.cyan.withAlpha(0x00)],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                // "AI Form Accuracy" label
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.memory_rounded, color: ft.cyan, size: 14),
                    const SizedBox(width: 6),
                    Text(
                      'AI FORM ACCURACY',
                      style: TextStyle(
                        color: ft.cyan,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // Large number
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      qualityPct != null ? '$qualityPct' : '—',
                      style: TextStyle(
                        fontSize: 84,
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
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: ft.cyan.withAlpha(0x26),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: ft.cyan.withAlpha(0x80)),
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
                  style: TextStyle(
                    color: ft.textDim,
                    fontSize: 13,
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Two-column stat card for Time / Reps (design grid row).
class _SummaryStatCard extends StatelessWidget {
  const _SummaryStatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.ft,
  });

  final IconData icon;
  final String label;
  final String value;
  final FiTrackColors ft;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ft.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ft.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: ft.textDim, size: 14),
              const SizedBox(width: 6),
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  color: ft.textDim,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: TextStyle(
              color: ft.textStrong,
              fontSize: 32,
              fontWeight: FontWeight.w700,
              letterSpacing: -1,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small inline chip showing set count — sits below the stat grid.
class _SetsChip extends StatelessWidget {
  const _SetsChip({required this.sets, required this.ft});

  final int sets;
  final FiTrackColors ft;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: ft.surface3,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: ft.stroke),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.layers_rounded, color: ft.textDim, size: 12),
          const SizedBox(width: 6),
          Text(
            '$sets SET${sets == 1 ? '' : 'S'}',
            style: TextStyle(
              color: ft.textDim,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}
