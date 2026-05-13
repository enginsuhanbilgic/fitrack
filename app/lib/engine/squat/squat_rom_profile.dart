/// Per-user ROM profile for squat.
///
/// Mirrors `curl_rom_profile.dart`'s shape with two structural differences:
///   - Squat has no `(side, view)` axis — there is a single bucket per user.
///   - Field names use squat-specific terminology
///     (`observedMinKneeAngle` / `observedMaxKneeAngle`) so the conceptual
///     boundary between curl's elbow-angle bucket and squat's knee-angle
///     bucket is clear at every call site.
///
/// Pure Dart — no I/O, no Flutter. The repository layer wraps this for
/// persistence (`'squat_profile_v1'` key in the `profiles` SQLite table).
library;

import '../../core/constants.dart';
import '../curl/mad_outlier.dart' as mad;

/// Outcome of applying a single squat rep's extremes to the bucket.
///
/// Mirrors `engine/curl/curl_rom_profile.dart`'s [RepApplyResult] enum
/// shape 1:1 — the same four dispositions apply (initialized, applied,
/// shrinkPending, rejectedOutlier). Squat reuses the curl semantics so
/// telemetry tags and downstream tier-resolver logic stay consistent.
enum RepApplyResult {
  /// Sample passed the outlier guard and the EMA was updated.
  applied,

  /// Sample looked like a real shrink but is awaiting confirmation
  /// (`kProfileShrinkConfirmReps` consecutive). Recent-sample buffers updated.
  shrinkPending,

  /// Sample was outside MAD threshold; nothing was updated except history.
  rejectedOutlier,

  /// First sample(s) — bucket initialized from the rep, no smoothing applied.
  initialized,
}

/// Single-bucket squat ROM bucket. One per user — there is no per-(side, view)
/// axis like curl has, so the profile owns at most one of these.
class SquatRomBucket {
  double observedMinKneeAngle;
  double observedMaxKneeAngle;

  int sampleCount;

  /// Anatomical femur/torso ratio captured during calibration, if any.
  /// Wired by the host when [SquatStrategy] reports a long-femur lock
  /// during the same session; null when the classifier never locked or
  /// when this bucket was created before Part 2 landed.
  double? femurTorsoRatio;

  DateTime lastUpdated;

  /// Recent deepest-flexion angles (bottom). Capped at [kProfileOutlierWindow].
  /// FIFO — newest appended; oldest dropped.
  final List<double> recentMinSamples;

  /// Recent standing-extension angles (top). Same cap + semantics as above.
  final List<double> recentMaxSamples;

  /// Confirm-counter for shrink direction (bottom getting shallower / top
  /// dropping). Reset on a confirming-direction rep or after the EMA fires.
  int _consecutiveShrinkCandidatesMin;
  int _consecutiveShrinkCandidatesMax;

  SquatRomBucket({
    required this.observedMinKneeAngle,
    required this.observedMaxKneeAngle,
    this.sampleCount = 0,
    this.femurTorsoRatio,
    DateTime? lastUpdated,
    List<double>? recentMinSamples,
    List<double>? recentMaxSamples,
    int consecutiveShrinkCandidatesMin = 0,
    int consecutiveShrinkCandidatesMax = 0,
  }) : lastUpdated = lastUpdated ?? DateTime.now(),
       recentMinSamples = recentMinSamples ?? <double>[],
       recentMaxSamples = recentMaxSamples ?? <double>[],
       _consecutiveShrinkCandidatesMin = consecutiveShrinkCandidatesMin,
       _consecutiveShrinkCandidatesMax = consecutiveShrinkCandidatesMax;

  /// Empty bucket initialized to the global FSM defaults. Used as a placeholder
  /// before the first rep lands.
  factory SquatRomBucket.empty() {
    return SquatRomBucket(
      observedMinKneeAngle: kSquatBottomAngle,
      observedMaxKneeAngle: kSquatStartAngle,
    );
  }

