import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../core/types.dart';
import '../models/landmark_types.dart';
import '../models/pose_result.dart';
import 'angle_utils.dart';
import 'curl/curl_form_analyzer.dart';
import 'curl/curl_view_detector.dart';
import 'squat/squat_form_analyzer.dart';
import 'push_up/push_up_form_analyzer.dart';

// ── Per-arm state machine (biceps curl only) ─────────────

/// Holds all state for one arm's rep-counting FSM.
class _ArmFsm {
  RepState state = RepState.idle;
  int reps = 0;
  final List<double> _buf = [];
  bool reachedPeak = false;
  DateTime? _lastTransition;
  DateTime? _stateStart;

  static const int _window = 3;

  void addAngle(double angle) {
    _buf.add(angle);
    if (_buf.length > _window) _buf.removeAt(0);
  }

  double? get smoothed {
    if (_buf.isEmpty) return null;
    return _buf.reduce((a, b) => a + b) / _buf.length;
  }

  bool get isDebouncing {
    if (_lastTransition == null) return false;
    return DateTime.now().difference(_lastTransition!) < kStateDebounce;
  }

  bool get isStuck {
    if (state == RepState.idle || _stateStart == null) return false;
    return DateTime.now().difference(_stateStart!) > kStuckStateLimit;
  }

  void transition(RepState next) {
    state = next;
    final now = DateTime.now();
    _lastTransition = now;
    _stateStart = now;
  }

  void forceIdle() {
    state = RepState.idle;
    reachedPeak = false;
    _stateStart = null;
    _lastTransition = DateTime.now(); // keeps debounce active after reset
  }

  void reset() {
    state = RepState.idle;
    reps = 0;
    _buf.clear();
    reachedPeak = false;
    _lastTransition = null;
    _stateStart = null;
  }
}

// ── RepSnapshot ──────────────────────────────────────────

/// Everything the UI needs after every frame.
class RepSnapshot {
  final int reps;
  final int sets;
  final RepState state;
  final double? jointAngle;
  final List<FormError> formErrors;
  final CurlCameraView detectedView;
  final double? lastRepQuality;
  final double? averageQuality;
  final List<double> repQualities;
  final bool fatigueDetected;
  final int eccentricTooFastCount;
  final Set<FormError> errorsTriggered;
  /// Per-arm rep counts — only meaningful for bicepsCurl; both 0 otherwise.
  final int leftReps;
  final int rightReps;

  const RepSnapshot({
    required this.reps,
    required this.sets,
    required this.state,
    this.jointAngle,
    this.formErrors = const [],
    this.detectedView = CurlCameraView.unknown,
    this.lastRepQuality,
    this.averageQuality,
    this.repQualities = const [],
    this.fatigueDetected = false,
    this.eccentricTooFastCount = 0,
    this.errorsTriggered = const {},
    this.leftReps = 0,
    this.rightReps = 0,
  });
}

// ── RepCounter ───────────────────────────────────────────

/// Multi-exercise rep counter.
///
/// Biceps curl uses TWO independent per-arm FSMs so left and right reps
/// are tracked separately. The primary arm (determined by view lock) also
/// drives form analysis; the secondary arm only counts reps.
///
/// Squat and push-up use the original single 4-state FSM.
class RepCounter {
  final ExerciseType exercise;
  final ExerciseSide side;

  // ── Form analyzers ────────────────────────────────────
  final CurlFormAnalyzer _curlForm = CurlFormAnalyzer();
  final CurlViewDetector _viewDetector = CurlViewDetector();
  CurlCameraView _lockedView = CurlCameraView.unknown;

  final SquatFormAnalyzer _squatForm = SquatFormAnalyzer();
  final PushUpFormAnalyzer _pushUpForm = PushUpFormAnalyzer();

  // ── Curl per-arm FSMs ─────────────────────────────────
  final _ArmFsm _leftArm = _ArmFsm();
  final _ArmFsm _rightArm = _ArmFsm();
  // Which arm currently owns form analysis (null = neither, mid-rep).
  bool? _formArmIsLeft;

  // ── Squat / push-up single FSM ────────────────────────
  RepState _state = RepState.idle;
  int _reps = 0;
  int _sets = 1;
  double? _lastAngle;
  List<FormError> _lastErrors = const [];

