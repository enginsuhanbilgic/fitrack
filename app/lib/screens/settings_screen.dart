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
  bool _demoEnabled = false;
  bool _demoBusy = false;
  ThemeMode _themeMode = ThemeMode.system;
  FeedbackSensitivity _feedbackSensitivity = FeedbackSensitivity.medium;
  bool _ttsEnabled = true;
  TtsVerbosity _ttsVerbosity = TtsVerbosity.medium;
  bool _hapticsEnabled = true;

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
    final themeMode = await services.preferencesRepository.getThemeMode();
    final feedbackSensitivity = await services.preferencesRepository
        .getFeedbackSensitivity();
    final tts = await services.preferencesRepository.getTtsEnabled();
    final ttsVerbosity = await services.preferencesRepository.getTtsVerbosity();
    final haptics = await services.preferencesRepository.getHapticsEnabled();
    if (!mounted) return;
    setState(() {
      _profile = liveCurl;
      _pushUpProfile = livePushUp;
      _squatProfile = liveSquat;
      _squatLongFemurLifter = longFemur;
      _diagnosticDisableAutoCalibration = diagnosticDisableAutoCal;
      _squatDebugSession = squatDebug;
      _themeMode = themeMode;
      _feedbackSensitivity = feedbackSensitivity;
      _ttsEnabled = tts;
      _ttsVerbosity = ttsVerbosity;
      _hapticsEnabled = haptics;
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
      'preferences.diagnostic_disable_auto_cal_toggled',
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

  Future<void> _recalibrate() async {
    final surfaceColor = Theme.of(context).colorScheme.surface;
    final selected = await showModalBottomSheet<ExerciseType>(
      context: context,
      backgroundColor: surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                'Recalibrate — choose view',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            /* ListTile(
              leading: const Icon(Icons.face),
              title: const Text('Front view'),
              subtitle: const Text('Face the camera'),
              onTap: () => Navigator.pop(ctx, ExerciseType.bicepsCurlFront),
            ), */
            ListTile(
              leading: const Icon(Icons.rotate_90_degrees_ccw),
              title: const Text('Biceps curl side view'),
              subtitle: const Text('Stand sideways to the camera'),
              onTap: () => Navigator.pop(ctx, ExerciseType.bicepsCurlSide),
            ),
            ListTile(
              leading: const Icon(Icons.accessibility),
              title: const Text('Squat'),
              subtitle: const Text('Calibrate your full squat range of motion'),
              onTap: () => Navigator.pop(ctx, ExerciseType.squat),
            ),
            ListTile(
              leading: const Icon(Icons.accessibility_new),
              title: const Text('Push-up side view'),
              subtitle: const Text('Calibrate top and bottom push-up depth'),
              onTap: () => Navigator.pop(ctx, ExerciseType.pushUp),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) =>
            WorkoutScreen(exercise: selected, forceCalibration: true),
      ),
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
                _subSectionHeader(context, 'Biceps curl'),
                _ProfileSection(
                  profile: _profile,
                  showDetails: _showDetails,
                  onToggleDetails: (v) => setState(() => _showDetails = v),
                ),
                const SizedBox(height: 12),
                _ActionRow(
                  icon: Icons.refresh,
                  label: 'Recalibrate curl',
                  subtitle: 'Re-record your full range of motion.',
                  onTap: _recalibrate,
                ),
                _ActionRow(
                  icon: Icons.delete_outline,
                  label: 'Reset curl profile',
                  subtitle: 'Delete all calibrated buckets.',
                  destructive: true,
                  onTap: _confirmReset,
                ),
                const SizedBox(height: 12),
                _subSectionHeader(context, 'Squat'),
                _SquatProfileSection(profile: _squatProfile),
                _ActionRow(
                  icon: Icons.refresh,
                  label: 'Recalibrate squat',
                  subtitle:
                      'Record your full squat range of motion. Opt-in only — '
                      'never auto-launches.',
                  onTap: () => Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const WorkoutScreen(
                        exercise: ExerciseType.squat,
                        forceCalibration: true,
                      ),
                    ),
                  ),
                ),
                _ActionRow(
                  icon: Icons.delete_outline,
                  label: 'Reset squat profile',
                  subtitle:
                      'Delete your calibrated squat range — falls back to '
                      'default thresholds.',
                  destructive: true,
                  onTap: _confirmResetSquat,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Tall lifter (relax lean threshold)'),
                  subtitle: const Text('Applies to next workout'),
                  value: _squatLongFemurLifter,
                  onChanged: _setSquatLongFemurLifter,
                ),
                const SizedBox(height: 12),
                _subSectionHeader(context, 'Push-up'),
                _PushUpProfileSection(profile: _pushUpProfile),
                _ActionRow(
                  icon: Icons.refresh,
                  label: 'Recalibrate push-up',
                  subtitle: 'Record your top and bottom push-up angles.',
                  onTap: () => Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const WorkoutScreen(
                        exercise: ExerciseType.pushUp,
                        forceCalibration: true,
                      ),
                    ),
                  ),
                ),
                _ActionRow(
                  icon: Icons.delete_outline,
                  label: 'Reset push-up profile',
                  subtitle:
                      'Delete your calibrated push-up range — falls back to '
                      'default thresholds.',
                  destructive: true,
                  onTap: _confirmResetPushUp,
                ),
                const Divider(),

                // ── 2. Workout ─────────────────────────────────────────────
                _sectionHeader(context, 'Workout'),
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text('Coaching strictness'),
                  subtitle: Text(
                    'How strict the form and rep-gate coaching is',
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
                  title: const Text('Disable auto-calibration (curl)'),
                  subtitle: const Text(
                    'Forces every rep to use cold-start defaults. '
                    'For tuning data collection only — turn off after.',
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
              ],
            ),
    );
  }
}

