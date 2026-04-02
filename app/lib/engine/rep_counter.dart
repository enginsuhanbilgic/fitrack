import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../core/types.dart';
import '../models/landmark_types.dart';
import '../models/pose_result.dart';
import 'angle_utils.dart';
import 'form_analyzer.dart';

/// Snapshot returned after every frame — everything the UI needs.
class RepSnapshot {
  final int reps;
  final int sets;
  final RepState state;
  final double? jointAngle;
  final List<FormError> formErrors;

  const RepSnapshot({
    required this.reps,
    required this.sets,
    required this.state,
    this.jointAngle,
    this.formErrors = const [],
  });
}

/// Multi-exercise rep counter. Drives a 4-state FSM for biceps curl
/// and a 4-state FSM for squat / push-up.
///
/// Biceps curl (elbow angle θ):
///   IDLE ──[θ < 150°]──► CONCENTRIC ──[θ ≤ 40°]──► PEAK
///     ▲                                                │ [θ > 50°]
///     └───────────[θ ≥ 160°, rep++]──── ECCENTRIC ◄───┘
///
/// Squat (knee angle θ, + hip Y direction):
///   IDLE ──[θ < 160°]──► DESCENDING ──[θ < 90°]──► BOTTOM
///     ▲                                                │ [hipY decreasing]
///     └───────────[θ > 160°, rep++]──── ASCENDING ◄───┘
///
/// Push-up (elbow angle θ):
///   IDLE ──[θ < 160°]──► DESCENDING ──[θ < 90°]──► BOTTOM
///     ▲                                                │ [θ > 90°]
///     └───────────[θ > 160°, rep++]──── ASCENDING ◄───┘
class RepCounter {
  final ExerciseType exercise;
  final ExerciseSide side;
  final FormAnalyzer _form = FormAnalyzer();

  RepState _state = RepState.idle;
  int _reps = 0;
  int _sets = 1;
  double? _lastAngle;
  List<FormError> _lastErrors = const [];

  // Timing & Debounce
  DateTime? _lastTransitionTime;
  DateTime? _stateStartTime;

  // Smoothing: small ring buffer for angle.
  final List<double> _angleBuffer = [];
  static const int _smoothWindow = 3;

  // Squat: track previous hip Y to detect rising direction.
  double? _prevHipY;

  // Long-femur detection (squat only)
  final List<double> _repMinAngles = [];
  bool _longFemurDetected = false;
  double _effectiveSquatBottomAngle = kSquatBottomAngle;
  double? _minAngleThisRep;

  RepCounter({this.exercise = ExerciseType.bicepsCurl, this.side = ExerciseSide.both});

  RepSnapshot update(PoseResult result) {
    final now = DateTime.now();
    final angle = _computeAngle(result);
    _lastAngle = angle;

    if (angle == null) {
      return _snapshot();
    }

    // Simple moving-average smoothing on the angle.
    _angleBuffer.add(angle);
    if (_angleBuffer.length > _smoothWindow) _angleBuffer.removeAt(0);
    final smoothed = _angleBuffer.reduce((a, b) => a + b) / _angleBuffer.length;

    // Stuck-State Timer (Zombie detection)
    if (_state != RepState.idle && _stateStartTime != null) {
      if (now.difference(_stateStartTime!) > kStuckStateLimit) {
        _resetToIdle();
        return _snapshot();
      }
    }

    // Transition Lockout (Debounce)
    if (_lastTransitionTime != null &&
        now.difference(_lastTransitionTime!) < kStateDebounce) {
      return _snapshot();
    }

    final oldState = _state;

    switch (exercise) {
      case ExerciseType.bicepsCurl:
        _runCurlFsm(smoothed, result);
      case ExerciseType.squat:
        _runSquatFsm(smoothed, result);
      case ExerciseType.pushUp:
        _runPushUpFsm(smoothed, result);
    }

    if (_state != oldState) {
      _lastTransitionTime = now;
      _stateStartTime = now;
    }

    return _snapshot();
  }

  // ── Biceps Curl FSM ───────────────────────────────────

  void _runCurlFsm(double smoothed, PoseResult result) {
    switch (_state) {
      case RepState.idle:
        if (smoothed < kCurlStartAngle) {
          _state = RepState.concentric;
          _form.onRepStart(result);
        }
      case RepState.concentric:
        _lastErrors = _form.evaluate(result);
        if (smoothed <= kCurlPeakAngle) {
          _state = RepState.peak;
        } else if (smoothed > kCurlStartAngle) {
          _resetToIdle();
        }
      case RepState.peak:
        if (smoothed > kCurlPeakExitAngle) {
          _state = RepState.eccentric;
        }
      case RepState.eccentric:
        _lastErrors = _form.evaluate(result);
        if (smoothed >= kCurlEndAngle) {
          _reps++;
          _resetToIdle();
          _lastErrors = const [];
        }
      default:
        break;
    }
  }

  // ── Squat FSM ─────────────────────────────────────────