  DateTime? _lastTransitionTime;
  DateTime? _stateStartTime;

  final List<double> _angleBuffer = [];
  static const int _smoothWindow = 3;

  double? _prevHipY;
  final List<double> _repMinAngles = [];
  bool _longFemurDetected = false;
  double _effectiveSquatBottomAngle = kSquatBottomAngle;
  double? _minAngleThisRep;

  // ── Active-phase view re-detection (curl) ─────────────
  CurlCameraView _pendingView = CurlCameraView.unknown;
  int _pendingViewStreak = 0;

  RepCounter({this.exercise = ExerciseType.bicepsCurl, this.side = ExerciseSide.both});

  // ── Public API ────────────────────────────────────────

  RepSnapshot update(PoseResult result) {
    final now = DateTime.now();
    final angle = _computeAngle(result);
    _lastAngle = angle;

    if (angle == null) return _snapshot();

    if (exercise == ExerciseType.bicepsCurl) {
      // Curl: independent per-arm FSMs; view re-detection runs in background.
      if (_lockedView != CurlCameraView.unknown) {
        _updateActiveViewDetection(result);
      }
      _runCurlFsm(result);
    } else {
      // Squat / push-up: shared single-angle FSM.
      _angleBuffer.add(angle);
      if (_angleBuffer.length > _smoothWindow) _angleBuffer.removeAt(0);
      final smoothed = _angleBuffer.reduce((a, b) => a + b) / _angleBuffer.length;

      if (_state != RepState.idle && _stateStartTime != null) {
        if (now.difference(_stateStartTime!) > kStuckStateLimit) {
          _resetToIdle();
          return _snapshot();
        }
      }
      if (_lastTransitionTime != null &&
          now.difference(_lastTransitionTime!) < kStateDebounce) {
        return _snapshot();
      }

      final oldState = _state;
      switch (exercise) {
        case ExerciseType.squat:
          _runSquatFsm(smoothed, result);
        case ExerciseType.pushUp:
          _runPushUpFsm(smoothed, result);
        default:
          break;
      }
      if (_state != oldState) {
        _lastTransitionTime = now;
        _stateStartTime = now;
      }
    }

    return _snapshot();
  }

  /// Feed frames during SETUP_CHECK and COUNTDOWN to lock the camera view.
  CurlCameraView updateSetupView(PoseResult pose) {
    if (exercise != ExerciseType.bicepsCurl) return CurlCameraView.unknown;
    final view = _viewDetector.update(pose);
    if (_viewDetector.isLocked && _lockedView == CurlCameraView.unknown) {
      _lockedView = view;
      _curlForm.setView(_lockedView);
    }
    return _lockedView;
  }

  /// Start a new set — resets reps, keeps set count and locked view.
  void nextSet() {
    _sets++;
    _reps = 0;
    _leftArm.reset();
    _rightArm.reset();
    _formArmIsLeft = null;
    _angleBuffer.clear();
    _prevHipY = null;
    _minAngleThisRep = null;
    _repMinAngles.clear();
    _longFemurDetected = false;
    _effectiveSquatBottomAngle = kSquatBottomAngle;
    // Intentionally keep _lockedView and _viewDetector — the user is in the
    // same position between sets, so the detected view remains valid.
    _curlForm.reset();
    _curlForm.setView(_lockedView); // re-apply view after form reset
    _squatForm.reset();
    _pushUpForm.reset();
    _state = RepState.idle;
    _stateStartTime = null;
    _lastErrors = const [];
  }

  /// Full reset — clears everything including view detection.
  void reset() {
    _reps = 0;
    _sets = 1;
    _state = RepState.idle;
    _leftArm.reset();
    _rightArm.reset();
    _formArmIsLeft = null;
    _angleBuffer.clear();
    _prevHipY = null;
    _minAngleThisRep = null;
    _repMinAngles.clear();
    _longFemurDetected = false;
    _effectiveSquatBottomAngle = kSquatBottomAngle;
    _viewDetector.reset();
    _lockedView = CurlCameraView.unknown;
    _pendingView = CurlCameraView.unknown;
    _pendingViewStreak = 0;
    _curlForm.reset();
    _squatForm.reset();
    _pushUpForm.reset();
    _stateStartTime = null;
    _lastErrors = const [];
    _lastAngle = null;
  }

