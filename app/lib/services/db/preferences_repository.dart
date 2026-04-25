/// Key/value preferences repository backed by the `preferences` SQLite table
/// (schema v2, T5.3). Reusable for future toggles (TTS, haptics, units).
library;

import 'package:sqflite/sqflite.dart';

abstract class PreferencesRepository {
  /// Whether DTW reference-rep scoring is enabled. Defaults to false.
  Future<bool> getEnableDtwScoring();
  Future<void> setEnableDtwScoring(bool value);
}

class SqlitePreferencesRepository implements PreferencesRepository {
  SqlitePreferencesRepository(this._db);

  final Database _db;

  static const String _kDtwScoringKey = 'enable_dtw_scoring';

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
}

/// In-memory test double. No SQLite dependency.
class InMemoryPreferencesRepository implements PreferencesRepository {
  bool _enableDtwScoring = false;

  @override
  Future<bool> getEnableDtwScoring() async => _enableDtwScoring;

  @override
  Future<void> setEnableDtwScoring(bool value) async {
    _enableDtwScoring = value;
  }
}
