/// Key/value preferences repository backed by the `preferences` SQLite table
/// (schema v2, T5.3). Reusable for future toggles (TTS, haptics, units).
library;

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/types.dart';
import '../../models/user_profile.dart' show Units;

abstract class PreferencesRepository {
  /// User-selected theme mode. Defaults to [ThemeMode.system].
  Future<ThemeMode> getThemeMode();
  Future<void> setThemeMode(ThemeMode mode);

  // ── Squat (Squat Master Rebuild, 2026-04-25) ──
  /// Last-used squat variant. Defaults to `SquatVariant.bodyweight` for
  /// first-ever squat sessions; subsequent taps pre-select whatever the
  /// user picked previously.
  Future<SquatVariant> getSquatVariant();
  Future<void> setSquatVariant(SquatVariant v);

  /// "Tall lifter (relax lean threshold)" toggle. When true, the active
  /// lean threshold is widened by `kSquatLongFemurLeanBoost` (+5°) for
  /// the next workout. Read at `WorkoutScreen.initState`; mid-session
  /// changes take effect on the *next* workout (snapshot-on-construction).
  Future<bool> getSquatLongFemurLifter();
  Future<void> setSquatLongFemurLifter(bool value);

  /// Diagnostic-only toggle. When true, the curl FSM forces every rep to
  /// run on `RomThresholds.global(view)` for the entire session — bypasses
  /// auto-calibration AND saved profile buckets. Used solely to collect
  /// clean per-rep extremes for default-threshold derivation. Has no
  /// effect on squat or push-up. Defaults to false.
  Future<bool> getDiagnosticDisableAutoCalibration();
  Future<void> setDiagnosticDisableAutoCalibration(bool value);

  /// Whether the next biceps curl session should run as a *debug session*
  /// — silent observation mode that suppresses user-facing feedback (TTS,
  /// haptics, banners), forces `source=global` for every rep, and emits a
  /// periodic `pose.frame_metrics` telemetry line so per-frame angle and
  /// landmark-confidence distributions are visible even when no rep
  /// commits. Read once at session start and frozen for the workout.
  /// Defaults to false. Has no effect when [kCurlDebugSessionEnabled] is
  /// compiled out.
  Future<bool> getCurlDebugSession();
  Future<void> setCurlDebugSession(bool value);

  /// Whether the next squat session should run as a *debug session* —
  /// silent observation mode, expanded ring buffer, per-frame metrics.
  /// Read once at session start; frozen for the workout.
  /// Defaults to false. No effect when [kSquatDebugSessionEnabled] is false.
  Future<bool> getSquatDebugSession();
  Future<void> setSquatDebugSession(bool value);

  /// Unified form/ROM coaching sensitivity for all exercises.
  /// Defaults to [FeedbackSensitivity.medium]. Affects only cold-start
  /// (`ThresholdSource.global`) reps — calibrated and auto-calibrated
  /// paths are personal and are never modified.
  Future<FeedbackSensitivity> getFeedbackSensitivity();
  Future<void> setFeedbackSensitivity(FeedbackSensitivity value);

  /// Display + input units. Defaults to [Units.metric] (cm, kg). Storage
  /// is always metric — this preference only affects formatting and form
  /// inputs in [EditProfileScreen]. Toggling units never mutates any saved
  /// height_cm / weight_kg values.
  Future<Units> getUnits();
  Future<void> setUnits(Units value);

  /// Whether spoken coaching cues (TTS) play during workouts. Defaults to
  /// `true`. Read at workout start and frozen for the session.
  Future<bool> getTtsEnabled();
  Future<void> setTtsEnabled(bool value);

  /// Whether haptic feedback fires on rep completion / form errors.
  /// Defaults to `true`. Read at workout start and frozen for the session.
  Future<bool> getHapticsEnabled();
  Future<void> setHapticsEnabled(bool value);
}

class SqlitePreferencesRepository implements PreferencesRepository {
  SqlitePreferencesRepository(this._db);

  final Database _db;

