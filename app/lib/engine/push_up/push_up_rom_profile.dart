library;

import '../../core/constants.dart';
import '../../core/types.dart';

class PushUpRomThresholds {
  const PushUpRomThresholds({
    required this.startAngle,
    required this.bottomAngle,
    required this.shallowRepMaxAngle,
    required this.endAngle,
  });

  static const defaults = PushUpRomThresholds(
    startAngle: kPushUpStartAngle,
    bottomAngle: kPushUpBottomAngle,
    shallowRepMaxAngle: kPushUpShallowRepMaxAngle,
    endAngle: kPushUpEndAngle,
  );

  final double startAngle;
  final double bottomAngle;
  final double shallowRepMaxAngle;
  final double endAngle;

  /// Apply the user's sensitivity selection to a High-anchored threshold set.
  ///
  /// Mirrors `PushUpRomThresholdSet.applySensitivity` (core layer) — same
  /// looseness deltas, applied to the engine-layer threshold class consumed
  /// by `PushUpStrategy`. Bucket-derived (calibrated) thresholds come back
  /// from `PushUpRomProfile.thresholds` as a High anchor; the resolver
  /// applies this post-pass before handing to the FSM. Idempotent on High.
  ///
  /// HYSTERESIS INVARIANT preserved by construction: the Medium deltas move
  /// startAngle by −5 and endAngle by only −3, so the start↔end gap *widens*
  /// by 2° relative to the anchor. Given the anchor satisfies
  /// startAngle < endAngle (enforced in constants.dart and, for calibrated
  /// profiles, by the [thresholds] getter's gate-gap clamp), every tier
  /// transform keeps startAngle < endAngle. Do NOT change these deltas such
  /// that the start delta becomes less negative than the end delta — that
  /// would shrink the dead-band and reintroduce the double-count bug.
  PushUpRomThresholds applySensitivity(FeedbackSensitivity sensitivity) {
    if (sensitivity == FeedbackSensitivity.high) return this;
    // Same deltas as PushUpRomThresholdSet._mediumLooseness: (-5, +5, -3, +5).
    return PushUpRomThresholds(
      startAngle: startAngle - 5,
      bottomAngle: bottomAngle + 5,
      shallowRepMaxAngle: shallowRepMaxAngle + 5,
      endAngle: endAngle - 3,
    );
  }
}

class PushUpRomProfile {
  /// Schema version. Bumped 1 → 2 on 2026-05-15 to add
  /// [calibrationRepCount] and [lastAppliedRepAt]. v1 records load cleanly
  /// via `fromJson` (the two new fields default to null when absent).
  static const int schemaVersion = 2;

  const PushUpRomProfile({
    required this.topAngle,
    required this.bottomAngle,
    required this.sampleCount,
    required this.createdAt,
    required this.lastUpdated,
    this.calibrationRepCount,
    this.lastAppliedRepAt,
    this.isLegacyV1 = false,
  });

  factory PushUpRomProfile.calibrated({
    required double topAngle,
    required double bottomAngle,
    int sampleCount = 1,
    int? calibrationRepCount,
    DateTime? now,
  }) {
    final reason = validate(topAngle: topAngle, bottomAngle: bottomAngle);
    if (reason != null) {
      throw StateError(reason);
    }
    final timestamp = now ?? DateTime.now();
    return PushUpRomProfile(
      topAngle: topAngle,
      bottomAngle: bottomAngle,
      sampleCount: sampleCount,
      createdAt: timestamp,
      lastUpdated: timestamp,
      calibrationRepCount: calibrationRepCount,
    );
  }

  final double topAngle;
  final double bottomAngle;
  final int sampleCount;
  final DateTime createdAt;
  final DateTime lastUpdated;

  /// How many reps the user performed during the calibration session that
  /// produced this profile. Null on v1 (legacy) records — the legacy
  /// calibration flow did not track this. Used by the
  /// "recalibrate suggestion" UX (Phase 6 of the parity plan): if this is
  /// less than the current `kPushUpCalibrationMinReps`, surface a
  /// non-blocking banner inviting recalibration. Never auto-launches
  /// calibration (per `feedback_calibration_opt_in.md` memory rule).
  final int? calibrationRepCount;

  /// Timestamp of the most recent `applyRep()` call. Null until in-session
  /// profile refinement has fired at least once. Used by the migration-
  /// safety path: a v1 record whose `lastAppliedRepAt` is null is treated
  /// as a one-shot calibration snapshot for the purposes of skipping
  /// shrink-confirm gates on first refinement. See Phase 4 of the parity
  /// plan for details.
  final DateTime? lastAppliedRepAt;

  /// True if this record was loaded from a pre-v2 schema (i.e. the
  /// `calibrationRepCount` field was absent in the source JSON). Recorded
  /// at deserialization time so downstream consumers don't have to guess
  /// from the field being null (which is also valid for fresh v2 records
  /// where the calibration overlay didn't supply a count).
  ///
  /// Defaults to false. Set true only by [fromJson] when migrating v1.
  /// Constructor-initialized as a `final` field so the class remains
  /// `const`-constructible.
  final bool isLegacyV1;

  bool get isCalibrated => sampleCount > 0;

  double get romDegrees => topAngle - bottomAngle;

