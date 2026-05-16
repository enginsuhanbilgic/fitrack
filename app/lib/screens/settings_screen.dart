/// User-facing controls for the per-user ROM profile.
///
/// Two responsibilities:
///   1. Show what's calibrated (per-bucket dot indicators + sample counts).
///   2. Provide three actions: Recalibrate, Reset Profile, Diagnostics.
///
/// "Show details" toggle reveals raw min/max angles per bucket — kept hidden
/// by default so the user isn't tempted to optimize the numbers themselves.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:share_plus/share_plus.dart';

import '../app.dart';
import '../core/constants.dart';
import '../core/rom_thresholds.dart';
import '../core/squat_rom_defaults.dart';
import '../core/types.dart';
import '../engine/curl/curl_rom_profile.dart';
import '../engine/push_up/push_up_rom_profile.dart';
import '../engine/squat/squat_rom_profile.dart'
    as squat_profile
    show SquatRomProfile;
import '../services/app_services.dart';
import '../services/db/profile_repository.dart';
import '../services/db/user_profile_repository.dart';
import '../services/demo/demo_service.dart';
import '../services/telemetry_log.dart';
import 'workout_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late ProfileRepository _repository;
  late DemoService _demoService;
  late UserProfileRepository _userProfileRepo;
  bool _servicesResolved = false;
  CurlRomProfile? _profile;
  PushUpRomProfile? _pushUpProfile;
  squat_profile.SquatRomProfile? _squatProfile;
  bool _loading = true;
  bool _showDetails = false;
  bool _squatLongFemurLifter = false;
  bool _diagnosticDisableAutoCalibration = false;
  bool _squatDebugSession = false;
  bool _pushUpDebugSession = false;
  bool _demoEnabled = false;
  bool _demoBusy = false;
  ThemeMode _themeMode = ThemeMode.system;
  FeedbackSensitivity _feedbackSensitivity = FeedbackSensitivity.medium;
  bool _ttsEnabled = true;
  TtsVerbosity _ttsVerbosity = TtsVerbosity.medium;
  bool _hapticsEnabled = true;
  int _formTolerancePercent = kDefaultFormTolerancePercent;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_servicesResolved) {
      final services = AppServicesScope.of(context);
      _repository = services.profileRepository;
      _demoService = services.demoService;
      _userProfileRepo = services.userProfileRepository;
      _servicesResolved = true;
      _reload();
    }
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final services = AppServicesScope.of(context);
    // Demo Mode no longer seeds ROM profiles (operator decision,
    // 2026-05-13 followup) — Settings ROM sections read live keys only.
    // When Demo Mode is on and the user hasn't calibrated yet, the sections
    // honestly show "Not calibrated", matching the cold-start workout path.
    final liveCurl = await _repository.loadCurl();
    final livePushUp = await _repository.loadPushUp();
    final liveSquat = await _repository.loadSquat();
    final demoOn = await _demoService.isEnabled();
    final longFemur = await services.preferencesRepository
        .getSquatLongFemurLifter();
    final diagnosticDisableAutoCal = await services.preferencesRepository
        .getDiagnosticDisableAutoCalibration();
    final squatDebug = kSquatDebugSessionEnabled
        ? await services.preferencesRepository.getSquatDebugSession()
        : false;
    final pushUpDebug = kPushUpDebugSessionEnabled
        ? await services.preferencesRepository.getPushUpDebugSession()
        : false;
    final themeMode = await services.preferencesRepository.getThemeMode();
    final feedbackSensitivity = await services.preferencesRepository
        .getFeedbackSensitivity();
    final tts = await services.preferencesRepository.getTtsEnabled();
    final ttsVerbosity = await services.preferencesRepository.getTtsVerbosity();
    final haptics = await services.preferencesRepository.getHapticsEnabled();
    final formTolerancePercent = await services.preferencesRepository
        .getFormTolerancePercent();
    if (!mounted) return;
    setState(() {
      _profile = liveCurl;
      _pushUpProfile = livePushUp;
      _squatProfile = liveSquat;
      _squatLongFemurLifter = longFemur;
      _diagnosticDisableAutoCalibration = diagnosticDisableAutoCal;
      _squatDebugSession = squatDebug;
      _pushUpDebugSession = pushUpDebug;
      _themeMode = themeMode;
      _feedbackSensitivity = feedbackSensitivity;
      _ttsEnabled = tts;
      _ttsVerbosity = ttsVerbosity;
      _hapticsEnabled = haptics;
      _formTolerancePercent = formTolerancePercent;
      _demoEnabled = demoOn;
      _loading = false;
    });
  }

  /// Sample Data toggle handler. Wraps `enableAndSeed`/`disable` with a
  /// confirmation dialog when enabling demo would overwrite a real user
  /// profile (Gap 33), busy-spinner to prevent re-entry during the long
  /// async op, and a full `_reload` afterward so the ROM cards refresh.
  Future<void> _setDemoEnabled(bool value) async {
    if (_demoBusy) return;
    if (value) {
      // Per Gap 33: warn the user before overwriting a real profile.
      final realProfileExists =
          (await _userProfileRepo.load()) != null &&
          !await _userProfileRepo.isDemoRow();
      if (realProfileExists && mounted) {
        final confirmed = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text('Enable Sample Data?'),
            content: const Text(
              'Demo Mode will temporarily replace your profile with sample '
              'data. Your saved profile will be restored when you turn '
              'Demo Mode off.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Continue'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
      }
    }
    setState(() => _demoBusy = true);
    try {
      if (value) {
        await _demoService.enableAndSeed();
      } else {
        await _demoService.disable();
      }
    } finally {
      if (mounted) {
        setState(() => _demoBusy = false);
        await _reload();
      }
    }
  }

  Future<void> _confirmResetSquat() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Squat Profile?'),
        content: const Text(
          'This deletes your saved squat range of motion. The next workout '
          'will fall back to default thresholds until you recalibrate. This '
          'cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _repository.resetSquat();
      await _reload();
    }
  }

  Future<void> _setTtsEnabled(bool value) async {
    final prefs = AppServicesScope.read(context).preferencesRepository;
    await prefs.setTtsEnabled(value);
    TelemetryLog.instance.log(
      'preferences.tts_enabled_changed',
      'enabled=$value',
    );
    if (!mounted) return;
    setState(() => _ttsEnabled = value);
  }

  Future<void> _setTtsVerbosity(TtsVerbosity value) async {
    final prefs = AppServicesScope.read(context).preferencesRepository;
    await prefs.setTtsVerbosity(value);
    TelemetryLog.instance.log(
      'preferences.tts_verbosity_changed',
      'verbosity=${value.name}',
    );
    if (!mounted) return;
    setState(() => _ttsVerbosity = value);
  }

  /// Opens an AlertDialog explaining the scope of Coaching strictness.
  /// Companion to [_showFormToleranceHelp] — together they answer the
  /// "wait, what does each dial actually do?" question that surfaced
  /// during the 2026-05-15 planning conversation. Wording mirrors the
  /// form tolerance dialog (same five sections) so the two read as a
  /// paired set rather than two independent monologues.
  Future<void> _showCoachingStrictnessHelp(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Coaching strictness'),
        content: const SingleChildScrollView(
          child: Text(
            'WHAT IT DOES\n'
            'Controls the range-of-motion gates that decide whether a '
            'movement counts as a rep. Applies to all exercises (curl, '
            'squat, push-up) and at every threshold tier (calibrated, '
            'auto-calibrated, cold-start).\n\n'
            'WHAT THE LEVELS MEAN\n'
            'High — strict. Reps must reach deeper peak flex and return '
            'closer to full extension to be counted. Better for technique '
            'training.\n'
            'Medium — easier. Shallower peaks and shallower returns still '
            'count. Better for fatigue sets and momentum drills.\n\n'
            'WHAT IT DOES NOT AFFECT\n'
            '• Form-error coaching loudness — that is "Curl form '
            'tolerance" below, a separate dial.\n'
            '• The biomechanical fault thresholds themselves (lean, swing, '
            'shrug, drift, elbow rise) — those are fixed safety gates.\n'
            '• Post-session form audit summaries — those always read the '
            'true motion regardless of strictness.\n\n'
            'COACHING STRICTNESS vs FORM TOLERANCE\n'
            'Coaching strictness controls *when a movement counts as a '
            'rep.* Form tolerance controls *when the analyzer talks to '
            'you about how that rep looked.* Two independent dials that '
            'never read each other.\n\n'
            'SCOPE\n'
            'All exercises (curl, squat, push-up). Comprehensive across '
            'all three resolver tiers — switching levels mid-app updates '
            'every rep that follows, calibrated or not.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  /// Human-readable subtitle for the Form Tolerance slider (Option B
  /// labeling, 2026-05-15): the slider keeps the `0 → 100` direction the
  /// user expects from a percent control, but every band's wording spells
  /// out direction explicitly so the percentage can't be misread as "fail
  /// probability." Five bands at 0 / 25 / 50 / 75 / 100 mark the dial's
  /// meaningful regions.
  static String _formToleranceSubtitle(int percent) {
    if (percent == 0) {
      return "0% — Strict (today's default). All sub-fault motion warned.";
    }
    if (percent <= 25) {
      return '$percent% — Mostly strict. Borderline form warned.';
    }
    if (percent < 75) {
      return '$percent% — Balanced. Mid-range motion stays silent.';
    }
    if (percent < 100) {
      return '$percent% — Relaxed. Only obvious form issues warned.';
    }
    return '100% — Most relaxed. Only clear faults trigger cues.';
  }

  /// Opens an AlertDialog explaining what the slider does and (more
  /// importantly) what it does NOT do — see the Sensitivity vs Form Audit
  /// doctrine in `.agent_brain/SKILLS.md`. The text exists to keep users
  /// from confusing this dial with "Coaching strictness" (ROM sensitivity);
  /// it answers in the help body the four questions that surfaced during
  /// the 2026-05-15 planning conversation (direction, scope, independence,
  /// what stays unaffected).
  Future<void> _showFormToleranceHelp(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Curl form tolerance'),
        content: const SingleChildScrollView(
          child: Text(
            'WHAT IT DOES\n'
            'Widens the silent budget before a form cue fires (lean, swing, '
            'drift, shrug, elbow rise) on biceps curls.\n\n'
            'WHAT THE NUMBERS MEAN\n'
            "0% — Strict (today's default). Every borderline motion is "
            'warned.\n'
            '100% — Most relaxed. Only clear, biomechanically-real faults '
            'trigger cues; minor postural shifts stay silent.\n'
            'The audit threshold is the ceiling — a real cheat (e.g. a 30° '
            'forward lean) fires at every setting. The slider widens '
            'silence below that line, it never weakens it.\n\n'
            'WHAT IT DOES NOT AFFECT\n'
            '• Rep counting — that is "Coaching strictness," a separate '
            'dial above.\n'
            '• Rep quality scoring — your per-rep score always reads the '
            'full motion, no matter where this slider sits.\n'
            '• The post-session form summary — always shows the truth.\n\n'
            'COACHING STRICTNESS vs FORM TOLERANCE\n'
            'Coaching strictness controls *when a movement counts as a '
            'rep.* Form tolerance controls *when the analyzer talks to '
            'you about how that rep looked.* Two independent dials.\n\n'
            'SCOPE\n'
            'Biceps curl only today. Squat and push-up coming in a '
            'follow-up.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  /// Persist a new Form Tolerance Percent. Called from the Slider's
  /// `onChangeEnd` so SQLite is not hit on every detent — live-preview
  /// updates `_formTolerancePercent` via local `setState` during drag.
  /// The repository clamps to `[0, 100]` on write; no need to pre-clamp
  /// here (the Slider widget can only emit values inside its `[min, max]`
  /// range anyway).
  Future<void> _setFormTolerancePercent(int value) async {
    final prefs = AppServicesScope.read(context).preferencesRepository;
    await prefs.setFormTolerancePercent(value);
    TelemetryLog.instance.log(
      'preferences.form_tolerance_changed',
      'percent=$value',
    );
    if (!mounted) return;
    setState(() => _formTolerancePercent = value);
  }

  Future<void> _setHapticsEnabled(bool value) async {
    final prefs = AppServicesScope.read(context).preferencesRepository;
    await prefs.setHapticsEnabled(value);
    TelemetryLog.instance.log(
      'preferences.haptics_enabled_changed',
      'enabled=$value',
    );
    if (!mounted) return;
    setState(() => _hapticsEnabled = value);
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    // Capture both context-dependent objects before the await gap.
    final prefs = AppServicesScope.read(context).preferencesRepository;
    final themeModeNotifier = ThemeModeScope.of(context);
    await prefs.setThemeMode(mode);
    themeModeNotifier.value = mode;
    TelemetryLog.instance.log('preferences.theme_mode_changed', mode.name);
    if (!mounted) return;
    setState(() => _themeMode = mode);
  }

  Future<void> _setSquatLongFemurLifter(bool value) async {
    final prefs = AppServicesScope.read(context).preferencesRepository;
    await prefs.setSquatLongFemurLifter(value);
    TelemetryLog.instance.log(
      'preferences.squat_long_femur_toggled',
      'enabled=$value',
    );
    if (!mounted) return;
    setState(() => _squatLongFemurLifter = value);
  }

  Future<void> _setDiagnosticDisableAutoCalibration(bool value) async {
    final prefs = AppServicesScope.read(context).preferencesRepository;
    await prefs.setDiagnosticDisableAutoCalibration(value);
    TelemetryLog.instance.log(
      'preferences.diagnostic_mode_toggled',
      'enabled=$value',
    );
    if (!mounted) return;
    setState(() => _diagnosticDisableAutoCalibration = value);
  }

  Future<void> _setSquatDebugSession(bool value) async {
    final prefs = AppServicesScope.read(context).preferencesRepository;
    await prefs.setSquatDebugSession(value);
    TelemetryLog.instance.log(
      'preferences.squat_debug_session_toggled',
      'enabled=$value',
    );
    if (!mounted) return;
    setState(() => _squatDebugSession = value);
  }

  Future<void> _setPushUpDebugSession(bool value) async {
    final prefs = AppServicesScope.read(context).preferencesRepository;
    await prefs.setPushUpDebugSession(value);
    TelemetryLog.instance.log(
      'preferences.pushup_debug_session_toggled',
      'enabled=$value',
    );
    if (!mounted) return;
    setState(() => _pushUpDebugSession = value);
  }

  Future<void> _setFeedbackSensitivity(FeedbackSensitivity sensitivity) async {
    final prefs = AppServicesScope.read(context).preferencesRepository;
    await prefs.setFeedbackSensitivity(sensitivity);
    TelemetryLog.instance.log(
      'preferences.feedback_sensitivity_changed',
      sensitivity.name,
    );
    if (!mounted) return;
    setState(() => _feedbackSensitivity = sensitivity);
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Profile?'),
        content: const Text(
          'This deletes your saved range of motion. The next workout will '
          'prompt you to recalibrate. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok == true) {
      // Curl-only reset. Prior to 2026-05-13 this also wiped the push-up
      // profile, which contradicted the button label — push-up now has its
      // own _confirmResetPushUp entrypoint.
      await _repository.resetCurl();
      await _reload();
    }
  }

  Future<void> _confirmResetPushUp() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Push-Up Profile?'),
        content: const Text(
          'This deletes your calibrated push-up range. The push-up audit '
          'will fall back to default thresholds until you recalibrate. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _repository.resetPushUp();
      await _reload();
    }
  }

  Future<void> _recalibrate(ExerciseType exercise) async {
    if (!mounted) return;
    // Curl is the only exercise where the user picks a side per calibration
    // pass. Pre-session bottom-sheet matches the home-screen flow so the side
    // is committed before WorkoutScreen mounts; the in-overlay picker becomes
    // a fallback for the (now-rare) case where the VM enters calibration with
    // `curlSide == both`. Without this, the previous Settings path defaulted
    // to ExerciseSide.both and let the analyzer pick the arm by landmark
    // confidence — which consistently selected the right arm regardless of
    // user intent.
    ExerciseSide curlSide = ExerciseSide.both;
    if (exercise.isCurl) {
      final picked = await _showSideFacingPickerForCalibration(context);
      if (picked == null) return; // user dismissed sheet
      if (!mounted) return;
      curlSide = picked;
    }
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => WorkoutScreen(
          exercise: exercise,
          forceCalibration: true,
          curlSide: curlSide,
        ),
      ),
    );
  }

  /// Pre-session side picker for curl recalibration.
  ///
  /// Faithful clone of [_FtExercisesTab._showSideFacingPicker] in
  /// `home_screen.dart` — same camera-frame ↔ user-frame mapping so the
  /// "Left" tile maps to `ExerciseSide.right` (right-side-of-frame is the
  /// user's physical LEFT arm under front-camera mirroring) and vice versa.
  /// Do NOT "fix" the mapping — see the doc comments on the home-screen
  /// version; a 2026-04-27 swap broke this and was reverted.
  Future<ExerciseSide?> _showSideFacingPickerForCalibration(
    BuildContext context,
  ) {
    final theme = Theme.of(context);
    return showModalBottomSheet<ExerciseSide>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Text(
                  'Which arm to calibrate?',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.swipe_left),
                title: const Text('Left'),
                subtitle: const Text('Calibrate your left arm'),
                // User's physical left arm = camera's right side =
                // ExerciseSide.right. See home_screen.dart line 1125-1131.
                onTap: () => Navigator.pop(ctx, ExerciseSide.right),
              ),
              ListTile(
                leading: const Icon(Icons.swipe_right),
                title: const Text('Right'),
                subtitle: const Text('Calibrate your right arm'),
                onTap: () => Navigator.pop(ctx, ExerciseSide.left),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _openDiagnostics() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const _DiagnosticsScreen()),
    );
  }

  Widget _sectionHeader(BuildContext context, String label) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        label,
        style: TextStyle(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  Widget _subSectionHeader(BuildContext context, String label) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Text(
        label,
        style: TextStyle(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── 1. Calibration ─────────────────────────────────────────
                // Curl and squat calibration sit together as one group with
                // per-exercise subsections. Pre-2026-05-13 this was split:
                // curl at the top, squat near the bottom — confusing scan.
                _sectionHeader(context, 'Calibration'),

                // Biceps Curl
                (() {
                  final theme = Theme.of(context);
                  final status = _CurlProfileContent.overallStatus(
                    _profile,
                    theme,
                  );
                  return ExpansionTile(
                    shape: const Border(), // Remove default top/bottom borders
                    title: const Text('Biceps Curl'),
                    leading: const Icon(Icons.fitness_center),
                    trailing: _StatusPill(label: status.$1, color: status.$2),
                    children: [
                      _CurlProfileContent(
                        profile: _profile,
                        showDetails: _showDetails,
                        onToggleDetails: (v) =>
                            setState(() => _showDetails = v),
                      ),
                      _RomDefaultsTile.forCurl(_feedbackSensitivity),
                      _ActionRow(
                        icon: Icons.refresh,
                        label: 'Recalibrate curl',
                        subtitle: 'Re-record your full range of motion.',
                        onTap: () => _recalibrate(ExerciseType.bicepsCurlSide),
                      ),
                      _ActionRow(
                        icon: Icons.delete_outline,
                        label: 'Reset curl profile',
                        subtitle: 'Delete all calibrated buckets.',
                        destructive: true,
                        onTap: _confirmReset,
                      ),
                      const SizedBox(height: 8),
                    ],
                  );
                })(),

                // Squat
                (() {
                  final theme = Theme.of(context);
                  final status = _SquatProfileContent.overallStatus(
                    _squatProfile,
                    theme,
                  );
                  return ExpansionTile(
                    shape: const Border(),
                    title: const Text('Squat'),
                    leading: const Icon(Icons.accessibility),
                    trailing: _StatusPill(label: status.$1, color: status.$2),
                    children: [
                      _SquatProfileContent(profile: _squatProfile),
                      _RomDefaultsTile.forSquat(_feedbackSensitivity),
                      _ActionRow(
                        icon: Icons.refresh,
                        label: 'Recalibrate squat',
                        subtitle: 'Record your full squat range of motion.',
                        onTap: () => _recalibrate(ExerciseType.squat),
                      ),
                      _ActionRow(
                        icon: Icons.delete_outline,
                        label: 'Reset squat profile',
                        subtitle: 'Delete your calibrated squat range.',
                        destructive: true,
                        onTap: _confirmResetSquat,
                      ),
                      SwitchListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        dense: true,
                        title: const Text('Tall lifter (relax lean threshold)'),
                        subtitle: const Text('Applies to next workout'),
                        value: _squatLongFemurLifter,
                        onChanged: _setSquatLongFemurLifter,
                      ),
                      const SizedBox(height: 8),
                    ],
                  );
                })(),

                // Push-up
                (() {
                  final theme = Theme.of(context);
                  final status = _PushUpProfileContent.overallStatus(
                    _pushUpProfile,
                    theme,
                  );
                  return ExpansionTile(
                    shape: const Border(),
                    title: const Text('Push-up'),
                    leading: const Icon(Icons.accessibility_new),
                    trailing: _StatusPill(label: status.$1, color: status.$2),
                    children: [
                      _PushUpProfileContent(profile: _pushUpProfile),
                      _RomDefaultsTile.forPushUp(_feedbackSensitivity),
                      _ActionRow(
                        icon: Icons.refresh,
                        label: 'Recalibrate push-up',
                        subtitle: 'Record your top and bottom push-up angles.',
                        onTap: () => _recalibrate(ExerciseType.pushUp),
                      ),
                      _ActionRow(
                        icon: Icons.delete_outline,
                        label: 'Reset push-up profile',
                        subtitle: 'Delete your calibrated push-up range.',
                        destructive: true,
                        onTap: _confirmResetPushUp,
                      ),
                      const SizedBox(height: 8),
                    ],
                  );
                })(),

                const Divider(),

                // ── 2. Workout ─────────────────────────────────────────────
                _sectionHeader(context, 'Workout'),
                // ── Coaching strictness ─────────────────────────────────
                // Controls REP-COUNTING ROM gates only. Form-error cue
                // loudness is governed by "Curl form tolerance" below —
                // two independent dials per the 2026-05-14 doctrine.
                // Subtitle wording matches that boundary literally so the
                // user doesn't carry over the pre-2026-05-14 mental model
                // ("strictness ⇒ everything coaching").
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Row(
                    children: [
                      const Text('Coaching strictness'),
                      IconButton(
                        icon: const Icon(Icons.help_outline, size: 18),
                        tooltip: 'About coaching strictness',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () => _showCoachingStrictnessHelp(context),
                      ),
                    ],
                  ),
                  subtitle: const Text(
                    'How strict the rep-counting range-of-motion gates are. '
                    'Does not affect form-error coaching loudness — see '
                    'Curl form tolerance below.',
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SegmentedButton<FeedbackSensitivity>(
                    segments: [
                      for (final s in FeedbackSensitivity.values)
                        ButtonSegment(value: s, label: Text(s.label)),
                    ],
                    selected: {_feedbackSensitivity},
                    onSelectionChanged: (s) => _setFeedbackSensitivity(s.first),
                  ),
                ),
                // ── Curl form tolerance slider ──────────────────────────
                // Scales the curl form-audit dead-band only. Does NOT
                // affect rep counting, quality scoring, or post-session
                // audit summaries (those always use the true magnitudes).
                // At 0 the analyzer behaves bit-for-bit like the
                // 2026-05-15 baseline; at 100 the dead-band collapses
                // onto the audit threshold (cues only fire on clear
                // faults). Title is curl-only-honest until the
                // squat/push-up dead-band layer follow-up lands.
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Row(
                    children: [
                      const Text('Curl form tolerance'),
                      IconButton(
                        icon: const Icon(Icons.help_outline, size: 18),
                        tooltip: 'About curl form tolerance',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () => _showFormToleranceHelp(context),
                      ),
                    ],
                  ),
                  subtitle: Text(_formToleranceSubtitle(_formTolerancePercent)),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Slider(
                    min: 0,
                    max: 100,
                    divisions: 20,
                    label: '$_formTolerancePercent%',
                    value: _formTolerancePercent.toDouble(),
                    // Live preview during drag: cheap setState, no SQLite hit.
                    onChanged: (v) =>
                        setState(() => _formTolerancePercent = v.round()),
                    // Persist only when the user releases the slider so the
                    // DB isn't written 20 times per drag.
                    onChangeEnd: (v) => _setFormTolerancePercent(v.round()),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Spoken coaching (TTS)'),
                  subtitle: const Text('Audio cues during workouts'),
                  value: _ttsEnabled,
                  onChanged: _setTtsEnabled,
                ),
                // Voice frequency — caps repeats of the same form-error cue
                // within a session. Visual highlights and the session-end
                // summary are unaffected; only the audio falls quiet after
                // the cap is hit. Disabled when TTS is off because there's
                // nothing to limit.
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  enabled: _ttsEnabled,
                  title: const Text('Voice frequency'),
                  subtitle: Text(switch (_ttsVerbosity) {
                    TtsVerbosity.low => 'Speak each form cue once per session',
                    TtsVerbosity.medium =>
                      'Speak each form cue up to $kTtsVerbosityMediumCap times per session',
                    TtsVerbosity.high => 'Speak every form cue, every time',
                  }),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SegmentedButton<TtsVerbosity>(
                    segments: [
                      for (final v in TtsVerbosity.values)
                        ButtonSegment(value: v, label: Text(v.label)),
                    ],
                    selected: {_ttsVerbosity},
                    onSelectionChanged: _ttsEnabled
                        ? (s) => _setTtsVerbosity(s.first)
                        : null,
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Haptic feedback'),
                  subtitle: const Text(
                    'Vibration on rep complete and form alerts',
                  ),
                  value: _hapticsEnabled,
                  onChanged: _setHapticsEnabled,
                ),
                // Auto-calibration toggle hidden 2026-05-15: the in-session
                // tier-2 refiner is permanently disabled at the persistence
                // layer (setAutoCalibrationEnabled is a no-op). UI surface
                // removed so users can't be misled into thinking the feature
                // is configurable. Engine code retained for possible future
                // reinstatement — see WorkoutViewModel autocal.disabled log.
                const Divider(),

                // ── 3. App ─────────────────────────────────────────────────
                _sectionHeader(context, 'App'),
                _subSectionHeader(context, 'Appearance'),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        icon: Icon(Icons.brightness_auto),
                        label: Text('System'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode),
                        label: Text('Light'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        icon: Icon(Icons.dark_mode),
                        label: Text('Dark'),
                      ),
                    ],
                    selected: {_themeMode},
                    onSelectionChanged: (s) => _setThemeMode(s.first),
                  ),
                ),
                _SampleDataSection(
                  enabled: _demoEnabled,
                  busy: _demoBusy,
                  onChanged: _setDemoEnabled,
                ),
                const Divider(),

                // ── 4. Diagnostics & Advanced ──────────────────────────────
                // Bottom of the page on purpose: low-frequency, some toggles
                // are destructive to data quality if left on. The telemetry
                // shortcut sits next to its companion toggles instead of
                // floating above the destructive Reset Profile rows where it
                // used to invite thumb-slips.
                _sectionHeader(context, 'Diagnostics & Advanced'),
                _ActionRow(
                  icon: Icons.science_outlined,
                  label: 'Diagnostics',
                  subtitle: '${TelemetryLog.instance.length} telemetry entries',
                  onTap: _openDiagnostics,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Diagnostic mode'),
                  subtitle: const Text(
                    'Developer override. Forces every rep (curl, squat, '
                    'push-up) onto cold-start defaults — bypasses both '
                    'calibrated personal profiles AND the Auto-calibration '
                    'switch above. Feedback stays ON. Turn off after '
                    'testing — leaving this on means your calibration '
                    'never applies.',
                  ),
                  value: _diagnosticDisableAutoCalibration,
                  onChanged: _setDiagnosticDisableAutoCalibration,
                ),
                if (kSquatDebugSessionEnabled)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Squat debug session'),
                    subtitle: const Text(
                      'Silent observation: no TTS / haptics / banners. '
                      'Logs frame-level pose metrics for threshold tuning. '
                      'Turn on, run a session, paste Diagnostics, turn off.',
                    ),
                    value: _squatDebugSession,
                    onChanged: _setSquatDebugSession,
                  ),
                if (kPushUpDebugSessionEnabled)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Push-up debug session'),
                    subtitle: const Text(
                      'Silent observation: no TTS / haptics / banners. '
                      'Logs frame-level pose metrics for threshold tuning. '
                      'Turn on, run a session, paste Diagnostics, turn off.',
                    ),
                    value: _pushUpDebugSession,
                    onChanged: _setPushUpDebugSession,
                  ),
              ],
            ),
    );
  }
}