  // ── Biceps Curl per-arm FSM ───────────────────────────

  void _runCurlFsm(PoseResult result) {
    final now = DateTime.now();

    final lAngle = angleDeg(
      result.landmark(LM.leftShoulder,  minConfidence: kMinLandmarkConfidence),
      result.landmark(LM.leftElbow,     minConfidence: kMinLandmarkConfidence),
      result.landmark(LM.leftWrist,     minConfidence: kMinLandmarkConfidence),
    );
    final rAngle = angleDeg(
      result.landmark(LM.rightShoulder, minConfidence: kMinLandmarkConfidence),
      result.landmark(LM.rightElbow,    minConfidence: kMinLandmarkConfidence),
      result.landmark(LM.rightWrist,    minConfidence: kMinLandmarkConfidence),
    );

    if (lAngle != null) _leftArm.addAngle(lAngle);
    if (rAngle != null) _rightArm.addAngle(rAngle);

    _stepArmFsm(_leftArm,  isLeft: true,  result: result, now: now);
    _stepArmFsm(_rightArm, isLeft: false, result: result, now: now);

    // Show the angle of whichever arm is currently moving.
    if (_leftArm.state != RepState.idle && _leftArm.smoothed != null) {
      _lastAngle = _leftArm.smoothed;
    } else if (_rightArm.state != RepState.idle && _rightArm.smoothed != null) {
      _lastAngle = _rightArm.smoothed;
    }
  }

  void _stepArmFsm(
    _ArmFsm arm, {
    required bool isLeft,
    required PoseResult result,
    required DateTime now,
  }) {
    if (arm.isStuck) {
      arm.forceIdle();
      if (_formArmIsLeft == isLeft) _formArmIsLeft = null;
      return;
    }
    if (arm.isDebouncing) return;

    final smoothed = arm.smoothed;
    if (smoothed == null) return;

    // Only the arm that claimed form-analysis ownership writes to _lastErrors
    // and calls form-analyzer lifecycle methods.
    final bool isPrimary = _formArmIsLeft == isLeft;

    switch (arm.state) {
      case RepState.idle:
        if (smoothed < kCurlStartAngle) {
          arm.transition(RepState.concentric);
          arm.reachedPeak = false;
          // Claim form analysis if no arm currently owns it.
          if (_formArmIsLeft == null) {
            _formArmIsLeft = isLeft;
            _curlForm.onRepStart(result);
          }
        }
      case RepState.concentric:
        if (isPrimary) _lastErrors = _curlForm.evaluate(result);
        if (smoothed <= kCurlPeakAngle) {
          arm.transition(RepState.peak);
          arm.reachedPeak = true;
          if (isPrimary) _curlForm.onPeakReached();
        } else if (smoothed > kCurlStartAngle) {
          // Abandoned rep — never reached peak.
          if (!arm.reachedPeak && isPrimary) _curlForm.onAbortedRep();
          if (isPrimary) {
            _lastErrors = [..._lastErrors, ..._curlForm.consumeCompletionErrors()];
            _formArmIsLeft = null;
          }
          arm.forceIdle();
        }
      case RepState.peak:
        if (smoothed > kCurlPeakExitAngle) {
          arm.transition(RepState.eccentric);
          if (isPrimary) _curlForm.onEccentricStart();
        }
      case RepState.eccentric:
        if (isPrimary) _lastErrors = _curlForm.evaluate(result);
        if (smoothed >= kCurlEndAngle) {
          arm.reps++;
          if (isPrimary) {
            _curlForm.recordBilateralAngles(
              _computeBilateralAngle(result, left: true),
              _computeBilateralAngle(result, left: false),
            );
            _lastErrors = [..._lastErrors, ..._curlForm.consumeCompletionErrors()];
            _curlForm.onRepEnd();
            _formArmIsLeft = null;
          }
          arm.forceIdle();
        }
      default:
        break;
    }
  }

  // ── Active-Phase View Re-Detection ───────────────────

