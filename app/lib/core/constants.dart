/// All magic numbers live here — nothing hard-coded in logic files.
library;

// ── Confidence ──────────────────────────────────────────
/// Minimum landmark confidence to use a frame for rep counting / feedback.
const double kMinLandmarkConfidence = 0.4;

/// Minimum confidence for the pose-presence gate at the ML Kit boundary —
/// "did the model emit a position at this landmark at all?" Strictly more
/// permissive than [kMinLandmarkConfidence] (which is the *measurement*
/// gate inside the engine). Two layers, two concerns: this gate filters
/// out frames where the model didn't even attempt a landmark; the engine
/// gate then filters frames where the position is too uncertain to
/// measure. 0.3 sits below the engine gate so we never reject a frame
/// the engine would have accepted.
const double kPoseGateMinConfidence = 0.3;

/// Relaxed gate threshold for side-view exercises. ML Kit operates in a
/// degraded mode when only one side of the body is visible — the
/// off-camera arm is fully occluded so the model can't cross-anchor
/// landmarks against each other, and on-camera landmark confidences drop
/// across the board. 0.3 (the front-view threshold) rejects too many
/// legitimate side-view frames; 0.15 admits the noisy reality of
/// partial-body inputs without polluting the FSM with garbage (the
/// `kMinLandmarkConfidence = 0.4` measurement gate inside the engine
/// remains in place to catch frames whose landmarks made it through but
/// aren't usable).
const double kPoseGateMinConfidenceSideRelaxed = 0.15;

// ── Joint-angle sanity clamps ───────────────────────────
/// Minimum length of each of the two segments forming a joint angle, in
/// normalized image coordinates (ML Kit returns landmarks in [0, 1]).
/// Below this, the triangle is degenerate — typically because one landmark
/// snapped onto another (occlusion, low confidence, or pose-estimation
/// failure at peak flexion). 0.02 ≈ 2% of frame width / height — safely
/// above pose-noise floor (~0.005) and well below any real human limb.
const double kMinJointSegmentLength = 0.02;

/// Maximum allowed ratio between the two segments of a joint-angle
/// triangle. When `max(BA, BC) / min(BA, BC) > this`, the triangle is
/// pathologically lopsided — likely a landmark snap. A real elbow at peak
/// flexion gives ratios up to ~2.5 (forearm vs. upper arm). 5.0 is well
/// above that and below the ratios produced by snapped landmarks
/// (typically 10× or more).
const double kMaxJointSegmentRatio = 5.0;

// ── Biomechanical Logic (Index-1) ───────────────────────
/// Mandatory lockout after state transition to prevent double-counting.
const Duration kStateDebounce = Duration(milliseconds: 500);

/// Reset to IDLE if stuck in active state for this long (Zombie user).
const Duration kStuckStateLimit = Duration(seconds: 5);

/// Minimum confidence for far-side limbs; if lower, use near-side as proxy.
const double kFarSideConfidenceGate = 0.4;

// ── Biceps Curl FSM thresholds (degrees) ────────────────
/// IDLE → CONCENTRIC when elbow angle drops below this.
const double kCurlStartAngle = 160.0;

/// CONCENTRIC → PEAK when elbow angle reaches this.
const double kCurlPeakAngle = 70.0;

/// PEAK → ECCENTRIC when elbow angle exceeds peak + hysteresis.
const double kCurlPeakExitAngle = 85.0;

/// ECCENTRIC → IDLE when elbow angle reaches this → rep++.
const double kCurlEndAngle = 140.0;

// ── Threshold source toggle (developer) ─────────────────
/// Developer toggle: when `true`, `RomThresholds.global(view)` returns the
/// T2.4-derived per-view thresholds from `DefaultRomThresholds.forView()`;
/// when `false`, it returns the hand-tuned legacy constants above
/// (`kCurlStartAngle`, `kCurlPeakAngle`, `kCurlPeakExitAngle`, `kCurlEndAngle`).
///
/// Default: `false` — preserves the shipping-2026-04 behavior so the T2.4 v2
/// wiring is a zero-behavior-change landing. Flip to `true` to ship the
/// data-driven defaults once validated on-device.
///
/// Only affects users without a `CurlRomProfile` or auto-calibration data —
/// i.e. the cold-start `ThresholdSource.global` fallback. Personal Calibration
/// and Auto-Calibration paths are unchanged.
///
/// See `T2.4_STATE.md §11.4` for the derived threshold values.
const bool kUseDataDrivenThresholds = false;

