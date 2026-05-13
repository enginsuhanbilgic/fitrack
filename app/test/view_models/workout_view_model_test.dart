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
import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/squat/squat_rom_profile.dart';
import 'package:fitrack/models/pose_result.dart';
import 'package:fitrack/services/camera_service.dart';
import 'package:fitrack/services/db/preferences_repository.dart';
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

WorkoutViewModel buildVm({
  ExerciseType exercise = ExerciseType.bicepsCurlFront,
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
    preferencesRepository: InMemoryPreferencesRepository(),
  );
}

/// Repo that throws on insert — used to verify UI emission is not blocked
/// by a persistence failure (the plan's "emit-then-persist" invariant).
class _ThrowingSessionRepository implements SessionRepository {
  @override
  Future<int> insertCompletedSession(
    WorkoutCompletedEvent event, {
    required DateTime startedAt,
    List<Duration?> concentricDurations = const [],
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
      expect(events.first.exercise, ExerciseType.bicepsCurlFront);
      expect(events.first.totalReps, 0);
      expect(events.first.totalSets, 1);
      expect(vm.phase, WorkoutPhase.completed);

      await sub.cancel();
      vm.dispose();
    });

    test(
      'WorkoutCompletedEvent.exercise is bicepsCurlFront for front variant',
      () async {
        final vm = buildVm(exercise: ExerciseType.bicepsCurlFront);
        final events = <WorkoutCompletedEvent>[];
        final sub = vm.completionEvents.listen(events.add);
        vm.finishWorkout();
        await Future<void>.delayed(Duration.zero);
        expect(events.first.exercise, ExerciseType.bicepsCurlFront);
        await sub.cancel();
        vm.dispose();
      },
    );

    test(
      'WorkoutCompletedEvent.exercise is bicepsCurlSide for side variant',
      () async {
        final vm = buildVm(exercise: ExerciseType.bicepsCurlSide);
        final events = <WorkoutCompletedEvent>[];
        final sub = vm.completionEvents.listen(events.add);
        vm.finishWorkout();
        await Future<void>.delayed(Duration.zero);
        expect(events.first.exercise, ExerciseType.bicepsCurlSide);
        await sub.cancel();
        vm.dispose();
      },
    );

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
    test(
      'increments sets, zeros reps, resets snapshot state to idle',
      () async {
        final vm = buildVm();
        // WP5.4: RepCounter is init-built now, so tests that exercise the
        // counter must await `init()` first.
        await vm.init();
        expect(vm.snapshot.sets, 1);
        expect(vm.snapshot.reps, 0);

        vm.startNextSet();
        expect(vm.snapshot.sets, 2);
        expect(vm.snapshot.reps, 0);
        expect(vm.snapshot.state, RepState.idle);

        vm.startNextSet();
        expect(vm.snapshot.sets, 3);
        vm.dispose();
      },
    );

    test('notifies listeners', () async {
      final vm = buildVm();
      await vm.init();
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
      expect(vm.needsCalibrationHint(), isFalse);
      vm.dispose();
    });

