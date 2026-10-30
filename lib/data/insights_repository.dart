import 'package:drift/drift.dart';

import 'flowstate_database.dart';
import 'habits_repository.dart';
import 'settings_repository.dart';

class DailyFocus {
  const DailyFocus({required this.day, required this.duration});

  final DateTime day;
  final Duration duration;
}

class InsightsSnapshot {
  const InsightsSnapshot({
    required this.focusToday,
    required this.focusWeek,
    required this.focusMonth,
    required this.sessionsToday,
    required this.sessionsWeek,
    required this.sessionsMonth,
    required this.tasksCompletedToday,
    required this.tasksCompletedWeek,
    required this.tasksCompletedMonth,
    required this.tasksCreatedWeek,
    required this.openTaskCount,
    required this.activeHabits,
    required this.habitCompletionsThisWeek,
    required this.habitConsistencyThisWeek,
    required this.lastSevenDays,
    required this.weekStartDate,
    required this.monthStart,
  });

  final Duration focusToday;
  final Duration focusWeek;
  final Duration focusMonth;
  final int sessionsToday;
  final int sessionsWeek;
  final int sessionsMonth;
  final int tasksCompletedToday;
  final int tasksCompletedWeek;
  final int tasksCompletedMonth;
  final int tasksCreatedWeek;
  final int openTaskCount;
  final int activeHabits;
  final int habitCompletionsThisWeek;

  /// Average share of elapsed week days completed across active habits.
  final double habitConsistencyThisWeek;

  /// Focus duration for the last seven days, oldest first.
  final List<DailyFocus> lastSevenDays;

  final DateTime weekStartDate;
  final DateTime monthStart;

  bool get hasFocusHistory => focusMonth > Duration.zero || sessionsMonth > 0;

  bool get hasAnyActivity =>
      hasFocusHistory ||
      tasksCompletedMonth > 0 ||
      habitCompletionsThisWeek > 0;
}

/// Read-only statistics computed from the local tables. Nothing here is
/// fabricated: every value comes from stored tasks, sessions, or habits.
class InsightsRepository {
  InsightsRepository(this._database);

  final FlowStateDatabase _database;

  Future<InsightsSnapshot> load({
    required DateTime now,
    required WeekStart weekStart,
  }) async {
    final today = dateOnly(now);
    final weekStartDate = startOfWeek(today, weekStart);
    final monthStart = DateTime(now.year, now.month);
    final tomorrow = today.add(const Duration(days: 1));
    final weekEnd = weekStartDate.add(const Duration(days: 7));

    final sessions =
        await (_database.select(_database.focusSessions)..where(
              (row) =>
                  row.status.equals('completed') &
                  row.startedAt.isBiggerOrEqualValue(monthStart) &
                  row.startedAt.isSmallerThanValue(tomorrow),
            ))
            .get();

    Duration sumWhere(bool Function(FocusSession session) test) => Duration(
      milliseconds: sessions
          .where(test)
          .fold<int>(0, (total, row) => total + row.durationMillis),
    );

    int countWhere(bool Function(FocusSession session) test) =>
        sessions.where(test).length;

    bool inToday(FocusSession row) =>
        !row.startedAt.isBefore(today) && row.startedAt.isBefore(tomorrow);
    bool inWeek(FocusSession row) =>
        !row.startedAt.isBefore(weekStartDate) &&
        row.startedAt.isBefore(weekEnd);

    final tasksCreatedWeekRow =
        await (_database.selectOnly(_database.tasks)
              ..addColumns([_database.tasks.id.count()])
              ..where(
                _database.tasks.createdAt.isBiggerOrEqualValue(weekStartDate) &
                    _database.tasks.createdAt.isSmallerThanValue(weekEnd),
              ))
            .getSingle();

    final openTasksRow =
        await (_database.selectOnly(_database.tasks)
              ..addColumns([_database.tasks.id.count()])
              ..where(_database.tasks.isCompleted.equals(false)))
            .getSingle();

    final habits = await (_database.select(
      _database.habits,
    )..where((row) => row.isArchived.equals(false))).get();
    final habitIds = habits.map((habit) => habit.id).toSet();
    final completions =
        await (_database.select(_database.habitCompletions)..where(
              (row) =>
                  row.completedOn.isBiggerOrEqualValue(weekStartDate) &
                  row.completedOn.isSmallerThanValue(weekEnd),
            ))
            .get();
    final activeCompletions = completions
        .where((row) => habitIds.contains(row.habitId))
        .length;
    final elapsedWeekDays = (dayNumber(today) - dayNumber(weekStartDate) + 1)
        .clamp(1, 7);
    final consistency = habits.isEmpty
        ? 0.0
        : activeCompletions / (habits.length * elapsedWeekDays);

    final lastSevenDays = <DailyFocus>[];
    for (var offset = 6; offset >= 0; offset--) {
      final day = today.subtract(Duration(days: offset));
      final next = day.add(const Duration(days: 1));
      lastSevenDays.add(
        DailyFocus(
          day: day,
          duration: sumWhere(
            (row) =>
                !row.startedAt.isBefore(day) && row.startedAt.isBefore(next),
          ),
        ),
      );
    }

    return InsightsSnapshot(
      focusToday: sumWhere(inToday),
      focusWeek: sumWhere(inWeek),
      focusMonth: sumWhere((_) => true),
      sessionsToday: countWhere(inToday),
      sessionsWeek: countWhere(inWeek),
      sessionsMonth: sessions.length,
      tasksCompletedToday: await _completedTasks(today, tomorrow),
      tasksCompletedWeek: await _completedTasks(weekStartDate, weekEnd),
      tasksCompletedMonth: await _completedTasks(monthStart, tomorrow),
      tasksCreatedWeek:
          tasksCreatedWeekRow.read(_database.tasks.id.count()) ?? 0,
      openTaskCount: openTasksRow.read(_database.tasks.id.count()) ?? 0,
      activeHabits: habits.length,
      habitCompletionsThisWeek: activeCompletions,
      habitConsistencyThisWeek: consistency.clamp(0.0, 1.0),
      lastSevenDays: lastSevenDays,
      weekStartDate: weekStartDate,
      monthStart: monthStart,
    );
  }

  Future<int> _completedTasks(DateTime start, DateTime end) async {
    final row =
        await (_database.selectOnly(_database.tasks)
              ..addColumns([_database.tasks.id.count()])
              ..where(
                _database.tasks.completedAt.isBiggerOrEqualValue(start) &
                    _database.tasks.completedAt.isSmallerThanValue(end),
              ))
            .getSingle();
    return row.read(_database.tasks.id.count()) ?? 0;
  }
}
