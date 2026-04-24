import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../core/types.dart';
import '../models/landmark_types.dart';
import '../services/app_services.dart';
import '../view_models/workout_view_model.dart';
import '../widgets/rep_counter_display.dart';
import '../widgets/skeleton_painter.dart';
import 'calibration_overlay.dart';
import 'settings_screen.dart';
import 'summary_screen.dart';

class WorkoutScreen extends StatefulWidget {
  final ExerciseType exercise;

  /// When true, force the calibration phase even if a saved profile exists.
  /// Set by Settings → Recalibrate.
  final bool forceCalibration;

  const WorkoutScreen({
    super.key,
    required this.exercise,
    this.forceCalibration = false,
  });

  @override
  State<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends State<WorkoutScreen> {
  late final WorkoutViewModel _vm;
  StreamSubscription<WorkoutCompletedEvent>? _completionSub;

  @override
  void initState() {
    super.initState();
    final services = AppServicesScope.read(context);
    _vm = WorkoutViewModel(
      exercise: widget.exercise,
      forceCalibration: widget.forceCalibration,
      profileRepository: services.profileRepository,
      sessionRepository: services.sessionRepository,
    );
    _completionSub = _vm.completionEvents.listen(_onWorkoutCompleted);
    _vm.init();
  }

  @override
  void dispose() {
    _completionSub?.cancel();
    _vm.dispose();
    super.dispose();
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
        ),
      ),
    );
  }

  /// Phase-aware uniform skeleton color. Null during IDLE keeps overlay quiet
  /// between reps (SkeletonPainter falls back to its default cyan/green).
  Color? _skeletonPhaseColor(RepState state) => switch (state) {
    RepState.idle => null,
    RepState.concentric => const Color(0xFFFFB300),
    RepState.peak => const Color(0xFF00E676),
    RepState.eccentric => const Color(0xFF40C4FF),
    RepState.descending => const Color(0xFFFFB300),
    RepState.bottom => const Color(0xFF00E676),
    RepState.ascending => const Color(0xFF40C4FF),
  };

  String _viewLabel(CurlCameraView v) => switch (v) {
    CurlCameraView.front => 'Front view',
    CurlCameraView.sideLeft => 'Side view · Left',
    CurlCameraView.sideRight => 'Side view · Right',
    CurlCameraView.unknown => 'Detecting…',
  };

  /// Bottom sheet from AppBar gear. Needs BuildContext for modal routing so it
  /// stays in the widget layer; calls back into the VM for the action.
  void _showCalibrationSheet() {
    final needsCal = _vm.needsCalibrationHint();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
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
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              if (needsCal)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    'Without a profile, rep thresholds fall back to '
                    'generic defaults. Takes about 20 seconds.',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
              const Divider(height: 1, color: Colors.white12),
              ListTile(
                leading: const Icon(
                  Icons.center_focus_strong,
                  color: Color(0xFF00E676),
                ),
                title: const Text(
                  'Calibrate now',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: const Text(
                  'Re-record your full range of motion.',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _vm.startInWorkoutCalibration();
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.settings_outlined,
                  color: Colors.white70,
                ),
                title: const Text(
                  'Open Settings',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: const Text(
                  'Diagnostics, reset, per-bucket status.',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
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
    return AppBar(
      title: Text(widget.exercise.label),
      actions: [
        if (widget.exercise == ExerciseType.bicepsCurl &&
            phase != WorkoutPhase.calibration)
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
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFF00E676)),
            SizedBox(height: 16),
            Text('Starting camera...', style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }

    final camera = _vm.camera;
    final phase = _vm.phase;
    final snapshot = _vm.snapshot;
    final landmarks = _vm.landmarks;
    final calibrationSummary = _vm.calibrationSummary;

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
                              landmarkColors: () {
                                final phaseColor = _skeletonPhaseColor(
                                  snapshot.state,
                                );
                                final phaseBase = phaseColor != null
                                    ? {
                                        for (final idx in LM.upperBodyLandmarks)
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
                              boneConnections:
                                  widget.exercise == ExerciseType.bicepsCurl
                                  ? LM.upperBodyConnections
                                  : null,
                              visibleLandmarks:
                                  widget.exercise == ExerciseType.bicepsCurl
                                  ? LM.upperBodyLandmarks
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
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        calibrationSummary.sidesLabel,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 16,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'For other camera angles, use\nSettings → Recalibrate.',
                        style: TextStyle(color: Colors.white54, fontSize: 13),
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
              color: Colors.black87,
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              child: Text(
                _vm.setupOkFrames > 0
                    ? 'Almost there… (${_vm.setupOkFrames} / $kSetupCheckFrames)'
                    : 'Step back until your full body is visible',
                style: const TextStyle(color: Colors.white, fontSize: 16),
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
                color: Colors.white,
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

        // ACTIVE — mid-session occlusion banner.
        if (phase == WorkoutPhase.active && _vm.isOccluded)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.orange.withValues(alpha: 0.85),
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
        if (widget.exercise == ExerciseType.bicepsCurl &&
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

        // ACTIVE — rep counter overlay.
        if (phase == WorkoutPhase.active)
          Positioned(
            left: 16,
            bottom: 32,
            child: RepCounterDisplay(
              reps: snapshot.reps,
              sets: snapshot.sets,
              state: snapshot.state,
              jointAngle: snapshot.jointAngle,
              activeErrors: snapshot.formErrors,
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
              border: Border.all(color: Colors.black, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}
