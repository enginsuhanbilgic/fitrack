import 'dart:math' as math;

import '../../core/constants.dart';
import '../../core/squat_form_thresholds.dart';
import '../../core/types.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_landmark.dart';
import '../../models/pose_result.dart';
import '../form_analyzer_base.dart';

/// Form analyzer for squat — research-grounded rulebook (Squat Master Rebuild).
///
/// Active frame-level errors (evaluated during DESCENDING + BOTTOM):
///   - `excessiveForwardLean`: signed trunk-from-vertical exceeds the
///     variant-specific threshold (45° BW, 50° HBBS, +5° if long-femur).
///     Backward lean (negative signed angle) does NOT fire — preventing
///     false positives for users who lean back as they squat.
///   - `heelLift`: `(foot_index_y − heel_y) / leg_len_px > 0.03`
///     (heel rises above forefoot in screen coords).
///   - `forwardKneeShift`: `(knee_x − ankle_x) / femur_len_px > 0.30`.
///     INFORMATIONAL — emitted to drive the on-screen highlight, but the
///     view-model's TTS path filters it out. No quality penalty.
///
/// Rep-boundary error (consumed once at rep commit):
///   - `squatDepth`: rep completed without reaching `effectiveBottomAngle`.
///
/// Per-rep quality score (mirrors curl multiplicative deduction model):
///   - Depth factor: `0.5 + 0.5 * ((180−minAngle)/(180−effectiveBottom))`
///   - Lean: up to `kQualitySquatLeanMaxDeduction` (0.20), proportional
///   - Heel lift: up to `kQualitySquatHeelLiftMaxDeduction` (0.10)
///   - Knee shift: intentionally excluded (informational only)
///
/// Camera-side selection: per frame, picks left vs. right based on
/// average hip+knee+ankle visibility. The two sides emit asymmetric
/// signals during a side-on recording — picking the high-visibility
/// side avoids flickering between low-confidence false-positives.
class SquatFormAnalyzer extends FormAnalyzerBase {
  SquatFormAnalyzer({
    required this.variant,
    required this.longFemurLifter,
    SquatFormThresholds formThresholds = SquatFormThresholds.defaults,
    List<Duration> historicalConcentricDurations = const [],
  }) : _formThresholds = formThresholds,
       _historicalConcentricDurations = List<Duration>.unmodifiable(
         historicalConcentricDurations,
       ),
       _leanWarnDeg = formThresholds.leanWarnFor(
         variant,
         longFemur: longFemurLifter,
       );

  final SquatVariant variant;

  /// "Tall lifter" Settings toggle. Orthogonal to the auto-detected
  /// long-femur flag in `SquatStrategy` (which relaxes BOTTOM angle, not
  /// the lean threshold). The two never stack on the same threshold.
  final bool longFemurLifter;

  final SquatFormThresholds _formThresholds;

  /// Active lean threshold (variant-specific + optional +5° boost).
  /// Frozen at construction so a mid-session Settings change cannot affect
  /// an in-flight workout (snapshot-on-construction, plan flow-decision #2).
  final double _leanWarnDeg;

  // ── Per-rep extremes (all reset by `consumeCompletionErrorsWithDepth`) ──
  double? _minKneeAngle;
  double? _maxLeanDeg;
  double? _maxKneeShiftRatio;
  double? _maxHeelLiftRatio;

  // ── No-knee-flexion detector (per-rep) ────────────────────
  /// Knee angle captured at `onDescendingStart` (rep start). Compared
  /// against `_minKneeAngle` at completion to compute the rep's total
  /// knee-flexion delta. Null between commit and the next descent.
  double? _startKneeAngle;

  // ── Hips-forward-on-descent detector (per-rep) ────────────
  /// First-frame hip/heel reference captured at `onDescendingStart` once
  /// a high-visibility pose is observed. Used as the t=0 anchor for the
  /// hip-X-drift evaluation inside the [kSquatHipsForwardWindowMs] window.
  double? _descentStartHipX;
  double? _descentStartHeelX;
  double? _descentStartLegLen;
  DateTime? _descentStartTime;

  /// Per-frame hip-X samples accumulated inside the descent window.
  /// Bounded by [kSquatHipsForwardWindowMs] — once the window closes,
  /// further samples are ignored so a slow descent can't smear the
  /// initiation signal.
  final List<double> _descentHipXSamples = [];

  /// Set during the descent-window evaluation if the hip drifted toward
  /// the toes by more than [kSquatHipsForwardMinRatio] of leg length.
  /// Drained at rep completion into the FormError set.
  bool _hipsForwardOnDescentFired = false;

  /// Most recent signed forward-drift ratio (`Δhip.x / leg_len`) measured
  /// at the close of the descent window. Positive = drifted toward toes
  /// (fault); negative = hinged back (correct). Null when the check has
  /// not yet run for the current rep. Surfaced for telemetry.
  double? _lastRepHipsForwardRatio;

  // ── Knee-led-descent detector (per-rep, 2026-05-16) ───────
  /// Knee.x and hip.y captured at the t=0 anchor of the SHARED descent
  /// window (the same `_descentStartTime` the hips-forward sampler opens —
  /// no second timer). Used to compute the early-descent knee-forward vs
  /// hip-drop dominance ratio. Null until the first valid anchor frame.
  double? _descentStartKneeX;
  double? _descentStartHipY;

  /// Most recent knee.x sample inside the window — the window-close value
  /// is differenced against `_descentStartKneeX`. Updated every sampled
  /// frame; the hip-Y counterpart is read from the live pose at close.
  double? _lastDescentKneeX;
  double? _lastDescentHipY;

  /// Set during the descent-window evaluation when early knee-forward
  /// travel dominated hip-drop beyond [kSquatKneeLedMinRatio]. Drained at
  /// rep completion into the FormError set.
  bool _kneeLedDescentFired = false;

  /// Count of frames sampled inside the shared descent window for the
  /// knee-led check (includes the anchor frame). Gates the fail-open floor
  /// [kSquatKneeLedMinFrames] — a too-short window is dominated by
  /// pose-detector noise. Mirrors the hips-forward sampler's
  /// `_descentHipXSamples.length` guard.
  int _kneeLedSampleCount = 0;

  /// Most recent knee-led ratio (`|Δknee.x| / max(ε, Δhip.y_down)`,
  /// leg-length-normalized) measured at the close of the descent window.
  /// > [kSquatKneeLedMinRatio] = knee darted forward instead of hips
  /// sitting back. Null between rep commit and the next window close.
  /// Surfaced for the `squat.knee_led` telemetry line.
  double? _lastRepKneeLedRatio;

  /// Latest signed lean reading from the most recent `evaluate()` frame.
  /// Drives the HUD's live forward-lean readout. Distinct from
  /// `_maxLeanDeg` (per-rep peak magnitude); this one is per-frame and
  /// preserves sign so the HUD can show "+32°" (forward) vs "−8°"
  /// (backward) in real time.
  double? _currentSignedLeanDeg;

  // ── Sustained forward-lean gate (per-rep) ─────────────────
  /// Count of evaluated frames this rep whose signed forward lean exceeded
  /// `_leanWarnDeg`. Numerator of the sustained-lean fraction. Reset at
  /// `onDescendingStart` and rep commit.
  int _leanExceedFrameCount = 0;

  /// Count of frames this rep where a valid (non-null) signed lean was
  /// measured at all. Denominator of the sustained-lean fraction — only
  /// frames with a usable shoulder/hip pair count. Reset alongside
  /// `_leanExceedFrameCount`.
  int _leanTotalEvalFrameCount = 0;

