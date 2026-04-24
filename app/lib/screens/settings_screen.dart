/// User-facing controls for the per-user ROM profile.
///
/// Two responsibilities:
///   1. Show what's calibrated (per-bucket dot indicators + sample counts).
///   2. Provide three actions: Recalibrate, Reset Profile, Diagnostics.
///
/// "Show details" toggle reveals raw min/max angles per bucket — kept hidden
/// by default so the user isn't tempted to optimize the numbers themselves.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/types.dart';
import '../engine/curl/curl_rom_profile.dart';
import '../services/rom_profile_store.dart';
import '../services/telemetry_log.dart';
import 'workout_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final RomProfileStore _store = FileRomProfileStore();
  CurlRomProfile? _profile;
  bool _loading = true;
  bool _showDetails = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final p = await _store.load();
    if (!mounted) return;
    setState(() {
      _profile = p;
      _loading = false;
    });
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
      await _store.reset();
      await _reload();
    }
  }

  void _recalibrate() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => const WorkoutScreen(
          exercise: ExerciseType.bicepsCurl,
          forceCalibration: true,
        ),
      ),
    );
  }

  void _openDiagnostics() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const _DiagnosticsScreen()),
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
    final p = profile;
    final summary = p == null ? null : ProfileSummary.of(p);
    final overallStatus = _overallStatus(summary);

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
              const Text(
                'Not calibrated. Start a workout to begin recording.',
                style: TextStyle(color: Colors.white70),
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
    (ProfileSide.left, CurlCameraView.front),
    (ProfileSide.right, CurlCameraView.front),
    (ProfileSide.left, CurlCameraView.sideLeft),
    (ProfileSide.right, CurlCameraView.sideRight),
  ];

  static (String, Color) _overallStatus(ProfileSummary? s) {
    if (s == null || s.totalBuckets == 0) {
      return ('Uncalibrated', Colors.white38);
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
    final calibrated =
        bucket != null && bucket!.sampleCount >= kCalibrationMinReps;
    final dotColor = calibrated
        ? const Color(0xFF00E676)
        : (bucket == null ? Colors.white24 : Colors.orangeAccent);
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
                style: const TextStyle(color: Colors.white60, fontSize: 13),
              ),
            ],
          ),
          if (showDetails && bucket != null)
            Padding(
              padding: const EdgeInsets.only(left: 22, top: 4),
              child: Text(
                'Peak ${bucket!.observedMinAngle.toStringAsFixed(0)}° · '
                'Rest ${bucket!.observedMaxAngle.toStringAsFixed(0)}°',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
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
    final entries = TelemetryLog.instance.entries
        .take(_maxShown)
        .map((e) => e.toString())
        .join('\n');
    Clipboard.setData(ClipboardData(text: entries));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
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
