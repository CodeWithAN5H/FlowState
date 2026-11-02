import 'dart:io';

// `isNotNull` is also a matcher in flutter_test; only OrderingTerm and Value are
// needed here.
import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:flowstate/data/flowstate_database.dart';
import 'package:flowstate/data/focus_sessions_repository.dart';
import 'package:flowstate/data/habits_repository.dart';
import 'package:flowstate/data/ids.dart';
import 'package:flowstate/data/notes_repository.dart';
import 'package:flowstate/data/tasks_repository.dart';

File _tempDatabaseFile() => File(
  '${Directory.systemTemp.path}/flowstate-v4-'
  '${DateTime.now().microsecondsSinceEpoch}.sqlite',
);

/// Drift stores `dateTime()` columns as whole seconds by default.
int _seconds(DateTime value) =>
    DateTime(
      value.year,
      value.month,
      value.day,
      value.hour,
      value.minute,
      value.second,
    ).millisecondsSinceEpoch ~/
    Duration.millisecondsPerSecond;

/// Builds a database that is byte-for-byte what schema v3 produced: no uuid
/// columns, no synchronization tables, and one row in every table so a migration
/// has something real to preserve.
sqlite.Database _createV3Database(File file) {
  final legacy = sqlite.sqlite3.open(file.path);
  legacy.execute('''
    CREATE TABLE tasks (
      id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      description TEXT,
      due_at INTEGER,
      priority INTEGER NOT NULL DEFAULT 0,
      is_completed INTEGER NOT NULL DEFAULT 0,
      completed_at INTEGER,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''');
  legacy.execute('''
    CREATE TABLE focus_sessions (
      id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
      started_at INTEGER NOT NULL,
      ended_at INTEGER,
      duration_millis INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL,
      running_since_millis INTEGER
    )
  ''');
  legacy.execute('''
    CREATE TABLE habits (
      id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      details TEXT,
      is_archived INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''');
  legacy.execute('''
    CREATE TABLE habit_completions (
      id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
      habit_id INTEGER NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
      completed_on INTEGER NOT NULL,
      created_at INTEGER NOT NULL,
      UNIQUE (habit_id, completed_on)
    )
  ''');
  legacy.execute('''
    CREATE TABLE notes (
      id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      content TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''');
  legacy.execute('''
    CREATE TABLE preferences (
      key TEXT NOT NULL PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''');

  final created = DateTime(2026, 10, 20, 8, 30);
  legacy.execute(
    'INSERT INTO tasks (title, description, due_at, priority, is_completed, '
    'completed_at, created_at, updated_at) VALUES (?, ?, ?, 2, 1, ?, ?, ?)',
    [
      'Legacy task',
      'Written before v4',
      _seconds(DateTime(2026, 10, 21, 9)),
      _seconds(DateTime(2026, 10, 21, 10)),
      _seconds(created),
      _seconds(DateTime(2026, 10, 21, 10)),
    ],
  );
  legacy.execute(
    'INSERT INTO tasks (title, priority, is_completed, created_at, updated_at) '
    'VALUES (?, 0, 0, ?, ?)',
    ['Second legacy task', _seconds(created), _seconds(created)],
  );
  legacy.execute(
    'INSERT INTO focus_sessions (started_at, ended_at, duration_millis, status) '
    'VALUES (?, ?, 12000, ?)',
    [
      _seconds(DateTime(2026, 10, 22, 7)),
      _seconds(DateTime(2026, 10, 22, 7, 0, 12)),
      'completed',
    ],
  );
  legacy.execute(
    'INSERT INTO habits (name, details, is_archived, created_at, updated_at) '
    'VALUES (?, ?, 0, ?, ?)',
    ['Walk', 'Twenty minutes', _seconds(created), _seconds(created)],
  );
  legacy.execute(
    'INSERT INTO habit_completions (habit_id, completed_on, created_at) '
    'VALUES (1, ?, ?)',
    [_seconds(DateTime(2026, 10, 23)), _seconds(created)],
  );
  legacy.execute(
    'INSERT INTO notes (title, content, created_at, updated_at) '
    'VALUES (?, ?, ?, ?)',
    ['Weekly plan', 'Ship milestone 2B', _seconds(created), _seconds(created)],
  );
  legacy.execute(
    "INSERT INTO preferences (key, value) VALUES ('weekStart', 'monday')",
  );
  legacy.userVersion = 3;
  return legacy;
}

