/// All magic numbers live here — nothing hard-coded in logic files.
library;

// ── Confidence ──────────────────────────────────────────
/// Minimum landmark confidence to use a frame for rep counting / feedback.
const double kMinLandmarkConfidence = 0.4;

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
