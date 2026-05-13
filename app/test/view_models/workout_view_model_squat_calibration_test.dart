/// Pure-Dart tests for the squat-calibration FSM in [WorkoutViewModel].
///
/// The camera + pose pipeline is bypassed via three `@visibleForTesting`
/// seams:
///   - `enterCalibrationForTest()` puts the VM into
///     [WorkoutPhase.calibration] without driving the camera stream.
///   - `ingestCalibrationRepForTest(minAngle:, maxAngle:)` simulates a
///     single rep arriving from the [RepBoundaryDetector].
///   - `timeoutCalibrationForTest()` fires the 60s timeout immediately
///     so tests don't have to wait.
///
/// Behaviours pinned here:
///   1. Three valid reps → SquatRomProfile saved via the repository,
///      `isCalibrated` flips true, calibration summary card fires.
///   2. Two valid reps + timeout → calibration fails with the no-reps
///      message; profile is NOT saved.
///   3. A rep with ROM = 30° is below `kSquatMinViableRomDegrees` (40°)
///      → rejected silently; counter stays at 0.
library;

import 'package:camera/camera.dart';
import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/squat/squat_rom_profile.dart';
import 'package:fitrack/models/pose_result.dart';
import 'package:fitrack/services/camera_service.dart';
import 'package:fitrack/services/db/preferences_repository.dart';
import 'package:fitrack/services/db/profile_repository.dart';
import 'package:fitrack/services/db/session_repository.dart';
import 'package:fitrack/services/pose/pose_service.dart';
import 'package:fitrack/services/tts_service.dart';
import 'package:fitrack/view_models/workout_view_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';

/// Fake services that satisfy the VM's construction-time wiring without
/// touching real camera / pose / TTS platform channels.
class _FakeCameraService extends CameraService {
  @override
  Future<void> init() async {}
  @override
  Future<void> dispose() async {}
}

class _FakePoseService extends PoseService {
  @override
  String get name => 'Fake';
  @override
  Future<void> init() async {}
  @override
  Future<PoseResult> processCameraImage(
    CameraImage image,
    int sensorRotation, {
    List<int>? requiredLandmarks,
    List<int>? requiredLandmarksAlt,
    double? confidenceFloor,
    Set<int>? bestEffortLandmarks,
  }) async => PoseResult(landmarks: const [], inferenceTime: Duration.zero);
  @override
  Future<PoseResult> processNv21(
    Uint8List bytes,
    int width,
    int height,
    int sensorRotation, {
    List<int>? requiredLandmarks,
    List<int>? requiredLandmarksAlt,
    double? confidenceFloor,
    Set<int>? bestEffortLandmarks,
  }) async => PoseResult(landmarks: const [], inferenceTime: Duration.zero);
  @override
  void dispose() {}
}

class _FakeTtsService extends TtsService {
  @override
  Future<void> init() async {}
  @override
  Future<void> speak(String text) async {}
  @override
  Future<void> stop() async {}
  @override
  void dispose() {}
}

