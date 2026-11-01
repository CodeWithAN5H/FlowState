import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowstate/data/flowstate_database.dart';
import 'package:flowstate/data/focus_sessions_repository.dart';
import 'package:flowstate/data/habits_repository.dart';
import 'package:flowstate/data/insights_repository.dart';
import 'package:flowstate/data/settings_repository.dart';
import 'package:flowstate/data/tasks_repository.dart';

void main() {
  late FlowStateDatabase database;
  late InsightsRepository insights;
  late TasksRepository tasks;
  late HabitsRepository habits;
  late FocusSessionsRepository sessions;

  // 1 November 2026 is a Sunday; the default week starts on Monday.
  final now = DateTime(2026, 11, 1, 12);

  setUp(() {
    database = FlowStateDatabase.forTesting(NativeDatabase.memory());
    insights = InsightsRepository(database);
    tasks = TasksRepository(database);
    habits = HabitsRepository(database);
    sessions = FocusSessionsRepository(database);
  });

  tearDown(() async => database.close());

  test('an untouched database reports an empty snapshot', () async {
    final snapshot = await insights.load(
      settings: const AppSettings(),
      now: now,
    );
    expect(snapshot.isEmpty, isTrue);
    expect(snapshot.todayFocus, Duration.zero);
    expect(snapshot.weekSessions, 0);
    expect(snapshot.tasksOpen, 0);
    expect(snapshot.activeHabits, 0);
    expect(snapshot.lastSevenDays, hasLength(7));
    expect(
      snapshot.lastSevenDays.every((day) => day.duration == Duration.zero),
      isTrue,
    );
  });

  test(
    'focus totals only count completed sessions inside each window',
    () async {
      // Today: completed 10 minutes.
      await sessions.start(now: DateTime(2026, 11, 1, 9));
      await sessions.finish(now: DateTime(2026, 11, 1, 9, 10));
      // Yesterday: completed 25 minutes (this week, not today).
      await sessions.start(now: DateTime(2026, 10, 31, 9));
      await sessions.finish(now: DateTime(2026, 10, 31, 9, 25));
      // Earlier this month but last week: completed 40 minutes.
      await sessions.start(now: DateTime(2026, 10, 27, 9));
      await sessions.finish(now: DateTime(2026, 10, 27, 9, 40));
      // Interrupted sessions never count.
      await sessions.start(now: DateTime(2026, 11, 1, 10));
      await sessions.cancel(now: DateTime(2026, 11, 1, 10, 30));

      final snapshot = await insights.load(
        settings: const AppSettings(),
        now: now,
      );
      expect(snapshot.todayFocus, const Duration(minutes: 10));
      expect(snapshot.todaySessions, 1);
      // The week runs Monday 26 October to Sunday 1 November.
      expect(snapshot.weekFocus, const Duration(minutes: 75));
      expect(snapshot.weekSessions, 3);
      // The month is November, so October sessions are excluded.
      expect(snapshot.monthFocus, const Duration(minutes: 10));
      expect(snapshot.monthSessions, 1);

      final lastSevenDays = snapshot.lastSevenDays;
      expect(lastSevenDays.last.date, DateTime(2026, 11, 1));
      expect(lastSevenDays.last.duration, const Duration(minutes: 10));
      // 31 October is one day back, 27 October is five days back.
      expect(
        lastSevenDays[lastSevenDays.length - 2].duration,
        const Duration(minutes: 25),
      );
      expect(
        lastSevenDays[lastSevenDays.length - 6].duration,
        const Duration(minutes: 40),
      );
    },
  );

  test('task statistics reflect stored completions', () async {
    await tasks.create(title: 'Done today');
    await tasks.create(title: 'Still open');
    final stored = await database.select(database.tasks).get();
    await tasks.setCompleted(
      stored.firstWhere((task) => task.title == 'Done today'),
      true,
      now: DateTime(2026, 11, 1, 8),
    );

    final snapshot = await insights.load(
      settings: const AppSettings(),
      now: now,
    );
    expect(snapshot.tasksCompletedToday, 1);
    expect(snapshot.tasksCompletedWeek, 1);
    expect(snapshot.tasksOpen, 1);
  });

  test('habit consistency uses active habits and elapsed week days', () async {
    final first = await habits.create(name: 'Read');
    await habits.create(name: 'Walk');
    await habits.create(name: 'Archived one');
    final archived = (await database.select(database.habits).get()).firstWhere(
      (habit) => habit.name == 'Archived one',
    );
    await habits.setArchived(archived, true);
    await habits.setCompletedOn(
      first,
      day: DateTime(2026, 11, 1),
      completed: true,
    );

    final snapshot = await insights.load(
      settings: const AppSettings(),
      now: now,
    );
    expect(snapshot.activeHabits, 2);
    expect(snapshot.habitsDoneToday, 1);
    // Two habits over the seven elapsed days of the week: 1 of 14.
    expect(snapshot.habitConsistency, closeTo(1 / 14, 0.0001));
  });

  test('a Sunday week start shortens the consistency window', () async {
    final habit = await habits.create(name: 'Read');
    await habits.setCompletedOn(
      habit,
      day: DateTime(2026, 11, 1),
      completed: true,
    );
    final snapshot = await insights.load(
      settings: const AppSettings(weekStart: WeekStart.sunday),
      now: now,
    );
    expect(snapshot.habitConsistency, 1);
  });

  test('the configured goal is reported with the snapshot', () async {
    final snapshot = await insights.load(
      settings: const AppSettings(dailyFocusGoalMinutes: 45),
      now: now,
    );
    expect(snapshot.goalMinutes, 45);
  });
}
