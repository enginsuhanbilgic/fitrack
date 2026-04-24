/// All magic numbers live here — nothing hard-coded in logic files.
library;

// ── Confidence ──────────────────────────────────────────
/// Minimum landmark confidence to use a frame for rep counting / feedback.
const double kMinLandmarkConfidence = 0.4;

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
const bool kUseDataDrivenThresholds = true;

// ── Form feedback thresholds ────────────────────────────
/// Torso swing: ΔX_shoulder / L_torso.
const double kSwingThreshold = 0.25;

/// Elbow drift: ΔX_elbow / L_torso.
const double kDriftThreshold = 0.20;

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
/// Max trunk-tibia deviation before flagging "chest up" cue (degrees).
const double kTrunkTibiaDeviation = 15.0;

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
