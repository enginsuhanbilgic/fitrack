import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../core/types.dart';
import '../engine/rep_counter.dart' show RepSnapshot;
import '../models/landmark_types.dart';
import '../models/pose_landmark.dart';
import '../services/app_services.dart';
import '../view_models/workout_view_model.dart';
import '../widgets/skeleton_painter.dart';
import 'calibration_overlay.dart';
import 'settings_screen.dart';
import 'summary_screen.dart';

class WorkoutScreen extends StatefulWidget {
  final ExerciseType exercise;

  /// When true, force the calibration phase even if a saved profile exists.
  /// Set by Settings → Recalibrate.
  final bool forceCalibration;

  /// User-declared side facing the camera for side-view curls. Set by
  /// HomeScreen's side-picker sheet for `bicepsCurlSide`. Forwarded to the
  /// VM so the initial `CurlCameraView` seeds correctly and the
  /// view-aware landmark gate demands the right arm's landmarks. Defaults
  /// to `both` for non-curl-side workouts (and as a safe fallback —
  /// legacy behavior treats `both` as sideLeft seeding).
  final ExerciseSide curlSide;

  const WorkoutScreen({
    super.key,
    required this.exercise,
    this.forceCalibration = false,
    this.curlSide = ExerciseSide.both,
  });

