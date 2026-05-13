import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'screens/edit_profile_screen.dart';
import 'screens/home_screen.dart';
import 'services/app_services.dart';
import 'services/db/database_service.dart';
import 'services/db/json_migrator.dart';
import 'services/db/preferences_repository.dart';
import 'services/db/profile_repository.dart';
import 'services/db/session_repository.dart';
import 'services/db/user_profile_repository.dart';
import 'services/demo/demo_service.dart';
import 'services/telemetry_log.dart';
import 'widgets/demo/first_launch_demo_dialog.dart';

/// Exposes the app-wide [ValueNotifier<ThemeMode>] to the widget tree.
/// Any screen can read the current mode or swap it without coupling to
/// [AppServicesScope] or requiring a Provider rebuild.
class ThemeModeScope extends InheritedWidget {
  const ThemeModeScope({
    super.key,
    required this.notifier,
    required super.child,
  });

  final ValueNotifier<ThemeMode> notifier;

  static ValueNotifier<ThemeMode> of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeModeScope>();
    assert(scope != null, 'ThemeModeScope not found in widget tree.');
    return scope!.notifier;
  }

  @override
  bool updateShouldNotify(ThemeModeScope old) => notifier != old.notifier;
}

class FiTrackApp extends StatefulWidget {
  const FiTrackApp({super.key});

  @override
  State<FiTrackApp> createState() => _FiTrackAppState();
}

class _FiTrackAppState extends State<FiTrackApp> {
  late final Future<AppServices> _servicesFuture;
  DatabaseService? _dbForDispose;
  final ValueNotifier<ThemeMode> _themeMode = ValueNotifier(ThemeMode.system);
  Object? _bootstrapError;
  StackTrace? _bootstrapStackTrace;

  @override
  void initState() {
    super.initState();
    _servicesFuture = _bootstrapServices();
  }

  Future<AppServices> _bootstrapServices() async {
    final db = SqfliteDatabaseService();
    _dbForDispose = db;
    try {
      final handle = await db.database();
      final docs = await db.docsDir();
      final migrator = JsonProfileMigrator(db: handle, docsDir: docs);
      final outcome = await migrator.migrateIfNeeded();
      TelemetryLog.instance.log(
        'app.bootstrap',
        'DB opened; migration outcome=${outcome.name}',
      );
      final prefs = SqlitePreferencesRepository(handle);
      final savedMode = await prefs.getThemeMode();
      _themeMode.value = savedMode;
      final sessionRepo = SqliteSessionRepository(handle);
      final profileRepo = SqliteProfileRepository(handle);
      final userProfileRepo = SqliteUserProfileRepository(handle);
      final demoService = DemoService(
        preferencesRepository: prefs,
        sessionRepository: sessionRepo,
        userProfileRepository: userProfileRepo,
        profileRepository: profileRepo,
      );
      // Gap 20 bootstrap ordering: auto-reseed BEFORE the FutureBuilder
      // resolves so the first HomeViewModel.load() sees fresh demo rows and
      // no badge-flash window exists.
      await demoService.cleanReseedIfStale();
      return AppServices(
        databaseService: db,
        profileRepository: profileRepo,
        sessionRepository: sessionRepo,
        preferencesRepository: prefs,
        userProfileRepository: userProfileRepo,
        demoService: demoService,
      );
    } catch (e, st) {
      // Bootstrap failure is recoverable: fall back to in-memory repos so the
      // app still launches. Persistence is disabled until next launch.
      setState(() {
        _bootstrapError = e;
        _bootstrapStackTrace = st;
      });
      TelemetryLog.instance.log(
        'app.bootstrap.failed',
        'DB bootstrap failed; falling back to in-memory repos. error=$e',
        data: <String, Object?>{'stackTrace': st.toString()},
      );
      final prefs = InMemoryPreferencesRepository();
      final sessionRepo = InMemorySessionRepository();
      final profileRepo = InMemoryProfileRepository();
      final userProfileRepo = InMemoryUserProfileRepository();
      // Gap 12: DemoService is constructed in the in-memory fallback too.
      // `enableAndSeed` is effectively a no-op against InMemorySessionRepository's
      // stub `insertSeededSession`, but `isEnabled`/`hasOnboardingChoiceBeenMade`
      // still work so the rest of the app behaves consistently.
      final demoService = DemoService(
        preferencesRepository: prefs,
        sessionRepository: sessionRepo,
        userProfileRepository: userProfileRepo,
        profileRepository: profileRepo,
      );
      return AppServices(
        databaseService: db,
        profileRepository: profileRepo,
        sessionRepository: sessionRepo,
        preferencesRepository: prefs,
        userProfileRepository: userProfileRepo,
        demoService: demoService,
      );
    }
  }

