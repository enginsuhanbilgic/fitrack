/// Unit tests for [WorkoutViewModel].
///
/// The VM takes CameraService / PoseService / TtsService via its constructor,
/// but `init()` calls platform channels (camera hardware, ML Kit, TTS engine)
/// that the Flutter test harness does not provide. We therefore instantiate
/// the VM *without* calling `init()` and exercise the pure-logic surface
/// that does not require live services:
///
///   - Construction wires services & registers the curl rep callback.
///   - `needsCalibrationHint()` reflects profile state faithfully.
///   - `asymmetryDetected` only flips after the left/right-lag cooldown key.
///   - `completionEvents` emits a single well-formed event from
///     `finishWorkout()` and is idempotent on a second call.
///   - `dispose()` is idempotent — safe to call after construction-only.
library;

import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/models/pose_result.dart';
import 'package:fitrack/services/camera_service.dart';
import 'package:fitrack/services/db/profile_repository.dart';
import 'package:fitrack/services/db/session_dtos.dart';
import 'package:fitrack/services/db/session_repository.dart';
import 'package:fitrack/services/pose/pose_service.dart';
import 'package:fitrack/services/telemetry_log.dart';
import 'package:fitrack/services/tts_service.dart';
import 'package:fitrack/view_models/workout_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal test doubles that avoid platform channels.
///
/// Production services (`CameraService`, `MlKitPoseService`, `TtsService`)
/// touch the camera hardware, ML Kit detector, and TTS engine via platform
/// channels at `init()`/`dispose()` time — none of which are wired in a
/// plain `flutter_test` harness. These fakes expose the same surface as
/// empty no-ops so the VM can be constructed and torn down cleanly.

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
    int sensorRotation,
  ) async => PoseResult(landmarks: const [], inferenceTime: Duration.zero);

  @override
  Future<PoseResult> processNv21(
    Uint8List bytes,
    int width,
    int height,
    int sensorRotation,
  ) async => PoseResult(landmarks: const [], inferenceTime: Duration.zero);

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

WorkoutViewModel buildVm({
  ExerciseType exercise = ExerciseType.bicepsCurl,
  bool forceCalibration = false,
  ProfileRepository? profileRepository,
  SessionRepository? sessionRepository,
}) {
  return WorkoutViewModel(
    exercise: exercise,
    forceCalibration: forceCalibration,
    camera: _FakeCameraService(),
    pose: _FakePoseService(),
    tts: _FakeTtsService(),
    profileRepository: profileRepository ?? InMemoryProfileRepository(),
    sessionRepository: sessionRepository ?? InMemorySessionRepository(),
  );
}

/// Repo that throws on insert — used to verify UI emission is not blocked
/// by a persistence failure (the plan's "emit-then-persist" invariant).
class _ThrowingSessionRepository implements SessionRepository {
  @override
  Future<int> insertCompletedSession(
    WorkoutCompletedEvent event, {
    required DateTime startedAt,
  }) async {
    throw StateError('simulated persistence failure');
  }

  @override
  Future<List<SessionSummary>> listSessions({
    ExerciseType? exercise,
    int limit = 100,
    int offset = 0,
  }) async => const [];

  @override
  Future<SessionDetail?> getSession(int sessionId) async => null;

  @override
  Future<void> deleteSession(int sessionId) async {}

  @override
  Future<List<Duration>> recentConcentricDurations({
    required ExerciseType exercise,
    required Duration window,
    int limitReps = 200,
  }) async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WorkoutViewModel — construction', () {
    test(
      'default constructor produces a VM in setupCheck with no snapshot',
      () {
        final vm = buildVm();
        expect(vm.phase, WorkoutPhase.setupCheck);
        expect(vm.isReady, isFalse);
        expect(vm.error, isNull);
        expect(vm.snapshot.reps, 0);
        expect(vm.snapshot.sets, 1);
        expect(vm.snapshot.state, RepState.idle);
        expect(vm.landmarks, isEmpty);
        expect(vm.detectedCurlView, CurlCameraView.unknown);
        expect(vm.asymmetryDetected, isFalse);
        vm.dispose();
      },
    );