  static const String _kSquatVariantKey = 'squat_variant';
  static const String _kSquatLongFemurKey = 'squat_long_femur_lifter';
  static const String _kDiagnosticDisableAutoCalibrationKey =
      'diagnostic_disable_auto_calibration';
  static const String _kCurlDebugSessionKey = 'curl_debug_session';
  static const String _kSquatDebugSessionKey = 'squat_debug_session';
  static const String _kThemeModeKey = 'theme_mode';
  static const String _kFeedbackSensitivityKey = 'feedback_sensitivity';
  static const String _kUnitsKey = 'units';
  static const String _kTtsEnabledKey = 'tts_enabled';
  static const String _kHapticsEnabledKey = 'haptics_enabled';

  @override
  Future<SquatVariant> getSquatVariant() async {
    final rows = await _db.query(
      'preferences',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_kSquatVariantKey],
      limit: 1,
    );
    if (rows.isEmpty) return SquatVariant.bodyweight;
    final raw = rows.first['value'] as String?;
    if (raw == null) return SquatVariant.bodyweight;
    try {
      return SquatVariant.values.byName(raw);
    } catch (_) {
      // Unknown name (corrupt DB or downgraded enum) — safe default.
      return SquatVariant.bodyweight;
    }
  }

  @override
  Future<void> setSquatVariant(SquatVariant v) async {
    await _db.insert('preferences', {
      'key': _kSquatVariantKey,
      'value': v.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<bool> getSquatLongFemurLifter() async {
    final rows = await _db.query(
      'preferences',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_kSquatLongFemurKey],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    return rows.first['value'] == 'true';
  }

  @override
  Future<void> setSquatLongFemurLifter(bool value) async {
    await _db.insert('preferences', {
      'key': _kSquatLongFemurKey,
      'value': value.toString(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<bool> getDiagnosticDisableAutoCalibration() async {
    final rows = await _db.query(
      'preferences',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_kDiagnosticDisableAutoCalibrationKey],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    return rows.first['value'] == 'true';
  }

  @override
  Future<void> setDiagnosticDisableAutoCalibration(bool value) async {
    await _db.insert('preferences', {
      'key': _kDiagnosticDisableAutoCalibrationKey,
      'value': value.toString(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<bool> getCurlDebugSession() async {
    final rows = await _db.query(
      'preferences',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_kCurlDebugSessionKey],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    return rows.first['value'] == 'true';
  }

  @override
  Future<void> setCurlDebugSession(bool value) async {
    await _db.insert('preferences', {
      'key': _kCurlDebugSessionKey,
      'value': value.toString(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<bool> getSquatDebugSession() async {
    final rows = await _db.query(
      'preferences',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_kSquatDebugSessionKey],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    return rows.first['value'] == 'true';
  }

  @override
  Future<void> setSquatDebugSession(bool value) async {
    await _db.insert('preferences', {
      'key': _kSquatDebugSessionKey,
      'value': value.toString(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<FeedbackSensitivity> getFeedbackSensitivity() async {
    final rows = await _db.query(
      'preferences',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_kFeedbackSensitivityKey],
      limit: 1,
    );
    if (rows.isEmpty) return FeedbackSensitivity.medium;
    final raw = rows.first['value'] as String?;
    if (raw == null) return FeedbackSensitivity.medium;
    try {
      return FeedbackSensitivity.values.byName(raw);
    } catch (_) {
      return FeedbackSensitivity.medium;
    }
  }

  @override
  Future<void> setFeedbackSensitivity(FeedbackSensitivity value) async {
    await _db.insert('preferences', {
      'key': _kFeedbackSensitivityKey,
      'value': value.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<ThemeMode> getThemeMode() async {
    final rows = await _db.query(
      'preferences',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_kThemeModeKey],
      limit: 1,
    );
    if (rows.isEmpty) return ThemeMode.system;
    return _themeModeFromString(rows.first['value'] as String?);
  }

  @override
  Future<void> setThemeMode(ThemeMode mode) async {
    await _db.insert('preferences', {
      'key': _kThemeModeKey,
      'value': mode.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static ThemeMode _themeModeFromString(String? raw) => switch (raw) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  @override
  Future<Units> getUnits() async {
    final rows = await _db.query(
      'preferences',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_kUnitsKey],
      limit: 1,
    );
    if (rows.isEmpty) return Units.metric;
    final raw = rows.first['value'] as String?;
    if (raw == null) return Units.metric;
    try {
      return Units.values.byName(raw);
    } catch (_) {
      return Units.metric;
    }
  }

  @override
  Future<void> setUnits(Units value) async {
    await _db.insert('preferences', {
      'key': _kUnitsKey,
      'value': value.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<bool> getTtsEnabled() async {
    final rows = await _db.query(
      'preferences',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_kTtsEnabledKey],
      limit: 1,
    );
    if (rows.isEmpty) return true;
    return rows.first['value'] != 'false';
  }

  @override
  Future<void> setTtsEnabled(bool value) async {
    await _db.insert('preferences', {
      'key': _kTtsEnabledKey,
      'value': value.toString(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<bool> getHapticsEnabled() async {
    final rows = await _db.query(
      'preferences',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_kHapticsEnabledKey],
      limit: 1,
    );
    if (rows.isEmpty) return true;
    return rows.first['value'] != 'false';
  }

  @override
  Future<void> setHapticsEnabled(bool value) async {
    await _db.insert('preferences', {
      'key': _kHapticsEnabledKey,
      'value': value.toString(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

/// In-memory test double. No SQLite dependency.
class InMemoryPreferencesRepository implements PreferencesRepository {
  SquatVariant _squatVariant = SquatVariant.bodyweight;
  bool _squatLongFemur = false;
  bool _diagnosticDisableAutoCalibration = false;
  bool _curlDebugSession = false;
  bool _squatDebugSession = false;
  FeedbackSensitivity _feedbackSensitivity = FeedbackSensitivity.medium;
  ThemeMode _themeMode = ThemeMode.system;
  Units _units = Units.metric;
  bool _ttsEnabled = true;
  bool _hapticsEnabled = true;

  @override
  Future<SquatVariant> getSquatVariant() async => _squatVariant;

  @override
  Future<void> setSquatVariant(SquatVariant v) async {
    _squatVariant = v;
  }

  @override
  Future<bool> getSquatLongFemurLifter() async => _squatLongFemur;

  @override
  Future<void> setSquatLongFemurLifter(bool value) async {
    _squatLongFemur = value;
  }

  @override
  Future<bool> getDiagnosticDisableAutoCalibration() async =>
      _diagnosticDisableAutoCalibration;

  @override
  Future<void> setDiagnosticDisableAutoCalibration(bool value) async {
    _diagnosticDisableAutoCalibration = value;
  }

  @override
  Future<bool> getCurlDebugSession() async => _curlDebugSession;

  @override
  Future<void> setCurlDebugSession(bool value) async {
    _curlDebugSession = value;
  }

  @override
  Future<bool> getSquatDebugSession() async => _squatDebugSession;

  @override
  Future<void> setSquatDebugSession(bool value) async {
    _squatDebugSession = value;
  }

  @override
  Future<FeedbackSensitivity> getFeedbackSensitivity() async =>
      _feedbackSensitivity;

  @override
  Future<void> setFeedbackSensitivity(FeedbackSensitivity value) async {
    _feedbackSensitivity = value;
  }

  @override
  Future<ThemeMode> getThemeMode() async => _themeMode;

  @override
  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
  }

  @override
  Future<Units> getUnits() async => _units;

  @override
  Future<void> setUnits(Units value) async {
    _units = value;
  }

  @override
  Future<bool> getTtsEnabled() async => _ttsEnabled;

  @override
  Future<void> setTtsEnabled(bool value) async {
    _ttsEnabled = value;
  }

  @override
  Future<bool> getHapticsEnabled() async => _hapticsEnabled;

  @override
  Future<void> setHapticsEnabled(bool value) async {
    _hapticsEnabled = value;
  }
}
