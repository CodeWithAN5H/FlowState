import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';

import 'flowstate_database.dart';

/// A user-facing backup problem. The message is safe to show in the UI.
class BackupException implements Exception {
  BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BackupCounts {
  const BackupCounts({
    this.tasks = 0,
    this.focusSessions = 0,
    this.habits = 0,
    this.habitCompletions = 0,
    this.notes = 0,
    this.preferences = 0,
  });

  final int tasks;
  final int focusSessions;
  final int habits;
  final int habitCompletions;
  final int notes;
  final int preferences;

  int get total =>
      tasks + focusSessions + habits + habitCompletions + notes + preferences;

  bool get isEmpty => total == 0;
}

class BackupPreview {
  const BackupPreview({
    required this.exportedAt,
    required this.schemaVersion,
    required this.counts,
  });

  final DateTime? exportedAt;
  final int schemaVersion;
  final BackupCounts counts;
}

class RestoreResult {
  const RestoreResult({required this.counts, this.safetyBackupPath});

  final BackupCounts counts;
  final String? safetyBackupPath;
}

/// Reads and writes a single, versioned JSON document that contains every local
/// row FlowState stores. Restoring always validates the whole document before
/// touching the database, and keeps a safety backup of the current data first.
class BackupService {
  BackupService(this._database, {Future<Directory> Function()? backupDirectory})
    : _backupDirectory = backupDirectory ?? getApplicationSupportDirectory;

  static const formatId = 'flowstate-backup';
  static const formatVersion = 1;
  static const supportedSchemaVersion = 4;

  final FlowStateDatabase _database;
  final Future<Directory> Function() _backupDirectory;

  Future<Map<String, Object?>> snapshot({DateTime? now}) async {
    final tasks = await _database.select(_database.tasks).get();
    final sessions = await _database.select(_database.focusSessions).get();
    final habits = await _database.select(_database.habits).get();
    final completions = await _database
        .select(_database.habitCompletions)
        .get();
    final notes = await _database.select(_database.notes).get();
    final preferences = await _database.select(_database.preferences).get();
    return {
      'format': formatId,
      'version': formatVersion,
      'schemaVersion': supportedSchemaVersion,
      'exportedAt': (now ?? DateTime.now()).toIso8601String(),
      'counts': {
        'tasks': tasks.length,
        'focusSessions': sessions.length,
        'habits': habits.length,
        'habitCompletions': completions.length,
        'notes': notes.length,
        'preferences': preferences.length,
      },
      'data': {
        'tasks': [
          for (final row in tasks)
            {
              'id': row.id,
              'title': row.title,
              'description': row.description,
              'dueAt': row.dueAt?.toIso8601String(),
              'priority': row.priority,
              'isCompleted': row.isCompleted,
              'completedAt': row.completedAt?.toIso8601String(),
              'createdAt': row.createdAt.toIso8601String(),
              'updatedAt': row.updatedAt.toIso8601String(),
              'uuid': row.uuid,
            },
        ],
        'focusSessions': [
          for (final row in sessions)
            {
              'id': row.id,
              'startedAt': row.startedAt.toIso8601String(),
              'endedAt': row.endedAt?.toIso8601String(),
              'durationMillis': row.durationMillis,
              'status': row.status,
              'runningSinceMillis': row.runningSinceMillis,
              'uuid': row.uuid,
            },
        ],
        'habits': [
          for (final row in habits)
            {
              'id': row.id,
              'name': row.name,
              'details': row.details,
              'isArchived': row.isArchived,
              'createdAt': row.createdAt.toIso8601String(),
              'updatedAt': row.updatedAt.toIso8601String(),
              'uuid': row.uuid,
            },
        ],
        'habitCompletions': [
          for (final row in completions)
            {
              'id': row.id,
              'habitId': row.habitId,
              'completedOn': row.completedOn.toIso8601String(),
              'createdAt': row.createdAt.toIso8601String(),
            },
        ],
        'notes': [
          for (final row in notes)
            {
              'id': row.id,
              'title': row.title,
              'content': row.content,
              'createdAt': row.createdAt.toIso8601String(),
              'updatedAt': row.updatedAt.toIso8601String(),
              'uuid': row.uuid,
            },
        ],
        'preferences': [
          for (final row in preferences) {'key': row.key, 'value': row.value},
        ],
      },
    };
  }

  Future<String> exportJson({DateTime? now}) async =>
      const JsonEncoder.withIndent('  ').convert(await snapshot(now: now));

  Future<File> writeBackup(File file, {DateTime? now}) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(await exportJson(now: now));
    return file;
  }

  /// Validates a backup document and summarizes it without changing any data.
  BackupPreview inspect(String source) {
    final data = _parse(source);
    return BackupPreview(
      exportedAt: data.exportedAt,
      schemaVersion: data.schemaVersion,
      counts: data.counts,
    );
  }