  void _updateActiveViewDetection(PoseResult result) {
    final candidate = _viewDetector.classifyFrame(result);

    if (candidate == CurlCameraView.unknown || candidate == _lockedView) {
      _pendingView = CurlCameraView.unknown;
      _pendingViewStreak = 0;
      return;
    }

    if (candidate == _pendingView) {
      _pendingViewStreak++;
    } else {
      _pendingView = candidate;
      _pendingViewStreak = 1;
    }

    // Switch only when both arms are idle — never mid-rep.
    if (_pendingViewStreak >= kViewRedetectHysteresisFrames &&
        _leftArm.state == RepState.idle &&
        _rightArm.state == RepState.idle) {
      _lockedView = _pendingView;
      _curlForm.setView(_lockedView);
      _pendingView = CurlCameraView.unknown;
      _pendingViewStreak = 0;
    }
  }

  // ── Squat FSM ─────────────────────────────────────────

  void _runSquatFsm(double smoothed, PoseResult result) {
    final hipY = _computeHipY(result);

    if (_state == RepState.descending || _state == RepState.bottom) {
      if (_minAngleThisRep == null || smoothed < _minAngleThisRep!) {
        _minAngleThisRep = smoothed;
      }
      _squatForm.trackAngle(smoothed);
    }

    switch (_state) {
      case RepState.idle:
        if (smoothed < kSquatStartAngle) {
          _state = RepState.descending;
          _squatForm.onRepStart();
        }
      case RepState.descending:
        if (smoothed < _effectiveSquatBottomAngle) {
          _state = RepState.bottom;
        } else if (smoothed > kSquatStartAngle) {
          _resetToIdle();
        }
      case RepState.bottom:
        if (hipY != null && _prevHipY != null && hipY < _prevHipY!) {
          _state = RepState.ascending;
        }
      case RepState.ascending:
        _lastErrors = _squatForm.evaluate(result);
        if (smoothed >= kSquatEndAngle) {
          _reps++;
          final completionErrors = _squatForm.consumeCompletionErrors(_effectiveSquatBottomAngle);
          _lastErrors = [..._lastErrors, ...completionErrors];

          if (!_longFemurDetected && _minAngleThisRep != null) {
            _repMinAngles.add(_minAngleThisRep!);
            if (_repMinAngles.length >= kLongFemurDetectReps) {
              final allAbove90 = _repMinAngles.every((a) => a > kSquatBottomAngle);
              final allReached100 = _repMinAngles.every((a) => a <= kLongFemurBottomAngle);
              if (allAbove90 && allReached100) {
                _longFemurDetected = true;
                _effectiveSquatBottomAngle = kLongFemurBottomAngle;
                debugPrint('[RepCounter] Long-femur detected — relaxing BOTTOM to $kLongFemurBottomAngle°');
              }
            }
          }
          _resetToIdle();
        }
      default:
        break;
    }

    _prevHipY = hipY;
  }

  // ── Push-up FSM ───────────────────────────────────────

  void _runPushUpFsm(double smoothed, PoseResult result) {
    if (_state == RepState.descending || _state == RepState.bottom) {
      _pushUpForm.trackAngle(smoothed);
    }

    switch (_state) {
      case RepState.idle:
        if (smoothed < kPushUpStartAngle) {
          _state = RepState.descending;
          _pushUpForm.onRepStart();
        }
      case RepState.descending:
        if (smoothed < kPushUpBottomAngle) {
          _state = RepState.bottom;
        } else if (smoothed > kPushUpStartAngle) {
          _resetToIdle();
        }
      case RepState.bottom:
        _lastErrors = _pushUpForm.evaluate(result);
        if (smoothed > kPushUpBottomAngle) {
          _state = RepState.ascending;
        }
      case RepState.ascending:
        _lastErrors = _pushUpForm.evaluate(result);
        if (smoothed >= kPushUpEndAngle) {
          _reps++;
          final completionErrors = _pushUpForm.consumeCompletionErrors();
          _lastErrors = [..._lastErrors, ...completionErrors];
          _resetToIdle();
        }
      default:
        break;
    }
  }

  // ── Helpers ───────────────────────────────────────────

  void _resetToIdle() {
    _state = RepState.idle;
    _prevHipY = null;
    _minAngleThisRep = null;
    _stateStartTime = null;
    if (_pendingViewStreak >= kViewRedetectHysteresisFrames &&
        _pendingView != CurlCameraView.unknown) {
      _lockedView = _pendingView;
      _curlForm.setView(_lockedView);
      _pendingView = CurlCameraView.unknown;
      _pendingViewStreak = 0;
    }
  }

