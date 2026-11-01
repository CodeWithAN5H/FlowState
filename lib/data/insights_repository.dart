import 'package:drift/drift.dart';

import 'flowstate_database.dart';
import 'habits_repository.dart';
import 'settings_repository.dart';

class DailyFocus {
  const DailyFocus({required this.date, required this.duration});

  final DateTime date;
  final Duration duration;
}

/// A snapshot computed only from rows that actually exist in the database.
class InsightsSnapshot {
  const InsightsSnapshot({
    required this.todayFocus,
    required this.weekFocus,
    required this.monthFocus,
    required this.todaySessions,
    required this.weekSessions,
    required this.monthSessions,
    required this.tasksCompletedToday,
    required this.tasksCompletedWeek,
    required this.tasksOpen,
    required this.activeHabits,
    required this.habitsDoneToday,
    required this.habitConsistency,
    required this.goalMinutes,
    required this.lastSevenDays,
  });

  final Duration todayFocus;
  final Duration weekFocus;
  final Duration monthFocus;
  final int todaySessions;
  final int weekSessions;
  final int monthSessions;
  final int tasksCompletedToday;
  final int tasksCompletedWeek;
  final int tasksOpen;
  final int activeHabits;
  final int habitsDoneToday;

  /// 0–1 across active habits over the elapsed days of the current week.
  final double habitConsistency;
  final int goalMinutes;
  final List<DailyFocus> lastSevenDays;

  bool get hasFocusActivity =>
      todayFocus > Duration.zero ||
      weekFocus > Duration.zero ||
      monthFocus > Duration.zero ||
      weekSessions > 0 ||
      monthSessions > 0;

  bool get hasTaskActivity => tasksCompletedWeek > 0 || tasksOpen > 0;

  bool get hasHabitActivity => activeHabits > 0;

  bool get isEmpty =>
      !hasFocusActivity && !hasTaskActivity && !hasHabitActivity;
}

class InsightsRepository {
  InsightsRepository(this._database);

  final FlowStateDatabase _database;

