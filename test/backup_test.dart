import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flowstate/data/backup_service.dart';
import 'package:flowstate/data/flowstate_database.dart';
import 'package:flowstate/data/focus_sessions_repository.dart';
import 'package:flowstate/data/habits_repository.dart';
import 'package:flowstate/data/notes_repository.dart';
import 'package:flowstate/data/settings_repository.dart';
import 'package:flowstate/data/tasks_repository.dart';

void main() {
  late FlowStateDatabase database;
  late BackupService backup;
  late TasksRepository tasks;
  late FocusSessionsRepository sessions;
  late HabitsRepository habits;
  late NotesRepository notes;
  late SettingsRepository settings;

  final now = DateTime(2026, 10, 30, 12);

  setUp(() {
    database = FlowStateDatabase.forTesting(NativeDatabase.memory());
    backup = BackupService(database);
    tasks = TasksRepository(database);
    sessions = FocusSessionsRepository(database);
    habits = HabitsRepository(database);
    notes = NotesRepository(database);
    settings = SettingsRepository(database);
  });

  tearDown(() async => database.close());

  Future<void> seed({int taskOffset = 0}) async {
    await tasks.create(
      title: 'Plan the week',
      description: 'Three priorities',
      dueAt: now.add(Duration(days: taskOffset)),
      priority: 2,
      now: now,
    );
    await tasks.create(title: 'Empty description', now: now);
    final allTasks = await database.select(database.tasks).get();
    await tasks.setCompleted(allTasks.first, true, now: now);

    await sessions.start(now: now.subtract(const Duration(hours: 2)));
    await sessions.finish(
      now: now.subtract(const Duration(hours: 1, minutes: 30)),
    );
    await sessions.start(now: now.subtract(const Duration(minutes: 10)));

    final habitId = await habits.create(
      name: 'Read 20 pages',
      description: 'Before bed',
      now: now,
    );
    await habits.setCompletedOn(
      habitId,
      now.subtract(const Duration(days: 1)),
      true,
      now: now,
    );
    await habits.setCompletedOn(habitId, now, true, now: now);
    await habits.create(name: 'Walk', now: now);

    await notes.create(
      title: 'Weekly plan',
      content: '# Focus\n\n- habits\n- notes',
      now: now,
    );
    await notes.create(title: 'Scratch', content: '', now: now);

    await settings.setTheme(AppTheme.light);
    await settings.setWeekStart(WeekStart.sunday);
    await settings.setDailyFocusGoalMinutes(90);
  }

  Map<String, Object?> decode(String json) =>
      jsonDecode(json) as Map<String, Object?>;

  test('exports every stored table with versioned metadata', () async {
    await seed();
    final document = decode(await backup.exportJson(now: now));

    expect(document['format'], 'flowstate-backup');
    expect(document['version'], 1);
    expect(document['schemaVersion'], 3);
    expect(document['exportedAt'], now.toIso8601String());
    expect(document['tasks'], hasLength(2));
    expect(document['focusSessions'], hasLength(2));
    expect(document['habits'], hasLength(2));
    expect(document['habitCompletions'], hasLength(2));
    expect(document['notes'], hasLength(2));
    expect(document['preferences'], {
      'theme': 'light',
      'weekStart': 'sunday',
      'dailyFocusGoalMinutes': '90',
    });

    final task = (document['tasks']! as List).first as Map<String, Object?>;
    expect(task['title'], 'Plan the week');
    expect(task['isCompleted'], isTrue);
    expect(task['dueAt'], now.toIso8601String());
    final habit = (document['habits']! as List).first as Map<String, Object?>;
    expect(habit['name'], 'Read 20 pages');
  });

  test(
    'restores an exported backup exactly, including open sessions',
    () async {
      await seed();
      final exported = await backup.exportJson(now: now);
      final original = await backup.snapshot(now: now);

      await backup.resetAllData();
      expect(await database.select(database.tasks).get(), isEmpty);
      expect(await database.select(database.preferences).get(), isEmpty);

      final result = await backup.importJson(exported);
      expect(result.counts.tasks, 2);
      expect(result.counts.focusSessions, 2);
      expect(result.counts.habits, 2);
      expect(result.counts.habitCompletions, 2);
      expect(result.counts.notes, 2);
      expect(result.counts.preferences, 3);
      expect(result.safetyBackupPath, isNull);

      final restored = await backup.snapshot(now: now);
      expect(restored, original);

      // The restored running session still recovers with its elapsed time.
      final recovered = await sessions.recover(
        now: now.add(const Duration(minutes: 5)),
      );
      expect(recovered, isNotNull);
      expect(recovered!.elapsed, const Duration(minutes: 15));
      expect(recovered.isRunning, isTrue);
      expect(
        await habits.currentStreak(
          (await habits.summaries(today: now, weekStart: WeekStart.sunday))
              .firstWhere((summary) => summary.habit.name == 'Read 20 pages')
              .habit
              .id,
          today: now,
        ),
        2,
      );
    },
  );

  test('writes a safety backup of existing data before replacing it', () async {
    await tasks.create(title: 'Old task', now: now);
    final directory = await Directory.systemTemp.createTemp('flowstate-test-');
    addTearDown(() => directory.delete(recursive: true));
    final safetyFile = File('${directory.path}/before-restore.json');

    await seed(taskOffset: 3);
    final incoming = await backup.exportJson(now: now);
    await backup.resetAllData();
    await tasks.create(title: 'Only before restore', now: now);

    final result = await backup.importJson(
      incoming,
      safetyBackupFile: safetyFile,
    );
    expect(result.safetyBackupPath, safetyFile.path);
    final safety = decode(await safetyFile.readAsString());
    final safetyTasks = safety['tasks']! as List;
    expect(safetyTasks, hasLength(1));
    expect(
      (safetyTasks.single as Map<String, Object?>)['title'],
      'Only before restore',
    );

    final titles = (await database.select(database.tasks).get())
        .map((task) => task.title)
        .toSet();
    expect(titles, contains('Plan the week'));
    expect(titles, isNot(contains('Only before restore')));
  });

  test('rejects invalid or incompatible files without touching data', () async {
    await seed();
    final before = await backup.snapshot(now: now);
    final valid = await backup.snapshot(now: now);

    Future<void> expectRejected(String source, Matcher message) async {
      await expectLater(
        backup.importJson(source),
        throwsA(
          isA<BackupException>().having((e) => e.message, 'message', message),
        ),
      );
      expect(await backup.snapshot(now: now), before);
    }

    await expectRejected('not json at all', contains('not valid JSON'));
    await expectRejected('[]', contains('backup object'));
    await expectRejected(
      jsonEncode({'format': 'other-app', 'version': 1}),
      contains('not a FlowState backup'),
    );
    await expectRejected(
      jsonEncode({...valid, 'version': 2}),
      contains('Unsupported backup version 2'),
    );
    await expectRejected(
      jsonEncode({...valid, 'schemaVersion': 99}),
      contains('newer version of FlowState'),
    );
    await expectRejected(
      jsonEncode({...valid, 'tasks': 'nope'}),
      contains('must be a list'),
    );

    final missingTitle = [
      for (final task in valid['tasks']! as List)
        if ((task as Map)['title'] != 'Plan the week') task,
      {
        ...(valid['tasks']! as List).first as Map<String, Object?>,
        'title': null,
      },
    ];
    await expectRejected(
      jsonEncode({...valid, 'tasks': missingTitle}),
      contains('missing a valid "title"'),
    );

    final tasksList = [
      for (final task in valid['tasks']! as List)
        Map<String, Object?>.from(task as Map),
    ];
    await expectRejected(
      jsonEncode({
        ...valid,
        'tasks': [tasksList.first, tasksList.first],
      }),
      contains('duplicate task id'),
    );

    final habitsList = [
      for (final habit in valid['habits']! as List)
        Map<String, Object?>.from(habit as Map),
    ];
    await expectRejected(
      jsonEncode({
        ...valid,
        'habitCompletions': [
          {
            'id': 1,
            'habitId': 999,
            'completedOn': now.toIso8601String(),
            'createdAt': now.toIso8601String(),
          },
        ],
      }),
      contains('which is not in the backup'),
    );

    await expectRejected(
      jsonEncode({
        ...valid,
        'habitCompletions': [
          for (final completion in valid['habitCompletions']! as List)
            Map<String, Object?>.from(completion as Map),
          {
            'id': 99,
            'habitId': habitsList.first['id'],
            'completedOn':
                ((valid['habitCompletions']! as List).first
                    as Map<String, Object?>)['completedOn'],
            'createdAt': now.toIso8601String(),
          },
        ],
      }),
      contains('same day recorded twice'),
    );

    await expectRejected(
      jsonEncode({
        ...valid,
        'focusSessions': [
          {
            'id': 1,
            'startedAt': now.toIso8601String(),
            'durationMillis': 1000,
            'status': 'paused',
          },
        ],
      }),
      contains('unknown status'),
    );

    await expectRejected(
      jsonEncode({
        ...valid,
        'notes': [
          {
            'id': 1,
            'title': 'Note',
            'content': 'body',
            'createdAt': 'yesterday',
            'updatedAt': now.toIso8601String(),
          },
        ],
      }),
      contains('missing a valid "createdAt"'),
    );

    await expectRejected(
      jsonEncode({
        ...valid,
        'preferences': {'theme': 4},
      }),
      contains('stored as text'),
    );
  });

  test(
    'accepts epoch millisecond timestamps and missing collections',
    () async {
      final minimal = jsonEncode({
        'format': 'flowstate-backup',
        'version': 1,
        'schemaVersion': 2,
        'tasks': [
          {
            'id': 7,
            'title': 'Imported',
            'priority': -4,
            'isCompleted': false,
            'createdAt': now.millisecondsSinceEpoch,
            'updatedAt': now.millisecondsSinceEpoch,
          },
        ],
      });

      final result = await backup.importJson(minimal);
      expect(result.counts.tasks, 1);
      expect(result.counts.notes, 0);
      final task = (await database.select(database.tasks).get()).single;
      expect(task.id, 7);
      expect(task.title, 'Imported');
      expect(task.priority, 0);
      expect(task.createdAt, now);
      expect(await database.select(database.notes).get(), isEmpty);
    },
  );

  test('reset clears every table and the database stays usable', () async {
    await seed();
    await backup.resetAllData();
    final snapshot = await backup.snapshot(now: now);
    for (final key in [
      'tasks',
      'focusSessions',
      'habits',
      'habitCompletions',
      'notes',
    ]) {
      expect(snapshot[key], isEmpty, reason: key);
    }
    expect(snapshot['preferences'], isEmpty);

    await tasks.create(title: 'After reset', now: now);
    expect(
      (await database.select(database.tasks).get()).single.title,
      'After reset',
    );
    final defaults = await settings.load();
    expect(defaults.theme, AppTheme.dark);
    expect(defaults.weekStart, WeekStart.monday);
    expect(defaults.dailyFocusGoalMinutes, 120);
  });
}
