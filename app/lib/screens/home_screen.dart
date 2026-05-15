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
import '../engine/squat/squat_rom_profile.dart'
    as squat_profile
    show SquatRomProfile;
import '../models/user_profile.dart';
import '../services/app_services.dart';
import '../services/db/profile_repository.dart';
import '../services/db/session_dtos.dart';
import '../services/demo/demo_service.dart';
import '../utils/dashboard_aggregates.dart';
import '../view_models/history_view_model.dart';
import '../view_models/home_view_model.dart';
import 'edit_profile_screen.dart';
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
  late DemoService _demoService;
  HomeViewModel? _homeVm;
  bool _servicesResolved = false;
  Color? _badgeColor;
  Color? _squatBadgeColor;
  // Keyed access to the History tab so the shell's app-bar filter button
  // can delegate filter-sheet wiring back into the tab's own VM.
  final GlobalKey<_HistoryTabState> _historyTabKey =
      GlobalKey<_HistoryTabState>();

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
      _demoService = services.demoService;
      _homeVm = HomeViewModel(
        repository: services.sessionRepository,
        userProfileRepository: services.userProfileRepository,
      )..load();
      // Listen for Demo Mode state changes so the dashboard refreshes after
      // first-launch onboarding chose "Use demo data" (VGV I3). The listener
      // also covers Settings-driven toggles, layered on top of the explicit
      // reload in `_openSettings`.
      _demoService.revision.addListener(_onDemoRevisionChanged);
      _servicesResolved = true;
      _refreshBadge();
    }
  }

  @override
  void dispose() {
    _pageController.removeListener(_onPageScrolled);
    _pageController.dispose();
    if (_servicesResolved) {
      _demoService.revision.removeListener(_onDemoRevisionChanged);
    }
    _homeVm?.dispose();
    super.dispose();
  }

  Future<void> _onDemoRevisionChanged() async {
    if (!mounted) return;
    await _refreshBadge();
    await _homeVm?.load();
    if (!mounted) return;
    await _historyTabKey.currentState?.reloadFromSettingsPop();
  }

  Future<void> _refreshBadge() async {
    // Demo Mode no longer seeds ROM profiles (operator decision, 2026-05-13
    // followup) — the badge reads only live profiles. A user toggling Demo
    // Mode on will see the uncalibrated badge stay uncalibrated, matching
    // the cold-start workout experience demo provides.
    final p = await _profileRepository.loadCurl();
    final sp = await _profileRepository.loadSquat();
    if (!mounted) return;
    setState(() {
      _badgeColor = _computeBadgeColor(p);
      _squatBadgeColor = _computeSquatBadgeColor(sp);
    });
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

  /// Squat badge color matches the curl model in spirit:
  ///   - red   = uncalibrated (no profile OR bucket below sample-count gate)
  ///   - orange = stale (calibrated, but last sample was >30 days ago)
  ///   - null  = calibrated and fresh (no badge rendered)
  ///
  /// Squat has only one bucket (no `(side, view)` axis), so there's no
  /// "partially calibrated" middle state — the orange tier is reserved
  /// for staleness instead.
  static Color? _computeSquatBadgeColor(squat_profile.SquatRomProfile? p) {
    if (p == null || !p.isCalibrated) return Colors.redAccent;
    final bucket = p.bucket;
    if (bucket == null) return Colors.redAccent;
    final ageDays = DateTime.now().difference(bucket.lastUpdated).inDays;
    if (ageDays > 30) return Colors.orangeAccent;
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
      IconButton(
        icon: const Icon(Icons.filter_list),
        onPressed: _openHistoryFilter,
        tooltip: 'Filter history',
      ),
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
      body: _homeVm == null
          ? const Center(child: CircularProgressIndicator())
          : ChangeNotifierProvider<HomeViewModel>.value(
              value: _homeVm!,
              child: PageView(
                controller: _pageController,
                onPageChanged: _onPageChanged,
                // Clamping prevents elastic over-scroll past first/last tab
                physics: const ClampingScrollPhysics(),
                children: [
                  _DashboardTab(
                    homeVm: _homeVm!,
                    badgeColor: _badgeColor,
                    onNavigateToTrain: () => _onTabTap(1),
                    onNavigateToHistory: () => _onTabTap(2),
                    onStartWorkout: _startWorkout,
                    onOpenSettings: _openSettings,
                  ),
                  _TrainTab(
                    squatBadgeColor: _squatBadgeColor,
                    onStartWorkout: _startWorkout,
                    onLaunchMLKitTest: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const MLKitTestScreen(),
                      ),
                    ),
                  ),
                  _HistoryTab(key: _historyTabKey),
                  _ProfileTab(
                    badgeColor: _badgeColor,
                    onOpenSettings: _openSettings,
                    onOpenEditProfile: _openEditProfile,
                  ),
                ],
              ),
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
    if (!mounted) return;
    // Gap 4: Settings may have toggled Demo Mode, which adds/removes 14
    // sessions, the user_profile row, and ROM profiles. A full reload of the
    // dashboard VM + invalidating the History tab's keep-alive cache is the
    // single canonical refresh path on return from Settings.
    _refreshBadge();
    await _homeVm?.load();
    if (!mounted) return;
    await _historyTabKey.currentState?.reloadFromSettingsPop();
  }

  /// Pushes [EditProfileScreen]; on Save (returns true) refreshes only the
  /// user-profile slice of the dashboard VM so the new name + avatar
  /// surface immediately without a full session re-fetch.
  Future<void> _openEditProfile() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const EditProfileScreen()),
    );
    if (saved == true) {
      await _homeVm?.refreshUserProfile();
    }
  }

  /// Opens the History filter bottom sheet, asks the user for an exercise
  /// filter (or "All"), and forwards the choice to the History tab's VM.
  /// Tab 2 mounts via a `GlobalKey` so we can poke its state imperatively
  /// from the shared shell app bar.
  Future<void> _openHistoryFilter() async {
    final tabState = _historyTabKey.currentState;
    final current = tabState?.currentFilter;
    final picked = await showModalBottomSheet<_HistoryFilterChoice?>(
      context: context,
      backgroundColor: FiTrackColors.of(context).surface2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _HistoryFilterSheet(initial: current),
    );
    if (picked == null) return;
    await tabState?.applyFilter(picked.exercise);
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
    return CustomScrollView(
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
    return Consumer<HomeViewModel>(
      builder: (_, vm, _) {
        final m = vm.metrics;
        // Strain ring uses 0..21 → 0..1 normalization for the ring fill.
        final strainPct = (m.strain / 21.0).clamp(0.0, 1.0);
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
                  IconButton(
                    icon: Icon(
                      Icons.info_outline,
                      size: 18,
                      color: ft.textMuted,
                    ),
                    onPressed: () => _showMetricsExplainer(context),
                    tooltip: 'How are these calculated?',
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _StrainRing(
                    progress: strainPct,
                    label: m.strain.toStringAsFixed(1),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _MetricStatRow(
                          label: 'Strain',
                          value: m.strain.toStringAsFixed(1),
                          ft: ft,
                        ),
                        const SizedBox(height: 14),
                        _MetricStatRow(
                          label: 'Recovery',
                          value: '${(m.recovery * 100).round()}%',
                          ft: ft,
                        ),
                        const SizedBox(height: 14),
                        _MetricStatRow(
                          label: 'Output',
                          value: '${(m.output * 100).round()}%',
                          ft: ft,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  static void _showMetricsExplainer(BuildContext context) {
    final ft = FiTrackColors.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: ft.surface2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'How these are calculated',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(ctx).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              _ExplainerRow(
                title: 'Strain',
                body:
                    'Sum of (reps × minutes) over the last 7 days, scaled to a 0–21 range.',
              ),
              _ExplainerRow(
                title: 'Recovery',
                body:
                    'Days since the last fatigue-flagged session, capped at 7 days = 100%.',
              ),
              _ExplainerRow(
                title: 'Output',
                body:
                    'Average rep-quality score across last-7-day sessions (0–100%).',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExplainerRow extends StatelessWidget {
  const _ExplainerRow({required this.title, required this.body});
  final String title;
  final String body;
  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: ft.accent,
            ),
          ),
          const SizedBox(height: 4),
          Text(body, style: TextStyle(fontSize: 13, color: ft.textPrimary)),
        ],
      ),
    );
  }
}

class _StrainRing extends StatelessWidget {
  const _StrainRing({required this.progress, required this.label});
  final double progress;
  final String label;
  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return SizedBox(
      width: 130,
      height: 130,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 130,
            height: 130,
            child: CircularProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              strokeWidth: 12,
              backgroundColor: ft.surface3,
              valueColor: AlwaysStoppedAnimation<Color>(ft.cyan),
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricStatRow extends StatelessWidget {
  const _MetricStatRow({
    required this.label,
    required this.value,
    required this.ft,
  });

  final String label;
  final String value;
  final FiTrackColors ft;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: ft.textMuted)),
        Text(
          value,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurface,
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
                          ? '${session.totalReps} reps · ${_formatDuration(session.duration)}'
                          : '0 reps · 0 min',
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
    this.squatBadgeColor,
  });

  final Future<void> Function(ExerciseType, {ExerciseSide curlSide})
  onStartWorkout;
  final VoidCallback onLaunchMLKitTest;

  /// Calibration state badge color for the squat tile. Red =
  /// uncalibrated, orange = stale (>30d since last sample), null =
  /// fresh and no badge rendered.
  final Color? squatBadgeColor;

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
                badgeColor: squatBadgeColor,
                onTap: () => _startNormalSquat(context),
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
              if (kSquatDebugSessionEnabled) ...[
                const SizedBox(height: 10),
                _ExerciseCard(
                  icon: Icons.bug_report_outlined,
                  title: 'Squat Debug Session',
                  subtitle:
                      'Silent observation — logs frame metrics for tuning',
                  onTap: () => _startSquatDebugSession(context),
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

  /// Normal squat entry. Defensively clears any stale `squat_debug_session`
  /// pref left over from a prior debug launch so a normal workout always
  /// runs with feedback ON. Squat is bilateral — no side picker.
  Future<void> _startNormalSquat(BuildContext context) async {
    if (!context.mounted) return;
    if (kSquatDebugSessionEnabled) {
      final prefs = AppServicesScope.read(context).preferencesRepository;
      await prefs.setSquatDebugSession(false);
      if (!context.mounted) return;
    }
    await onStartWorkout(ExerciseType.squat);
  }

  /// "Squat Debug Session" entry. Mirrors [_showCurlDebugSidePicker] but
  /// without a side picker since squat is a bilateral sagittal-plane
  /// movement. Flips the `squat_debug_session` preference to `true` so the
  /// view-model reads it during `init()` and forces tier 3 / source=global
  /// / silent observation mode for the session.
  Future<void> _startSquatDebugSession(BuildContext context) async {
    if (!context.mounted) return;
    final prefs = AppServicesScope.read(context).preferencesRepository;
    await prefs.setSquatDebugSession(true);
    if (!context.mounted) return;
    await onStartWorkout(ExerciseType.squat);
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
    this.badgeColor,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// Calibration-state dot rendered on the icon block. Red = uncalibrated,
  /// orange = stale, null = no badge.
  final Color? badgeColor;

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
                // Placeholder image block with optional calibration badge
                Stack(
                  clipBehavior: Clip.none,
                  children: [
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
                    if (badgeColor != null)
                      Positioned(
                        top: -2,
                        right: -2,
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: badgeColor,
                            shape: BoxShape.circle,
                            border: Border.all(color: ft.surface1, width: 2),
                          ),
                        ),
                      ),
                  ],
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
  const _HistoryTab({super.key});

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab>
    with AutomaticKeepAliveClientMixin {
  HistoryViewModel? _vm;

  @override
  bool get wantKeepAlive => true;

  /// Exposed to the shell so the app-bar filter sheet can pre-select the
  /// user's current filter. Null = "All exercises".
  ExerciseType? get currentFilter => _vm?.filter;

  /// Apply a filter chosen in the shell's app-bar bottom sheet.
  Future<void> applyFilter(ExerciseType? next) async {
    await _vm?.setFilter(next);
  }

  /// Public re-entry point used by the shell after Settings pops (Gap 4).
  /// Invalidates the keep-alive cache by re-running the same load the
  /// constructor's `didChangeDependencies` kicks off, so demo-toggle changes
  /// in Settings appear in the History list immediately.
  Future<void> reloadFromSettingsPop() async {
    await _vm?.load();
  }

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
    const days = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final todayIdx = DateTime.now().weekday - 1;

    return Consumer<HomeViewModel>(
      builder: (_, vm, _) {
        final bars = vm.metrics.weeklyBars;
        final maxBar = bars.isEmpty ? 1 : bars.reduce((a, b) => a > b ? a : b);
        final hasData = bars.any((v) => v > 0);

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
                        hasData
                            ? '${vm.metrics.weeklyRepCount} reps'
                            : 'No reps yet',
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
                  if (hasData)
                    FtChip(
                      label: '${vm.metrics.totalSessions} total',
                      tone: FtChipTone.accent,
                    ),
                ],
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 84,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: List.generate(7, (i) {
                    final isToday = i == todayIdx;
                    // Normalize the day's rep count to a 0..1 fraction of the
                    // week's tallest bar, then scale to the available 64-pixel
                    // height. Empty bars get a 4-pixel "stub" so the chart's
                    // weekday baseline reads visually even with no data.
                    final fraction = maxBar == 0 ? 0.0 : bars[i] / maxBar;
                    final barH = bars[i] == 0 ? 4.0 : (8.0 + fraction * 56.0);
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
      },
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
          final tile = _SessionRow(
            summary: s,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => HistoryDetailLoader(sessionId: s.id),
              ),
            ),
          );
          // Gap 24: demo rows render as plain non-dismissible tiles. The
          // canonical way to remove demo data is the Settings → Sample Data
          // toggle. Swipe-to-delete on a demo row would only get restored on
          // the next `cleanReseedIfStale` cold boot, creating an "I deleted
          // it but it came back" surprise.
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: s.isDemo
                ? tile
                : Dismissible(
                    key: ValueKey<int>(s.id),
                    direction: DismissDirection.endToStart,
                    background: const SizedBox.shrink(),
                    secondaryBackground: _DeleteBg(),
                    confirmDismiss: (_) => _confirmDelete(context),
                    onDismissed: (_) => vm.deleteSession(s.id),
                    child: tile,
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
                if (summary.isDemo)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: FtChip(label: 'DEMO', tone: FtChipTone.cyan),
                  ),
                if (summary.fatigueDetected || summary.asymmetryDetected)
                  const FtChip(label: 'Alert', tone: FtChipTone.accent),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Per-rep form-quality trajectory for this session. Pinned to
                // a fixed 0..1 scale so a flat-good session looks flat; an
                // empty list (pre-WP6 rows or quality-less sessions) draws a
                // flat baseline rather than an empty gap, keeping the row
                // layout stable.
                _RowSparkline(series: summary.qualitySeries, color: ft.cyan),
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

/// Per-row history sparkline. Renders [series] on a fixed `0..1` scale (the
/// engine's clamped form-quality range). **2026-05-13:** auto-rescales each
/// session to its own min/max instead of pinning to a fixed 0..1 axis, so the
/// line shows the within-session trajectory clearly even when all reps cluster
/// in a narrow band (e.g. 0.86..0.92). Tradeoff: cross-session comparison by
/// vertical position is no longer meaningful — each card's line is shape-only.
/// Empty / single-point series (legacy pre-WP6 sessions, or in-flight rows
/// mid-write) draw a muted flat baseline so the row layout doesn't jump.
class _RowSparkline extends StatelessWidget {
  const _RowSparkline({required this.series, required this.color});

  final List<double> series;
  final Color color;

  static const double _w = 120;
  static const double _h = 28;

  @override
  Widget build(BuildContext context) {
    // FtSparkline's painter needs >= 2 points to draw a path. For 0/1-point
    // series fall back to a faint flat baseline at the mid-height so the row
    // visually balances with the FORM/REPS column on the right.
    if (series.length < 2) {
      return SizedBox(
        width: _w,
        height: _h,
        child: Center(
          child: Container(
            height: 1.5,
            width: _w,
            color: FiTrackColors.of(context).textMuted.withValues(alpha: 0.35),
          ),
        ),
      );
    }
    // No min/maxOverride → FtSparkline auto-rescales to this series' own
    // min/max, maximizing vertical resolution for the shape of THIS session.
    return FtSparkline(data: series, color: color, width: _w, height: _h);
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
  const _ProfileTab({
    required this.badgeColor,
    required this.onOpenSettings,
    required this.onOpenEditProfile,
  });

  final Color? badgeColor;
  final Future<void> Function() onOpenSettings;
  final Future<void> Function() onOpenEditProfile;

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return Consumer<HomeViewModel>(
      builder: (_, vm, _) {
        final profile = vm.userProfile;
        final m = vm.metrics;
        final hasProfile = profile != null;

        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  // Profile hero
                  Row(
                    children: [
                      _ProfileAvatar(profile: profile),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              hasProfile
                                  ? profile.displayName
                                  : 'Set up your profile',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.48,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _heroSubtitle(profile, m),
                              style: TextStyle(
                                fontSize: 12,
                                color: ft.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.edit_outlined, color: ft.textMuted),
                        tooltip: 'Edit profile',
                        onPressed: onOpenEditProfile,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Stats grid — driven by computed dashboard aggregates.
                  Row(
                    children: [
                      Expanded(
                        child: _ProfileStat(
                          label: 'Sessions',
                          value: m.totalSessions.toString(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _ProfileStat(
                          label: 'Exercises',
                          value: m.personalRecords.toString(),
                          color: ft.accent,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _ProfileStat(
                          label: 'Hours',
                          value: m.totalHours.toStringAsFixed(1),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // First-time CTA when no profile saved yet.
                  if (!hasProfile) ...[
                    FtAccentCard(
                      accentColor: ft.accent,
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          Icon(
                            Icons.account_circle_outlined,
                            color: ft.accent,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              'Add your name and personal info so we can tailor your '
                              'training experience.',
                              style: TextStyle(fontSize: 13),
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: onOpenEditProfile,
                            child: const Text('Set up'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Active Goals section removed 2026-05-13 — surface was
                  // judged redundant with the Goals editor inside Edit
                  // Profile. The underlying `UserGoal` model, persistence,
                  // and editor remain intact.

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
                          icon: Icons.account_circle_outlined,
                          label: hasProfile ? 'Edit Profile' : 'Set up Profile',
                          onTap: onOpenEditProfile,
                        ),
                        Divider(height: 1, color: ft.stroke),
                        _SettingsRow(
                          icon: Icons.settings_outlined,
                          label: 'App Settings',
                          onTap: onOpenSettings,
                        ),
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
                              style: TextStyle(
                                fontSize: 13,
                                color: ft.textPrimary,
                              ),
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
      },
    );
  }

  /// Generate the small line under the user's name. Prefers their fitness
  /// goal + experience when both are set, falls back to a session count,
  /// and ends with a generic prompt for fresh installs.
  static String _heroSubtitle(UserProfile? p, DashboardMetrics m) {
    if (p == null) {
      return 'Add your details to personalize FiTrack.';
    }
    final parts = <String>[];
    if (p.experience != null) parts.add(p.experience!.label);
    if (p.primaryGoal != null) parts.add(p.primaryGoal!.label);
    if (parts.isEmpty) {
      if (m.totalSessions > 0) {
        parts.add(
          '${m.totalSessions} session${m.totalSessions == 1 ? '' : 's'} logged',
        );
      } else {
        parts.add('Ready when you are');
      }
    }
    return parts.join(' · ');
  }
}

/// Profile hero avatar — picks emoji > initials > generic icon based on
/// what the user has saved.
class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({required this.profile});
  final UserProfile? profile;

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        color: ft.surface3,
        shape: BoxShape.circle,
        border: Border.all(color: ft.stroke),
      ),
      alignment: Alignment.center,
      child: profile == null
          ? Icon(Icons.person, size: 32, color: ft.accent)
          : profile!.avatarEmoji != null
          ? Text(profile!.avatarEmoji!, style: const TextStyle(fontSize: 32))
          : Text(
              profile!.initials,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: ft.accent,
                letterSpacing: -0.5,
              ),
            ),
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

// _UnitsSelector + _UnitsSelectorState removed 2026-05-13 — home-screen
// units shortcut was redundant with the units control inside Edit Profile.
// The `Units` enum, `getUnits` / `setUnits` preferences API, and the
// EditProfileScreen control remain.

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

// ─────────────────────────────────────────────────────────────────────────────
// History filter — bottom sheet wired to _HistoryTabState.applyFilter
// ─────────────────────────────────────────────────────────────────────────────

/// Result returned from [_HistoryFilterSheet]. Wraps the chosen exercise
/// (null = "All exercises") so the sheet's pop value is unambiguous —
/// we can distinguish "user dismissed" (returns null at the showModalBottomSheet
/// level) from "user picked All" (returns a [_HistoryFilterChoice] with
/// `exercise == null`).
class _HistoryFilterChoice {
  const _HistoryFilterChoice(this.exercise);
  final ExerciseType? exercise;
}

class _HistoryFilterSheet extends StatelessWidget {
  const _HistoryFilterSheet({required this.initial});

  final ExerciseType? initial;

  /// Curl variants visible in History today. Skip the deprecated
  /// `bicepsCurlFront` and the legacy `bicepsCurl` enum members so the
  /// sheet only offers exercises the user can actually start.
  static const List<ExerciseType> _filterableExercises = <ExerciseType>[
    ExerciseType.bicepsCurlSide,
    ExerciseType.squat,
    ExerciseType.pushUp,
  ];

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Filter by exercise',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 14),
            _FilterTile(
              label: 'All exercises',
              selected: initial == null,
              onTap: () =>
                  Navigator.of(context).pop(const _HistoryFilterChoice(null)),
            ),
            for (final ex in _filterableExercises)
              _FilterTile(
                label: ex.label,
                selected: initial == ex,
                onTap: () =>
                    Navigator.of(context).pop(_HistoryFilterChoice(ex)),
              ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('Cancel', style: TextStyle(color: ft.textMuted)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterTile extends StatelessWidget {
  const _FilterTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 20,
              color: selected ? ft.accent : ft.textMuted,
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
