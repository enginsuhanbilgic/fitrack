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
//
// SENSITIVITY CONTRACT (2026-05-14)
// ──────────────────────────────────
// The `kCurl*Angle` / `kSquat*Angle` / `kPushUp*Angle` constants below are
// the **Medium-baseline** numbers — referenced by *non-sensitivity-aware*
// downstream paths:
//   * `RomThresholds.globalUnmodified` — diagnostic short-circuit.
//   * `curl_rom_profile.dart:78-79` — cold-start bucket seeding.
//   * `squat_strategy.dart:417` — long-femur auto-detection gate.
//   * `squat_rom_profile.dart` — cold-start squat bucket seeding.
//   * `push_up_rom_profile.dart` — push-up FSM defaults.
//   * `form_auditor.dart` push-up audit cold-start fallback.
//   * `workout_view_model.dart` `squat.calibration_start` telemetry payload.
//
// The **High anchor** (consumed by the sensitivity post-pass) lives inside
// the per-exercise `core/*_rom_defaults.dart` modules — NOT here. Editing
// any constant below moves the Medium baseline for every consumer above;
// editing the High anchor only changes the FSM gates routed through the
// post-pass (`RomThresholds.global`, `SquatRomThresholdSet.anchor`,
// `PushUpRomDefaults.anchor`).
//
// Do not edit these to "tune sensitivity." The toggle lives in
// `_tier3MediumLooseness` / `_telemetryMediumLooseness` / per-exercise
// `_mediumLooseness` tuples in the threshold modules.
/// IDLE → CONCENTRIC when elbow angle drops below this.
const double kCurlStartAngle = 160.0;

/// CONCENTRIC → PEAK when elbow angle reaches this.
const double kCurlPeakAngle = 70.0;

/// PEAK → ECCENTRIC when elbow angle exceeds peak + hysteresis.
const double kCurlPeakExitAngle = 85.0;

/// ECCENTRIC → IDLE when elbow angle reaches this → rep++.
const double kCurlEndAngle = 140.0;

// ── Threshold source toggle (developer) ─────────────────
/// PROJECT CONVENTION (2026-05-13)
/// ───────────────────────────────
/// FiTrack's cold-start ROM thresholds are derived from **live in-app
/// diagnostic-session telemetry** — the "Curl debug session" toggle in
/// Settings records per-rep extremes, which are post-processed into the
/// per-view threshold buckets in `curl_rom_defaults.dart`.
///
/// The alternative — deriving thresholds from an offline video-clip
/// analysis pipeline (`tools/dataset_analysis/`) — is SHELVED. The
/// pipeline output remains in `pipeline_rom_defaults.dart` for a future
/// re-derivation when the recorded dataset grows, but is not consumed at
/// runtime today.
///
/// Three-tier resolver (see `rom_thresholds.dart`):
///   1. Telemetry-derived defaults  (this flag, default `true`)        ★ shipping
///   2. Pipeline-derived defaults   (`kUsePipelineRomDefaults`, false)   shelved
///   3. Legacy hand-tuned constants (`kCurl*` above)                     fallback

/// Tier 1 gate. When `true`, `RomThresholds.global(view)` consults
/// [CurlRomDefaults.forView] first. Views with a null entry fall
/// through to the next tier. This is the **project convention** — leave on.
const bool kUseTelemetryRomDefaults = true;

/// Tier 2 gate. When `true`, `RomThresholds.global(view)` consults
/// `PipelineRomDefaults.forView` after the telemetry tier and before the
/// legacy constants. Default `false` — the pipeline is shelved pending a
/// larger dataset (current leave-one-clip-out cross-validation std is ±20–28°,
/// not yet generalizable). Only affects users without a `CurlRomProfile`
/// or auto-calibration data — the cold-start `ThresholdSource.global` path.
const bool kUsePipelineRomDefaults = false;

// ── Form feedback thresholds ────────────────────────────
/// Torso swing: ΔX_shoulder / L_torso.
const double kSwingThreshold = 0.25;

/// Forward trunk lean: change in torso-to-vertical angle (degrees) relative to
/// rep-start baseline. Only evaluated in side views (sideLeft / sideRight) where
/// the sagittal-plane projection is faithful.
///
/// HISTORY:
///   - 15° pre-2026-04-28 (too permissive, missed momentum cheats)
///   - 8° 2026-04-28 → 2026-05-15 (over-tightened: fired on natural ~5-7°
///     postural shift during heavy contraction, especially on the last reps
///     of a set)
///   - 12° 2026-05-15 retune: pairs with the new minimum-movement dead-band
///     (kFormMinMovementLeanDeg) so micro-wobble below pose-noise can never
///     fire, while genuine momentum-driven lean (typically 15-25°) is still
///     flagged decisively.
const double kTorsoLeanThresholdDeg = 12.0;

/// Backward trunk lean threshold (degrees). Typically smaller than forward
/// lean as hyperextension is more dangerous and clearly indicates cheat.
///
/// HISTORY:
///   - 10° pre-2026-04-28
///   - 6°  2026-04-28 → 2026-05-15 (caught natural counterbalance lean on
///     heavier curls as "hyperextension"; constant false positives)
///   - 10° 2026-05-15 retune: real lumbar-hyperextension cheats sit at
///     15-25°; 10° still warns before the danger zone but no longer treats
///     normal end-of-set counterbalance as a fault. Dead-band guard via
///     kFormMinMovementLeanDeg handles the sub-noise floor.
const double kBackLeanThresholdDeg = 10.0;

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
const double kShrugThreshold = 0.20;

