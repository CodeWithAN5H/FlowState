import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';

import 'flowstate_database.dart';

/// A backup file that cannot be restored safely. The message is shown to the
/// user, so it explains what is wrong without exposing internals.
class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BackupCounts {
  const BackupCounts({
    required this.tasks,
    required this.focusSessions,
    required this.habits,
    required this.habitCompletions,
    required this.notes,
    required this.preferences,
  });

  final int tasks;
  final int focusSessions;
  final int habits;
  final int habitCompletions;
  final int notes;
  final int preferences;

  int get totalRecords =>
      tasks + focusSessions + habits + habitCompletions + notes;

  @override
  String toString() =>
      '$tasks tasks, $focusSessions focus sessions, $habits habits, '
      '$habitCompletions habit check-ins, $notes notes, $preferences settings';
}

class ImportResult {
  const ImportResult({required this.counts, required this.safetyBackupPath});

  final BackupCounts counts;

  /// Where the pre-restore snapshot was written, when one was requested.
  final String? safetyBackupPath;
}

/// Exports and restores all local data as a versioned JSON document.
///
/// Restoring always replaces the current data, and a snapshot of the existing
/// data is written before anything is deleted. Invalid or incompatible files
/// are rejected before the database is touched.
class BackupService {
  BackupService(this._database);

  final FlowStateDatabase _database;

