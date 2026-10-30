import 'flowstate_database.dart';

/// Selected appearance. Dark is the default and the app's designed look.
enum AppTheme { dark, light, system }

/// Which day a week starts on, used by habits and weekly insights.
enum WeekStart { monday, sunday }

class AppSettings {
  const AppSettings({
    this.theme = AppTheme.dark,
    this.weekStart = WeekStart.monday,
    this.dailyFocusGoalMinutes = 120,
  });

  final AppTheme theme;
  final WeekStart weekStart;
  final int dailyFocusGoalMinutes;

  AppSettings copyWith({
    AppTheme? theme,
    WeekStart? weekStart,
    int? dailyFocusGoalMinutes,
  }) => AppSettings(
    theme: theme ?? this.theme,
    weekStart: weekStart ?? this.weekStart,
    dailyFocusGoalMinutes: dailyFocusGoalMinutes ?? this.dailyFocusGoalMinutes,
  );
}

/// Persists preferences in the local key/value table.
class SettingsRepository {
  SettingsRepository(this._database);

  final FlowStateDatabase _database;

  static const themeKey = 'theme';
  static const weekStartKey = 'weekStart';
  static const dailyFocusGoalKey = 'dailyFocusGoalMinutes';

  static const minFocusGoalMinutes = 15;
  static const maxFocusGoalMinutes = 720;

  Stream<AppSettings> watch() =>
      _database.select(_database.preferences).watch().map(_decode);

  Future<AppSettings> load() async =>
      _decode(await _database.select(_database.preferences).get());

  Future<void> setTheme(AppTheme theme) => _write(themeKey, theme.name);

  Future<void> setWeekStart(WeekStart weekStart) =>
      _write(weekStartKey, weekStart.name);

  Future<void> setDailyFocusGoalMinutes(int minutes) => _write(
    dailyFocusGoalKey,
    minutes.clamp(minFocusGoalMinutes, maxFocusGoalMinutes).toString(),
  );

  Future<void> clear() => _database.delete(_database.preferences).go();

  Future<void> _write(String key, String value) => _database
      .into(_database.preferences)
      .insertOnConflictUpdate(
        PreferencesCompanion.insert(key: key, value: value),
      );

  AppSettings _decode(List<Preference> rows) {
    final values = {for (final row in rows) row.key: row.value};
    return AppSettings(
      theme: AppTheme.values.firstWhere(
        (theme) => theme.name == values[themeKey],
        orElse: () => AppTheme.dark,
      ),
      weekStart: WeekStart.values.firstWhere(
        (weekStart) => weekStart.name == values[weekStartKey],
        orElse: () => WeekStart.monday,
      ),
      dailyFocusGoalMinutes:
          (int.tryParse(values[dailyFocusGoalKey] ?? '') ??
                  const AppSettings().dailyFocusGoalMinutes)
              .clamp(minFocusGoalMinutes, maxFocusGoalMinutes),
    );
  }
}