/// Elbow drift: torso-perpendicular elbow offset / L_torso.
///
/// 2026-05-16: 0.20→0.15 (~25% stricter). In side-view curls the elbow
/// must stay pinned to the shoulder→hip line; leaving it is the front-delt
/// cheat. The added false-positive risk from the tighter gate is absorbed
/// by the per-rep sustained-frame gate (see [kDriftSustainedFraction] /
/// [kDriftMinEvalFrames]) — a single noisy off-line frame no longer fires
/// the cue. This is an AUDIT threshold (FIXED, never sensitivity-keyed per
/// SKILLS "Sensitivity vs Form Audit"); the user-tunable dead-band stays
/// at [kFormMinMovementDriftRatio] = 0.08 and is NOT touched here.
const double kDriftThreshold = 0.15;

/// Fraction of a rep's *evaluated* frames that must hold the elbow over
/// the drift threshold before [FormError.elbowDrift] is emitted at rep
/// commit. Mirrors [kSquatLeanSustainedFraction] verbatim — the proven,
/// doctrine-clean sustained-frame template. A clean rep momentarily clips
/// threshold for ~2-3 of ~20 evaluated frames (~0.10-0.15); a genuine
/// off-line elbow holds it for the bulk of the rep (≫ 0.35).
///
/// FIXED value — NOT tier-keyed (the sustained gate is pure per-rep signal
/// processing with no sensitivity branch, per SKILLS doctrine). PRELIMINARY
/// — rides the existing `biceps_elbow_drift_signed`/`_ratio` telemetry
/// columns for a future derivation pass; no new channel needed.
const double kDriftSustainedFraction = 0.35;

/// Minimum evaluated-frame count before the sustained-drift fraction is
/// trusted. Below this floor the verdict fails OPEN (no fault emitted) —
/// a too-short rep can't carry enough signal to grade. Mirrors
/// [kSquatLeanMinEvalFrames] and the fail-open semantics of the other
/// per-rep curl verdicts.
const int kDriftMinEvalFrames = 6;

// ── Form-audit minimum-movement dead-band (2026-05-15) ──
// Two-layer guard: BELOW these magnitudes the analyzer treats the signal
// as pose-estimation noise and does not even compare against the audit
// threshold. ABOVE the audit threshold, the cue fires as before. The
// intermediate band (dead-band < x < threshold) is the user's "minimal
// movement budget" — natural breathing, scapular activity, postural
// micro-shifts pass through silently.
//
// The values below are the **baseline floor** — the strictest possible
// dead-band, equivalent to the 2026-05-15 hard-coded behavior. After
// 2026-05-15 a user-controlled Form Tolerance Percent dial scales the
// effective dead-band from this floor UP TO (but never above) the
// corresponding audit threshold; see `FormThresholds.withTolerance` and
// the Form-Audit Tolerance section of `.agent_brain/SKILLS.md`. Doctrine
// compliance: the dial widens silence, never weakens the audit threshold,
// so the "Sensitivity vs Form Audit" safety inversion can't recur.
//
// The audit thresholds themselves remain NOT user-tunable (same doctrine
// as `curl_form_audit_defaults.dart`). The pose-noise floor encoded here
// is a property of ML Kit + the 1€ filter, not user preference; the
// tolerance dial only controls how much pre-threshold motion stays silent
// ABOVE that floor.
//
// Floors derived from observed jitter in clean reps:
//   - lateral shift / torso  ≈ 0.02-0.05 noise floor → 0.08 dead-band
//   - lean delta              ≈ 1-2° noise floor    → 3° dead-band
//   - shrug ratio             ≈ 0.03-0.05 floor     → 0.06 dead-band
//   - drift ratio             ≈ 0.04-0.06 floor     → 0.08 dead-band
//   - elbow-rise ratio        ≈ 0.04-0.07 floor     → 0.08 dead-band
//
// Each value sits at roughly 1/3 to 1/2 of its corresponding audit
// threshold — large enough to absorb noise, small enough that real
// faults (which sit at 1.5-3× the audit threshold) still trigger.

/// Default Form Tolerance Percent for cold-start / never-touched users.
/// `0` means "use the baseline dead-band exactly" — bit-for-bit identical
/// to the 2026-05-15 hard-coded behavior. The slider in Settings can
/// widen the dead-band from here up to the corresponding audit threshold.
/// See `FormThresholds.withTolerance` for the formula.
const int kDefaultFormTolerancePercent = 0;

/// Below this swing ratio, no `torsoSwing` cue may fire even if other
/// branches of the swing check would have triggered. Applies to lateral
/// shift and shoulder-arc legs of the combined swing detector.
const double kFormMinMovementSwingRatio = 0.08;

/// Below this absolute lean delta (degrees), no forward-lean cue fires.
/// Targets the same `torsoSwing` cue as the swing dead-band (lean and
/// swing are co-emitted), and back-lean as a separate evaluation.
const double kFormMinMovementLeanDeg = 3.0;

/// Below this shrug ratio, no `shoulderShrug` cue fires.
const double kFormMinMovementShrugRatio = 0.06;

/// Below this drift ratio, no `elbowDrift` cue fires. Uses the absolute
/// (unsigned) perpendicular projection magnitude.
const double kFormMinMovementDriftRatio = 0.08;

/// Below this elbow-rise ratio, no `elbowRise` cue fires. Sign convention
/// matches `kElbowRiseThreshold` — only positive (upward) rise is gated;
/// negative rise (elbow dropping) was never a fault.
const double kFormMinMovementRiseRatio = 0.08;

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
const double kElbowRiseThreshold = 0.22;

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