/// Biceps-curl-only calibration content.
class _CurlProfileContent extends StatelessWidget {
  final CurlRomProfile? profile;
  final bool showDetails;
  final ValueChanged<bool> onToggleDetails;

  const _CurlProfileContent({
    required this.profile,
    required this.showDetails,
    required this.onToggleDetails,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = profile;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (p == null || p.buckets.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Not calibrated. Start a workout to begin recording.',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
                ),
              ),
            )
          else
            ..._allCombos().map((combo) {
              final (side, view) = combo;
              final bucket = p.bucketFor(side, view);
              return _BucketRow(
                side: side,
                view: view,
                bucket: bucket,
                showDetails: showDetails,
              );
            }),
          if (p != null && p.buckets.isNotEmpty)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Show details'),
              value: showDetails,
              onChanged: onToggleDetails,
            ),
        ],
      ),
    );
  }

  static List<(ProfileSide, CurlCameraView)> _allCombos() => const [
    (ProfileSide.left, CurlCameraView.sideLeft),
    (ProfileSide.right, CurlCameraView.sideRight),
  ];

  static (String, Color) overallStatus(CurlRomProfile? p, ThemeData theme) {
    final summary = p == null ? null : ProfileSummary.of(p);
    if (summary == null || summary.totalBuckets == 0) {
      return (
        'Uncalibrated',
        theme.colorScheme.onSurface.withValues(alpha: 0.38),
      );
    }
    if (summary.calibratedBuckets == 0) {
      return ('Auto', Colors.orangeAccent);
    }
    return ('Calibrated', const Color(0xFF00E676));
  }
}

