/// Canonical Demo Mode blueprint — "Demo Alex" + 14 sessions across the
/// last 21 days + per-rep details + ROM profiles.
///
/// Pure Dart: no DB access, no Flutter imports. Every call to
/// [DemoSeed.build] is deterministic for a given `now` timestamp; per-rep
/// numeric values use Knuth's multiplicative hash as a stable pseudo-random
/// generator so two builds at the same `now` produce byte-identical output.
///
/// Day-N offsets are computed against `now ?? DateTime.now()` at build
/// time. `DemoService.cleanReseedIfStale()` re-runs the build every cold
/// boot when the newest demo session is >36h old, so "Day -1" is always
/// roughly yesterday from the user's perspective.
///
/// See `plans_of_claude/demo-mode-toggle.md` revision 6 for the full
/// design rationale (ADRs 1–9 and Gaps 26 / 27 / 32 are particularly
/// relevant to this file).
library;

import '../../core/types.dart';
import '../../models/user_profile.dart';

/// One demo session — three row-maps ready to hand to
/// `SessionRepository.insertSeededSession`. All maps use named SQL
/// columns matching the schema-v10 layout.
class DemoSessionBlueprint {
  const DemoSessionBlueprint({
    required this.sessionRow,
    required this.repRows,
    required this.formErrorRows,
  });

  final Map<String, Object?> sessionRow;
  final List<Map<String, Object?>> repRows;
  final List<Map<String, Object?>> formErrorRows;
}

/// Full demo data set returned by [DemoSeed.build]. Pure value object.
///
/// **ROM profiles are intentionally absent** (per operator direction,
/// 2026-05-13 followup). Demo Mode does NOT seed `demo_curl_profile_v1` /
/// `demo_squat_profile_v1` / `demo_push_up_profile_v1` rows. Workouts started
/// while Demo Mode is on use the cold-start `RomThresholds.global` path
/// exactly like a fresh user. Settings ROM sections show "Not calibrated"
/// and the Profile-tab gear badge stays uncalibrated.
///
/// Recorded per-rep angles on the 14 historical demo sessions are unchanged
/// (those live in the `reps` table per-session and are unrelated to the
/// `profiles` keyspace).
class DemoBlueprint {
  const DemoBlueprint({required this.userProfile, required this.sessions});

  final UserProfile userProfile;
  final List<DemoSessionBlueprint> sessions;
}

/// Canonical persona + dataset for Demo Mode. Call [build] to materialize
/// fresh row maps and ROM profiles relative to `now`.
class DemoSeed {
  const DemoSeed._();

  /// Display name for the seeded `user_profile` row. Plain ASCII so it
  /// renders correctly in every font / locale we ship.
  static const String displayName = 'Demo Alex';

  /// Build the full blueprint. `now` is injectable for deterministic
  /// tests; production callers pass null and accept `DateTime.now()`.
  static DemoBlueprint build({DateTime? now}) {
    final ts = now ?? DateTime.now();
    return DemoBlueprint(
      userProfile: _buildUserProfile(ts),
      sessions: _buildSessions(ts),
    );
  }

  // ── User profile ────────────────────────────────────────────────────

  static UserProfile _buildUserProfile(DateTime now) {
    final goals = <UserGoal>[
      UserGoal(
        id: now.subtract(const Duration(days: 14)).millisecondsSinceEpoch,
        title: '30 push-ups in one set',
        detail: '22 / 30 — three to go',
        createdAt: now.subtract(const Duration(days: 14)),
      ),
      UserGoal(
        id: now.subtract(const Duration(days: 21)).millisecondsSinceEpoch,
        title: 'Hit 4 sessions per week',
        detail: '3 / 4 this week',
        createdAt: now.subtract(const Duration(days: 21)),
      ),
    ];
    return UserProfile(
      displayName: displayName,
      avatarEmoji: '💪',
      age: 28,
      gender: Gender.female,
      heightCm: 168,
      weightKg: 62,
      experience: ExperienceLevel.intermediate,
      primaryGoal: FitnessGoal.buildMuscle,
      goals: goals,
      createdAt: now.subtract(const Duration(days: 21)),
      updatedAt: now,
    );
  }

  // ── Sessions ────────────────────────────────────────────────────────