/// Per-error voice-cue cap when [TtsVerbosity.low] is selected. After this
/// many fires of the same error in a single session, the voice mutes for
/// that error — UNTIL the persistence re-arm fires it again (see
/// [kTtsPersistenceReArmRepsLow]). Visual highlights and the session-end
/// summary still surface every fire regardless. Tuned to 1 (single spoken
/// reminder per cue) because the "low" tier exists for users who've
/// internalized the coaching and want a quiet workout.
const int kTtsVerbosityLowCap = 1;

/// Per-error voice-cue cap when [TtsVerbosity.medium] is selected. After
/// this many fires of the same error in a single session, the voice mutes
/// for that error — UNTIL the persistence re-arm fires it again (see
/// [kTtsPersistenceReArmRepsMedium]). Visual highlights and the session-end
/// summary still surface every fire regardless. Tuned to 3 (initial cue +
/// two follow-ups) because most form errors fire 2-5 times per set, so the
/// cap silences the *repeat* without missing the first warning. Default tier.
const int kTtsVerbosityMediumCap = 3;

/// Persistence re-arm window for [TtsVerbosity.medium]. After the per-error
/// voice cap ([kTtsVerbosityMediumCap]) mutes a fault, if it keeps clearing
/// the [kFeedbackCooldownSec] time-cooldown this many more times, the voice
/// re-alerts EXACTLY ONCE, then re-mutes for another full window. Because the
/// 3 s cooldown collapses multi-frame error spam to ≈ one fire per rep, this
/// is effectively "re-nudge after this many more faulty reps." Mirrors the
/// proven `kTempoConsistencyReArmReps` (5) re-arm shape. A user who fixes the
/// fault never hears it again; a persistently-wrong user gets a periodic
/// nudge instead of permanent silence. Audio-only — detection, highlights,
/// `errorCounts`, and the summary are unaffected.
const int kTtsPersistenceReArmRepsMedium = 5;

/// Persistence re-arm window for [TtsVerbosity.low]. Wider than
/// [kTtsPersistenceReArmRepsMedium] — "low" means "I've internalized the
/// cues, keep it quiet" — but a persistently-wrong user is still re-nudged,
/// just less often. Same mechanism as the medium window.
const int kTtsPersistenceReArmRepsLow = 8;

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

// ── Setup Check — Camera framing (industry-standard "Frame Check") ──────────
// Four-signal framing gate that runs during SETUP_CHECK for biceps curl.
// Enforces the spec: "the whole arm — from the wrist at full extension up to
// the head — must fit inside the frame, and the camera lens must sit at
// mid-chest height." All signals use normalised landmark coordinates (0..1
// of frame), so no frame dimensions are required.
//
// Signal 1 — Head visible with safe top margin.
// `nose.y` must be greater than this value (i.e. below the very top edge).
// The nose is the highest reliably-detected landmark and sits above the
// shoulders — if it is in-frame with margin, the head is in-frame, and the
// peak-curl fingertip position (which lands near the shoulder/head) has
// vertical room. Below 0.04 means the head is clipping the top edge.
const double kSetupHeadTopMargin = 0.04;

// Signal 2 — Wrist visible with safe bottom margin at rest.
// At setup the arm is extended downward, so the active wrist sits near the
// hip. Its `y` must be less than this value (i.e. above the very bottom
// edge). Below this margin the extended-arm bottom of the rep is clipping
// the frame and the FSM will miss the END threshold.
const double kSetupWristBottomMargin = 0.92;

// Signal 3 — Camera lens at mid-chest height.
// When the lens is level with mid-chest, the optical axis crosses the body
// midway between shoulders and hips, so the shoulder-hip midpoint y projects
// near the vertical center of the frame. Tolerance ±0.12 around 0.5 allows
// some user-height variance while still catching obviously high/low phones.
const double kSetupMidChestTarget = 0.5;
const double kSetupMidChestTolerance = 0.12;

// Signal 4 — Shoulder-hip tilt from vertical (degrees).
// `atan2(|shoulder.x − hip.x|, |shoulder.y − hip.y|)`. A correctly-placed
// side-view camera shows a near-vertical torso. Larger tilts mean the user
// is leaning, the phone is rotated, or the camera is severely keystoning.
const double kSetupTorsoTiltMaxDeg = 25.0;

// ── Squat FSM thresholds (degrees) ──────────────────────
/// IDLE → DESCENDING when knee angle drops below this.
const double kSquatStartAngle = 160.0;

/// DESCENDING → BOTTOM when knee angle drops below this — the squat depth
/// gate. A rep that never crosses this angle fires `FormError.squatDepth`
/// and is vetoed by the half-squat guard (not counted).
///
/// 2026-05-16: tightened 90° → 80° (parallel → clearly below parallel).
/// At 90° the counter committed reps at parallel-depth, which the user
/// reported as "counting earlier than it should" — their target depth is
/// below parallel. 80° demands a visibly below-parallel squat.
///
/// **PROVISIONAL — telemetry-derivation pending.** This is an interim
/// value chosen so clean-rep telemetry collection isn't polluted by
/// parallel-only reps. The empirical retune comes from the `squat.rep`
/// `min_knee=` distribution of labeled clean reps via the standard
/// derive-from-telemetry workflow (curl-peak lesson: derive, don't guess).
/// Do NOT treat 80° as final.
///
/// NOTE: the long-femur auto-relax detection band is deliberately NOT
/// coupled to this constant — it uses [kSquatLongFemurDetectFloorAngle]
/// (pinned at anatomical 90°) so tightening the depth gate does not
/// silently widen long-femur detection.
const double kSquatBottomAngle = 80.0;

/// ASCENDING → IDLE when knee angle returns above this → rep++.
const double kSquatEndAngle = 160.0;

