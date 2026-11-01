import 'flowstate_database.dart';

enum WeekStart { monday, sunday }

class AppSettings {
  const AppSettings({
    this.weekStart = WeekStart.monday,
    this.dailyFocusGoalMinutes = 120,
  });

  final WeekStart weekStart;
  final int dailyFocusGoalMinutes;

  AppSettings copyWith({WeekStart? weekStart, int? dailyFocusGoalMinutes}) =>
      AppSettings(
        weekStart: weekStart ?? this.weekStart,
        dailyFocusGoalMinutes:
            dailyFocusGoalMinutes ?? this.dailyFocusGoalMinutes,
      );
}

/// Stores small preferences in the local `preferences` table.
///
/// The app is dark-theme only for now (a real light theme needs the whole
/// design-token pass), so theme is deliberately not offered as a dead setting.
class SettingsRepository {
  SettingsRepository(this._database);

  static const weekStartKey = 'weekStart';
  static const dailyFocusGoalKey = 'dailyFocusGoalMinutes';
  static const minimumGoalMinutes = 15;
  static const maximumGoalMinutes = 720;

  final FlowStateDatabase _database;

  Stream<AppSettings> watch() =>
      _database.select(_database.preferences).watch().map(_fromRows);

  Future<AppSettings> load() async =>
      _fromRows(await _database.select(_database.preferences).get());

  Future<void> setWeekStart(WeekStart weekStart) =>
      _write(weekStartKey, weekStart.name);

  Future<void> setDailyFocusGoalMinutes(int minutes) => _write(
    dailyFocusGoalKey,
    minutes.clamp(minimumGoalMinutes, maximumGoalMinutes).toString(),
  );

  Future<void> _write(String key, String value) => _database
      .into(_database.preferences)
      .insertOnConflictUpdate(
        PreferencesCompanion.insert(key: key, value: value),
      );

  AppSettings _fromRows(List<Preference> rows) {
    final values = {for (final row in rows) row.key: row.value};
    final goal = int.tryParse(values[dailyFocusGoalKey] ?? '');
    return AppSettings(
      weekStart: WeekStart.values.firstWhere(
        (value) => value.name == values[weekStartKey],
        orElse: () => WeekStart.monday,
      ),
      dailyFocusGoalMinutes: (goal ?? 120).clamp(
        minimumGoalMinutes,
        maximumGoalMinutes,
      ),
    );
  }
}