/// When true, `RomThresholds.global(view)` consults
/// [ManualRomOverrides.forView] before either the data-driven or legacy
/// path. Views with a null override entry fall through to the next tier.
///
/// Three-tier precedence:
///   1. Manual override (`manual_rom_overrides.dart`) — this flag
///   2. Data-driven generated defaults (`default_rom_thresholds.dart`) —
///      gated by [kUseDataDrivenThresholds]
///   3. Legacy constants (`kCurlStartAngle` etc.) — always available
///
/// Default `true` so the diagnostic-derived front-view numbers ship.
/// Flip to `false` to A/B test against the lower tiers without losing
/// the manual values.
const bool kUseManualOverrides = true;

// ── Form feedback thresholds ────────────────────────────
/// Torso swing: ΔX_shoulder / L_torso.
const double kSwingThreshold = 0.25;

/// Forward trunk lean: change in torso-to-vertical angle (degrees) relative to
/// rep-start baseline. Only evaluated in side views (sideLeft / sideRight) where
/// the sagittal-plane projection is faithful. Reduced from 15° (2026-04-28) —
/// field testing showed 15° was too permissive; 8° catches momentum-driven
/// body swing while ignoring minor postural wobble (≤3–4°).
const double kTorsoLeanThresholdDeg = 8.0;

/// Backward trunk lean threshold (degrees). Typically smaller than forward
/// lean as hyperextension is more dangerous and clearly indicates cheat.
/// Reduced from 10° (2026-04-28) alongside forward lean tightening.
const double kBackLeanThresholdDeg = 6.0;

/// Shoulder shrug: vertical (Y-axis) shoulder displacement / L_torso.
/// A positive shrug (shoulder moving UP) > this fires `shoulderShrug`.
///
/// Tuned from `kShrugThreshold = 0.12` (2026-04-27) — natural scapular
/// elevation during peak elbow flexion (3–4 cm on a ~50 cm torso ≈
/// 0.06–0.08) was firing the cue on clean reps. 0.16 leaves ~2×
/// headroom over normal scapular activity while still catching real
/// "shoulders to ears" shrugs (8–12 cm ≈ 0.16–0.24). Will be re-derived
/// from the 95th percentile of clean reps once diagnostic-mode telemetry
/// produces a real distribution; this is a first-principles guard, not
/// a final number.
const double kShrugThreshold = 0.16;

/// Elbow drift: ΔX_elbow / L_torso.
const double kDriftThreshold = 0.20;

/// Elbow rise: (elbow_y − shoulder_y) relative upward shift / L_torso.
/// Fires when the upper arm swings forward and the elbow lifts away from
/// the torso during the curl (side view only). Positive = elbow moving up.
///
/// Tuned from `kElbowRiseThreshold = 0.12` (2026-04-27) — at peak
/// flexion the upper arm naturally tilts forward 5–10° even with strict
/// form, translating to ~0.08–0.12 elbow rise on a typical torso. The
/// old threshold sat right at the upper bound of natural form,
/// producing constant warnings on textbook reps. 0.18 keeps real
/// front-delt cheats (typical 0.24–0.36) flagged while permitting the
/// natural arc. Same retune-from-real-data caveat as `kShrugThreshold`.
const double kElbowRiseThreshold = 0.18;

// ── Sagittal sway (front view depth swing) ──────────────
// Composite scale-invariant features over a 1€-filtered, baseline z-scored
// signal classified by per-second velocity with N-frame hysteresis. See
// `SagittalSwayDetector` for the full rationale and feature definitions.

/// Feature weights for the composite z-scored sway signal
///   z₁ → shoulder/hip width ratio (primary depth proxy: 1/Z scaling).
///   z₂ → torso area normalized by hip width² (corroborates movement).
///   z₃ → torso length over shoulder width (catches hip-thrust/compression).
const double kSagittalWeightShoulderHipRatio = 0.65;
const double kSagittalWeightTorsoArea = 0.30;
const double kSagittalWeightTorsoLengthRatio = 0.05;

/// Velocity threshold on the z-scored composite, in **standard-deviations
/// per second** (signal is z-scored, time is real seconds via frame timestamps).
/// Above +threshold = forward sway; below −threshold = backward sway.
const double kSagittalVelocityThreshold = 1.1;

