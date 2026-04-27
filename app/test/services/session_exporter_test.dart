import 'dart:io';

import 'package:fitrack/core/types.dart';
import 'package:fitrack/services/db/session_dtos.dart';
import 'package:fitrack/services/db/session_repository.dart';
import 'package:fitrack/services/session_exporter.dart';
import 'package:fitrack/view_models/workout_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

WorkoutCompletedEvent _curlEvent({
  int reps = 2,
  Set<FormError> errors = const {},
  bool fatigue = false,
  bool asymmetry = false,
  CurlCameraView detectedView = CurlCameraView.front,
}) {
  final records = List<CurlRepRecord>.generate(
    reps,
    (i) => CurlRepRecord(
      repIndex: i + 1,
      side: i.isEven ? ProfileSide.left : ProfileSide.right,
      view: detectedView,
      minAngle: 50.0 + i,
      maxAngle: 160.0 + i,
      source: ThresholdSource.calibrated,
      bucketUpdated: true,
      rejectedOutlier: false,
    ),
  );
  final qualities = List<double>.generate(reps, (i) => 0.80 + 0.01 * i);
  return WorkoutCompletedEvent(
    exercise: ExerciseType.bicepsCurl,
    totalReps: reps,
    totalSets: 1,
    sessionDuration: const Duration(seconds: 45),
    averageQuality: qualities.reduce((a, b) => a + b) / qualities.length,
    detectedView: detectedView,
    repQualities: qualities,
    fatigueDetected: fatigue,
    asymmetryDetected: asymmetry,
    eccentricTooFastCount: 0,
    errorsTriggered: errors,
    curlRepRecords: records,
    curlBucketSummaries: const [],
  );
}

