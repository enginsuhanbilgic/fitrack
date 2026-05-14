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
  final int progressTarget;
  final String progressLabel;
  final String instruction;
  final ExerciseType exercise;

  /// Current smoothed elbow angle in degrees, if known. Null while pose is
  /// not yet locked.
  final double? currentAngle;

  /// Current detected view. `unknown` while still collecting evidence.
  /// Null for exercises with no view-detection concept (squat, push-up).
  /// When null, the view-detection chip + the "calibrating left/right
  /// view" sub-banner are both hidden.
  final CurlCameraView? detectedView;

  /// Seconds remaining before the auto-timeout fires. Null = timer not running.
  final int? secondsRemaining;

  /// True while a transient "didn't see any reps" error message is shown.
  final String? errorMessage;

  /// Tapped when the user wants to bail entirely and use globals/auto.
  final VoidCallback onSkip;

  /// Tapped when the user wants to restart calibration after a failure.
  final VoidCallback? onRetry;

  /// Curl Global Calibration: the side the user has explicitly picked.
  /// Null means the side-pick panel must be shown and the FSM-driven
  /// progress UI suppressed. Ignored for non-curl exercises.
  final ProfileSide? chosenSide;

  /// Called when the user taps Left / Right on the side-pick panel.
  /// Only consulted when [chosenSide] is null and the exercise is curl.
  final ValueChanged<ProfileSide>? onPickSide;

  const CalibrationOverlay({
    super.key,
    required this.repsDetected,
    required this.currentAngle,
    required this.detectedView,
    required this.secondsRemaining,
    required this.onSkip,
    this.progressTarget = kCalibrationMinReps,
    this.progressLabel = 'reps',
    this.instruction =
        'Curl through your full natural range — $kCalibrationMinReps reps.',
    this.exercise = ExerciseType.bicepsCurlSide,
    this.errorMessage,
    this.onRetry,
    this.chosenSide,
    this.onPickSide,
  });

  @override
  Widget build(BuildContext context) {
    // View detection only matters for curl. Squat / push-up pass
    // `detectedView: null` and the chip + sub-banner are hidden.
    final view = detectedView;
    final viewLocked = view != null && view != CurlCameraView.unknown;
    final isCurl = exercise.isCurl;
    final viewChipVisible = view != null && isCurl;
    // Curl side-pick panel is shown until the user explicitly picks an
    // arm. While the panel is up the timeout chip, Skip and Retry are
    // hidden — the user must commit to a side first. Non-curl exercises
    // never enter this branch (chosenSide is ignored).
    final awaitingSidePick = isCurl && chosenSide == null && onPickSide != null;
    final bannerText =
        errorMessage ??
        (awaitingSidePick ? "Pick the side you'll calibrate" : instruction);

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
                Semantics(
                  header: true,
                  child: const Text(
                    'Calibration',
                    style: TextStyle(
                      color: Color(0xFF00E676),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                // liveRegion: error/instruction swap mid-flow — screen reader
                // re-announces when errorMessage transitions from null to set.
                Semantics(
                  liveRegion: true,
                  child: Text(
                    bannerText,
                    style: TextStyle(
                      color: errorMessage == null
                          ? Colors.white
                          : Colors.orangeAccent,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                if (errorMessage == null &&
                    viewChipVisible &&
                    view != CurlCameraView.unknown) ...[
                  const SizedBox(height: 8),
                  Text(
                    view == CurlCameraView.front
                        ? 'Front view isn\'t supported — please turn '
                              '90° so the camera sees you from the side.'
                        : 'Calibrating ${_viewLabel(view).toLowerCase()} profile. '
                              'Do a ${_otherViewLabel(view)} workout to calibrate that view too.',
                    style: TextStyle(
                      color: view == CurlCameraView.front
                          ? Colors.orangeAccent
                          : Colors.white54,
                      fontSize: 12,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),

        // ── Center: side-pick panel OR progress dots + live angle ─────────
        Center(
          child: awaitingSidePick
              ? _SidePickPanel(onPick: onPickSide!)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Decorative dot row gets an accessible label so
                    // screen-reader users hear progress instead of nothing.
                    // liveRegion so each detected rep re-announces.
                    Semantics(
                      liveRegion: true,
                      label:
                          'Calibration progress: $repsDetected of $progressTarget $progressLabel detected',
                      excludeSemantics: true,
                      child: _RepDots(
                        detected: repsDetected,
                        target: progressTarget,
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (currentAngle != null)
                      Semantics(
                        label:
                            'Current elbow angle ${currentAngle!.toStringAsFixed(0)} degrees',
                        excludeSemantics: true,
                        child: Text(
                          '${currentAngle!.toStringAsFixed(0)}°',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 64,
                            fontWeight: FontWeight.w900,
                          ),
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
                    // View chip hidden entirely for exercises without a
                    // view-detection concept (squat / push-up — they pass
                    // `detectedView: null`). The non-curl-with-detector
                    // case ("Side view" fallback) remains for legacy
                    // call-sites that pass a non-null but non-curl view.
                    if (viewChipVisible)
                      _Chip(
                        icon: Icons.videocam,
                        label: viewLocked
                            ? (view == CurlCameraView.front
                                  ? 'Side view needed'
                                  : _viewLabel(view))
                            : 'Detecting view…',
                        colored: viewLocked && view != CurlCameraView.front,
                      )
                    else if (view != null && !isCurl)
                      const _Chip(
                        icon: Icons.videocam,
                        label: 'Side view',
                        colored: true,
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
                // Skip and Retry are hidden while the side-pick panel is
                // up — the user must commit to a side first. Otherwise
                // a Skip tap could exit calibration before the timeout
                // is even running, leaving the next workout unaware
                // whether the user opted out vs. just hadn't picked yet.
                if (!awaitingSidePick)
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

  // Returns a short label for the complementary view — shown in the
  // awareness hint so the user knows the other view exists.
  static String _otherViewLabel(CurlCameraView v) => switch (v) {
    CurlCameraView.front => 'side-view',
    CurlCameraView.sideLeft || CurlCameraView.sideRight => 'front-view',
    CurlCameraView.unknown => 'other-view',
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

/// Curl Global Calibration: explicit Left/Right picker shown before
/// any reps are detected. Until the user taps a side the parent VM
/// holds off arming the rep detector and starting the timeout, so the
/// user can take their time without burning calibration seconds.
///
/// **Anatomical mapping** — `Left arm` maps to [ProfileSide.left] (the
/// limb the user is curling). The home-screen mirroring quirk does not
/// apply here: calibration concerns the limb being curled, and the
/// engine attributes commits by ML Kit anatomical side.
class _SidePickPanel extends StatelessWidget {
  final ValueChanged<ProfileSide> onPick;
  const _SidePickPanel({required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Which arm will you calibrate?',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          const Text(
            "We'll apply this to both arms. You can calibrate the other "
            'side right after.',
            style: TextStyle(color: Colors.white70, fontSize: 13),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _SidePickButton(
                label: 'Left arm',
                onTap: () => onPick(ProfileSide.left),
              ),
              const SizedBox(width: 16),
              _SidePickButton(
                label: 'Right arm',
                onTap: () => onPick(ProfileSide.right),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SidePickButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _SidePickButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Calibrate $label',
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF00E676),
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Text(label),
      ),
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
