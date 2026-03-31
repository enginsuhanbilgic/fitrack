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
  final double? elbowAngle;
  final List<FormError> formErrors;

  const RepSnapshot({
    required this.reps,
    required this.sets,
    required this.state,
    this.elbowAngle,
    this.formErrors = const [],
  });
}

/// 4-state FSM for biceps curl counting with form analysis.
///
/// States per proposal (Figure 5):
///   IDLE  ──[θ < 150°]──►  CONCENTRIC  ──[θ ≤ 40°]──►  PEAK
///     ▲                                                   │
///     │                                                   │ [θ > 50°]
///     │                                                   ▼
///     └───────────[θ ≥ 160°, rep++]──────  ECCENTRIC ◄────┘
class RepCounter {
  final ExerciseSide side;
  final FormAnalyzer _form = FormAnalyzer();

  RepState _state = RepState.idle;
  int _reps = 0;
  int _sets = 1;
  double? _lastAngle;
  List<FormError> _lastErrors = const [];

  // Smoothing: small ring buffer for angle.
  final List<double> _angleBuffer = [];
  static const int _smoothWindow = 3;

  RepCounter({this.side = ExerciseSide.both});

  RepSnapshot update(PoseResult result) {
    final angle = _computeAngle(result);
    _lastAngle = angle;

    if (angle == null) {
      return _snapshot();
    }

    // Simple moving-average smoothing on the angle.
    _angleBuffer.add(angle);
    if (_angleBuffer.length > _smoothWindow) _angleBuffer.removeAt(0);
    final smoothed =
        _angleBuffer.reduce((a, b) => a + b) / _angleBuffer.length;

    // ── FSM transitions ──
    switch (_state) {
      case RepState.idle:
        if (smoothed < kCurlStartAngle) {
          _state = RepState.concentric;
          _form.onRepStart(result); // snapshot for form comparison
        }
        break;

      case RepState.concentric:
        _lastErrors = _form.evaluate(result);
        if (smoothed <= kCurlPeakAngle) {
          _state = RepState.peak;
        }
        // Safety: if user extends back without reaching peak → drop rep.
        if (smoothed > kCurlStartAngle) {
          _state = RepState.idle;
          _form.onRepEnd();
        }
        break;

      case RepState.peak:
        if (smoothed > kCurlPeakExitAngle) {
          _state = RepState.eccentric;
        }
        break;

      case RepState.eccentric:
        _lastErrors = _form.evaluate(result);
        if (smoothed >= kCurlEndAngle) {
          _reps++;
          _state = RepState.idle;
          _form.onRepEnd();
          _lastErrors = const [];
        }
        break;
    }

    return _snapshot();
  }

  /// Start a new set — resets reps, keeps set count.
  void nextSet() {
    _sets++;
    _reps = 0;
    _angleBuffer.clear();
    _form.reset();
    _state = RepState.idle;
    _lastErrors = const [];
  }

  /// Full reset.
  void reset() {
    _reps = 0;
    _sets = 1;
    _state = RepState.idle;
    _angleBuffer.clear();
    _form.reset();
    _lastErrors = const [];
    _lastAngle = null;
  }

  // ── Private helpers ──

  double? _computeAngle(PoseResult r) {
    // Compute both arms, pick based on [side].
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
        if (leftAngle != null && rightAngle != null) {
          return (leftAngle + rightAngle) / 2.0;
        }
        return leftAngle ?? rightAngle;
    }
  }

  RepSnapshot _snapshot() => RepSnapshot(
        reps: _reps,
        sets: _sets,
        state: _state,
        elbowAngle: _lastAngle,
        formErrors: _lastErrors,
      );
}