/// Biceps-curl-only calibration card. Push-up used to share this card —
/// split out 2026-05-13 into [_PushUpProfileSection] so the Calibration
/// section's subheadings ("Biceps curl" / "Squat" / "Push-up") honestly
/// describe what lives under each.
class _ProfileSection extends StatelessWidget {
  final CurlRomProfile? profile;
  final bool showDetails;
  final ValueChanged<bool> onToggleDetails;

  const _ProfileSection({
    required this.profile,
    required this.showDetails,
    required this.onToggleDetails,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = profile;
    final summary = p == null ? null : ProfileSummary.of(p);
    final overallStatus = _overallStatus(summary, theme);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.fitness_center, color: Color(0xFF00E676)),
                const SizedBox(width: 8),
                const Text(
                  'Biceps Curl Profile',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                _StatusPill(label: overallStatus.$1, color: overallStatus.$2),
              ],
            ),
            const SizedBox(height: 12),
            if (p == null || p.buckets.isEmpty)
              Text(
                'Not calibrated. Start a workout to begin recording.',
                style: TextStyle(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.70),
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
      ),
    );
  }

  static List<(ProfileSide, CurlCameraView)> _allCombos() => const [
    (ProfileSide.left, CurlCameraView.sideLeft),
    (ProfileSide.right, CurlCameraView.sideRight),
  ];

  static (String, Color) _overallStatus(ProfileSummary? s, ThemeData theme) {
    if (s == null || s.totalBuckets == 0) {
      return (
        'Uncalibrated',
        theme.colorScheme.onSurface.withValues(alpha: 0.38),
      );
    }
    if (s.calibratedBuckets == 0) {
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

/// Squat-profile summary card. Mirrors the shape of `_ProfileSection`'s
/// push-up block but with squat-specific terminology — squat has no
/// `(side, view)` axis, so just one row of "Bottom · Top · ROM" plus a
/// diagnostics line with sample count + last-updated.
class _SquatProfileSection extends StatelessWidget {
  final squat_profile.SquatRomProfile? profile;

  const _SquatProfileSection({required this.profile});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = profile;
    final bucket = p?.bucket;
    final isCalibrated = p?.isCalibrated ?? false;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.accessibility, color: Color(0xFF00E676)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Squat Profile',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                _StatusPill(
                  label: isCalibrated ? 'Calibrated' : 'Uncalibrated',
                  color: isCalibrated
                      ? const Color(0xFF00E676)
                      : theme.colorScheme.onSurface.withValues(alpha: 0.38),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (bucket == null)
              Text(
                'Not calibrated. Use Recalibrate to record your deepest '
                'squat and standing extension.',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
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
              // Diagnostics line — sample count + last updated. Matches
              // the curl block's `_BucketRow` "N reps" / showDetails
              // exposure but lives inline because squat has only one
              // bucket so there's nothing to expand/collapse.
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
      ),
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

/// Push-up calibration card. Mirrors [_SquatProfileSection]'s single-bucket
/// shape (push-up profile has no per-side splits). Split out from
/// [_ProfileSection] 2026-05-13 so the "Push-up" subheading on the Settings
/// → Calibration screen actually corresponds to its own card.
class _PushUpProfileSection extends StatelessWidget {
  final PushUpRomProfile? profile;

  const _PushUpProfileSection({required this.profile});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = profile;
    final isCalibrated = p?.isCalibrated ?? false;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.accessibility_new, color: Color(0xFF00E676)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Push-up Profile',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                _StatusPill(
                  label: isCalibrated ? 'Calibrated' : 'Uncalibrated',
                  color: isCalibrated
                      ? const Color(0xFF00E676)
                      : theme.colorScheme.onSurface.withValues(alpha: 0.38),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (p == null)
              Text(
                'Not calibrated. Use Recalibrate to record your top and '
                'bottom push-up angles.',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
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
      ),
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
