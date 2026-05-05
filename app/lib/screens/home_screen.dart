/// FiTrack Home — tabbed shell (Dashboard / Train / History / Profile).
///
/// The tab bar is the primary navigation surface, replacing the old
/// single-screen home layout. All workout-launch logic is unchanged.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../core/types.dart';
import '../engine/curl/curl_rom_profile.dart';
import '../services/app_services.dart';
import '../services/db/profile_repository.dart';
import '../services/db/session_dtos.dart';
import '../view_models/history_view_model.dart';
import '../view_models/home_view_model.dart';
import 'history_detail_loader.dart';
import 'mlkit_test_screen.dart';
import 'settings_screen.dart';
import 'workout_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Shell
// ─────────────────────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final PageController _pageController = PageController();
  int _tab = 0;

  late ProfileRepository _profileRepository;
  HomeViewModel? _homeVm;
  bool _servicesResolved = false;
  Color? _badgeColor;

  static const List<(ProfileSide, CurlCameraView)> _expectedCombos = [
    (ProfileSide.left, CurlCameraView.sideLeft),
    (ProfileSide.right, CurlCameraView.sideRight),
  ];

  @override
  void initState() {
    super.initState();
    _pageController.addListener(_onPageScrolled);
  }

  void _onPageScrolled() {
    final page = _pageController.page;
    if (page != null) {
      setState(() => _tab = page.round());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_servicesResolved) {
      final services = AppServicesScope.of(context);
      _profileRepository = services.profileRepository;
      _homeVm = HomeViewModel(repository: services.sessionRepository)..load();
      _servicesResolved = true;
      _refreshBadge();
    }
  }

  @override
  void dispose() {
    _pageController.removeListener(_onPageScrolled);
    _pageController.dispose();
    _homeVm?.dispose();
    super.dispose();
  }

  Future<void> _refreshBadge() async {
    final p = await _profileRepository.loadCurl();
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

  void _onTabTap(int index) {
    setState(() => _tab = index);
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeInOutCubic,
    );
  }

  void _onPageChanged(int index) {
    setState(() => _tab = index);
  }

  // Per-tab trailing action widgets shown in the shared top app bar.
  List<Widget> _tabActions() => [
    if (_tab == 0)
      _GearWithBadge(badgeColor: _badgeColor, onTap: _openSettings)
    else if (_tab == 2)
      IconButton(icon: const Icon(Icons.filter_list), onPressed: () {}),
  ];

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: ft.bg,
      appBar: AppBar(
        backgroundColor: ft.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        title: const _BrandWordmark(),
        actions: _tabActions(),
        iconTheme: IconThemeData(color: cs.onSurface),
      ),
      body: PageView(
        controller: _pageController,
        onPageChanged: _onPageChanged,
        // Clamping prevents elastic over-scroll past first/last tab
        physics: const ClampingScrollPhysics(),
        children: [
          if (_homeVm != null)
            _DashboardTab(
              homeVm: _homeVm!,
              badgeColor: _badgeColor,
              onNavigateToTrain: () => _onTabTap(1),
              onNavigateToHistory: () => _onTabTap(2),
              onStartWorkout: _startWorkout,
              onOpenSettings: _openSettings,
            )
          else
            const Center(child: CircularProgressIndicator()),
          _TrainTab(
            onStartWorkout: _startWorkout,
            onLaunchMLKitTest: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const MLKitTestScreen()),
            ),
          ),
          _HistoryTab(),
          _ProfileTab(badgeColor: _badgeColor, onOpenSettings: _openSettings),
        ],
      ),
      bottomNavigationBar: _FtNavBar(currentIndex: _tab, onTap: _onTabTap),
    );
  }

  Future<void> _startWorkout(
    ExerciseType exercise, {
    ExerciseSide curlSide = ExerciseSide.both,
  }) async {
    if (exercise == ExerciseType.squat) {
      final selected = await _showSquatVariantSheet();
      if (selected == null) return;
      if (!mounted) return;
      final prefs = AppServicesScope.read(context).preferencesRepository;
      await prefs.setSquatVariant(selected);
      if (!mounted) return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WorkoutScreen(exercise: exercise, curlSide: curlSide),
      ),
    );
    _refreshBadge();
  }

  Future<void> _openSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
    _refreshBadge();
  }

  Future<SquatVariant?> _showSquatVariantSheet() async {
    final prefs = AppServicesScope.read(context).preferencesRepository;
    final lastUsed = await prefs.getSquatVariant();
    if (!mounted) return null;
    return showModalBottomSheet<SquatVariant>(
      context: context,
      backgroundColor: FiTrackColors.of(context).surface2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _SquatVariantSheet(initial: lastUsed),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Navigation bar
// ─────────────────────────────────────────────────────────────────────────────

class _FtNavBar extends StatelessWidget {
  const _FtNavBar({required this.currentIndex, required this.onTap});

  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ft = FiTrackColors.of(context);
    return NavigationBar(
      selectedIndex: currentIndex,
      onDestinationSelected: onTap,
      animationDuration: const Duration(milliseconds: 320),
      backgroundColor: theme.colorScheme.surface.withValues(alpha: 0.95),
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      // Accent pill under active icon — tinted from the mode-correct accent
      indicatorColor: ft.accent.withAlpha(0x38),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.dashboard_outlined),
          selectedIcon: Icon(Icons.dashboard),
          label: 'Dashboard',
        ),
        NavigationDestination(
          icon: Icon(Icons.fitness_center_outlined),
          selectedIcon: Icon(Icons.fitness_center),
          label: 'Train',
        ),
        NavigationDestination(
          icon: Icon(Icons.history_outlined),
          selectedIcon: Icon(Icons.history),
          label: 'History',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: 'Profile',
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 0 — Dashboard
// ─────────────────────────────────────────────────────────────────────────────

class _DashboardTab extends StatelessWidget {
  const _DashboardTab({
    required this.homeVm,
    required this.badgeColor,
    required this.onNavigateToTrain,
    required this.onNavigateToHistory,
    required this.onStartWorkout,
    required this.onOpenSettings,
  });

  final HomeViewModel homeVm;
  final Color? badgeColor;
  final VoidCallback onNavigateToTrain;
  final VoidCallback onNavigateToHistory;
  final Future<void> Function(ExerciseType, {ExerciseSide curlSide})
  onStartWorkout;
  final Future<void> Function() onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<HomeViewModel>.value(
      value: homeVm,
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _DashGreeting(),
                const SizedBox(height: 16),
                _StrainCard(),
                const SizedBox(height: 12),
                _RecentExerciseCard(onTrack: onNavigateToTrain),
                const SizedBox(height: 12),
                _RecentActivityCard(onViewAll: onNavigateToHistory),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _BrandWordmark extends StatelessWidget {
  const _BrandWordmark();

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return Text(
      'FITRACK',
      style: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w900,
        fontStyle: FontStyle.italic,
        letterSpacing: -0.18,
        color: ft.accent,
      ),
    );
  }
}

class _DashGreeting extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    final now = DateTime.now();
    final day = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ][now.weekday - 1];
    final hour = now.hour.toString().padLeft(2, '0');
    final min = now.minute.toString().padLeft(2, '0');

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$day · $hour:$min',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.32,
              color: ft.cyan,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Ready to work.',
            style: TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.72,
              height: 1.05,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Track one exercise at a time.',
            style: TextStyle(fontSize: 14, color: ft.textDim, height: 1.55),
          ),
        ],
      ),
    );
  }
}