  // ── Lean sign-convention diagnostics (per-rep, 2026-05-16) ──
  /// SIGNED lean at the frame where |lean| peaked this rep. Distinct from
  /// `_maxLeanDeg` (which is `abs(lean)` and loses the sign — the reason a
  /// `lean_deg=38` telemetry value can't tell us whether the camera saw a
  /// forward (+) or backward (−) lean). Added to diagnose Bug 4: every
  /// pre-flight rep logged `lean_deg≈38` yet `lean_exceed_frac=0.0000`,
  /// which is consistent with the signed value being NEGATIVE at this
  /// camera angle (so `lean > +30°` never trips). Surfaced as
  /// `signed_lean=` on `squat.rep` so the next session is conclusive.
  double? _lastRepSignedLeanAtPeak;

  /// Count of frames this rep that fired `excessiveBackwardLean`
  /// (`lean < -kSquatBackwardLeanWarnDeg`). If the sign is inverted at the
  /// user's camera, a genuinely forward-leaning squat will rack up backward
  /// fires while forward never triggers — this counter is the smoking gun.
  /// Surfaced as `backward_lean_frames=` on `squat.rep`.
  int _backwardLeanFrameCount = 0;

  /// Commit-time snapshot of `_backwardLeanFrameCount` (the live counter
  /// drains at the next `onDescendingStart`; the host reads this getter
  /// post-commit). Mirrors the `_lastRepLeanExceedFrac` snapshot pattern.
  int _lastRepBackwardLeanFrameCount = 0;

  // ── Hip-lead detection (per-rep) ────────────────────────────
  /// True between `onAscendingStart` and `onAscendingEnd`. Gates per-frame
  /// hip/shoulder Y appending — `evaluate()` does not accumulate during
  /// DESCENDING / BOTTOM so the velocity buffer is purely ASCENDING.
  bool _ascendingPhaseActive = false;

  /// Per-frame hip + shoulder Y samples accumulated during the ASCENDING
  /// phase. Cleared at `onDescendingStart` and again at rep commit. Records
  /// are taken from the higher-visibility camera side picked by
  /// `_pickCameraSide` — same side selection rule as the rest of the
  /// analyzer for consistency.
  final List<({double hipY, double shoulderY})> _ascendingFrames = [];

  /// Set by `onAscendingEnd` when the hip-lead check fires. Drained into
  /// `consumeCompletionErrorsWithDepth`'s return set on the next call.
  bool _lastRepHipLeadFired = false;

  /// Most recent hip-lead ratio (`mean(v_y_hip) / mean(v_y_shoulder)` over
  /// the evaluation window). Null until the check has run at least once
  /// AND the window had ≥4 valid velocity pairs. Exposed for telemetry.
  double? _lastRepHipLeadRatio;

  /// Mean hip/shoulder screen-Y velocity recorded during the last
  /// `onAscendingEnd`. Stored separately from the ratio so a
  /// sign-convention test can pin the SIGN of each velocity component
  /// independently — a regression that flipped the velocity formula
  /// `-(y[i] − y[i-1])` to `(y[i] − y[i-1])` is invisible in the ratio
  /// (both flip; signs cancel) but visible here.
  double? _lastRepHipMeanVelocity;
  double? _lastRepShoulderMeanVelocity;

  // ── Last-rep outputs (read by SquatStrategy after rep commit) ──
  double? _lastRepQuality;
  double? _lastRepLeanDeg;
  double? _lastRepKneeShiftRatio;
  double? _lastRepHeelLiftRatio;

  /// Fraction of the last rep's evaluated frames whose forward lean
  /// exceeded `_leanWarnDeg` (`_leanExceedFrameCount / _leanTotalEvalFrameCount`).
  /// Snapshotted at commit before the per-rep counters drain. Null when the
  /// rep had zero evaluable lean frames. Surfaced for the `squat.rep`
  /// `lean_exceed_frac` telemetry field — this is the channel the offline
  /// threshold-derivation workflow consumes to retune
  /// `kSquatLeanSustainedFraction`.
  double? _lastRepLeanExceedFrac;

  // ── Tombstoned-detector commit snapshots (2026-05-21) ──
  // These three booleans capture whether the corresponding tombstoned
  // detector triggered on the just-committed rep. The detectors still
  // compute (their underlying samplers feed telemetry), but they no
  // longer emit a FormError. The snapshots survive past the per-rep
  // counter drain so the host can log them on the `squat.rep` telemetry
  // line. See enum-tombstone note in `consumeCompletionErrorsWithDepth`.
  bool _lastRepHipsForwardOnDescentFired = false;
  bool _lastRepKneeLedDescentFired = false;
  bool _lastRepTempoInconsistentSnapshot = false;

  // ── Tempo / fatigue tracking (2026-05-16, curl-parity) ──────────────
  // Phase mapping: DESCENDING = eccentric (lowering), ASCENDING =
  // concentric (lift). The STRATEGY pushes the injected `input.now`
  // timestamp in via stampDescentStart/stampAscentStart/stampAscentEnd
  // (NOT curl's DateTime.now() — squat uses the test-injectable clock).
  //
  // HALF-SQUAT VETO INTERACTION: `stampAscentEnd` computes
  // `_lastConcentricDuration` (so the per-rep too-fast cue still fires as
  // feedback on a vetoed half-squat — the user DID rush it), but does NOT
  // append to `_ascentDurations`. The strategy calls `commitAscentToWindow`
  // ONLY when the rep actually commits (`!missedDepth`), so a vetoed
  // half-squat never poisons the tempo-consistency / fatigue rolling
  // window. This is the one place squat deliberately diverges from curl
  // (curl has no depth veto, so it appends in onPeakReached).
  DateTime? _descentStart;
  DateTime? _ascentStart;
  Duration? _lastEccentricDuration;
  Duration? _lastConcentricDuration;
  int _tempoReArmRepsRemaining = 0;
  bool _lastRepTempoInconsistent = false;
  final List<Duration> _ascentDurations = [];
  bool _fatigueFired = false;
  final List<Duration> _historicalConcentricDurations;

  /// Ascent (concentric/lift) duration of the most recently committed
  /// rep, or null on a rep with no measured ascent. Pass-through to the
  /// host for `concentric_ms` persistence + the cross-session fatigue
  /// baseline. Mirrors `CurlSideFormAnalyzer.lastConcentricDuration`.
  Duration? get lastConcentricDuration => _lastConcentricDuration;

  /// Strategy stamps this at IDLE→DESCENDING (alongside the existing
  /// no-arg `onDescendingStart`). Resets per-rep phase timers.
  void stampDescentStart(DateTime now) {
    _descentStart = now;
    _ascentStart = null;
    _lastEccentricDuration = null;
    _lastConcentricDuration = null;
  }

  /// Strategy stamps this at BOTTOM→ASCENDING. Closes the eccentric
  /// (descent) timer, opens the concentric (ascent) timer.
  void stampAscentStart(DateTime now) {
    if (_descentStart != null) {
      _lastEccentricDuration = now.difference(_descentStart!);
    }
    _ascentStart = now;
  }

  /// Strategy stamps this at ASCENDING→IDLE BEFORE
  /// `consumeCompletionErrorsWithDepth`. Closes the concentric timer.
  /// Does NOT append to the rolling window — see [commitAscentToWindow].
  void stampAscentEnd(DateTime now) {
    if (_ascentStart != null) {
      _lastConcentricDuration = now.difference(_ascentStart!);
    }
  }

  /// Strategy calls this ONLY when the rep actually commits (passes the
  /// half-squat depth veto). Appends the just-measured ascent duration to
  /// the rolling window the tempo-consistency + fatigue signals read, so
  /// a vetoed half-squat never contaminates the window.
  void commitAscentToWindow() {
    if (_lastConcentricDuration != null) {
      _ascentDurations.add(_lastConcentricDuration!);
    }
  }

