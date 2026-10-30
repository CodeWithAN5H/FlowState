import 'package:async/async.dart';
import 'package:drift/drift.dart';

import 'flowstate_database.dart';
import 'settings_repository.dart';

/// Strips the time component, keeping a local calendar date at midnight.
DateTime dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// Days since the Unix epoch for a local calendar date. Using whole day
/// numbers avoids daylight-saving drift when stepping through dates.
int dayNumber(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;

DateTime dayFromNumber(int day) {
  final utc = DateTime.fromMillisecondsSinceEpoch(
    day * Duration.millisecondsPerDay,
    isUtc: true,
  );
  return DateTime(utc.year, utc.month, utc.day);
}

/// First day of the week containing [date] for the given week start.
DateTime startOfWeek(DateTime date, WeekStart weekStart) {
  final startIndex = weekStart == WeekStart.monday ? 1 : 7;
  final offset = (date.weekday - startIndex + 7) % 7;
  return dateOnly(date).subtract(Duration(days: offset));
}

class HabitSummary {
  const HabitSummary({
    required this.habit,
    required this.completedToday,
    required this.currentStreak,
    required this.weekDates,
    required this.completedDays,
    required this.today,
  });

  final Habit habit;
  final bool completedToday;
  final int currentStreak;

  /// Seven dates starting on the configured first day of the week.
  final List<DateTime> weekDates;

  /// Completed calendar days for this habit, as epoch day numbers.
  final Set<int> completedDays;

  final DateTime today;

  int get weekCompleted => weekDates
      .where((date) => !date.isAfter(today))
      .where((date) => completedDays.contains(dayNumber(date)))
      .length;

  int get weekElapsedDays => dayNumber(today) - dayNumber(weekDates.first) + 1;

  /// Share of elapsed days this week with a completion, 0 when not applicable.
  double get weekConsistency {
    final elapsed = weekElapsedDays.clamp(1, 7);
    return weekCompleted / elapsed;
  }

  bool isCompletedOn(DateTime date) => completedDays.contains(dayNumber(date));
}

class HabitsRepository {
  HabitsRepository(this._database);

  final FlowStateDatabase _database;

  Stream<List<Habit>> watchAll() =>
      (_database.select(_database.habits)..orderBy([
            (row) => OrderingTerm.asc(row.isArchived),
            (row) => OrderingTerm.desc(row.createdAt),
          ]))
          .watch();

  /// Watches habits together with their completion history so the UI updates
  /// when either table changes.
  Stream<List<HabitSummary>> watchSummaries({
    required DateTime today,
    required WeekStart weekStart,
  }) {
    final habits =
        (_database.select(_database.habits)..orderBy([
              (row) => OrderingTerm.asc(row.isArchived),
              (row) => OrderingTerm.desc(row.createdAt),
            ]))
            .watch();
    final completions = _database.select(_database.habitCompletions).watch();
    return StreamZip<dynamic>([habits, completions])
        .map((latest) => _summaries(latest[0], latest[1], today, weekStart));
  }

  Future<List<HabitSummary>> summaries({
    required DateTime today,
    required WeekStart weekStart,
  }) async {
    final habits =
        await (_database.select(_database.habits)..orderBy([
              (row) => OrderingTerm.asc(row.isArchived),
              (row) => OrderingTerm.desc(row.createdAt),
            ]))
            .get();
    final completions = await _database
        .select(_database.habitCompletions)
        .get();
    return _summaries(habits, completions, today, weekStart);
  }

  Future<int> create({
    required String name,
    String? description,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    return _database
        .into(_database.habits)
        .insert(
          HabitsCompanion.insert(
            name: name.trim(),
            description: Value(_normalize(description)),
            createdAt: at,
            updatedAt: at,
          ),
        );
  }

  Future<void> updateHabit(
    Habit habit, {
    required String name,
    String? description,
    DateTime? now,
  }) =>
      (_database.update(
        _database.habits,
      )..where((row) => row.id.equals(habit.id))).write(
        HabitsCompanion(
          name: Value(name.trim()),
          description: Value(_normalize(description)),
          updatedAt: Value(now ?? DateTime.now()),
        ),
      );

  Future<void> setArchived(Habit habit, bool archived, {DateTime? now}) =>
      (_database.update(
        _database.habits,
      )..where((row) => row.id.equals(habit.id))).write(
        HabitsCompanion(
          isArchived: Value(archived),
          updatedAt: Value(now ?? DateTime.now()),
        ),
      );

  Future<int> deleteHabit(int id) => (_database.delete(
    _database.habits,
  )..where((row) => row.id.equals(id))).go();

  /// Idempotently marks [day] complete or not for a habit, so tapping twice
  /// never records a duplicate completion.
  Future<void> setCompletedOn(
    int habitId,
    DateTime day,
    bool completed, {
    DateTime? now,
  }) async {
    final normalized = dateOnly(day);
    if (completed) {
      await _database
          .into(_database.habitCompletions)
          .insert(
            HabitCompletionsCompanion.insert(
              habitId: habitId,
              completedOn: normalized,
              createdAt: now ?? DateTime.now(),
            ),
            mode: InsertMode.insertOrIgnore,
          );
    } else {
      await (_database.delete(_database.habitCompletions)..where(
            (row) =>
                row.habitId.equals(habitId) &
                row.completedOn.equals(normalized),
          ))
          .go();
    }
  }

  Future<bool> isCompletedOn(int habitId, DateTime day) async {
    final row =
        await (_database.select(_database.habitCompletions)..where(
              (row) =>
                  row.habitId.equals(habitId) &
                  row.completedOn.equals(dateOnly(day)),
            ))
            .getSingleOrNull();
    return row != null;
  }

  Future<Set<int>> completedDayNumbers(int habitId) async {
    final rows = await (_database.select(
      _database.habitCompletions,
    )..where((row) => row.habitId.equals(habitId))).get();
    return rows.map((row) => dayNumber(row.completedOn)).toSet();
  }

  /// Counts back from today (or yesterday, so a streak stays alive until the
  /// day ends) over consecutive completed days.
  Future<int> currentStreak(int habitId, {required DateTime today}) async {
    final days = await completedDayNumbers(habitId);
    var cursor = dayNumber(today);
    if (!days.contains(cursor)) cursor -= 1;
    var streak = 0;
    while (days.contains(cursor)) {
      streak++;
      cursor--;
    }
    return streak;
  }

  Future<List<bool>> history(
    int habitId, {
    required DateTime endDay,
    int days = 7,
  }) async {
    final completed = await completedDayNumbers(habitId);
    final end = dayNumber(endDay);
    return [
      for (var offset = days - 1; offset >= 0; offset--)
        completed.contains(end - offset),
    ];
  }

  Future<void> deleteAll() async {
    await _database.delete(_database.habitCompletions).go();
    await _database.delete(_database.habits).go();
  }

  List<HabitSummary> _summaries(
    List<Habit> habits,
    List<HabitCompletion> completions,
    DateTime today,
    WeekStart weekStart,
  ) {
    final daysByHabit = <int, Set<int>>{};
    for (final completion in completions) {
      daysByHabit
          .putIfAbsent(completion.habitId, () => <int>{})
          .add(dayNumber(completion.completedOn));
    }
    final start = startOfWeek(today, weekStart);
    final weekDates = [
      for (var offset = 0; offset < 7; offset++)
        dateOnly(start.add(Duration(days: offset))),
    ];
    return [
      for (final habit in habits)
        _summary(
          habit,
          daysByHabit[habit.id] ?? const <int>{},
          today,
          weekDates,
        ),
    ];
  }

  HabitSummary _summary(
    Habit habit,
    Set<int> days,
    DateTime today,
    List<DateTime> weekDates,
  ) {
    var cursor = dayNumber(today);
    if (!days.contains(cursor)) cursor -= 1;
    var streak = 0;
    while (days.contains(cursor)) {
      streak++;
      cursor--;
    }
    return HabitSummary(
      habit: habit,
      completedToday: days.contains(dayNumber(today)),
      currentStreak: streak,
      weekDates: weekDates,
      completedDays: days,
      today: today,
    );
  }

  static String? _normalize(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
