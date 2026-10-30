import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flowstate/data/flowstate_database.dart';
import 'package:flowstate/data/habits_repository.dart';
import 'package:flowstate/data/settings_repository.dart';

void main() {
  late FlowStateDatabase database;
  late HabitsRepository habits;
  final today = DateTime(2026, 10, 30, 15, 30);

  setUp(() {
    database = FlowStateDatabase.forTesting(NativeDatabase.memory());
    habits = HabitsRepository(database);
  });

  tearDown(() async => database.close());

  test('creates, edits, archives and deletes habits', () async {
    final id = await habits.create(
      name: '  Read 20 pages  ',
      description: '  Before bed  ',
      now: today,
    );
    var all = await database.select(database.habits).get();
    expect(all.single.name, 'Read 20 pages');
    expect(all.single.description, 'Before bed');
    expect(all.single.isArchived, isFalse);

    await habits.updateHabit(
      all.single,
      name: 'Read 30 pages',
      description: '   ',
      now: today,
    );
    all = await database.select(database.habits).get();
    expect(all.single.name, 'Read 30 pages');
    expect(all.single.description, isNull);

    await habits.setArchived(all.single, true, now: today);
    all = await database.select(database.habits).get();
    expect(all.single.isArchived, isTrue);

    expect(await habits.deleteHabit(id), 1);
    expect(await database.select(database.habits).get(), isEmpty);
  });

  test('completion is idempotent and can be undone', () async {
    final id = await habits.create(name: 'Stretch', now: today);

    await habits.setCompletedOn(id, today, true, now: today);
    await habits.setCompletedOn(id, today, true, now: today);

    var rows = await database.select(database.habitCompletions).get();
    expect(rows, hasLength(1));
    expect(rows.single.completedOn, DateTime(2026, 10, 30));
    expect(await habits.isCompletedOn(id, today), isTrue);

    await habits.setCompletedOn(id, today, false, now: today);
    rows = await database.select(database.habitCompletions).get();
    expect(rows, isEmpty);
    expect(await habits.isCompletedOn(id, today), isFalse);
  });

  test('day boundaries keep completions on their own day', () async {
    final id = await habits.create(name: 'Walk', now: today);

    await habits.setCompletedOn(id, DateTime(2026, 10, 30, 23, 59), true);
    await habits.setCompletedOn(id, DateTime(2026, 10, 31, 0, 1), true);

    final dayNumbers = await habits.completedDayNumbers(id);
    expect(dayNumbers, hasLength(2));
    expect(await habits.isCompletedOn(id, DateTime(2026, 10, 30, 8)), isTrue);
    expect(await habits.isCompletedOn(id, DateTime(2026, 10, 31, 8)), isTrue);
    expect(await habits.isCompletedOn(id, DateTime(2026, 10, 29, 23)), isFalse);
  });

  test('streak counts consecutive days and tolerates an open today', () async {
    final id = await habits.create(name: 'Journal', now: today);
    for (final offset in [3, 2, 1]) {
      await habits.setCompletedOn(
        id,
        today.subtract(Duration(days: offset)),
        true,
      );
    }
    // Yesterday plus the two days before it, today still open.
    expect(await habits.currentStreak(id, today: today), 3);

    await habits.setCompletedOn(id, today, true);
    expect(await habits.currentStreak(id, today: today), 4);

    // A missed day ends the streak rather than being skipped.
    await habits.setCompletedOn(
      id,
      today.subtract(const Duration(days: 2)),
      false,
    );
    expect(await habits.currentStreak(id, today: today), 2);
    // Tomorrow, today and yesterday form the streak; the missed day stops it.
    expect(
      await habits.currentStreak(id, today: today.add(const Duration(days: 1))),
      2,
    );
  });

  test(
    'weekly consistency uses elapsed days and respects week start',
    () async {
      final id = await habits.create(name: 'Meditate', now: today);

      // Friday 2026-10-30. A Monday-start week runs Oct 26 - Nov 1.
      DateTime mondayWeekStart() => startOfWeek(today, WeekStart.monday);
      expect(mondayWeekStart(), DateTime(2026, 10, 26));
      expect(startOfWeek(today, WeekStart.sunday), DateTime(2026, 10, 25));

      await habits.setCompletedOn(id, DateTime(2026, 10, 26), true);
      await habits.setCompletedOn(id, DateTime(2026, 10, 28), true);
      await habits.setCompletedOn(id, DateTime(2026, 10, 30), true);

      final summary = (await habits.summaries(
        today: today,
        weekStart: WeekStart.monday,
      )).single;
      expect(summary.completedToday, isTrue);
      expect(summary.weekDates, hasLength(7));
      expect(summary.weekDates.first, DateTime(2026, 10, 26));
      expect(summary.weekCompleted, 3);
      expect(summary.weekElapsedDays, 5);
      expect(summary.weekConsistency, closeTo(0.6, 1e-9));
      expect(summary.isCompletedOn(DateTime(2026, 10, 28)), isTrue);
      expect(summary.isCompletedOn(DateTime(2026, 11, 1)), isFalse);
    },
  );

  test('deleting a habit removes its completion history', () async {
    final id = await habits.create(name: 'Floss', now: today);
    await habits.setCompletedOn(id, today, true);
    await habits.deleteHabit(id);
    expect(await database.select(database.habitCompletions).get(), isEmpty);
  });

  test('history returns oldest to newest flags', () async {
    final id = await habits.create(name: 'Water', now: today);
    await habits.setCompletedOn(id, today, true);
    await habits.setCompletedOn(
      id,
      today.subtract(const Duration(days: 2)),
      true,
    );

    expect(await habits.history(id, endDay: today), [
      false,
      false,
      false,
      false,
      true,
      false,
      true,
    ]);
  });
}