  /// Writes a timestamped copy of the current data next to the app support
  /// directory so a replace never happens without a fallback.
  Future<File> saveSafetyBackup({DateTime? now}) async {
    final at = now ?? DateTime.now();
    final directory = Directory('${(await _backupDirectory()).path}/backups');
    final stamp = at
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    return writeBackup(
      File('${directory.path}/flowstate-before-restore-$stamp.json'),
      now: at,
    );
  }

  /// Replaces every local row with the contents of [source].
  ///
  /// There is no merge mode: restore is all-or-nothing so partially restored
  /// data can never be mistaken for a merge.
  Future<RestoreResult> restore(String source, {DateTime? now}) async {
    final data = _parse(source);
    final safety = await saveSafetyBackup(now: now);
    await _database.transaction(() async {
      await _clearLocalData();
      await _database.batch((batch) {
        batch.insertAll(_database.tasks, data.tasks);
        batch.insertAll(_database.focusSessions, data.focusSessions);
        batch.insertAll(_database.habits, data.habits);
        batch.insertAll(_database.habitCompletions, data.habitCompletions);
        batch.insertAll(_database.notes, data.notes);
        batch.insertAll(_database.preferences, data.preferences);
      });
    });
    return RestoreResult(counts: data.counts, safetyBackupPath: safety.path);
  }

  /// Deletes all local rows. Callers must confirm with the user first.
  Future<void> resetAllData() => _database.transaction(_clearLocalData);

  /// Deletes every stored row, including synchronization bookkeeping.
  ///
  /// Restore and reset replace the whole local dataset, so queued operations
  /// and remote links for rows that no longer exist would be stale references.
  Future<void> _clearLocalData() async {
    await _database.delete(_database.syncOutbox).go();
    await _database.delete(_database.syncState).go();
    await _database.delete(_database.remoteLinks).go();
    await _database.delete(_database.syncConflicts).go();
    await _database.delete(_database.syncTombstones).go();
    await _database.delete(_database.habitCompletions).go();
    await _database.delete(_database.habits).go();
    await _database.delete(_database.notes).go();
    await _database.delete(_database.focusSessions).go();
    await _database.delete(_database.tasks).go();
    await _database.delete(_database.preferences).go();
  }