/// Consecutive frames with `|v(t)| > threshold` required before the detector
/// declares a sway event. Suppresses single-frame jitter and brief
/// landmark-confidence dips that snuck past the visibility gate.
const int kSagittalHysteresisFrames = 2;

/// Number of FRAMES of neutral-pose samples the detector needs before it
/// will start emitting sway decisions. The detector only ingests samples
/// while the FSM is in IDLE or near full extension, so this is "frames
/// observed in baseline-eligible state," not wall-clock time.
const int kSagittalBaselineMinFrames = 30;

/// Hard cap on σ adaptation: after the initial baseline window, the running
/// σ is clamped at `cap × baselineSigma` to prevent fatigue-induced drift
/// from gradually swallowing real form breakdown into the "neutral" range.
const double kSagittalSigmaDriftCap = 1.5;

/// Minimum landmark `inFrameLikelihood` for the detector to ingest a frame.
/// Below this on any of the four torso landmarks (L/R shoulder, L/R hip)
/// the detector pauses sampling rather than poisoning the EMA / baseline
/// with degenerate values.
const double kSagittalMinLandmarkVisibility = 0.5;

/// Reject a frame's velocity computation when the sample-to-sample dt
/// jumps to more than this multiple of the recent median dt — guards
/// against ML Kit thermal-throttling skips that would otherwise spike v(t).
const double kSagittalDtAnomalyFactor = 2.0;

// ── Head stability corroboration (depth-swing veto) ─────
// The head sits above the arm-over-torso occlusion zone, so its motion
// is a clean witness for whether the spine actually moved. When the
// SagittalSwayDetector fires but the head is stationary, the warning
// is suppressed as occlusion artifact. See `HeadStabilityCorroborator`.

/// Minimum |z-score| of the weighted head-motion signal required to
/// corroborate a sway detection. Below this, the warning is vetoed
/// because the head did not move with the spine — a strong signal
/// that the shoulder/hip drift was an arm-over-torso artifact.
const double kHeadCorroborationMinZ = 0.6;

/// Min `inFrameLikelihood` for nose + both ears to participate.
/// Below this on any required head landmark, the corroborator returns
/// "landmarks unavailable" and the analyzer fails open (does NOT veto)
/// — the bar is "never make detection worse than baseline."
const double kHeadCorroborationMinVisibility = 0.6;

/// Frames of neutral-pose samples needed before the corroborator emits
/// a verdict. Mirrors `kSagittalBaselineMinFrames` so both detectors
/// are armed at roughly the same wall-clock moment.
const int kHeadBaselineMinFrames = 30;

/// Weights for the composite head signal:
///   weight_y * |nose.y z| + weight_s * |inter-ear distance z|
/// Vertical motion is a more direct sagittal proxy in 2D than ear
/// distance (which conflates lean with head turn), so it dominates.
const double kHeadVerticalWeight = 0.7;
const double kHeadScaleWeight = 0.3;

/// Hard cap on σ adaptation for head signals — prevents long-set
/// postural drift from swallowing real head motion. Slightly looser
/// than `kSagittalSigmaDriftCap` because the head bobs naturally
/// during breathing/effort.
const double kHeadSigmaDriftCap = 2.0;

// ── Timing ──────────────────────────────────────────────
/// Minimum seconds between two audio cues of the same type.
const double kFeedbackCooldownSec = 3.0;

// ── 1€ Filter defaults ──────────────────────────────────
/// Paper defaults (Casiez et al., CHI 2012). Kept as the base for any
/// consumer that wants the reference behavior (e.g. a future engine-side
/// smoother where low lag matters more than low jitter).
const double kOneEuroMinCutoff = 1.0;
const double kOneEuroBeta = 0.007;
const double kOneEuroDCutoff = 1.0;

// ── 1€ Filter — display-tuned (skeleton overlay) ────────
/// Aggressive smoothing for the skeleton rendered on top of the camera
/// preview. Only the display pipeline uses these; the FSM consumes raw
/// landmarks from ML Kit, so tuning here cannot regress rep detection.
///
/// `minCutoff = 0.4` cuts stationary jitter roughly in half vs. the paper
/// default. `beta = 0.015` is raised slightly to preserve responsiveness
/// during fast lifting phases (adaptive cutoff opens up when the user
/// moves quickly).
const double kOneEuroDisplayMinCutoff = 0.4;
const double kOneEuroDisplayBeta = 0.015;
const double kOneEuroDisplayDCutoff = 1.0;