// ── Squat FSM thresholds — High sensitivity (telemetry-derived, 2026-05-15) ─
/// **Downstream copy** of the High-anchored squat thresholds. The
/// authoritative source is `SquatRomThresholdSet.anchor` in
/// `squat_rom_defaults.dart` — these constants exist for backwards-compatible
/// test references (see `test/core/squat_rom_thresholds_test.dart`) and any
/// existing direct-constant consumers.
///
/// When retuning: update the literals in `squat_rom_defaults.dart` first,
/// then mirror the same values here. The two MUST agree or
/// `squat_rom_thresholds_test.dart` will fail.
///
/// Provenance: 2026-05-15 squat debug session (parity mode, tier 3, n=12
/// kept reps). See `squat_rom_defaults.dart` file-level doc-block for full
/// derivation context. Medium-sensitivity is computed at runtime via
/// `SquatRomThresholdSet.applySensitivity` (deltas `-5, +2, -3`).
const double kSquatStartAngleHigh = 166.4;
const double kSquatBottomAngleHigh = 47.1;
const double kSquatEndAngleHigh = 163.4;

// ── Squat personal calibration ──────────────────────────
/// Minimum reps required for squat personal calibration to commit. Mirrors
/// [kCalibrationMinReps] (curl) and lives as a separate constant so a future
/// per-exercise dial can diverge the two values without a refactor.
const int kSquatCalibrationMinReps = 3;

/// Minimum ROM excursion (degrees) for a squat rep to qualify as a valid
/// calibration sample. CANONICAL NAME — referenced by upcoming Parts 5, 6, 8
/// of the squat overhaul plan. Looser than the curl floor (25°) because squat
/// reps with shallow knee flexion still carry calibration value via the
/// long-femur path.
const double kSquatMinViableRomDegrees = 40.0;

/// Minimum ROM excursion (top_elbow − bottom_elbow, degrees) required for the
/// push-up [PushUpAutoCalibrator] to emit thresholds. Added 2026-05-15 alongside
/// the new auto-calibrator class. Mirrors [kSquatMinViableRomDegrees] in shape
/// — the bar exists so a flat-elbow-angle session (pose detector confused, user
/// hovering over a chair, etc.) cannot trip a "calibrated-looking" tier-2
/// threshold from garbage data. 40° matches the existing
/// [kPushUpCalibrationMinExcursion] floor (20°) doubled for in-session
/// robustness — auto-cal sees real workout reps with more variance than a
/// deliberate calibration session, so the floor is stricter here.
const double kPushUpMinViableRomDegrees = 40.0;

/// Margin added to `observedMinKneeAngle` when deriving the BOTTOM gate from
/// a calibrated profile. Mirrors [kPushUpProfileBottomMargin] / the curl
/// profile's peak-tolerance pattern — the gate sits a touch *above* the
/// observed deepest angle so a noisy rep doesn't fail the user's own bar.
const double kSquatProfileBottomMargin = 5.0;

/// Margin subtracted from `observedMaxKneeAngle` for the START gate. Wider
/// than the END margin so the FSM enters DESCENDING decisively before the
/// user is committed to the rep.
const double kSquatProfileStartMargin = 10.0;

/// Margin subtracted from `observedMaxKneeAngle` for the END gate. Tighter
/// than the START margin so the rep doesn't commit prematurely — mirrors
/// curl's `start > end` FSM invariant (which prevents jitter at the top from
/// flipping into a new rep before the user has stabilized).
const double kSquatProfileEndMargin = 5.0;

// ── Push-up FSM thresholds (degrees) ────────────────────
//
// HYSTERESIS INVARIANT: kPushUpStartAngle < kPushUpEndAngle.
// The rep-commit gate (endAngle, ASCENDING→IDLE) and the next-rep-arm gate
// (startAngle, IDLE→DESCENDING) MUST NOT be equal. If they are, the
// 1€-filtered elbow angle jittering a few degrees around lockout straddles
// both gates: one physical rep commits, the filter dips, IDLE→DESCENDING
// re-arms, and a phantom second rep commits (the original double-count bug).
// A dead-band between the two gates means lockout jitter can never re-arm a
// rep. This mirrors curl's `start > end` and squat's
// kSquatProfileStartMargin(10°) > kSquatProfileEndMargin(5°) invariants.
// Any tier transform (sensitivity post-pass, calibration derivation) MUST
// preserve startAngle < endAngle.
/// IDLE → DESCENDING when elbow angle drops below this. 10° below
/// [kPushUpEndAngle] — the hysteresis dead-band that prevents lockout
/// jitter from re-arming a just-committed rep. See invariant note above.
const double kPushUpStartAngle = 150.0;

/// DESCENDING → BOTTOM when elbow angle drops below this.
const double kPushUpBottomAngle = 90.0;

/// A push-up attempt that reverses above bottom but reaches at least this
/// elbow angle is counted as a shallow/faulty rep instead of being discarded.
/// Sits between [kPushUpBottomAngle] and [kPushUpStartAngle].
const double kPushUpShallowRepMaxAngle = 130.0;

/// ASCENDING → IDLE when elbow angle returns above this → rep++.
/// Strictly greater than [kPushUpStartAngle] (hysteresis invariant).
const double kPushUpEndAngle = 160.0;

/// Push-up calibration accepts only realistic top-lockout elbow angles.
const double kPushUpCalibrationTopMinAngle = 140.0;
const double kPushUpCalibrationTopMaxAngle = 180.0;

/// Push-up calibration accepts only realistic bottom-position elbow angles.
const double kPushUpCalibrationBottomMinAngle = 55.0;
const double kPushUpCalibrationBottomMaxAngle = 145.0;

/// Minimum personal ROM excursion required before saving a push-up profile.
const double kPushUpCalibrationMinExcursion = 20.0;