  _BackupData _parse(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw BackupException(
        'That file is not valid JSON. Choose a FlowState backup file.',
      );
    }
    if (decoded is! Map) {
      throw BackupException('That backup file has an unexpected structure.');
    }
    final root = decoded.cast<String, Object?>();
    if (root['format'] != formatId) {
      throw BackupException(
        'This is not a FlowState backup file (missing "${root['format']}").',
      );
    }
    final version = _asInt(root, 'version', 'backup');
    if (version != formatVersion) {
      throw BackupException(
        'Backup version $version is not supported by this app version.',
      );
    }
    final schemaVersion = _asInt(root, 'schemaVersion', 'backup');
    if (schemaVersion > supportedSchemaVersion) {
      throw BackupException(
        'This backup was made by a newer FlowState version '
        '(schema $schemaVersion). Update the app before restoring it.',
      );
    }
    final exportedAt = _asDate(root['exportedAt'], 'exportedAt', 'backup');
    final data = root['data'];
    if (data is! Map) {
      throw BackupException('The backup file has no "data" section.');
    }
    final section = data.cast<String, Object?>();
    final habits = [
      for (final row in _rows(section, 'habits'))
        HabitsCompanion.insert(
          id: Value(_asInt(row, 'id', 'habit')),
          name: _asString(row, 'name', 'habit'),
          details: Value(_asOptionalString(row, 'details', 'habit')),
          isArchived: Value(row['isArchived'] == true),
          createdAt:
              _asDate(row['createdAt'], 'createdAt', 'habit') ?? DateTime.now(),
          updatedAt:
              _asDate(row['updatedAt'], 'updatedAt', 'habit') ?? DateTime.now(),
          uuid: _optionalUuid(row, 'habit'),
        ),
    ];
    final habitIds = {for (final habit in habits) habit.id.value};
    final completions = [
      for (final row in _rows(section, 'habitCompletions'))
        _completion(row, habitIds),
    ];
    final tasks = [
      for (final row in _rows(section, 'tasks'))
        TasksCompanion.insert(
          id: Value(_asInt(row, 'id', 'task')),
          title: _asString(row, 'title', 'task'),
          description: Value(_asOptionalString(row, 'description', 'task')),
          dueAt: Value(_asDate(row['dueAt'], 'dueAt', 'task')),
          priority: Value((row['priority'] as num?)?.toInt() ?? 0),
          isCompleted: Value(row['isCompleted'] == true),
          completedAt: Value(
            _asDate(row['completedAt'], 'completedAt', 'task'),
          ),
          createdAt:
              _asDate(row['createdAt'], 'createdAt', 'task') ?? DateTime.now(),
          updatedAt:
              _asDate(row['updatedAt'], 'updatedAt', 'task') ?? DateTime.now(),
          uuid: _optionalUuid(row, 'task'),
        ),
    ];
    final sessions = [
      for (final row in _rows(section, 'focusSessions'))
        FocusSessionsCompanion.insert(
          id: Value(_asInt(row, 'id', 'session')),
          startedAt: _asDateRequired(row['startedAt'], 'startedAt', 'session'),
          endedAt: Value(_asDate(row['endedAt'], 'endedAt', 'session')),
          durationMillis: Value((row['durationMillis'] as num?)?.toInt() ?? 0),
          status: _asString(row, 'status', 'session'),
          runningSinceMillis: Value(
            (row['runningSinceMillis'] as num?)?.toInt(),
          ),
          uuid: _optionalUuid(row, 'session'),
        ),
    ];
    final notes = [
      for (final row in _rows(section, 'notes'))
        NotesCompanion.insert(
          id: Value(_asInt(row, 'id', 'note')),
          title: _asString(row, 'title', 'note'),
          content: row['content'] as String? ?? '',
          createdAt:
              _asDate(row['createdAt'], 'createdAt', 'note') ?? DateTime.now(),
          updatedAt:
              _asDate(row['updatedAt'], 'updatedAt', 'note') ?? DateTime.now(),
          uuid: _optionalUuid(row, 'note'),
        ),
    ];
    final preferences = [
      for (final row in _rows(section, 'preferences'))
        PreferencesCompanion.insert(
          key: _asString(row, 'key', 'preference'),
          value: row['value'] as String? ?? '',
        ),
    ];
    return _BackupData(
      exportedAt: exportedAt,
      schemaVersion: schemaVersion,
      tasks: tasks,
      focusSessions: sessions,
      habits: habits,
      habitCompletions: completions,
      notes: notes,
      preferences: preferences,
    );
  }

  /// Backup documents written before schema v4 have no uuid; leaving the
  /// value absent lets the column's client default mint a fresh one.
  static Value<String> _optionalUuid(Map<String, Object?> row, String section) {
    final value = row['uuid'];
    if (value == null) return const Value.absent();
    if (value is String && value.isNotEmpty) return Value(value);
    throw BackupException('Backup $section has an invalid "uuid".');
  }

  HabitCompletionsCompanion _completion(
    Map<String, Object?> row,
    Set<int?> habitIds,
  ) {
    final habitId = _asInt(row, 'habitId', 'habit completion');
    if (!habitIds.contains(habitId)) {
      throw BackupException(
        'Habit history in this backup refers to a habit that is not included.',
      );
    }
    return HabitCompletionsCompanion.insert(
      id: Value(_asInt(row, 'id', 'habit completion')),
      habitId: habitId,
      completedOn: _asDateRequired(
        row['completedOn'],
        'completedOn',
        'habit completion',
      ),
      createdAt:
          _asDate(row['createdAt'], 'createdAt', 'habit completion') ??
          DateTime.now(),
    );
  }

  static List<Map<String, Object?>> _rows(
    Map<String, Object?> section,
    String key,
  ) {
    final value = section[key];
    if (value == null) return const [];
    if (value is! List) {
      throw BackupException('The backup "$key" section is not a list.');
    }
    return [
      for (var index = 0; index < value.length; index++)
        if (value[index] is Map)
          (value[index] as Map).cast<String, Object?>()
        else
          throw BackupException('Backup $key entry #${index + 1} is invalid.'),
    ];
  }

  static int _asInt(Map<String, Object?> row, String key, String section) {
    final value = row[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    throw BackupException('Backup $section is missing a numeric "$key".');
  }

  static String _asString(
    Map<String, Object?> row,
    String key,
    String section,
  ) {
    final value = row[key];
    if (value is String && value.isNotEmpty) return value;
    throw BackupException('Backup $section is missing text "$key".');
  }

  static String? _asOptionalString(
    Map<String, Object?> row,
    String key,
    String section,
  ) {
    final value = row[key];
    if (value == null) return null;
    if (value is String) return value;
    throw BackupException('Backup $section has an invalid "$key".');
  }

  static DateTime? _asDate(Object? value, String key, String section) {
    if (value == null) return null;
    if (value is! String) {
      throw BackupException('Backup $section has an invalid date "$key".');
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      throw BackupException('Backup $section has an invalid date "$key".');
    }
    return parsed;
  }

  static DateTime _asDateRequired(Object? value, String key, String section) =>
      _asDate(value, key, section) ??
      (throw BackupException('Backup $section is missing date "$key".'));
}

class _BackupData {
  const _BackupData({
    required this.exportedAt,
    required this.schemaVersion,
    required this.tasks,
    required this.focusSessions,
    required this.habits,
    required this.habitCompletions,
    required this.notes,
    required this.preferences,
  });

  final DateTime? exportedAt;
  final int schemaVersion;
  final List<TasksCompanion> tasks;
  final List<FocusSessionsCompanion> focusSessions;
  final List<HabitsCompanion> habits;
  final List<HabitCompletionsCompanion> habitCompletions;
  final List<NotesCompanion> notes;
  final List<PreferencesCompanion> preferences;

  BackupCounts get counts => BackupCounts(
    tasks: tasks.length,
    focusSessions: focusSessions.length,
    habits: habits.length,
    habitCompletions: habitCompletions.length,
    notes: notes.length,
    preferences: preferences.length,
  );
}