// ── Camera ──────────────────────────────────────────────
const int kCameraFps = 30;

/// Target inference rate during the ACTIVE phase (ms between processed frames).
/// 15 FPS is sufficient — the FSM's 500 ms debounce already filters sub-500 ms
/// state flips, and biceps curl movements are slow relative to this interval.
const int kActiveFrameIntervalMs = 66; // ~15 FPS

/// Target inference rate during non-critical phases (setupCheck, countdown).
/// 8 FPS is enough to confirm position and run view detection consensus.
const int kIdleFrameIntervalMs = 125; // ~8 FPS

/// Calibration uses the same rate as active — rep boundary detection needs
/// enough temporal resolution to catch direction flips accurately.
const int kCalibrationFrameIntervalMs = 66; // ~15 FPS

// ── Setup Check ─────────────────────────────────────────
/// Number of consecutive frames all required landmarks must pass the confidence
/// gate before transitioning from SETUP_CHECK to COUNTDOWN.
const int kSetupCheckFrames = 10;

/// Stricter landmark confidence required during SETUP_CHECK for curl exercises.
/// Higher than [kMinLandmarkConfidence] (0.4) to reject bystanders whose
/// landmarks are partially visible at the edges of frame. A person standing
/// at arm's length facing the camera passes easily; someone walking past in
/// the background does not.
const double kSetupCurlMinConfidence = 0.65;

/// Elbow angle range that counts as a "resting arm" for the curl setup posture
/// check. Arms hanging naturally sit at ~160°–180°. A bystander mid-walk,
/// reaching, or gesturing will typically be outside this window.
const double kSetupRestingArmMinDeg = 130.0;
const double kSetupRestingArmMaxDeg = 185.0;

// ── Squat FSM thresholds (degrees) ──────────────────────
/// IDLE → DESCENDING when knee angle drops below this.
const double kSquatStartAngle = 160.0;

/// DESCENDING → BOTTOM when knee angle drops below this.
const double kSquatBottomAngle = 90.0;

/// ASCENDING → IDLE when knee angle returns above this → rep++.
const double kSquatEndAngle = 160.0;

// ── Push-up FSM thresholds (degrees) ────────────────────
/// IDLE → DESCENDING when elbow angle drops below this.
const double kPushUpStartAngle = 160.0;

/// DESCENDING → BOTTOM when elbow angle drops below this.
const double kPushUpBottomAngle = 90.0;

/// ASCENDING → IDLE when elbow angle returns above this → rep++.
const double kPushUpEndAngle = 160.0;

// ── Squat form thresholds ────────────────────────────────
/// (DEPRECATED 2026-04-25, Squat Master Rebuild) Max trunk-tibia deviation
/// before flagging the "chest up" cue. Retained as a constant — never read
/// by new code — only to keep historic references compiling.
const double kTrunkTibiaDeviation = 15.0;

// ── Squat form thresholds (Squat Master Rebuild, 2026-04-25) ─────
/// Lean threshold for bodyweight squat. Trunk-from-vertical > this fires
/// `excessiveForwardLean`. Literature: Straub & Powers 2024 IJSPT (40°)
/// + 5° measurement-noise margin for 2D RMSE (Heliyon 2024).
const double kSquatLeanWarnDegBodyweight = 45.0;

/// Lean threshold for high-bar back squat. Glassbrook 2017 + 5° margin.
const double kSquatLeanWarnDegHBBS = 50.0;

/// Long-femur lifter boost — added to active lean threshold when the
/// "Tall lifter" Settings toggle is on. Orthogonal to the auto long-femur
/// detection (which relaxes the BOTTOM angle, not the lean threshold).
const double kSquatLongFemurLeanBoost = 5.0;

/// Forward knee shift threshold — `(knee_x − ankle_x) / femur_len_px`.
/// (empirical-TBD): research docs disagreed 3× (Claude 0.30, Google 0.10).
/// Informational metric only — no TTS, no quality penalty in v1.
const double kSquatKneeShiftWarnRatio = 0.30;

/// Heel lift threshold — `(foot_index_y − heel_y) / leg_len_px`.
/// (empirical-TBD): engineering estimate; Macrum 2012 supports 2–3% of
/// leg length.
const double kSquatHeelLiftWarnRatio = 0.03;

