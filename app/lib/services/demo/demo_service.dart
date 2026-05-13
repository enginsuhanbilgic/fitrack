/// Demo Mode orchestrator — wipes + seeds + restores demo data.
///
/// All mutating ops use strict transaction ordering so a mid-operation
/// failure leaves a retryable state. See `enableAndSeed` and `disable`
/// step-comments for the exact ordering, and Gap 28 + Gap 33 in
/// `plans_of_claude/demo-mode-toggle.md` for the rationale.
///
/// Telemetry events fired by this service are tagged
/// `data: {'is_demo': true}` so future analytics pipelines can filter
/// them out of real user metrics (per Gap 9 + Gap 25).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/user_profile.dart';
import '../db/preferences_repository.dart';
import '../db/profile_repository.dart';
import '../db/session_repository.dart';
import '../db/user_profile_repository.dart';
import '../telemetry_log.dart';
import 'demo_seed.dart';

/// Cold-boot staleness threshold. The demo timeline's Day-N offsets are
/// computed at seed time relative to `DateTime.now()`. If the newest demo
/// session is older than this, `cleanReseedIfStale` re-seeds so "Day -1"
/// stays roughly yesterday from the user's perspective.
const Duration kDemoStalenessThreshold = Duration(hours: 36);

class DemoService {
  DemoService({
    required this.preferencesRepository,
    required this.sessionRepository,
    required this.userProfileRepository,
    required this.profileRepository,
  });

  final PreferencesRepository preferencesRepository;
  final SessionRepository sessionRepository;
  final UserProfileRepository userProfileRepository;
  final ProfileRepository profileRepository;

  /// Bumps every time `enableAndSeed` or `disable` completes. Surfaces are
  /// expected to listen and refresh their cached state — used by
  /// `_HomeScreenState` to reload `HomeViewModel` after first-launch demo
  /// onboarding so the dashboard doesn't flash empty → populated.
  ValueListenable<int> get revision => _revision;
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  /// Bump the [revision] listener from a caller outside this class. Used
  /// by surfaces that performed an action the dashboard should react to
  /// but isn't itself a demo enable/disable — e.g., the onboarding gate
  /// completing a "Start fresh" flow with a profile save. Closes the
  /// post-onboarding empty-hero bug (E17 in
  /// `docs/plan/2026-05-13-feat-start-fresh-auto-push-edit-profile-plan.md`).
  /// Cheap; no I/O.
  void notifyExternalRefresh() {
    _revision.value++;
  }

  /// True when Demo Mode is currently active.
  Future<bool> isEnabled() => preferencesRepository.getDemoModeEnabled();

  /// True after the user has answered the first-launch dialog. Once true,
  /// the dialog never reappears.
  Future<bool> hasOnboardingChoiceBeenMade() =>
      preferencesRepository.getOnboardingChoiceMade();

  /// Persist the user's first-launch choice. Sets
  /// `onboarding_choice_made = true` and (if `useDemoData`) runs
  /// `enableAndSeed()`.
  Future<void> recordOnboardingChoice({required bool useDemoData}) async {
    await preferencesRepository.setOnboardingChoiceMade(true);
    if (useDemoData) {
      await enableAndSeed();
    }
  }

  /// Wipe any existing demo rows, then insert the canonical seed.
  ///
  /// Strict step ordering (per Gap 28) — pref flips LAST so a failure in
  /// any earlier step leaves the pref at its prior value and the user
  /// can retry. If the user had a real profile saved, it's backed up to
  /// `user_profile_backup` in step 1 (per Gap 33) and restored by
  /// `disable()` step 3 Case A.
  Future<void> enableAndSeed() async {
    // Step 1: back up real user_profile row, if any.
    final existing = await userProfileRepository.load();
    if (existing != null && !await userProfileRepository.isDemoRow()) {
      final json = jsonEncode(_encodeProfile(existing));
      await preferencesRepository.setUserProfileBackup(json);
    }

    // Step 2: wipe demo sessions (cascades to reps + form_errors).
    await sessionRepository.deleteDemoSessions();

    // Step 3: defensively wipe any demo_* ROM profile rows. Current builds
    // never write them (operator decision: demo uses cold-start defaults),
    // but older builds did, so this clears stale state on upgrade-then-toggle.
    await profileRepository.deleteDemoProfiles();

    // Step 4: overwrite user_profile row with Demo Alex (is_demo=1).
    final blueprint = DemoSeed.build();
    await userProfileRepository.saveAsDemo(blueprint.userProfile);

    // Step 5: insert all 14 sessions + their per-rep + form-error rows.
    for (final session in blueprint.sessions) {
      await sessionRepository.insertSeededSession(
        sessionRow: session.sessionRow,
        repRows: session.repRows,
        formErrorRows: session.formErrorRows,
      );
    }

    // Step 6 (removed): no demo ROM profiles to seed. Workouts started
    // during Demo Mode use the cold-start `RomThresholds.global` path
    // exactly like a fresh user. The Settings ROM sections will read
    // "Not calibrated" and the Profile-tab badge stays uncalibrated.

    // Step 7: flip pref LAST. A failure before this leaves pref at false,
    // so retry is safe.
    await preferencesRepository.setDemoModeEnabled(true);

    TelemetryLog.instance.log(
      'demo.seeded',
      '${blueprint.sessions.length} sessions inserted',
      data: const <String, Object?>{'is_demo': true},
    );
    _revision.value++;
  }