  void _runSquatFsm(double smoothed, PoseResult result) {
    final hipY = _computeHipY(result);

    // Track minimum knee angle during active descent for long-femur detection.
    if (_state == RepState.descending || _state == RepState.bottom) {
      if (_minAngleThisRep == null || smoothed < _minAngleThisRep!) {
        _minAngleThisRep = smoothed;
      }
    }

    switch (_state) {
      case RepState.idle:
        if (smoothed < kSquatStartAngle) {
          _state = RepState.descending;
        }
      case RepState.descending:
        if (smoothed < _effectiveSquatBottomAngle) {
          _state = RepState.bottom;
        } else if (smoothed > kSquatStartAngle) {
          // User stood back up before reaching bottom — abort
          _resetToIdle();
        }
      case RepState.bottom:
        // Transition to ascending only when hip is actually rising.
        // In screen coordinates Y=0 is top, so rising = Y decreasing.
        if (hipY != null && _prevHipY != null && hipY < _prevHipY!) {
          _state = RepState.ascending;
        }
      case RepState.ascending:
        if (smoothed >= kSquatEndAngle) {
          _reps++;
          // Long-femur detection: after kLongFemurDetectReps reps, check if
          // the user never reached 90° but consistently reached 95–100°.
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
          _lastErrors = const [];
        }
      default:
        break;
    }

    _prevHipY = hipY;
  }

  // ── Push-up FSM ───────────────────────────────────────

  void _runPushUpFsm(double smoothed, PoseResult result) {
    switch (_state) {
      case RepState.idle:
        if (smoothed < kPushUpStartAngle) {
          _state = RepState.descending;
        }
      case RepState.descending:
        if (smoothed < kPushUpBottomAngle) {
          _state = RepState.bottom;
        } else if (smoothed > kPushUpStartAngle) {
          _resetToIdle();
        }
      case RepState.bottom:
        if (smoothed > kPushUpBottomAngle) {
          _state = RepState.ascending;
        }
      case RepState.ascending:
        if (smoothed >= kPushUpEndAngle) {
          _reps++;
          _resetToIdle();
          _lastErrors = const [];
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
    _form.onRepEnd();
    _stateStartTime = null;
  }

  /// Start a new set — resets reps, keeps set count.
  void nextSet() {
    _sets++;
    _reps = 0;
    _angleBuffer.clear();
    _prevHipY = null;
    _minAngleThisRep = null;
    _repMinAngles.clear();
    _longFemurDetected = false;
    _effectiveSquatBottomAngle = kSquatBottomAngle;
    _form.reset();
    _state = RepState.idle;
    _stateStartTime = null;
    _lastErrors = const [];
  }

  /// Full reset.
  void reset() {
    _reps = 0;
    _sets = 1;
    _state = RepState.idle;
    _angleBuffer.clear();
    _prevHipY = null;
    _minAngleThisRep = null;
    _repMinAngles.clear();
    _longFemurDetected = false;
    _effectiveSquatBottomAngle = kSquatBottomAngle;
    _form.reset();
    _stateStartTime = null;
    _lastErrors = const [];
    _lastAngle = null;
  }

  double? _computeAngle(PoseResult r) {
    switch (exercise) {
      case ExerciseType.bicepsCurl:
        final leftAngle = angleDeg(
          r.landmark(LM.leftShoulder, minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.leftElbow, minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.leftWrist, minConfidence: kMinLandmarkConfidence),
        );
        final rightAngle = angleDeg(
          r.landmark(LM.rightShoulder, minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.rightElbow, minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.rightWrist, minConfidence: kMinLandmarkConfidence),
        );
        switch (side) {
          case ExerciseSide.left:
            return leftAngle;
          case ExerciseSide.right:
            return rightAngle;
          case ExerciseSide.both:
            if (leftAngle != null && rightAngle != null) return (leftAngle + rightAngle) / 2.0;
            return leftAngle ?? rightAngle;
        }

      case ExerciseType.squat:
        final leftAngle = angleDeg(
          r.landmark(LM.leftHip, minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.leftKnee, minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.leftAnkle, minConfidence: kMinLandmarkConfidence),
        );
        final rightAngle = angleDeg(
          r.landmark(LM.rightHip, minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.rightKnee, minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.rightAnkle, minConfidence: kMinLandmarkConfidence),
        );
        if (leftAngle != null && rightAngle != null) return (leftAngle + rightAngle) / 2.0;
        return leftAngle ?? rightAngle;

      case ExerciseType.pushUp:
        final leftAngle = angleDeg(
          r.landmark(LM.leftShoulder, minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.leftElbow, minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.leftWrist, minConfidence: kMinLandmarkConfidence),
        );
        final rightAngle = angleDeg(
          r.landmark(LM.rightShoulder, minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.rightElbow, minConfidence: kMinLandmarkConfidence),
          r.landmark(LM.rightWrist, minConfidence: kMinLandmarkConfidence),
        );
        if (leftAngle != null && rightAngle != null) return (leftAngle + rightAngle) / 2.0;
        return leftAngle ?? rightAngle;
    }
  }

  double? _computeHipY(PoseResult r) {
    final left = r.landmark(LM.leftHip, minConfidence: kMinLandmarkConfidence);
    final right = r.landmark(LM.rightHip, minConfidence: kMinLandmarkConfidence);
    if (left != null && right != null) return (left.y + right.y) / 2.0;
    return left?.y ?? right?.y;
  }

  RepSnapshot _snapshot() => RepSnapshot(
        reps: _reps,
        sets: _sets,
        state: _state,
        jointAngle: _lastAngle,
        formErrors: _lastErrors,
      );
}
