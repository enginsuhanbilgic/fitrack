/// Service-level tests for `DemoService`. Run against in-memory SQLite via
/// sqflite_ffi so we exercise the real schema, foreign-key cascades, and
/// transaction semantics — no test doubles.
///
/// Covers: enableAndSeed idempotence, disable wipes only demo rows,
/// real-session survival, Edit Profile flag preservation (ADR-8 / Gap 6),
/// cleanReseedIfStale 36-hour threshold, real-profile backup + restore
/// across enable/disable (Gap 33), edit-while-demo-on promotion (Gap 34).
library;

import 'package:fitrack/core/types.dart';
import 'package:fitrack/models/user_profile.dart';
import 'package:fitrack/services/db/preferences_repository.dart';
import 'package:fitrack/services/db/profile_repository.dart';
import 'package:fitrack/services/db/session_repository.dart';
import 'package:fitrack/services/db/user_profile_repository.dart';
import 'package:fitrack/services/demo/demo_service.dart';
import 'package:fitrack/view_models/workout_view_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../db/_test_db.dart';

void main() {
  setUpAll(initSqfliteFfi);

  late Database db;
  late DemoService demoService;
  late SqliteSessionRepository sessionRepo;
  late SqliteProfileRepository profileRepo;
  late SqliteUserProfileRepository userProfileRepo;
  late SqlitePreferencesRepository prefsRepo;

  setUp(() async {
    db = await openTestDb();
    sessionRepo = SqliteSessionRepository(db);
    profileRepo = SqliteProfileRepository(db);
    userProfileRepo = SqliteUserProfileRepository(db);
    prefsRepo = SqlitePreferencesRepository(db);
    demoService = DemoService(
      preferencesRepository: prefsRepo,
      sessionRepository: sessionRepo,
      userProfileRepository: userProfileRepo,
      profileRepository: profileRepo,
    );
  });

  tearDown(() async {
    await db.close();
  });

  group('enableAndSeed', () {
    test('inserts 14 sessions, all tagged is_demo=1', () async {
      await demoService.enableAndSeed();
      final rows = await db.query('sessions');
      expect(rows, hasLength(14));
      for (final r in rows) {
        expect(r['is_demo'], 1);
      }
    });

    test('flips demo_mode_enabled pref to true', () async {
      expect(await prefsRepo.getDemoModeEnabled(), isFalse);
      await demoService.enableAndSeed();
      expect(await prefsRepo.getDemoModeEnabled(), isTrue);
    });

    test('idempotent: second call still leaves 14 sessions', () async {
      await demoService.enableAndSeed();
      await demoService.enableAndSeed();
      final rows = await db.query('sessions');
      expect(rows, hasLength(14));
    });

    test('writes user_profile row as is_demo=1 (Demo Alex)', () async {
      await demoService.enableAndSeed();
      final profile = await userProfileRepo.load();
      expect(profile, isNotNull);
      expect(profile!.displayName, 'Demo Alex');
      expect(await userProfileRepo.isDemoRow(), isTrue);
    });

    test(
      'does NOT seed ROM profiles (operator decision: demo uses cold-start)',
      () async {
        await demoService.enableAndSeed();
        // No demo_* ROM profile rows are written — workouts started during
        // Demo Mode use the cold-start `RomThresholds.global` path.
        expect(await profileRepo.loadDemoCurl(), isNull);
        expect(await profileRepo.loadDemoSquat(), isNull);
        expect(await profileRepo.loadDemoPushUp(), isNull);
        // Live keyspace is untouched.
        expect(await profileRepo.loadCurl(), isNull);
        expect(await profileRepo.loadSquat(), isNull);
      },
    );
  });

  group('disable', () {
    test('removes all 14 demo sessions; pref flips false', () async {
      await demoService.enableAndSeed();
      await demoService.disable();
      final rows = await db.query('sessions');
      expect(rows, isEmpty);
      expect(await prefsRepo.getDemoModeEnabled(), isFalse);
    });

    test('preserves real (is_demo=0) sessions', () async {
      await demoService.enableAndSeed();
      await sessionRepo.insertCompletedSession(
        const WorkoutCompletedEvent(
          exercise: ExerciseType.bicepsCurlFront,
          totalReps: 1,
          totalSets: 1,
          sessionDuration: Duration(minutes: 1),
          averageQuality: 0.9,
          detectedView: CurlCameraView.unknown,
          repQualities: [0.9],
          fatigueDetected: false,
          asymmetryDetected: false,
          eccentricTooFastCount: 0,
          errorsTriggered: {},
          curlRepRecords: [],
          curlBucketSummaries: [],
        ),
        startedAt: DateTime.now(),
      );
      await demoService.disable();
      final rows = await db.query('sessions');
      expect(rows, hasLength(1));
      expect(rows.first['is_demo'], 0);
    });

    test(
      'defensively wipes any stray demo_* ROM rows + leaves live profiles alone',
      () async {
        // Pre-populate a live curl profile to ensure disable doesn't touch it.
        await db.insert('profiles', {
          'profile_key': SqliteProfileRepository.curlKey,
          'profile_json': '{"userId":"u","buckets":{},"schemaVersion":1}',
          'schema_version': 1,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        // Pre-populate a stray demo_* row as if it came from an older build
        // that seeded ROM profiles. Current builds never write these, but
        // `disable()` must wipe them on upgrade-and-toggle paths.
        await db.insert('profiles', {
          'profile_key': SqliteProfileRepository.demoCurlKey,
          'profile_json': '{"userId":"demo","buckets":{},"schemaVersion":1}',
          'schema_version': 1,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        await demoService.enableAndSeed();
        // enableAndSeed step 3 wipes demo_* rows defensively.
        expect(await profileRepo.loadDemoCurl(), isNull);

        await demoService.disable();
        // disable step 2 also wipes demo_* rows defensively.
        expect(await profileRepo.loadDemoCurl(), isNull);
        // Live curl row still present.
        final liveRows = await db.query(
          'profiles',
          where: 'profile_key = ?',
          whereArgs: [SqliteProfileRepository.curlKey],
        );
        expect(liveRows, hasLength(1));
      },
    );
  });

  group('user_profile backup/restore round-trip (Gap 33)', () {
    test('S2 → S8 → S2: real profile is restored after demo cycle', () async {
      // S2: real user with saved profile.
      final realProfile = UserProfile(
        displayName: 'Real Me',
        age: 35,
        heightCm: 180,
        weightKg: 75,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );
      await userProfileRepo.saveAsReal(realProfile);
      expect(await userProfileRepo.isDemoRow(), isFalse);

      // S2 → S8: enable demo → user_profile becomes Demo Alex.
      await demoService.enableAndSeed();
      final demoLoaded = await userProfileRepo.load();
      expect(demoLoaded!.displayName, 'Demo Alex');
      expect(await prefsRepo.getUserProfileBackup(), isNotNull);

      // S8 → S2: disable demo → real profile restored byte-for-byte.
      await demoService.disable();
      final restored = await userProfileRepo.load();
      expect(restored!.displayName, 'Real Me');
      expect(restored.age, 35);
      expect(restored.heightCm, 180);
      expect(restored.weightKg, 75);
      expect(await userProfileRepo.isDemoRow(), isFalse);
      expect(await prefsRepo.getUserProfileBackup(), isNull);
    });
  });

  group('Edit-while-demo-on promotion (Gap 34)', () {
    test('S7 → edit → disable leaves edited row alone (Case C)', () async {
      // S1 → S7: enable demo from anonymous state.
      await demoService.enableAndSeed();
      expect(await userProfileRepo.isDemoRow(), isTrue);

      // User opens Edit Profile and saves. EditProfileScreen._save calls
      // saveAsReal which promotes is_demo to 0.
      final edited = UserProfile(
        displayName: 'My Name',
        age: 30,
        createdAt: DateTime(2026, 5, 1),
        updatedAt: DateTime(2026, 5, 12),
      );
      await userProfileRepo.saveAsReal(edited);
      expect(await userProfileRepo.isDemoRow(), isFalse);

      // disable() Case C: backup is null AND row is_demo=0 → leave alone.
      await demoService.disable();
      final after = await userProfileRepo.load();
      expect(after, isNotNull);
      expect(after!.displayName, 'My Name');
      expect(after.age, 30);
    });
  });

  group('cleanReseedIfStale', () {
    test('no-op when demo is off', () async {
      await demoService.cleanReseedIfStale();
      expect(await prefsRepo.getDemoModeEnabled(), isFalse);
      final rows = await db.query('sessions');
      expect(rows, isEmpty);
    });

    test('reseeds when newest demo session is older than threshold', () async {
      await demoService.enableAndSeed();
      // Backdate every demo session by 40 hours so the newest is stale.
      final cutoff = DateTime.now()
          .subtract(const Duration(hours: 40))
          .millisecondsSinceEpoch;
      await db.update('sessions', {'started_at': cutoff}, where: 'is_demo = 1');
      await demoService.cleanReseedIfStale();
      // After reseed the newest started_at should be ~now (Day -1 from now).
      final rows = await db.rawQuery(
        'SELECT MAX(started_at) AS m FROM sessions WHERE is_demo = 1',
      );
      final newest = rows.first['m']! as int;
      final delta = DateTime.now().millisecondsSinceEpoch - newest;
      // Day -1 from now ≈ 24 h ago, well under 36 h.
      expect(delta, lessThan(const Duration(hours: 30).inMilliseconds));
    });

    test('does not reseed when demo timeline is fresh', () async {
      await demoService.enableAndSeed();
      final before = await db.rawQuery(
        'SELECT MAX(started_at) AS m FROM sessions WHERE is_demo = 1',
      );
      await demoService.cleanReseedIfStale();
      final after = await db.rawQuery(
        'SELECT MAX(started_at) AS m FROM sessions WHERE is_demo = 1',
      );
      // Newest timestamp unchanged — no reseed fired.
      expect(after.first['m'], before.first['m']);
    });
  });

  group('In-memory fallback (Gap 11 / plan §5)', () {
    test('enableAndSeed + disable + isEnabled toggle do not throw', () async {
      final inMemoryPrefs = InMemoryPreferencesRepository();
      final inMemorySessions = InMemorySessionRepository();
      final inMemoryUserProfile = InMemoryUserProfileRepository();
      final inMemoryProfile = InMemoryProfileRepository();
      final service = DemoService(
        preferencesRepository: inMemoryPrefs,
        sessionRepository: inMemorySessions,
        userProfileRepository: inMemoryUserProfile,
        profileRepository: inMemoryProfile,
      );
      // The in-memory `insertSeededSession` is a stub that returns a fake id,
      // so the seed insert chain completes without writing real rows. We only
      // assert that the orchestration doesn't NPE — full parity with SQLite
      // isn't required for this bootstrap-fallback path.
      expect(await service.isEnabled(), isFalse);
      await service.enableAndSeed();
      expect(await service.isEnabled(), isTrue);
      // Demo Alex written to in-memory user profile.
      expect(await inMemoryUserProfile.load(), isNotNull);
      expect(await inMemoryUserProfile.isDemoRow(), isTrue);
      // No demo ROM profile rows are written (operator decision).
      expect(await inMemoryProfile.loadDemoCurl(), isNull);
      expect(await inMemoryProfile.loadDemoSquat(), isNull);
      expect(await inMemoryProfile.loadDemoPushUp(), isNull);

      await service.disable();
      expect(await service.isEnabled(), isFalse);
      expect(await inMemoryUserProfile.load(), isNull);
      expect(await inMemoryProfile.loadDemoCurl(), isNull);
    });

    test('cleanReseedIfStale on in-memory repos no-ops cleanly', () async {
      final service = DemoService(
        preferencesRepository: InMemoryPreferencesRepository(),
        sessionRepository: InMemorySessionRepository(),
        userProfileRepository: InMemoryUserProfileRepository(),
        profileRepository: InMemoryProfileRepository(),
      );
      // Demo off → no-op.
      await service.cleanReseedIfStale();
      expect(await service.isEnabled(), isFalse);
    });
  });

  group('Onboarding choice', () {
    test('recordOnboardingChoice(useDemoData: true) seeds', () async {
      await demoService.recordOnboardingChoice(useDemoData: true);
      expect(await prefsRepo.getOnboardingChoiceMade(), isTrue);
      expect(await prefsRepo.getDemoModeEnabled(), isTrue);
      final rows = await db.query('sessions');
      expect(rows, hasLength(14));
    });

    test(
      'recordOnboardingChoice(useDemoData: false) leaves demo off',
      () async {
        await demoService.recordOnboardingChoice(useDemoData: false);
        expect(await prefsRepo.getOnboardingChoiceMade(), isTrue);
        expect(await prefsRepo.getDemoModeEnabled(), isFalse);
        final rows = await db.query('sessions');
        expect(rows, isEmpty);
      },
    );
  });
}
