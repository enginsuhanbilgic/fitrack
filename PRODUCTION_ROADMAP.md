# FiTrack — Production Roadmap

> **Status:** Living document. Phase 1 shipped 2026-05-13 in the
> `we-will-refine-the-eager-fountain` plan. Subsequent phases are scoped
> here so the team has a clear forward path. Update the **Status** column
> at the top of each phase as work begins, lands, or is rescheduled.

This document captures the production-readiness work we've **deferred**
out of the local-profile pass so the app could ship a polished anonymous
experience without committing to a backend yet. Each phase is self-
contained and can be picked up independently.

---

## Phase 1 — Local profile + placeholder cleanup ✅

**Status:** Shipped 2026-05-13.

What landed:
- `UserProfile` model + `user_profile` SQLite table (schema v8).
- `EditProfileScreen` reachable from the Profile tab.
- Real Strain / Recovery / Output metrics on Dashboard (proxy formulas
  documented in `app/lib/utils/dashboard_aggregates.dart`).
- Real weekly-volume bar chart from session data.
- Functional History filter sheet (was a no-op `IconButton`).
- TTS / Haptics / Units preferences added to `PreferencesRepository`.
- All hardcoded "Alex Chen" / "315 lb Squat" placeholders replaced.

Reference plan: `plans_of_claude/we-will-refine-the-eager-fountain.md`

---

## Phase 2 — First-launch onboarding flow

**Status:** Partial — a minimal first-launch gate shipped early as the **Demo Mode** prompt (`plans_of_claude/demo-mode-toggle.md`, 2026-05-13). It asks the user "Try with sample data?" and persists the choice via `onboarding_choice_made`. A second small extension (`docs/plan/2026-05-13-feat-start-fresh-auto-push-edit-profile-plan.md`) auto-pushes `EditProfileScreen` on the "Start fresh" path so the user lands on the personal-info form instead of an empty Dashboard. The full onboarding walkthrough described below will REPLACE both pieces when it lands. The `onboarding_choice_made` pref will be migrated or re-used as the gate key. **Effort remaining:** ~1 week.

Today the app boots straight to the Dashboard with no profile. New users
see "Set up your profile" as a CTA, but a guided flow would convert
better and let us collect higher-quality demographic data upfront.

**Scope:**
1. Detect first launch (`PreferencesRepository.getOnboardingComplete()`,
   new key — defaults to false).
2. Insert an `OnboardingScreen` route ahead of `HomeScreen` in `app.dart`
   when the pref is false.
3. Steps (4–5 panels):
   - Welcome / brand intro.
   - Display name + avatar.
   - Demographics (age, gender, height, weight) — all optional, "Skip"
     button visible.
   - Fitness experience + primary goal.
   - Camera permission grant (if not already granted) + a 30-second
     "how it works" demo card.
4. Save via the existing `UserProfileRepository.save()`.
5. Set `setOnboardingComplete(true)` and `Navigator.pushReplacement` to
   `HomeScreen`.

**Dependencies:** none beyond what Phase 1 already shipped.

**Exit criteria:** Fresh install → onboarding → profile saved → home
shows real name. Re-installing skips onboarding only if the user
explicitly chose "Skip all" on every step.

---

## Phase 3 — Backend choice & schema design

**Status:** Not started. **Effort:** 1–2 weeks (mostly evaluation +
spike).

Before we add auth or sync, we need to pick the backend. The decision
should be documented in `.agent_brain/STATE.md` once locked.

**Candidates:**

| Option           | Pros                                               | Cons                                              |
|------------------|----------------------------------------------------|---------------------------------------------------|
| Firebase         | Fastest auth (Google + Apple OOB), Firestore for documents, free tier covers MVP. | Vendor lock-in; complex pricing past free tier.   |
| Supabase         | Postgres-native (joins, real SQL), open-source.    | Less mature mobile SDK; Apple Sign-In is custom.  |
| Custom (Node/Go) | Total control, no third-party data sharing.        | Significantly more ops work.                      |

