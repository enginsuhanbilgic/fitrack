import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'screens/home_screen.dart';
import 'services/app_services.dart';
import 'services/db/database_service.dart';
import 'services/db/json_migrator.dart';
import 'services/db/profile_repository.dart';
import 'services/db/session_repository.dart';
import 'services/telemetry_log.dart';

class FiTrackApp extends StatefulWidget {
  const FiTrackApp({super.key});

  @override
  State<FiTrackApp> createState() => _FiTrackAppState();
}

class _FiTrackAppState extends State<FiTrackApp> {
  late final Future<AppServices> _servicesFuture;
  DatabaseService? _dbForDispose;

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
      return AppServices(
        databaseService: db,
        profileRepository: SqliteProfileRepository(handle),
        sessionRepository: SqliteSessionRepository(handle),
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
      );
    }
  }

  @override
  void dispose() {
    // Best-effort close — fire-and-forget, matches the VM's profile-flush
    // pattern. We don't block teardown on a DB I/O round-trip.
    _dbForDispose?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppServices>(
      future: _servicesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          // Black splash while the DB opens. <200ms on real devices; the
          // FiTrackTheme.dark background matches so there's no visual flash.
          return const MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(backgroundColor: Colors.black),
          );
        }
        final services = snapshot.data!;
        return AppServicesScope(
          services: services,
          child: MaterialApp(
            title: 'FiTrack',
            debugShowCheckedModeBanner: false,
            theme: FiTrackTheme.dark,
            home: const HomeScreen(),
          ),
        );
      },
    );
  }
}