  /// Active lean threshold (deg) for the lifetime of this analyzer.
  double get leanWarnDeg => _leanWarnDeg;

  /// Most recently committed rep's quality score (0.0–1.0). Null until
  /// the first rep is committed.
  double? get lastRepQuality => _lastRepQuality;

  /// Most recent peak-lean reading (deg). Null until first commit.
  double? get lastRepLeanDeg => _lastRepLeanDeg;

  /// Most recent peak knee-shift ratio. Null until first commit.
  double? get lastRepKneeShiftRatio => _lastRepKneeShiftRatio;

  /// Most recent peak heel-lift ratio. Null until first commit.
  double? get lastRepHeelLiftRatio => _lastRepHeelLiftRatio;

  /// Fraction of the most recent rep's evaluated frames whose forward lean
  /// exceeded the active threshold. Null until first commit OR when the rep
  /// had zero evaluable lean frames. Read by the host for the `squat.rep`
  /// `lean_exceed_frac` telemetry field.
  double? get lastRepLeanExceedFrac => _lastRepLeanExceedFrac;

  /// SIGNED lean at the |lean| peak of the just-committed rep (forward = +,
  /// backward = −). Diagnostic for the Bug-4 sign-convention question.
  /// Null until first commit. Read by the host for `squat.rep`
  /// `signed_lean=`.
  double? get lastRepSignedLeanAtPeak => _lastRepSignedLeanAtPeak;

  /// Frames in the just-committed rep that fired `excessiveBackwardLean`.
  /// Read by the host for `squat.rep` `backward_lean_frames=`. A high
  /// value with `lean_exceed_frac=0` ⇒ sign inversion at the camera.
  /// Snapshotted at commit (the live counter drains at the next descent).
  int get lastRepBackwardLeanFrameCount => _lastRepBackwardLeanFrameCount;

  /// Most recent hip-lead ratio (`mean(v_y_hip) / mean(v_y_shoulder)` over
  /// the first 30% of ASCENDING). Null when the check hasn't run yet OR
  /// the rep was skipped (fewer than `kHipLeadMinAscendingFrames` raw
  /// frames OR <4 valid velocity pairs after the stationary-shoulder
  /// filter). Surfaced for telemetry — `consumeCompletionErrorsWithDepth`
  /// drains it, but the host reads this getter for the `squat.hip_lead`
  /// log line.
  double? get lastRepHipLeadRatio => _lastRepHipLeadRatio;

  /// Mean per-frame screen-Y velocity of the hip over the evaluation
  /// window (sign convention: positive = rising). Exposed so tests can
  /// lock the screen-Y inversion contract: a sign flip in the velocity
  /// formula would not change `lastRepHipLeadRatio` (same flip applied
  /// to both numerator and denominator), but it WOULD invert this
  /// value. Null in the same cases as [lastRepHipLeadRatio].
  double? get lastRepHipMeanVelocity => _lastRepHipMeanVelocity;

  /// Mean per-frame screen-Y velocity of the shoulder. Same lifecycle
  /// and sign convention as [lastRepHipMeanVelocity].
  double? get lastRepShoulderMeanVelocity => _lastRepShoulderMeanVelocity;

  /// Number of raw frames accumulated during the most recent ASCENDING
  /// window. Reset by `onDescendingStart` (the start of the next rep), so
  /// the host has the full window's count between commit and the next
  /// IDLE → DESCENDING transition. Exposed for the `squat.hip_lead`
  /// telemetry's `ascending_frame_count` field.
  int get ascendingFrameCount => _ascendingFrames.length;

  /// Number of frames sampled inside the shared early-descent window for
  /// the knee-led check (includes the anchor frame). Reset by
  /// `onDescendingStart`, so the host reads it between commit and the next
  /// rep. Exposed for the `squat.knee_led` telemetry's `window_frames`
  /// field — contextualizes the ratio the same way `ascending_frame_count`
  /// does for hip-lead.
  int get kneeLedSampleCount => _kneeLedSampleCount;

  /// Live signed forward-lean angle (deg) from the most recent `evaluate()`
  /// frame. Positive = forward lean; negative = backward; null when no
  /// high-confidence shoulder/hip pair was observed yet. The HUD binds to
  /// this for the on-screen real-time lean indicator (Cue 3, 2026-05-15).
  double? get currentSignedLeanDeg => _currentSignedLeanDeg;

  /// Most recent forward-hip-drift ratio measured at the close of the
  /// descent window. Positive = drifted toward toes (fault); negative =
  /// hinged back (correct). Null between rep commit and the next
  /// window close. Surfaced for telemetry.
  double? get lastRepHipsForwardRatio => _lastRepHipsForwardRatio;

  /// Most recent knee-led-descent ratio (`|Δknee.x| / max(ε,
  /// Δhip.y_down)`, leg-length-normalized) measured at the close of the
  /// shared descent window. Greater than [kSquatKneeLedMinRatio] means the
  /// knee darted forward instead of the hips sitting back — the inverse of
  /// "sit back into the squat." Null between rep commit and the next
  /// window close. The host reads this for the `squat.knee_led` telemetry
  /// line.
  double? get lastRepKneeLedRatio => _lastRepKneeLedRatio;

  /// Whether the (now tombstoned) hips-forward-on-descent detector
  /// triggered on the just-committed rep. The host reads this for
  /// telemetry; no TTS is emitted. False between resets.
  bool get lastRepHipsForwardOnDescentFired =>
      _lastRepHipsForwardOnDescentFired;

  /// Whether the (now tombstoned) knee-led-descent detector triggered on
  /// the just-committed rep. Telemetry only; no TTS.
  bool get lastRepKneeLedDescentFired => _lastRepKneeLedDescentFired;

  /// Whether the (now tombstoned) tempo-inconsistency detector triggered
  /// on the just-committed rep. Telemetry only; no TTS.
  bool get lastRepTempoInconsistent => _lastRepTempoInconsistentSnapshot;

  /// Call at IDLE → DESCENDING. Resets per-rep extremes; preserves the
  /// `_lastRep*` outputs so the strategy can still read the previous rep's
  /// quality between reps.
  @override
  void onRepStart(PoseResult startSnapshot) {
    _minKneeAngle = null;
    _maxLeanDeg = null;
    _maxKneeShiftRatio = null;
    _maxHeelLiftRatio = null;
    onDescendingStart();
  }

  /// Per-rep state for hip-lead. Called at IDLE → DESCENDING in addition
  /// to `onRepStart` — mirrors curl's `onRepStart` shape with an extra
  /// hook so the strategy can wire the lifecycle explicitly. Resets the
  /// hip-lead frame buffer + last-rep flags. Safe to call multiple times.
  void onDescendingStart() {
    _ascendingFrames.clear();
    _ascendingPhaseActive = false;
    _lastRepHipLeadFired = false;
    _lastRepHipLeadRatio = null;
    _lastRepHipMeanVelocity = null;
    _lastRepShoulderMeanVelocity = null;
    // Reset the no-knee-flexion + hips-forward detectors. `_startKneeAngle`
    // is populated on the next `trackAngle` call (the first frame of the
    // descent); `_descentStartHipX` / `_descentStartHeelX` /
    // `_descentStartLegLen` populate on the first `evaluate()` call where
    // landmarks are visible enough to anchor the t=0 reference.
    _startKneeAngle = null;
    _descentStartHipX = null;
    _descentStartHeelX = null;
    _descentStartLegLen = null;
    _descentStartTime = null;
    _descentHipXSamples.clear();
    _hipsForwardOnDescentFired = false;
    _lastRepHipsForwardRatio = null;
    _leanExceedFrameCount = 0;
    _leanTotalEvalFrameCount = 0;
    _backwardLeanFrameCount = 0;
    _lastRepSignedLeanAtPeak = null;
    _descentStartKneeX = null;
    _descentStartHipY = null;
    _lastDescentKneeX = null;
    _lastDescentHipY = null;
    _kneeLedDescentFired = false;
    _kneeLedSampleCount = 0;
    _lastRepKneeLedRatio = null;
  }