    test('pushUp exercise has no curl-specific fields populated', () {
      final vm = buildVm(exercise: ExerciseType.pushUp);
      expect(vm.detectedCurlView, CurlCameraView.unknown);
      expect(vm.profile, isNull);
      expect(vm.needsCalibrationHint(), isTrue);
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

    // Pins the Part-4 audit wiring: `_triggerCompleted` must populate the
    // squat context bundle for squat sessions. Without this, a late-init
    // bug (e.g. accidentally constructing the bundle for the wrong
    // exercise, or forgetting to set it) would only be caught by a live
    // run. We don't assert on the per-rep profile/autoCal contents here
    // — those have dedicated tests in form_auditor_test.dart — just that
    // the bundle exists and carries the session's variant + sensitivity.
    test(
      'finishWorkout on squat emits a non-null squatContext bundle',
      () async {
        final vm = buildVm(exercise: ExerciseType.squat);
        final completion = vm.completionEvents.first;
        vm.finishWorkout();
        final e = await completion;

        expect(
          e.squatContext,
          isNotNull,
          reason: 'squat sessions must always produce a squatContext.',
        );
        expect(e.squatContext!.variant, e.squatVariant);
        expect(
          e.squatContext!.longFemurLifter,
          e.squatLongFemurLifter,
          reason: 'context.longFemurLifter must mirror the flat field.',
        );
        expect(e.squatContext!.feedbackSensitivity, e.feedbackSensitivity);
        vm.dispose();
      },
    );

    test(
      'finishWorkout on non-squat exercises emits a null squatContext',
      () async {
        // Symmetric guard: the bundle is squat-only. A future refactor
        // that accidentally constructs SquatSessionContext for curl
        // sessions should fail this test.
        final vm = buildVm(); // defaults to bicepsCurlFront
        final completion = vm.completionEvents.first;
        vm.finishWorkout();
        final e = await completion;
        expect(e.squatContext, isNull);
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
        expect(list.first.exercise, ExerciseType.bicepsCurlFront);
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

  group('WorkoutViewModel — historical fatigue baseline (WP5.4)', () {
    test(
      'init() queries recentConcentricDurations with 30-day window for curl',
      () async {
        final spy = _SpyingSessionRepository();
        final vm = buildVm(sessionRepository: spy);
        await vm.init();
        expect(spy.concentricQueries, hasLength(1));
        expect(
          spy.concentricQueries.first.exercise,
          ExerciseType.bicepsCurlFront,
        );
        expect(spy.concentricQueries.first.window, const Duration(days: 30));
        vm.dispose();
      },
    );

    test(
      'init() on squat does NOT query historical baseline (curl-only path)',
      () async {
        final spy = _SpyingSessionRepository();
        final vm = buildVm(
          exercise: ExerciseType.squat,
          sessionRepository: spy,
        );
        await vm.init();
        expect(spy.concentricQueries, isEmpty);
        vm.dispose();
      },
    );

    test(
      'init() swallows repository errors and still succeeds (empty baseline fallback)',
      () async {
        TelemetryLog.instance.clear();
        final vm = buildVm(sessionRepository: _BaselineThrowingRepository());
        await vm.init();
        // VM reached isReady despite the baseline-load failure.
        expect(vm.error, isNull);
        expect(
          TelemetryLog.instance.entries.any(
            (e) => e.tag == 'fatigue.baseline.load_failed',
          ),
          isTrue,
          reason: 'baseline load failures must be logged, not crash init',
        );
        vm.dispose();
      },
    );
  });

  group('WorkoutViewModel — squat preferences hydration', () {
    test('init() reads squat variant + long-femur from preferences', () async {
      final prefs = InMemoryPreferencesRepository();
      await prefs.setSquatVariant(SquatVariant.highBarBackSquat);
      await prefs.setSquatLongFemurLifter(true);
      // Wire prefs into the VM by constructing it with our seeded repo.
      final vm = WorkoutViewModel(
        exercise: ExerciseType.squat,
        camera: _FakeCameraService(),
        pose: _FakePoseService(),
        tts: _FakeTtsService(),
        profileRepository: InMemoryProfileRepository(),
        sessionRepository: InMemorySessionRepository(),
        preferencesRepository: prefs,
      );
      await vm.init();
      // Triggering completion forwards the snapshotted values into the
      // emitted event.
      final events = <WorkoutCompletedEvent>[];
      final sub = vm.completionEvents.listen(events.add);
      vm.finishWorkout();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(events, hasLength(1));
      expect(events.first.squatVariant, SquatVariant.highBarBackSquat);
      expect(events.first.squatLongFemurLifter, isTrue);
      vm.dispose();
    });

    test(
      'curl session uses default squat values (bodyweight, false) regardless of prefs',
      () async {
        final prefs = InMemoryPreferencesRepository();
        await prefs.setSquatVariant(SquatVariant.highBarBackSquat);
        await prefs.setSquatLongFemurLifter(true);
        final vm = WorkoutViewModel(
          exercise: ExerciseType.bicepsCurlFront,
          camera: _FakeCameraService(),
          pose: _FakePoseService(),
          tts: _FakeTtsService(),
          profileRepository: InMemoryProfileRepository(),
          sessionRepository: InMemorySessionRepository(),
          preferencesRepository: prefs,
        );
        await vm.init();
        final events = <WorkoutCompletedEvent>[];
        final sub = vm.completionEvents.listen(events.add);
        vm.finishWorkout();
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();
        // Curl session should not surface squat prefs in the event.
        expect(events.first.squatVariant, SquatVariant.bodyweight);
        expect(events.first.squatLongFemurLifter, isFalse);
        vm.dispose();
      },
    );
  });

  group('WorkoutViewModel — TTS suppression contract', () {
    test('forwardKneeShift is suppressed from TTS path', () {
      // Pure-Dart unit test on the static suppression predicate. Locks the
      // contract that `forwardKneeShift` must not trigger TTS — a future
      // developer adding it back to the spoken path would have to change
      // this test, making the regression visible at review time.
      expect(
        WorkoutViewModel.isTtsSuppressed(FormError.forwardKneeShift),
        isTrue,
      );
    });

    test('all other FormError values flow through TTS', () {
      // Every other error must reach the TTS coordinator. If a new
      // informational-only error is added in the future, this test will
      // need to be updated alongside `isTtsSuppressed`.
      for (final err in FormError.values) {
        if (err == FormError.forwardKneeShift) continue;
        expect(
          WorkoutViewModel.isTtsSuppressed(err),
          isFalse,
          reason: '$err must not be silently suppressed from TTS',
        );
      }
    });

    test('FormError.hipLead → "Lead with your chest" cue', () {
      // Lock the user-visible TTS phrasing for the new hip-lead cue.
      // The plan explicitly named this string ("Lead with your chest")
      // — a future refactor that swaps it for a less-actionable phrase
      // ("Chest up", etc.) would be visible at review time via this
      // test rather than only at on-device QA.
      expect(
        WorkoutViewModel.errorMessageForTest(FormError.hipLead),
        'Lead with your chest',
      );
    });

    test('every FormError has a non-empty TTS cue', () {
      // Belt-and-suspenders: every enum value must map to a non-empty
      // string. If someone adds a new FormError without wiring it
      // into the switch, the analyzer will flag exhaustiveness — but
      // an empty default would slip through. Guard against that.
      for (final err in FormError.values) {
        final cue = WorkoutViewModel.errorMessageForTest(err);
        expect(cue, isNotEmpty, reason: '$err must have a TTS cue');
      }
    });
  });

  group('WorkoutViewModel — _resolveSquatThresholds tier priority', () {
    test(
      'Tier 3: no profile, no auto-cal → cold-start sensitivity defaults',
      () {
        TelemetryLog.instance.clear();
        final vm = buildVm(exercise: ExerciseType.squat);

        final t = vm.resolveSquatThresholds(0);

        // Medium-sensitivity defaults (160 / 90 / 160) — the VM defaults to
        // medium when the preferences repo returns its default sensitivity.
        expect(t.startAngle, kSquatStartAngle);
        expect(t.bottomAngle, kSquatBottomAngle);
        expect(t.endAngle, kSquatEndAngle);

        // Telemetry pin: Tier 3 fired.
        expect(
          TelemetryLog.instance.entries.any(
            (e) =>
                e.tag == 'squat.thresholds_resolved' &&
                e.message.contains('tier=3'),
          ),
          isTrue,
        );

        vm.dispose();
      },
    );

    test('Tier 2: auto-cal viable → resolver returns auto-cal tuple', () {
      TelemetryLog.instance.clear();
      final vm = buildVm(exercise: ExerciseType.squat);

      // Seed the auto-cal with two reps that span a viable ROM:
      // min=85°, max=175°, ROM excursion = 90° (≥ 40° gate).
      vm.seedSquatAutoCalForTest(85, 175, 2);
      final t = vm.resolveSquatThresholds(0);

      // Derived from `SquatRomThresholdSet.fromBucket(85, 175)`:
      //   start = 175 - 10 = 165
      //   bottom = 85 + 5 = 90
      //   end = 175 - 5 = 170
      expect(t.startAngle, closeTo(165, 1e-9));
      expect(t.bottomAngle, closeTo(90, 1e-9));
      expect(t.endAngle, closeTo(170, 1e-9));

      expect(
        TelemetryLog.instance.entries.any(
          (e) =>
              e.tag == 'squat.thresholds_resolved' &&
              e.message.contains('tier=2'),
        ),
        isTrue,
      );

      vm.dispose();
    });

    test('Tier 1: calibrated profile beats Tier 2 auto-cal '
        '(priority order pinned)', () {
      TelemetryLog.instance.clear();
      final vm = buildVm(exercise: ExerciseType.squat);

      // Seed BOTH a calibrated profile AND a viable auto-cal.
      // Profile values are deliberately distinct from auto-cal values so
      // the assertion discriminates between the two tiers.
      vm.seedSquatProfileForTest(
        SquatRomProfile(
          bucket: SquatRomBucket(
            observedMinKneeAngle: 80,
            observedMaxKneeAngle: 180,
            sampleCount: kSquatCalibrationMinReps,
          ),
        ),
      );
      vm.seedSquatAutoCalForTest(85, 175, 2);

      final t = vm.resolveSquatThresholds(0);

      // Tier 1 wins: derived from profile bucket (80, 180) with the same
      // margin policy:  start=170, bottom=85, end=175.
      expect(t.startAngle, closeTo(170, 1e-9));
      expect(t.bottomAngle, closeTo(85, 1e-9));
      expect(t.endAngle, closeTo(175, 1e-9));

      expect(
        TelemetryLog.instance.entries.any(
          (e) =>
              e.tag == 'squat.thresholds_resolved' &&
              e.message.contains('tier=1'),
        ),
        isTrue,
      );

      vm.dispose();
    });

    test('Tier 1: uncalibrated profile (sampleCount < min) falls through '
        'to Tier 2 / Tier 3', () {
      TelemetryLog.instance.clear();
      final vm = buildVm(exercise: ExerciseType.squat);

      // Profile exists but is under the calibration sample-count floor —
      // tier 1 should NOT activate. With no auto-cal seeded, the chain
      // falls through to tier 3.
      vm.seedSquatProfileForTest(
        SquatRomProfile(
          bucket: SquatRomBucket(
            observedMinKneeAngle: 80,
            observedMaxKneeAngle: 180,
            sampleCount: kSquatCalibrationMinReps - 1,
          ),
        ),
      );

      final t = vm.resolveSquatThresholds(0);

      // Tier 3 defaults — NOT the profile-derived values.
      expect(t.startAngle, kSquatStartAngle);
      expect(t.bottomAngle, kSquatBottomAngle);
      expect(t.endAngle, kSquatEndAngle);

      expect(
        TelemetryLog.instance.entries.any(
          (e) =>
              e.tag == 'squat.thresholds_resolved' &&
              e.message.contains('tier=3'),
        ),
        isTrue,
      );

      vm.dispose();
    });
  });
}

/// Session repo that records every `recentConcentricDurations` call for
/// assertion. Inherits all other behavior from InMemory so `init()` can load
/// profile-side state without surprises.
class _SpyingSessionRepository extends InMemorySessionRepository {
  final List<({ExerciseType exercise, Duration window, int limitReps})>
  concentricQueries = [];

  @override
  Future<List<Duration>> recentConcentricDurations({
    required ExerciseType exercise,
    required Duration window,
    int limitReps = 200,
  }) async {
    concentricQueries.add((
      exercise: exercise,
      window: window,
      limitReps: limitReps,
    ));
    return super.recentConcentricDurations(
      exercise: exercise,
      window: window,
      limitReps: limitReps,
    );
  }
}

/// Session repo whose baseline query throws — exercises the
/// `fatigue.baseline.load_failed` branch of `init()`.
class _BaselineThrowingRepository extends InMemorySessionRepository {
  @override
  Future<List<Duration>> recentConcentricDurations({
    required ExerciseType exercise,
    required Duration window,
    int limitReps = 200,
  }) async {
    throw StateError('simulated baseline failure');
  }
}