  /// Wipe all demo-tagged rows and demo-keyspace profiles, restore the
  /// user's real profile from backup if any, flip pref OFF last.
  ///
  /// Strict step ordering (per Gap 28). User-edited demo rows (per Gap 34)
  /// survive because `EditProfileScreen._save()` calls `saveAsReal()`,
  /// promoting the row to `is_demo=0` — step 3 Case C leaves them alone.
  Future<void> disable() async {
    // Step 1: wipe demo sessions.
    await sessionRepository.deleteDemoSessions();

    // Step 2: wipe demo ROM profiles.
    await profileRepository.deleteDemoProfiles();

    // Step 3: reconcile user_profile row (per Gaps 33 + 34).
    final backupJson = await preferencesRepository.getUserProfileBackup();
    if (backupJson != null) {
      // Case A: restore the real profile that existed BEFORE demo was enabled.
      final decoded = jsonDecode(backupJson) as Map<String, dynamic>;
      await userProfileRepository.saveAsReal(_decodeProfile(decoded));
      await preferencesRepository.clearUserProfileBackup();
    } else if (await userProfileRepository.isDemoRow()) {
      // Case B: Demo Alex existed but the user never edited it → safe to clear.
      await userProfileRepository.clear();
    }
    // Case C: backup is null AND row is is_demo=0 → user promoted the row via
    // EditProfileScreen; leave it alone. Case D: no row exists at all → no-op.

    // Step 4: flip pref LAST.
    await preferencesRepository.setDemoModeEnabled(false);

    TelemetryLog.instance.log(
      'demo.disabled',
      'demo data wiped; pref off',
      data: const <String, Object?>{'is_demo': true},
    );
    _revision.value++;
  }

  /// Auto-reseed on cold boot when the demo timeline is stale. No-op if
  /// demo is OFF. Called from `_bootstrapServices()` in `app.dart` BEFORE
  /// any UI consumer reads the DB (per Gap 20 bootstrap ordering).
  Future<void> cleanReseedIfStale() async {
    if (!await isEnabled()) return;
    // Find the newest demo session's started_at. Uses `listSessions(limit: 1)`
    // with an in-Dart filter — adequate because demo seed always produces
    // newest-Day-(-1)-first, but more importantly this scans at most 100 rows
    // (one page). If a user has accumulated 100+ real sessions newer than every
    // demo row, the staleness check could under-detect; in that case demo
    // sessions are 21+ days old by definition (real sessions newer than the
    // newest demo Day-(-1)) so the reseed-iff-no-demo-row branch fires below.
    final sessions = await sessionRepository.listSessions(limit: 100);
    DateTime? newest;
    for (final s in sessions) {
      if (!s.isDemo) continue;
      if (newest == null || s.startedAt.isAfter(newest)) {
        newest = s.startedAt;
      }
    }
    final isStale =
        newest == null ||
        DateTime.now().difference(newest) > kDemoStalenessThreshold;
    if (isStale) {
      TelemetryLog.instance.log(
        'demo.reseed_stale',
        'newest=$newest threshold=$kDemoStalenessThreshold',
        data: const <String, Object?>{'is_demo': true},
      );
      await enableAndSeed();
    }
  }

  // ── UserProfile JSON helpers (backup/restore round-trip) ──

  static Map<String, Object?> _encodeProfile(UserProfile p) =>
      <String, Object?>{
        'displayName': p.displayName,
        'avatarEmoji': p.avatarEmoji,
        'age': p.age,
        'gender': p.gender?.name,
        'heightCm': p.heightCm,
        'weightKg': p.weightKg,
        'experience': p.experience?.name,
        'primaryGoal': p.primaryGoal?.name,
        'goalsJson': p.encodeGoals(),
        'createdAt': p.createdAt.millisecondsSinceEpoch,
        'updatedAt': p.updatedAt.millisecondsSinceEpoch,
      };

  static UserProfile _decodeProfile(Map<String, dynamic> j) => UserProfile(
    displayName: j['displayName'] as String,
    avatarEmoji: j['avatarEmoji'] as String?,
    age: (j['age'] as num?)?.toInt(),
    gender: _decodeEnum(j['gender'] as String?, Gender.values),
    heightCm: (j['heightCm'] as num?)?.toDouble(),
    weightKg: (j['weightKg'] as num?)?.toDouble(),
    experience: _decodeEnum(j['experience'] as String?, ExperienceLevel.values),
    primaryGoal: _decodeEnum(j['primaryGoal'] as String?, FitnessGoal.values),
    goals: UserProfile.decodeGoals(j['goalsJson'] as String?),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (j['createdAt'] as num).toInt(),
    ),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      (j['updatedAt'] as num).toInt(),
    ),
  );

  static T? _decodeEnum<T extends Enum>(String? raw, List<T> values) {
    if (raw == null) return null;
    for (final v in values) {
      if (v.name == raw) return v;
    }
    return null;
  }
}