  /// Call at BOTTOM → ASCENDING. Enables per-frame hip+shoulder Y
  /// accumulation inside `evaluate()`.
  void onAscendingStart() {
    _ascendingPhaseActive = true;
  }

  /// Call at ASCENDING → IDLE (rep commit) BEFORE
  /// `consumeCompletionErrorsWithDepth(...)`. Evaluates the hip-lead
  /// ratio over the first [kHipLeadAscendingWindowFraction] of the
  /// collected frames; sets `_lastRepHipLeadFired` / `_lastRepHipLeadRatio`
  /// if the threshold is exceeded.
  ///
  /// Sign convention: in screen coordinates Y=0 is at the top, so
  /// "moving up" means `y` *decreases*. Velocity is computed as
  /// `-(y[i] − y[i-1])` so ascending produces POSITIVE values. A clean
  /// rep where hip and shoulder rise in lock-step yields ratio ≈ 1.0;
  /// a hip-lead rep yields ratio > 1.4.
  void onAscendingEnd() {
    _ascendingPhaseActive = false;
    final frames = _ascendingFrames;
    if (frames.length < kHipLeadMinAscendingFrames) return;

    final windowSize = math.max(
      kHipLeadMinAscendingFrames,
      (frames.length * kHipLeadAscendingWindowFraction).round(),
    );
    final clipped = windowSize > frames.length ? frames.length : windowSize;

    // Pairwise velocity over the window. Sign-inverted so screen-Y's
    // top-is-zero convention produces positive values during ascent.
    final hipVels = <double>[];
    final shoulderVels = <double>[];
    for (var i = 1; i < clipped; i++) {
      final dHip = -(frames[i].hipY - frames[i - 1].hipY);
      final dShoulder = -(frames[i].shoulderY - frames[i - 1].shoulderY);
      // Filter out frames where the shoulder is briefly stationary —
      // avoids div-by-zero noise on the ratio. The hip's own velocity
      // is unfiltered so a paused-shoulder hip-rising frame doesn't
      // drop out of the hip mean as well.
      if (dShoulder.abs() < 1e-6) continue;
      hipVels.add(dHip);
      shoulderVels.add(dShoulder);
    }

    // Fail-open below the minimum valid-pair count. A noisy 30%-of-rep
    // window where the shoulder was stationary for most frames doesn't
    // carry enough signal to grade — better to silently skip than to
    // false-fire on the few non-stationary samples.
    if (hipVels.length < 4) return;

    final meanHip = hipVels.reduce((a, b) => a + b) / hipVels.length;
    final meanShoulder =
        shoulderVels.reduce((a, b) => a + b) / shoulderVels.length;
    _lastRepHipMeanVelocity = meanHip;
    _lastRepShoulderMeanVelocity = meanShoulder;
    if (meanShoulder.abs() < 1e-6) return;
    final ratio = meanHip / meanShoulder;
    _lastRepHipLeadRatio = ratio;
    if (ratio > kHipLeadVelocityRatio) {
      _lastRepHipLeadFired = true;
    }
  }

  /// Track the lowest-knee-angle of the current rep. Called by
  /// `SquatStrategy` per frame during DESCENDING + BOTTOM. Also captures
  /// the descent-start knee angle (first call after `onDescendingStart`)
  /// for the no-knee-flexion detector's delta calculation.
  void trackAngle(double kneeAngle) {
    _startKneeAngle ??= kneeAngle;
    if (_minKneeAngle == null || kneeAngle < _minKneeAngle!) {
      _minKneeAngle = kneeAngle;
    }
  }

  /// Frame-level evaluation. Updates per-rep extremes and returns the set
  /// of frame-active errors.
  ///
  /// `forwardKneeShift` is intentionally surfaced here so the view-model
  /// can drive the visual highlight; the TTS path filters it out.
  @override
  List<FormError> evaluate(PoseResult current, {DateTime? now}) {
    final errors = <FormError>[];

    final side = _pickCameraSide(current);
    if (side == null) return errors;

    // Hip-lead per-frame accumulation. Only active between
    // `onAscendingStart` and `onAscendingEnd` — frames during DESCENDING
    // and BOTTOM are deliberately excluded because the velocity signal
    // we care about is the hip-vs-shoulder rise rate at the start of the
    // ascent. Uses the same camera-side selection rule as the rest of
    // the analyzer so a confidence flicker doesn't pull samples from
    // the off-camera arm into the buffer.
    if (_ascendingPhaseActive) {
      final hip = current.landmark(
        side == ExerciseSide.left ? LM.leftHip : LM.rightHip,
        minConfidence: kMinLandmarkConfidence,
      );
      final shoulder = current.landmark(
        side == ExerciseSide.left ? LM.leftShoulder : LM.rightShoulder,
        minConfidence: kMinLandmarkConfidence,
      );
      if (hip != null && shoulder != null) {
        _ascendingFrames.add((hipY: hip.y, shoulderY: shoulder.y));
      }
    }

    // Lean — signed; positive = forward, negative = backward.
    //
    // 2026-05-15: backward lean is now tracked AND cued. Pre-2026-05-15
    // `_signedLeanDeg` returned negative values for backward lean but the
    // analyzer filtered `lean > 0` at both the tracking site and the cue
    // site — erasing lumbar-hyperextension risk along with benign
    // counterbalance lean. Backward lean fires when `lean < -kSquatBackwardLeanWarnDeg`.
    final lean = _signedLeanDeg(current, side);
    _currentSignedLeanDeg = lean; // null-aware sink for the HUD readout
    if (lean != null) {
      // Track magnitude of the WORSE-direction lean for the per-rep peak.
      // Stored as a positive magnitude so `_lastRepLeanDeg` consumers see
      // a single number regardless of direction; direction is implied by
      // which FormError was emitted during the rep.
      final absLean = lean.abs();
      if (_maxLeanDeg == null || absLean > _maxLeanDeg!) {
        _maxLeanDeg = absLean;
        // Capture the SIGNED value at the magnitude peak — the diagnostic
        // that survives the abs(). Tells us forward(+) vs backward(−).
        _lastRepSignedLeanAtPeak = lean;
      }
      // Sustained-lean gate: accumulate evidence per frame, emit the
      // verdict ONCE at rep commit (see `consumeCompletionErrorsWithDepth`).
      // A single over-threshold frame at the deepest point of an otherwise
      // good rep no longer false-fires `excessiveForwardLean`.
      _leanTotalEvalFrameCount++;
      if (lean > _leanWarnDeg) {
        _leanExceedFrameCount++;
      } else if (lean < -kSquatBackwardLeanWarnDeg) {
        // Backward lean stays instantaneous — lumbar hyperextension is a
        // genuine single-frame injury vector, not a sustained-pattern fault.
        _backwardLeanFrameCount++;
        errors.add(FormError.excessiveBackwardLean);
      }
    }

    // Knee shift — informational. Always non-negative.
    final kneeShift = _kneeShiftRatio(current, side);
    if (kneeShift != null) {
      if (_maxKneeShiftRatio == null || kneeShift > _maxKneeShiftRatio!) {
        _maxKneeShiftRatio = kneeShift;
      }
      if (kneeShift > _formThresholds.kneeShiftWarnRatio) {
        errors.add(FormError.forwardKneeShift);
      }
    }

    // Heel lift — non-negative ratio; fires when heel rises above forefoot.
    final heelLift = _heelLiftRatio(current, side);
    if (heelLift != null) {
      if (_maxHeelLiftRatio == null || heelLift > _maxHeelLiftRatio!) {
        _maxHeelLiftRatio = heelLift;
      }
      if (heelLift > _formThresholds.heelLiftWarnRatio) {
        errors.add(FormError.heelLift);
      }
    }

    // Hips-forward-on-descent: sample hip.x trajectory in the first
    // [kSquatHipsForwardWindowMs] of the descent and grade at window
    // close. The window opens when the first high-confidence pose lands;
    // `onDescendingStart` itself cannot anchor t=0 because it may fire on
    // a frame where landmarks weren't yet visible.
    _maybeSampleDescentHipX(current, side, now);

    // Knee-led-descent: sample knee.x vs hip.y over the SAME early-descent
    // window the hip-X sampler opens (shared `_descentStartTime` — no
    // second timer). Detects knees darting forward instead of hips sitting
    // back. Called after the hip-X sampler so the t=0 anchor is already
    // open on the first valid frame.
    _maybeSampleKneeLedDescent(current, side, now);

    return errors;
  }