  @override
  State<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends State<WorkoutScreen> {
  late final WorkoutViewModel _vm;
  StreamSubscription<WorkoutCompletedEvent>? _completionSub;

  /// Latch so `_onVmTick` only pops once even though `notifyListeners` fires
  /// many times after the flag flips (the screen still rebuilds on subsequent
  /// VM updates during the dispose tail).
  bool _exitPopped = false;

  @override
  void initState() {
    super.initState();
    final services = AppServicesScope.read(context);
    _vm = WorkoutViewModel(
      exercise: widget.exercise,
      forceCalibration: widget.forceCalibration,
      curlSide: widget.curlSide,
      profileRepository: services.profileRepository,
      sessionRepository: services.sessionRepository,
      preferencesRepository: services.preferencesRepository,
    );
    _completionSub = _vm.completionEvents.listen(_onWorkoutCompleted);
    _vm.addListener(_onVmTick);
    _vm.init();
  }

  @override
  void dispose() {
    _vm.removeListener(_onVmTick);
    _completionSub?.cancel();
    _vm.dispose();
    super.dispose();
  }

  /// VM-state listener for one-shot navigation events. Currently only handles
  /// the post-recalibrate exit (Settings → Recalibrate path): when the VM
  /// flips `shouldExitAfterCalibration`, pop this Workout route so the user
  /// returns to the screen they came from instead of being dumped into a
  /// countdown they didn't ask for.
  void _onVmTick() {
    if (_exitPopped) return;
    if (!_vm.shouldExitAfterCalibration) return;
    if (!mounted) return;
    _exitPopped = true;
    Navigator.of(context).pop();
  }

  void _onWorkoutCompleted(WorkoutCompletedEvent e) {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SummaryScreen(
          exercise: e.exercise,
          totalReps: e.totalReps,
          totalSets: e.totalSets,
          sessionDuration: e.sessionDuration,
          averageQuality: e.averageQuality,
          detectedView: e.detectedView,
          repQualities: e.repQualities,
          fatigueDetected: e.fatigueDetected,
          asymmetryDetected: e.asymmetryDetected,
          eccentricTooFastCount: e.eccentricTooFastCount,
          errorsTriggered: e.errorsTriggered,
          curlRepRecords: e.curlRepRecords,
          curlBucketSummaries: e.curlBucketSummaries,
          dtwSimilarities: e.dtwSimilarities,
          squatVariant: e.squatVariant,
          squatLongFemurLifter: e.squatLongFemurLifter,
          squatRepMetrics: e.squatRepMetrics,
        ),
      ),
    );
  }

  /// Phase-aware uniform skeleton color. Null during IDLE keeps overlay quiet
  /// between reps (SkeletonPainter falls back to its default cyan/green).
  Color? _skeletonPhaseColor(RepState state) => switch (state) {
    RepState.idle => null,
    RepState.concentric => const Color(0xFFC3F400), // accent
    RepState.peak => const Color(0xFF00EEFC), // cyan
    RepState.eccentric => const Color(0xFFC3F400), // accent
    RepState.descending => const Color(0xFFC3F400), // accent
    RepState.bottom => const Color(0xFF00EEFC), // cyan
    RepState.ascending => const Color(0xFFC3F400), // accent
  };

  /// Returns the elbow landmark index for the active curl side, used to
  /// anchor the angle arc annotation in the Overlay skeleton style.
  int _elbowLandmarkForSide() {
    if (widget.curlSide == ExerciseSide.right ||
        _vm.detectedCurlView == CurlCameraView.sideRight) {
      return LM.rightElbow;
    }
    return LM.leftElbow;
  }

  String _viewLabel(CurlCameraView v) => switch (v) {
    CurlCameraView.front => 'Front view',
    CurlCameraView.sideLeft => 'Side view · Left',
    CurlCameraView.sideRight => 'Side view · Right',
    CurlCameraView.unknown => 'Detecting…',
  };

  /// Filter the rendered skeleton to only landmarks that are actually
  /// visible to the camera in the given view. ML Kit always emits all 33
  /// landmarks regardless of orientation; in side view the off-camera
  /// arm's positions are low-confidence guesses behind the body that
  /// cause the rendered skeleton to "glitch" into empty space. Hiding
  /// them produces a clean visible-side-only skeleton that matches what
  /// the user sees in the camera preview.
  ///
  /// Front and unknown views fall through unchanged — both arms are
  /// visible (or detection hasn't settled, in which case showing
  /// everything is the safer default).
  List<PoseLandmark> _filterSkeletonForView(
    List<PoseLandmark> all,
    CurlCameraView view,
  ) {
    if (view != CurlCameraView.sideLeft && view != CurlCameraView.sideRight) {
      return all;
    }
    final hideIds = view == CurlCameraView.sideLeft
        // Hide the user's anatomical RIGHT side (off-camera in sideLeft).
        ? <int>{
            LM.rightShoulder,
            LM.rightElbow,
            LM.rightWrist,
            LM.rightHip,
            LM.rightKnee,
            LM.rightAnkle,
            LM.rightHeel,
            LM.rightFootIndex,
          }
        // Hide the user's anatomical LEFT side (off-camera in sideRight).
        : <int>{
            LM.leftShoulder,
            LM.leftElbow,
            LM.leftWrist,
            LM.leftHip,
            LM.leftKnee,
            LM.leftAnkle,
            LM.leftHeel,
            LM.leftFootIndex,
          };
    return all.where((lm) => !hideIds.contains(lm.type)).toList();
  }

  /// Bottom sheet from AppBar gear. Needs BuildContext for modal routing so it
  /// stays in the widget layer; calls back into the VM for the action.
  void _showCalibrationSheet() {
    final needsCal = _vm.needsCalibrationHint();
    final sheetBg = Theme.of(context).colorScheme.surface;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: sheetBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Icon(
                      needsCal ? Icons.warning_amber_rounded : Icons.tune,
                      color: needsCal
                          ? Colors.redAccent
                          : const Color(0xFF00E676),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      needsCal ? 'Calibration recommended' : 'Calibration',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              if (needsCal)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    'Without a profile, rep thresholds fall back to '
                    'generic defaults. Takes about 20 seconds.',
                    style: TextStyle(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.70),
                      fontSize: 13,
                    ),
                  ),
                ),
              Divider(
                height: 1,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.12),
              ),
              ListTile(
                leading: const Icon(
                  Icons.center_focus_strong,
                  color: Color(0xFF00E676),
                ),
                title: Text(
                  'Calibrate now',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                subtitle: Text(
                  'Re-record your full range of motion.',
                  style: TextStyle(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.70),
                    fontSize: 12,
                  ),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _vm.startInWorkoutCalibration();
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.settings_outlined,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.70),
                ),
                title: Text(
                  'Open Settings',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                subtitle: Text(
                  'Diagnostics, reset, per-bucket status.',
                  style: TextStyle(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.70),
                    fontSize: 12,
                  ),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsScreen(),
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // `.value` is mandatory: the widget's `dispose()` already owns VM
    // teardown. The `create:` constructor would dispose the VM a second
    // time and throw "ChangeNotifier was disposed twice".
    return ChangeNotifierProvider<WorkoutViewModel>.value(
      value: _vm,
      child: Scaffold(
        backgroundColor: Colors.black,
        // AppBar only depends on phase + calibration-hint — split it out so
        // the 15–20 Hz pose-frame rebuild of the body never re-renders the
        // title, gear icon, or action buttons.
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child:
              Selector<WorkoutViewModel, ({WorkoutPhase phase, bool needsCal})>(
                selector: (_, vm) =>
                    (phase: vm.phase, needsCal: vm.needsCalibrationHint()),
                builder: (_, s, _) => _buildAppBar(s.phase, s.needsCal),
              ),
        ),
        body: Consumer<WorkoutViewModel>(builder: (_, _, _) => _buildBody()),
      ),
    );
  }

  AppBar _buildAppBar(WorkoutPhase phase, bool needsCal) {
    final ft = FiTrackColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AppBar(
      backgroundColor: isDark
          ? const Color(0xD90A0A0A) // dark mode: ~85% opacity black
          : const Color(0xEBF3F2EE), // light mode: ~92% opacity warm ivory
      elevation: 0,
      scrolledUnderElevation: 0,
      title: Text(
        widget.exercise.label,
        style: TextStyle(
          color: ft.textStrong,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      iconTheme: IconThemeData(color: ft.textStrong),
      actions: [
        if (widget.exercise.isCurl && phase != WorkoutPhase.calibration)
          IconButton(
            icon: _WorkoutGearIcon(needsCalibration: needsCal),
            tooltip: 'Calibration',
            onPressed: _showCalibrationSheet,
          ),
        if (phase == WorkoutPhase.active) ...[
          IconButton(
            icon: const Icon(Icons.replay),
            tooltip: 'New set',
            onPressed: _vm.startNextSet,
          ),
          IconButton(
            icon: const Icon(
              Icons.stop_circle_outlined,
              color: Colors.redAccent,
            ),
            tooltip: 'Finish workout',
            onPressed: _vm.finishWorkout,
          ),
        ],
      ],
    );
  }

  Widget _buildBody() {
    if (_vm.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _vm.error!,
            style: const TextStyle(color: Colors.redAccent, fontSize: 16),
          ),
        ),
      );
    }

    if (!_vm.isReady) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Color(0xFF00E676)),
            const SizedBox(height: 16),
            Text(
              'Starting camera...',
              style: TextStyle(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.70),
              ),
            ),
          ],
        ),
      );
    }

    final camera = _vm.camera;
    final phase = _vm.phase;
    final snapshot = _vm.snapshot;
    final allLandmarks = _vm.landmarks;
    final calibrationSummary = _vm.calibrationSummary;

    // Side-view skeleton filter: hide the off-camera arm's hallucinated
    // landmarks. ML Kit always emits all 33 landmarks; in side view the
    // off-camera arm is invisible to the camera and the model produces
    // low-confidence guesses behind the body. Rendering them confuses the
    // user (skeleton "glitches" into the void). For sideLeft we keep
    // left-side body landmarks + face + hips/legs; for sideRight, mirror.
    // Front view and unknown render the full skeleton unchanged.
    final landmarks = _filterSkeletonForView(
      allLandmarks,
      _vm.detectedCurlView,
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        // Camera preview + skeleton overlay — identical FittedBox transform.
        if (camera.controller != null)
          ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: camera.controller!.value.previewSize!.height,
                height: camera.controller!.value.previewSize!.width,
                child: Stack(
                  children: [
                    CameraPreview(camera.controller!),
                    if (landmarks.isNotEmpty)
                      Positioned.fill(
                        // Isolates the 15–20 Hz skeleton repaint into its own
                        // compositor layer so sibling Positioned banners
                        // (rep counter, occlusion banner) aren't re-rasterized
                        // every frame.
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: SkeletonPainter(
                              landmarks: landmarks,
                              mirror: false, // already mirrored in VM
                              boneColor: FiTrackColors.of(context).accent,
                              landmarkColors: () {
                                final phaseColor = _skeletonPhaseColor(
                                  snapshot.state,
                                );
                                final phaseBase = phaseColor != null
                                    ? {
                                        for (final idx in LM.bodyOnlyLandmarks)
                                          idx: phaseColor,
                                      }
                                    : <int, Color>{};
                                final merged = {
                                  ...phaseBase,
                                  ..._vm.landmarkColors,
                                  ..._vm.errorHighlight,
                                };
                                return merged.isNotEmpty ? merged : null;
                              }(),
                              boneConnections: widget.exercise.isCurl
                                  ? LM.upperBodyConnections
                                  : null,
                              elbowAngleAnnotation:
                                  phase == WorkoutPhase.active &&
                                      snapshot.jointAngle != null
                                  ? (
                                      _elbowLandmarkForSide(),
                                      snapshot.jointAngle!,
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

        // CALIBRATION overlay (or post-cal 2s summary card).
        if (phase == WorkoutPhase.calibration && calibrationSummary == null)
          CalibrationOverlay(
            repsDetected: _vm.calibrationReps,
            currentAngle: _vm.calibrationCurrentAngle,
            detectedView: _vm.detectedCurlView,
            secondsRemaining: _vm.calibrationError == null
                ? _vm.calibrationSecondsRemaining
                : null,
            errorMessage: _vm.calibrationError,
            onSkip: _vm.skipCalibration,
            onRetry: _vm.calibrationError != null ? _vm.retryCalibration : null,
          ),
        if (phase == WorkoutPhase.calibration && calibrationSummary != null)
          Positioned.fill(
            child: Container(
              color: Colors.black87,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.check_circle,
                        color: Color(0xFF00E676),
                        size: 64,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '${calibrationSummary.viewLabel} calibrated',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        calibrationSummary.sidesLabel,
                        style: TextStyle(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.70),
                          fontSize: 16,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'For other camera angles, use\nSettings → Recalibrate.',
                        style: TextStyle(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.54),
                          fontSize: 13,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

        // SETUP_CHECK banner.
        if (phase == WorkoutPhase.setupCheck)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xCC0A0A0A),
                border: Border(
                  bottom: BorderSide(color: FiTrackColors.of(context).stroke),
                ),
              ),
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              child: Text(
                _vm.setupOkFrames > 0
                    ? 'Almost there… (${_vm.setupOkFrames} / $kSetupCheckFrames)'
                    : widget.exercise == ExerciseType.squat
                    ? 'Stand sideways — left or right side to the camera'
                    : 'Step back until your full body is visible',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 16,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),

        // COUNTDOWN — centered big number.
        if (phase == WorkoutPhase.countdown)
          Center(
            child: Text(
              '${_vm.countdownValue}',
              style: const TextStyle(
                fontSize: 160,
                fontWeight: FontWeight.w900,
                color: Color(0xFFC3F400),
              ),
            ),
          ),

        // SETUP / COUNTDOWN — camera framing hint when body is too close
        // to frame edges. Reuses the same passive-banner styling as the
        // uncalibrated-view notice for visual consistency.
        if ((phase == WorkoutPhase.setupCheck ||
                phase == WorkoutPhase.countdown) &&
            _vm.framingHint != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xCC0A0A0A),
                border: Border(
                  bottom: BorderSide(color: FiTrackColors.of(context).stroke),
                ),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.crop_free,
                    color: Color(0xFFFFB300),
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _vm.framingHint!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),

        // ACTIVE — passive uncalibrated-view notice (Hole #1).
        if (phase == WorkoutPhase.active && _vm.uncalibratedViewNotice != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedOpacity(
              opacity: 1.0,
              duration: const Duration(milliseconds: 200),
              child: Container(
                color: Colors.black87,
                padding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 20,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.straighten,
                      color: Color(0xFF00E676),
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _vm.uncalibratedViewNotice!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

        // ACTIVE — runtime view-flip advisory. Shown for 2s after the
        // engine commits a re-detection at FSM idle. Reuses the same
        // transient-banner template as the framing-hint notice; amber
        // tone matches the "advisory" semantic. The cameraswitch icon
        // signals the rotate-detection meaning.
        if (phase == WorkoutPhase.active && _vm.viewFlipBanner != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedOpacity(
              opacity: 1.0,
              duration: const Duration(milliseconds: 200),
              child: Container(
                color: Colors.black87,
                padding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 20,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.cameraswitch,
                      color: Color(0xFFFFB300),
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _vm.viewFlipBanner!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

        // ACTIVE — mid-session occlusion banner.
        if (phase == WorkoutPhase.active && _vm.isOccluded)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              color: const Color(0xDDFF8A3D),
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
              child: const Text(
                'Move into frame — keep all joints visible',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),

        // Curl view indicator chip — bottom right, setup/countdown only.
        if (widget.exercise.isCurl &&
            (phase == WorkoutPhase.setupCheck ||
                phase == WorkoutPhase.countdown) &&
            _vm.detectedCurlView != CurlCameraView.unknown)
          Positioned(
            bottom: 32,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.videocam,
                    color: Color(0xFF00E676),
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _viewLabel(_vm.detectedCurlView),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),

        // ACTIVE — AI coach toast (cycles tips every 4 s).
        if (phase == WorkoutPhase.active) const _CoachToast(),

        // ACTIVE — rep counter overlay.
        //
        // Wrapped in a `Selector<WorkoutViewModel, RepSnapshot>` so the
        // counter's widget construction skips on frames where the snapshot
        // didn't change (rep counter typically changes 1–2× per second; the
        // pose pipeline notifies at 15–20 Hz). Without this, the
        // `RepCounterDisplay` subtree was rebuilt on every pose frame even
        // when only `landmarks` advanced.
        //
        // Note: the skeleton overlay above is intentionally NOT wrapped in
        // a Selector. The VM publishes a fresh `landmarks` list every pose
        // frame (via `LandmarkSmoother.smooth` returning a new List), so the
        // `==` short-circuit would never fire. The skeleton's perf hedge is
        // the existing `RepaintBoundary` (line 300+) which isolates the
        // 15–20 Hz repaint into its own compositor layer.
        // ACTIVE — Minimal HUD: large reps/target at ~38% height (design Minimal variant).
        if (phase == WorkoutPhase.active)
          Positioned.fill(
            child: Selector<WorkoutViewModel, RepSnapshot>(
              selector: (_, vm) => vm.snapshot,
              builder: (context, snap, _) => _MinimalHud(snapshot: snap),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Coach Toast — rotates 5 tips every 4 s during WorkoutPhase.active.
// ---------------------------------------------------------------------------

class _CoachToast extends StatefulWidget {
  const _CoachToast();

  @override
  State<_CoachToast> createState() => _CoachToastState();
}

class _CoachToastState extends State<_CoachToast> {
  static const _tips = [
    (
      icon: Icons.speed,
      label: 'Tempo',
      text:
          'Slow down on the eccentric phase. Control the weight down for 3 seconds.',
    ),
    (
      icon: Icons.straighten,
      label: 'Form',
      text: 'Keep elbows tucked at your sides. Avoid swinging at the shoulder.',
    ),
    (
      icon: Icons.air,
      label: 'Breath',
      text: 'Exhale on the contraction. Strong breath stabilizes the core.',
    ),
    (
      icon: Icons.timer_outlined,
      label: 'Pace',
      text: 'Hold this output. Two more clean reps will close the working set.',
    ),
    (
      icon: Icons.bolt,
      label: 'Power',
      text:
          'Drive the concentric phase. Explosive intent recruits more fibers.',
    ),
  ];

  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) setState(() => _index = (_index + 1) % _tips.length);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tip = _tips[_index];
    return Positioned(
      left: 16,
      right: 16,
      bottom: 140,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xCC141414),
          borderRadius: BorderRadius.circular(10),
          border: const Border(
            left: BorderSide(color: Color(0xFF00EEFC), width: 3),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(tip.icon, color: const Color(0xFF00EEFC), size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'COACH · ${tip.label.toUpperCase()}',
                    style: const TextStyle(
                      color: Color(0xFF00EEFC),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    tip.text,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Minimal HUD — design "Minimal" variant: compact rep counter at 38% height
// + set indicator, bottom stats card, form errors. No full RepCounterDisplay.
// ---------------------------------------------------------------------------

class _MinimalHud extends StatelessWidget {
  final RepSnapshot snapshot;
  const _MinimalHud({required this.snapshot});

  static const int _targetReps = 12;

  static String _formErrorLabel(FormError e) {
    // Convert camelCase enum name to readable words, e.g. torsoSwing → Torso Swing.
    final spaced = e.name.replaceAllMapped(
      RegExp(r'([A-Z])'),
      (m) => ' ${m[0]}',
    );
    return spaced[0].toUpperCase() + spaced.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    final errors = snapshot.formErrors;

    return Stack(
      children: [
        // Large reps/target counter at ~38% vertical position (design spec).
        Positioned(
          top: null,
          left: 16,
          right: 16,
          bottom: null,
          child: FractionallySizedBox(
            widthFactor: 1,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(
                  top: MediaQuery.sizeOf(context).height * 0.38,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '${snapshot.reps}',
                      style: const TextStyle(
                        fontSize: 84,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFFC3F400),
                        letterSpacing: -4,
                        height: 1,
                      ),
                    ),
                    Text(
                      '/$_targetReps',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: ft.textDim,
                        height: 1,
                      ),
                    ),
                    const Spacer(),
                    // Set indicator — top-right of this row.
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'SET',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: ft.textDim,
                            letterSpacing: 1.4,
                          ),
                        ),
                        Text(
                          '${snapshot.sets}',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: ft.accent,
                            height: 1,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),

        // Bottom stats bar — backdrop-blurred card matching design.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xCC141414)
                  : ft.surface2.withValues(alpha: 0.95),
              border: Border(top: BorderSide(color: ft.stroke)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Progress bar.
                Row(
                  children: [
                    Text(
                      'SET PROGRESS',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: ft.textDim,
                        letterSpacing: 1.4,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${((snapshot.reps / _targetReps) * 100).round().clamp(0, 100)}%',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: ft.accent,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: (snapshot.reps / _targetReps).clamp(0.0, 1.0),
                    minHeight: 8,
                    backgroundColor:
                        Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFF2A2A2A)
                        : ft.surface3,
                    valueColor: AlwaysStoppedAnimation<Color>(ft.accent),
                  ),
                ),
                // Form errors — show first active error if any.
                if (errors.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? const Color(0xFFFFB4AB)
                            : Colors.red.shade700,
                        size: 14,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _formErrorLabel(errors.first),
                          style: TextStyle(
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                ? const Color(0xFFFFB4AB)
                                : Colors.red.shade700,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// AppBar gear icon with optional red dot badge for "needs calibration".
class _WorkoutGearIcon extends StatelessWidget {
  final bool needsCalibration;
  const _WorkoutGearIcon({required this.needsCalibration});

  @override
  Widget build(BuildContext context) {
    const icon = Icon(Icons.tune);
    if (!needsCalibration) return icon;
    final outline = Theme.of(context).colorScheme.outline;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(
          right: -2,
          top: -2,
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: Colors.redAccent,
              shape: BoxShape.circle,
              border: Border.all(color: outline, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}