// ── Squat per-rep quality scoring (multiplicative, mirrors curl) ─
/// Maximum quality deduction for excessive forward lean. Applied
/// proportionally to severity — see `SquatFormAnalyzer._computeQualityScore`.
const double kQualitySquatLeanMaxDeduction = 0.20;

/// Maximum quality deduction for heel lift. Applied proportionally.
const double kQualitySquatHeelLiftMaxDeduction = 0.10;
// `forwardKneeShift` is intentionally excluded — informational only.
// `squatDepth` is handled via the depth_factor multiplier, not a subtraction.

// ── Push-up form thresholds ──────────────────────────────
/// Max shoulder-hip-ankle collinearity deviation for hip sag (degrees).
const double kHipSagDeviation = 15.0;

// ── Visual feedback ──────────────────────────────────────
/// Duration in ms to highlight offending landmarks after a form error.
const int kHighlightDurationMs = 1500;

// ── Mid-session occlusion ────────────────────────────────
/// Seconds of partial occlusion before showing adjustment prompt.
const double kOcclusionPromptSec = 1.5;

/// Consecutive good frames required to auto-resume after occlusion.
const int kOcclusionResumeFrames = 5;

// ── Long-femur squat adaptation ──────────────────────────
/// Fallback BOTTOM angle for users whose anatomy prevents reaching 90°.
const double kLongFemurBottomAngle = 100.0;

/// Number of completed reps used to detect long-femur pattern.
const int kLongFemurDetectReps = 3;

// ── Countdown & Session ──────────────────────────────────
/// Starting value for the hands-free countdown (counts down to 1 then fires GO).
const int kCountdownSeconds = 3;

/// Seconds of continuous landmark absence in ACTIVE phase before auto-termination.
const double kAbsenceTimeoutSec = 3.0;

// ── Curl Tempo Tracking ──────────────────────────────────
/// Minimum eccentric duration in seconds — below this fires eccentricTooFast.
const double kMinEccentricSec = 0.8;

/// Minimum concentric (lifting) duration in seconds — below this fires concentricTooFast.
/// Asymmetric with eccentric (0.8 s) because the lift is meant to be explosive but
/// controlled; below ~0.3 s the user is flinging the weight with momentum, not muscle.
const double kMinConcentricSec = 0.3;

/// Concentric-tempo consistency threshold: if `(max − min) / mean` of the last N
/// concentric durations exceeds this ratio, fires `tempoInconsistent`. 0.30 is
/// permissive enough to tolerate natural rep-to-rep variation but catches the
/// "two controlled reps then a flung rep" pattern that signals fatigue onset.
const double kTempoInconsistencyRatio = 0.30;

/// Sliding-window size for tempo consistency evaluation. 3 reps is the minimum
/// that can produce a meaningful variance ratio while still reacting quickly.
const int kTempoConsistencyWindow = 3;

/// After firing `tempoInconsistent`, suppress re-emission for this many reps.
/// Unlike fatigue (permanent one-shot), tempo drift is recoverable mid-session —
/// the user can correct and we want to flag it again if they slip back.
const int kTempoConsistencyReArmReps = 5;

// ── Curl Bilateral Asymmetry ─────────────────────────────
/// Peak angle delta (degrees) between left and right arm to flag asymmetry.
const double kAsymmetryAngleDelta = 15.0;

/// Consecutive asymmetric reps required before firing asymmetryLeftLag /
/// asymmetryRightLag (directional; the lagging side is decided by the sign of
/// `left − right` at the emitting rep, while this streak gate uses `|delta|`).
const int kAsymmetryConsecutiveReps = 3;

// ── Curl Fatigue Detection ───────────────────────────────
/// Minimum reps before fatigue comparison is possible (first N vs last N).
const int kFatigueMinReps = 6;

/// Number of reps to average at start and end for comparison.
const int kFatigueWindowSize = 3;

/// Ratio threshold: if lastAvg / firstAvg > this, user is fatiguing.
const double kFatigueSlowdownRatio = 1.4;

// ── Curl Per-Rep Quality Score ───────────────────────────
/// Maximum deduction for torso swing (proportional to magnitude).
const double kQualitySwingMaxDeduction = 0.25;

/// Maximum deduction for elbow drift (proportional to magnitude).
const double kQualityDriftMaxDeduction = 0.20;

