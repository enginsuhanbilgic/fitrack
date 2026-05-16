/// Equivalence tests for the extracted required-landmark gate
/// (`lib/services/pose/pose_gate.dart`).
///
/// Phase 2 of the perf pass replaced a per-id `landmarks.firstWhere(...)`
/// linear scan inside `MlKitPoseService` with an O(1) map lookup via
/// `indexByType` + `evaluateLandmarkGroup`. The safety claim is that the
/// refactor is **bit-identical** to the old code, not merely "equivalent
/// on the happy path".
///
/// To prove that, each test runs a `_referenceFirstWhere` implementation —
/// the exact pre-refactor algorithm copied verbatim — and asserts the new
/// function produces the SAME `missing` / `missingConfs` / `nearEdge` for
/// the same input. A divergence here means the perf refactor changed the
/// body-frame gate (which feeds the engine), and must block.
///
/// Pure-Dart — `flutter_test` only for `group` / `test` / `expect`
/// (no `pumpWidget`). Satisfies the "no widget tests" hard rule by
/// construction (the gate logic was extracted as a top-level pure function
/// precisely so it is testable without a platform `CameraImage`).
library;

import 'package:fitrack/models/pose_landmark.dart';
import 'package:fitrack/services/pose/pose_gate.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verbatim copy of the pre-refactor private `_evaluateLandmarkGroup`
/// (List + firstWhere). The new code must match this exactly.
GroupEvaluation _referenceFirstWhere(
  List<PoseLandmark> landmarks,
  List<int> required, {
  required double floor,
  required Set<int> bestEffort,
}) {
  final missing = <int>[];
  final missingConfs = <double>[];
  var nearEdge = false;
  for (final id in required) {
    final lm = landmarks.firstWhere(
      (l) => l.type == id,
      orElse: () => const PoseLandmark(type: -1, x: 0, y: 0, confidence: 0),
    );
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

PoseLandmark _lm(
  int type, {
  double x = 0.5,
  double y = 0.5,
  double confidence = 0.9,
}) => PoseLandmark(type: type, x: x, y: y, confidence: confidence);

void _expectEquivalent(
  List<PoseLandmark> landmarks,
  List<int> required, {
  required double floor,
  required Set<int> bestEffort,
}) {
  final actual = evaluateLandmarkGroup(
    indexByType(landmarks),
    required,
    floor: floor,
    bestEffort: bestEffort,
  );
  final ref = _referenceFirstWhere(
    landmarks,
    required,
    floor: floor,
    bestEffort: bestEffort,
  );
  expect(actual.missing, ref.missing, reason: 'missing must match firstWhere');
  expect(
    actual.missingConfs,
    ref.missingConfs,
    reason: 'missingConfs must match firstWhere (parallel to missing)',
  );
  expect(
    actual.nearEdge,
    ref.nearEdge,
    reason: 'nearEdge must match firstWhere',
  );
}

void main() {
  group('indexByType', () {
    test('maps each type to its landmark', () {
      final map = indexByType([_lm(11), _lm(13), _lm(15)]);
      expect(map.keys.toSet(), {11, 13, 15});
      expect(map[13]!.type, 13);
    });

    test('first-wins on duplicate type (matches List.firstWhere)', () {
      final first = _lm(11, confidence: 0.91);
      final second = _lm(11, confidence: 0.22);
      final map = indexByType([first, second]);
      // firstWhere returns `first`; the map must too.
      expect(identical(map[11], first), isTrue);
      expect(map[11]!.confidence, 0.91);
    });

    test('empty list → empty map', () {
      expect(indexByType(const <PoseLandmark>[]), isEmpty);
    });
  });

  group('evaluateLandmarkGroup — equivalence to firstWhere', () {
    const floor = 0.3;

    test('all required present & above floor → nothing missing', () {
      _expectEquivalent(
        [_lm(11), _lm(13), _lm(15)],
        const [11, 13, 15],
        floor: floor,
        bestEffort: const {},
      );
    });

    test('one required absent → sentinel path (id missing, conf 0.0)', () {
      final r = evaluateLandmarkGroup(
        indexByType([_lm(11), _lm(13)]),
        const [11, 13, 15],
        floor: floor,
        bestEffort: const {},
      );
      expect(r.missing, [15]);
      expect(r.missingConfs, [0.0]);
      _expectEquivalent(
        [_lm(11), _lm(13)],
        const [11, 13, 15],
        floor: floor,
        bestEffort: const {},
      );
    });

    test('present but below floor → missing carries ACTUAL conf', () {
      final r = evaluateLandmarkGroup(
        indexByType([_lm(11), _lm(13, confidence: 0.12)]),
        const [11, 13],
        floor: floor,
        bestEffort: const {},
      );
      expect(r.missing, [13]);
      // Not 0.0 — the real confidence, distinguishing "uncertain" from
      // "absent" for the telemetry warning.
      expect(r.missingConfs, [0.12]);
      _expectEquivalent(
        [_lm(11), _lm(13, confidence: 0.12)],
        const [11, 13],
        floor: floor,
        bestEffort: const {},
      );
    });

    test('bestEffort landmark passes at exactly 0.5×floor', () {
      // floor 0.3 → effective 0.15 for bestEffort. conf 0.15 is NOT < 0.15.
      _expectEquivalent(
        [_lm(11), _lm(15, confidence: 0.15)],
        const [11, 15],
        floor: floor,
        bestEffort: const {15},
      );
      final r = evaluateLandmarkGroup(
        indexByType([_lm(11), _lm(15, confidence: 0.15)]),
        const [11, 15],
        floor: floor,
        bestEffort: const {15},
      );
      expect(r.missing, isEmpty);
    });

    test('bestEffort landmark just below 0.5×floor → missing', () {
      _expectEquivalent(
        [_lm(11), _lm(15, confidence: 0.149)],
        const [11, 15],
        floor: floor,
        bestEffort: const {15},
      );
      final r = evaluateLandmarkGroup(
        indexByType([_lm(11), _lm(15, confidence: 0.149)]),
        const [11, 15],
        floor: floor,
        bestEffort: const {15},
      );
      expect(r.missing, [15]);
    });

    test('nearEdge fires for each edge band on a PRESENT landmark', () {
      for (final pos in [
        (x: 0.04, y: 0.5), // left
        (x: 0.96, y: 0.5), // right
        (x: 0.5, y: 0.04), // top
        (x: 0.5, y: 0.96), // bottom
      ]) {
        final lms = [_lm(11, x: pos.x, y: pos.y)];
        _expectEquivalent(lms, const [11], floor: floor, bestEffort: const {});
        final r = evaluateLandmarkGroup(
          indexByType(lms),
          const [11],
          floor: floor,
          bestEffort: const {},
        );
        expect(r.nearEdge, isTrue, reason: 'edge at $pos');
      }
    });

    test('absent landmark NEVER sets nearEdge', () {
      final r = evaluateLandmarkGroup(
        indexByType(const <PoseLandmark>[]),
        const [11],
        floor: floor,
        bestEffort: const {},
      );
      expect(r.nearEdge, isFalse);
      expect(r.missing, [11]);
      _expectEquivalent(
        const <PoseLandmark>[],
        const [11],
        floor: floor,
        bestEffort: const {},
      );
    });

    test('missing / missingConfs preserve required iteration order', () {
      final lms = [_lm(13)]; // only 13 present
      final r = evaluateLandmarkGroup(
        indexByType(lms),
        const [15, 13, 11], // deliberately unordered
        floor: floor,
        bestEffort: const {},
      );
      expect(r.missing, [15, 11]); // 13 present → skipped; order kept
      expect(r.missingConfs, [0.0, 0.0]);
      _expectEquivalent(
        lms,
        const [15, 13, 11],
        floor: floor,
        bestEffort: const {},
      );
    });
  });
}
