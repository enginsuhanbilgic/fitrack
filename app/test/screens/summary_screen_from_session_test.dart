import 'package:fitrack/core/types.dart';
import 'package:fitrack/screens/summary_screen.dart';
import 'package:fitrack/services/db/session_dtos.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure-Dart unit tests for `SummaryScreen.fromSession`.
///
/// Per project rule (CLAUDE.md ⛔ Test Writing Hard Rules), no widget tests.
/// `SummaryScreen` is a `StatefulWidget`, so the test constructs it and
/// reads its public fields — it never calls `pumpWidget`.
///
/// These tests pin the reconstruction contract that the unified Session
/// Complete page relies on: history-reopened squat sessions must surface
/// `squatRepMetrics` (audit precondition) and push-up sessions must
/// surface min/max angles via `curlRepRecords` (audit precondition).
///
/// History of the bug guarded here: pre-2026-05-13, `fromSession` filtered
/// every push-up rep out of `curlRepRecords` (because `RepRow.toCurlRepRecord`
/// requires `side` / `view` / `source` and push-up rows have all three
/// NULL) and never reconstructed `squatRepMetrics` at all. The Form Audit
/// card showed "No reps recorded" on every reopened squat or push-up,
/// even though the data sat in the database.
SessionSummary _summary(ExerciseType exercise, {int totalReps = 5}) {
  return SessionSummary(
    id: 1,
    exercise: exercise,
    startedAt: DateTime.fromMillisecondsSinceEpoch(0),
    duration: const Duration(minutes: 5),
    totalReps: totalReps,
    totalSets: 1,
    fatigueDetected: false,
    asymmetryDetected: false,
  );
}

RepRow _squatRep(
  int i, {
  double minAngle = 90,
  double maxAngle = 170,
  SquatVariant variant = SquatVariant.bodyweight,
  double leanDeg = 25,
  double kneeShift = 0.12,
  double heelLift = 0.03,
}) => RepRow(
  repIndex: i,
  quality: 0.85,
  minAngle: minAngle,
  maxAngle: maxAngle,
  squatLeanDeg: leanDeg,
  squatKneeShiftRatio: kneeShift,
  squatHeelLiftRatio: heelLift,
  squatVariant: variant,
  squatMinKneeAngle: minAngle,
  squatMaxKneeAngle: maxAngle,
);

RepRow _pushUpRep(int i, {double minAngle = 95, double maxAngle = 160}) =>
    RepRow(repIndex: i, quality: 0.80, minAngle: minAngle, maxAngle: maxAngle);