  /// Captures the first valid hip/heel/leg-length anchor at descent start,
  /// then accumulates `hip.x` samples until the time window closes. On
  /// close, computes the signed drift ratio and sets the fault flag if it
  /// exceeds the threshold. Subsequent frames inside the same rep no-op
  /// (the check has already run).
  void _maybeSampleDescentHipX(
    PoseResult current,
    ExerciseSide side,
    DateTime? now,
  ) {
    if (_lastRepHipsForwardRatio != null) return; // window already graded
    final hip = current.landmark(
      side == ExerciseSide.left ? LM.leftHip : LM.rightHip,
      minConfidence: kMinLandmarkConfidence,
    );
    final heel = current.landmark(
      side == ExerciseSide.left ? LM.leftHeel : LM.rightHeel,
      minConfidence: kMinLandmarkConfidence,
    );
    final ankle = current.landmark(
      side == ExerciseSide.left ? LM.leftAnkle : LM.rightAnkle,
      minConfidence: kMinLandmarkConfidence,
    );
    if (hip == null || heel == null || ankle == null) return;
    final t = now ?? DateTime.now();
    // First valid frame: anchor t=0.
    if (_descentStartTime == null) {
      _descentStartTime = t;
      _descentStartHipX = hip.x;
      _descentStartHeelX = heel.x;
      _descentStartLegLen = _euclidean(hip, ankle);
      _descentHipXSamples.add(hip.x);
      return;
    }
    _descentHipXSamples.add(hip.x);
    final elapsedMs = t.difference(_descentStartTime!).inMilliseconds;
    if (elapsedMs < kSquatHipsForwardWindowMs) return;
    if (_descentHipXSamples.length < kSquatHipsForwardMinFrames) {
      // Fail-open: not enough samples in the window. Mark as graded so the
      // check doesn't re-run later in the same rep, but emit a null ratio.
      _lastRepHipsForwardRatio = 0.0;
      return;
    }
    final legLen = _descentStartLegLen!;
    if (legLen < 1e-6) {
      _lastRepHipsForwardRatio = 0.0;
      return;
    }
    final endHipX = _descentHipXSamples.last;
    // Sign convention: in image space, the "toes" direction depends on
    // which side faces the camera. We use `heel.x` as the reference: a
    // hip drifting AWAY from the heel along the heel→toes axis is the
    // fault. For a right-side view (camera on user's left), toes have
    // higher x than heel, so `(endHipX - startHipX)` with the same sign
    // as `(toes - heel)` flags a forward drift. The heel anchor itself
    // is the most stable foot landmark across the descent (foot_index
    // is occluded once the user shifts their weight back).
    final hipDelta = endHipX - _descentStartHipX!;
    // Use the START heel anchor (descent-time t=0) so micro-jitter in the
    // current frame's heel doesn't perturb the sign. Toes-direction is
    // approximated as the direction the hip would naturally migrate
    // during a knee-dominant fault: same X sign as the lateral offset of
    // hip from heel at start. If `hip - heel` was positive at t=0, then
    // further positive hipDelta = forward; if negative at t=0, then
    // further negative hipDelta = forward. Sign-normalize accordingly.
    final initialHipHeelOffset = _descentStartHipX! - _descentStartHeelX!;
    final forwardSign = initialHipHeelOffset >= 0 ? 1.0 : -1.0;
    final ratio = (hipDelta * forwardSign) / legLen;
    _lastRepHipsForwardRatio = ratio;
    if (ratio > kSquatHipsForwardMinRatio) {
      _hipsForwardOnDescentFired = true;
    }
  }

  /// Knee-led-descent sampler. Mirrors [_maybeSampleDescentHipX]'s window
  /// machinery but measures a different signal: how far the knee travels
  /// horizontally vs how far the hip drops vertically in the first
  /// [kSquatHipsForwardWindowMs] of the descent. A correct squat *sits
  /// back* — large hip-Y drop, small knee-X travel. A knee-dominant fault
  /// *darts the knee forward* — large knee-X travel, small hip drop.
  ///
  /// Shares `_descentStartTime` with the hip-X sampler (the plan forbids a
  /// second timer): both anchor on the first valid frame and close the
  /// window at the same elapsed time, so the two early-descent signals are
  /// directly comparable. This sampler keys its own anchor off
  /// `_descentStartKneeX == null` (rather than `_descentStartTime`) so the
  /// call ordering with the hip-X sampler doesn't matter — whichever opens
  /// the timer, this one captures its own anchor on the same frame.
  ///
  /// Sign convention: in screen coords Y=0 is top, so a descending hip has
  /// INCREASING y. `Δhip.y_down = endHipY - startHipY` is positive on a
  /// real descent. Knee-X travel is taken as an absolute magnitude — the
  /// fault is "knee moved a lot horizontally regardless of direction"
  /// relative to a small hip drop. Both deltas are leg-length-normalized so
  /// the ratio is scale-invariant; `ratio = |Δknee.x| / max(ε, Δhip.y_down)`.
  void _maybeSampleKneeLedDescent(
    PoseResult current,
    ExerciseSide side,
    DateTime? now,
  ) {
    if (_lastRepKneeLedRatio != null) return; // window already graded
    final hip = current.landmark(
      side == ExerciseSide.left ? LM.leftHip : LM.rightHip,
      minConfidence: kMinLandmarkConfidence,
    );
    final knee = current.landmark(
      side == ExerciseSide.left ? LM.leftKnee : LM.rightKnee,
      minConfidence: kMinLandmarkConfidence,
    );
    final ankle = current.landmark(
      side == ExerciseSide.left ? LM.leftAnkle : LM.rightAnkle,
      minConfidence: kMinLandmarkConfidence,
    );
    if (hip == null || knee == null || ankle == null) return;
    final t = now ?? DateTime.now();
    // First valid frame for THIS sampler: anchor the knee.x / hip.y
    // reference. `_descentStartTime` may already be set by the hip-X
    // sampler (called first) — that's fine, we reuse it as the shared
    // window clock. If for some reason this sampler sees a valid frame
    // before the hip-X one, set the shared timer here too.
    if (_descentStartKneeX == null) {
      _descentStartTime ??= t;
      _descentStartKneeX = knee.x;
      _descentStartHipY = hip.y;
      _descentStartLegLen ??= _euclidean(hip, ankle);
      _lastDescentKneeX = knee.x;
      _lastDescentHipY = hip.y;
      _kneeLedSampleCount = 1;
      return;
    }
    _lastDescentKneeX = knee.x;
    _lastDescentHipY = hip.y;
    _kneeLedSampleCount++;
    final elapsedMs = t.difference(_descentStartTime!).inMilliseconds;
    if (elapsedMs < kSquatHipsForwardWindowMs) return;
    if (_kneeLedSampleCount < kSquatKneeLedMinFrames) {
      // Fail-open: too few samples in the window to grade. Mark as graded
      // (null ratio) so the check doesn't re-run later in the same rep.
      _lastRepKneeLedRatio = 0.0;
      return;
    }
    final legLen = _descentStartLegLen;
    if (legLen == null || legLen < 1e-6) {
      _lastRepKneeLedRatio = 0.0;
      return;
    }
    final kneeTravel = (_lastDescentKneeX! - _descentStartKneeX!).abs();
    // Hip drop in screen-Y (positive on a real descent). Clamp the
    // denominator at a small epsilon so a near-zero hip drop (the user
    // barely sank) doesn't explode the ratio into a false positive — a
    // shallow rep is already caught by `squatDepth`, not this detector.
    final hipDrop = math.max(1e-6, _lastDescentHipY! - _descentStartHipY!);
    final ratio = (kneeTravel / legLen) / (hipDrop / legLen);
    _lastRepKneeLedRatio = ratio;
    if (ratio > kSquatKneeLedMinRatio) {
      _kneeLedDescentFired = true;
    }
  }

