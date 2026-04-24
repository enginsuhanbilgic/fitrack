/// Per-user ROM profile for biceps curl.
///
/// A profile is a sparse map of buckets keyed by `(side, view)`. Each bucket
/// owns the smoothed `(observedMinAngle, observedMaxAngle)` for its slice of
/// the user's anatomy + camera framing. Buckets update via asymmetric EMA
/// guarded by median+MAD outlier rejection.
///
/// Pure Dart — no I/O, no Flutter. The store layer wraps this for persistence.
library;

import '../../core/constants.dart';
import '../../core/rom_thresholds.dart';
import '../../core/types.dart';
import 'mad_outlier.dart' as mad;

/// Outcome of applying a single rep's extremes to a bucket.
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

class RomBucket implements RomBucketLike {
  final ProfileSide side;
  final CurlCameraView view;

  @override
  double observedMinAngle;
  @override
  double observedMaxAngle;

  int sampleCount;
  DateTime lastUpdated;

  /// Recent peaks (deepest flexion). Capped at [kProfileOutlierWindow].
  /// FIFO — newest appended; oldest dropped.
  final List<double> recentMinSamples;

  /// Recent rests (most extended). Same cap + semantics as above.
  final List<double> recentMaxSamples;

  /// Confirm-counter for shrink direction (peak getting shallower / rest dropping).
  int _consecutiveShrinkCandidatesMin;
  int _consecutiveShrinkCandidatesMax;

