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
const double kCurlStartAngle = 150.0;

/// CONCENTRIC → PEAK when elbow angle reaches this.
const double kCurlPeakAngle = 40.0;

/// PEAK → ECCENTRIC when elbow angle exceeds peak + hysteresis.
const double kCurlPeakExitAngle = 50.0;

/// ECCENTRIC → IDLE when elbow angle reaches this → rep++.
const double kCurlEndAngle = 160.0;

// ── Form feedback thresholds ────────────────────────────
/// Torso swing: ΔX_shoulder / L_torso.
const double kSwingThreshold = 0.15;

/// Elbow drift: ΔX_elbow / L_torso.
const double kDriftThreshold = 0.10;

// ── Timing ──────────────────────────────────────────────
/// Minimum seconds between two audio cues of the same type.
const double kFeedbackCooldownSec = 3.0;

// ── 1€ Filter defaults ──────────────────────────────────
const double kOneEuroMinCutoff = 1.0;
const double kOneEuroBeta = 0.007;
const double kOneEuroDCutoff = 1.0;

// ── Camera ──────────────────────────────────────────────
const int kCameraFps = 30;

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
const double kMinEccentricSec = 1.5;

// ── Curl Bilateral Asymmetry ─────────────────────────────
/// Peak angle delta (degrees) between left and right arm to flag asymmetry.
const double kAsymmetryAngleDelta = 15.0;
/// Consecutive asymmetric reps required before firing lateralAsymmetry.
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
/// Deduction for short ROM (abandoned rep).
const double kQualityShortRomDeduction = 0.30;
/// Deduction for bilateral asymmetry.
const double kQualityAsymmetryDeduction = 0.10;

// ── Curl Camera-View Detection ───────────────────────────
/// Shoulder separation ratio below this → likely side view.
const double kSideViewShoulderSepThreshold = 0.10;
/// Shoulder separation ratio above this → likely front view.
const double kFrontViewShoulderSepThreshold = 0.15;
/// Confidence asymmetry above this → corroborates side view.
const double kViewShoulderConfidenceDeltaThreshold = 0.20;
/// Nose offset from shoulder midpoint above this → corroborates side view.
const double kViewNoseOffsetThreshold = 0.10;
/// Frames to accumulate before attempting to lock the view.
const int kViewDetectionFrames = 15;
/// Frames that must agree on the same view to lock it.
const int kViewDetectionConsensusFrames = 10;