  @override
  void dispose() {
    _themeMode.dispose();
    _dbForDispose?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppServices>(
      future: _servicesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(backgroundColor: Colors.black),
          );
        }
        final services = snapshot.data!;
        return ThemeModeScope(
          notifier: _themeMode,
          child: AppServicesScope(
            services: services,
            child: ValueListenableBuilder<ThemeMode>(
              valueListenable: _themeMode,
              builder: (context, mode, child) => MaterialApp(
                title: 'FiTrack',
                debugShowCheckedModeBanner: false,
                theme: FiTrackTheme.light,
                darkTheme: FiTrackTheme.dark,
                themeMode: mode,
                builder: (context, child) {
                  if (_bootstrapError != null) {
                    return Material(
                      child: Column(
                        children: [
                          Expanded(child: child!),
                          Container(
                            color: Colors.red.shade900,
                            padding: const EdgeInsets.all(16),
                            child: SafeArea(
                              top: false,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'DATABASE ERROR (Persistence disabled)',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '$_bootstrapError',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return child!;
                },
                home: const _OnboardingGate(child: HomeScreen()),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Wraps the home screen and fires the first-launch Demo Mode dialog once,
/// after the first frame commits. Per Gap 20 bootstrap ordering this means
/// the dialog overlays a fully-populated dashboard (if the user chooses demo
/// later, the data appears after the chosen action; on first launch the
/// dashboard is empty until the user picks "Use demo data").
class _OnboardingGate extends StatefulWidget {
  const _OnboardingGate({required this.child});

  final Widget child;

  @override
  State<_OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends State<_OnboardingGate> {
  bool _checked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_checked) return;
    _checked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShow());
  }

  Future<void> _maybeShow() async {
    if (!mounted) return;
    final services = AppServicesScope.read(context);
    final demoService = services.demoService;
    if (await demoService.hasOnboardingChoiceBeenMade()) return;
    if (!mounted) return;
    final useDemo = await FirstLaunchDemoDialog.show(context);
    if (!mounted) return;
    await demoService.recordOnboardingChoice(useDemoData: useDemo);
    // Only tag `is_demo: true` when the user actually opted into demo data —
    // a "Start fresh" choice is a real onboarding event and must not be
    // filtered out of analytics by the demo-event guard (per Gap 9).
    TelemetryLog.instance.log(
      'demo.onboarding_choice',
      'useDemoData=$useDemo',
      data: useDemo ? const <String, Object?>{'is_demo': true} : null,
    );
    if (!mounted) return;
    // "Start fresh" path: auto-push EditProfileScreen so the user lands on
    // the personal-info form instead of an empty Dashboard. Only do this
    // when there's no profile row yet — covers fresh installs and pathological
    // "Start fresh" → re-launch states. The user can still dismiss without
    // saving; nothing forces them to fill in any field (only `displayName`
    // is required, and only at form-Save time). If they back out, the app
    // remains fully usable in its anonymous state.
    final hasProfile = await services.userProfileRepository.exists();
    if (hasProfile || useDemo) return;
    if (!mounted) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const EditProfileScreen()),
    );
    // Closes E17: HomeViewModel cached `userProfile = null` before the form
    // pushed; if the user saved a profile, the dashboard hero would still
    // read "Set up your profile" until the next navigation. Bumping the
    // demo-service revision signals `_HomeScreenState._onDemoRevisionChanged`
    // to reload HomeViewModel + History. Cheap; safe even on dismiss-without-
    // save (the reload is a no-op when the row is still null).
    if (!mounted) return;
    services.demoService.notifyExternalRefresh();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
