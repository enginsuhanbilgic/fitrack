import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'screens/home_screen.dart';
import 'services/app_services.dart';
import 'services/db/database_service.dart';
import 'services/db/json_migrator.dart';
import 'services/db/preferences_repository.dart';
import 'services/db/profile_repository.dart';
import 'services/db/session_repository.dart';
import 'services/telemetry_log.dart';

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
      return AppServices(
        databaseService: db,
        profileRepository: SqliteProfileRepository(handle),
        sessionRepository: SqliteSessionRepository(handle),
        preferencesRepository: prefs,
      );
    } catch (e, st) {
      // Bootstrap failure is recoverable: fall back to in-memory repos so the
      // app still launches. Persistence is disabled until next launch.
      TelemetryLog.instance.log(
        'app.bootstrap.failed',
        'DB bootstrap failed; falling back to in-memory repos. error=$e',
        data: <String, Object?>{'stackTrace': st.toString()},
      );
      return AppServices(
        databaseService: db,
        profileRepository: InMemoryProfileRepository(),
        sessionRepository: InMemorySessionRepository(),
        preferencesRepository: InMemoryPreferencesRepository(),
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
                home: const HomeScreen(),
              ),
            ),
          ),
        );
      },
    );
  }
}
