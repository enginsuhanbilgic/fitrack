/// Pure-Dart tests for the curl Global Calibration / Second-Side
/// Calibration contract in [WorkoutViewModel].
///
/// Behaviours pinned here:
///   1. First-pass: pick Left + 3 valid reps → BOTH `(left, sideLeft)`
///      AND `(right, sideLeft)` buckets exist with equal observed
///      min/max and sample count (Global Calibration via duplicate-at-save).
///   2. Second-pass: accept the "other side" prompt + 3 different reps
///      → Right bucket is replaced from the second-pass data; Left
///      bucket is unchanged byte-wise.
///   3. Guard: pre-seed a calibrated Left bucket, then recalibrate Right
///      only → the prior Left bucket survives byte-identically (no
///      silent overwrite by `_shouldDuplicateToOtherSide`).
///
/// The camera + pose pipeline is bypassed via the existing
/// `@visibleForTesting` seams (`enterCalibrationForTest`,
/// `ingestCalibrationRepForTest`, `setDetectedCurlViewForTest`) so no
/// platform plugins are touched.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/curl/curl_rom_profile.dart';
import 'package:fitrack/models/pose_result.dart';
import 'package:fitrack/services/camera_service.dart';
import 'package:fitrack/services/db/preferences_repository.dart';
import 'package:fitrack/services/db/profile_repository.dart';
import 'package:fitrack/services/db/session_repository.dart';
import 'package:fitrack/services/pose/pose_service.dart';
import 'package:fitrack/services/tts_service.dart';
import 'package:fitrack/view_models/workout_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

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

WorkoutViewModel _buildCurlVm({InMemoryProfileRepository? repo}) {
  return WorkoutViewModel(
    exercise: ExerciseType.bicepsCurlSide,
    forceCalibration: true,
    camera: _FakeCameraService(),
    pose: _FakePoseService(),
    tts: _FakeTtsService(),
    profileRepository: repo ?? InMemoryProfileRepository(),
    sessionRepository: InMemorySessionRepository(),
    preferencesRepository: InMemoryPreferencesRepository(),
  );
}

/// Three reps comfortably above `kMinViableRomDegrees` covering the
/// expected curl ROM band (peak ~50°, rest ~165°).
void _ingestThreeFirstPassReps(WorkoutViewModel vm) {
  vm.ingestCalibrationRepForTest(minAngle: 52, maxAngle: 168);
  vm.ingestCalibrationRepForTest(minAngle: 50, maxAngle: 170);
  vm.ingestCalibrationRepForTest(minAngle: 54, maxAngle: 167);
}