  static const formatId = 'flowstate-backup';
  static const formatVersion = 1;
  static const supportedSchemaVersion = 3;

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
      'tasks': [for (final task in tasks) _taskToJson(task)],
      'focusSessions': [
        for (final session in sessions) _sessionToJson(session),
      ],
      'habits': [for (final habit in habits) _habitToJson(habit)],
      'habitCompletions': [
        for (final completion in completions) _completionToJson(completion),
      ],
      'notes': [for (final note in notes) _noteToJson(note)],
      'preferences': {
        for (final preference in preferences) preference.key: preference.value,
      },
    };
  }

  Future<String> exportJson({DateTime? now}) async =>
      const JsonEncoder.withIndent('  ').convert(await snapshot(now: now));

  /// Writes a readable backup and returns the file.
  Future<File> writeBackup(File target, {DateTime? now}) async {
    await target.parent.create(recursive: true);
    return target.writeAsString(await exportJson(now: now), flush: true);
  }

  /// Validates [source] completely, snapshots the current data when
  /// [safetyBackupFile] is given, then replaces all local data.
  Future<ImportResult> importJson(
    String source, {
    File? safetyBackupFile,
  }) async {
    final parsed = _parseAndValidate(source);

    String? safetyPath;
    if (safetyBackupFile != null) {
      final written = await writeBackup(safetyBackupFile);
      safetyPath = written.path;
    }

    await _database.transaction(() async {
      await _deleteEverything();
      await _database.batch((batch) {
        batch.insertAll(_database.tasks, parsed.tasks);
        batch.insertAll(_database.focusSessions, parsed.sessions);
        batch.insertAll(_database.habits, parsed.habits);
        batch.insertAll(_database.habitCompletions, parsed.completions);
        batch.insertAll(_database.notes, parsed.notes);
        batch.insertAll(_database.preferences, parsed.preferences);
      });
    });

    return ImportResult(counts: parsed.counts, safetyBackupPath: safetyPath);
  }

  /// Deletes every stored record. Used by the explicit reset action, which
  /// asks the user to confirm first.
  Future<void> resetAllData() => _database.transaction(_deleteEverything);

  Future<void> _deleteEverything() async {
    await _database.delete(_database.habitCompletions).go();
    await _database.delete(_database.habits).go();
    await _database.delete(_database.notes).go();
    await _database.delete(_database.focusSessions).go();
    await _database.delete(_database.tasks).go();
    await _database.delete(_database.preferences).go();
  }

  _ParsedBackup _parseAndValidate(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const BackupException('That file is not valid JSON.');
    }
    if (decoded is! Map<String, Object?>) {
      throw const BackupException(
        'That file does not contain a backup object.',
      );
    }
    if (decoded['format'] != formatId) {
      throw const BackupException(
        'That file is not a FlowState backup (missing format marker).',
      );
    }
    final version = decoded['version'];
    if (version is! int || version != formatVersion) {
      throw BackupException(
        'Unsupported backup version ${version ?? '(missing)'}. '
        'This build restores version $formatVersion backups.',
      );
    }
    final schemaVersion = decoded['schemaVersion'];
    if (schemaVersion is! int) {
      throw const BackupException('The backup is missing its schema version.');
    }
    if (schemaVersion > supportedSchemaVersion) {
      throw BackupException(
        'This backup was made by a newer version of FlowState '
        '(schema $schemaVersion, this build supports $supportedSchemaVersion).',
      );
    }

    final tasks = _list(decoded, 'tasks');
    final sessions = _list(decoded, 'focusSessions');
    final habits = _list(decoded, 'habits');
    final completions = _list(decoded, 'habitCompletions');
    final notes = _list(decoded, 'notes');

    final taskRows = <TasksCompanion>[];
    final usedTaskIds = <int>{};
    for (var index = 0; index < tasks.length; index++) {
      final row = _record(tasks[index], 'tasks[$index]');
      final id = _id(row, 'tasks[$index]');
      _unique(usedTaskIds, id, 'task');
      taskRows.add(
        TasksCompanion(
          id: Value(id),
          title: Value(_string(row, 'title', 'Task $id')),
          description: Value(_optionalString(row, 'description', 'Task $id')),
          dueAt: Value(_optionalDate(row, 'dueAt', 'Task $id')),
          priority: Value(_int(row, 'priority', 'Task $id').clamp(0, 2)),
          isCompleted: Value(_bool(row, 'isCompleted', 'Task $id')),
          completedAt: Value(_optionalDate(row, 'completedAt', 'Task $id')),
          createdAt: Value(_date(row, 'createdAt', 'Task $id')),
          updatedAt: Value(_date(row, 'updatedAt', 'Task $id')),
        ),
      );
    }

    final sessionRows = <FocusSessionsCompanion>[];
    final usedSessionIds = <int>{};
    for (var index = 0; index < sessions.length; index++) {
      final row = _record(sessions[index], 'focusSessions[$index]');
      final id = _id(row, 'focusSessions[$index]');
      _unique(usedSessionIds, id, 'focus session');
      final status = _string(row, 'status', 'Focus session $id');
      if (status != 'active' &&
          status != 'completed' &&
          status != 'interrupted') {
        throw BackupException(
          'Focus session $id has unknown status "$status".',
        );
      }
      final duration = _int(row, 'durationMillis', 'Focus session $id');
      if (duration < 0) {
        throw BackupException('Focus session $id has a negative duration.');
      }
      sessionRows.add(
        FocusSessionsCompanion(
          id: Value(id),
          startedAt: Value(_date(row, 'startedAt', 'Focus session $id')),
          endedAt: Value(_optionalDate(row, 'endedAt', 'Focus session $id')),
          durationMillis: Value(duration),
          status: Value(status),
          runningSinceMillis: Value(
            _optionalInt(row, 'runningSinceMillis', 'Focus session $id'),
          ),
        ),
      );
    }

    final habitRows = <HabitsCompanion>[];
    final habitIds = <int>{};
    for (var index = 0; index < habits.length; index++) {
      final row = _record(habits[index], 'habits[$index]');
      final id = _id(row, 'habits[$index]');
      _unique(habitIds, id, 'habit');
      habitRows.add(
        HabitsCompanion(
          id: Value(id),
          name: Value(_string(row, 'name', 'Habit $id')),
          description: Value(_optionalString(row, 'description', 'Habit $id')),
          isArchived: Value(_bool(row, 'isArchived', 'Habit $id')),
          createdAt: Value(_date(row, 'createdAt', 'Habit $id')),
          updatedAt: Value(_date(row, 'updatedAt', 'Habit $id')),
        ),
      );
    }

    final completionRows = <HabitCompletionsCompanion>[];
    final usedCompletionIds = <int>{};
    for (var index = 0; index < completions.length; index++) {
      final row = _record(completions[index], 'habitCompletions[$index]');
      final id = _id(row, 'habitCompletions[$index]');
      _unique(usedCompletionIds, id, 'habit check-in');
      final habitId = _int(row, 'habitId', 'Habit check-in $id');
      if (!habitIds.contains(habitId)) {
        throw BackupException(
          'Habit check-in $id refers to habit $habitId, which is not in the backup.',
        );
      }
      completionRows.add(
        HabitCompletionsCompanion(
          id: Value(id),
          habitId: Value(habitId),
          completedOn: Value(_date(row, 'completedOn', 'Habit check-in $id')),
          createdAt: Value(_date(row, 'createdAt', 'Habit check-in $id')),
        ),
      );
    }

    final seenCompletions = <String>{};
    for (final completion in completionRows) {
      final habitId = completion.habitId.value;
      final day = completion.completedOn.value.toIso8601String();
      if (!seenCompletions.add('$habitId/$day')) {
        throw BackupException(
          'Habit $habitId has the same day recorded twice in this backup.',
        );
      }
    }

    final noteRows = <NotesCompanion>[];
    final usedNoteIds = <int>{};
    for (var index = 0; index < notes.length; index++) {
      final row = _record(notes[index], 'notes[$index]');
      final id = _id(row, 'notes[$index]');
      _unique(usedNoteIds, id, 'note');
      noteRows.add(
        NotesCompanion(
          id: Value(id),
          title: Value(_string(row, 'title', 'Note $id')),
          content: Value(_string(row, 'content', 'Note $id')),
          createdAt: Value(_date(row, 'createdAt', 'Note $id')),
          updatedAt: Value(_date(row, 'updatedAt', 'Note $id')),
        ),
      );
    }

    final preferenceRows = <PreferencesCompanion>[];
    final rawPreferences = decoded['preferences'] ?? const <String, Object?>{};
    if (rawPreferences is! Map<String, Object?>) {
      throw const BackupException('Backup preferences must be an object.');
    }
    for (final entry in rawPreferences.entries) {
      if (entry.value is! String) {
        throw BackupException(
          'Preference "${entry.key}" must be stored as text.',
        );
      }
      preferenceRows.add(
        PreferencesCompanion.insert(
          key: entry.key,
          value: entry.value! as String,
        ),
      );
    }

    return _ParsedBackup(
      tasks: taskRows,
      sessions: sessionRows,
      habits: habitRows,
      completions: completionRows,
      notes: noteRows,
      preferences: preferenceRows,
    );
  }

  static List<Object?> _list(Map<String, Object?> source, String key) {
    final value = source[key];
    if (value == null) return const [];
    if (value is! List<Object?>) {
      throw BackupException('Backup "$key" must be a list.');
    }
    return value;
  }

  static Map<String, Object?> _record(Object? value, String path) {
    if (value is! Map<String, Object?>) {
      throw BackupException('$path must be an object.');
    }
    return value;
  }

  static int _id(Map<String, Object?> row, String path) {
    final id = row['id'];
    if (id is! int || id <= 0) {
      throw BackupException('$path is missing a valid id.');
    }
    return id;
  }

  static void _unique(Set<int> seen, int id, String label) {
    if (!seen.add(id)) {
      throw BackupException('The backup contains duplicate $label id $id.');
    }
  }

  static String _string(Map<String, Object?> row, String key, String owner) {
    final value = row[key];
    if (value is! String) {
      throw BackupException('$owner is missing a valid "$key".');
    }
    return value;
  }

  static String? _optionalString(
    Map<String, Object?> row,
    String key,
    String owner,
  ) {
    final value = row[key];
    if (value == null) return null;
    if (value is! String) {
      throw BackupException('$owner has an invalid "$key".');
    }
    return value;
  }

  static int _int(Map<String, Object?> row, String key, String owner) {
    final value = row[key];
    if (value is! int) {
      throw BackupException('$owner is missing a valid "$key".');
    }
    return value;
  }

  static int? _optionalInt(Map<String, Object?> row, String key, String owner) {
    final value = row[key];
    if (value == null) return null;
    if (value is! int) {
      throw BackupException('$owner has an invalid "$key".');
    }
    return value;
  }

  static bool _bool(Map<String, Object?> row, String key, String owner) {
    final value = row[key];
    if (value is! bool) {
      throw BackupException('$owner is missing a valid "$key".');
    }
    return value;
  }

  static DateTime _date(Map<String, Object?> row, String key, String owner) {
    final parsed = _parseDate(row[key]);
    if (parsed == null) {
      throw BackupException('$owner is missing a valid "$key".');
    }
    return parsed;
  }

  static DateTime? _optionalDate(
    Map<String, Object?> row,
    String key,
    String owner,
  ) {
    if (row[key] == null) return null;
    final parsed = _parseDate(row[key]);
    if (parsed == null) {
      throw BackupException('$owner has an invalid "$key".');
    }
    return parsed;
  }

  static DateTime? _parseDate(Object? value) {
    if (value is String) return DateTime.tryParse(value);
    // Older exports or hand-edited files may use epoch milliseconds.
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value);
    }
    return null;
  }

  static Map<String, Object?> _taskToJson(Task task) => {
    'id': task.id,
    'title': task.title,
    'description': task.description,
    'dueAt': task.dueAt?.toIso8601String(),
    'priority': task.priority,
    'isCompleted': task.isCompleted,
    'completedAt': task.completedAt?.toIso8601String(),
    'createdAt': task.createdAt.toIso8601String(),
    'updatedAt': task.updatedAt.toIso8601String(),
  };

  static Map<String, Object?> _sessionToJson(FocusSession session) => {
    'id': session.id,
    'startedAt': session.startedAt.toIso8601String(),
    'endedAt': session.endedAt?.toIso8601String(),
    'durationMillis': session.durationMillis,
    'status': session.status,
    'runningSinceMillis': session.runningSinceMillis,
  };

  static Map<String, Object?> _habitToJson(Habit habit) => {
    'id': habit.id,
    'name': habit.name,
    'description': habit.description,
    'isArchived': habit.isArchived,
    'createdAt': habit.createdAt.toIso8601String(),
    'updatedAt': habit.updatedAt.toIso8601String(),
  };

  static Map<String, Object?> _completionToJson(HabitCompletion completion) => {
    'id': completion.id,
    'habitId': completion.habitId,
    'completedOn': completion.completedOn.toIso8601String(),
    'createdAt': completion.createdAt.toIso8601String(),
  };

  static Map<String, Object?> _noteToJson(Note note) => {
    'id': note.id,
    'title': note.title,
    'content': note.content,
    'createdAt': note.createdAt.toIso8601String(),
    'updatedAt': note.updatedAt.toIso8601String(),
  };
}

class _ParsedBackup {
  const _ParsedBackup({
    required this.tasks,
    required this.sessions,
    required this.habits,
    required this.completions,
    required this.notes,
    required this.preferences,
  });

  final List<TasksCompanion> tasks;
  final List<FocusSessionsCompanion> sessions;
  final List<HabitsCompanion> habits;
  final List<HabitCompletionsCompanion> completions;
  final List<NotesCompanion> notes;
  final List<PreferencesCompanion> preferences;

  BackupCounts get counts => BackupCounts(
    tasks: tasks.length,
    focusSessions: sessions.length,
    habits: habits.length,
    habitCompletions: completions.length,
    notes: notes.length,
    preferences: preferences.length,
  );
}