  double? _computeAngle(PoseResult r) {
    switch (exercise) {
      case ExerciseType.bicepsCurl:
        final l = angleDeg(
          r.landmark(LM.leftShoulder,  minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.leftElbow,     minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.leftWrist,     minConfidence: kMinLandmarkConfidence),
        );
        final rr = angleDeg(
          r.landmark(LM.rightShoulder, minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.rightElbow,    minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.rightWrist,    minConfidence: kMinLandmarkConfidence),
        );
        if (l != null && rr != null) return (l + rr) / 2.0;
        return l ?? rr;

      case ExerciseType.squat:
        final l = angleDeg(
          r.landmark(LM.leftHip,   minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.leftKnee,  minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.leftAnkle, minConfidence: kMinLandmarkConfidence),
        );
        final rr = angleDeg(
          r.landmark(LM.rightHip,   minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.rightKnee,  minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.rightAnkle, minConfidence: kMinLandmarkConfidence),
        );
        if (l != null && rr != null) return (l + rr) / 2.0;
        return l ?? rr;

      case ExerciseType.pushUp:
        final l = angleDeg(
          r.landmark(LM.leftShoulder, minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.leftElbow,    minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.leftWrist,    minConfidence: kMinLandmarkConfidence),
        );
        final rr = angleDeg(
          r.landmark(LM.rightShoulder, minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.rightElbow,    minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.rightWrist,    minConfidence: kMinLandmarkConfidence),
        );
        if (l != null && rr != null) return (l + rr) / 2.0;
        return l ?? rr;
    }
  }

  double? _computeBilateralAngle(PoseResult r, {required bool left}) {
    if (left) {
      return angleDeg(
        r.landmark(LM.leftShoulder, minConfidence: kMinLandmarkConfidence),
        r.landmark(LM.leftElbow,    minConfidence: kMinLandmarkConfidence),
        r.landmark(LM.leftWrist,    minConfidence: kMinLandmarkConfidence),
      );
    }
    return angleDeg(
      r.landmark(LM.rightShoulder, minConfidence: kMinLandmarkConfidence),
      r.landmark(LM.rightElbow,    minConfidence: kMinLandmarkConfidence),
      r.landmark(LM.rightWrist,    minConfidence: kMinLandmarkConfidence),
    );
  }

  double? _computeHipY(PoseResult r) {
    final left  = r.landmark(LM.leftHip,  minConfidence: kMinLandmarkConfidence);
    final right = r.landmark(LM.rightHip, minConfidence: kMinLandmarkConfidence);
    if (left != null && right != null) return (left.y + right.y) / 2.0;
    return left?.y ?? right?.y;
  }

  RepSnapshot _snapshot() {
    final int leftR  = _leftArm.reps;
    final int rightR = _rightArm.reps;
    final int totalR = exercise == ExerciseType.bicepsCurl ? leftR + rightR : _reps;

    final RepState displayState = exercise == ExerciseType.bicepsCurl
        ? (_leftArm.state != RepState.idle
            ? _leftArm.state
            : _rightArm.state != RepState.idle
                ? _rightArm.state
                : RepState.idle)
        : _state;

    return RepSnapshot(
      reps: totalR,
      sets: _sets,
      state: displayState,
      jointAngle: _lastAngle,
      formErrors: _lastErrors,
      detectedView: _lockedView,
      lastRepQuality:      exercise == ExerciseType.bicepsCurl ? _curlForm.lastRepQuality  : null,
      averageQuality:      exercise == ExerciseType.bicepsCurl ? _curlForm.averageQuality  : null,
      repQualities:        exercise == ExerciseType.bicepsCurl ? _curlForm.repQualities    : const [],
      fatigueDetected:     exercise == ExerciseType.bicepsCurl ? _curlForm.fatigueDetected : false,
      eccentricTooFastCount: exercise == ExerciseType.bicepsCurl ? _curlForm.eccentricTooFastCount : 0,
      errorsTriggered: const {},
      leftReps:  exercise == ExerciseType.bicepsCurl ? leftR  : 0,
      rightReps: exercise == ExerciseType.bicepsCurl ? rightR : 0,
    );
  }
}
