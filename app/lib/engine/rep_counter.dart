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

/// Snapshot returned after every frame — everything the UI needs.
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
  });
}

/// Multi-exercise rep counter. Drives a 4-state FSM for biceps curl
/// and a 4-state FSM for squat / push-up. Each exercise has its own
/// form analyzer for quality evaluation.
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

  final CurlFormAnalyzer _curlForm = CurlFormAnalyzer();
  final CurlViewDetector _viewDetector = CurlViewDetector();
  CurlCameraView _lockedView = CurlCameraView.unknown;

  final SquatFormAnalyzer _squatForm = SquatFormAnalyzer();
  final PushUpFormAnalyzer _pushUpForm = PushUpFormAnalyzer();

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

  // Curl: track whether PEAK was reached (for shortRom detection)
  bool _curlReachedPeak = false;

  // Curl: continuous view re-detection (active phase hysteresis)
  CurlCameraView _pendingView = CurlCameraView.unknown;
  int _pendingViewStreak = 0;

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

    // Continuous view re-detection for curl (active phase).
    if (exercise == ExerciseType.bicepsCurl && _lockedView != CurlCameraView.unknown) {
      _updateActiveViewDetection(result);
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

  /// Call once per frame during SETUP_CHECK and COUNTDOWN (biceps curl only).
  /// Returns the current detected view; [CurlCameraView.unknown] until locked.
  CurlCameraView updateSetupView(PoseResult pose) {
    if (exercise != ExerciseType.bicepsCurl) return CurlCameraView.unknown;
    final view = _viewDetector.update(pose);
    if (_viewDetector.isLocked && _lockedView == CurlCameraView.unknown) {
      _lockedView = view;
      _curlForm.setView(_lockedView);
    }
    return _lockedView;
  }

  // ── Biceps Curl FSM ───────────────────────────────────

  void _runCurlFsm(double smoothed, PoseResult result) {
    switch (_state) {
      case RepState.idle:
        if (smoothed < kCurlStartAngle) {
          _state = RepState.concentric;
          _curlReachedPeak = false;
          _curlForm.onRepStart(result);
        }
      case RepState.concentric:
        _lastErrors = _curlForm.evaluate(result);
        if (smoothed <= kCurlPeakAngle) {
          _state = RepState.peak;
          _curlReachedPeak = true;
          _curlForm.onPeakReached();
        } else if (smoothed > kCurlStartAngle) {
          // Abandoned rep — never reached peak
          if (!_curlReachedPeak) _curlForm.onAbortedRep();
          _lastErrors = [..._lastErrors, ..._curlForm.consumeCompletionErrors()];
          _resetToIdle();
        }
      case RepState.peak:
        if (smoothed > kCurlPeakExitAngle) {
          _state = RepState.eccentric;
          _curlForm.onEccentricStart();
        }
      case RepState.eccentric:
        _lastErrors = _curlForm.evaluate(result);
        if (smoothed >= kCurlEndAngle) {
          _reps++;
          // Record bilateral angles for asymmetry detection (front view).
          _curlForm.recordBilateralAngles(
            _computeBilateralAngle(result, left: true),
            _computeBilateralAngle(result, left: false),
          );
          final completionErrors = _curlForm.consumeCompletionErrors();
          _lastErrors = [..._lastErrors, ...completionErrors];
          _curlForm.onRepEnd();
          _resetToIdle();
        }
      default:
        break;
    }
  }

  // ── Curl Active-Phase View Re-Detection ───────────────

  /// Runs every frame during ACTIVE phase (curl only).
  /// Classifies the current frame and increments a streak counter when
  /// consecutive frames agree on a view different from the locked one.
  /// Only applies the switch when the FSM is idle — never mid-rep.
  void _updateActiveViewDetection(PoseResult result) {
    final candidate = _viewDetector.classifyFrame(result);

    if (candidate == CurlCameraView.unknown || candidate == _lockedView) {
      // No evidence for a different view — reset streak.
      _pendingView = CurlCameraView.unknown;
      _pendingViewStreak = 0;
      return;
    }

    if (candidate == _pendingView) {
      _pendingViewStreak++;
    } else {
      // New candidate — start fresh streak.
      _pendingView = candidate;
      _pendingViewStreak = 1;
    }

    // Only switch when hysteresis threshold met AND FSM is idle (never mid-rep).
    if (_pendingViewStreak >= kViewRedetectHysteresisFrames &&
        _state == RepState.idle) {
      _lockedView = _pendingView;
      _curlForm.setView(_lockedView);
      _pendingView = CurlCameraView.unknown;
      _pendingViewStreak = 0;
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
        // Transition to ascending only when hip is actually rising.
        // In screen coordinates Y=0 is top, so rising = Y decreasing.
        if (hipY != null && _prevHipY != null && hipY < _prevHipY!) {
          _state = RepState.ascending;
        }
      case RepState.ascending:
        _lastErrors = _squatForm.evaluate(result);
        if (smoothed >= kSquatEndAngle) {
          _reps++;
          final completionErrors = _squatForm.consumeCompletionErrors(_effectiveSquatBottomAngle);
          _lastErrors = [..._lastErrors, ...completionErrors];

          // Long-femur detection
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
    _curlReachedPeak = false;
    _stateStartTime = null;
    // Apply any deferred view switch now that we're back to idle.
    if (_pendingViewStreak >= kViewRedetectHysteresisFrames &&
        _pendingView != CurlCameraView.unknown) {
      _lockedView = _pendingView;
      _curlForm.setView(_lockedView);
      _pendingView = CurlCameraView.unknown;
      _pendingViewStreak = 0;
    }
  }

  /// Start a new set — resets reps, keeps set count.
  void nextSet() {
    _sets++;
    _reps = 0;
    _angleBuffer.clear();
    _prevHipY = null;
    _minAngleThisRep = null;
    _curlReachedPeak = false;
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
    _curlReachedPeak = false;
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

  double? _computeAngle(PoseResult r) {
    switch (exercise) {
      case ExerciseType.bicepsCurl:
        // Use a lower confidence gate for curl angle — allows tracking
        // even when the user turns slightly and landmarks get noisier.
        const curlConf = 0.2;
        final leftAngle = angleDeg(
          r.landmark(LM.leftShoulder, minConfidence: curlConf),
          r.landmark(LM.leftElbow,    minConfidence: curlConf),
          r.landmark(LM.leftWrist,    minConfidence: curlConf),
        );
        final rightAngle = angleDeg(
          r.landmark(LM.rightShoulder, minConfidence: curlConf),
          r.landmark(LM.rightElbow,    minConfidence: curlConf),
          r.landmark(LM.rightWrist,    minConfidence: curlConf),
        );
        // Always try both arms and use whichever is available.
        // When both visible, average them; otherwise use whichever works.
        // This ensures counting continues even when user turns to the side.
        if (leftAngle != null && rightAngle != null) return (leftAngle + rightAngle) / 2.0;
        return leftAngle ?? rightAngle;

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
        detectedView: _lockedView,
        lastRepQuality: exercise == ExerciseType.bicepsCurl ? _curlForm.lastRepQuality : null,
        averageQuality: exercise == ExerciseType.bicepsCurl ? _curlForm.averageQuality : null,
        repQualities: exercise == ExerciseType.bicepsCurl ? _curlForm.repQualities : const [],
        fatigueDetected: exercise == ExerciseType.bicepsCurl ? _curlForm.fatigueDetected : false,
        eccentricTooFastCount: exercise == ExerciseType.bicepsCurl ? _curlForm.eccentricTooFastCount : 0,
        errorsTriggered: const {},
      );
}