  /// Derive FSM gates from a calibrated `[bottomAngle, topAngle]` band.
  ///
  /// HYSTERESIS INVARIANT (calibration path): the returned tuple MUST satisfy
  /// `startAngle < endAngle` with at least `kPushUpProfileMinGateGap` between
  /// them. The pre-fix derivation collapsed `end` onto `start` via
  /// `maxEnd <= start ? start : …` — that start==end equality is the exact
  /// double-count bug (lockout jitter re-armed IDLE→DESCENDING immediately
  /// after a commit). Everything except the final `end` computation is the
  /// original, well-behaved derivation (start/bottom/shallow each anchored
  /// to their proper reference points); only `end` is restructured so it is
  /// ALWAYS at least one gate-gap above `start`.
  PushUpRomThresholds get thresholds {
    const gap = kPushUpProfileMinGateGap;
    final rom = romDegrees;
    final startMargin = _clampDouble(
      rom * 0.25,
      gap,
      kPushUpProfileStartMargin,
    );
    final start = _clampDouble(
      topAngle - startMargin,
      bottomAngle + (gap * 2),
      kPushUpEndAngle,
    );
    final bottomMargin = _clampDouble(
      rom * 0.20,
      gap,
      kPushUpProfileBottomMargin,
    );
    final bottom = _clampDouble(
      bottomAngle + bottomMargin,
      kPushUpCalibrationBottomMinAngle,
      start - (gap * 2),
    );
    final activeRom = start - bottom;
    final shallow = _clampDouble(
      bottom + (activeRom * 0.55),
      bottom + gap,
      start - gap,
    );
    final endMargin = _clampDouble(rom * 0.12, gap, kPushUpProfileEndMargin);
    // HYSTERESIS-SAFE end gate. `end` must clear `start` by ≥ gap so the
    // FSM has a dead-band between the rep-commit gate and the next-rep-arm
    // gate (the missing dead-band was the double-count root cause). Lower
    // bound is therefore `start + gap`, NEVER `start` (the pre-fix code's
    // `? start :` branch and `start`-floored clamp both allowed end==start).
    // Upper bound prefers the user's measured lockout headroom
    // (`topAngle - gap`) but is itself lifted to `start + gap` when a tight
    // calibration leaves no headroom, so the clamp's `min ≤ max`
    // precondition always holds (avoids the `Invalid argument` throw) and
    // the dead-band is guaranteed even for a minimal-ROM profile.
    final endLowerBound = start + gap;
    final endUpperBound = _maxD(endLowerBound, topAngle - gap);
    final end = _clampDouble(start + endMargin, endLowerBound, endUpperBound);

    return PushUpRomThresholds(
      startAngle: start,
      bottomAngle: bottom,
      shallowRepMaxAngle: shallow,
      endAngle: end,
    );
  }

  static double _maxD(double a, double b) => a > b ? a : b;

  static String? validate({
    required double topAngle,
    required double bottomAngle,
  }) {
    if (topAngle < kPushUpCalibrationTopMinAngle ||
        topAngle > kPushUpCalibrationTopMaxAngle) {
      return 'Top angle must be ${kPushUpCalibrationTopMinAngle.toStringAsFixed(0)}-'
          '${kPushUpCalibrationTopMaxAngle.toStringAsFixed(0)} degrees.';
    }
    if (bottomAngle < kPushUpCalibrationBottomMinAngle ||
        bottomAngle > kPushUpCalibrationBottomMaxAngle) {
      return 'Bottom angle must be ${kPushUpCalibrationBottomMinAngle.toStringAsFixed(0)}-'
          '${kPushUpCalibrationBottomMaxAngle.toStringAsFixed(0)} degrees.';
    }
    if ((topAngle - bottomAngle) < kPushUpCalibrationMinExcursion) {
      return 'Range too small. Start fully extended and go to your lowest controlled push-up.';
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'topAngle': topAngle,
    'bottomAngle': bottomAngle,
    'sampleCount': sampleCount,
    'createdAt': createdAt.toIso8601String(),
    'lastUpdated': lastUpdated.toIso8601String(),
    // v2 fields (2026-05-15). Omitted from payload when null so reading
    // a freshly-serialised v2 record on an older app version that only
    // knows v1 still deserialises cleanly via the v1 fast-path below.
    if (calibrationRepCount != null) 'calibrationRepCount': calibrationRepCount,
    if (lastAppliedRepAt != null)
      'lastAppliedRepAt': lastAppliedRepAt!.toIso8601String(),
  };

  /// Deserialise a `PushUpRomProfile` from JSON.
  ///
  /// Accepts both v1 (pre-2026-05-15) and v2 schemas. v1 records have no
  /// `calibrationRepCount` or `lastAppliedRepAt` fields; those default to
  /// null and `isLegacyV1` is set true so downstream consumers (in-session
  /// refinement, recalibrate-suggestion UX) can adapt their behaviour.
  factory PushUpRomProfile.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'] as int?;
    if (version != 1 && version != schemaVersion) {
      throw StateError(
        'PushUpRomProfile schema mismatch: '
        'got=$version expected=1 or $schemaVersion',
      );
    }
    final isV1 = version == 1;
    final lastAppliedRaw = json['lastAppliedRepAt'] as String?;
    final profile = PushUpRomProfile(
      topAngle: (json['topAngle'] as num).toDouble(),
      bottomAngle: (json['bottomAngle'] as num).toDouble(),
      sampleCount: json['sampleCount'] as int? ?? 0,
      createdAt: DateTime.parse(json['createdAt'] as String),
      lastUpdated: DateTime.parse(json['lastUpdated'] as String),
      calibrationRepCount: json['calibrationRepCount'] as int?,
      lastAppliedRepAt: lastAppliedRaw != null
          ? DateTime.parse(lastAppliedRaw)
          : null,
      isLegacyV1: isV1,
    );
    final reason = validate(
      topAngle: profile.topAngle,
      bottomAngle: profile.bottomAngle,
    );
    if (reason != null) {
      throw StateError(reason);
    }
    return profile;
  }

  static double _clampDouble(double value, double min, double max) =>
      value.clamp(min, max).toDouble();
}