/// Calibration-time body-line guard. Looser than live hipSag feedback because
/// ML Kit side-view hip/ankle landmarks are noisy near the floor, but still
/// rejects collapsed pike/sag positions as a saved ROM baseline.
const double kPushUpCalibrationBodyLineMaxDeviation = 30.0;

/// Hold duration for each push-up calibration pose.
/// DEPRECATED 2026-05-15 — push-up manual calibration migrated from the
/// hold-and-average protocol to per-rep extreme observation. Constant
/// retained because it appears in test fixtures and pre-migration telemetry
/// derivation scripts; new code should not read it.
const int kPushUpCalibrationHoldSeconds = 3;

/// Maximum angle spread allowed while holding a calibration pose.
/// DEPRECATED 2026-05-15 — see [kPushUpCalibrationHoldSeconds].
const double kPushUpCalibrationHoldMaxSpread = 10.0;

/// Number of valid push-up reps the manual calibrator observes before
/// computing anchor angles. With 3 reps, MAD outlier rejection is applied
/// from rep #3 onward — the first two reps seed the buffer, rep #3 is
/// retried if it deviates more than 3.5×MAD from the seed pair.
const int kPushUpCalibrationTargetReps = 3;

/// Minimum elbow-angle threshold a rep must reach at its top before the
/// per-rep detector treats the upward phase as a completed rep. Set just
/// below [kPushUpCalibrationTopMinAngle] so a controlled lockout is
/// required but a slightly shallow top doesn't silently drop the rep.
const double kPushUpCalibrationRepTopMinAngle = 135.0;

/// Personal push-up threshold margins derived from calibrated top/bottom.
const double kPushUpProfileStartMargin = 12.0;
const double kPushUpProfileEndMargin = 10.0;
const double kPushUpProfileBottomMargin = 8.0;
const double kPushUpProfileShallowMargin = 35.0;
const double kPushUpProfileMinGateGap = 6.0;

// ── Squat form thresholds ────────────────────────────────
/// (DEPRECATED 2026-04-25, Squat Master Rebuild) Max trunk-tibia deviation
/// before flagging the "chest up" cue. Retained as a constant — never read
/// by new code — only to keep historic references compiling.
const double kTrunkTibiaDeviation = 15.0;

// ── Squat form thresholds (Squat Master Rebuild, 2026-04-25; retuned 2026-05-15) ─
/// Lean threshold for bodyweight squat. Trunk-from-vertical > this fires
/// `excessiveForwardLean`.
///
/// HISTORY: Pre-2026-05-15 this was 45° — literature + 5° measurement-noise
/// *additive* margin, which pushed cueing well past the actual-injury-risk
/// zone (~30°). Retuned to 30° to cue 5° BEFORE the literature-cited risk
/// threshold (Straub & Powers 2024 IJSPT ~35°) instead of 10° after it.
/// Cueing should warn before the dangerous angle, not confirm it.
const double kSquatLeanWarnDegBodyweight = 30.0;

/// Lean threshold for high-bar back squat. Retuned 2026-05-15 from 50° to
/// 35° on the same "cue before, not after" principle. Glassbrook 2017
/// HBBS-specific risk threshold ≈40°; 35° gives a 5° early warning.
const double kSquatLeanWarnDegHBBS = 35.0;

/// Long-femur lifter boost — added to active lean threshold when the
/// "Tall lifter" Settings toggle is on. Orthogonal to the auto long-femur
/// detection (which relaxes the BOTTOM angle, not the lean threshold).
const double kSquatLongFemurLeanBoost = 5.0;

// ── Sustained forward-lean gate (2026-05-16) ─────────────
/// Fraction of a rep's *evaluated* frames whose signed lean must exceed the
/// active forward-lean threshold before `FormError.excessiveForwardLean`
/// fires at rep commit. Replaces the pre-2026-05-16 single-frame trigger
/// that false-fired on a momentary dip at the deepest point of an
/// otherwise-good rep.
///
/// Rationale for the rep-boundary move: forward lean at the very bottom of
/// a squat is transiently normal (the trunk pitches forward to keep the
/// bar over mid-foot, then recovers on the ascent). A single noisy frame
/// crossing 30°/35° is NOT a form fault; a *sustained* lean across a
/// meaningful share of the rep is. Backward lean keeps its instantaneous
/// fire — lumbar hyperextension is a genuine single-frame injury vector.
///
/// PRELIMINARY — telemetry-derivation pending. 0.35 is an engineering
/// starting point: a clean rep momentarily clips threshold for ~2-3 of
/// ~20 evaluated frames (~0.10-0.15); a genuine deep-lean fault holds it
/// for the bulk of the descent + bottom (≫ 0.35). The numeric retune
/// happens via the `squat.rep lean_exceed_frac` channel once real sessions
/// are collected with this logic shipping (curl-peak lesson: don't guess
/// thresholds — derive them).
const double kSquatLeanSustainedFraction = 0.35;

/// Minimum evaluated-frame count before the sustained-lean fraction is
/// trusted. Below this floor the verdict fails OPEN (no fault emitted) —
/// a 2-frame rep can't carry enough signal to grade. Mirrors the
/// fail-open semantics of `kSquatHipsForwardMinFrames` /
/// `kHipLeadMinAscendingFrames`.
const int kSquatLeanMinEvalFrames = 6;

