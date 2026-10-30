import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flowstate/data/flowstate_database.dart';
import 'package:flowstate/data/habits_repository.dart';
import 'package:flowstate/data/notes_repository.dart';
import 'package:flowstate/data/settings_repository.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:drift/native.dart';

void main() {
  test('migrates v1 rows and adds v2 task and recovery columns', () async {
    final file = File(
      '${Directory.systemTemp.path}/flowstate-migration-${DateTime.now().microsecondsSinceEpoch}.sqlite',
    );
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
      expect(
        await database
            .customSelect('PRAGMA user_version')
            .getSingle()
            .then((row) => row.read<int>('user_version')),
        3,
      );
    } finally {
      await database.close();
      if (file.existsSync()) file.deleteSync();
    }
  });

  test('migrates v2 data and creates habit, note and preference tables', () async {
    final file = File(
      '${Directory.systemTemp.path}/flowstate-migration-v2-${DateTime.now().microsecondsSinceEpoch}.sqlite',
    );
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
    final createdAt = DateTime(2026, 10, 29).millisecondsSinceEpoch ~/ 1000;
    legacy.execute(
      'INSERT INTO tasks (title, priority, is_completed, created_at, updated_at) VALUES (?, 1, 0, ?, ?)',
      ['Task from v2', createdAt, createdAt],
    );
    legacy.execute(
      'INSERT INTO focus_sessions (started_at, ended_at, duration_millis, status) VALUES (?, ?, 600000, ?)',
      [createdAt, createdAt + 600, 'completed'],
    );
    legacy.userVersion = 2;
    legacy.close();

    final database = FlowStateDatabase.forTesting(NativeDatabase(file));
    try {
      final tasks = await database.select(database.tasks).get();
      final sessions = await database.select(database.focusSessions).get();
      expect(tasks.single.title, 'Task from v2');
      expect(tasks.single.priority, 1);
      expect(sessions.single.durationMillis, 600000);

      final habitId = await HabitsRepository(database)
          .create(name: 'Migrated habit');
      await HabitsRepository(database)
          .setCompletedOn(habitId, DateTime(2026, 10, 30), true);
      await NotesRepository(database).create(title: 'Migrated note');
      await SettingsRepository(database).setTheme(AppTheme.light);

      expect(
        await database.select(database.habitCompletions).get(),
        hasLength(1),
      );
      expect(await database.select(database.notes).get(), hasLength(1));
      expect((await SettingsRepository(database).load()).theme, AppTheme.light);
      expect(
        await database
            .customSelect('PRAGMA user_version')
            .getSingle()
            .then((row) => row.read<int>('user_version')),
        3,
      );
    } finally {
      await database.close();
      if (file.existsSync()) file.deleteSync();
    }
  });
}
