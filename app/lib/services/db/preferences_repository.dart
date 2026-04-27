/// Key/value preferences repository backed by the `preferences` SQLite table
/// (schema v2, T5.3). Reusable for future toggles (TTS, haptics, units).
library;

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/types.dart';

abstract class PreferencesRepository {
  /// Whether DTW reference-rep scoring is enabled. Defaults to false.
  Future<bool> getEnableDtwScoring();
  Future<void> setEnableDtwScoring(bool value);

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
}

class SqlitePreferencesRepository implements PreferencesRepository {
  SqlitePreferencesRepository(this._db);

  final Database _db;

  static const String _kDtwScoringKey = 'enable_dtw_scoring';
  static const String _kSquatVariantKey = 'squat_variant';
  static const String _kSquatLongFemurKey = 'squat_long_femur_lifter';
  static const String _kDiagnosticDisableAutoCalibrationKey =
      'diagnostic_disable_auto_calibration';
  static const String _kThemeModeKey = 'theme_mode';

  @override
  Future<bool> getEnableDtwScoring() async {
    final rows = await _db.query(
      'preferences',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_kDtwScoringKey],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    return rows.first['value'] == 'true';
  }

  @override
  Future<void> setEnableDtwScoring(bool value) async {
    await _db.insert('preferences', {
      'key': _kDtwScoringKey,
      'value': value.toString(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

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
}

/// In-memory test double. No SQLite dependency.
class InMemoryPreferencesRepository implements PreferencesRepository {
  bool _enableDtwScoring = false;
  SquatVariant _squatVariant = SquatVariant.bodyweight;
  bool _squatLongFemur = false;
  bool _diagnosticDisableAutoCalibration = false;
  ThemeMode _themeMode = ThemeMode.system;

  @override
  Future<bool> getEnableDtwScoring() async => _enableDtwScoring;

  @override
  Future<void> setEnableDtwScoring(bool value) async {
    _enableDtwScoring = value;
  }

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
  Future<ThemeMode> getThemeMode() async => _themeMode;

  @override
  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
  }
}
