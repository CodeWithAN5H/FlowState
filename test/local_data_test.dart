import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowstate/data/flowstate_database.dart';
import 'package:flowstate/data/tasks_repository.dart';
import 'package:flowstate/data/focus_sessions_repository.dart';

void main() {
  late FlowStateDatabase database;
  late TasksRepository tasks;
  late FocusSessionsRepository sessions;

  setUp(() {
    database = FlowStateDatabase.forTesting(NativeDatabase.memory());
    tasks = TasksRepository(database);
    sessions = FocusSessionsRepository(database);
  });

  tearDown(() async => database.close());

  group('tasks', () {
    test('create, edit, complete, uncomplete and delete', () async {
      final id = await tasks.create(
        title: '  Read chapter  ',
        description: '  Notes  ',
        priority: 9,
      );
      var all = await database.select(database.tasks).get();
      expect(all.single.title, 'Read chapter');
      expect(all.single.description, 'Notes');
      expect(all.single.priority, 2);

      var task = all.single;
      await tasks.updateTask(
        task,
        title: 'Review notes',
        description: '',
        priority: 1,
      );
      task = (await database.select(database.tasks).get()).single;
      expect(task.title, 'Review notes');
      expect(task.description, isNull);
      expect(task.priority, 1);

      await tasks.setCompleted(task, true);
      task = (await database.select(database.tasks).get()).single;
      expect(task.isCompleted, isTrue);
      expect(task.completedAt, isNotNull);
      expect(await tasks.completedToday(DateTime.now()), 1);

      await tasks.setCompleted(task, false);
      task = (await database.select(database.tasks).get()).single;
      expect(task.isCompleted, isFalse);
      expect(task.completedAt, isNull);
      expect(await tasks.delete(id), 1);
      expect(await database.select(database.tasks).get(), isEmpty);
    });

    test(
      'today list and dashboard count use actual due/completed records',
      () async {
        final now = DateTime(2026, 10, 29, 12);
        final today = await tasks.create(title: 'Today', dueAt: now);
        await tasks.create(
          title: 'Tomorrow',
          dueAt: now.add(const Duration(days: 1)),
        );
        await tasks.create(title: 'No due date');
        expect((await tasks.todayTasks(now)).map((task) => task.id).toSet(), {
          today,
          (await database.select(database.tasks).get())
              .singleWhere((task) => task.title == 'No due date')
              .id,
        });

        final todayTask = (await database.select(database.tasks).get())
            .singleWhere((task) => task.id == today);
        await tasks.setCompleted(todayTask, true);
        expect(await tasks.completedToday(now), 1);
      },
    );

    test('rows survive closing and reopening the SQLite file', () async {
      await database.close();
      final file = File(
        '${Directory.systemTemp.path}/flowstate-${DateTime.now().microsecondsSinceEpoch}.sqlite',
      );
      final first = FlowStateDatabase.forTesting(NativeDatabase(file));
      final firstRepository = TasksRepository(first);
      await firstRepository.create(title: 'Survives restart');
      await first.close();

      final reopened = FlowStateDatabase.forTesting(NativeDatabase(file));
      addTearDown(() async {
        await reopened.close();
        if (file.existsSync()) file.deleteSync();
      });
      final saved = await reopened.select(reopened.tasks).get();
      expect(saved.single.title, 'Survives restart');
    });
  });

  group('recoverable focus sessions', () {
    final origin = DateTime(2026, 10, 29, 9);

    test('running session recovers elapsed time after closing and reopening SQLite', () async {
      await database.close();
      final file = File(
        '${Directory.systemTemp.path}/flowstate-session-${DateTime.now().microsecondsSinceEpoch}.sqlite',
      );
      final first = FlowStateDatabase.forTesting(NativeDatabase(file));
      final firstSessions = FocusSessionsRepository(first);
      await firstSessions.start(now: origin);
      await first.close();

      final reopened = FlowStateDatabase.forTesting(NativeDatabase(file));
      addTearDown(() async {
        await reopened.close();
        if (file.existsSync()) file.deleteSync();
      });
      final recovered = await FocusSessionsRepository(reopened)
          .recover(now: origin.add(const Duration(minutes: 7)));
      expect(recovered, isNotNull);
      expect(recovered!.isRunning, isTrue);
      expect(recovered.elapsed, const Duration(minutes: 7));
    });

    test(
      'recovery counts running wall-clock time and clamps clock rollback',
      () async {
        final id = await sessions.start(now: origin);
        final restored = await sessions.recover(
          now: origin.add(const Duration(minutes: 12)),
        );
        expect(restored!.id, id);
        expect(restored.elapsed, const Duration(minutes: 12));
        expect(restored.isRunning, isTrue);

        final afterClockRollback = await sessions.recover(
          now: origin.subtract(const Duration(minutes: 1)),
        );
        expect(afterClockRollback!.elapsed, Duration.zero);
      },
    );

    test(
      'pause preserves elapsed time and resume adds only the new run',
      () async {
        await sessions.start(now: origin);
        final paused = await sessions.pause(
          now: origin.add(const Duration(minutes: 10)),
        );
        expect(paused!.elapsed, const Duration(minutes: 10));
        expect(paused.isRunning, isFalse);

        await sessions.resume(now: origin.add(const Duration(hours: 1)));
        final recovered = await sessions.recover(
          now: origin.add(const Duration(hours: 1, minutes: 5)),
        );
        expect(recovered!.elapsed, const Duration(minutes: 15));
      },
    );

    test('completed and interrupted sessions remain distinct and count toward stats only when completed', () async {
      await sessions.start(now: origin);
      final completed = await sessions.finish(
        now: origin.add(const Duration(minutes: 25)),
      );
      expect(completed!.elapsed, const Duration(minutes: 25));
      expect(
        await sessions.completedDurationBetween(
          DateTime(2026, 10, 29),
          DateTime(2026, 10, 30),
        ),
        const Duration(minutes: 25),
      );

      await sessions.start(now: origin.add(const Duration(hours: 2)));
      final interrupted = await sessions.cancel(
        now: origin.add(const Duration(hours: 2, minutes: 3)),
      );
      expect(interrupted!.elapsed, const Duration(minutes: 3));
      expect(
        (await database.select(database.focusSessions).get()).map(
          (row) => row.status,
        ),
        ['completed', 'interrupted'],
      );
      expect(
        await sessions.completedDurationBetween(
          DateTime(2026, 10, 29),
          DateTime(2026, 10, 30),
        ),
        const Duration(minutes: 25),
      );
    });
  });
}
