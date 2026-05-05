import 'dart:async';
import 'dart:ui';
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
          errorCounts: e.errorCounts,
          curlRepRecords: e.curlRepRecords,
          curlBucketSummaries: e.curlBucketSummaries,
          dtwSimilarities: e.dtwSimilarities,
          squatVariant: e.squatVariant,
          squatLongFemurLifter: e.squatLongFemurLifter,
          squatRepMetrics: e.squatRepMetrics,
          bicepsSideRepMetrics: e.bicepsSideRepMetrics,
          repConcentricMs: e.repConcentricMs,
          repDepthPercents: e.repDepthPercents,
        ),
      ),
    );
  }

  Color? _skeletonPhaseColor(RepState state) => switch (state) {
    RepState.idle => null,
    RepState.concentric => const Color(0xFFC3F400),
    RepState.peak => const Color(0xFF00EEFC),
    RepState.eccentric => const Color(0xFFC3F400),
    RepState.descending => const Color(0xFFC3F400),
    RepState.bottom => const Color(0xFF00EEFC),
    RepState.ascending => const Color(0xFFC3F400),
  };

  // `curlSide == ExerciseSide.right` is camera-frame for the user's physical
  // LEFT arm (home screen swaps left↔right for front-camera mirroring).
  // `sideRight` in camera-frame also means the user's physical left arm is
  // the near-side arm being tracked.
  int _elbowLandmarkForSide() {
    if (widget.curlSide == ExerciseSide.right ||
        _vm.detectedCurlView == CurlCameraView.sideRight) {
      return LM.leftElbow;
    }
    return LM.rightElbow;
  }

  // Camera-frame → user-frame flip: sideLeft = camera's left = user's RIGHT
  // physical arm; sideRight = camera's right = user's LEFT physical arm.
  // Matches the identical flip in summary_screen.dart _viewLabel.
  String _viewLabel(CurlCameraView v) => switch (v) {
    CurlCameraView.front => 'Front view',
    CurlCameraView.sideLeft => 'Side view · Right',
    CurlCameraView.sideRight => 'Side view · Left',
    CurlCameraView.unknown => 'Detecting…',
  };

  List<PoseLandmark> _filterSkeletonForView(
    List<PoseLandmark> all,
    CurlCameraView view,
  ) {
    if (view != CurlCameraView.sideLeft && view != CurlCameraView.sideRight) {
      return all;
    }
    final hideIds = view == CurlCameraView.sideLeft
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
    return ChangeNotifierProvider<WorkoutViewModel>.value(
      value: _vm,
      child: Scaffold(
        backgroundColor: Colors.black,
        // No AppBar — replaced by a floating glassmorphic top HUD bar.
        extendBodyBehindAppBar: true,
        body: Consumer<WorkoutViewModel>(builder: (_, _, _) => _buildBody()),
      ),
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

    final landmarks = _filterSkeletonForView(
      allLandmarks,
      _vm.detectedCurlView,
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        // ── Camera preview + skeleton overlay ──────────────────────────────
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
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: SkeletonPainter(
                              landmarks: landmarks,
                              mirror: false,
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

        // ── Cinematic camera vignette / gradient scrim ────────────────────
        // Top → transparent fade so the HUD bar is always readable.
        // Bottom → dark fade so the stats card text is legible.
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.22, 0.60, 1.0],
                  colors: [
                    Colors.black.withValues(alpha: 0.65),
                    Colors.transparent,
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.88),
                  ],
                ),
              ),
            ),
          ),
        ),

        // ── CALIBRATION overlay ─────────────────────────────────────────────
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

        // ── SETUP_CHECK banner ──────────────────────────────────────────────
        if (phase == WorkoutPhase.setupCheck)
          _SetupBanner(vm: _vm, exercise: widget.exercise),

        // ── COUNTDOWN — centered big number ────────────────────────────────
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

        // ── SETUP/COUNTDOWN framing hint ────────────────────────────────────
        if ((phase == WorkoutPhase.setupCheck ||
                phase == WorkoutPhase.countdown) &&
            _vm.framingHint != null)
          _FramingHintBanner(hint: _vm.framingHint!),

        // ── ACTIVE — uncalibrated-view notice ───────────────────────────────
        if (phase == WorkoutPhase.active && _vm.uncalibratedViewNotice != null)
          _InfoBanner(
            icon: Icons.straighten,
            text: _vm.uncalibratedViewNotice!,
            tone: _BannerTone.cyan,
          ),

        // ── ACTIVE — runtime view-flip advisory ─────────────────────────────
        if (phase == WorkoutPhase.active && _vm.viewFlipBanner != null)
          _InfoBanner(
            icon: Icons.cameraswitch,
            text: _vm.viewFlipBanner!,
            tone: _BannerTone.amber,
          ),

        // ── ACTIVE — mid-session occlusion banner ────────────────────────────
        if (phase == WorkoutPhase.active && _vm.isOccluded) _OcclusionBanner(),

        // ── Curl view indicator chip ─────────────────────────────────────────
        if (widget.exercise.isCurl &&
            (phase == WorkoutPhase.setupCheck ||
                phase == WorkoutPhase.countdown) &&
            _vm.detectedCurlView != CurlCameraView.unknown)
          Positioned(
            bottom: 32,
            right: 16,
            child: _GlassPill(
              icon: Icons.videocam,
              label: _viewLabel(_vm.detectedCurlView),
              iconColor: const Color(0xFF00E676),
            ),
          ),

        // ── ACTIVE — AI coach toast ──────────────────────────────────────────
        if (phase == WorkoutPhase.active) const _CoachToast(),

        // ── ACTIVE — rep counter + bottom stats HUD ──────────────────────────
        if (phase == WorkoutPhase.active)
          Positioned.fill(
            child: Selector<WorkoutViewModel, RepSnapshot>(
              selector: (_, vm) => vm.snapshot,
              builder: (context, snap, _) => _MinimalHud(snapshot: snap),
            ),
          ),

        // ── Floating top HUD bar (replaces AppBar) ───────────────────────────
        Selector<WorkoutViewModel, ({WorkoutPhase phase, bool needsCal})>(
          selector: (_, vm) =>
              (phase: vm.phase, needsCal: vm.needsCalibrationHint()),
          builder: (_, s, _) => _TopHudBar(
            exercise: widget.exercise,
            phase: s.phase,
            needsCalibration: s.needsCal,
            vm: _vm,
            onCalibration: _showCalibrationSheet,
          ),
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Top HUD bar — glassmorphic, replaces AppBar.
// ──────────────────────────────────────────────────────────────────────────────

class _TopHudBar extends StatelessWidget {
  final ExerciseType exercise;
  final WorkoutPhase phase;
  final bool needsCalibration;
  final WorkoutViewModel vm;
  final VoidCallback onCalibration;

  const _TopHudBar({
    required this.exercise,
    required this.phase,
    required this.needsCalibration,
    required this.vm,
    required this.onCalibration,
  });

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final topPad = MediaQuery.of(context).padding.top;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: EdgeInsets.fromLTRB(12, topPad + 10, 12, 10),
            decoration: BoxDecoration(
              color: isLight
                  ? const Color(0xDEF4F2EC) // --overlay-bg light
                  : const Color(0xD9141414), // --overlay-bg dark
              border: Border(
                bottom: BorderSide(
                  color: isLight
                      ? const Color(0x33D8D6CD)
                      : const Color(0x332D2D30),
                ),
              ),
            ),
            child: Row(
              children: [
                // Back button
                _HudIconButton(
                  icon: Icons.arrow_back_ios_new_rounded,
                  onTap: () => Navigator.of(context).maybePop(),
                  isLight: isLight,
                ),
                const SizedBox(width: 8),
                // Center — Live pill + exercise label
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _LivePill(),
                      const SizedBox(height: 3),
                      Text(
                        exercise.label.toUpperCase(),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.4,
                          color: isLight
                              ? const Color(0xFF4A4E3D)
                              : const Color(0xFFC4C9AC),
                          height: 1,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Right action buttons
                if (exercise.isCurl && phase != WorkoutPhase.calibration)
                  _HudIconButton(
                    icon: needsCalibration ? Icons.tune : Icons.tune,
                    onTap: onCalibration,
                    badge: needsCalibration,
                    isLight: isLight,
                  ),
                if (phase == WorkoutPhase.active) ...[
                  const SizedBox(width: 6),
                  _HudIconButton(
                    icon: Icons.replay,
                    onTap: vm.startNextSet,
                    isLight: isLight,
                  ),
                  const SizedBox(width: 6),
                  _HudIconButton(
                    icon: Icons.stop_circle_outlined,
                    onTap: vm.finishWorkout,
                    isLight: isLight,
                    danger: true,
                  ),
                ],
                if (!(exercise.isCurl && phase != WorkoutPhase.calibration) &&
                    phase != WorkoutPhase.active)
                  // Spacer to balance the back button on the left
                  const SizedBox(width: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Glassmorphic 40×40 circular button for the top HUD.
class _HudIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isLight;
  final bool badge;
  final bool danger;

  const _HudIconButton({
    required this.icon,
    required this.onTap,
    required this.isLight,
    this.badge = false,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isLight ? const Color(0x28000000) : const Color(0x28FFFFFF);
    final iconColor = danger
        ? Colors.redAccent
        : (isLight ? const Color(0xFF1A1C14) : Colors.white);

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              border: Border.all(
                color: isLight
                    ? const Color(0x22000000)
                    : const Color(0x22FFFFFF),
              ),
            ),
            child: Icon(icon, size: 18, color: iconColor),
          ),
          if (badge)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: Colors.redAccent,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isLight
                        ? const Color(0xFFF4F2EC)
                        : const Color(0xFF141414),
                    width: 1.5,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Animated "● LIVE" pill with a pulsing green dot.
class _LivePill extends StatefulWidget {
  const _LivePill();

  @override
  State<_LivePill> createState() => _LivePillState();
}

class _LivePillState extends State<_LivePill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _opacity = Tween<double>(
      begin: 1.0,
      end: 0.35,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final accentColor = isLight
        ? const Color(0xFF5A8C00)
        : const Color(0xFFC3F400);
    final bgColor = isLight ? const Color(0x1F5A8C00) : const Color(0x1FC3F400);
    final borderColor = isLight
        ? const Color(0x665A8C00)
        : const Color(0x66C3F400);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: _opacity,
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: accentColor,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 5),
          Text(
            'LIVE',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: accentColor,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Setup check banner — frosted glass bottom-anchored at top.
// ──────────────────────────────────────────────────────────────────────────────

class _SetupBanner extends StatelessWidget {
  final WorkoutViewModel vm;
  final ExerciseType exercise;

  const _SetupBanner({required this.vm, required this.exercise});

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final topPad = MediaQuery.of(context).padding.top;

    final text = vm.setupOkFrames > 0
        ? 'Almost there… (${vm.setupOkFrames} / $kSetupCheckFrames)'
        : exercise == ExerciseType.squat
        ? 'Stand sideways — left or right side to the camera'
        : 'Step back until your full body is visible';

    return Positioned(
      top: topPad + 62, // below top HUD bar
      left: 16,
      right: 16,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: isLight
                  ? const Color(0xB8F4F2EC)
                  : const Color(0xB8141414),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isLight
                    ? const Color(0x33D8D6CD)
                    : const Color(0x332D2D30),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.person_search_rounded,
                  color: isLight
                      ? const Color(0xFF5A8C00)
                      : const Color(0xFFC3F400),
                  size: 16,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    text,
                    style: TextStyle(
                      color: isLight ? const Color(0xFF1A1C14) : Colors.white,
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
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Framing hint banner — amber warning pill.
// ──────────────────────────────────────────────────────────────────────────────

class _FramingHintBanner extends StatelessWidget {
  final String hint;

  const _FramingHintBanner({required this.hint});

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final topPad = MediaQuery.of(context).padding.top;

    return Positioned(
      top: topPad + 62,
      left: 16,
      right: 16,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
            decoration: BoxDecoration(
              color: isLight
                  ? const Color(0xB8FFF3E0)
                  : const Color(0xB8251800),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0x66FFB300)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.crop_free, color: Color(0xFFFFB300), size: 16),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    hint,
                    style: TextStyle(
                      color: isLight ? const Color(0xFF5A3A00) : Colors.white,
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
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Generic info banner (cyan = uncalibrated notice, amber = view flip).
// ──────────────────────────────────────────────────────────────────────────────

enum _BannerTone { cyan, amber }

class _InfoBanner extends StatelessWidget {
  final IconData icon;
  final String text;
  final _BannerTone tone;

  const _InfoBanner({
    required this.icon,
    required this.text,
    required this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final topPad = MediaQuery.of(context).padding.top;

    final (iconColor, bgDark, bgLight, borderColor) = switch (tone) {
      _BannerTone.cyan => (
        isLight ? const Color(0xFF007A85) : const Color(0xFF00EEFC),
        const Color(0xB8001C20),
        const Color(0xB8E0F7FA),
        const Color(0x6600EEFC),
      ),
      _BannerTone.amber => (
        const Color(0xFFFFB300),
        const Color(0xB8251800),
        const Color(0xB8FFF8E1),
        const Color(0x66FFB300),
      ),
    };

    return Positioned(
      top: topPad + 62,
      left: 16,
      right: 16,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
            decoration: BoxDecoration(
              color: isLight ? bgLight : bgDark,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: iconColor, size: 16),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    text,
                    style: TextStyle(
                      color: isLight ? const Color(0xFF1A1C14) : Colors.white,
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
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Occlusion banner — full-width orange warning at top.
// ──────────────────────────────────────────────────────────────────────────────

class _OcclusionBanner extends StatelessWidget {
  const _OcclusionBanner();

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    return Positioned(
      top: topPad + 62,
      left: 0,
      right: 0,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
            decoration: const BoxDecoration(
              color: Color(0xCC4A1A00),
              border: Border(bottom: BorderSide(color: Color(0x88FF8A3D))),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.visibility_off_rounded,
                  color: Color(0xFFFF8A3D),
                  size: 16,
                ),
                SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Move into frame — keep all joints visible',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Reusable glass pill chip (view indicator, etc.)
// ──────────────────────────────────────────────────────────────────────────────

class _GlassPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color iconColor;

  const _GlassPill({
    required this.icon,
    required this.label,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;

    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: isLight ? const Color(0xB8F4F2EC) : const Color(0xB8141414),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: isLight
                  ? const Color(0x33D8D6CD)
                  : const Color(0x332D2D30),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: iconColor, size: 14),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: isLight ? const Color(0xFF1A1C14) : Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Coach Toast — card-ai style with backdrop blur, cyan icon holder.
// ──────────────────────────────────────────────────────────────────────────────

class _CoachToast extends StatefulWidget {
  const _CoachToast();

  @override
  State<_CoachToast> createState() => _CoachToastState();
}

class _CoachToastState extends State<_CoachToast>
    with SingleTickerProviderStateMixin {
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
  late final AnimationController _slideCtrl;
  late final Animation<Offset> _slideAnim;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutCubic));
    _fadeAnim = CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOut);
    _slideCtrl.forward();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted) return;
      _slideCtrl.reset();
      setState(() => _index = (_index + 1) % _tips.length);
      _slideCtrl.forward();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _slideCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tip = _tips[_index];
    final isLight = Theme.of(context).brightness == Brightness.light;
    final cyanColor = isLight
        ? const Color(0xFF007A85)
        : const Color(0xFF00EEFC);

    return Positioned(
      left: 16,
      right: 16,
      bottom: 148,
      child: FadeTransition(
        opacity: _fadeAnim,
        child: SlideTransition(
          position: _slideAnim,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isLight
                      ? const Color(0xDEF4F2EC)
                      : const Color(0xD9141414),
                  borderRadius: BorderRadius.circular(12),
                  border: Border(
                    left: BorderSide(color: cyanColor, width: 3),
                    top: BorderSide(
                      color: isLight
                          ? const Color(0x22D8D6CD)
                          : const Color(0x222D2D30),
                    ),
                    right: BorderSide(
                      color: isLight
                          ? const Color(0x22D8D6CD)
                          : const Color(0x222D2D30),
                    ),
                    bottom: BorderSide(
                      color: isLight
                          ? const Color(0x22D8D6CD)
                          : const Color(0x222D2D30),
                    ),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 32×32 icon holder with cyan tint
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: isLight
                            ? const Color(0x1F007A85)
                            : const Color(0x1F00EEFC),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(tip.icon, color: cyanColor, size: 16),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'COACH · ${tip.label.toUpperCase()}',
                            style: TextStyle(
                              color: cyanColor,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2,
                              height: 1,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            tip.text,
                            style: TextStyle(
                              color: isLight
                                  ? const Color(0xFF1A1C14)
                                  : const Color(0xFFE5E2E1),
                              fontSize: 13,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Minimal HUD — rep counter at 38% height + glassmorphic bottom stats card.
// ──────────────────────────────────────────────────────────────────────────────

class _MinimalHud extends StatelessWidget {
  final RepSnapshot snapshot;
  const _MinimalHud({required this.snapshot});

  static const int _targetReps = 12;

  static String _formErrorLabel(FormError e) {
    final spaced = e.name.replaceAllMapped(
      RegExp(r'([A-Z])'),
      (m) => ' ${m[0]}',
    );
    return spaced[0].toUpperCase() + spaced.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    final isLight = Theme.of(context).brightness == Brightness.light;
    final errors = snapshot.formErrors;
    final progress = (snapshot.reps / _targetReps).clamp(0.0, 1.0);

    // Accent glow color for text shadow
    final accentColor = isLight
        ? const Color(0xFF5A8C00)
        : const Color(0xFFC3F400);

    return Stack(
      children: [
        // ── Large reps counter at ~38% vertical position ────────────────────
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
                    // The rep number — unchanged per spec (body frame + counter)
                    Text(
                      '${snapshot.reps}',
                      style: TextStyle(
                        fontSize: 84,
                        fontWeight: FontWeight.w900,
                        color: accentColor,
                        letterSpacing: -4,
                        height: 1,
                        shadows: [
                          Shadow(
                            color: accentColor.withValues(alpha: 0.55),
                            blurRadius: 28,
                          ),
                        ],
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
                    // Set indicator
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

        // ── Bottom stats card — glassmorphic ────────────────────────────────
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
                decoration: BoxDecoration(
                  color: isLight
                      ? const Color(0xDEF4F2EC)
                      : const Color(0xD9141414),
                  border: Border(
                    top: BorderSide(
                      color: isLight
                          ? const Color(0x44D8D6CD)
                          : const Color(0x442D2D30),
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Stats row: Tempo · Time · Set
                    _StatsRow(snapshot: snapshot, isLight: isLight, ft: ft),
                    const SizedBox(height: 12),
                    // Progress label row
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
                          '${(progress * 100).round().clamp(0, 100)}%',
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
                    // Progress bar with glow
                    _GlowProgressBar(
                      value: progress,
                      accentColor: accentColor,
                      trackColor: isLight
                          ? const Color(0xFFECEBE4)
                          : const Color(0xFF2A2A2A),
                    ),
                    // Form error row
                    if (errors.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            color: ft.red,
                            size: 14,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _formErrorLabel(errors.first),
                              style: TextStyle(
                                color: ft.red,
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
          ),
        ),
      ],
    );
  }
}

/// Three-stat row: Set Progress % · Elapsed time placeholder · Set count.
class _StatsRow extends StatelessWidget {
  final RepSnapshot snapshot;
  final bool isLight;
  final FiTrackColors ft;

  const _StatsRow({
    required this.snapshot,
    required this.isLight,
    required this.ft,
  });

  @override
  Widget build(BuildContext context) {
    final dividerColor = isLight
        ? const Color(0x33D8D6CD)
        : const Color(0x332D2D30);

    return Row(
      children: [
        _StatCell(label: 'REPS', value: '${snapshot.reps}', ft: ft),
        _VertDivider(color: dividerColor),
        _StatCell(label: 'TARGET', value: '12', ft: ft),
        _VertDivider(color: dividerColor),
        _StatCell(
          label: 'SET',
          value: '${snapshot.sets}',
          ft: ft,
          valueColor: ft.accent,
        ),
      ],
    );
  }
}

class _StatCell extends StatelessWidget {
  final String label;
  final String value;
  final FiTrackColors ft;
  final Color? valueColor;

  const _StatCell({
    required this.label,
    required this.value,
    required this.ft,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: ft.textDim,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: valueColor ?? ft.textStrong,
              letterSpacing: -0.5,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _VertDivider extends StatelessWidget {
  final Color color;
  const _VertDivider({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 32,
      color: color,
      margin: const EdgeInsets.symmetric(horizontal: 8),
    );
  }
}

/// Progress bar with an accent glow shadow.
class _GlowProgressBar extends StatelessWidget {
  final double value;
  final Color accentColor;
  final Color trackColor;

  const _GlowProgressBar({
    required this.value,
    required this.accentColor,
    required this.trackColor,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final fillWidth = totalWidth * value;

        return Container(
          height: 10,
          decoration: BoxDecoration(
            color: trackColor,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Stack(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                width: fillWidth,
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: [
                    BoxShadow(
                      color: accentColor.withValues(alpha: 0.5),
                      blurRadius: 8,
                      spreadRadius: 0,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
