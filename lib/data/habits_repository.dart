import 'package:drift/drift.dart';

import 'flowstate_database.dart';
import 'settings_repository.dart';
import 'sync/sync_models.dart';
import 'sync/sync_store.dart';

/// Drops the time part so completions are compared per calendar day.
DateTime dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// A timezone-independent day index, safe across daylight-saving changes.
int dayNumber(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;

DateTime dayFromNumber(int number) {
  final utc = DateTime.fromMillisecondsSinceEpoch(
    number * Duration.millisecondsPerDay,
    isUtc: true,
  );
  return DateTime(utc.year, utc.month, utc.day);
}

DateTime startOfWeek(DateTime value, WeekStart weekStart) {
  final day = dateOnly(value);
  final offset = weekStart == WeekStart.monday
      ? day.weekday - DateTime.monday
      : day.weekday % DateTime.daysPerWeek;
  return day.subtract(Duration(days: offset));
}

String weekdayLabel(DateTime date) =>
    const ['M', 'T', 'W', 'T', 'F', 'S', 'S'][date.weekday - 1];

class HabitSummary {
  const HabitSummary({
    required this.habit,
    required this.weekDays,
    required this.weekComputedDays,
    required this.currentStreak,
    required this.completedToday,
    required this.totalCompletions,
  });

  final Habit habit;

  /// Seven flags starting on the user's configured week-start day.
  final List<bool> weekDays;

  /// Days of the current week that have actually happened (1–7).
  final int weekComputedDays;
  final int currentStreak;
  final bool completedToday;
  final int totalCompletions;

  int get weekCompletedDays =>
      weekDays.take(weekComputedDays).where((done) => done).length;

  /// Completed days out of the elapsed days of this week.
  double get weekConsistency => weekComputedDays == 0
      ? 0
      : (weekDays.take(weekComputedDays).where((done) => done).length /
                weekComputedDays)
            .clamp(0, 1);
}

class HabitsRepository {
  HabitsRepository(this._database);

  final FlowStateDatabase _database;

  /// Watches habits and their history through a single joined query.
  ///
  /// Two independently combined streams would only re-emit when *both* tables
  /// changed, so a new habit would stay invisible until it was also checked in.
  Stream<List<HabitSummary>> watchSummaries({
    required DateTime today,
    required WeekStart weekStart,
  }) {
    final query =
        _database.select(_database.habits).join([
          leftOuterJoin(
            _database.habitCompletions,
            _database.habitCompletions.habitId.equalsExp(_database.habits.id),
          ),
        ])..orderBy([
          OrderingTerm.asc(_database.habits.isArchived),
          OrderingTerm.asc(_database.habits.createdAt),
        ]);
    return query.watch().map((rows) {
      final habits = <int, Habit>{};
      final daysByHabit = <int, Set<int>>{};
      for (final row in rows) {
        final habit = row.readTable(_database.habits);
        habits[habit.id] = habit;
        final completion = row.readTableOrNull(_database.habitCompletions);
        if (completion != null) {
          daysByHabit
              .putIfAbsent(habit.id, () => <int>{})
              .add(dayNumber(completion.completedOn));
        }
      }
      return _buildSummaries(habits.values, daysByHabit, today, weekStart);
    });
  }

  Future<List<HabitSummary>> summaries({
    required DateTime today,
    required WeekStart weekStart,
  }) async {
    final habits =
        await (_database.select(_database.habits)..orderBy([
              (row) => OrderingTerm.asc(row.isArchived),
              (row) => OrderingTerm.asc(row.createdAt),
            ]))
            .get();
    final completions = await _database
        .select(_database.habitCompletions)
        .get();
    return _buildSummaries(habits, _daysByHabit(completions), today, weekStart);
  }

  Future<int> create({required String name, String? details, DateTime? now}) {
    final at = now ?? DateTime.now();
    return _database
        .into(_database.habits)
        .insert(
          HabitsCompanion.insert(
            name: name.trim(),
            details: Value(_normalizeDetails(details)),
            createdAt: at,
            updatedAt: at,
          ),
        );
  }

  Future<void> updateHabit(
    Habit habit, {
    required String name,
    String? details,
    DateTime? now,
  }) =>
      (_database.update(
        _database.habits,
      )..where((row) => row.id.equals(habit.id))).write(
        HabitsCompanion(
          name: Value(name.trim()),
          details: Value(_normalizeDetails(details)),
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

  /// Deletes the row and keeps a durable tombstone for synchronization.
  ///
  /// The tombstone is written in the same transaction as the delete, so a crash
  /// can never leave a record that vanished locally with nothing left to report
  /// to a future backend.
  Future<int> delete(int id) => _database.transaction(() async {
    final deleted = await (_database.select(
      _database.habits,
    )..where((row) => row.id.equals(id))).getSingleOrNull();
    if (deleted == null) return 0;
    await recordLocalDeletion(
      _database,
      entity: SyncEntity.habit,
      entityUuid: deleted.uuid,
    );
    return (_database.delete(
      _database.habits,
    )..where((row) => row.id.equals(id))).go();
  });

  /// Marks [day] for a habit. Inserting the same day twice is a no-op.
  Future<void> setCompletedOn(
    int habitId, {
    required DateTime day,
    required bool completed,
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
      return;
    }
    await (_database.delete(_database.habitCompletions)..where(
          (row) =>
              row.habitId.equals(habitId) & row.completedOn.equals(normalized),
        ))
        .go();
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

  Future<List<DateTime>> history(int habitId) async {
    final rows =
        await (_database.select(_database.habitCompletions)
              ..where((row) => row.habitId.equals(habitId))
              ..orderBy([(row) => OrderingTerm.desc(row.completedOn)]))
            .get();
    return rows.map((row) => dateOnly(row.completedOn)).toList();
  }

  Future<void> deleteAll() => _database.delete(_database.habits).go();

  List<HabitSummary> _buildSummaries(
    Iterable<Habit> habits,
    Map<int, Set<int>> daysByHabit,
    DateTime today,
    WeekStart weekStart,
  ) {
    final weekStartDay = startOfWeek(today, weekStart);
    final todayNumber = dayNumber(today);
    final computed = todayNumber - dayNumber(weekStartDay) + 1;
    return [
      for (final habit in habits)
        _summary(
          habit,
          daysByHabit[habit.id] ?? const <int>{},
          weekStartDay,
          computed,
          todayNumber,
        ),
    ];
  }

  HabitSummary _summary(
    Habit habit,
    Set<int> days,
    DateTime weekStartDay,
    int computedDays,
    int todayNumber,
  ) {
    final weekStartNumber = dayNumber(weekStartDay);
    return HabitSummary(
      habit: habit,
      weekDays: [
        for (var index = 0; index < DateTime.daysPerWeek; index++)
          days.contains(weekStartNumber + index),
      ],
      weekComputedDays: computedDays.clamp(1, DateTime.daysPerWeek),
      currentStreak: _streak(days, todayNumber),
      completedToday: days.contains(todayNumber),
      totalCompletions: days.length,
    );
  }

  /// Counts back from today. A day not yet completed keeps yesterday's streak
  /// alive until the day is over, so the number does not drop at midnight.
  int _streak(Set<int> days, int todayNumber) {
    var cursor = days.contains(todayNumber) ? todayNumber : todayNumber - 1;
    var streak = 0;
    while (days.contains(cursor)) {
      streak++;
      cursor--;
    }
    return streak;
  }

  static Map<int, Set<int>> _daysByHabit(List<HabitCompletion> completions) {
    final days = <int, Set<int>>{};
    for (final completion in completions) {
      days
          .putIfAbsent(completion.habitId, () => <int>{})
          .add(dayNumber(completion.completedOn));
    }
    return days;
  }

  static String? _normalizeDetails(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
