import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowstate/data/flowstate_database.dart';
import 'package:flowstate/data/habits_repository.dart';
import 'package:flowstate/data/settings_repository.dart';

void main() {
  late FlowStateDatabase database;
  late HabitsRepository habits;

  setUp(() {
    database = FlowStateDatabase.forTesting(NativeDatabase.memory());
    habits = HabitsRepository(database);
  });

  tearDown(() async => database.close());

  test('create, edit, archive and delete a habit', () async {
    final id = await habits.create(name: '  Read  ', details: ' Before bed ');
    var summary = (await habits.summaries(
      today: DateTime(2026, 11, 1),
      weekStart: WeekStart.monday,
    )).single;
    expect(summary.habit.name, 'Read');
    expect(summary.habit.details, 'Before bed');
    expect(summary.habit.isArchived, isFalse);

    await habits.updateHabit(summary.habit, name: 'Read more', details: '');
    summary = (await habits.summaries(
      today: DateTime(2026, 11, 1),
      weekStart: WeekStart.monday,
    )).single;
    expect(summary.habit.name, 'Read more');
    expect(summary.habit.details, isNull);

    await habits.setArchived(summary.habit, true);
    expect(
      (await database.select(database.habits).get()).single.isArchived,
      isTrue,
    );

    expect(await habits.delete(id), 1);
    expect(await database.select(database.habits).get(), isEmpty);
  });

  test('completing the same day twice never duplicates history', () async {
    final id = await habits.create(name: 'Journal');
    await habits.setCompletedOn(
      id,
      day: DateTime(2026, 11, 1),
      completed: true,
    );
    await habits.setCompletedOn(
      id,
      day: DateTime(2026, 11, 1, 22),
      completed: true,
    );
    expect(
      await database.select(database.habitCompletions).get(),
      hasLength(1),
    );

    await habits.setCompletedOn(
      id,
      day: DateTime(2026, 11, 1),
      completed: false,
    );
    expect(await database.select(database.habitCompletions).get(), isEmpty);
  });

  test('a completion belongs to exactly one local calendar day', () async {
    final id = await habits.create(name: 'Stretch');
    // Late evening check-ins still belong to that calendar day.
    await habits.setCompletedOn(
      id,
      day: DateTime(2026, 10, 31, 23, 45),
      completed: true,
    );
    expect(await habits.isCompletedOn(id, DateTime(2026, 10, 31, 7)), isTrue);
    expect(await habits.isCompletedOn(id, DateTime(2026, 11, 1)), isFalse);

    final summary = (await habits.summaries(
      today: DateTime(2026, 11, 1, 8),
      weekStart: WeekStart.monday,
    )).single;
    expect(summary.completedToday, isFalse);
    // Yesterday's completion keeps the streak visible until today is over.
    expect(summary.currentStreak, 1);
    expect(summary.totalCompletions, 1);
  });

  test('streaks count consecutive days and stop at a missed day', () async {
    final id = await habits.create(name: 'Run');
    for (final day in [
      DateTime(2026, 10, 27),
      DateTime(2026, 10, 28),
      // 29 October was missed.
      DateTime(2026, 10, 30),
      DateTime(2026, 10, 31),
    ]) {
      await habits.setCompletedOn(id, day: day, completed: true);
    }

    final summary = (await habits.summaries(
      today: DateTime(2026, 10, 31),
      weekStart: WeekStart.monday,
    )).single;
    expect(summary.currentStreak, 2);
    expect(summary.completedToday, isTrue);

    await habits.setCompletedOn(
      id,
      day: DateTime(2026, 11, 2),
      completed: true,
    );
    final later = (await habits.summaries(
      today: DateTime(2026, 11, 2),
      weekStart: WeekStart.monday,
    )).single;
    expect(later.currentStreak, 1);
  });

  test(
    'weekly consistency counts only elapsed days, honouring week start',
    () async {
      // 1 November 2026 is a Sunday.
      final id = await habits.create(name: 'Water');
      await habits.setCompletedOn(
        id,
        day: DateTime(2026, 10, 26),
        completed: true,
      );
      await habits.setCompletedOn(
        id,
        day: DateTime(2026, 11, 1),
        completed: true,
      );

      final sunday = (await habits.summaries(
        today: DateTime(2026, 11, 1, 9),
        weekStart: WeekStart.sunday,
      )).single;
      expect(sunday.weekComputedDays, 1);
      expect(sunday.weekDays.first, isTrue);
      expect(sunday.weekConsistency, 1);

      final monday = (await habits.summaries(
        today: DateTime(2026, 11, 1, 9),
        weekStart: WeekStart.monday,
      )).single;
      expect(monday.weekComputedDays, 7);
      expect(monday.weekCompletedDays, 2);
      expect(monday.weekConsistency, closeTo(2 / 7, 0.0001));
    },
  );

  test(
    'watching summaries reflects a newly created habit immediately',
    () async {
      final events = <List<HabitSummary>>[];
      final subscription = habits
          .watchSummaries(
            today: DateTime(2026, 11, 1),
            weekStart: WeekStart.monday,
          )
          .listen(events.add);
      await pumpEventQueue();

      await habits.create(name: 'Meditate');
      await pumpEventQueue();

      expect(events.last.single.habit.name, 'Meditate');
      await subscription.cancel();
    },
  );
}