class _StrainCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return FtAccentCard(
      accentColor: ft.cyan,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'DAILY PROGRESS',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.32,
                      color: ft.textDim,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Strain · Recovery · Output',
                    style: TextStyle(fontSize: 12, color: ft.textMuted),
                  ),
                ],
              ),
              const FtChip(label: 'Placeholder', tone: FtChipTone.cyan),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Ring chart placeholder
              Container(
                width: 130,
                height: 130,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: ft.surface3, width: 12),
                ),
                child: Center(
                  child: Text(
                    '—',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: ft.textMuted,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _PlaceholderStatRow(label: 'Strain', ft: ft),
                    const SizedBox(height: 14),
                    _PlaceholderStatRow(label: 'Recovery', ft: ft),
                    const SizedBox(height: 14),
                    _PlaceholderStatRow(label: 'Output', ft: ft),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlaceholderStatRow extends StatelessWidget {
  const _PlaceholderStatRow({required this.label, required this.ft});

  final String label;
  final FiTrackColors ft;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: ft.textMuted)),
        Text(
          '—',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: ft.textMuted,
          ),
        ),
      ],
    );
  }
}

class _RecentExerciseCard extends StatelessWidget {
  const _RecentExerciseCard({required this.onTrack});

  final VoidCallback onTrack;

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return Consumer<HomeViewModel>(
      builder: (_, vm, _) {
        final session = vm.lastSession;
        final hasData = session != null;

        return Container(
          decoration: ftCardDecoration(context),
          clipBehavior: Clip.hardEdge,
          child: Stack(
            children: [
              // Subtle radial glow in corner
              Positioned(
                top: -40,
                right: -40,
                child: Container(
                  width: 200,
                  height: 200,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [Color(0x14C3F400), Colors.transparent],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'LAST EXERCISE',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.32,
                            color: ft.textDim,
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (hasData)
                          FtChip(
                            label: session.exercise.label,
                            tone: FtChipTone.cyan,
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (hasData)
                      Text(
                        session.exercise.label,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: ft.textPrimary,
                          letterSpacing: -0.4,
                        ),
                      )
                    else
                      Text(
                        'No exercise yet',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: ft.textMuted,
                          letterSpacing: -0.4,
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      hasData
                          ? '${session.totalReps} reps · ${session.totalSets} sets · ${_formatDuration(session.duration)}'
                          : '0 reps · 0 sets · 0 min',
                      style: TextStyle(fontSize: 13, color: ft.textDim),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: onTrack,
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('TRACK EXERCISE'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: onTrack,
                          child: const Text('LIBRARY'),
                        ),
                      ],
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

  static String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    if (hours > 0) return '${hours}h ${minutes}m';
    if (minutes > 0) return '${minutes}m';
    return '${d.inSeconds}s';
  }
}

class _RecentActivityCard extends StatelessWidget {
  const _RecentActivityCard({required this.onViewAll});

  final VoidCallback onViewAll;

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return Consumer<HomeViewModel>(
      builder: (_, vm, _) {
        final sessions = vm.allSessions;
        final hasData = sessions.isNotEmpty;

        return Container(
          padding: const EdgeInsets.all(18),
          decoration: ftCardDecoration(context),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'RECENT EXERCISES',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.32,
                      color: ft.textDim,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: onViewAll,
                    icon: const Icon(Icons.arrow_forward, size: 14),
                    label: const Text('View all'),
                    iconAlignment: IconAlignment.end,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (hasData)
                Column(
                  children: sessions.take(3).map((s) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            s.exercise.label,
                            style: TextStyle(
                              fontSize: 14,
                              color: ft.textPrimary,
                            ),
                          ),
                          Text(
                            '${s.totalReps} reps',
                            style: TextStyle(fontSize: 13, color: ft.textDim),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                )
              else
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.fitness_center, size: 40, color: ft.textMuted),
                      const SizedBox(height: 12),
                      Text(
                        'No exercises logged yet',
                        style: TextStyle(fontSize: 14, color: ft.textMuted),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Start tracking to see your recent activity here',
                        style: TextStyle(fontSize: 12, color: ft.textDim),
                        textAlign: TextAlign.center,
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

// ─────────────────────────────────────────────────────────────────────────────
// Tab 1 — Train (exercise selection)
// ─────────────────────────────────────────────────────────────────────────────

class _TrainTab extends StatelessWidget {
  const _TrainTab({
    required this.onStartWorkout,
    required this.onLaunchMLKitTest,
  });

  final Future<void> Function(ExerciseType, {ExerciseSide curlSide})
  onStartWorkout;
  final VoidCallback onLaunchMLKitTest;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Select Exercise',
                      style: TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.72,
                        height: 1.05,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Choose your next movement to begin tracking.',
                      style: TextStyle(
                        fontSize: 14,
                        color: FiTrackColors.of(context).textDim,
                        height: 1.55,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              _ExerciseCard(
                icon: Icons.fitness_center,
                title: 'Biceps Curl',
                subtitle: 'Side camera · stand 2 m away',
                onTap: () => _showCurlViewPicker(context),
              ),
              const SizedBox(height: 10),
              _ExerciseCard(
                icon: Icons.accessibility,
                title: ExerciseType.squat.label,
                subtitle: 'Side view · stand 2 m away at waist height',
                onTap: () => onStartWorkout(ExerciseType.squat),
              ),
              const SizedBox(height: 10),
              _ExerciseCard(
                icon: Icons.sports_gymnastics,
                title: ExerciseType.pushUp.label,
                subtitle:
                    'Side camera · place phone at floor level, 1.5 m away',
                onTap: () => onStartWorkout(ExerciseType.pushUp),
              ),
              if (kCurlDebugSessionEnabled) ...[
                const SizedBox(height: 10),
                _ExerciseCard(
                  icon: Icons.bug_report_outlined,
                  title: 'Curl Debug Session',
                  subtitle:
                      'Silent observation — logs frame metrics for tuning',
                  onTap: () => _showCurlDebugSidePicker(context),
                ),
              ],
            ]),
          ),
        ),
      ],
    );
  }

  Future<void> _showCurlViewPicker(BuildContext context) async {
    if (!context.mounted) return;
    final side = await _showSideFacingPicker(context);
    if (side == null) return;
    if (!context.mounted) return;
    // Defensive: a previous "Curl Debug Session" launch may have left the
    // pref enabled. Normal curl tile must always run with feedback ON, so
    // clear the flag before navigating. Cheap (single SQLite upsert) and
    // makes the two entry points unambiguous from the user's perspective.
    if (kCurlDebugSessionEnabled) {
      final prefs = AppServicesScope.read(context).preferencesRepository;
      await prefs.setCurlDebugSession(false);
      if (!context.mounted) return;
    }
    await onStartWorkout(ExerciseType.bicepsCurlSide, curlSide: side);
  }

  /// "Curl Debug Session" entry. Mirrors [_showCurlViewPicker] but flips
  /// the `curl_debug_session` preference to `true` before launching the
  /// workout so the view-model reads it during `init()`. The Settings
  /// switch reflects the flip — users can manually flip it back off after
  /// the session, or the next normal-curl launch will clear it.
  Future<void> _showCurlDebugSidePicker(BuildContext context) async {
    if (!context.mounted) return;
    final side = await _showSideFacingPicker(context);
    if (side == null) return;
    if (!context.mounted) return;
    final prefs = AppServicesScope.read(context).preferencesRepository;
    await prefs.setCurlDebugSession(true);
    if (!context.mounted) return;
    await onStartWorkout(ExerciseType.bicepsCurlSide, curlSide: side);
  }

  Future<ExerciseSide?> _showSideFacingPicker(BuildContext context) {
    return showModalBottomSheet<ExerciseSide>(
      context: context,
      backgroundColor: FiTrackColors.of(context).surface2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final ft = FiTrackColors.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Text(
                  'Which arm to track?',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(ctx).colorScheme.onSurface,
                  ),
                ),
              ),
              ListTile(
                leading: Icon(Icons.swipe_left, color: ft.accent),
                title: Text(
                  'Left',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.onSurface),
                ),
                subtitle: Text(
                  'Track your left arm',
                  style: TextStyle(color: ft.textMuted),
                ),
                // DO NOT "fix" this — the user's physical left arm appears on
                // the camera's right side due to front-camera mirroring, so
                // tracking the user's left arm requires `ExerciseSide.right`
                // (right-side-of-frame). Title/subtitle are user-frame
                // ("your left arm"); the enum is camera-frame. Reverted on
                // 2026-04-27 after a misguided "swap" broke the mapping.
                onTap: () => Navigator.pop(ctx, ExerciseSide.right),
              ),
              ListTile(
                leading: Icon(Icons.swipe_right, color: ft.accent),
                title: Text(
                  'Right',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.onSurface),
                ),
                subtitle: Text(
                  'Track your right arm',
                  style: TextStyle(color: ft.textMuted),
                ),
                // Same camera-mirroring rationale as the Left tile above.
                onTap: () => Navigator.pop(ctx, ExerciseSide.left),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

class _ExerciseCard extends StatelessWidget {
  const _ExerciseCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return Semantics(
      button: true,
      label: '$title. $subtitle',
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: ft.surface1,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: ft.stroke, width: 1),
            ),
            child: Row(
              children: [
                // Placeholder image block
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: ft.surface3,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: ft.stroke),
                  ),
                  child: Icon(icon, size: 32, color: ft.accent),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: ft.textMuted,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right, color: ft.textMuted, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 2 — History
// ─────────────────────────────────────────────────────────────────────────────

class _HistoryTab extends StatefulWidget {
  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab>
    with AutomaticKeepAliveClientMixin {
  HistoryViewModel? _vm;

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_vm == null) {
      final repo = AppServicesScope.of(context).sessionRepository;
      _vm = HistoryViewModel(repository: repo)..load();
    }
  }

  @override
  void dispose() {
    _vm?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final vm = _vm;
    if (vm == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ChangeNotifierProvider<HistoryViewModel>.value(
      value: vm,
      child: Consumer<HistoryViewModel>(
        builder: (_, vm, _) => CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'History',
                      style: TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.72,
                        color: Theme.of(context).colorScheme.onSurface,
                        height: 1.05,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${vm.sessions.length} sessions this month',
                      style: TextStyle(
                        fontSize: 14,
                        color: FiTrackColors.of(context).textDim,
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Weekly volume bar chart
                    _WeeklyVolumeCard(),
                    const SizedBox(height: 16),
                    Text(
                      'RECENT SESSIONS',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0,
                        color: FiTrackColors.of(context).textDim,
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            ),
            if (vm.loading && vm.sessions.isEmpty)
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (vm.error != null)
              SliverFillRemaining(
                child: _HistoryError(error: vm.error!, onRetry: vm.load),
              )
            else if (vm.sessions.isEmpty)
              const SliverFillRemaining(child: _HistoryEmpty())
            else
              _HistorySessionList(vm: vm),
            const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
          ],
        ),
      ),
    );
  }
}

class _WeeklyVolumeCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    const heights = [40.0, 65.0, 50.0, 80.0, 55.0, 90.0, 72.0];
    const days = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    // Saturday (index 5) is highlighted as today's peak.
    const todayIdx = 5;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: ftCardDecoration(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'WEEKLY VOLUME',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.0,
                      color: ft.textDim,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '42,180 lb',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -1.12,
                      color: Theme.of(context).colorScheme.onSurface,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
              const FtChip(label: '+8% wk', tone: FtChipTone.accent),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 64,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(7, (i) {
                final isToday = i == todayIdx;
                final barH = heights[i] * 0.64;
                return Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 400),
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        height: barH,
                        decoration: BoxDecoration(
                          color: isToday ? ft.accent : ft.surface5,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        days[i],
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: isToday ? ft.accent : ft.textMuted,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistorySessionList extends StatefulWidget {
  const _HistorySessionList({required this.vm});

  final HistoryViewModel vm;

  @override
  State<_HistorySessionList> createState() => _HistorySessionListState();
}

class _HistorySessionListState extends State<_HistorySessionList> {
  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final itemCount = vm.sessions.length + 1;

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate((context, i) {
          if (i == vm.sessions.length) {
            return _ListFooter(
              loadingMore: vm.loadingMore,
              hasMore: vm.hasMore,
            );
          }
          final s = vm.sessions[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Dismissible(
              key: ValueKey<int>(s.id),
              direction: DismissDirection.endToStart,
              background: const SizedBox.shrink(),
              secondaryBackground: _DeleteBg(),
              confirmDismiss: (_) => _confirmDelete(context),
              onDismissed: (_) => vm.deleteSession(s.id),
              child: _SessionRow(
                summary: s,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => HistoryDetailLoader(sessionId: s.id),
                  ),
                ),
              ),
            ),
          );
        }, childCount: itemCount),
      ),
    );
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final ft = FiTrackColors.of(ctx);
        return AlertDialog(
          backgroundColor: ft.surface2,
          title: Text(
            'Delete session?',
            style: TextStyle(color: Theme.of(ctx).colorScheme.onSurface),
          ),
          content: Text(
            'This permanently removes the session and all its reps. '
            'This cannot be undone.',
            style: TextStyle(color: ft.textDim),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: FiTrackTheme.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    return ok ?? false;
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.summary, required this.onTap});

  final SessionSummary summary;
  final VoidCallback onTap;

  String _relativeDate() {
    final diff = DateTime.now().difference(summary.startedAt);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    return '${diff.inDays} days ago';
  }

  String _fmtDuration() {
    final m = summary.duration.inMinutes;
    return '${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    final quality = summary.averageQuality;
    final hasQuality = quality != null;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: ftCardDecoration(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: ft.surface4,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.fitness_center,
                    size: 18,
                    color: ft.textPrimary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        summary.exercise.label,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface,
                          height: 1.2,
                        ),
                      ),
                      Text(
                        '${_relativeDate()} · ${_fmtDuration()}',
                        style: TextStyle(fontSize: 12, color: ft.textMuted),
                      ),
                    ],
                  ),
                ),
                if (summary.fatigueDetected || summary.asymmetryDetected)
                  const FtChip(label: 'Alert', tone: FtChipTone.accent),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Sparkline placeholder
                FtSparkline(
                  data: const [70, 80, 75, 90, 85, 95, 88, 92, 80, 85, 78, 82],
                  color: ft.cyan,
                  width: 120,
                  height: 28,
                ),
                Row(
                  children: [
                    if (hasQuality) ...[
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '${(quality * 100).toInt()}%',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.56,
                              color: ft.cyan,
                            ),
                          ),
                          Text(
                            'FORM',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.0,
                              color: ft.textMuted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 14),
                    ],
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${summary.totalReps}',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.56,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        Text(
                          'REPS',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.0,
                            color: ft.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DeleteBg extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: FiTrackTheme.red.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.delete_outline, color: Colors.white, size: 22),
          SizedBox(width: 8),
          Text(
            'Delete',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ListFooter extends StatelessWidget {
  const _ListFooter({required this.loadingMore, required this.hasMore});

  final bool loadingMore;
  final bool hasMore;

  @override
  Widget build(BuildContext context) {
    if (loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (!hasMore && true) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            'End of history',
            style: TextStyle(
              color: FiTrackColors.of(context).textMuted,
              fontSize: 12,
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

class _HistoryError extends StatelessWidget {
  const _HistoryError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: FiTrackTheme.red, size: 40),
            const SizedBox(height: 12),
            Text(
              "Couldn't load history.",
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '$error',
              style: TextStyle(color: ft.textMuted, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _HistoryEmpty extends StatelessWidget {
  const _HistoryEmpty();

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_edu, size: 48, color: ft.textMuted),
            const SizedBox(height: 12),
            Text(
              'No sessions yet — finish one to see it here.',
              style: TextStyle(color: ft.textDim, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 3 — Profile
// ─────────────────────────────────────────────────────────────────────────────

class _ProfileTab extends StatelessWidget {
  const _ProfileTab({required this.badgeColor, required this.onOpenSettings});

  final Color? badgeColor;
  final Future<void> Function() onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              // Profile hero
              Row(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: ft.surface3,
                      shape: BoxShape.circle,
                      border: Border.all(color: ft.stroke),
                    ),
                    child: Icon(Icons.person, size: 32, color: ft.accent),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Alex Chen',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.48,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Powerlifter · 12-day streak',
                          style: TextStyle(fontSize: 12, color: ft.textMuted),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.settings_outlined, color: ft.textMuted),
                    onPressed: onOpenSettings,
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Stats grid
              Row(
                children: [
                  const Expanded(
                    child: _ProfileStat(label: 'Sessions', value: '—'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ProfileStat(
                      label: 'PRs',
                      value: '—',
                      color: ft.accent,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: _ProfileStat(label: 'Hours', value: '—'),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Goals
              Text(
                'ACTIVE GOALS',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                  color: ft.textDim,
                ),
              ),
              const SizedBox(height: 10),
              _GoalCard(
                title: '315 lb Squat',
                progress: 0.81,
                detail: 'Current: 255 lb · 60 lb to go',
                color: ft.accent,
              ),
              const SizedBox(height: 8),
              _GoalCard(
                title: '30-day Streak',
                progress: 0.40,
                detail: 'Day 12 of 30',
                color: ft.cyan,
              ),
              const SizedBox(height: 16),

              // Settings shortcut
              Text(
                'SETTINGS',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                  color: ft.textDim,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                decoration: ftCardDecoration(context),
                clipBehavior: Clip.hardEdge,
                child: Column(
                  children: [
                    _SettingsRow(
                      icon: Icons.settings_outlined,
                      label: 'App Settings',
                      onTap: onOpenSettings,
                    ),
                    Divider(height: 1, color: ft.stroke),
                    _UnitsSelector(last: true),
                  ],
                ),
              ),

              if (badgeColor != null) ...[
                const SizedBox(height: 16),
                FtAccentCard(
                  accentColor: ft.accent,
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Icon(Icons.tune, color: badgeColor, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          badgeColor == Colors.redAccent
                              ? 'Calibration recommended — no biceps curl profile set yet.'
                              : 'Some curl views not calibrated yet.',
                          style: TextStyle(fontSize: 13, color: ft.textPrimary),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: onOpenSettings,
                        child: const Text('Settings'),
                      ),
                    ],
                  ),
                ),
              ],
            ]),
          ),
        ),
      ],
    );
  }
}

class _ProfileStat extends StatelessWidget {
  const _ProfileStat({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolvedColor = color ?? Theme.of(context).colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: ftCardDecoration(context),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.96,
              color: resolvedColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
              color: FiTrackColors.of(context).textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({
    required this.title,
    required this.progress,
    required this.detail,
    required this.color,
  });

  final String title;
  final double progress;
  final String detail;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: ftCardDecoration(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              Text(
                '${(progress * 100).toInt()}%',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.56,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              color: color,
              backgroundColor: FiTrackColors.of(context).surface4,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            style: TextStyle(
              fontSize: 12,
              color: FiTrackColors.of(context).textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _UnitsSelector extends StatefulWidget {
  const _UnitsSelector({this.last = false});

  final bool last;

  @override
  State<_UnitsSelector> createState() => _UnitsSelectorState();
}

class _UnitsSelectorState extends State<_UnitsSelector> {
  String _selectedUnit = 'lb';

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return InkWell(
      onTap: () => _showUnitsMenu(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: [
            Icon(Icons.straighten, size: 18, color: ft.textMuted),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Units',
                style: TextStyle(fontSize: 14, color: ft.textPrimary),
              ),
            ),
            Text(
              _selectedUnit,
              style: TextStyle(fontSize: 13, color: ft.textMuted),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 16, color: ft.textMuted),
          ],
        ),
      ),
    );
  }

  void _showUnitsMenu(BuildContext context) {
    final ft = FiTrackColors.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: ft.surface2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                'Select Units',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(ctx).colorScheme.onSurface,
                ),
              ),
            ),
            ListTile(
              leading: _selectedUnit == 'lb'
                  ? Icon(Icons.check, color: ft.accent)
                  : null,
              title: Text(
                'Pounds (lb)',
                style: TextStyle(color: Theme.of(ctx).colorScheme.onSurface),
              ),
              onTap: () {
                setState(() => _selectedUnit = 'lb');
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: _selectedUnit == 'kg'
                  ? Icon(Icons.check, color: ft.accent)
                  : null,
              title: Text(
                'Kilograms (kg)',
                style: TextStyle(color: Theme.of(ctx).colorScheme.onSurface),
              ),
              onTap: () {
                setState(() => _selectedUnit = 'kg');
                Navigator.pop(ctx);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 18, color: ft.textMuted),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: 14, color: ft.textPrimary),
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 16, color: ft.textMuted),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Gear badge (top-bar icon with calibration dot)
// ─────────────────────────────────────────────────────────────────────────────

class _GearWithBadge extends StatelessWidget {
  const _GearWithBadge({required this.badgeColor, required this.onTap});

  final Color? badgeColor;
  final Future<void> Function() onTap;

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
          onPressed: () async => await onTap(),
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
                  border: Border.all(
                    color: Theme.of(context).colorScheme.surface,
                    width: 1.5,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Squat variant sheet (unchanged logic, updated styling)
// ─────────────────────────────────────────────────────────────────────────────

class _SquatVariantSheet extends StatefulWidget {
  const _SquatVariantSheet({required this.initial});

  final SquatVariant initial;

  @override
  State<_SquatVariantSheet> createState() => _SquatVariantSheetState();
}

class _SquatVariantSheetState extends State<_SquatVariantSheet> {
  late SquatVariant _selected = widget.initial;

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Squat variant',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'The form rulebook adjusts the lean threshold to your variant.',
              style: TextStyle(color: ft.textDim, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: ft.accent.withAlpha(0x1F),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: ft.accent),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.videocam, color: ft.accent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Place your phone to the side — left or right — '
                      'at waist height (~1 m), 2 m away. '
                      'Do not face the camera directly.',
                      style: TextStyle(color: ft.textDim, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            for (final v in SquatVariant.values) ...[
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _selected == v ? ft.accent : ft.stroke,
                    width: _selected == v ? 2 : 1,
                  ),
                  color: _selected == v
                      ? ft.accent.withAlpha(0x1F)
                      : Colors.transparent,
                ),
                child: RadioListTile<SquatVariant>(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  title: Text(
                    v.label,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: _selected == v
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                  value: v,
                  // ignore: deprecated_member_use
                  groupValue: _selected,
                  // ignore: deprecated_member_use
                  onChanged: (next) {
                    if (next != null) setState(() => _selected = next);
                  },
                  activeColor: ft.accent,
                ),
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 4),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(_selected),
              child: const Text('START'),
            ),
          ],
        ),
      ),
    );
  }
}
