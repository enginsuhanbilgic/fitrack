/// Single control panel for every FSM angle gate, form-error threshold,
/// and sensitivity parameter in FiTrack.
///
/// WHAT TO EDIT HERE
/// ─────────────────
/// Open this file when you want to tune:
///   • Biceps-curl FSM angle gates (start / peak / peakExit / end)
///   • Squat FSM angle gates (start / bottom / end)
///   • Push-up FSM angle gates (start / bottom / end)
///   • Form-error thresholds (swing, shrug, drift, lean, elbow rise)
///   • Sensitivity deltas (how much ±High / ±Low shift each gate)
///   • Per-view telemetry-derived defaults (front / sideLeft / sideRight)
///   • Developer flags: kUseTelemetryRomDefaults, kUsePipelineRomDefaults
///
/// WHAT NOT TO EDIT HERE
/// ─────────────────────
/// Confidence gates, camera FPS, 1€ filter params, ring-buffer sizes,
/// countdown timers, feature flags unrelated to thresholds — those live
/// in `constants.dart` and are intentionally separate from motion thresholds.
///
/// HOW THE THREE-TIER RESOLVER WORKS
/// ──────────────────────────────────
/// `RomThresholds.global(view, sensitivity)` tries each tier in order:
///   Tier 1 — CurlRomDefaults (PROJECT CONVENTION — values derived from
///             live in-app diagnostic-session telemetry; edit in
///             `curl_rom_defaults.dart` after recording a new session)
///   Tier 2 — PipelineRomDefaults (SHELVED — gated by kUsePipelineRomDefaults;
///             produced by the offline video-clip pipeline at
///             `tools/dataset_analysis/`, parked until the dataset grows)
///   Tier 3 — Legacy kCurl* constants below (always available)
library;

// ── Re-exports so callers need only one import ──────────────────────────────
export 'constants.dart'
    show
        // ── Biceps Curl FSM (Tier 3 / legacy fallback) ──
        kCurlStartAngle,
        kCurlPeakAngle,
        kCurlPeakExitAngle,
        kCurlEndAngle,
        kCurlPeakExitGap,
        // ── Squat FSM ──
        kSquatStartAngle,
        kSquatBottomAngle,
        kSquatEndAngle,
        // ── Push-up FSM ──
        kPushUpStartAngle,
        kPushUpBottomAngle,
        kPushUpEndAngle,
        // ── Sensitivity deltas (applied by RomThresholds._applyRomSensitivity) ──
        // High:  dStart=+5, dPeak=−10, dEnd=0
        // Low:   dStart=−5, dPeak=+10, dEnd=−5
        // (deltas are inline in rom_thresholds.dart — edit there to change them)
        // ── Developer flags ──
        kUseTelemetryRomDefaults,
        kUsePipelineRomDefaults,
        // ── Form-error globals (curl) ──
        kSwingThreshold,
        kTorsoLeanThresholdDeg,
        kBackLeanThresholdDeg,
        kShrugThreshold,
        kDriftThreshold,
        kElbowRiseThreshold,
        kShortRomTolerance,
        // ── Form-error globals (squat) ──
        kSquatLeanWarnDegBodyweight,
        kSquatLeanWarnDegHBBS,
        kSquatLongFemurLeanBoost,
        kSquatKneeShiftWarnRatio,
        kSquatHeelLiftWarnRatio,
        // ── Profile / calibration tolerances ──
        kProfilePeakTolerance,
        kProfileStartTolerance,
        kProfileEndTolerance,
        kProfileWarmupMultiplier,
        kProfileWarmupReps,
        kMinViableRomDegrees;

export 'form_thresholds.dart' show FormThresholds;
export 'curl_rom_defaults.dart' show CurlRomDefaults;
export 'squat_rom_defaults.dart' show SquatRomDefaults, SquatRomThresholdSet;
export 'push_up_rom_defaults.dart'
    show PushUpRomDefaults, PushUpRomThresholdSet;
export 'rom_thresholds.dart' show RomThresholds, RomBucketLike;
export 'squat_form_thresholds.dart' show SquatFormThresholds;