/// Minimum dwell time in the BOTTOM state (milliseconds) before
/// BOTTOM → ASCENDING can fire. Added 2026-05-15.
///
/// Rationale: pre-2026-05-15 the BOTTOM→ASCENDING transition triggered the
/// instant hip Y started decreasing (single-frame trigger at 30 fps). A
/// "sit down once and immediately stand up" pattern entered BOTTOM for one
/// frame and exited the next — no actual bottom phase, no real rep, but
/// the FSM commited one anyway. Requiring 200ms of dwell rejects these
/// flash transitions while staying well under any normal squat tempo
/// (even a fast bodyweight rep pauses ≥300ms at the bottom).
///
/// Gates the *exit* of BOTTOM, not the entry — entering BOTTOM still fires
/// on the first frame the knee angle clears `_effectiveBottomAngle`, so
/// the user never feels "stuck waiting to bottom out." The dwell only
/// affects when the ascent can commit a rep.
const int kSquatBottomDwellMs = 200;

/// Backward-lean threshold (degrees). Signed lean more negative than this
/// (i.e., trunk leaning *backward* from vertical) fires
/// `FormError.excessiveBackwardLean`. Added 2026-05-15.
///
/// Rationale: lumbar hyperextension at the bottom of a squat is a real
/// injury vector that the prior analyzer ignored by design — `_signedLeanDeg`
/// returned negative values for backward lean but `evaluate()` filtered
/// `lean > 0` to "avoid false positives for users who lean back as they
/// squat." That filter erased the dangerous case along with the benign one.
/// 15° is below typical counterbalance backward lean (~5-10°) but well
/// inside the lumbar-hyperextension risk zone (10-20°+).
///
/// No long-femur boost — long-femur lifters tend toward MORE forward lean,
/// not more backward, so the boost is forward-only.
const double kSquatBackwardLeanWarnDeg = 15.0;

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

/// Maximum quality deduction for hip-lead ("Stripper Squat" / "Good Morning
/// Squat"). Severity = `((ratio − threshold) / 0.6).clamp(0, 1)` so a ratio
/// of 1.4 = 0 deduction, ratio of 2.0 = full 0.15 deduction. Mirrors the
/// proportional-severity model used for lean + heel-lift.
const double kQualitySquatHipLeadMaxDeduction = 0.15;
// `forwardKneeShift` is intentionally excluded — informational only.
// `squatDepth` is handled via the depth_factor multiplier, not a subtraction.

// ── Hip-lead detector (research, 2026-05-13) ────────────
/// Hip vs shoulder vertical-velocity ratio threshold. When the hip rises
/// faster than the shoulder by more than this multiple during the first
/// [kHipLeadAscendingWindowFraction] of ASCENDING, the lifter is leading
/// with the hips — a classic "Stripper Squat" / "Good Morning Squat"
/// fault. Source: deep-research biomechanical spec (2026-05-13).
const double kHipLeadVelocityRatio = 1.4;

/// Fraction of the ASCENDING phase evaluated for hip-lead. Only the first
/// 30% — by mid-ascent the spine straightens out naturally even on a
/// hip-lead rep, so evaluating later would mask the fault. The first
/// third is where the "Good Morning" pattern is biomechanically visible.
const double kHipLeadAscendingWindowFraction = 0.30;

/// Minimum raw ASCENDING frames required before the hip-lead check runs.
/// Floors out single-frame velocity spikes and very fast reps where the
/// 30%-window math degenerates to a 1–2 frame sample. Fail-open below
/// this count.
const int kHipLeadMinAscendingFrames = 6;

// ── No-knee-flexion detector (2026-05-15) ────────────────
/// Minimum peak forward-lean magnitude (deg) required before
/// [FormError.noKneeFlexion] can fire. Below this, the rep doesn't look
/// remotely like a torso-pivot pattern even if the knee delta is small,
/// so suppressing the cue avoids false positives on stiff-legged "almost
/// no-rep" attempts that already trigger `squatDepth`.
///
/// PRELIMINARY — awaiting telemetry-derived tuning. Picked from
/// biomechanics literature: a real squat at parallel sits the trunk at
/// 30–45° from vertical, while a torso-pivot-only fault commonly clears
/// 25° well before the knees engage.
const double kSquatNoKneeFlexionMinLeanDeg = 25.0;

/// Maximum knee-angle delta (deg) from descent-start to bottom that still
/// counts as "no meaningful knee flexion." A normal squat drops the knee
/// angle by 40–60°+; a torso-pivot rep drops it under ~20°.
///
/// PRELIMINARY — awaiting telemetry-derived tuning. Source: biomechanics
/// of squat patterning (deep-research spec, 2026-05-15).
const double kSquatNoKneeFlexionMaxKneeDeltaDeg = 20.0;

// ── Hips-forward-on-descent detector (2026-05-15) ────────
/// Time window (ms) after `onDescendingStart` during which the hip-X
/// trajectory is sampled. A proper hip-hinge initiates immediately —
/// 200 ms covers the first ~6 frames at 30 fps, which is where the
/// "sit back" pattern is biomechanically distinguishable from a
/// knee-dominant or chest-dive descent.
const int kSquatHipsForwardWindowMs = 200;

/// Minimum forward hip-X drift (toward toes), measured as a fraction of
/// leg length, that fires [FormError.hipsForwardOnDescent]. Compares
/// `hip.x[t=window] - hip.x[t=0]` against the heel reference: positive
/// means hips drifted toward the toes (fault), negative means hinged
/// back (correct).
///
/// PRELIMINARY — awaiting telemetry-derived tuning. 0.05 of leg length
/// is roughly 4–5 cm of forward hip travel for an average lifter; well
/// above pose-jitter noise floor but below the natural micro-shift of a
/// correctly-executed hip-hinge.
const double kSquatHipsForwardMinRatio = 0.05;

/// Minimum raw frame count inside the window before the hips-forward
/// check runs. Fail-open below this count — a 1-frame window is
/// dominated by pose-detector noise. Mirrors `kHipLeadMinAscendingFrames`.
const int kSquatHipsForwardMinFrames = 3;