/// Maximum deduction for shoulder shrug.
const double kQualityShrugMaxDeduction = 0.15;

/// Maximum deduction for backward lean (back hyperextension).
const double kQualityBackLeanMaxDeduction = 0.20;

/// Maximum deduction for elbow rise (upper arm swinging forward/up).
const double kQualityElbowRiseMaxDeduction = 0.15;

/// Deduction for rushed eccentric.
const double kQualityEccentricDeduction = 0.15;

/// Deduction for rushed concentric (lift).
const double kQualityConcentricDeduction = 0.10;

/// Deduction for inconsistent concentric tempo across the sliding window.
const double kQualityTempoInconsistencyDeduction = 0.10;

/// Deduction for short ROM (applied to both `shortRomStart` and `shortRomPeak`).
const double kQualityShortRomDeduction = 0.30;

/// Tolerance for start/peak short-ROM classification. Smaller than the
/// profile's `kProfilePeakTolerance` (15°) — we only flag clear shortfalls,
/// not borderline-OK reps. 5° sits above the ~2–3° pose-estimation noise
/// floor and well below a meaningful ROM restriction.
///
/// Applied asymmetrically against the FSM's active `RomThresholds`:
/// - `shortRomStart` fires when `maxAngleAtStart < startAngle − kShortRomTolerance`
/// - `shortRomPeak` fires when `minAngleReached > peakAngle + kShortRomTolerance`
const double kShortRomTolerance = 5.0;

/// Deduction for bilateral asymmetry.
const double kQualityAsymmetryDeduction = 0.10;

// ── Curl Active-Phase View Re-Detection ──────────────────
/// Consecutive frames that must agree on a NEW view before switching mid-session.
/// At 30 fps this is ~0.33 s — stable enough to ignore brief wobbles.
const int kViewRedetectHysteresisFrames = 10;

// ── Curl Camera-View Detection ───────────────────────────
/// Shoulder separation ratio below this → likely side view.
const double kSideViewShoulderSepThreshold = 0.10;

/// Shoulder separation ratio above this → likely front view.
const double kFrontViewShoulderSepThreshold = 0.15;

/// Post-lock hysteresis band. Once a view is locked, flipping to the other
/// view requires crossing the **opposite** threshold by this delta. Sits above
/// the ~0.02 frame-to-frame noise floor at the front/side boundary and below
/// the existing 0.05 gap between side/front thresholds. Applies **only** to
/// continuous re-detection — initial consensus lock is unchanged.
const double kViewHysteresisDelta = 0.03;

/// Confidence asymmetry above this → corroborates side view.
const double kViewShoulderConfidenceDeltaThreshold = 0.20;

/// Nose offset from shoulder midpoint above this → corroborates side view.
const double kViewNoseOffsetThreshold = 0.10;

/// Frames to accumulate before attempting to lock the view.
const int kViewDetectionFrames = 15;

/// Frames that must agree on the same view to lock it.
const int kViewDetectionConsensusFrames = 10;

// ── Per-User ROM Profile (Biceps Curl) ───────────────────
/// Tolerance below the bucket's observed peak before the FSM accepts a peak.
const double kProfilePeakTolerance = 15.0;

/// Tolerance below the bucket's observed rest before the FSM enters CONCENTRIC.
const double kProfileStartTolerance = 10.0;

/// Tolerance applied to ECCENTRIC → IDLE transition (rep++).
const double kProfileEndTolerance = 25.0;

/// Hysteresis gap between peakAngle and peakExitAngle (peakExit = peak + this).
const double kCurlPeakExitGap = 15.0;

/// EMA alpha when the new sample EXTENDS the bucket (deeper peak / fuller rest).
const double kProfileExpandAlpha = 0.4;

/// EMA alpha when the new sample SHRINKS the bucket (after confirmation).
const double kProfileShrinkAlpha = 0.1;

/// Consecutive shorter-than-bucket reps required to confirm a real ROM regression.
/// Set to 3 to avoid encoding a single fatigue rep as the new normal.
const int kProfileShrinkConfirmReps = 3;

/// Window size for median + MAD outlier rejection.
const int kProfileOutlierWindow = 8;

/// MAD multiplier — samples beyond this many MADs from the median are rejected.
const double kProfileMadThreshold = 2.5;

