import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flowstate/data/flowstate_database.dart';
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
        2,
      );
    } finally {
      await database.close();
      if (file.existsSync()) file.deleteSync();
    }
  });
}