  /// Base-contract stub. Squat completion requires the effective bottom
  /// angle (long-femur adaptation), so callers must use
  /// [consumeCompletionErrorsWithDepth] instead.
  @override
  List<FormError> consumeCompletionErrors() {
    throw UnsupportedError(
      'SquatFormAnalyzer requires effectiveBottomAngle — '
      'call consumeCompletionErrorsWithDepth instead.',
    );
  }

  /// Rep-boundary evaluation — called by `SquatStrategy` at rep commit.
  /// Computes the per-rep quality score, snapshots it for the strategy
  /// to read, then resets the per-rep extremes.
  ///
  /// IMPORTANT: callers must invoke `onAscendingEnd()` BEFORE this so the
  /// hip-lead check has populated `_lastRepHipLeadFired` /
  /// `_lastRepHipLeadRatio`. The quality score also reads
  /// `_lastRepHipLeadRatio`, so the ordering is load-bearing.
  List<FormError> consumeCompletionErrorsWithDepth(
    double effectiveBottomAngle,
  ) {
    // ── Emission order = priority order (2026-05-21 audit). ────────────
    // The view-model's `_onFormErrors` walks this list and `break`s at the
    // first speakable item, so list-position IS the cue priority. Final
    // shipped order: depth → noKneeFlexion → hipLead → forwardLean →
    // eccentricTooFast. Frame-level errors (heelLift, backwardLean) are
    // merged BEFORE this list by SquatStrategy, so heelLift naturally
    // lands between noKneeFlexion and hipLead at the priority slot it
    // deserves.
    //
    // ENUM-TOMBSTONE NOTE: the following FormError values are no longer
    // emitted but remain in `types.dart` per project policy (no clean
    // deletes without dev-mode authorization):
    //   - kneeDominantPattern (subsumed by noKneeFlexion + heelLift firing
    //     independently)
    //   - hipsForwardOnDescent, kneeLedDescent (subsumed by noKneeFlexion;
    //     small-window detectors with fragile sign normalization)
    //   - squatConcentricTooFast (explosive ascent is good form unloaded)
    //   - squatTempoInconsistent, squatFatigue (statistical, low confidence
    //     at typical rep counts)
    // Their underlying metrics are STILL COMPUTED below so the telemetry
    // pipeline remains intact — only the `errors.add(...)` calls are gone.
    final errors = <FormError>[];

    // 1. Depth — the dominant fault. If you didn't reach depth, no other
    // cue is more important; the half-squat veto in SquatStrategy also
    // suppresses rep-counting on this verdict.
    if (_minKneeAngle != null && _minKneeAngle! >= effectiveBottomAngle) {
      errors.add(FormError.squatDepth);
    }

    // 2. noKneeFlexion — broadened 2026-05-21. Two firing conditions:
    //   (a) Stiff-legged miss (lone trigger): kneeDelta < 15° regardless
    //       of lean. Covers the user who barely bent their knees at all,
    //       which is hip-pivoting in either lean direction.
    //   (b) Hip-pivot conjunction (legacy): lean ≥ 25° AND kneeDelta < 20°.
    //       Covers the user who pivoted at the hip with a torso dive but
    //       slightly-more-than-stiff-legged knee bend.
    final kneeDelta = (_startKneeAngle != null && _minKneeAngle != null)
        ? _startKneeAngle! - _minKneeAngle!
        : null;
    final stiffLegged =
        kneeDelta != null &&
        kneeDelta < kSquatNoKneeFlexionStiffLeggedMaxDeltaDeg;
    final hipPivotConjunction =
        _maxLeanDeg != null &&
        _maxLeanDeg! >= kSquatNoKneeFlexionMinLeanDeg &&
        kneeDelta != null &&
        kneeDelta < kSquatNoKneeFlexionMaxKneeDeltaDeg;
    if (stiffLegged || hipPivotConjunction) {
      errors.add(FormError.noKneeFlexion);
    }

    // 3. hipLead — "good morning out of the hole." Y-velocity only, so the
    // sign-immune by construction. Catches the cause ~300ms earlier than
    // the forward-lean detector catches the symptom.
    if (_lastRepHipLeadFired) {
      errors.add(FormError.hipLead);
    }

    // 4. Sustained forward-lean verdict. Emitted once per rep iff a meaningful
    // fraction of the rep's evaluated frames held the lean over threshold.
    // Fails OPEN below the min-frame floor — a too-short rep can't carry
    // enough signal to grade, so it's silently passed rather than false-flagged.
    if (_leanTotalEvalFrameCount >= kSquatLeanMinEvalFrames &&
        _leanExceedFrameCount / _leanTotalEvalFrameCount >=
            kSquatLeanSustainedFraction) {
      errors.add(FormError.excessiveForwardLean);
    }

    // 5. Eccentric (descent) too fast. The strategy has already called
    // `stampAscentEnd` before this, so phase durations are final. Fires
    // as feedback EVEN on a vetoed half-squat (the user did rush it).
    if (_lastEccentricDuration != null &&
        _lastEccentricDuration!.inMilliseconds < kSquatMinEccentricSec * 1000) {
      errors.add(FormError.squatEccentricTooFast);
    }

    // ── Tombstoned detectors: metrics still compute, no errors.add. ────
    // The view-model and telemetry pipeline read the underlying
    // `_lastRepHipsForwardRatio`, `_lastRepKneeLedRatio`,
    // `_lastConcentricDuration`, the tempo rolling window, and the
    // historical concentric-duration baseline. The book-keeping below
    // preserves those reads without surfacing TTS or quality penalties.

    // Tempo-inconsistency book-keeping (telemetry only — no errors.add).
    _lastRepTempoInconsistent = false;
    if (_tempoReArmRepsRemaining > 0) {
      _tempoReArmRepsRemaining--;
    } else if (_ascentDurations.length >= kSquatTempoConsistencyWindow) {
      final window = _ascentDurations.sublist(
        _ascentDurations.length - kSquatTempoConsistencyWindow,
      );
      final ms = window.map((d) => d.inMilliseconds.toDouble()).toList();
      final mean = ms.reduce((a, b) => a + b) / ms.length;
      if (mean > 0) {
        final spread =
            ms.reduce((a, b) => a > b ? a : b) -
            ms.reduce((a, b) => a < b ? a : b);
        if (spread / mean > kSquatTempoInconsistencyRatio) {
          _lastRepTempoInconsistent = true;
          _tempoReArmRepsRemaining = kSquatTempoConsistencyReArmReps;
        }
      }
    }

    // Fatigue book-keeping (telemetry only — no errors.add).
    if (!_fatigueFired && _ascentDurations.length >= kSquatFatigueMinReps) {
      final firstAvg = _avgDurationMs(
        _ascentDurations.sublist(0, kSquatFatigueWindowSize),
      );
      final lastAvg = _avgDurationMs(
        _ascentDurations.sublist(
          _ascentDurations.length - kSquatFatigueWindowSize,
        ),
      );
      final baseline = math.max(firstAvg, _historicalMedianMs());
      if (baseline > 0 && lastAvg / baseline > kSquatFatigueSlowdownRatio) {
        _fatigueFired = true;
      }
    }

    _lastRepQuality = _computeQualityScore(
      effectiveBottomAngle: effectiveBottomAngle,
    );
    _lastRepLeanDeg = _maxLeanDeg;
    _lastRepKneeShiftRatio = _maxKneeShiftRatio;
    _lastRepHeelLiftRatio = _maxHeelLiftRatio;
    // Snapshot the sustained-lean fraction BEFORE the counters drain below
    // so the host can emit it on the `squat.rep` telemetry line. Null when
    // the rep had no evaluable lean frames (no usable shoulder/hip pair).
    _lastRepLeanExceedFrac = _leanTotalEvalFrameCount > 0
        ? _leanExceedFrameCount / _leanTotalEvalFrameCount
        : null;
    // Snapshot the tombstoned-detector verdicts before per-rep counters
    // drain at `onDescendingStart`. The host reads the getters
    // (`lastRepHipsForwardOnDescentFired`, `lastRepKneeLedDescentFired`,
    // `lastRepTempoInconsistent`) on the `squat.rep` telemetry line. The
    // detectors still compute — only their FormError emission was retired
    // by the 2026-05-21 audit.
    _lastRepHipsForwardOnDescentFired = _hipsForwardOnDescentFired;
    _lastRepKneeLedDescentFired = _kneeLedDescentFired;
    _lastRepTempoInconsistentSnapshot = _lastRepTempoInconsistent;
    // Snapshot the backward-fire count before it drains (Bug-4 sign
    // diagnostic). `_lastRepSignedLeanAtPeak` needs no snapshot — it is
    // only assigned on a |lean| peak and reset at `onDescendingStart`, so
    // it already holds the just-committed rep's value here.
    _lastRepBackwardLeanFrameCount = _backwardLeanFrameCount;

    _minKneeAngle = null;
    _maxLeanDeg = null;
    _maxKneeShiftRatio = null;
    _maxHeelLiftRatio = null;
    _startKneeAngle = null;
    _leanExceedFrameCount = 0;
    _leanTotalEvalFrameCount = 0;
    // `_ascendingFrames` is cleared at the NEXT `onDescendingStart` so a
    // test that inspects mid-rep state can still read the buffer
    // post-commit. `_lastRepHipLead*` fields drain the same way.
    return errors;
  }