class _BucketRow extends StatelessWidget {
  final ProfileSide side;
  final CurlCameraView view;
  final RomBucket? bucket;
  final bool showDetails;

  const _BucketRow({
    required this.side,
    required this.view,
    required this.bucket,
    required this.showDetails,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final calibrated =
        bucket != null && bucket!.sampleCount >= kCalibrationMinReps;
    final dotColor = calibrated
        ? const Color(0xFF00E676)
        : (bucket == null
              ? theme.colorScheme.onSurface.withValues(alpha: 0.24)
              : Colors.orangeAccent);
    final samples = bucket?.sampleCount ?? 0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${_sideLabel(side)} · ${_viewLabel(view)}',
                  style: const TextStyle(fontSize: 15),
                ),
              ),
              Text(
                '$samples ${samples == 1 ? "rep" : "reps"}',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.60),
                  fontSize: 13,
                ),
              ),
            ],
          ),
          if (showDetails && bucket != null)
            Padding(
              padding: const EdgeInsets.only(left: 22, top: 4),
              child: Text(
                'Peak ${bucket!.observedMinAngle.toStringAsFixed(0)}° · '
                'Rest ${bucket!.observedMaxAngle.toStringAsFixed(0)}°',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _sideLabel(ProfileSide s) => switch (s) {
    ProfileSide.left => 'Left arm',
    ProfileSide.right => 'Right arm',
  };

  static String _viewLabel(CurlCameraView v) => switch (v) {
    CurlCameraView.front => 'front',
    CurlCameraView.sideLeft => 'side L',
    CurlCameraView.sideRight => 'side R',
    CurlCameraView.unknown => '—',
  };
}

class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Squat-profile summary content.
class _SquatProfileContent extends StatelessWidget {
  final squat_profile.SquatRomProfile? profile;

  const _SquatProfileContent({required this.profile});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = profile;
    final bucket = p?.bucket;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (bucket == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Not calibrated. Use Recalibrate to record your deepest '
                'squat and standing extension.',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
                ),
              ),
            )
          else
            Text(
              'Bottom ${bucket.observedMinKneeAngle.toStringAsFixed(0)}° · '
              'Top ${bucket.observedMaxKneeAngle.toStringAsFixed(0)}° · '
              'ROM ${(bucket.observedMaxKneeAngle - bucket.observedMinKneeAngle).toStringAsFixed(0)}°',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
              ),
            ),
          if (bucket != null) ...[
            const SizedBox(height: 6),
            Text(
              '${bucket.sampleCount} ${bucket.sampleCount == 1 ? "rep" : "reps"} '
              '· updated ${_relativeTime(bucket.lastUpdated)}',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static (String, Color) overallStatus(
    squat_profile.SquatRomProfile? p,
    ThemeData theme,
  ) {
    final isCalibrated = p?.isCalibrated ?? false;
    return (
      isCalibrated ? 'Calibrated' : 'Uncalibrated',
      isCalibrated
          ? const Color(0xFF00E676)
          : theme.colorScheme.onSurface.withValues(alpha: 0.38),
    );
  }

  static String _relativeTime(DateTime t) {
    final delta = DateTime.now().difference(t);
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inHours < 1) return '${delta.inMinutes}m ago';
    if (delta.inDays < 1) return '${delta.inHours}h ago';
    return '${delta.inDays}d ago';
  }
}