WorkoutViewModel _buildSquatVm({InMemoryProfileRepository? repo}) {
  return WorkoutViewModel(
    exercise: ExerciseType.squat,
    forceCalibration: true,
    camera: _FakeCameraService(),
    pose: _FakePoseService(),
    tts: _FakeTtsService(),
    profileRepository: repo ?? InMemoryProfileRepository(),
    sessionRepository: InMemorySessionRepository(),
    preferencesRepository: InMemoryPreferencesRepository(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WorkoutViewModel — squat calibration FSM', () {
    test(
      '3 valid reps → SquatRomProfile saved, calibration summary fires',
      () async {
        final repo = InMemoryProfileRepository();
        final vm = _buildSquatVm(repo: repo);
        addTearDown(vm.dispose);

        vm.enterCalibrationForTest();
        expect(vm.phase, WorkoutPhase.calibration);

        // Three reps comfortably above kSquatMinViableRomDegrees (40°).
        // Min < Max because for the calibrator min = deepest knee
        // flexion (small angle) and max = standing extension (large).
        vm.ingestCalibrationRepForTest(minAngle: 90, maxAngle: 170);
        vm.ingestCalibrationRepForTest(minAngle: 88, maxAngle: 172);
        vm.ingestCalibrationRepForTest(minAngle: 92, maxAngle: 171);

        // Save is fire-and-forget via `unawaited`; pump the microtask
        // queue so the repository write lands before we assert.
        await Future<void>.delayed(Duration.zero);

        final saved = await repo.loadSquat();
        expect(
          saved,
          isNotNull,
          reason: 'three valid reps must persist a SquatRomProfile',
        );
        expect(saved!.isCalibrated, isTrue);
        expect(saved.bucket, isNotNull);

        // Calibration summary should fire — a non-null banner during
        // the 2s display window. The screen consumes this to render
        // the post-calibration card.
        expect(vm.calibrationSummary, isNotNull);
        expect(vm.calibrationError, isNull);
      },
    );

    test(
      '2 valid reps + timeout → calibration fail, profile not saved',
      () async {
        final repo = InMemoryProfileRepository();
        final vm = _buildSquatVm(repo: repo);
        addTearDown(vm.dispose);

        vm.enterCalibrationForTest();
        vm.ingestCalibrationRepForTest(minAngle: 90, maxAngle: 170);
        vm.ingestCalibrationRepForTest(minAngle: 88, maxAngle: 172);

        // Two reps is below the 3-rep gate — completion was not triggered.
        expect(vm.calibrationReps, 2);
        expect(vm.calibrationSummary, isNull);

        vm.timeoutCalibrationForTest();

        // Fail path: error message set, summary still null, profile not
        // saved. The user sees the "didn't see any reps" banner; the
        // squat profile is untouched.
        expect(vm.calibrationError, isNotNull);
        await Future<void>.delayed(Duration.zero);
        final saved = await repo.loadSquat();
        expect(
          saved,
          isNull,
          reason:
              'sub-threshold rep counts must not produce a persisted profile',
        );
      },
    );

    test('rep with ROM 30° is rejected (below kSquatMinViableRomDegrees) — '
        'counter does not advance', () async {
      final repo = InMemoryProfileRepository();
      final vm = _buildSquatVm(repo: repo);
      addTearDown(vm.dispose);

      vm.enterCalibrationForTest();

      // 170 − 140 = 30°, below the 40° squat-viability floor.
      vm.ingestCalibrationRepForTest(minAngle: 140, maxAngle: 170);

      expect(
        vm.calibrationReps,
        0,
        reason: 'sub-viable rep must vanish silently from the counter',
      );
      expect(vm.calibrationSummary, isNull);
      expect(vm.calibrationError, isNull);
    });

    test(
      'mixed ROM: only viable reps count toward the calibration gate',
      () async {
        final repo = InMemoryProfileRepository();
        final vm = _buildSquatVm(repo: repo);
        addTearDown(vm.dispose);

        vm.enterCalibrationForTest();

        // Three above-viability reps interleaved with one rejection.
        vm.ingestCalibrationRepForTest(minAngle: 90, maxAngle: 170); // 80°
        vm.ingestCalibrationRepForTest(
          minAngle: 145,
          maxAngle: 170,
        ); // 25° — rejected
        vm.ingestCalibrationRepForTest(minAngle: 92, maxAngle: 168); // 76°
        vm.ingestCalibrationRepForTest(minAngle: 88, maxAngle: 172); // 84°
        // After 3 valid reps the completion path fires; further reps
        // would be discarded (timer cancelled, summary set).

        await Future<void>.delayed(Duration.zero);
        final saved = await repo.loadSquat();
        expect(saved, isNotNull);
        expect(saved!.bucket, isNotNull);
        // 3 valid reps fired the completion gate. Whether `isCalibrated`
        // flips depends on the bucket's own `applyRep` disposition —
        // tightly clustered reps may produce `shrinkPending` outcomes
        // that don't bump `sampleCount`. Calibration-gate completion is
        // independent of bucket sample-count promotion.
        expect(vm.calibrationReps, kSquatCalibrationMinReps);
        expect(saved.bucket!.sampleCount, greaterThanOrEqualTo(1));
      },
    );

    test('second calibration run MERGES into the existing bucket — '
        'does NOT replace it (contract lock)', () async {
      // The host calls `bucket.applyRep` per collected rep on the
      // existing bucket, so a returning user's calibration history
      // is preserved (sampleCount grows; EMA smooths against the
      // prior baseline). The alternative — replacing the bucket on
      // every recalibration — would lose history and produce
      // jarring rep-1 threshold shifts.
      final repo = InMemoryProfileRepository();
      final seed = SquatRomProfile(bucket: SquatRomBucket.empty());
      seed.bucket!.applyRep(85, 175);
      final seedSampleCount = seed.bucket!.sampleCount;
      await repo.saveSquat(seed);

      final vm = _buildSquatVm(repo: repo);
      addTearDown(vm.dispose);

      vm.enterCalibrationForTest();
      vm.ingestCalibrationRepForTest(minAngle: 88, maxAngle: 171);
      vm.ingestCalibrationRepForTest(minAngle: 90, maxAngle: 170);
      vm.ingestCalibrationRepForTest(minAngle: 89, maxAngle: 172);

      await Future<void>.delayed(Duration.zero);
      final saved = await repo.loadSquat();
      expect(saved, isNotNull);
      expect(saved!.bucket, isNotNull);
      // Sample count must have GROWN, not reset to a fresh-bucket
      // count. The seed contributed `seedSampleCount` and the three
      // calibration reps add up to it (each one bumps sampleCount
      // on `applied`/`initialized` outcomes; tightly-clustered ones
      // may produce `shrinkPending`, but at least one must apply
      // for a user-visible "I just calibrated" promise to hold).
      expect(
        saved.bucket!.sampleCount,
        greaterThan(seedSampleCount),
        reason:
            'second-run calibration must merge into the existing '
            'bucket, not reset its sample history',
      );
    });
  });
}
