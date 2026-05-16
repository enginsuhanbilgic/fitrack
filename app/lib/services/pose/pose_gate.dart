import '../../models/pose_landmark.dart';

/// Per-group evaluation result for the required-landmark gate. Carries
/// missing IDs (with parallel confidences) and a nearedge flag so the
/// caller can pick whichever group came closer to passing when reporting.
///
/// Public (extracted from the former private `_GroupEvaluation` in
/// `mlkit_pose_service.dart`) so the gate decision is unit-testable as a
/// pure function without a platform `CameraImage` — same testability
/// pattern as `view_models/telemetry/pushup_rep_line.dart`.
class GroupEvaluation {
  final List<int> missing;
  final List<double> missingConfs;
  final bool nearEdge;
  const GroupEvaluation(this.missing, this.missingConfs, this.nearEdge);
}

/// Build a type→landmark index from a detected-landmark list, **first-wins**
/// to preserve `List.firstWhere` semantics exactly.
///
/// A plain map comprehension (`{for (l in list) l.type: l}`) keeps the
/// *last* duplicate; `firstWhere` returns the *first*. ML Kit emits exactly
/// one landmark per type so duplicates never occur in practice, but
/// matching the precise semantic makes the O(1)-lookup refactor provably
/// bit-identical to the previous per-id `firstWhere` scan, not merely
/// equivalent on the happy path.
Map<int, PoseLandmark> indexByType(List<PoseLandmark> landmarks) {
  final byType = <int, PoseLandmark>{};
  for (final l in landmarks) {
    byType.putIfAbsent(l.type, () => l);
  }
  return byType;
}

/// Evaluate a single landmark group against the detected landmarks.
/// Returns the missing IDs (with parallel confidences) and a nearedge
/// flag. Pure function; no side effects.
///
/// `byType` — type→landmark map (build once per frame via [indexByType] and
/// reuse for the primary AND alternate groups, avoiding repeated O(n)
/// scans).
/// `floor` — confidence threshold for non-best-effort landmarks.
/// `bestEffort` — landmark IDs that pass the gate at half the floor
/// (e.g., wrists in side view, where ML Kit struggles at peak flexion but
/// the FSM tolerates occasional missing angle frames).
///
/// Algorithm is bit-identical to the former private
/// `MlKitPoseService._evaluateLandmarkGroup`: an absent landmark is treated
/// as the `type:-1, confidence:0` sentinel (so it lands in `missing` with a
/// `0.0` confidence); a present landmark below its effective floor lands in
/// `missing` carrying its *actual* confidence; `nearEdge` flips only for a
/// *present* landmark sitting within 5% of any image edge.
GroupEvaluation evaluateLandmarkGroup(
  Map<int, PoseLandmark> byType,
  List<int> required, {
  required double floor,
  required Set<int> bestEffort,
}) {
  final missing = <int>[];
  final missingConfs = <double>[];
  var nearEdge = false;
  for (final id in required) {
    final lm =
        byType[id] ?? const PoseLandmark(type: -1, x: 0, y: 0, confidence: 0);
    final effectiveFloor = bestEffort.contains(id) ? floor * 0.5 : floor;
    if (lm.type == -1 || lm.confidence < effectiveFloor) {
      missing.add(id);
      missingConfs.add(lm.type == -1 ? 0.0 : lm.confidence);
    }
    if (lm.type != -1) {
      if (lm.x < 0.05 || lm.x > 0.95 || lm.y < 0.05 || lm.y > 0.95) {
        nearEdge = true;
      }
    }
  }
  return GroupEvaluation(missing, missingConfs, nearEdge);
}