  /// Apply a rep's extremes. Returns the disposition for telemetry.
  ///
  /// - `thisRepMin`: deepest knee flexion observed during the rep (bottom).
  /// - `thisRepMax`: most extended knee angle (standing).
  ///
  /// Logic mirrors `curl_rom_profile.RomBucket.applyRep` 1:1 — same EMA
  /// asymmetry, same MAD outlier rejection, same shrink-pending semantics,
  /// same suppression of MAD when a shrink trend is already pending. The
  /// methods deliberately mirror each other; if one is fixed, fix both.
  RepApplyResult applyRep(double thisRepMin, double thisRepMax) {
    // First sample: seed the bucket, no smoothing.
    if (sampleCount == 0) {
      observedMinKneeAngle = thisRepMin;
      observedMaxKneeAngle = thisRepMax;
      _appendRecent(recentMinSamples, thisRepMin);
      _appendRecent(recentMaxSamples, thisRepMax);
      sampleCount = 1;
      lastUpdated = DateTime.now();
      return RepApplyResult.initialized;
    }

    // Outlier check uses the existing window BEFORE this sample is added.
    // Suppressed when a shrink trend is already pending — the confirm-counter
    // is the authority on real ROM shrink (vs. one-off noise), so the MAD
    // guard would otherwise reject every sample of a legitimate slow shrink.
    final isMinOutlier =
        _consecutiveShrinkCandidatesMin == 0 &&
        mad.isMadOutlier(recentMinSamples, thisRepMin);
    final isMaxOutlier =
        _consecutiveShrinkCandidatesMax == 0 &&
        mad.isMadOutlier(recentMaxSamples, thisRepMax);

    _appendRecent(recentMinSamples, thisRepMin);
    _appendRecent(recentMaxSamples, thisRepMax);

    if (isMinOutlier && isMaxOutlier) {
      return RepApplyResult.rejectedOutlier;
    }

    var didShrinkPend = false;
    var didApply = false;

    // ── Bottom side (observedMinKneeAngle = deepest knee flexion) ─────
    if (!isMinOutlier) {
      // Deeper flexion = lower angle = expand the bucket downward.
      final isExpand = thisRepMin < observedMinKneeAngle;
      if (isExpand) {
        _consecutiveShrinkCandidatesMin = 0;
        observedMinKneeAngle = _ema(
          observedMinKneeAngle,
          thisRepMin,
          kProfileExpandAlpha,
        );
        didApply = true;
      } else {
        _consecutiveShrinkCandidatesMin++;
        if (_consecutiveShrinkCandidatesMin >= kProfileShrinkConfirmReps) {
          observedMinKneeAngle = _ema(
            observedMinKneeAngle,
            thisRepMin,
            kProfileShrinkAlpha,
          );
          _consecutiveShrinkCandidatesMin = 0;
          didApply = true;
        } else {
          didShrinkPend = true;
        }
      }
    }

    // ── Top side (observedMaxKneeAngle = most extended) ────────────────
    if (!isMaxOutlier) {
      // More extended = higher angle = expand the bucket upward.
      final isExpand = thisRepMax > observedMaxKneeAngle;
      if (isExpand) {
        _consecutiveShrinkCandidatesMax = 0;
        observedMaxKneeAngle = _ema(
          observedMaxKneeAngle,
          thisRepMax,
          kProfileExpandAlpha,
        );
        didApply = true;
      } else {
        _consecutiveShrinkCandidatesMax++;
        if (_consecutiveShrinkCandidatesMax >= kProfileShrinkConfirmReps) {
          observedMaxKneeAngle = _ema(
            observedMaxKneeAngle,
            thisRepMax,
            kProfileShrinkAlpha,
          );
          _consecutiveShrinkCandidatesMax = 0;
          didApply = true;
        } else {
          didShrinkPend = true;
        }
      }
    }

    if (didApply) {
      sampleCount++;
      lastUpdated = DateTime.now();
      return RepApplyResult.applied;
    }
    if (didShrinkPend) return RepApplyResult.shrinkPending;
    return RepApplyResult.rejectedOutlier;
  }

