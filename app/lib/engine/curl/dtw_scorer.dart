import 'dart:math' as math;

/// Result of a DTW comparison between a candidate rep trace and a reference.
class DtwScore {
  const DtwScore({required this.similarity, required this.rawDistance});

  /// 0.0 (no match) → 1.0 (perfect match). Clamped. Safe to display as %.
  final double similarity;

  /// Unnormalized accumulated warp distance. Exposed for diagnostics.
  final double rawDistance;
}

/// Dynamic Time Warping scorer for per-rep angle traces.
///
/// Both series are normalized and resampled to [_kResampleLength] samples
/// before comparison so amplitude scale and capture-rate differences don't
/// dominate the score. The Sakoe-Chiba band (width [_kBandWidth]) limits
/// warping to near-diagonal paths — O(n × band) instead of O(n²), and
/// prevents degenerate alignments.
class DtwScorer {
  static const int _kResampleLength = 64;
  static const int _kBandWidth = 8;

  DtwScore score(List<double> candidate, List<double> reference) {
    final c = _prepareTrace(candidate);
    final r = _prepareTrace(reference);

    if (c == null || r == null) {
      return const DtwScore(similarity: 0, rawDistance: double.infinity);
    }

    final raw = _dtw(c, r);
    // Normalize by series length so short and long reps are comparable.
    final normalized = raw / _kResampleLength;
    final similarity = (1.0 / (1.0 + normalized)).clamp(0.0, 1.0);
    return DtwScore(similarity: similarity, rawDistance: raw);
  }

  /// Normalize amplitude to [0, 1] and resample to [_kResampleLength] points.
  /// Returns null when the series is too short to be meaningful (< 2 samples).
  List<double>? _prepareTrace(List<double> raw) {
    if (raw.length < 2) return null;

    final minV = raw.reduce(math.min);
    final maxV = raw.reduce(math.max);
    final range = maxV - minV;

    // Flat trace (zero range) — normalize to all-zeros rather than crashing.
    final normalized = range < 1e-9
        ? List<double>.filled(raw.length, 0.0)
        : raw.map((v) => (v - minV) / range).toList(growable: false);

    return _linearResample(normalized, _kResampleLength);
  }

  /// Linear interpolation resample to exactly [targetLen] samples.
  List<double> _linearResample(List<double> src, int targetLen) {
    if (src.length == targetLen) return List<double>.from(src);
    final out = List<double>.filled(targetLen, 0.0);
    final step = (src.length - 1) / (targetLen - 1);
    for (var i = 0; i < targetLen; i++) {
      final pos = i * step;
      final lo = pos.floor().clamp(0, src.length - 2);
      final hi = lo + 1;
      final t = pos - lo;
      out[i] = src[lo] * (1.0 - t) + src[hi] * t;
    }
    return out;
  }

  /// Wagner-Fischer DP with Sakoe-Chiba band.
  double _dtw(List<double> a, List<double> b) {
    final n = a.length; // == b.length == _kResampleLength
    // Use two rows to keep memory O(n) instead of O(n²).
    var prev = List<double>.filled(n, double.infinity);
    var curr = List<double>.filled(n, double.infinity);
    prev[0] = (a[0] - b[0]).abs();

    for (var i = 1; i < n; i++) {
      final jMin = math.max(0, i - _kBandWidth);
      final jMax = math.min(n - 1, i + _kBandWidth);
      curr.fillRange(0, n, double.infinity);
      for (var j = jMin; j <= jMax; j++) {
        final cost = (a[i] - b[j]).abs();
        final above = prev[j]; // came from row i-1
        final left = j > 0 ? curr[j - 1] : double.infinity;
        final diag = j > 0 ? prev[j - 1] : double.infinity;
        curr[j] = cost + [above, left, diag].reduce(math.min);
      }
      // Swap rows.
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[n - 1];
  }
}