// ── Knee-led-descent detector (2026-05-16) ───────────────
/// Early-descent dominance threshold: `|Δknee.x| / Δhip.y_down`
/// (leg-length-normalized) measured over the SAME window as the
/// hips-forward sampler ([kSquatHipsForwardWindowMs] — deliberately reused,
/// no second timer). A correct squat sits the hips back: the hip drops far
/// (large Δy) while the knee barely translates (small Δx), so the ratio is
/// well below 1.0. A knee-dominant initiation darts the knee forward with
/// little hip drop, pushing the ratio above this threshold. This is the
/// industry-standard "sit back into the squat" rule (NSCA/ACSM movement
/// screening) — NOT the retired "knees must not pass toes" myth.
///
/// PRELIMINARY — telemetry-derivation pending. 1.2 means horizontal knee
/// travel exceeded vertical hip drop by 20% in the first ~200 ms. A clean
/// hip-hinge sits well under 1.0 (hip drop dominates); a quad-dominant
/// knee-slide commonly clears 1.2 before the hip meaningfully descends.
/// The numeric retune happens via the `squat.knee_led ratio=` channel once
/// real sessions ship with this logic (curl-peak lesson: derive, don't
/// guess).
const double kSquatKneeLedMinRatio = 1.2;

/// Minimum raw frame count inside the shared window before the knee-led
/// check grades. Fail-open below this count. Reuses the hips-forward
/// floor's value semantics — both detectors share the window, so they
/// share the noise-floor frame count too. Kept as its own named constant
/// (rather than referencing `kSquatHipsForwardMinFrames` directly) so a
/// future telemetry retune can move them independently.
const int kSquatKneeLedMinFrames = 3;

/// Minimum leg-length-normalized hip-drop over the early-descent window
/// for the knee-led ratio to be DEFINED. The ratio is `knee-X-travel /
/// hip-drop`; with a near-zero denominator it is meaningless. Added
/// 2026-05-16 after a pre-flight session logged `knee_led ratio=5814`
/// (the old `math.max(1e-6, …)` clamp divided by epsilon instead of
/// guarding). Below this fraction the hip simply hasn't descended enough
/// in the window to compare against — the detector emits a null ratio and
/// does not fire (fail-open; the shallow rep is `squatDepth`'s concern).
///
/// PRELIMINARY — telemetry-derivation pending. 0.03 of leg length ≈ a few
/// cm of vertical hip travel: above pose-jitter, below the drop of any
/// genuine descent that has progressed far enough to be gradable.
const double kSquatKneeLedMinHipDropNorm = 0.03;

// ── Push-up form thresholds ──────────────────────────────
/// Max shoulder-hip-ankle collinearity deviation for hip sag (degrees).
const double kHipSagDeviation = 15.0;

/// Maximum quality deduction for losing a straight shoulder-hip-ankle line
/// during a push-up. Applied proportionally once deviation exceeds
/// [kHipSagDeviation].
const double kQualityPushUpHipSagMaxDeduction = 0.35;

/// Deduction for a committed push-up rep that does not reach the configured
/// bottom elbow angle.
const double kQualityPushUpShortRomDeduction = 0.30;

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

/// Lower bound of the rep-history long-femur detection band — anatomical,
/// pinned at 90° (parallel). The `_maybeUpdateLongFemur` heuristic relaxes
/// the depth gate only when the user consistently bottoms in
/// `(kSquatLongFemurDetectFloorAngle, kLongFemurBottomAngle]` =
/// `(90°, 100°]`, i.e. they can't reach parallel.
///
/// Deliberately a SEPARATE constant from [kSquatBottomAngle] (2026-05-16):
/// the depth gate was tightened to 80° (below-parallel target), but the
/// long-femur band must stay anchored to the anatomical 90° parallel
/// reference — otherwise tightening the depth gate would silently widen
/// long-femur detection to `(80°, 100°]`, making the auto-relax fire on
/// users who simply aren't squatting deep enough yet.
const double kSquatLongFemurDetectFloorAngle = 90.0;

/// Number of completed reps used to detect long-femur pattern.
const int kLongFemurDetectReps = 3;

// ── Anatomical long-femur classification (research, 2026-05-13) ──
/// Femur/torso ratio above which the user is classified as a long-femur
/// lifter and the squat BOTTOM gate relaxes to [kLongFemurBottomAngle]
/// from rep 1. Derived from biomechanical research: lifters with
/// femur/torso > 0.60 cannot reach 90° knee flexion without losing
/// balance over the midfoot. Replaces the rep-history heuristic (which
/// required 3 consecutive shallow reps before relaxing the gate) for
/// users whose first 5 high-confidence frames already classify them.
const double kLongFemurRatioThreshold = 0.60;

/// Minimum number of high-confidence frames the `_FemurTorsoClassifier`
/// must observe before it locks a ratio decision. The window-median
/// over ≥ this many samples filters ML Kit's first-frame jitter.
const int kFemurTorsoMinSamples = 5;

/// Maximum number of recent ratio samples retained for the
/// `_FemurTorsoClassifier`'s window-median calculation. Once locked,
/// the classifier ignores further samples — so this bound only applies
/// during the pre-lock accumulation phase.
const int kFemurTorsoWindowSize = 15;

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

// ── Squat Tempo Tracking (PRELIMINARY 2026-05-16 — telemetry-tunable) ──
// Squat is a slower compound movement than a curl, so the speed floors are
// higher than the curl equivalents (0.8/0.3). DESCENDING = eccentric
// (lowering), ASCENDING = concentric (lifting) — NSCA convention. Values
// are conservative first-pass estimates; refine from `squat.rep` telemetry.
/// Minimum descent (eccentric) duration in seconds — below fires
/// `squatEccentricTooFast`.
const double kSquatMinEccentricSec = 0.6;