  RomBucket({
    required this.side,
    required this.view,
    required this.observedMinAngle,
    required this.observedMaxAngle,
    this.sampleCount = 0,
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

  /// Empty bucket initialized to the global constants. Used as a placeholder
  /// before the first rep lands.
  factory RomBucket.empty(ProfileSide side, CurlCameraView view) {
    return RomBucket(
      side: side,
      view: view,
      observedMinAngle: kCurlPeakAngle,
      observedMaxAngle: kCurlStartAngle,
    );
  }

  /// Stable key for storage in [CurlRomProfile.buckets].
  static String keyFor(ProfileSide side, CurlCameraView view) =>
      '${side.name}_${view.name}';

  String get key => keyFor(side, view);

  /// Apply a rep's extremes. Returns the disposition for telemetry.
  ///
  /// - `thisRepMin`: deepest flexion observed during the rep (peak end).
  /// - `thisRepMax`: most extended angle at rep start (rest end).
  ///
  /// Calls are independent per dimension — peak-only or rest-only updates are
  /// possible. The bucket records both regardless because they share state.
  RepApplyResult applyRep(double thisRepMin, double thisRepMax) {
    // First sample: seed the bucket from the rep, no smoothing.
    if (sampleCount == 0) {
      observedMinAngle = thisRepMin;
      observedMaxAngle = thisRepMax;
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

    // Always remember the sample in the recent window (bounded), so future
    // distribution shifts are detectable. But don't apply EMA if outlier.
    _appendRecent(recentMinSamples, thisRepMin);
    _appendRecent(recentMaxSamples, thisRepMax);

    if (isMinOutlier && isMaxOutlier) {
      return RepApplyResult.rejectedOutlier;
    }

    var didShrinkPend = false;
    var didApply = false;

    // ── Peak side (observedMinAngle = deepest flexion) ─────────
    if (!isMinOutlier) {
      // Deeper flexion = lower angle = expand the bucket downward.
      final isExpand = thisRepMin < observedMinAngle;
      if (isExpand) {
        _consecutiveShrinkCandidatesMin = 0;
        observedMinAngle = _ema(
          observedMinAngle,
          thisRepMin,
          kProfileExpandAlpha,
        );
        didApply = true;
      } else {
        _consecutiveShrinkCandidatesMin++;
        if (_consecutiveShrinkCandidatesMin >= kProfileShrinkConfirmReps) {
          observedMinAngle = _ema(
            observedMinAngle,
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

    // ── Rest side (observedMaxAngle = most extended) ──────────
    if (!isMaxOutlier) {
      // More extended = higher angle = expand the bucket upward.
      final isExpand = thisRepMax > observedMaxAngle;
      if (isExpand) {
        _consecutiveShrinkCandidatesMax = 0;
        observedMaxAngle = _ema(
          observedMaxAngle,
          thisRepMax,
          kProfileExpandAlpha,
        );
        didApply = true;
      } else {
        _consecutiveShrinkCandidatesMax++;
        if (_consecutiveShrinkCandidatesMax >= kProfileShrinkConfirmReps) {
          observedMaxAngle = _ema(
            observedMaxAngle,
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
    // Both dimensions outlier-rejected.
    return RepApplyResult.rejectedOutlier;
  }

  /// `α·new + (1−α)·old`.
  static double _ema(double prev, double sample, double alpha) =>
      alpha * sample + (1 - alpha) * prev;

  static void _appendRecent(List<double> buf, double v) {
    buf.add(v);
    if (buf.length > kProfileOutlierWindow) buf.removeAt(0);
  }

  // ── (De)serialization ──────────────────────────────────
  Map<String, dynamic> toJson() => {
    'side': side.name,
    'view': view.name,
    'observedMinAngle': observedMinAngle,
    'observedMaxAngle': observedMaxAngle,
    'sampleCount': sampleCount,
    'lastUpdated': lastUpdated.toIso8601String(),
    'recentMinSamples': recentMinSamples,
    'recentMaxSamples': recentMaxSamples,
    'shrinkMin': _consecutiveShrinkCandidatesMin,
    'shrinkMax': _consecutiveShrinkCandidatesMax,
  };

  factory RomBucket.fromJson(Map<String, dynamic> j) {
    return RomBucket(
      side: ProfileSide.values.byName(j['side'] as String),
      view: CurlCameraView.values.byName(j['view'] as String),
      observedMinAngle: (j['observedMinAngle'] as num).toDouble(),
      observedMaxAngle: (j['observedMaxAngle'] as num).toDouble(),
      sampleCount: j['sampleCount'] as int,
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

class CurlRomProfile {
  /// Bumped on any breaking change to the on-disk schema. Loader deletes the
  /// file and re-prompts on mismatch.
  static const int schemaVersion = 1;

  String userId;
  Map<String, RomBucket> buckets;
  DateTime createdAt;
  DateTime lastUsedAt;

  CurlRomProfile({
    this.userId = 'local_user',
    Map<String, RomBucket>? buckets,
    DateTime? createdAt,
    DateTime? lastUsedAt,
  }) : buckets = buckets ?? <String, RomBucket>{},
       createdAt = createdAt ?? DateTime.now(),
       lastUsedAt = lastUsedAt ?? DateTime.now();

  RomBucket? bucketFor(ProfileSide side, CurlCameraView view) =>
      buckets[RomBucket.keyFor(side, view)];

  /// Returns the existing bucket or a fresh empty one. The empty bucket is
  /// **NOT** automatically inserted — caller decides whether to keep it.
  RomBucket bucketOrEmpty(ProfileSide side, CurlCameraView view) =>
      buckets[RomBucket.keyFor(side, view)] ?? RomBucket.empty(side, view);

  void upsertBucket(RomBucket b) {
    buckets[b.key] = b;
    lastUsedAt = DateTime.now();
  }

  /// True iff this bucket has enough samples to drive `RomThresholds.fromBucket`.
  bool isCalibrated(ProfileSide side, CurlCameraView view) {
    final b = bucketFor(side, view);
    return b != null && b.sampleCount >= kCalibrationMinReps;
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'userId': userId,
    'createdAt': createdAt.toIso8601String(),
    'lastUsedAt': lastUsedAt.toIso8601String(),
    'buckets': buckets.values.map((b) => b.toJson()).toList(),
  };

  factory CurlRomProfile.fromJson(Map<String, dynamic> j) {
    final v = j['schemaVersion'] as int?;
    if (v != schemaVersion) {
      throw StateError(
        'CurlRomProfile schema mismatch: got=$v expected=$schemaVersion',
      );
    }
    final bucketsList = (j['buckets'] as List).cast<Map<String, dynamic>>().map(
      RomBucket.fromJson,
    );
    final byKey = <String, RomBucket>{};
    for (final b in bucketsList) {
      byKey[b.key] = b;
    }
    return CurlRomProfile(
      userId: j['userId'] as String? ?? 'local_user',
      createdAt: DateTime.parse(j['createdAt'] as String),
      lastUsedAt: DateTime.parse(j['lastUsedAt'] as String),
      buckets: byKey,
    );
  }
}

/// Compact summary used by Settings → Diagnostics.
class ProfileSummary {
  final int totalBuckets;
  final int calibratedBuckets;
  final DateTime? oldest;
  final DateTime? newest;

  const ProfileSummary({
    required this.totalBuckets,
    required this.calibratedBuckets,
    this.oldest,
    this.newest,
  });

  factory ProfileSummary.of(CurlRomProfile p) {
    if (p.buckets.isEmpty) {
      return const ProfileSummary(totalBuckets: 0, calibratedBuckets: 0);
    }
    final updates = p.buckets.values.map((b) => b.lastUpdated).toList();
    return ProfileSummary(
      totalBuckets: p.buckets.length,
      calibratedBuckets: p.buckets.values
          .where((b) => b.sampleCount >= kCalibrationMinReps)
          .length,
      oldest: updates.reduce((a, b) => a.isBefore(b) ? a : b),
      newest: updates.reduce((a, b) => a.isAfter(b) ? a : b),
    );
  }
}
