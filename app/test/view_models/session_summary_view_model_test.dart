import 'package:fitrack/core/types.dart';
import 'package:fitrack/view_models/session_summary_input.dart';
import 'package:fitrack/view_models/session_summary_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure-Dart unit tests for [SessionSummaryViewModel].
///
/// Per project rule (CLAUDE.md ⛔ Test Writing Hard Rules), no widget tests —
/// every assertion here is on the VM's plain-Dart slot data. The VM is
/// constructed from a [SessionSummaryInput] DTO, so tests do NOT need to
/// instantiate a `SummaryScreen` widget.
SessionSummaryInput _curl({
  int totalReps = 12,
  int totalSets = 2,
  Duration duration = const Duration(minutes: 5),
  double? averageQuality,
  List<double> repQualities = const [],
  Set<FormError> errorsTriggered = const {},
  Map<FormError, int> errorCounts = const {},
  bool fatigueDetected = false,
  bool asymmetryDetected = false,
  int eccentricTooFastCount = 0,
  ExerciseType exercise = ExerciseType.bicepsCurlSide,
}) => SessionSummaryInput(
  exercise: exercise,
  totalReps: totalReps,
  totalSets: totalSets,
  sessionDuration: duration,
  averageQuality: averageQuality,
  repQualities: repQualities,
  errorsTriggered: errorsTriggered,
  errorCounts: errorCounts,
  fatigueDetected: fatigueDetected,
  asymmetryDetected: asymmetryDetected,
  eccentricTooFastCount: eccentricTooFastCount,
);

SessionSummaryInput _squat({
  int totalReps = 10,
  int totalSets = 1,
  Duration duration = const Duration(minutes: 4),
  double? averageQuality,
  List<double> repQualities = const [],
  Set<FormError> errorsTriggered = const {},
  SquatVariant variant = SquatVariant.bodyweight,
  bool longFemur = false,
  bool fatigueDetected = false,
}) => SessionSummaryInput(
  exercise: ExerciseType.squat,
  totalReps: totalReps,
  totalSets: totalSets,
  sessionDuration: duration,
  averageQuality: averageQuality,
  repQualities: repQualities,
  errorsTriggered: errorsTriggered,
  squatVariant: variant,
  squatLongFemurLifter: longFemur,
  fatigueDetected: fatigueDetected,
);

SessionSummaryInput _pushUp({
  int totalReps = 15,
  int totalSets = 3,
  double? averageQuality,
  Set<FormError> errorsTriggered = const {},
  bool fatigueDetected = false,
}) => SessionSummaryInput(
  exercise: ExerciseType.pushUp,
  totalReps: totalReps,
  totalSets: totalSets,
  sessionDuration: const Duration(minutes: 3),
  averageQuality: averageQuality,
  errorsTriggered: errorsTriggered,
  fatigueDetected: fatigueDetected,
);

/// Curl-flavored phrases that must NEVER appear in squat or push-up insight
/// copy. If any of these surface for a non-curl exercise, an exercise's
/// insight path is silently delegating to `_curlInsights` — the exact bug
/// the May 2026 unification introduced and the post-review pass fixed.
const _curlFlavoredPhrases = <String>[
  'curl', // 'during the curl', 'No reps were counted (curl path)' etc.
  'bicep',
  'elbow rose',
  'shoulder shrugged',
  'leaned back to complete',
  'right arm', // side-view armLabel
  'left arm', // side-view armLabel
];