  /// `α·new + (1−α)·old`.
  static double _ema(double prev, double sample, double alpha) =>
      alpha * sample + (1 - alpha) * prev;

  static void _appendRecent(List<double> buf, double v) {
    buf.add(v);
    if (buf.length > kProfileOutlierWindow) buf.removeAt(0);
  }

  Map<String, dynamic> toJson() => {
    'observedMinKneeAngle': observedMinKneeAngle,
    'observedMaxKneeAngle': observedMaxKneeAngle,
    'sampleCount': sampleCount,
    'femurTorsoRatio': femurTorsoRatio,
    'lastUpdated': lastUpdated.toIso8601String(),
    'recentMinSamples': recentMinSamples,
    'recentMaxSamples': recentMaxSamples,
    'shrinkMin': _consecutiveShrinkCandidatesMin,
    'shrinkMax': _consecutiveShrinkCandidatesMax,
  };

  factory SquatRomBucket.fromJson(Map<String, dynamic> j) {
    return SquatRomBucket(
      observedMinKneeAngle: (j['observedMinKneeAngle'] as num).toDouble(),
      observedMaxKneeAngle: (j['observedMaxKneeAngle'] as num).toDouble(),
      sampleCount: j['sampleCount'] as int,
      femurTorsoRatio: (j['femurTorsoRatio'] as num?)?.toDouble(),
      lastUpdated: DateTime.parse(j['lastUpdated'] as String),
      recentMinSamples: (j['recentMinSamples'] as List)
          .cast<num>()
          .map((n) => n.toDouble())
          .toList(),
      recentMaxSamples: (j['recentMaxSamples'] as List)
          .cast<num>()
          .map((n) => n.toDouble())
          .toList(),
      consecutiveShrinkCandidatesMin: j['shrinkMin'] as int? ?? 0,
      consecutiveShrinkCandidatesMax: j['shrinkMax'] as int? ?? 0,
    );
  }
}

/// Top-level squat ROM profile. One per user.
///
/// Unlike [CurlRomProfile] (which holds a `Map<key, RomBucket>` indexed by
/// `(side, view)`), squat has no such axis — there's a single nullable
/// [bucket] field exposed directly. Per simplicity review: no facade method
/// (`bucketFor()`), because there's no key to look up.
class SquatRomProfile {
  /// Bumped on any breaking change to the on-disk schema. Loader deletes the
  /// row and re-prompts on mismatch.
  static const int schemaVersion = 1;

  String userId;

  /// The user's calibrated squat bucket, or null when the user hasn't
  /// calibrated yet. Exposed directly — no facade per simplicity review.
  SquatRomBucket? bucket;

  DateTime createdAt;
  DateTime lastUsedAt;

  SquatRomProfile({
    this.userId = 'local_user',
    this.bucket,
    DateTime? createdAt,
    DateTime? lastUsedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       lastUsedAt = lastUsedAt ?? DateTime.now();

  /// True iff the bucket exists and has accumulated enough samples to drive
  /// Tier 1 in the workout view-model's threshold resolver.
  bool get isCalibrated =>
      bucket != null && bucket!.sampleCount >= kSquatCalibrationMinReps;

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'userId': userId,
    'createdAt': createdAt.toIso8601String(),
    'lastUsedAt': lastUsedAt.toIso8601String(),
    'bucket': bucket?.toJson(),
  };

  factory SquatRomProfile.fromJson(Map<String, dynamic> j) {
    final v = j['schemaVersion'] as int?;
    if (v != schemaVersion) {
      throw StateError(
        'SquatRomProfile schema mismatch: got=$v expected=$schemaVersion',
      );
    }
    final bucketJson = j['bucket'] as Map<String, dynamic>?;
    return SquatRomProfile(
      userId: j['userId'] as String? ?? 'local_user',
      createdAt: DateTime.parse(j['createdAt'] as String),
      lastUsedAt: DateTime.parse(j['lastUsedAt'] as String),
      bucket: bucketJson == null ? null : SquatRomBucket.fromJson(bucketJson),
    );
  }
}
