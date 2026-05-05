/// Abstraction over where reference rep angle series come from.
///
/// Layer 1 ships [ConstReferenceRepSource] (hand-curated constants from T2.4).
/// Layer 2 will introduce `PersonalReferenceRepSource` backed by a SQLite
/// table, falling back to [ConstReferenceRepSource] — no engine changes needed.
library;

import '../../core/default_reference_reps.dart';
import '../../core/types.dart';

/// Returns the reference angle series for a given view, or null
/// when no reference is available for that bucket.
abstract class ReferenceRepSource {
  List<double>? forBucket(CurlCameraView view);
}

class ConstReferenceRepSource implements ReferenceRepSource {
  const ConstReferenceRepSource();

  @override
  List<double>? forBucket(CurlCameraView view) =>
      DefaultReferenceReps.forBucket(view);
}