  /// The 14-session timeline. Each tuple is
  /// `(daysAgo, exercise, side, view, reps, durSec, avgQ, fatigue,
  ///   eccentricCount, formErrors)`.
  ///
  /// Asymmetry intentionally omitted from the seed per Gap 27 — squat
  /// doesn't track it and curl sessions lock to one side, so synthesizing
  /// it would look wrong.
  static const List<_SessionPlan> _plans = <_SessionPlan>[
    _SessionPlan(
      daysAgo: 21,
      exercise: ExerciseType.squat,
      reps: 18,
      durSec: 330,
      avgQuality: 0.82,
      formErrors: {FormError.excessiveForwardLean: 2},
    ),
    _SessionPlan(
      daysAgo: 20,
      exercise: ExerciseType.bicepsCurlSide,
      side: ProfileSide.right,
      view: CurlCameraView.sideRight,
      reps: 20,
      durSec: 370,
      avgQuality: 0.78,
      formErrors: {FormError.shoulderArc: 1, FormError.elbowDrift: 2},
    ),
    _SessionPlan(
      daysAgo: 18,
      exercise: ExerciseType.pushUp,
      reps: 15,
      durSec: 260,
      avgQuality: 0.74,
      formErrors: {FormError.hipSag: 3, FormError.pushUpShortRom: 1},
    ),
    _SessionPlan(
      daysAgo: 17,
      exercise: ExerciseType.squat,
      reps: 20,
      durSec: 360,
      avgQuality: 0.85,
      formErrors: {FormError.excessiveForwardLean: 1},
    ),
    _SessionPlan(
      daysAgo: 15,
      exercise: ExerciseType.bicepsCurlSide,
      side: ProfileSide.left,
      view: CurlCameraView.sideLeft,
      reps: 24,
      durSec: 425,
      avgQuality: 0.83,
      fatigue: true,
      eccentricTooFastCount: 2,
      formErrors: {FormError.shoulderShrug: 1, FormError.eccentricTooFast: 2},
    ),
    _SessionPlan(
      daysAgo: 14,
      exercise: ExerciseType.pushUp,
      reps: 18,
      durSec: 310,
      avgQuality: 0.79,
      formErrors: {FormError.hipSag: 2},
    ),
    _SessionPlan(
      daysAgo: 12,
      exercise: ExerciseType.squat,
      reps: 22,
      durSec: 390,
      avgQuality: 0.87,
      formErrors: {FormError.forwardKneeShift: 1},
    ),
    _SessionPlan(
      daysAgo: 10,
      exercise: ExerciseType.bicepsCurlSide,
      side: ProfileSide.right,
      view: CurlCameraView.sideRight,
      reps: 22,
      durSec: 405,
      avgQuality: 0.85,
      formErrors: {},
    ),
    _SessionPlan(
      daysAgo: 8,
      exercise: ExerciseType.pushUp,
      reps: 20,
      durSec: 345,
      avgQuality: 0.81,
      formErrors: {FormError.hipSag: 1},
    ),
    _SessionPlan(
      daysAgo: 6,
      exercise: ExerciseType.squat,
      reps: 24,
      durSec: 430,
      avgQuality: 0.88,
      formErrors: {FormError.excessiveForwardLean: 1},
    ),
    _SessionPlan(
      daysAgo: 5,
      exercise: ExerciseType.bicepsCurlSide,
      side: ProfileSide.left,
      view: CurlCameraView.sideLeft,
      reps: 26,
      durSec: 450,
      avgQuality: 0.86,
      formErrors: {FormError.elbowRise: 1},
    ),
    _SessionPlan(
      daysAgo: 3,
      exercise: ExerciseType.pushUp,
      reps: 22,
      durSec: 365,
      avgQuality: 0.83,
      formErrors: {},
    ),
    _SessionPlan(
      daysAgo: 2,
      exercise: ExerciseType.squat,
      reps: 25,
      durSec: 440,
      avgQuality: 0.89,
      formErrors: {},
    ),
    _SessionPlan(
      daysAgo: 1,
      exercise: ExerciseType.bicepsCurlSide,
      side: ProfileSide.right,
      view: CurlCameraView.sideRight,
      reps: 24,
      durSec: 420,
      avgQuality: 0.87,
      formErrors: {FormError.elbowDrift: 1},
    ),
  ];

  static List<DemoSessionBlueprint> _buildSessions(DateTime now) {
    return _plans.map((p) => _buildSession(p, now)).toList(growable: false);
  }

  static DemoSessionBlueprint _buildSession(_SessionPlan p, DateTime now) {
    final startedAt = now.subtract(Duration(days: p.daysAgo));
    final sessionRow = <String, Object?>{
      'exercise': p.exercise.name,
      'started_at': startedAt.millisecondsSinceEpoch,
      'duration_ms': p.durSec * 1000,
      'total_reps': p.reps,
      'total_sets': 1,
      'average_quality': p.avgQuality,
      'detected_view': p.exercise.isCurl ? p.view.name : null,
      'fatigue_detected': p.fatigue ? 1 : 0,
      'asymmetry_detected': 0,
      'eccentric_too_fast_count': p.eccentricTooFastCount,
      'schema_version': 1,
      'is_demo': 1,
    };
    final repRows = <Map<String, Object?>>[];
    for (var i = 0; i < p.reps; i++) {
      repRows.add(_buildRepRow(plan: p, repIndex: i + 1));
    }
    final formErrorRows = <Map<String, Object?>>[];
    p.formErrors.forEach((err, count) {
      formErrorRows.add(<String, Object?>{'error': err.name, 'count': count});
    });
    return DemoSessionBlueprint(
      sessionRow: sessionRow,
      repRows: repRows,
      formErrorRows: formErrorRows,
    );
  }