/// Minimum ascent (concentric/lift) duration in seconds — below fires
/// `squatConcentricTooFast`. Closer to the eccentric floor than in a curl: a
/// squat ascent is a controlled grind, not an explosive curl.
const double kSquatMinConcentricSec = 0.5;

/// `(max − min) / mean` of the last N ascent durations above this fires
/// `squatTempoInconsistent`. Same ratio as curl — the fatigue signature
/// ("two controlled reps then a rushed one") is movement-agnostic.
const double kSquatTempoInconsistencyRatio = 0.30;

/// Sliding-window size for squat tempo-consistency evaluation.
const int kSquatTempoConsistencyWindow = 3;

/// After firing `squatTempoInconsistent`, suppress re-emission for this many
/// reps (recoverable drift, not a permanent one-shot — mirrors curl).
const int kSquatTempoConsistencyReArmReps = 5;

/// Minimum reps before squat fatigue comparison is possible (first N vs last N).
const int kSquatFatigueMinReps = 6;

/// Reps to average at start and end for the squat fatigue comparison.
const int kSquatFatigueWindowSize = 3;

/// Ratio threshold: if lastAvg / max(firstAvg, historicalMedian) > this, the
/// user is fatiguing on squat ascents.
const double kSquatFatigueSlowdownRatio = 1.4;

// ── Push-up Tempo Tracking (PRELIMINARY 2026-05-16 — telemetry-tunable) ──
// Push-up is faster than a squat but slower than a curl. DESCENDING =
// eccentric (lowering), ASCENDING = concentric (press). Conservative
// first-pass values; refine from `pushup.rep` telemetry.
/// Minimum descent (eccentric) duration in seconds — below fires
/// `pushUpEccentricTooFast`.
const double kPushUpMinEccentricSec = 0.5;

/// Minimum ascent (concentric/press) duration in seconds — below fires
/// `pushUpConcentricTooFast`.
const double kPushUpMinConcentricSec = 0.4;

/// `(max − min) / mean` of the last N ascent durations above this fires
/// `pushUpTempoInconsistent`.
const double kPushUpTempoInconsistencyRatio = 0.30;

/// Sliding-window size for push-up tempo-consistency evaluation.
const int kPushUpTempoConsistencyWindow = 3;

/// After firing `pushUpTempoInconsistent`, suppress re-emission for this many
/// reps (recoverable drift — mirrors curl).
const int kPushUpTempoConsistencyReArmReps = 5;

/// Minimum reps before push-up fatigue comparison is possible.
const int kPushUpFatigueMinReps = 6;

/// Reps to average at start and end for the push-up fatigue comparison.
const int kPushUpFatigueWindowSize = 3;

/// Ratio threshold: if lastAvg / max(firstAvg, historicalMedian) > this, the
/// user is fatiguing on push-up ascents.
const double kPushUpFatigueSlowdownRatio = 1.4;

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

/// Tolerance for start/peak short-ROM classification. Now equal to the
/// profile's `kProfilePeakTolerance` (7.5°) after the 2026-05-16 halving —
/// we only flag clear shortfalls, not borderline-OK reps. 5° sits above the
/// ~2–3° pose-estimation noise floor and well below a meaningful ROM
/// restriction.
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
/// Halved 2026-05-16 (was 15.0) — gates hug demonstrated ROM more tightly for
/// both manual calibration (`RomThresholds.fromBucket`) and auto-cal
/// (`RomThresholds.autoCalibrated`); they share `_build`.
const double kProfilePeakTolerance = 7.5;

/// Tolerance below the bucket's observed rest before the FSM enters CONCENTRIC.
/// Halved 2026-05-16 (was 10.0) — see [kProfilePeakTolerance].
const double kProfileStartTolerance = 5.0;

/// Tolerance applied to ECCENTRIC → IDLE transition (rep++).
/// Halved 2026-05-16 (was 25.0) — see [kProfilePeakTolerance].
const double kProfileEndTolerance = 12.5;

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

/// Compile-time gate for squat debug sessions. Ships false in production.
/// Currently `true` on dev builds — surfaces the home-screen "Squat Debug
/// Session" tile and the Settings switch so squat threshold telemetry can
/// be collected the same way as curl. Flip back to `false` before cutting
/// a production build.
const bool kSquatDebugSessionEnabled = true;

/// Ring-buffer size for squat debug sessions.
/// Overrides [kTelemetryRingSize] for the session lifetime; resetCap() restores it.
const int kSquatDebugRingBufferSize = 2000;

/// Target frequency (Hz) for squat frame-metric telemetry.
/// 3 Hz (vs curl's 2 Hz) — squat reps are slower so slightly higher density is useful.
const double kSquatDebugFrameMetricsHz = 3.0;

/// Compile-time gate for push-up debug sessions. Ships false in production.
/// Currently `true` on dev builds — surfaces the home-screen "Push-up Debug
/// Session" tile and the Settings switch so push-up FSM-threshold telemetry
/// can be collected the same way as curl and squat. Flip back to `false`
/// before cutting a production build. Mirrors [kSquatDebugSessionEnabled].
const bool kPushUpDebugSessionEnabled = true;

/// Ring-buffer size for push-up debug sessions.
/// Overrides [kTelemetryRingSize] for the session lifetime; resetCap() restores it.
const int kPushUpDebugRingBufferSize = 2000;

/// Target frequency (Hz) for push-up frame-metric telemetry.
/// 3 Hz — push-up cadence is comparable to squat (slower than curl), so the
/// same density used for squat captures the elbow-angle rise/fall shape well.
const double kPushUpDebugFrameMetricsHz = 3.0;
