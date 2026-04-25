/// Hand-curated median good-rep angle series per (view, side) bucket.
///
/// Derived from the T2.4 dataset (tools/dataset_analysis/):
///   - 'front:both' — median of n=9 good reps, front-view bilateral curls
///   - 'side:left'  — median of n=4 good reps, side-view left-arm curls
///   - 'side:right' — not yet in dataset; returns null (ConstReferenceRepSource
///                    falls back gracefully)
///
/// Each series is a 64-sample normalized elbow-angle trace (degrees, raw —
/// not amplitude-normalized; DtwScorer normalizes at score time).
///
/// A follow-up will extend tools/dataset_analysis/scripts/generate_dart_v2.py
/// to emit this file automatically from Phase D median-good-rep selection.
library;

import 'types.dart';

class DefaultReferenceReps {
  DefaultReferenceReps._();

  static const Map<String, List<double>> _data = {
    // Front view, bilateral — 9 good reps from front_good clip.
    // Trace: starts near full extension (~160°), curls to peak (~40°), returns.
    'front:both': [
      158.2,
      155.6,
      150.1,
      143.4,
      135.8,
      127.2,
      118.9,
      110.3,
      101.7,
      93.4,
      85.6,
      78.1,
      71.3,
      65.2,
      59.8,
      55.1,
      51.3,
      48.2,
      45.8,
      43.9,
      42.6,
      41.8,
      41.3,
      41.1,
      41.2,
      41.8,
      42.9,
      44.6,
      47.1,
      50.3,
      54.2,
      58.8,
      63.9,
      69.4,
      75.1,
      80.9,
      86.7,
      92.4,
      98.0,
      103.4,
      108.5,
      113.3,
      117.8,
      121.9,
      125.6,
      129.0,
      132.1,
      134.9,
      137.4,
      139.7,
      141.8,
      143.7,
      145.4,
      147.0,
      148.5,
      149.8,
      151.1,
      152.2,
      153.3,
      154.2,
      155.1,
      155.9,
      156.6,
      157.2,
    ],
    // Side view, left arm — 4 good reps from side_good clip.
    // Trace: starts near full extension (~165°), curls to peak (~38°), returns.
    'side:left': [
      164.1,
      161.3,
      156.8,
      150.4,
      142.9,
      134.3,
      125.2,
      115.8,
      106.4,
      97.2,
      88.4,
      80.1,
      72.5,
      65.7,
      59.8,
      54.7,
      50.4,
      46.9,
      44.1,
      42.0,
      40.5,
      39.5,
      38.9,
      38.7,
      38.8,
      39.4,
      40.5,
      42.2,
      44.6,
      47.7,
      51.5,
      55.9,
      60.9,
      66.3,
      72.0,
      77.9,
      83.8,
      89.6,
      95.2,
      100.6,
      105.7,
      110.5,
      115.0,
      119.1,
      122.9,
      126.4,
      129.6,
      132.5,
      135.1,
      137.5,
      139.7,
      141.7,
      143.5,
      145.1,
      146.6,
      148.0,
      149.3,
      150.5,
      151.6,
      152.6,
      153.5,
      154.4,
      155.2,
      155.9,
    ],
  };

  /// Returns the reference series for the given view bucket, or null
  /// when no reference exists for that view.
  static List<double>? forBucket(CurlCameraView view) {
    return switch (view) {
      CurlCameraView.front => _data['front:both'],
      CurlCameraView.sideLeft => _data['side:left'],
      CurlCameraView.sideRight => _data['side:right'],
      CurlCameraView.unknown => null,
    };
  }
}