  static Map<String, Object?> _buildRepRow({
    required _SessionPlan plan,
    required int repIndex,
  }) {
    // Deterministic per-rep jitter — Knuth multiplicative hash on
    // (daysAgo, repIndex). Same inputs → same output across runs.
    final j = _jitter(plan.daysAgo * 1000 + repIndex);
    final quality = (plan.avgQuality - 0.05 + j * 0.10).clamp(0.0, 1.0);
    final concentricMs = 1200 + (j * 800).round();

    if (plan.exercise == ExerciseType.bicepsCurlSide) {
      final minAngle = 40.0 + j * 18.0;
      final maxAngle = 155.0 + j * 15.0;
      return <String, Object?>{
        'rep_index': repIndex,
        'quality': quality,
        'min_angle': minAngle,
        'max_angle': maxAngle,
        'side': plan.side.name,
        'view': plan.view.name,
        'threshold_source': ThresholdSource.calibrated.name,
        'bucket_updated': repIndex <= 3 ? 1 : 0,
        'rejected_outlier': 0,
        'concentric_ms': concentricMs,
        'biceps_lean_deg': 5.0 + j * 8.0,
        'biceps_shoulder_drift_ratio': 0.05 + j * 0.10,
        'biceps_elbow_drift_ratio': 0.04 + j * 0.08,
        'biceps_back_lean_deg': 2.0 + j * 5.0,
        'biceps_elbow_drift_signed': (j > 0.5 ? 1 : -1) * (0.04 + j * 0.08),
        'biceps_shrug_ratio': 0.02 + j * 0.06,
        'biceps_elbow_rise_ratio': 0.03 + j * 0.07,
      };
    }
    if (plan.exercise == ExerciseType.squat) {
      final minAngle = 85.0 + j * 20.0;
      final maxAngle = 165.0 + j * 10.0;
      return <String, Object?>{
        'rep_index': repIndex,
        'quality': quality,
        'min_angle': minAngle,
        'max_angle': maxAngle,
        'threshold_source': ThresholdSource.calibrated.name,
        'concentric_ms': concentricMs,
        'squat_lean_deg': 30.0 + j * 15.0,
        'squat_knee_shift_ratio': 0.10 + j * 0.15,
        'squat_heel_lift_ratio': 0.02 + j * 0.04,
        'squat_variant': SquatVariant.bodyweight.name,
        'squat_min_knee_angle': minAngle,
        'squat_max_knee_angle': maxAngle,
      };
    }
    // pushUp
    final minAngle = 90.0 + j * 15.0;
    final maxAngle = 160.0 + j * 12.0;
    return <String, Object?>{
      'rep_index': repIndex,
      'quality': quality,
      'min_angle': minAngle,
      'max_angle': maxAngle,
      'concentric_ms': concentricMs,
    };
  }

  /// Stable pseudo-random `[0.0, 1.0)` from a 32-bit input via Knuth's
  /// multiplicative hash. Deterministic across runs — call with the same
  /// seed and get the same value back.
  static double _jitter(int seed) {
    // 2654435761 is Knuth's recommended multiplier for hashing 32-bit ints.
    final hashed = (seed * 2654435761) & 0xFFFFFFFF;
    return (hashed % 1000) / 1000.0;
  }

  // ROM profiles are intentionally NOT generated — see `DemoBlueprint`
  // class doc. Demo Mode leaves the demo_* keyspace empty so workouts
  // started during demo use the cold-start `RomThresholds.global` path.
}

/// Internal plan struct — one row in the canonical 14-session table.
class _SessionPlan {
  const _SessionPlan({
    required this.daysAgo,
    required this.exercise,
    required this.reps,
    required this.durSec,
    required this.avgQuality,
    required this.formErrors,
    this.side = ProfileSide.right,
    this.view = CurlCameraView.unknown,
    this.fatigue = false,
    this.eccentricTooFastCount = 0,
  });

  final int daysAgo;
  final ExerciseType exercise;
  final ProfileSide side;
  final CurlCameraView view;
  final int reps;
  final int durSec;
  final double avgQuality;
  final bool fatigue;
  final int eccentricTooFastCount;
  final Map<FormError, int> formErrors;
}
