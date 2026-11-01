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
  late Directory tempDirectory;
  late FlowStateDatabase database;
  late BackupService backup;

  setUp(() {
    tempDirectory = Directory.systemTemp.createTempSync('flowstate-backup');
    database = FlowStateDatabase.forTesting(NativeDatabase.memory());
    backup = BackupService(
      database,
      backupDirectory: () async => tempDirectory,
    );
  });

  tearDown(() async {
    await database.close();
    if (tempDirectory.existsSync()) tempDirectory.deleteSync(recursive: true);
  });

  Future<void> seed() async {
    final tasks = TasksRepository(database);
    await tasks.create(
      title: 'Backup task',
      description: 'With details',
      priority: 2,
    );
    final task = (await database.select(database.tasks).get()).single;
    await tasks.setCompleted(task, true, now: DateTime(2026, 10, 31, 10));

    final habits = HabitsRepository(database);
    final habitId = await habits.create(name: 'Read', details: 'Before bed');
    await habits.setCompletedOn(
      habitId,
      day: DateTime(2026, 10, 31),
      completed: true,
    );

    await NotesRepository(database).create(
      title: 'Weekly plan',
      content: 'Ship milestone 1C',
      now: DateTime(2026, 10, 31, 9),
    );

    final sessions = FocusSessionsRepository(database);
    await sessions.start(now: DateTime(2026, 10, 31, 8));
    await sessions.finish(now: DateTime(2026, 10, 31, 8, 20));

    await SettingsRepository(database).setDailyFocusGoalMinutes(60);
  }

  test('export contains every table and round-trips through restore', () async {
    await seed();
    final json = await backup.exportJson(now: DateTime(2026, 11, 1));

    final preview = backup.inspect(json);
    expect(preview.schemaVersion, BackupService.supportedSchemaVersion);
    expect(preview.exportedAt, DateTime(2026, 11, 1));
    expect(preview.counts.tasks, 1);
    expect(preview.counts.habits, 1);
    expect(preview.counts.habitCompletions, 1);
    expect(preview.counts.notes, 1);
    // Starting and finishing a session updates a single row.
    expect(preview.counts.focusSessions, 1);

    final document = jsonDecode(json) as Map<String, dynamic>;
    expect(document['format'], BackupService.formatId);
    expect(
      (document['data'] as Map).keys,
      containsAll(<String>[
        'tasks',
        'focusSessions',
        'habits',
        'habitCompletions',
        'notes',
        'preferences',
      ]),
    );

    final fresh = FlowStateDatabase.forTesting(NativeDatabase.memory());
    addTearDown(fresh.close);
    final freshBackup = BackupService(
      fresh,
      backupDirectory: () async => tempDirectory,
    );
    final result = await freshBackup.restore(json, now: DateTime(2026, 11, 1));

    expect(result.counts.tasks, 1);
    expect(result.safetyBackupPath, isNotNull);
    expect(File(result.safetyBackupPath!).existsSync(), isTrue);

    final task = (await fresh.select(fresh.tasks).get()).single;
    expect(task.title, 'Backup task');
    expect(task.description, 'With details');
    expect(task.priority, 2);
    expect(task.isCompleted, isTrue);
    expect(task.completedAt, DateTime(2026, 10, 31, 10));

    final habit = (await fresh.select(fresh.habits).get()).single;
    expect(habit.name, 'Read');
    final completion =
        (await fresh.select(fresh.habitCompletions).get()).single;
    expect(completion.habitId, habit.id);
    expect(completion.completedOn, DateTime(2026, 10, 31));

    final note = (await fresh.select(fresh.notes).get()).single;
    expect(note.title, 'Weekly plan');
    expect(note.content, 'Ship milestone 1C');

    final session = (await fresh.select(fresh.focusSessions).get()).single;
    expect(session.status, 'completed');
    expect(session.durationMillis, const Duration(minutes: 20).inMilliseconds);

    final preference = (await fresh.select(fresh.preferences).get()).single;
    expect(preference.key, SettingsRepository.dailyFocusGoalKey);
    expect(preference.value, '60');
  });

  test('restoring replaces existing rows instead of merging them', () async {
    await seed();
    final json = await backup.exportJson();
    await TasksRepository(database).create(title: 'Only local');

    final result = await backup.restore(json);
    expect(result.counts.tasks, 1);
    final titles = (await database.select(database.tasks).get()).map(
      (task) => task.title,
    );
    expect(titles, ['Backup task']);
  });

  test('invalid files are rejected without changing data', () async {
    await seed();
    final before = await database.select(database.tasks).get();

    expect(
      () => backup.inspect('this is not json'),
      throwsA(isA<BackupException>()),
    );
    expect(() => backup.inspect('[]'), throwsA(isA<BackupException>()));
    expect(
      () => backup.inspect(jsonEncode({'format': 'something-else'})),
      throwsA(isA<BackupException>()),
    );
    expect(
      () => backup.inspect(
        jsonEncode({
          'format': BackupService.formatId,
          'version': 99,
          'schemaVersion': 3,
          'data': {},
        }),
      ),
      throwsA(isA<BackupException>()),
    );
    expect(
      () => backup.inspect(
        jsonEncode({
          'format': BackupService.formatId,
          'version': 1,
          'schemaVersion': 99,
          'data': {},
        }),
      ),
      throwsA(isA<BackupException>()),
    );

    await expectLater(
      backup.restore('{"format": "flowstate-backup"'),
      throwsA(isA<BackupException>()),
    );
    expect(
      await database.select(database.tasks).get(),
      hasLength(before.length),
    );
  });

  test('habit history pointing at a missing habit is rejected', () async {
    final document = {
      'format': BackupService.formatId,
      'version': 1,
      'schemaVersion': 3,
      'exportedAt': DateTime(2026, 11, 1).toIso8601String(),
      'data': {
        'habits': <Object>[],
        'habitCompletions': [
          {
            'id': 1,
            'habitId': 99,
            'completedOn': DateTime(2026, 11, 1).toIso8601String(),
            'createdAt': DateTime(2026, 11, 1).toIso8601String(),
          },
        ],
      },
    };
    expect(
      () => backup.inspect(jsonEncode(document)),
      throwsA(isA<BackupException>()),
    );
  });

  test('a missing optional section is treated as empty', () async {
    final document = {
      'format': BackupService.formatId,
      'version': 1,
      'schemaVersion': 3,
      'exportedAt': DateTime(2026, 11, 1).toIso8601String(),
      'data': {
        'tasks': [
          {
            'id': 1,
            'title': 'Imported',
            'createdAt': DateTime(2026, 11, 1).toIso8601String(),
            'updatedAt': DateTime(2026, 11, 1).toIso8601String(),
          },
        ],
      },
    };
    final preview = backup.inspect(jsonEncode(document));
    expect(preview.counts.tasks, 1);
    expect(preview.counts.notes, 0);

    await backup.restore(jsonEncode(document));
    final task = (await database.select(database.tasks).get()).single;
    expect(task.title, 'Imported');
    expect(task.priority, 0);
  });

  test('resetting deletes every stored row', () async {
    await seed();
    await backup.resetAllData();
    expect(await database.select(database.tasks).get(), isEmpty);
    expect(await database.select(database.focusSessions).get(), isEmpty);
    expect(await database.select(database.habits).get(), isEmpty);
    expect(await database.select(database.habitCompletions).get(), isEmpty);
    expect(await database.select(database.notes).get(), isEmpty);
    expect(await database.select(database.preferences).get(), isEmpty);
  });
}