/// First N reps of every set use loosened thresholds (× kProfileWarmupMultiplier).
const int kProfileWarmupReps = 2;

/// Multiplier applied to all tolerances during warmup reps.
const double kProfileWarmupMultiplier = 1.5;

/// Floor on usable ROM excursion (deg). Below this, calibration / auto-cal are rejected.
const double kMinViableRomDegrees = 25.0;

// ── Calibration ──────────────────────────────────────────
/// Minimum reps required to consider a calibration successful and persistable.
const int kCalibrationMinReps = 3;

/// Hard upper bound on a calibration session before timing out (seconds).
const int kCalibrationTimeoutSec = 60;

/// Minimum frame pass-rate (landmarks above confidence) to validate calibration.
const double kCalibrationFramePassRate = 0.80;

/// Minimum angle excursion (deg) for the rep boundary detector to accept a rep.
const double kCalibrationMinExcursion = 40.0;

/// Minimum frames the rep boundary detector must remain in the descending
/// phase before the `descending → ascending` flip is allowed to commit a rep.
/// Prevents phantom reps during long rest pauses at the bottom, where pose
/// noise can cause direction flip-flops. 8 frames @ 30 fps ≈ 267 ms — below
/// perceived latency, well above per-frame noise.
const int kRepBoundaryMinDwellFrames = 8;

// ── Telemetry ────────────────────────────────────────────
/// Cap on the in-memory telemetry ring buffer (oldest entries dropped).
const int kTelemetryRingSize = 500;

// ── Feature flags ────────────────────────────────────────
/// Front-view biceps curl is temporarily hidden from the user-facing UI
/// while side-view accuracy is the active focus. Engine code paths
/// (`CurlFormAnalyzer`, `CurlViewDetector` front branch, front ROM
/// buckets) remain intact — this flag only gates surfaces the user
/// sees: the curl view picker, calibration progress matrix, settings
/// ROM-override rows, calibration overlay live label, and summary view
/// label. Flip back to `true` to restore.
const bool kCurlFrontViewEnabled = false;

/// Exposes the "Curl Debug Session" entry on the home screen and the
/// matching toggle in Settings. When `true`, the user can launch a
/// silent observation session that:
///   - records every committed rep's `rep.extremes` / `rep.side_metrics`
///     / `rep.arm_resolved` lines (same format as a normal session,
///     `source=global` enforced),
///   - emits a periodic `pose.frame_metrics` line at
///     [kDebugFrameMetricsHz] so per-frame angle / confidence
///     distributions are visible even when no rep commits (the path
///     we kept hitting when landmarks were marginal),
///   - suppresses all user-facing feedback (TTS, haptics, banners) so
///     the user can pose without the app reacting,
///   - bypasses the regular summary screen in favor of a minimal
///     "session ended" view with a copy-log shortcut.
/// Flip to `false` for production builds — the flag is read at compile
/// time so unreachable code is tree-shaken.
const bool kCurlDebugSessionEnabled = true;

/// Frame-metrics emission rate during a curl debug session. 2 Hz =
/// one `pose.frame_metrics` line every ~500 ms. Low enough that a
/// 60-second session produces ~120 lines (well under the boosted
/// [kDebugRingBufferSize]); high enough to capture the rise-and-fall
/// shape of an elbow angle through a curl. Increase if you need finer
/// granularity (e.g. for tempo analysis); decrease if the buffer is
/// filling too fast.
const double kDebugFrameMetricsHz = 2.0;

/// Ring-buffer size in effect during a debug session — reverts to
/// [kTelemetryRingSize] when the session ends. Larger because debug
/// sessions emit ~5× more entries per minute than normal sessions
/// (frame metrics + arm-resolved + side-metrics + extremes per rep).
const int kDebugRingBufferSize = 2000;

/// Compile-time gate for squat debug sessions. Ships false.
/// Set true only on dev builds when collecting squat threshold telemetry.
const bool kSquatDebugSessionEnabled = false;

/// Ring-buffer size for squat debug sessions.
/// Overrides [kTelemetryRingSize] for the session lifetime; resetCap() restores it.
const int kSquatDebugRingBufferSize = 2000;

/// Target frequency (Hz) for squat frame-metric telemetry.
/// 3 Hz (vs curl's 2 Hz) — squat reps are slower so slightly higher density is useful.
const double kSquatDebugFrameMetricsHz = 3.0;