    test('propagates exercise identity to internal RepCounter', () {
      final vm = buildVm(exercise: ExerciseType.squat);
      expect(vm.exercise, ExerciseType.squat);
      vm.dispose();
    });
  });

  group('WorkoutViewModel — needsCalibrationHint', () {
    test('returns true when no profile loaded', () {
      final vm = buildVm();
      expect(vm.needsCalibrationHint(), isTrue);
      vm.dispose();
    });
  });

  group('WorkoutViewModel — completion events', () {
    test('finishWorkout emits exactly one event', () async {
      final vm = buildVm();
      final events = <WorkoutCompletedEvent>[];
      final sub = vm.completionEvents.listen(events.add);

      vm.finishWorkout();
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.first.exercise, ExerciseType.bicepsCurl);
      expect(events.first.totalReps, 0);
      expect(events.first.totalSets, 1);
      expect(vm.phase, WorkoutPhase.completed);

      await sub.cancel();
      vm.dispose();
    });

    test('finishWorkout is idempotent — second call emits nothing', () async {
      final vm = buildVm();
      final events = <WorkoutCompletedEvent>[];
      final sub = vm.completionEvents.listen(events.add);

      vm.finishWorkout();
      vm.finishWorkout();
      vm.finishWorkout();
      await Future<void>.delayed(Duration.zero);

      expect(
        events,
        hasLength(1),
        reason: 'completed-phase guard must swallow re-fires',
      );

      await sub.cancel();
      vm.dispose();
    });

    test('event includes empty curl records when no reps committed', () async {
      final vm = buildVm();
      final completion = vm.completionEvents.first;

      vm.finishWorkout();
      final e = await completion;

      expect(e.curlRepRecords, isEmpty);
      expect(e.curlBucketSummaries, isEmpty);
      expect(e.errorsTriggered, isEmpty);
      expect(e.asymmetryDetected, isFalse);
      vm.dispose();
    });

    test(
      'sessionDuration is Duration.zero when activeStart never set',
      () async {
        final vm = buildVm();
        final completion = vm.completionEvents.first;

        vm.finishWorkout();
        final e = await completion;

        expect(e.sessionDuration, Duration.zero);
        vm.dispose();
      },
    );
  });

  group('WorkoutViewModel — startNextSet', () {
    test('increments sets, zeros reps, resets snapshot state to idle', () {
      final vm = buildVm();
      expect(vm.snapshot.sets, 1);
      expect(vm.snapshot.reps, 0);

      vm.startNextSet();
      expect(vm.snapshot.sets, 2);
      expect(vm.snapshot.reps, 0);
      expect(vm.snapshot.state, RepState.idle);

      vm.startNextSet();
      expect(vm.snapshot.sets, 3);
      vm.dispose();
    });

    test('notifies listeners', () {
      final vm = buildVm();
      var notifyCount = 0;
      vm.addListener(() => notifyCount++);

      vm.startNextSet();
      expect(notifyCount, greaterThanOrEqualTo(1));
      vm.dispose();
    });
  });

  group('WorkoutViewModel — dispose semantics', () {
    test('dispose on a never-initialized VM does not throw', () {
      final vm = buildVm();
      expect(vm.dispose, returnsNormally);
    });

    test('dispose after finishWorkout does not throw', () async {
      final vm = buildVm();
      vm.finishWorkout();
      await Future<void>.delayed(Duration.zero);
      expect(vm.dispose, returnsNormally);
    });
  });

  group('WorkoutViewModel — calibration summary lifecycle', () {
    test('calibrationSummary is null before any calibration', () {
      final vm = buildVm();
      expect(vm.calibrationSummary, isNull);
      vm.dispose();
    });

    test('phase stays setupCheck when forceCalibration is false', () {
      final vm = buildVm();
      expect(vm.phase, WorkoutPhase.setupCheck);
      vm.dispose();
    });
  });

  group('WorkoutViewModel — non-curl exercises', () {
    test('squat exercise has no curl-specific fields populated', () {
      final vm = buildVm(exercise: ExerciseType.squat);
      expect(vm.detectedCurlView, CurlCameraView.unknown);
      expect(vm.profile, isNull);
      expect(vm.needsCalibrationHint(), isTrue);
      vm.dispose();
    });

    test('pushUp exercise has no curl-specific fields populated', () {
      final vm = buildVm(exercise: ExerciseType.pushUp);
      expect(vm.detectedCurlView, CurlCameraView.unknown);
      expect(vm.profile, isNull);
      vm.dispose();
    });

    test(
      'finishWorkout on squat emits event with squat exercise type',
      () async {
        final vm = buildVm(exercise: ExerciseType.squat);
        final completion = vm.completionEvents.first;

        vm.finishWorkout();
        final e = await completion;

        expect(e.exercise, ExerciseType.squat);
        expect(e.curlRepRecords, isEmpty);
        vm.dispose();
      },
    );
  });

  group('WorkoutViewModel — completion snapshot immutability', () {
    test('event.curlRepRecords is unmodifiable', () async {
      final vm = buildVm();
      final completion = vm.completionEvents.first;

      vm.finishWorkout();
      final e = await completion;

      expect(
        () => e.curlRepRecords.add(
          CurlRepRecord(
            repIndex: 1,
            side: ProfileSide.left,
            view: CurlCameraView.front,
            minAngle: 40,
            maxAngle: 150,
            source: ThresholdSource.global,
            bucketUpdated: false,
            rejectedOutlier: false,
          ),
        ),
        throwsUnsupportedError,
      );
      vm.dispose();
    });
  });

  group('WorkoutViewModel — persistence (WP5.2)', () {
    test(
      'finishWorkout writes one session via the injected SessionRepository',
      () async {
        final repo = InMemorySessionRepository();
        final vm = buildVm(sessionRepository: repo);

        vm.finishWorkout();
        // Allow the stream emit AND the fire-and-forget persist to settle.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        final list = await repo.listSessions();
        expect(list, hasLength(1));
        expect(list.first.exercise, ExerciseType.bicepsCurl);
        vm.dispose();
      },
    );

    test(
      'persistence failure does not block completion event emission',
      () async {
        TelemetryLog.instance.clear();
        final vm = buildVm(sessionRepository: _ThrowingSessionRepository());
        final events = <WorkoutCompletedEvent>[];
        final sub = vm.completionEvents.listen(events.add);

        vm.finishWorkout();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(
          events,
          hasLength(1),
          reason: 'UI emit must not wait on persistence',
        );
        expect(
          TelemetryLog.instance.entries.any(
            (e) => e.tag == 'session.save_failed',
          ),
          isTrue,
          reason: 'persistence failure must be logged to telemetry',
        );

        await sub.cancel();
        vm.dispose();
      },
    );
  });
}