void main() {
  group('SessionExporter — sessionsCsv format', () {
    test('emits the canonical header on the first line', () {
      final csv = SessionExporter.sessionsCsv(const []);
      expect(
        csv.split('\n').first,
        'id,exercise,started_at,duration_seconds,total_reps,total_sets,'
        'average_quality,detected_view,fatigue_detected,asymmetry_detected',
      );
    });

    test('empty list produces header-only output', () {
      final csv = SessionExporter.sessionsCsv(const []);
      // header + trailing newline = 2 elements when split.
      expect(csv.split('\n'), hasLength(2));
      expect(csv.split('\n').last, isEmpty);
    });

    test(
      'serializes enum names (not indices) for exercise + detected_view',
      () {
        final csv = SessionExporter.sessionsCsv([
          SessionSummary(
            id: 1,
            exercise: ExerciseType.bicepsCurl,
            startedAt: DateTime.utc(2026, 4, 25, 14, 32),
            duration: const Duration(seconds: 45),
            totalReps: 8,
            totalSets: 1,
            averageQuality: 0.875,
            detectedView: CurlCameraView.front,
            fatigueDetected: false,
            asymmetryDetected: false,
          ),
        ]);
        final row = csv.split('\n')[1];
        expect(row.contains(',bicepsCurl,'), isTrue);
        expect(row.contains(',front,'), isTrue);
      },
    );

    test('booleans serialize as 0/1', () {
      final csv = SessionExporter.sessionsCsv([
        SessionSummary(
          id: 1,
          exercise: ExerciseType.bicepsCurl,
          startedAt: DateTime.utc(2026, 4, 25),
          duration: const Duration(seconds: 30),
          totalReps: 5,
          totalSets: 1,
          fatigueDetected: true,
          asymmetryDetected: true,
        ),
      ]);
      final row = csv.split('\n')[1];
      // Last two columns are fatigue, asymmetry.
      expect(row.endsWith(',1,1'), isTrue);
    });

    test('null detected_view emits empty field, not "null"', () {
      final csv = SessionExporter.sessionsCsv([
        SessionSummary(
          id: 1,
          exercise: ExerciseType.squat,
          startedAt: DateTime.utc(2026, 4, 25),
          duration: const Duration(seconds: 30),
          totalReps: 5,
          totalSets: 1,
          fatigueDetected: false,
          asymmetryDetected: false,
        ),
      ]);
      final row = csv.split('\n')[1];
      expect(
        row.contains('null'),
        isFalse,
        reason: 'null fields must serialize as empty, not the string "null"',
      );
      // Two consecutive commas where detected_view sits.
      expect(row, contains(',,'));
    });

    test('startedAt serializes as ISO8601 UTC', () {
      final csv = SessionExporter.sessionsCsv([
        SessionSummary(
          id: 1,
          exercise: ExerciseType.bicepsCurl,
          // Local time input.
          startedAt: DateTime(2026, 4, 25, 14, 32, 7),
          duration: const Duration(seconds: 30),
          totalReps: 5,
          totalSets: 1,
          fatigueDetected: false,
          asymmetryDetected: false,
        ),
      ]);
      final row = csv.split('\n')[1];
      // Must contain a 'Z' (UTC) and 'T' (ISO8601 separator).
      expect(row.contains('Z'), isTrue);
      expect(row.contains('T'), isTrue);
    });
  });

  group('SessionExporter — CSV escaping (RFC 4180)', () {
    test('plain values pass through unquoted', () {
      // Using sessionsCsv as the integration point — the exercise field
      // never contains commas/quotes/newlines IRL, but the helper handles
      // any string input.
      final csv = SessionExporter.sessionsCsv([
        SessionSummary(
          id: 1,
          exercise: ExerciseType.bicepsCurl,
          startedAt: DateTime.utc(2026, 4, 25),
          duration: const Duration(seconds: 30),
          totalReps: 5,
          totalSets: 1,
          fatigueDetected: false,
          asymmetryDetected: false,
        ),
      ]);
      final row = csv.split('\n')[1];
      expect(row.contains('"'), isFalse);
    });
  });

  group('SessionExporter — repsCsv format', () {
    test('emits the canonical header on the first line', () {
      final csv = SessionExporter.repsCsv(const []);
      expect(
        csv.split('\n').first,
        'session_id,rep_index,quality,min_angle,max_angle,side,view,'
        'threshold_source,bucket_updated,rejected_outlier,concentric_ms,'
        'squat_lean_deg,squat_knee_shift_ratio,squat_heel_lift_ratio,'
        'squat_variant,'
        'biceps_lean_deg,biceps_shoulder_drift_ratio,'
        'biceps_elbow_drift_ratio,biceps_back_lean_deg,'
        'biceps_elbow_drift_signed,'
        'form_errors',
      );
    });

    test('curl rep populates all curl-specific columns', () {
      final summary = SessionSummary(
        id: 7,
        exercise: ExerciseType.bicepsCurl,
        startedAt: DateTime.utc(2026, 4, 25),
        duration: const Duration(seconds: 30),
        totalReps: 1,
        totalSets: 1,
        fatigueDetected: false,
        asymmetryDetected: false,
      );
      final detail = SessionDetail(
        summary: summary,
        eccentricTooFastCount: 0,
        reps: const [
          RepRow(
            repIndex: 1,
            quality: 0.91,
            minAngle: 48.5,
            maxAngle: 162.0,
            side: ProfileSide.right,
            view: CurlCameraView.sideRight,
            source: ThresholdSource.warmup,
            bucketUpdated: true,
            rejectedOutlier: false,
            concentricMs: 380,
          ),
        ],
        formErrors: const {},
      );
      final csv = SessionExporter.repsCsv([(session: summary, detail: detail)]);
      final row = csv.split('\n')[1];
      expect(row.startsWith('7,1,'), isTrue);
      expect(row, contains(',right,'));
      expect(row, contains(',sideRight,'));
      expect(row, contains(',warmup,'));
      expect(row, contains(',1,0,380,'));
    });

    test('squat rep without metrics leaves all curl + squat columns empty', () {
      final summary = SessionSummary(
        id: 9,
        exercise: ExerciseType.squat,
        startedAt: DateTime.utc(2026, 4, 25),
        duration: const Duration(seconds: 60),
        totalReps: 1,
        totalSets: 1,
        fatigueDetected: false,
        asymmetryDetected: false,
      );
      final detail = SessionDetail(
        summary: summary,
        eccentricTooFastCount: 0,
        reps: const [RepRow(repIndex: 1, quality: 0.78)],
        formErrors: const {},
      );
      final csv = SessionExporter.repsCsv([(session: summary, detail: detail)]);
      final row = csv.split('\n')[1];
      expect(
        row.contains('null'),
        isFalse,
        reason: 'null fields must serialize as empty',
      );
      // session_id=9, rep_index=1, quality=0.7800, then 18 empty fields
      // (min_angle, max_angle, side, view, threshold_source, bucket_updated,
      // rejected_outlier, concentric_ms, squat_lean_deg,
      // squat_knee_shift_ratio, squat_heel_lift_ratio, squat_variant,
      // biceps_lean_deg, biceps_shoulder_drift_ratio,
      // biceps_elbow_drift_ratio, biceps_back_lean_deg,
      // biceps_elbow_drift_signed, form_errors). 21 total columns.
      expect(row.startsWith('9,1,0.7800,'), isTrue);
      expect(row.split(',').length, 21);
    });

    test('squat rep WITH metrics populates the 4 squat columns', () {
      final summary = SessionSummary(
        id: 11,
        exercise: ExerciseType.squat,
        startedAt: DateTime.utc(2026, 4, 26),
        duration: const Duration(seconds: 90),
        totalReps: 1,
        totalSets: 1,
        fatigueDetected: false,
        asymmetryDetected: false,
      );
      final detail = SessionDetail(
        summary: summary,
        eccentricTooFastCount: 0,
        reps: const [
          RepRow(
            repIndex: 1,
            quality: 0.85,
            squatLeanDeg: 38.5,
            squatKneeShiftRatio: 0.245,
            squatHeelLiftRatio: 0.018,
            squatVariant: SquatVariant.highBarBackSquat,
          ),
        ],
        formErrors: const {},
      );
      final csv = SessionExporter.repsCsv([(session: summary, detail: detail)]);
      final row = csv.split('\n')[1];
      // Spot-check the 4 squat values land in the correct columns.
      expect(row, contains(',38.50,'));
      expect(row, contains(',0.2450,'));
      expect(row, contains(',0.0180,'));
      expect(row, contains(',highBarBackSquat,'));
      // Field count must match the header (21 columns post-signed-add).
      expect(row.split(',').length, 21);
    });

    test('bicepsCurlSide rep WITH metrics populates the 5 biceps columns', () {
      final summary = SessionSummary(
        id: 13,
        exercise: ExerciseType.bicepsCurlSide,
        startedAt: DateTime.utc(2026, 4, 26),
        duration: const Duration(seconds: 75),
        totalReps: 1,
        totalSets: 1,
        fatigueDetected: false,
        asymmetryDetected: false,
      );
      final detail = SessionDetail(
        summary: summary,
        eccentricTooFastCount: 0,
        reps: const [
          RepRow(
            repIndex: 1,
            quality: 0.92,
            bicepsLeanDeg: 7.50,
            bicepsShoulderDriftRatio: 0.1234,
            bicepsElbowDriftRatio: 0.2750,
            bicepsBackLeanDeg: 3.25,
            // Negative sign — elbow drifted to the −n̂ side (back).
            bicepsElbowDriftSigned: -0.2680,
          ),
        ],
        formErrors: const {},
      );
      final csv = SessionExporter.repsCsv([(session: summary, detail: detail)]);
      final row = csv.split('\n')[1];
      // Spot-check the 5 biceps values land in the correct columns.
      expect(row, contains(',7.50,'));
      expect(row, contains(',0.1234,'));
      expect(row, contains(',0.2750,'));
      expect(row, contains(',3.25,'));
      // Negative signed value — sign must survive the round-trip.
      expect(row, contains(',-0.2680,'));
      // Field count must match the header (21 columns post-signed-add).
      expect(row.split(',').length, 21);
    });
  });

  group('SessionExporter.exportToTempDir — integration', () {
    late InMemorySessionRepository repo;
    late Directory tmp;

    setUp(() {
      repo = InMemorySessionRepository();
      tmp = Directory.systemTemp.createTempSync('fitrack_export_test_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('writes both CSVs and reports counts', () async {
      await repo.insertCompletedSession(
        _curlEvent(reps: 3),
        startedAt: DateTime(2026, 4, 25, 10),
      );
      await repo.insertCompletedSession(
        _curlEvent(reps: 2),
        startedAt: DateTime(2026, 4, 25, 12),
      );
      final exporter = SessionExporter(repository: repo);

      final result = await exporter.exportToTempDir(tmpOverride: tmp);

      expect(result.sessionCount, 2);
      expect(result.repCount, 5);
      expect(File(result.sessionsCsv).existsSync(), isTrue);
      expect(File(result.repsCsv).existsSync(), isTrue);

      final sessionsBody = File(result.sessionsCsv).readAsStringSync();
      // Header + 2 sessions + trailing newline = 4 lines after split.
      expect(sessionsBody.split('\n'), hasLength(4));

      final repsBody = File(result.repsCsv).readAsStringSync();
      // Header + 5 rep rows + trailing newline = 7 lines.
      expect(repsBody.split('\n'), hasLength(7));
    });

    test(
      'empty repo writes header-only files and reports zero counts',
      () async {
        final exporter = SessionExporter(repository: repo);
        final result = await exporter.exportToTempDir(tmpOverride: tmp);

        expect(result.sessionCount, 0);
        expect(result.repCount, 0);
        final sessionsBody = File(result.sessionsCsv).readAsStringSync();
        expect(
          sessionsBody.split('\n'),
          hasLength(2),
        ); // header + trailing newline
      },
    );
  });
}