/// Push-up calibration content. Mirrors [_SquatProfileContent]'s single-bucket
/// shape (push-up profile has no per-side splits). Split out from
/// [_CurlProfileContent] 2026-05-13 so the "Push-up" subheading on the Settings
/// → Calibration screen actually corresponds to its own card.
class _PushUpProfileContent extends StatelessWidget {
  final PushUpRomProfile? profile;

  const _PushUpProfileContent({required this.profile});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = profile;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (p == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Not calibrated. Use Recalibrate to record your top and '
                'bottom push-up angles.',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
                ),
              ),
            )
          else
            Text(
              'Top ${p.topAngle.toStringAsFixed(0)}° · '
              'Bottom ${p.bottomAngle.toStringAsFixed(0)}° · '
              'ROM ${p.romDegrees.toStringAsFixed(0)}°',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
              ),
            ),
        ],
      ),
    );
  }

  static (String, Color) overallStatus(PushUpRomProfile? p, ThemeData theme) {
    final isCalibrated = p?.isCalibrated ?? false;
    return (
      isCalibrated ? 'Calibrated' : 'Uncalibrated',
      isCalibrated
          ? const Color(0xFF00E676)
          : theme.colorScheme.onSurface.withValues(alpha: 0.38),
    );
  }
}

/// Collapsed-by-default tile showing the **resolved cold-start ROM defaults**
/// for one exercise at the current sensitivity. These are the same numbers the
/// FSM logs in `*.thresholds_resolved` lines — surface them in-app so users
/// can correlate live `angle_raw` traces with the gates that actually run.
///
/// Always reflects the FSM's view of the world: anchors with the sensitivity
/// post-pass already applied. Does NOT show calibrated personal thresholds
/// (Q3 deferred — see 2026-05-15 design discussion).
class _RomDefaultsTile extends StatelessWidget {
  const _RomDefaultsTile({
    required this.sensitivity,
    required this.rows,
    this.subtitle,
  });