/// Three reps with a clearly different ROM band so a second-pass
/// overwrite is byte-detectable on the opposite-side bucket.
void _ingestThreeSecondPassReps(WorkoutViewModel vm) {
  vm.ingestCalibrationRepForTest(minAngle: 70, maxAngle: 155);
  vm.ingestCalibrationRepForTest(minAngle: 72, maxAngle: 153);
  vm.ingestCalibrationRepForTest(minAngle: 68, maxAngle: 156);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WorkoutViewModel — curl Global Calibration', () {
    test('pick Left + 3 reps → both side buckets exist with equal extremes '
        '(duplicate-at-save)', () async {
      final repo = InMemoryProfileRepository();
      final vm = _buildCurlVm(repo: repo);
      addTearDown(vm.dispose);

      vm.enterCalibrationForTest();
      // Detector + timeout are deferred under the new contract — the
      // user must explicitly pick a side first. Until they do,
      // calibrationReps stays at 0 and no detector is armed.
      expect(vm.calibrationChosenSide, isNull);
      expect(vm.calibrationReps, 0);

      vm.setDetectedCurlViewForTest(CurlCameraView.sideLeft);
      vm.pickCalibrationSide(ProfileSide.left);
      expect(vm.calibrationChosenSide, ProfileSide.left);

      _ingestThreeFirstPassReps(vm);

      await Future<void>.delayed(Duration.zero);

      final saved = await repo.loadCurl();
      expect(saved, isNotNull);
      final left = saved!.bucketFor(ProfileSide.left, CurlCameraView.sideLeft);
      final right = saved.bucketFor(ProfileSide.right, CurlCameraView.sideLeft);
      expect(left, isNotNull, reason: 'chosen-side bucket must be saved');
      expect(
        right,
        isNotNull,
        reason:
            'first-pass calibration must duplicate the chosen bucket '
            'into the opposite side (Global Calibration)',
      );
      expect(left!.observedMinAngle, right!.observedMinAngle);
      expect(left.observedMaxAngle, right.observedMaxAngle);
      expect(left.sampleCount, right.sampleCount);

      // The host should now offer the Second-Side Calibration prompt
      // instead of auto-dismissing.
      expect(vm.calibrationOfferSecondSide, isTrue);
      expect(vm.calibrationSummary, isNotNull);
    });

    test('second pass: accept + different reps → only opposite-side bucket '
        'changes; first-pass side untouched', () async {
      final repo = InMemoryProfileRepository();
      final vm = _buildCurlVm(repo: repo);
      addTearDown(vm.dispose);

      vm.enterCalibrationForTest();
      vm.setDetectedCurlViewForTest(CurlCameraView.sideLeft);
      vm.pickCalibrationSide(ProfileSide.left);
      _ingestThreeFirstPassReps(vm);
      await Future<void>.delayed(Duration.zero);

      // Snapshot the Left bucket bytes before the second pass.
      final savedAfterFirst = await repo.loadCurl();
      final leftBytesBefore = jsonEncode(
        savedAfterFirst!
            .bucketFor(ProfileSide.left, CurlCameraView.sideLeft)!
            .toJson(),
      );

      // User taps Yes — second pass starts. Detector is re-armed,
      // chosenSide flips to Right, collected list is reset.
      vm.acceptSecondSideCalibration();
      expect(vm.calibrationChosenSide, ProfileSide.right);
      expect(vm.calibrationOfferSecondSide, isFalse);
      expect(vm.calibrationReps, 0);

      _ingestThreeSecondPassReps(vm);
      await Future<void>.delayed(Duration.zero);

      final savedAfterSecond = await repo.loadCurl();
      final leftAfter = savedAfterSecond!.bucketFor(
        ProfileSide.left,
        CurlCameraView.sideLeft,
      );
      final rightAfter = savedAfterSecond.bucketFor(
        ProfileSide.right,
        CurlCameraView.sideLeft,
      );

      // Left must be untouched byte-identically.
      expect(
        jsonEncode(leftAfter!.toJson()),
        leftBytesBefore,
        reason: 'second-pass must not touch the first-pass bucket',
      );
      // Right must have been overwritten with second-pass data —
      // its observedMinAngle reflects the higher peak band of pass 2.
      expect(
        rightAfter!.observedMinAngle,
        greaterThan(leftAfter.observedMinAngle),
        reason:
            'second-pass reps had a shallower peak (min ≈70°) than '
            'first-pass (min ≈50°) — opposite-side bucket must '
            'reflect the pass-2 distribution',
      );
    });

    test('pre-seeded calibrated Left bucket survives a Right-only '
        'recalibration (duplication guard)', () async {
      final repo = InMemoryProfileRepository();
      // Seed a fully-calibrated Left bucket. Use a sequence of
      // monotonically expanding reps so every applyRep call resolves to
      // `RepApplyResult.applied` (or `initialized` for the first) — that
      // guarantees `sampleCount` increments past `kCalibrationMinReps`
      // without falling into the shrink-pending path that would NOT
      // bump the count.
      final seed = CurlRomProfile();
      final leftBucket = RomBucket.empty(
        ProfileSide.left,
        CurlCameraView.sideLeft,
      );
      // Initial seed.
      leftBucket.applyRep(60, 160);
      // Each subsequent rep expands the bucket on at least one
      // dimension (lower min OR higher max), so applyRep returns
      // `applied` and bumps sampleCount.
      leftBucket.applyRep(58, 162);
      leftBucket.applyRep(56, 164);
      leftBucket.applyRep(54, 166);
      leftBucket.applyRep(52, 168);
      leftBucket.applyRep(50, 170);
      assert(
        leftBucket.sampleCount >= 3,
        'test seed precondition: bucket must clear kCalibrationMinReps',
      );
      seed.upsertBucket(leftBucket);
      await repo.saveCurl(seed);

      // Capture the seed's exact byte representation BEFORE the test
      // reloads anything — this is the contract: a calibrated
      // opposite-side bucket must not be mutated by a single-side
      // recalibration.
      final seedSavedJson = jsonEncode(
        (await repo.loadCurl())!
            .bucketFor(ProfileSide.left, CurlCameraView.sideLeft)!
            .toJson(),
      );

      final vm = _buildCurlVm(repo: repo);
      addTearDown(vm.dispose);

      // Hydrate the in-memory `_profile` reference so the VM's
      // duplication guard (`_shouldDuplicateToOtherSide`) can observe
      // the seed. `init()` is the live path that does this; tests use
      // this seam to skip camera/pose boot.
      await vm.loadCurlProfileForTest();

      vm.enterCalibrationForTest();
      vm.setDetectedCurlViewForTest(CurlCameraView.sideLeft);
      vm.pickCalibrationSide(ProfileSide.right);
      _ingestThreeSecondPassReps(vm);
      await Future<void>.delayed(Duration.zero);

      final saved = await repo.loadCurl();
      final leftAfter = saved!.bucketFor(
        ProfileSide.left,
        CurlCameraView.sideLeft,
      );
      expect(leftAfter, isNotNull);
      expect(
        jsonEncode(leftAfter!.toJson()),
        seedSavedJson,
        reason:
            '_shouldDuplicateToOtherSide must suppress duplication when '
            'the opposite side already has ≥ kCalibrationMinReps '
            'samples — the prior calibration is the user\'s real data',
      );
    });
  });
}