  static double _avgDurationMs(List<Duration> durations) {
    if (durations.isEmpty) return 0;
    final totalMs = durations.fold<int>(0, (sum, d) => sum + d.inMilliseconds);
    return totalMs / durations.length;
  }

  double _historicalMedianMs() {
    if (_historicalConcentricDurations.isEmpty) return 0.0;
    final sorted =
        _historicalConcentricDurations.map((d) => d.inMilliseconds).toList()
          ..sort();
    final n = sorted.length;
    if (n.isOdd) return sorted[n ~/ 2].toDouble();
    return (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2.0;
  }

  @override
  void reset() {
    _minKneeAngle = null;
    _maxLeanDeg = null;
    _maxKneeShiftRatio = null;
    _maxHeelLiftRatio = null;
    _lastRepQuality = null;
    _lastRepLeanDeg = null;
    _lastRepKneeShiftRatio = null;
    _lastRepHeelLiftRatio = null;
    _lastRepLeanExceedFrac = null;
    _ascendingPhaseActive = false;
    _ascendingFrames.clear();
    _lastRepHipLeadFired = false;
    _lastRepHipLeadRatio = null;
    _lastRepHipMeanVelocity = null;
    _lastRepShoulderMeanVelocity = null;
    _startKneeAngle = null;
    _descentStartHipX = null;
    _descentStartHeelX = null;
    _descentStartLegLen = null;
    _descentStartTime = null;
    _descentHipXSamples.clear();
    _hipsForwardOnDescentFired = false;
    _lastRepHipsForwardRatio = null;
    _currentSignedLeanDeg = null;
    _leanExceedFrameCount = 0;
    _leanTotalEvalFrameCount = 0;
    _backwardLeanFrameCount = 0;
    _lastRepBackwardLeanFrameCount = 0;
    _lastRepSignedLeanAtPeak = null;
    _descentStartKneeX = null;
    _descentStartHipY = null;
    _lastDescentKneeX = null;
    _lastDescentHipY = null;
    _kneeLedDescentFired = false;
    _kneeLedSampleCount = 0;
    _lastRepKneeLedRatio = null;
    // Tempo / fatigue state — cleared on reset, mirroring
    // CurlSideFormAnalyzer.reset(). Fresh analyzer per session, so this is
    // the session-boundary clear; the fatigue one-shot + tempo window do
    // NOT survive a reset (parity with curl).
    _descentStart = null;
    _ascentStart = null;
    _lastEccentricDuration = null;
    _lastConcentricDuration = null;
    _ascentDurations.clear();
    _tempoReArmRepsRemaining = 0;
    _lastRepTempoInconsistent = false;
    _fatigueFired = false;
  }

  // ── Internals ────────────────────────────────────────────

  /// Picks the camera-side (left or right) with higher average visibility
  /// across hip + knee + ankle landmarks. Returns null if neither side has
  /// the required landmarks above the confidence gate.
  ExerciseSide? _pickCameraSide(PoseResult p) {
    final leftAvg = _sideAvgVisibility(p, isLeft: true);
    final rightAvg = _sideAvgVisibility(p, isLeft: false);
    if (leftAvg == null && rightAvg == null) return null;
    if (leftAvg == null) return ExerciseSide.right;
    if (rightAvg == null) return ExerciseSide.left;
    return leftAvg >= rightAvg ? ExerciseSide.left : ExerciseSide.right;
  }

  double? _sideAvgVisibility(PoseResult p, {required bool isLeft}) {
    final hip = p.landmark(
      isLeft ? LM.leftHip : LM.rightHip,
      minConfidence: kMinLandmarkConfidence,
    );
    final knee = p.landmark(
      isLeft ? LM.leftKnee : LM.rightKnee,
      minConfidence: kMinLandmarkConfidence,
    );
    final ankle = p.landmark(
      isLeft ? LM.leftAnkle : LM.rightAnkle,
      minConfidence: kMinLandmarkConfidence,
    );
    if (hip == null || knee == null || ankle == null) return null;
    return (hip.confidence + knee.confidence + ankle.confidence) / 3.0;
  }

  /// Signed forward-lean angle (degrees). Positive = forward (hip ahead of
  /// shoulder along the user's toes direction); negative = backward.
  ///
  /// **Sign-normalized against the user's facing direction (2026-05-21).**
  /// The previous formula `dx = hip.x − shoulder.x` was direction-dependent:
  /// a left-facing user leaning forward produced a NEGATIVE `dx`, which
  /// suppressed `excessiveForwardLean` and false-fired `excessiveBackwardLean`.
  /// The "Bug-4" diagnostic block above documents the inversion symptom.
  ///
  /// Fix: anchor "forward" against the heel→hip X direction. The toes are
  /// (approximately) opposite the heel along the foot's long axis, so a hip
  /// drifting AWAY from the heel along that axis is leaning forward. We use
  /// `sign(hip.x − heel.x)` as the forward direction and multiply the raw
  /// `dx` by it — the result is positive for forward lean regardless of
  /// whether the camera sees the user from their left or right side.
  ///
  /// `atan2(dx, dy)` is used so the magnitude matches the trunk's tilt
  /// from vertical regardless of how far apart the two landmarks are
  /// (purely angular — independent of body size in pixels).
  double? _signedLeanDeg(PoseResult p, ExerciseSide side) {
    final shoulder = p.landmark(
      side == ExerciseSide.left ? LM.leftShoulder : LM.rightShoulder,
      minConfidence: kMinLandmarkConfidence,
    );
    final hip = p.landmark(
      side == ExerciseSide.left ? LM.leftHip : LM.rightHip,
      minConfidence: kMinLandmarkConfidence,
    );
    final heel = p.landmark(
      side == ExerciseSide.left ? LM.leftHeel : LM.rightHeel,
      minConfidence: kMinLandmarkConfidence,
    );
    if (shoulder == null || hip == null || heel == null) return null;
    final dy = (hip.y - shoulder.y).abs();
    if (dy < 1e-6) return null;
    // Forward direction: the X axis pointing from heel toward hip projection.
    // Returns null sign when hip stacks exactly over heel (degenerate frame,
    // typically a fully upright standing pose where lean is ~0 anyway).
    final hipHeelOffset = hip.x - heel.x;
    if (hipHeelOffset.abs() < 1e-6) return 0.0;
    final forwardSign = hipHeelOffset >= 0 ? 1.0 : -1.0;
    final dx = (hip.x - shoulder.x) * forwardSign;
    return math.atan2(dx, dy) * 180.0 / math.pi;
  }

  /// Knee shift ratio: how far the knee is displaced horizontally from the
  /// ankle, normalized by femur length.
  ///
  /// **Direction-agnostic (2026-05-21).** The previous formula
  /// `max(0, knee.x − ankle.x)` clamped to zero for left-facing users (whose
  /// knee tracks toward lower x as it travels forward), making the entire
  /// `forwardKneeShift` and `kneeDominantPattern` codepath dead for half the
  /// user population. The new formula uses `.abs()` — the fault is "knee
  /// displaced from ankle by a lot," regardless of which side of the ankle
  /// it sits on. In a real side-view squat the knee virtually never sits
  /// BEHIND the ankle, so the abs is equivalent to the original intent for
  /// right-facing users while also working for left-facing users.
  double? _kneeShiftRatio(PoseResult p, ExerciseSide side) {
    final hip = p.landmark(
      side == ExerciseSide.left ? LM.leftHip : LM.rightHip,
      minConfidence: kMinLandmarkConfidence,
    );
    final knee = p.landmark(
      side == ExerciseSide.left ? LM.leftKnee : LM.rightKnee,
      minConfidence: kMinLandmarkConfidence,
    );
    final ankle = p.landmark(
      side == ExerciseSide.left ? LM.leftAnkle : LM.rightAnkle,
      minConfidence: kMinLandmarkConfidence,
    );
    if (hip == null || knee == null || ankle == null) return null;
    final femurLen = _euclidean(hip, knee);
    if (femurLen < 1e-6) return null;
    final shift = (knee.x - ankle.x).abs();
    return shift / femurLen;
  }

  /// Heel lift ratio. Positive when the heel rises above the forefoot
  /// (ankle stays grounded but `foot_index` drops below `heel`).
  ///
  /// In screen coordinates Y=0 is top, so a heel rising means `heel.y`
  /// becomes smaller (more negative offset) than `foot_index.y`. We
  /// measure `(foot_index.y - heel.y)` and clamp at 0; non-zero means
  /// the heel is above the forefoot in screen space.
  double? _heelLiftRatio(PoseResult p, ExerciseSide side) {
    final hip = p.landmark(
      side == ExerciseSide.left ? LM.leftHip : LM.rightHip,
      minConfidence: kMinLandmarkConfidence,
    );
    final ankle = p.landmark(
      side == ExerciseSide.left ? LM.leftAnkle : LM.rightAnkle,
      minConfidence: kMinLandmarkConfidence,
    );
    final heel = p.landmark(
      side == ExerciseSide.left ? LM.leftHeel : LM.rightHeel,
      minConfidence: kMinLandmarkConfidence,
    );
    final foot = p.landmark(
      side == ExerciseSide.left ? LM.leftFootIndex : LM.rightFootIndex,
      minConfidence: kMinLandmarkConfidence,
    );
    if (hip == null || ankle == null || heel == null || foot == null) {
      return null;
    }
    // Leg length = hip → ankle (sagittal-plane proxy, robust to camera
    // distance). 1e-6 guard against degenerate poses.
    final legLen = _euclidean(hip, ankle);
    if (legLen < 1e-6) return null;
    final lift = math.max(0.0, foot.y - heel.y);
    return lift / legLen;
  }

  double _euclidean(PoseLandmark a, PoseLandmark b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Per-rep quality score (0.0–1.0). Multiplicative composition of:
  ///   - Depth factor (1.0 if reached effective bottom; tapers linearly).
  ///   - Lean penalty (proportional, capped at `kQualitySquatLeanMaxDeduction`).
  ///   - Heel-lift penalty (proportional, capped at `kQualitySquatHeelLiftMaxDeduction`).
  ///
  /// Knee-shift is excluded by design (informational only). Backward lean
  /// is excluded because `_maxLeanDeg` is only updated for positive lean.
  double _computeQualityScore({required double effectiveBottomAngle}) {
    var score = 1.0;

    // Depth factor — multiplicative. Gives full credit when minAngle <=
    // effectiveBottom; otherwise interpolates linearly so a half-rep gets
    // ~0.5 weight.
    final minAngle = _minKneeAngle ?? 180.0;
    final double depthFactor;
    if (minAngle <= effectiveBottomAngle) {
      depthFactor = 1.0;
    } else {
      final span = 180.0 - effectiveBottomAngle;
      if (span <= 1e-6) {
        depthFactor = 1.0;
      } else {
        final progress = ((180.0 - minAngle) / span).clamp(0.0, 1.0);
        depthFactor = 0.5 + 0.5 * progress;
      }
    }
    score *= depthFactor;

    // Lean — proportional. Severity 1.0 reached at lean = warn + 30°.
    final maxLean = _maxLeanDeg;
    if (maxLean != null && maxLean > _leanWarnDeg) {
      final severity = ((maxLean - _leanWarnDeg) / 30.0).clamp(0.0, 1.0);
      score *= 1.0 - severity * kQualitySquatLeanMaxDeduction;
    }

    // Heel lift — proportional. Severity 1.0 reached at ratio 0.05
    // (~67% above the warning floor).
    final maxHeel = _maxHeelLiftRatio;
    if (maxHeel != null && maxHeel > _formThresholds.heelLiftWarnRatio) {
      final severity = (maxHeel / 0.05).clamp(0.0, 1.0);
      score *= 1.0 - severity * kQualitySquatHeelLiftMaxDeduction;
    }

    // Hip-lead — proportional. Applied AFTER lean and heel-lift per plan
    // ordering (multiplicative composition, so the order doesn't change
    // the numerical outcome — but documents the design intent). Severity
    // 1.0 reached at ratio = warn + 0.6 (i.e. 2.0); ratio at threshold
    // (1.4) yields zero deduction so a borderline-fail rep doesn't
    // double-count between the cue and the quality score.
    final hipLeadRatio = _lastRepHipLeadRatio;
    if (hipLeadRatio != null && hipLeadRatio > kHipLeadVelocityRatio) {
      final severity = ((hipLeadRatio - kHipLeadVelocityRatio) / 0.6).clamp(
        0.0,
        1.0,
      );
      score *= 1.0 - severity * kQualitySquatHipLeadMaxDeduction;
    }

    return score.clamp(0.0, 1.0);
  }
}