Future<int> _userVersion(FlowStateDatabase database) async =>
    (await database.customSelect('PRAGMA user_version').getSingle()).read<int>(
      'user_version',
    );

void main() {
  test(
    'v3 migrates to v4 keeping every row, relation and preference',
    () async {
      final file = _tempDatabaseFile();
      _createV3Database(file).close();

      final database = FlowStateDatabase.forTesting(NativeDatabase(file));
      try {
        expect(await _userVersion(database), 4);

        final tasks = await (database.select(
          database.tasks,
        )..orderBy([(row) => OrderingTerm.asc(row.id)])).get();
        expect(tasks.map((task) => task.title), [
          'Legacy task',
          'Second legacy task',
        ]);
        expect(tasks.first.description, 'Written before v4');
        expect(tasks.first.priority, 2);
        expect(tasks.first.isCompleted, isTrue);
        expect(tasks.first.completedAt, DateTime(2026, 10, 21, 10));
        expect(tasks.first.createdAt, DateTime(2026, 10, 20, 8, 30));

        final session =
            (await database.select(database.focusSessions).get()).single;
        expect(session.durationMillis, 12000);
        expect(session.status, 'completed');
        expect(session.startedAt, DateTime(2026, 10, 22, 7));
        expect(session.endedAt, DateTime(2026, 10, 22, 7, 0, 12));

        final habit = (await database.select(database.habits).get()).single;
        expect(habit.name, 'Walk');
        expect(habit.details, 'Twenty minutes');
        expect(habit.isArchived, isFalse);

        // The relation between a habit and its history survives the migration.
        final completion =
            (await database.select(database.habitCompletions).get()).single;
        expect(completion.habitId, habit.id);
        expect(completion.completedOn, DateTime(2026, 10, 23));
        expect(await HabitsRepository(database).history(habit.id), [
          DateTime(2026, 10, 23),
        ]);

        final note = (await database.select(database.notes).get()).single;
        expect(note.title, 'Weekly plan');
        expect(note.content, 'Ship milestone 2B');

        final preferences = await database.select(database.preferences).get();
        expect(preferences.single.key, 'weekStart');
        expect(preferences.single.value, 'monday');

        // The synchronization tables exist and start empty.
        expect(await database.select(database.syncOutbox).get(), isEmpty);
        expect(await database.select(database.syncState).get(), isEmpty);
        expect(await database.select(database.remoteLinks).get(), isEmpty);
        expect(await database.select(database.syncConflicts).get(), isEmpty);
        expect(await database.select(database.syncTombstones).get(), isEmpty);
      } finally {
        await database.close();
        if (file.existsSync()) file.deleteSync();
      }
    },
  );

  test('every migrated row gets a unique, valid, stable UUID', () async {
    final file = _tempDatabaseFile();
    _createV3Database(file).close();

    final first = FlowStateDatabase.forTesting(NativeDatabase(file));
    final assigned = <String, List<String>>{};
    try {
      assigned['tasks'] = [
        for (final row in await first.select(first.tasks).get()) row.uuid!,
      ];
      assigned['habits'] = [
        for (final row in await first.select(first.habits).get()) row.uuid!,
      ];
      assigned['notes'] = [
        for (final row in await first.select(first.notes).get()) row.uuid!,
      ];
      assigned['focusSessions'] = [
        for (final row in await first.select(first.focusSessions).get())
          row.uuid!,
      ];

      final all = [for (final ids in assigned.values) ...ids];
      expect(all, hasLength(5));
      expect(
        all.toSet(),
        hasLength(all.length),
        reason: 'UUIDs must be unique',
      );
      for (final uuid in all) {
        expect(isUuidV4(uuid), isTrue, reason: '$uuid must be a v4 UUID');
      }
      expect(assigned['tasks'], hasLength(2));
    } finally {
      await first.close();
    }

    // Restarting must not re-mint identifiers: they are the sync identity.
    final reopened = FlowStateDatabase.forTesting(NativeDatabase(file));
    try {
      expect([
        for (final row in await reopened.select(reopened.tasks).get()) row.uuid,
      ], assigned['tasks']);
      expect([
        for (final row in await reopened.select(reopened.habits).get())
          row.uuid,
      ], assigned['habits']);
      expect([
        for (final row in await reopened.select(reopened.notes).get()) row.uuid,
      ], assigned['notes']);
      expect([
        for (final row in await reopened.select(reopened.focusSessions).get())
          row.uuid,
      ], assigned['focusSessions']);
    } finally {
      await reopened.close();
      if (file.existsSync()) file.deleteSync();
    }
  });

  test(
    'new records receive their own UUIDs, and duplicates are rejected',
    () async {
      final database = FlowStateDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);

      final tasks = TasksRepository(database);
      final habits = HabitsRepository(database);
      final notes = NotesRepository(database);
      final sessions = FocusSessionsRepository(database);

      final taskId = await tasks.create(title: 'New task');
      final habitId = await habits.create(name: 'New habit');
      final noteId = await notes.create(title: '', content: 'Body');
      await sessions.start();
      final sessionId =
          (await database.select(database.focusSessions).get()).single.id;

      final uuids = {
        'task': (await tasks.todayTasks(DateTime.now()))
            .singleWhere((row) => row.id == taskId)
            .uuid,
        'habit': (await database.select(database.habits).get())
            .singleWhere((row) => row.id == habitId)
            .uuid,
        'note': (await database.select(database.notes).get())
            .singleWhere((row) => row.id == noteId)
            .uuid,
        'session': (await database.select(database.focusSessions).get())
            .singleWhere((row) => row.id == sessionId)
            .uuid,
      };
      for (final entry in uuids.entries) {
        expect(entry.value, isNotNull);
        expect(isUuidV4(entry.value!), isTrue, reason: '${entry.key} uuid');
      }
      expect(uuids.values.toSet(), hasLength(4));

      // The database, not only the Dart code, refuses a repeated identifier.
      final stored = (await database.select(database.tasks).get()).single;
      await expectLater(
        (database.update(database.tasks)
              ..where((row) => row.id.equals(stored.id)))
            .write(TasksCompanion(uuid: Value(stored.uuid))),
        completes,
      );
      final secondId = await tasks.create(title: 'Another task');
      await expectLater(
        (database.update(database.tasks)
              ..where((row) => row.id.equals(secondId)))
            .write(TasksCompanion(uuid: Value(stored.uuid!))),
        throwsA(anything),
      );
    },
  );

  test('the v4 migration is additive for a v2 database', () async {
    final file = _tempDatabaseFile();
    final legacy = sqlite.sqlite3.open(file.path);
    legacy.execute('''
      CREATE TABLE tasks (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        description TEXT,
        due_at INTEGER,
        priority INTEGER NOT NULL DEFAULT 0,
        is_completed INTEGER NOT NULL DEFAULT 0,
        completed_at INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    legacy.execute('''
      CREATE TABLE focus_sessions (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        started_at INTEGER NOT NULL,
        ended_at INTEGER,
        duration_millis INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL,
        running_since_millis INTEGER
      )
    ''');
    final created = DateTime(2026, 10, 25, 12);
    legacy.execute(
      'INSERT INTO tasks (title, created_at, updated_at) VALUES (?, ?, ?)',
      ['From v2', _seconds(created), _seconds(created)],
    );
    legacy.userVersion = 2;
    legacy.close();

    final database = FlowStateDatabase.forTesting(NativeDatabase(file));
    try {
      expect(await _userVersion(database), 4);
      final task = (await database.select(database.tasks).get()).single;
      expect(task.title, 'From v2');
      expect(task.uuid, isNotNull);
      expect(isUuidV4(task.uuid!), isTrue);
      // v3 tables arrived with the same upgrade.
      expect(await database.select(database.habits).get(), isEmpty);
      expect(await database.select(database.preferences).get(), isEmpty);
    } finally {
      await database.close();
      if (file.existsSync()) file.deleteSync();
    }
  });
}
