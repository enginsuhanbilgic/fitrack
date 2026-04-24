/// Calibration-only rep detector.
///
/// Watches the elbow angle stream and emits one [RepExtreme] per detected
/// curl rep. **Not** the workout FSM — used only by the calibration overlay
/// where the full FSM is intentionally bypassed (no thresholds yet to drive
/// it).
///
/// Detection algorithm:
///   1. Smooth raw angle with a 3-frame buffer (matches the workout FSM).
///   2. Track sample-to-sample direction; require [_directionConfirmFrames]
///      consecutive same-sign steps to *confirm* a direction.
///   3. The cycle is anchored at the first confirmed local max (rest). The
///      rep emits at the **bottom turning point** — when descent flips to
///      confirmed ascent — using the running min as `minAngle` and the
///      anchored max as `maxAngle`. Biomechanically the lift is "done" at
///      peak flexion; emitting here lets the UI count reps live.
///   4. The cycle's ROM (max − min) must be ≥ [kCalibrationMinExcursion];
///      otherwise the candidate is discarded silently.
///   5. After emission, the next cycle re-anchors: the user must extend back
///      out (ascent run continues) and a fresh confirmed descent restarts
///      the cycle.
library;

import 'dart:async';

import '../../core/constants.dart';

class RepExtreme {
  final double minAngle;
  final double maxAngle;

  const RepExtreme({required this.minAngle, required this.maxAngle});

  @override
  String toString() => 'RepExtreme(min=$minAngle, max=$maxAngle)';
}

enum _Phase { awaitingFirstMax, descending, ascending }

class RepBoundaryDetector {
  static const int _smoothWindow = 3;
  static const int _directionConfirmFrames = 3;

  final List<double> _angleBuffer = <double>[];
  final StreamController<RepExtreme> _controller =
      StreamController<RepExtreme>.broadcast();

  double? _prevSmoothed;

  /// Direction of the *current confirmed* phase: 1 = ascending, -1 = descending.
  int _confirmedDir = 0;

  /// Direction of the latest sample-to-sample step. Distinct from
  /// `_confirmedDir` until the confirmation window elapses.
  int _candidateDir = 0;
  int _candidateRunLength = 0;

  /// Anchor extremes for the in-flight cycle.
  double? _cycleStartMax;
  double? _cycleMin;

  /// Running max while ascending — captures the true peak between reps so
  /// the next cycle's `_cycleStartMax` isn't a post-reversal sample.
  double? _ascentMax;

  /// Frames spent in `_Phase.descending`. Gates the descending → ascending
  /// flip against a minimum dwell so a rest-pause with noise-driven direction
  /// flip-flops cannot commit a phantom rep. Incremented on every sample while
  /// descending; reset when entering or leaving that phase.
  int _framesInDescending = 0;

  _Phase _phase = _Phase.awaitingFirstMax;

  Stream<RepExtreme> get extremes => _controller.stream;

  void onAngle(double rawAngle) {
    _angleBuffer.add(rawAngle);
    if (_angleBuffer.length > _smoothWindow) _angleBuffer.removeAt(0);
    final smoothed = _angleBuffer.reduce((a, b) => a + b) / _angleBuffer.length;

    if (_prevSmoothed == null) {
      _prevSmoothed = smoothed;
      _cycleStartMax = smoothed;
      return;
    }

    final delta = smoothed - _prevSmoothed!;
    final stepDir = delta > 0
        ? 1
        : delta < 0
        ? -1
        : 0;

    // Maintain rolling extremes regardless of phase confirmation.
    // Max only grows while we haven't yet committed to a descent — once
    // descending, the running max is locked (it's the rep's top).
    if (_phase == _Phase.awaitingFirstMax) {
      _cycleStartMax = (_cycleStartMax == null || smoothed > _cycleStartMax!)
          ? smoothed
          : _cycleStartMax;
    }
    if (_phase == _Phase.descending || _phase == _Phase.ascending) {
      _cycleMin = (_cycleMin == null || smoothed < _cycleMin!)
          ? smoothed
          : _cycleMin;
    }
    if (_phase == _Phase.ascending) {
      _ascentMax = (_ascentMax == null || smoothed > _ascentMax!)
          ? smoothed
          : _ascentMax;
    }
    if (_phase == _Phase.descending) {
      _framesInDescending++;
    }

    // Track candidate direction run.
    if (stepDir == 0) {
      // Flat — neither breaks nor extends a run.
      _prevSmoothed = smoothed;
      return;
    }
    if (stepDir == _candidateDir) {
      _candidateRunLength++;
    } else {
      _candidateDir = stepDir;
      _candidateRunLength = 1;
    }

    final confirmed = _candidateRunLength >= _directionConfirmFrames;
    if (confirmed && _candidateDir != _confirmedDir) {
      _onDirectionConfirmed(_candidateDir, smoothed);
    }

    _prevSmoothed = smoothed;
  }

  void _onDirectionConfirmed(int newDir, double smoothed) {
    switch (_phase) {
      case _Phase.awaitingFirstMax:
        if (newDir == -1) {
          // First confirmed descent → start of the rep cycle.
          // The cycle's max was captured during awaitingFirstMax.
          _phase = _Phase.descending;
          _cycleMin = smoothed;
          _framesInDescending = 0;
        }
        break;
      case _Phase.descending:
        if (newDir == 1) {
          // Bottom dwell guard: ignore the ascent confirmation if we haven't
          // spent at least `kRepBoundaryMinDwellFrames` in descending. This
          // rejects noise-driven flip-flops during a rest-pause at the bottom
          // without affecting clean bottom reversals (a true reversal has
          // already accumulated many descending frames).
          if (_framesInDescending < kRepBoundaryMinDwellFrames) {
            // Swallow the confirmation; stay in descending. Don't update
            // _confirmedDir so a subsequent confirmation can still commit
            // once the dwell threshold is crossed.
            return;
          }
          // Bottom turning point — rep completes here.
          final excursion = (_cycleStartMax! - _cycleMin!).abs();
          if (excursion >= kCalibrationMinExcursion) {
            _controller.add(
              RepExtreme(minAngle: _cycleMin!, maxAngle: _cycleStartMax!),
            );
          }
          _phase = _Phase.ascending;
          _ascentMax = smoothed;
        }
        break;
      case _Phase.ascending:
        if (newDir == -1) {
          // Top of next up-stroke — start the next descent cycle.
          // Use the running ascent max (the *true* peak) — `_prevSmoothed`
          // is several frames past the peak by the time descent confirms.
          _cycleStartMax = _ascentMax ?? _prevSmoothed;
          _cycleMin = smoothed;
          _ascentMax = null;
          _phase = _Phase.descending;
          _framesInDescending = 0;
        }
        break;
    }
    _confirmedDir = newDir;
  }

  void reset() {
    _angleBuffer.clear();
    _prevSmoothed = null;
    _confirmedDir = 0;
    _candidateDir = 0;
    _candidateRunLength = 0;
    _cycleStartMax = null;
    _cycleMin = null;
    _ascentMax = null;
    _framesInDescending = 0;
    _phase = _Phase.awaitingFirstMax;
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}
