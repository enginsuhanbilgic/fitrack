/// Root-level service bundle for FiTrack.
///
/// Holds the app-lifetime singletons that must be reachable from every screen
/// without a global MultiProvider: the single [DatabaseService] connection and
/// its repositories. Exposed via an [InheritedWidget] ([AppServicesScope]) so
/// descendants can resolve services via `AppServicesScope.of(context)`.
///
/// Created once in `FiTrackApp.initState` after the DB opens and the legacy
/// JSON migration runs. Disposed in `FiTrackApp.dispose`.
library;

import 'package:flutter/widgets.dart';

import 'db/database_service.dart';
import 'db/preferences_repository.dart';
import 'db/profile_repository.dart';
import 'db/session_repository.dart';

class AppServices {
  const AppServices({
    required this.databaseService,
    required this.profileRepository,
    required this.sessionRepository,
    required this.preferencesRepository,
  });

  final DatabaseService databaseService;
  final ProfileRepository profileRepository;
  final SessionRepository sessionRepository;
  final PreferencesRepository preferencesRepository;
}

class AppServicesScope extends InheritedWidget {
  const AppServicesScope({
    super.key,
    required this.services,
    required super.child,
  });

  final AppServices services;

  /// Resolve the ambient [AppServices]. Throws in debug if no scope is found —
  /// every screen reachable through `FiTrackApp` is under the scope, so a null
  /// here means the widget tree is being built outside the app (e.g. a test
  /// that forgot to wrap with a scope).
  static AppServices of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AppServicesScope>();
    assert(
      scope != null,
      'AppServicesScope not found. Wrap MaterialApp in FiTrackApp with it.',
    );
    return scope!.services;
  }

  /// Non-listening variant for one-shot reads (e.g. inside `onPressed`).
  static AppServices read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppServicesScope>();
    assert(
      scope != null,
      'AppServicesScope not found. Wrap MaterialApp in FiTrackApp with it.',
    );
    return scope!.services;
  }

  @override
  bool updateShouldNotify(AppServicesScope oldWidget) =>
      services != oldWidget.services;
}