  /// Active sensitivity — shown in the tile subtitle so the user knows which
  /// post-pass produced the numbers below.
  final FeedbackSensitivity sensitivity;

  /// `(label, angle°)` pairs. Each exercise supplies its own field set —
  /// curl has 4, squat has 3, push-up has 4 (different names).
  final List<(String, double)> rows;

  /// Optional extra qualifier appended after the sensitivity name
  /// (e.g. "side-right" for curl).
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitleText = subtitle == null
        ? sensitivity.name
        : '${sensitivity.name} · $subtitle';
    return ExpansionTile(
      shape: const Border(),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: const Icon(Icons.tune, size: 20),
      title: const Text('ROM defaults'),
      subtitle: Text(
        subtitleText,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
        ),
      ),
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
                Text(
                  '${value.toStringAsFixed(1)}°',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        Text(
          'Matches `*.thresholds_resolved` telemetry. Calibrated personal '
          'thresholds, when present, override these for the matched buckets.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }

  // ── Per-exercise factories ───────────────────────────────────────────────
  //
  // Co-located here so the widget owns the resolution logic. Each factory
  // returns the *resolved* tuple (sensitivity post-pass applied), not the
  // raw anchor — see file-level doc-block.

  static _RomDefaultsTile forCurl(FeedbackSensitivity sensitivity) {
    // Curl anchors are bilateral-symmetric today (`sideRightAnchor` aliases
    // `sideLeftAnchor`); picking sideRight is arbitrary but matches the most
    // recent diagnostic-session source.
    final t = RomThresholds.global(CurlCameraView.sideRight, sensitivity);
    return _RomDefaultsTile(
      sensitivity: sensitivity,
      subtitle: 'side view',
      rows: [
        ('Start', t.startAngle),
        ('Peak', t.peakAngle),
        ('Peak exit', t.peakExitAngle),
        ('End', t.endAngle),
      ],
    );
  }

  static _RomDefaultsTile forSquat(FeedbackSensitivity sensitivity) {
    final t = SquatRomThresholdSet.anchor.applySensitivity(sensitivity);
    return _RomDefaultsTile(
      sensitivity: sensitivity,
      rows: [
        ('Start', t.startAngle),
        ('Bottom', t.bottomAngle),
        ('End', t.endAngle),
      ],
    );
  }

  static _RomDefaultsTile forPushUp(FeedbackSensitivity sensitivity) {
    final t = PushUpRomThresholds.defaults.applySensitivity(sensitivity);
    return _RomDefaultsTile(
      sensitivity: sensitivity,
      rows: [
        ('Start', t.startAngle),
        ('Bottom', t.bottomAngle),
        ('Shallow rep max', t.shallowRepMaxAngle),
        ('End', t.endAngle),
      ],
    );
  }
}

/// "Sample Data" section on the Settings screen — a section header + the
/// Demo Mode `SwitchListTile`. Extracted from `_SettingsScreenState.build`
/// to keep the screen file scannable. The parent owns the demo state +
/// the toggle handler (which talks to `DemoService.enableAndSeed/disable`
/// with the Gap 33 confirmation dialog).
class _SampleDataSection extends StatelessWidget {
  const _SampleDataSection({
    required this.enabled,
    required this.busy,
    required this.onChanged,
  });

  /// Current `DemoService.isEnabled()` value (cached in parent state).
  final bool enabled;

  /// True while `enableAndSeed`/`disable` is in flight. Replaces the switch's
  /// trailing icon with a spinner and disables `onChanged` so the user can't
  /// double-tap mid-operation.
  final bool busy;

  /// Toggle handler. Called with the new value when the user taps the switch.
  /// Parent runs the Gap 33 confirmation dialog before delegating to
  /// `DemoService.enableAndSeed` for the enable direction.
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(
            'Sample Data',
            style: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Demo Mode'),
          subtitle: const Text(
            "Loads Demo Alex's profile + 14 sample workouts. "
            'Toggle off to remove sample data.',
          ),
          value: enabled,
          onChanged: busy ? null : onChanged,
          secondary: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
        ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool destructive;
  final VoidCallback onTap;

  const _ActionRow({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? Colors.redAccent : null;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

// ── Diagnostics ──────────────────────────────────────────────

class _DiagnosticsScreen extends StatefulWidget {
  const _DiagnosticsScreen();

  @override
  State<_DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<_DiagnosticsScreen> {
  static const int _maxShown = 100;

  void _copy() {
    // Copy ALL entries — no truncation. The display cap (_maxShown) is for
    // rendering only; the paste-back workflow needs the full ring buffer.
    final all = TelemetryLog.instance.entries;
    final text = all.map((e) => e.toString()).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied ${all.length} entries to clipboard')),
    );
  }

  Future<void> _share() async {
    // Gap 25: strip demo-tagged events from the SHARE output. The on-screen
    // list (in `build`) keeps showing everything so developers can still
    // see demo events locally — only the .txt + .json artifacts handed to
    // the system share sheet drop them.
    final all = TelemetryLog.instance.entries
        .where((e) => e.data?['is_demo'] != true)
        .toList()
        .reversed
        .toList();
    if (all.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No telemetry to export.')));
      return;
    }

    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-')
        .substring(0, 19);
    final dir = Directory.systemTemp;

    // .txt — one line per entry, chronological (oldest first), for Python paste
    final txtFile = File('${dir.path}/fitrack_telemetry_$stamp.txt');
    await txtFile.writeAsString(all.map((e) => e.toString()).join('\n'));

    // .json — array of objects, same chronological order
    final jsonList = all
        .map(
          (e) => {
            'timestamp': e.timestamp.toIso8601String(),
            'tag': e.tag,
            'message': e.message,
            if (e.data != null) 'data': e.data,
          },
        )
        .toList();
    final jsonFile = File('${dir.path}/fitrack_telemetry_$stamp.json');
    await jsonFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(jsonList),
    );

    await Share.shareXFiles([
      XFile(txtFile.path),
      XFile(jsonFile.path),
    ], subject: 'FiTrack telemetry $stamp');
  }

  void _clear() {
    TelemetryLog.instance.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final entries = TelemetryLog.instance.entries.take(_maxShown).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(icon: const Icon(Icons.copy), onPressed: _copy),
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Export as files',
            onPressed: _share,
          ),
          IconButton(icon: const Icon(Icons.delete_outline), onPressed: _clear),
        ],
      ),
      body: entries.isEmpty
          ? const Center(
              child: Text(
                'No telemetry yet.',
                style: TextStyle(color: Colors.white60),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(8),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final e = entries[i];
                return ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(
                    e.tag,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      color: Color(0xFF00E676),
                    ),
                  ),
                  subtitle: Text(
                    e.message,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                  trailing: Text(
                    '${e.timestamp.hour.toString().padLeft(2, '0')}:'
                    '${e.timestamp.minute.toString().padLeft(2, '0')}:'
                    '${e.timestamp.second.toString().padLeft(2, '0')}',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Colors.white54,
                    ),
                  ),
                );
              },
            ),
    );
  }
}
