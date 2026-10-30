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
  late TasksRepository tasks;
  late FocusSessionsRepository sessions;
  late HabitsRepository habits;
  late InsightsRepository insights;

  // Friday, 30 October 2026; Monday-start week runs 26 Oct - 1 Nov.
  final now = DateTime(2026, 10, 30, 12);

  setUp(() {
    database = FlowStateDatabase.forTesting(NativeDatabase.memory());
    tasks = TasksRepository(database);
    sessions = FocusSessionsRepository(database);
    habits = HabitsRepository(database);
    insights = InsightsRepository(database);
  });

  tearDown(() async => database.close());

  test('empty workspace reports zeros rather than sample activity', () async {
    final snapshot = await insights.load(now: now, weekStart: WeekStart.monday);
    expect(snapshot.focusToday, Duration.zero);
    expect(snapshot.focusWeek, Duration.zero);
    expect(snapshot.focusMonth, Duration.zero);
    expect(snapshot.sessionsMonth, 0);
    expect(snapshot.tasksCompletedMonth, 0);
    expect(snapshot.activeHabits, 0);
    expect(snapshot.habitConsistencyThisWeek, 0);
    expect(snapshot.lastSevenDays, hasLength(7));
    expect(
      snapshot.lastSevenDays.every((day) => day.duration == Duration.zero),
      isTrue,
    );
    expect(snapshot.hasAnyActivity, isFalse);
  });

  test('focus, task and habit statistics come from stored rows', () async {
    // 25 minutes two days earlier, 10 minutes today, plus an interrupted run
    // and a session from the previous month that must not be counted.
    await sessions.start(now: DateTime(2026, 10, 28, 9));
    await sessions.finish(now: DateTime(2026, 10, 28, 9, 25));
    await sessions.start(now: DateTime(2026, 10, 30, 10));
    await sessions.finish(now: DateTime(2026, 10, 30, 10, 10));
    await sessions.start(now: DateTime(2026, 10, 30, 11));
    await sessions.cancel(now: DateTime(2026, 10, 30, 11, 5));
    await sessions.start(now: DateTime(2026, 9, 30, 9));
    await sessions.finish(now: DateTime(2026, 9, 30, 9, 30));

    final weekTask = await tasks.create(
      title: 'Finish notes',
      now: DateTime(2026, 10, 27, 8),
    );
    final monthTask = await tasks.create(
      title: 'Plan month',
      now: DateTime(2026, 10, 1, 8),
    );
    await tasks.create(title: 'Old open task', now: DateTime(2026, 9, 15));

    final weekTaskRow = (await database.select(database.tasks).get())
        .singleWhere((task) => task.id == weekTask);
    await tasks.setCompleted(weekTaskRow, true, now: DateTime(2026, 10, 30, 9));
    final monthTaskRow = (await database.select(database.tasks).get())
        .singleWhere((task) => task.id == monthTask);
    await tasks.setCompleted(
      monthTaskRow,
      true,
      now: DateTime(2026, 10, 27, 9),
    );

    final read = await habits.create(name: 'Read', now: now);
    await habits.create(name: 'Stretch', now: now);
    final archived = await habits.create(name: 'Old habit', now: now);
    final archivedRow = (await database.select(database.habits).get())
        .singleWhere((habit) => habit.id == archived);
    await habits.setArchived(archivedRow, true, now: now);

    await habits.setCompletedOn(read, DateTime(2026, 10, 28), true);
    await habits.setCompletedOn(read, DateTime(2026, 10, 30), true);

    final snapshot = await insights.load(now: now, weekStart: WeekStart.monday);
    expect(snapshot.focusToday, const Duration(minutes: 10));
    expect(snapshot.focusWeek, const Duration(minutes: 35));
    expect(snapshot.focusMonth, const Duration(minutes: 35));
    expect(snapshot.sessionsToday, 1);
    expect(snapshot.sessionsWeek, 2);
    expect(snapshot.sessionsMonth, 2);
    expect(snapshot.tasksCompletedToday, 1);
    expect(snapshot.tasksCompletedWeek, 2);
    expect(snapshot.tasksCompletedMonth, 2);
    expect(snapshot.tasksCreatedWeek, 1);
    expect(snapshot.openTaskCount, 1);
    expect(snapshot.activeHabits, 2);
    expect(snapshot.habitCompletionsThisWeek, 2);
    expect(snapshot.habitConsistencyThisWeek, closeTo(0.2, 1e-9));
    expect(snapshot.weekStartDate, DateTime(2026, 10, 26));
    expect(snapshot.monthStart, DateTime(2026, 10, 1));

    expect(snapshot.lastSevenDays, hasLength(7));
    expect(snapshot.lastSevenDays.first.day, DateTime(2026, 10, 24));
    expect(snapshot.lastSevenDays[4].day, DateTime(2026, 10, 28));
    expect(snapshot.lastSevenDays[4].duration, const Duration(minutes: 25));
    expect(snapshot.lastSevenDays.last.day, DateTime(2026, 10, 30));
    expect(snapshot.lastSevenDays.last.duration, const Duration(minutes: 10));
    expect(snapshot.hasFocusHistory, isTrue);
  });

  test('sunday week start shifts the weekly window', () async {
    await sessions.start(now: DateTime(2026, 10, 25, 9));
    await sessions.finish(now: DateTime(2026, 10, 25, 9, 20));

    final monday = await insights.load(now: now, weekStart: WeekStart.monday);
    expect(monday.weekStartDate, DateTime(2026, 10, 26));
    expect(monday.focusWeek, Duration.zero);

    final sunday = await insights.load(now: now, weekStart: WeekStart.sunday);
    expect(sunday.weekStartDate, DateTime(2026, 10, 25));
    expect(sunday.focusWeek, const Duration(minutes: 20));
  });
}
