import 'package:flutter/material.dart';
import '../core/types.dart';
import '../engine/curl/curl_rom_profile.dart';
import '../services/rom_profile_store.dart';
import 'mlkit_test_screen.dart';
import 'settings_screen.dart';
import 'workout_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final RomProfileStore _profileStore = FileRomProfileStore();

  /// Hole #2 — gear-icon badge color (null = no badge).
  /// Red    → no buckets calibrated (cold start).
  /// Orange → at least one of the 4 main combos is missing.
  /// null   → all 4 main combos calibrated, no nudge needed.
  Color? _badgeColor;

  // The 4 main (side, view) combos we expect a fully-calibrated user to cover.
  static const List<(ProfileSide, CurlCameraView)> _expectedCombos = [
    (ProfileSide.left, CurlCameraView.front),
    (ProfileSide.right, CurlCameraView.front),
    (ProfileSide.left, CurlCameraView.sideLeft),
    (ProfileSide.right, CurlCameraView.sideRight),
  ];

  @override
  void initState() {
    super.initState();
    _refreshBadge();
  }

  Future<void> _refreshBadge() async {
    final p = await _profileStore.load();
    if (!mounted) return;
    setState(() => _badgeColor = _computeBadgeColor(p));
  }

  static Color? _computeBadgeColor(CurlRomProfile? profile) {
    if (profile == null || profile.buckets.isEmpty) return Colors.redAccent;
    final calibratedCount = _expectedCombos
        .where((c) => profile.isCalibrated(c.$1, c.$2))
        .length;
    if (calibratedCount == 0) return Colors.redAccent;
    if (calibratedCount < _expectedCombos.length) return Colors.orangeAccent;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FiTrack'),
        actions: [
          _GearWithBadge(
            badgeColor: _badgeColor,
            onTap: () async {
              await Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
              // Refresh badge in case the user calibrated/reset.
              _refreshBadge();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 32),
              const Text(
                'Choose Exercise',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Place your phone 2 m away and step back',
                style: TextStyle(color: Colors.white54),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),
              TextButton(
                onPressed: () => _launchMLKitTest(context),
                child: const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Text(
                    '🧪 ML Kit Test',
                    style: TextStyle(color: Colors.orange),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              _ExerciseCard(
                icon: Icons.fitness_center,
                title: ExerciseType.bicepsCurl.label,
                subtitle: 'Front camera · stand 2 m away, side profile',
                enabled: true,
                onTap: () => _startWorkout(ExerciseType.bicepsCurl),
              ),
              const SizedBox(height: 16),
              _ExerciseCard(
                icon: Icons.airline_seat_legroom_extra,
                title: ExerciseType.squat.label,
                subtitle: 'Front camera · stand 2 m away, full body visible',
                enabled: true,
                onTap: () => _startWorkout(ExerciseType.squat),
              ),
              const SizedBox(height: 16),
              _ExerciseCard(
                icon: Icons.sports_gymnastics,
                title: ExerciseType.pushUp.label,
                subtitle:
                    'Side camera · place phone at floor level, 1.5 m away',
                enabled: true,
                onTap: () => _startWorkout(ExerciseType.pushUp),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _startWorkout(ExerciseType exercise) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => WorkoutScreen(exercise: exercise)),
    );
    // Profile may have grown via auto-cal during the session.
    _refreshBadge();
  }

  void _launchMLKitTest(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const MLKitTestScreen()));
  }
}

/// Gear icon with an optional colored dot in the upper-right.
class _GearWithBadge extends StatelessWidget {
  final Color? badgeColor;
  final VoidCallback onTap;

  const _GearWithBadge({required this.badgeColor, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: badgeColor == null
              ? 'Settings'
              : (badgeColor == Colors.redAccent
                    ? 'Settings — calibration recommended'
                    : 'Settings — some views uncalibrated'),
          onPressed: onTap,
        ),
        if (badgeColor != null)
          Positioned(
            right: 8,
            top: 8,
            child: IgnorePointer(
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: badgeColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.black, width: 1.5),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ExerciseCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  const _ExerciseCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: Material(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Icon(icon, size: 36, color: const Color(0xFF00E676)),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                if (enabled)
                  const Icon(Icons.chevron_right, color: Colors.white38),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