  Future<InsightsSnapshot> load({
    required AppSettings settings,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final today = dateOnly(at);
    final weekStart = startOfWeek(at, settings.weekStart);
    final monthStart = DateTime(at.year, at.month);
    final tomorrow = today.add(const Duration(days: 1));
    final weekEnd = weekStart.add(const Duration(days: 7));
    final monthEnd = DateTime(at.year, at.month + 1);

    final weekFocus = await _focusBetween(weekStart, weekEnd);
    final monthFocus = await _focusBetween(monthStart, monthEnd);
    final weekSessions = await _sessionsBetween(weekStart, weekEnd);
    final tasksWeek = await _tasksCompletedBetween(weekStart, weekEnd);
    final habitStats = await _habitStats(
      weekStart: weekStart,
      today: today,
      weekStartPreference: settings.weekStart,
    );

    return InsightsSnapshot(
      todayFocus: await _focusBetween(today, tomorrow),
      weekFocus: weekFocus,
      monthFocus: monthFocus,
      todaySessions: await _sessionsBetween(today, tomorrow),
      weekSessions: weekSessions,
      monthSessions: await _sessionsBetween(monthStart, monthEnd),
      tasksCompletedToday: await _tasksCompletedBetween(today, tomorrow),
      tasksCompletedWeek: tasksWeek,
      tasksOpen: await _openTasks(),
      activeHabits: habitStats.active,
      habitsDoneToday: habitStats.doneToday,
      habitConsistency: habitStats.consistency,
      goalMinutes: settings.dailyFocusGoalMinutes,
      lastSevenDays: await _lastSevenDays(today),
    );
  }

  Future<Duration> _focusBetween(DateTime start, DateTime end) async {
    final total = _database.focusSessions.durationMillis.sum();
    final row =
        await (_database.selectOnly(_database.focusSessions)
              ..addColumns([total])
              ..where(
                _database.focusSessions.status.equals('completed') &
                    _database.focusSessions.startedAt.isBiggerOrEqualValue(
                      start,
                    ) &
                    _database.focusSessions.startedAt.isSmallerThanValue(end),
              ))
            .getSingle();
    return Duration(milliseconds: row.read(total) ?? 0);
  }

  Future<int> _sessionsBetween(DateTime start, DateTime end) async {
    final count = _database.focusSessions.id.count();
    final row =
        await (_database.selectOnly(_database.focusSessions)
              ..addColumns([count])
              ..where(
                _database.focusSessions.status.equals('completed') &
                    _database.focusSessions.startedAt.isBiggerOrEqualValue(
                      start,
                    ) &
                    _database.focusSessions.startedAt.isSmallerThanValue(end),
              ))
            .getSingle();
    return row.read(count) ?? 0;
  }

  Future<int> _tasksCompletedBetween(DateTime start, DateTime end) async {
    final count = _database.tasks.id.count();
    final row =
        await (_database.selectOnly(_database.tasks)
              ..addColumns([count])
              ..where(
                _database.tasks.completedAt.isBiggerOrEqualValue(start) &
                    _database.tasks.completedAt.isSmallerThanValue(end),
              ))
            .getSingle();
    return row.read(count) ?? 0;
  }

  Future<int> _openTasks() async {
    final count = _database.tasks.id.count();
    final row =
        await (_database.selectOnly(_database.tasks)
              ..addColumns([count])
              ..where(_database.tasks.isCompleted.equals(false)))
            .getSingle();
    return row.read(count) ?? 0;
  }

  Future<_HabitStats> _habitStats({
    required DateTime weekStart,
    required DateTime today,
    required WeekStart weekStartPreference,
  }) async {
    final habits = await (_database.select(
      _database.habits,
    )..where((row) => row.isArchived.equals(false))).get();
    if (habits.isEmpty) {
      return const _HabitStats(active: 0, doneToday: 0, consistency: 0);
    }
    final elapsedDays = dayNumber(today) - dayNumber(weekStart) + 1;
    final completions =
        await (_database.select(_database.habitCompletions)..where(
              (row) =>
                  row.completedOn.isBiggerOrEqualValue(weekStart) &
                  row.completedOn.isSmallerThanValue(
                    today.add(const Duration(days: 1)),
                  ),
            ))
            .get();
    final activeIds = {for (final habit in habits) habit.id};
    final daysByHabit = <int, Set<int>>{};
    for (final completion in completions) {
      if (!activeIds.contains(completion.habitId)) continue;
      daysByHabit
          .putIfAbsent(completion.habitId, () => <int>{})
          .add(dayNumber(completion.completedOn));
    }
    final todayNumber = dayNumber(today);
    var doneToday = 0;
    var doneInWeek = 0;
    for (final habit in habits) {
      final days = daysByHabit[habit.id] ?? const <int>{};
      if (days.contains(todayNumber)) doneToday++;
      doneInWeek += days.length;
    }
    final possible = habits.length * elapsedDays.clamp(1, 7);
    return _HabitStats(
      active: habits.length,
      doneToday: doneToday,
      consistency: possible == 0 ? 0 : (doneInWeek / possible).clamp(0, 1),
    );
  }

  Future<List<DailyFocus>> _lastSevenDays(DateTime today) async {
    final start = today.subtract(const Duration(days: 6));
    final sessions =
        await (_database.select(_database.focusSessions)..where(
              (row) =>
                  row.status.equals('completed') &
                  row.startedAt.isBiggerOrEqualValue(start) &
                  row.startedAt.isSmallerThanValue(
                    today.add(const Duration(days: 1)),
                  ),
            ))
            .get();
    final totals = <int, int>{};
    for (final session in sessions) {
      final day = dayNumber(session.startedAt);
      totals[day] = (totals[day] ?? 0) + session.durationMillis;
    }
    return [
      for (var offset = 6; offset >= 0; offset--)
        DailyFocus(
          date: today.subtract(Duration(days: offset)),
          duration: Duration(
            milliseconds: totals[dayNumber(today) - offset] ?? 0,
          ),
        ),
    ];
  }
}

class _HabitStats {
  const _HabitStats({
    required this.active,
    required this.doneToday,
    required this.consistency,
  });

  final int active;
  final int doneToday;
  final double consistency;
}
