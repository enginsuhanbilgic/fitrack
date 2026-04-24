/// Calibration overlay rendered by [WorkoutScreen] during
/// [WorkoutPhase.calibration].
///
/// Pure presentation: shows live progress (reps detected, current angle,
/// view-detection chip) plus a bottom action bar with "Skip" / "Retry".
/// All state lives in the parent — this widget is rebuilt on every frame
/// it needs to react to.
library;

import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/types.dart';

class CalibrationOverlay extends StatelessWidget {
  /// 0..[kCalibrationMinReps]. Drives the progress dots.
  final int repsDetected;

  /// Current smoothed elbow angle in degrees, if known. Null while pose is
  /// not yet locked.
  final double? currentAngle;

  /// Current detected view. `unknown` while still collecting evidence.
  final CurlCameraView detectedView;

  /// Seconds remaining before the auto-timeout fires. Null = timer not running.
  final int? secondsRemaining;

  /// True while a transient "didn't see any reps" error message is shown.
  final String? errorMessage;

  /// Tapped when the user wants to bail entirely and use globals/auto.
  final VoidCallback onSkip;

  /// Tapped when the user wants to restart calibration after a failure.
  final VoidCallback? onRetry;

  const CalibrationOverlay({
    super.key,
    required this.repsDetected,
    required this.currentAngle,
    required this.detectedView,
    required this.secondsRemaining,
    required this.onSkip,
    this.errorMessage,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final viewLocked = detectedView != CurlCameraView.unknown;

    return Stack(
      children: [
        // ── Top instruction banner ──────────────────────
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            color: Colors.black87,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
            child: Column(
              children: [
                const Text(
                  'Calibration',
                  style: TextStyle(
                    color: Color(0xFF00E676),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  errorMessage ??
                      'Curl through your full natural range — '
                          '$kCalibrationMinReps reps.',
                  style: TextStyle(
                    color: errorMessage == null
                        ? Colors.white
                        : Colors.orangeAccent,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),

        // ── Center: progress dots + live angle ─────────
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _RepDots(detected: repsDetected, target: kCalibrationMinReps),
              const SizedBox(height: 24),
              if (currentAngle != null)
                Text(
                  '${currentAngle!.toStringAsFixed(0)}°',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 64,
                    fontWeight: FontWeight.w900,
                  ),
                ),
            ],
          ),
        ),

        // ── Bottom: chips + actions ────────────────────
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            color: Colors.black87,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _Chip(
                      icon: Icons.videocam,
                      label: viewLocked
                          ? _viewLabel(detectedView)
                          : 'Detecting view…',
                      colored: viewLocked,
                    ),
                    if (secondsRemaining != null)
                      _Chip(
                        icon: Icons.timer_outlined,
                        label: '${secondsRemaining}s',
                        colored: secondsRemaining! > 10,
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: onSkip,
                      child: const Text(
                        'Skip',
                        style: TextStyle(color: Colors.white70, fontSize: 16),
                      ),
                    ),
                    if (onRetry != null)
                      ElevatedButton(
                        onPressed: onRetry,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00E676),
                          foregroundColor: Colors.black,
                        ),
                        child: const Text('Retry'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static String _viewLabel(CurlCameraView v) => switch (v) {
    CurlCameraView.front => 'Front view',
    CurlCameraView.sideLeft => 'Side · Left',
    CurlCameraView.sideRight => 'Side · Right',
    CurlCameraView.unknown => 'Detecting…',
  };
}

class _RepDots extends StatelessWidget {
  final int detected;
  final int target;
  const _RepDots({required this.detected, required this.target});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(target, (i) {
        final filled = i < detected;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: filled ? const Color(0xFF00E676) : Colors.transparent,
              border: Border.all(
                color: filled ? const Color(0xFF00E676) : Colors.white54,
                width: 2,
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool colored;
  const _Chip({required this.icon, required this.label, required this.colored});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            color: colored ? const Color(0xFF00E676) : Colors.white70,
            size: 16,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