**Recommendation:** Firebase for MVP — its mobile SDK + auth providers
match our timeline. Migrate to custom only if we hit pricing or
data-residency constraints.

**Schema sketch (Firestore):**
```
users/{uid}
  ├─ profile (mirror of UserProfile)
  ├─ preferences (mirror of PreferencesRepository keys)
  ├─ sessions/{sessionId}
  │   └─ reps/{repIndex}
  └─ profiles/curl_v1, profiles/push_up_v1 (ROM)
```

The on-device SQLite stays as-is — Firestore becomes a read-through cache
(write locally first, sync in background). This survives offline
workouts cleanly.

---

## Phase 4 — Authentication

**Status:** Blocked on Phase 3. **Effort:** ~2 weeks.

**Providers (in priority order):**
1. Sign in with Apple (App Store requirement on iOS if any 3rd-party
   provider is offered).
2. Google Sign-In.
3. Email + magic-link (no passwords).

**UX:**
- New `AuthGate` widget between bootstrap and `HomeScreen`. If no signed
  user, show `SignInScreen`.
- `SignInScreen` has a "Continue without account" button that routes to
  the existing local-only experience — preserves Phase 1's anonymous
  path. Local profile gets adopted (linked to the new uid) on
  subsequent sign-in.
- Drop the `CHECK (id = 1)` constraint on `user_profile` table; add a
  `user_id TEXT` column; backfill existing single rows with the new
  uid on first sign-in.

**Risk:** Account-linking edge cases (user signs in on a 2nd device with
existing local data on both — which "wins"?). Spec the merge policy
before coding.

---

## Phase 5 — Cloud sync

**Status:** Blocked on Phase 4. **Effort:** ~2 weeks.

- Background sync worker writes new sessions to Firestore on a debounced
  schedule (or immediately on Wi-Fi).
- Pull-down refresh on Dashboard / History triggers a manual sync.
- Conflict policy: server wins for profile fields, last-write-wins
  per-session (sessions are append-only and identified by start
  timestamp + device id, so collisions are rare).
- Provide an offline-mode banner when the device is disconnected.

**Tests required:** Airplane-mode workout → reconnect → sync → second
device sees the session within 30 s.

---

## Phase 6 — Photo avatar

**Status:** Not started. **Effort:** 2–3 days.

Today the avatar is initials or one of 10 emojis. To allow user photos
we need:
- `image_picker` dependency (camera + gallery).
- Image cropping (`image_cropper`).
- Storage permission handling on Android 13+ / iOS 14+.
- Upload + thumbnail in Firebase Storage (depends on Phase 4).

**Reason this is deferred:** the permission scope expansion is a non-
trivial UX and platform-permission story for what is (today) a low-value
feature. Initials/emojis cover 95% of the desire.

---

## Phase 7 — Data export & account deletion (GDPR)

**Status:** Not started. **Effort:** ~1 week.

Required if we launch in EU/UK or take payments anywhere.
- "Download my data" button → JSON export of profile + all sessions +
  all reps. Email link via Cloud Function or share-sheet.
- "Delete my account" button → confirmation → server-side cascade
  delete + local DB wipe.
- Add a "Last sign-in" + "Account created" row in Settings so users can
  see what we have on them.

---

## Cross-cutting follow-ups (any phase)

- **Real "Personal Records" system:** the Profile stat currently shows
  "distinct exercises trained" because we don't yet record PRs. A future
  `personal_records` table keyed by `(exercise, metric)` (e.g. squat
  max-depth, push-up max-set) would let us show a real PRs count and
  award badges.
- **Goals → progress wiring:** `UserGoal.completed` is a boolean today.
  Real goal progress requires linking goals to measurable metrics
  ("3 sessions per week" → check session count vs target). Spec the
  goal-to-metric mapping when we ship Phase 2 onboarding.
- **Strain / Recovery / Output validation:** the proxy formulas in
  `app/lib/utils/dashboard_aggregates.dart` are intentionally simple.
  Once we have real session telemetry from a few hundred users, retune
  the scaling constants.
