/// Local user profile data captured by [EditProfileScreen] and persisted by
/// [UserProfileRepository] (single-row SQLite table, schema v8).
///
/// Storage convention: heights in cm, weights in kg — always metric on disk.
/// The [Units] preference controls only display + input, never storage. This
/// guarantees no data drift when the user toggles units mid-app-life.
///
/// All demographic fields are nullable except [displayName] which is required
/// at save time (validated by the form). Anonymous users with no profile yet
/// are represented by the absence of a row, not a [UserProfile] with all-null
/// fields — see `UserProfileRepository.load` returning `null`.
library;

import 'dart:convert';

/// Self-reported gender. Used for future calorie/load estimates and simple
/// personalization. Never used as a gating constraint anywhere in the app.
enum Gender {
  male('Male'),
  female('Female'),
  preferNotToSay('Prefer not to say');

  final String label;
  const Gender(this.label);
}

/// Self-reported training experience. Drives default coaching strictness:
/// beginner → wider tolerances, advanced → tighter form expectations. The
/// existing [FeedbackSensitivity] preference still wins if explicitly set.
enum ExperienceLevel {
  beginner('Beginner'),
  intermediate('Intermediate'),
  advanced('Advanced');

  final String label;
  const ExperienceLevel(this.label);
}

/// Top-level training intent. Surfaces in onboarding (future) and on the
/// Profile tab as the headline goal. Editable via [EditProfileScreen].
enum FitnessGoal {
  buildMuscle('Build muscle'),
  loseFat('Lose fat'),
  improveForm('Improve form'),
  generalFitness('General fitness');

  final String label;
  const FitnessGoal(this.label);
}

/// Display + input units. Storage is always metric — see file-level doc.
enum Units {
  metric('Metric (cm, kg)'),
  imperial('Imperial (in, lb)');

  final String label;
  const Units(this.label);
}

/// A single user-defined goal shown in the Profile tab's "Active Goals" list.
/// Free-form so the user can write any objective; an optional [targetDate]
/// drives the progress chip ("12 days left").
class UserGoal {
  const UserGoal({
    required this.id,
    required this.title,
    required this.createdAt,
    this.detail,
    this.targetDate,
    this.completed = false,
  });

  /// Stable identifier — millisecond timestamp at creation time. Used for
  /// edit / delete operations from the goal-editor sheet.
  final int id;
  final String title;
  final String? detail;
  final DateTime createdAt;
  final DateTime? targetDate;
  final bool completed;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'detail': detail,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'targetDate': targetDate?.millisecondsSinceEpoch,
    'completed': completed,
  };

  factory UserGoal.fromJson(Map<String, Object?> j) => UserGoal(
    id: (j['id'] as num).toInt(),
    title: j['title'] as String,
    detail: j['detail'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (j['createdAt'] as num).toInt(),
    ),
    targetDate: j['targetDate'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((j['targetDate'] as num).toInt()),
    completed: (j['completed'] as bool?) ?? false,
  );

  UserGoal copyWith({
    String? title,
    String? detail,
    DateTime? targetDate,
    bool? completed,
  }) => UserGoal(
    id: id,
    title: title ?? this.title,
    detail: detail ?? this.detail,
    createdAt: createdAt,
    targetDate: targetDate ?? this.targetDate,
    completed: completed ?? this.completed,
  );
}

/// Immutable snapshot of the user's profile. Treat as a value type — never
/// mutate; always copy via [copyWith].
class UserProfile {
  const UserProfile({
    required this.displayName,
    required this.createdAt,
    required this.updatedAt,
    this.avatarEmoji,
    this.age,
    this.gender,
    this.heightCm,
    this.weightKg,
    this.experience,
    this.primaryGoal,
    this.goals = const <UserGoal>[],
  });

  /// Required at save time. Empty string is rejected by the form.
  final String displayName;

  /// Optional emoji rendered in the profile hero avatar. When null, the
  /// avatar shows initials derived from [displayName].
  final String? avatarEmoji;

  final int? age;
  final Gender? gender;

  /// Always cm. Convert at the UI boundary via `utils/units.dart`.
  final double? heightCm;

  /// Always kg. Convert at the UI boundary via `utils/units.dart`.
  final double? weightKg;

  final ExperienceLevel? experience;
  final FitnessGoal? primaryGoal;

  /// User-defined goals, ordered by creation time (newest first by convention
  /// in the editor sheet; we preserve whatever order the caller supplies).
  final List<UserGoal> goals;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// Two-character initials for the avatar fallback. "John Doe" → "JD";
  /// "Cher" → "C". Returns "?" if [displayName] is whitespace.
  String get initials {
    final parts = displayName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  UserProfile copyWith({
    String? displayName,
    String? avatarEmoji,
    bool clearAvatarEmoji = false,
    int? age,
    bool clearAge = false,
    Gender? gender,
    bool clearGender = false,
    double? heightCm,
    bool clearHeightCm = false,
    double? weightKg,
    bool clearWeightKg = false,
    ExperienceLevel? experience,
    bool clearExperience = false,
    FitnessGoal? primaryGoal,
    bool clearPrimaryGoal = false,
    List<UserGoal>? goals,
    DateTime? updatedAt,
  }) => UserProfile(
    displayName: displayName ?? this.displayName,
    avatarEmoji: clearAvatarEmoji ? null : (avatarEmoji ?? this.avatarEmoji),
    age: clearAge ? null : (age ?? this.age),
    gender: clearGender ? null : (gender ?? this.gender),
    heightCm: clearHeightCm ? null : (heightCm ?? this.heightCm),
    weightKg: clearWeightKg ? null : (weightKg ?? this.weightKg),
    experience: clearExperience ? null : (experience ?? this.experience),
    primaryGoal: clearPrimaryGoal ? null : (primaryGoal ?? this.primaryGoal),
    goals: goals ?? this.goals,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// Encode the goals list to a JSON string for the `goals_json` column.
  /// Returns "[]" for an empty list so the column is never NULL after first
  /// save — simplifies repository decoding.
  String encodeGoals() => jsonEncode(goals.map((g) => g.toJson()).toList());

  /// Decode a `goals_json` column value. Tolerates null + empty + corrupt
  /// inputs by returning an empty list (logged at the call site).
  static List<UserGoal> decodeGoals(String? raw) {
    if (raw == null || raw.isEmpty) return const <UserGoal>[];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => UserGoal.fromJson(e as Map<String, Object?>))
          .toList(growable: false);
    } catch (_) {
      return const <UserGoal>[];
    }
  }
}
