import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowstate/data/flowstate_database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

File _tempDatabaseFile() => File(
  '${Directory.systemTemp.path}/flowstate-migration-${DateTime.now().microsecondsSinceEpoch}.sqlite',
);

void main() {
  test('migrates v1 rows, adds v2 columns, and creates v3 tables', () async {
    final file = _tempDatabaseFile();
    final legacy = sqlite.sqlite3.open(file.path);
    legacy.execute('''
      CREATE TABLE tasks (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        is_completed INTEGER NOT NULL DEFAULT 0,
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
        status TEXT NOT NULL
      )
    ''');
    final createdAt = DateTime(2026, 10, 29).millisecondsSinceEpoch;
    legacy.execute(
      'INSERT INTO tasks (title, is_completed, created_at, updated_at) VALUES (?, 0, ?, ?)',
      ['Legacy task', createdAt, createdAt],
    );
    legacy.execute(
      'INSERT INTO focus_sessions (started_at, duration_millis, status) VALUES (?, 12000, ?)',
      [createdAt, 'completed'],
    );
    legacy.userVersion = 1;
    legacy.close();

    final database = FlowStateDatabase.forTesting(NativeDatabase(file));
    try {
      final tasks = await database.select(database.tasks).get();
      final sessions = await database.select(database.focusSessions).get();
      expect(tasks.single.title, 'Legacy task');
      expect(tasks.single.priority, 0);
      expect(tasks.single.description, isNull);
      expect(sessions.single.durationMillis, 12000);
      expect(sessions.single.runningSinceMillis, isNull);

      // The new 1C tables exist and are empty rather than missing.
      expect(await database.select(database.habits).get(), isEmpty);
      expect(await database.select(database.habitCompletions).get(), isEmpty);
      expect(await database.select(database.notes).get(), isEmpty);
      expect(await database.select(database.preferences).get(), isEmpty);

      final version = await database
          .customSelect('PRAGMA user_version')
          .getSingle()
          .then((row) => row.read<int>('user_version'));
      expect(version, 4);
    } finally {
      await database.close();
      if (file.existsSync()) file.deleteSync();
    }
  });

  test('migrates a v2 database to v3 without touching its rows', () async {
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
    final createdDate = DateTime(2026, 10, 30);
    final createdAt = createdDate.millisecondsSinceEpoch;
    legacy.execute(
      'INSERT INTO tasks (title, description, priority, created_at, updated_at) '
      'VALUES (?, ?, 2, ?, ?)',
      ['Keep me', 'v2 row', createdAt, createdAt],
    );
    legacy.userVersion = 2;
    legacy.close();

    final database = FlowStateDatabase.forTesting(NativeDatabase(file));
    try {
      final task = (await database.select(database.tasks).get()).single;
      expect(task.title, 'Keep me');
      expect(task.description, 'v2 row');
      expect(task.priority, 2);

      // A v3 table is usable after upgrade, and habit history cascades.
      final habitId = await database
          .into(database.habits)
          .insert(
            HabitsCompanion.insert(
              name: 'Walk',
              createdAt: createdDate,
              updatedAt: createdDate,
            ),
          );
      await database
          .into(database.habitCompletions)
          .insert(
            HabitCompletionsCompanion.insert(
              habitId: habitId,
              completedOn: DateTime(2026, 10, 30),
              createdAt: createdDate,
            ),
          );
      await (database.delete(
        database.habits,
      )..where((row) => row.id.equals(habitId))).go();
      expect(await database.select(database.habitCompletions).get(), isEmpty);
    } finally {
      await database.close();
      if (file.existsSync()) file.deleteSync();
    }
  });
}