void main() {
  group('SummaryScreen.fromSession — squat reconstruction', () {
    test('reconstructs squatRepMetrics from persisted columns', () {
      final detail = SessionDetail(
        summary: _summary(ExerciseType.squat, totalReps: 3),
        eccentricTooFastCount: 0,
        reps: [_squatRep(1), _squatRep(2), _squatRep(3)],
        formErrors: const {},
      );

      final widget = SummaryScreen.fromSession(detail);

      expect(widget.squatRepMetrics, hasLength(3));
      expect(widget.squatRepMetrics.first.repIndex, 1);
      expect(widget.squatRepMetrics.first.leanDeg, 25);
      expect(widget.squatRepMetrics.first.kneeShiftRatio, 0.12);
      expect(widget.squatRepMetrics.first.heelLiftRatio, 0.03);
      expect(widget.squatRepMetrics.first.minKneeAngle, 90);
      expect(widget.squatRepMetrics.first.maxKneeAngle, 170);
    });

    test('recovers squatVariant from the first non-null rep row', () {
      final detail = SessionDetail(
        summary: _summary(ExerciseType.squat),
        eccentricTooFastCount: 0,
        reps: [_squatRep(1, variant: SquatVariant.highBarBackSquat)],
        formErrors: const {},
      );

      final widget = SummaryScreen.fromSession(detail);

      expect(widget.squatVariant, SquatVariant.highBarBackSquat);
    });

    test('defaults squatVariant to bodyweight when no rep carries the column '
        '(pre-v3 sessions)', () {
      final detail = SessionDetail(
        summary: _summary(ExerciseType.squat),
        eccentricTooFastCount: 0,
        reps: [
          const RepRow(repIndex: 1, quality: 0.8, minAngle: 90, maxAngle: 170),
        ],
        formErrors: const {},
      );

      final widget = SummaryScreen.fromSession(detail);

      expect(widget.squatVariant, SquatVariant.bodyweight);
    });

    test('rep with no squat columns is filtered out of squatRepMetrics', () {
      // Mixed: one valid squat row + one row with no squat data at all.
      // The second row should NOT produce a SquatRepMetrics entry — the
      // audit needs at least one populated field to grade a rep.
      final detail = SessionDetail(
        summary: _summary(ExerciseType.squat, totalReps: 2),
        eccentricTooFastCount: 0,
        reps: [_squatRep(1), const RepRow(repIndex: 2, quality: 0.8)],
        formErrors: const {},
      );

      final widget = SummaryScreen.fromSession(detail);

      expect(widget.squatRepMetrics, hasLength(1));
      expect(widget.squatRepMetrics.single.repIndex, 1);
    });

    test('non-squat exercise does not populate squatRepMetrics', () {
      // Defensive: even if a curl session row somehow had squat columns
      // (shouldn't happen, but the constructor doesn't enforce it), the
      // factory must not surface them. Mirrors the bicepsSideRepMetrics
      // exercise-gated branch.
      final detail = SessionDetail(
        summary: _summary(ExerciseType.bicepsCurlSide),
        eccentricTooFastCount: 0,
        reps: [_squatRep(1)],
        formErrors: const {},
      );

      final widget = SummaryScreen.fromSession(detail);

      expect(widget.squatRepMetrics, isEmpty);
    });
  });

  group('SummaryScreen.fromSession — push-up reconstruction', () {
    test('reconstructs CurlRepRecord list from persisted min/max angles', () {
      final detail = SessionDetail(
        summary: _summary(ExerciseType.pushUp, totalReps: 3),
        eccentricTooFastCount: 0,
        reps: [
          _pushUpRep(1, minAngle: 92, maxAngle: 158),
          _pushUpRep(2, minAngle: 90, maxAngle: 162),
          _pushUpRep(3, minAngle: 88, maxAngle: 165),
        ],
        formErrors: const {},
      );

      final widget = SummaryScreen.fromSession(detail);

      expect(widget.curlRepRecords, hasLength(3));
      expect(widget.curlRepRecords.first.minAngle, 92);
      expect(widget.curlRepRecords.first.maxAngle, 158);
      // Sentinel side/view — push-up isn't sided. The audit ignores these
      // fields; the test pins them so a future change won't silently break
      // a curl path that happens to inherit a CurlRepRecord originally
      // produced for a push-up.
      expect(widget.curlRepRecords.first.side, ProfileSide.right);
      expect(widget.curlRepRecords.first.view, CurlCameraView.unknown);
    });

    test('reps missing min or max angle are dropped from the audit list', () {
      final detail = SessionDetail(
        summary: _summary(ExerciseType.pushUp, totalReps: 3),
        eccentricTooFastCount: 0,
        reps: [
          _pushUpRep(1),
          const RepRow(repIndex: 2, minAngle: null, maxAngle: 150),
          const RepRow(repIndex: 3, minAngle: 90, maxAngle: null),
        ],
        formErrors: const {},
      );

      final widget = SummaryScreen.fromSession(detail);

      expect(widget.curlRepRecords, hasLength(1));
      expect(widget.curlRepRecords.single.repIndex, 1);
    });

    test('non-push-up exercise routes through the curl reconstruction', () {
      // Curl rows have side/view/source non-null; non-curl rows pre-fix
      // were filtered out. Pin the behavior so the curl path still works.
      final detail = SessionDetail(
        summary: _summary(ExerciseType.bicepsCurlSide),
        eccentricTooFastCount: 0,
        reps: [
          const RepRow(
            repIndex: 1,
            quality: 0.85,
            minAngle: 50,
            maxAngle: 165,
            side: ProfileSide.right,
            view: CurlCameraView.sideRight,
            source: ThresholdSource.calibrated,
            bucketUpdated: true,
            rejectedOutlier: false,
          ),
        ],
        formErrors: const {},
      );

      final widget = SummaryScreen.fromSession(detail);

      expect(widget.curlRepRecords, hasLength(1));
      expect(widget.curlRepRecords.single.view, CurlCameraView.sideRight);
    });
  });
}