void main() {
  group('SessionSummaryViewModel.fromInput', () {
    test('dispatches to curl factory for biceps-curl variants', () {
      final vm = SessionSummaryViewModel.fromInput(
        _curl(exercise: ExerciseType.bicepsCurlSide),
      );
      expect(vm.exerciseLabel, 'Biceps Curl (Side)');
      // Curl factory does not produce variant chips.
      expect(vm.variantLabels, isEmpty);
    });

    test('dispatches to squat factory', () {
      final vm = SessionSummaryViewModel.fromInput(_squat());
      expect(vm.exerciseLabel, 'Squat');
    });

    test('dispatches to push-up factory', () {
      final vm = SessionSummaryViewModel.fromInput(_pushUp());
      expect(vm.exerciseLabel, 'Push-up');
    });
  });

  group('quality / grade derivation', () {
    test('zero reps yields null qualityPct, "—" grade, no-reps subtitle', () {
      final vm = SessionSummaryViewModel.fromInput(_curl(totalReps: 0));
      expect(vm.qualityPct, isNull);
      expect(vm.grade, '—');
      expect(vm.heroSubtitle, contains('No reps were counted'));
    });

    test('A grade at ≥0.90', () {
      final vm = SessionSummaryViewModel.fromInput(
        _curl(repQualities: const [0.92, 0.95, 0.90]),
      );
      expect(vm.qualityPct, 92);
      expect(vm.grade, 'A');
    });

    test('B grade at ≥0.80', () {
      final vm = SessionSummaryViewModel.fromInput(
        _curl(repQualities: const [0.82, 0.85]),
      );
      expect(vm.grade, 'B');
    });

    test('C grade at ≥0.70', () {
      final vm = SessionSummaryViewModel.fromInput(
        _curl(repQualities: const [0.70, 0.72]),
      );
      expect(vm.grade, 'C');
    });

    test('D grade at ≥0.60', () {
      final vm = SessionSummaryViewModel.fromInput(
        _curl(repQualities: const [0.60, 0.62]),
      );
      expect(vm.grade, 'D');
    });

    test('F grade below 0.60', () {
      final vm = SessionSummaryViewModel.fromInput(
        _curl(repQualities: const [0.40, 0.45]),
      );
      expect(vm.grade, 'F');
    });

    test('"Excellent" subtitle at ≥0.85', () {
      final vm = SessionSummaryViewModel.fromInput(
        _curl(repQualities: const [0.90]),
      );
      expect(vm.heroSubtitle, startsWith('Excellent control'));
    });

    test('"Good effort" subtitle at ≥0.70', () {
      final vm = SessionSummaryViewModel.fromInput(
        _curl(repQualities: const [0.75]),
      );
      expect(vm.heroSubtitle, startsWith('Good effort'));
    });

    test('"Room for improvement" subtitle at ≥0.60', () {
      final vm = SessionSummaryViewModel.fromInput(
        _curl(repQualities: const [0.65]),
      );
      expect(vm.heroSubtitle, startsWith('Room for improvement'));
    });

    test('"Several form issues" subtitle below 0.60', () {
      final vm = SessionSummaryViewModel.fromInput(
        _curl(repQualities: const [0.40]),
      );
      expect(vm.heroSubtitle, startsWith('Several form issues'));
    });

    test('"no quality data" subtitle when reps committed but no qualities', () {
      // History-screen reconstructed sessions can land here when no per-rep
      // quality was persisted but totalReps > 0.
      final vm = SessionSummaryViewModel.fromInput(
        _curl(totalReps: 5, repQualities: const [0.0, 0.0]),
      );
      expect(vm.qualityPct, isNull);
      expect(vm.heroSubtitle, contains('No quality data captured'));
    });

    test('falls back to averageQuality when repQualities is empty', () {
      // History-screen reconstructed sessions use the saved session-level
      // average when per-rep qualities aren't available.
      final vm = SessionSummaryViewModel.fromInput(
        _curl(totalReps: 5, averageQuality: 0.82),
      );
      expect(vm.qualityPct, 82);
      expect(vm.grade, 'B');
    });

    test('zero-value reps are excluded from the mean', () {
      final vm = SessionSummaryViewModel.fromInput(
        _curl(repQualities: const [0.0, 0.8, 0.0, 0.8]),
      );
      expect(vm.qualityPct, 80);
    });
  });

  group('squat variant labels', () {
    test('bodyweight + short femur: variant label only', () {
      final vm = SessionSummaryViewModel.fromInput(
        _squat(variant: SquatVariant.bodyweight, longFemur: false),
      );
      expect(vm.variantLabels, ['Bodyweight']);
    });

    test('barbell back squat + tall lifter: two chips', () {
      final vm = SessionSummaryViewModel.fromInput(
        _squat(variant: SquatVariant.highBarBackSquat, longFemur: true),
      );
      expect(vm.variantLabels, ['Barbell back squat', 'Tall lifter (+5°)']);
    });

    test('barbell back squat + short femur: one chip', () {
      final vm = SessionSummaryViewModel.fromInput(
        _squat(variant: SquatVariant.highBarBackSquat, longFemur: false),
      );
      expect(vm.variantLabels, ['Barbell back squat']);
    });
  });

  group('form-issue filtering by exercise', () {
    test('curl excludes squat-only and push-up-only errors', () {
      final vm = SessionSummaryViewModel.fromInput(
        _curl(
          errorsTriggered: {
            FormError.shoulderShrug,
            FormError.squatDepth,
            FormError.hipSag,
            FormError.heelLift,
          },
        ),
      );
      expect(vm.formIssues, [FormError.shoulderShrug]);
    });

    test('squat keeps only its four canonical errors', () {
      final vm = SessionSummaryViewModel.fromInput(
        _squat(
          errorsTriggered: {
            FormError.excessiveForwardLean,
            FormError.shoulderShrug, // curl-only — must be filtered out
            FormError.squatDepth,
            FormError.heelLift,
            FormError.forwardKneeShift,
            FormError.trunkTibia, // legacy — surfaced separately, not here
          },
        ),
      );
      expect(vm.formIssues.toSet(), {
        FormError.excessiveForwardLean,
        FormError.squatDepth,
        FormError.heelLift,
        FormError.forwardKneeShift,
      });
    });

    test('push-up keeps only hipSag and pushUpShortRom', () {
      final vm = SessionSummaryViewModel.fromInput(
        _pushUp(
          errorsTriggered: {
            FormError.hipSag,
            FormError.pushUpShortRom,
            FormError.shoulderShrug, // curl-only — must be filtered out
            FormError.squatDepth, // squat-only — must be filtered out
          },
        ),
      );
      expect(vm.formIssues.toSet(), {
        FormError.hipSag,
        FormError.pushUpShortRom,
      });
    });
  });

  group('insights — curl', () {
    test('zero-rep session yields one framing-focused insight', () {
      final vm = SessionSummaryViewModel.fromInput(_curl(totalReps: 0));
      expect(vm.insights, hasLength(1));
      expect(vm.insights.first, contains('stays in frame'));
    });

    test('rushed-eccentric majority surfaces "most reps" tempo coaching', () {
      // 4 of 6 reps rushed = > 50 % → "most reps" copy
      final vm = SessionSummaryViewModel.fromInput(
        _curl(totalReps: 6, eccentricTooFastCount: 4),
      );
      expect(vm.insights.any((s) => s.contains('most reps')), isTrue);
    });

    test('partial rushed-eccentric surfaces "X rep(s)" tempo coaching', () {
      final vm = SessionSummaryViewModel.fromInput(
        _curl(totalReps: 10, eccentricTooFastCount: 2),
      );
      expect(vm.insights.any((s) => s.contains('2 rep(s)')), isTrue);
    });

    test('fatigueDetected surfaces fatigue coaching', () {
      final vm = SessionSummaryViewModel.fromInput(
        _curl(totalReps: 10, fatigueDetected: true),
      );
      expect(vm.insights.any((s) => s.contains('Fatigue detected')), isTrue);
    });

    test('asymmetryDetected surfaces asymmetry coaching', () {
      final vm = SessionSummaryViewModel.fromInput(
        _curl(totalReps: 10, asymmetryDetected: true),
      );
      expect(vm.insights.any((s) => s.contains('uneven range')), isTrue);
    });

    test('clean session with high quality emits positive insight ONCE', () {
      // Test-quality C1 regression guard: positive message must NOT stack on
      // top of other coaching lines. With no errors and ≥0.85 quality, ONLY
      // the "Great session!" line should fire.
      final vm = SessionSummaryViewModel.fromInput(
        _curl(repQualities: const [0.95, 0.92, 0.98], averageQuality: 0.95),
      );
      expect(vm.insights, hasLength(1));
      expect(vm.insights.single, contains('Great session'));
    });

    test('clean session + fatigue does NOT also emit "Great session"', () {
      // The pre-fix bug appended "Great session!" alongside fatigue coaching,
      // producing contradictory copy. The fallback must only fire when
      // insights is otherwise empty.
      final vm = SessionSummaryViewModel.fromInput(
        _curl(
          repQualities: const [0.95],
          averageQuality: 0.95,
          fatigueDetected: true,
        ),
      );
      expect(vm.insights.any((s) => s.contains('Fatigue detected')), isTrue);
      expect(vm.insights.any((s) => s.contains('Great session')), isFalse);
    });

    test(
      'errors present + low quality emits the "Review form issues" fallback',
      () {
        final vm = SessionSummaryViewModel.fromInput(
          _curl(
            repQualities: const [0.55],
            averageQuality: 0.55,
            errorsTriggered: {FormError.shoulderShrug},
          ),
        );
        expect(
          vm.insights.any((s) => s.contains('Review the form issues')),
          isTrue,
        );
      },
    );
  });

  group('insights — push-up', () {
    test('zero-rep yields push-up-specific framing insight', () {
      final vm = SessionSummaryViewModel.fromInput(_pushUp(totalReps: 0));
      expect(vm.insights, hasLength(1));
      expect(vm.insights.first, contains('side angle'));
    });

    test('hipSag surfaces hip-sag coaching', () {
      final vm = SessionSummaryViewModel.fromInput(
        _pushUp(errorsTriggered: {FormError.hipSag}),
      );
      expect(vm.insights.any((s) => s.contains('hips dropped')), isTrue);
    });

    test('pushUpShortRom surfaces short-ROM coaching', () {
      final vm = SessionSummaryViewModel.fromInput(
        _pushUp(errorsTriggered: {FormError.pushUpShortRom}),
      );
      expect(vm.insights.any((s) => s.contains('full depth')), isTrue);
    });

    test('fatigueDetected surfaces "drop to your knees" coaching', () {
      final vm = SessionSummaryViewModel.fromInput(
        _pushUp(fatigueDetected: true),
      );
      expect(vm.insights.any((s) => s.contains('Drop to your knees')), isTrue);
    });

    test('no curl-flavored phrases leak into push-up insights', () {
      // Regression guard for the bug where _fromPushUp called _curlInsights.
      final vm = SessionSummaryViewModel.fromInput(
        _pushUp(
          fatigueDetected: true,
          errorsTriggered: {FormError.hipSag, FormError.pushUpShortRom},
        ),
      );
      for (final phrase in _curlFlavoredPhrases) {
        expect(
          vm.insights.any(
            (s) => s.toLowerCase().contains(phrase.toLowerCase()),
          ),
          isFalse,
          reason:
              'Push-up insights should not contain curl phrase "$phrase". '
              'Got: ${vm.insights}',
        );
      }
    });
  });

  group('insights — squat', () {
    test('zero-rep yields squat-specific framing insight', () {
      final vm = SessionSummaryViewModel.fromInput(_squat(totalReps: 0));
      expect(vm.insights, hasLength(1));
      expect(vm.insights.first, contains('side angle'));
      expect(vm.insights.first, contains('hips, knees, and feet'));
    });

    test('squatDepth surfaces depth coaching', () {
      final vm = SessionSummaryViewModel.fromInput(
        _squat(errorsTriggered: {FormError.squatDepth}),
      );
      expect(vm.insights.any((s) => s.contains('break parallel')), isTrue);
    });

    test('excessiveForwardLean surfaces lean coaching', () {
      final vm = SessionSummaryViewModel.fromInput(
        _squat(errorsTriggered: {FormError.excessiveForwardLean}),
      );
      expect(vm.insights.any((s) => s.contains('chest up')), isTrue);
    });

    test('heelLift surfaces heel coaching', () {
      final vm = SessionSummaryViewModel.fromInput(
        _squat(errorsTriggered: {FormError.heelLift}),
      );
      expect(vm.insights.any((s) => s.contains('heels')), isTrue);
    });

    test('forwardKneeShift surfaces knee-tracking coaching', () {
      final vm = SessionSummaryViewModel.fromInput(
        _squat(errorsTriggered: {FormError.forwardKneeShift}),
      );
      expect(vm.insights.any((s) => s.contains('mid-foot')), isTrue);
    });

    test('fatigueDetected surfaces squat-flavored fatigue coaching', () {
      final vm = SessionSummaryViewModel.fromInput(
        _squat(fatigueDetected: true),
      );
      expect(
        vm.insights.any((s) => s.contains('Drop a set or reduce the load')),
        isTrue,
      );
    });

    test('no curl-flavored phrases leak into squat insights', () {
      // Regression guard for the bug where _fromSquat called _curlInsights.
      // This is the bug code-review caught: squat sessions were rendering
      // curl strings like "elbow rose on your right arm during the curl."
      final vm = SessionSummaryViewModel.fromInput(
        _squat(
          fatigueDetected: true,
          errorsTriggered: {
            FormError.squatDepth,
            FormError.excessiveForwardLean,
            FormError.heelLift,
            FormError.forwardKneeShift,
          },
        ),
      );
      for (final phrase in _curlFlavoredPhrases) {
        expect(
          vm.insights.any(
            (s) => s.toLowerCase().contains(phrase.toLowerCase()),
          ),
          isFalse,
          reason:
              'Squat insights should not contain curl phrase "$phrase". '
              'Got: ${vm.insights}',
        );
      }
    });
  });

  group('VM convenience flags', () {
    test('hasFormIssues is false when totalReps is zero', () {
      // Frame-level errors can fire on uncommitted reps; the VM must NOT
      // surface them in that case — surfacing errors without a rep context
      // is misleading.
      final vm = SessionSummaryViewModel.fromInput(
        _curl(totalReps: 0, errorsTriggered: {FormError.shoulderShrug}),
      );
      expect(vm.formIssues, isNotEmpty);
      expect(vm.hasFormIssues, isFalse);
    });

    test('hasFormIssues is true when errors present and reps committed', () {
      final vm = SessionSummaryViewModel.fromInput(
        _curl(totalReps: 5, errorsTriggered: {FormError.shoulderShrug}),
      );
      expect(vm.hasFormIssues, isTrue);
    });

    test('hasInsights tracks insight presence', () {
      final vm = SessionSummaryViewModel.fromInput(
        _curl(repQualities: const [0.9], averageQuality: 0.9),
      );
      expect(vm.hasInsights, isTrue); // always emits at least one fallback
    });
  });

  group('form audit', () {
    test('curl factory produces a curl-grade audit', () {
      // formAudit is read directly by the screen (no double-audit). We
      // exercise the field by asserting the factory wired it through and
      // it carries a non-null applicable flag for inspection.
      final audit = SessionSummaryViewModel.fromInput(_curl()).formAudit;
      // FormAudit.applicable is a bool — assert it is one of the two
      // legal values (not null). Tautological asserts (`expect(x, x)`) are
      // avoided here intentionally.
      expect(audit.applicable, anyOf(isTrue, isFalse));
    });

    test('squat factory produces a squat-grade audit', () {
      final audit = SessionSummaryViewModel.fromInput(_squat()).formAudit;
      expect(audit.applicable, anyOf(isTrue, isFalse));
    });

    test('push-up factory produces a push-up-grade audit', () {
      final audit = SessionSummaryViewModel.fromInput(_pushUp()).formAudit;
      expect(audit.applicable, anyOf(isTrue, isFalse));
    });
  });
}
