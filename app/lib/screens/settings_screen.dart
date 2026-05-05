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
import '../services/app_services.dart';
import '../services/db/profile_repository.dart';
import '../services/session_exporter.dart';
import '../services/telemetry_log.dart';
import 'workout_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late ProfileRepository _repository;
  bool _servicesResolved = false;
  CurlRomProfile? _profile;
  bool _loading = true;
  bool _showDetails = false;
  bool _dtwScoringEnabled = false;
  bool _squatLongFemurLifter = false;
  bool _diagnosticDisableAutoCalibration = false;
  bool _curlDebugSession = false;
  bool _squatDebugSession = false;
  ThemeMode _themeMode = ThemeMode.system;
  CurlSensitivity _curlSensitivity = CurlSensitivity.medium;
  SquatSensitivity _squatSensitivity = SquatSensitivity.medium;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_servicesResolved) {
      _repository = AppServicesScope.of(context).profileRepository;
      _servicesResolved = true;
      _reload();
    }
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final services = AppServicesScope.of(context);
    final p = await _repository.loadCurl();
    final dtw = await services.preferencesRepository.getEnableDtwScoring();
    final longFemur = await services.preferencesRepository
        .getSquatLongFemurLifter();
    final diagnosticDisableAutoCal = await services.preferencesRepository
        .getDiagnosticDisableAutoCalibration();
    final curlDebug = await services.preferencesRepository
        .getCurlDebugSession();
    final squatDebug = kSquatDebugSessionEnabled
        ? await services.preferencesRepository.getSquatDebugSession()
        : false;
    final themeMode = await services.preferencesRepository.getThemeMode();
    final curlSensitivity = await services.preferencesRepository
        .getCurlSensitivity();
    final squatSensitivity = await services.preferencesRepository
        .getSquatSensitivity();
    if (!mounted) return;
    setState(() {
      _profile = p;
      _dtwScoringEnabled = dtw;
      _squatLongFemurLifter = longFemur;
      _diagnosticDisableAutoCalibration = diagnosticDisableAutoCal;
      _curlDebugSession = curlDebug;
      _squatDebugSession = squatDebug;
      _themeMode = themeMode;
      _curlSensitivity = curlSensitivity;
      _squatSensitivity = squatSensitivity;
      _loading = false;
    });
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

  Future<void> _setDtwScoring(bool value) async {
    final prefs = AppServicesScope.read(context).preferencesRepository;
    await prefs.setEnableDtwScoring(value);
    TelemetryLog.instance.log(
      'preferences.dtw_scoring_toggled',
      'enabled=$value',
    );
    if (!mounted) return;
    setState(() => _dtwScoringEnabled = value);
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

  Future<void> _setCurlDebugSession(bool value) async {
    final prefs = AppServicesScope.read(context).preferencesRepository;
    await prefs.setCurlDebugSession(value);
    TelemetryLog.instance.log(
      'preferences.curl_debug_session_toggled',
      'enabled=$value',
    );
    if (!mounted) return;
    setState(() => _curlDebugSession = value);
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

  Future<void> _setCurlSensitivity(CurlSensitivity sensitivity) async {
    final prefs = AppServicesScope.read(context).preferencesRepository;
    await prefs.setCurlSensitivity(sensitivity);
    TelemetryLog.instance.log(
      'preferences.curl_sensitivity_changed',
      sensitivity.name,
    );
    if (!mounted) return;
    setState(() => _curlSensitivity = sensitivity);
  }

  Future<void> _setSquatSensitivity(SquatSensitivity sensitivity) async {
    final prefs = AppServicesScope.read(context).preferencesRepository;
    await prefs.setSquatSensitivity(sensitivity);
    TelemetryLog.instance.log(
      'preferences.squat_sensitivity_changed',
      sensitivity.name,
    );
    if (!mounted) return;
    setState(() => _squatSensitivity = sensitivity);
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
      await _repository.resetCurl();
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
              title: const Text('Side view'),
              subtitle: const Text('Turn sideways to the camera'),
              onTap: () => Navigator.pop(ctx, ExerciseType.bicepsCurlSide),
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

  /// Build sessions.csv + reps.csv in a temp dir, hand both to the system
  /// share sheet. Failures land in a SnackBar — no telemetry tag because
  /// share-sheet cancellation is a normal user flow, not an error.
  Future<void> _exportSessions() async {
    final repo = AppServicesScope.read(context).sessionRepository;
    final messenger = ScaffoldMessenger.of(context);
    final exporter = SessionExporter(repository: repo);
    try {
      final result = await exporter.exportToTempDir();
      if (result.sessionCount == 0) {
        if (!mounted) return;
        messenger.showSnackBar(
          const SnackBar(content: Text('No sessions to export yet.')),
        );
        return;
      }
      // share_plus 10.x legacy static API (`SharePlus.instance.share` lands
      // in 11+). XFile is provided by cross_file, re-exported by share_plus.
      await Share.shareXFiles(
        <XFile>[XFile(result.sessionsCsv), XFile(result.repsCsv)],
        subject: 'FiTrack workout export',
        text:
            'Exported ${result.sessionCount} sessions, '
            '${result.repCount} reps.',
      );
    } catch (e, st) {
      TelemetryLog.instance.log(
        'export.failed',
        e.toString(),
        data: <String, Object?>{'stackTrace': st.toString()},
      );
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _ProfileSection(
                  profile: _profile,
                  showDetails: _showDetails,
                  onToggleDetails: (v) => setState(() => _showDetails = v),
                ),
                const SizedBox(height: 24),
                _ActionRow(
                  icon: Icons.refresh,
                  label: 'Recalibrate',
                  subtitle: 'Re-record your full range of motion.',
                  onTap: _recalibrate,
                ),
                const Divider(),
                _ActionRow(
                  icon: Icons.delete_outline,
                  label: 'Reset Profile',
                  subtitle: 'Delete all calibrated buckets.',
                  destructive: true,
                  onTap: _confirmReset,
                ),
                const Divider(),
                _ActionRow(
                  icon: Icons.science_outlined,
                  label: 'Diagnostics',
                  subtitle: '${TelemetryLog.instance.length} telemetry entries',
                  onTap: _openDiagnostics,
                ),
                const Divider(),
                _ActionRow(
                  icon: Icons.ios_share,
                  label: 'Export sessions',
                  subtitle: 'Share sessions.csv + reps.csv',
                  onTap: _exportSessions,
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(
                    'Appearance',
                    style: TextStyle(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.54,
                      ),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
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
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Reference Rep Scoring (Beta)'),
                  subtitle: const Text(
                    'Compare your form against a textbook-correct rep.',
                  ),
                  value: _dtwScoringEnabled,
                  onChanged: _setDtwScoring,
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(
                    'Squat',
                    style: TextStyle(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.54,
                      ),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Tall lifter (relax lean threshold)'),
                  subtitle: const Text('Applies to next workout'),
                  value: _squatLongFemurLifter,
                  onChanged: _setSquatLongFemurLifter,
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(
                    'Biceps Curl',
                    style: TextStyle(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.54,
                      ),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text('Feedback sensitivity'),
                  subtitle: Text(
                    'How strict the form and rep-gate coaching is',
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SegmentedButton<CurlSensitivity>(
                    segments: [
                      for (final s in CurlSensitivity.values)
                        ButtonSegment(value: s, label: Text(s.label)),
                    ],
                    selected: {_curlSensitivity},
                    onSelectionChanged: (s) => _setCurlSensitivity(s.first),
                  ),
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(
                    'Squat',
                    style: TextStyle(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.54,
                      ),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text('Feedback sensitivity'),
                  subtitle: Text(
                    'How strict the form and rep-gate coaching is',
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SegmentedButton<SquatSensitivity>(
                    segments: [
                      for (final s in SquatSensitivity.values)
                        ButtonSegment(value: s, label: Text(s.label)),
                    ],
                    selected: {_squatSensitivity},
                    onSelectionChanged: (s) => _setSquatSensitivity(s.first),
                  ),
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(
                    'Diagnostics',
                    style: TextStyle(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.54,
                      ),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                    ),
                  ),
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
                if (kCurlDebugSessionEnabled)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Curl debug session'),
                    subtitle: const Text(
                      'Silent observation: no TTS / haptics / banners. '
                      'Logs frame-level pose metrics for threshold tuning. '
                      'Forces auto-calibration off. Turn on, run a session, '
                      'paste Diagnostics, turn off.',
                    ),
                    value: _curlDebugSession,
                    onChanged: _setCurlDebugSession,
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
    if (kCurlFrontViewEnabled) (ProfileSide.left, CurlCameraView.front),
    if (kCurlFrontViewEnabled) (ProfileSide.right, CurlCameraView.front),
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
    final all = TelemetryLog.instance.entries.toList().reversed.toList();
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
