import 'package:drift/drift.dart';

import 'flowstate_database.dart';

class NotesRepository {
  NotesRepository(this._database);

  final FlowStateDatabase _database;

  /// Notes ordered by last edit. [query] filters title and content; SQLite's
  /// LIKE is case-insensitive for ASCII.
  Stream<List<Note>> watchNotes({String query = ''}) {
    final statement = _database.select(_database.notes)
      ..orderBy([(row) => OrderingTerm.desc(row.updatedAt)]);
    final trimmed = query.trim();
    if (trimmed.isNotEmpty) {
      statement.where(
        (row) => row.title.contains(trimmed) | row.content.contains(trimmed),
      );
    }
    return statement.watch();
  }

  Future<List<Note>> notes({String query = ''}) {
    final statement = _database.select(_database.notes)
      ..orderBy([(row) => OrderingTerm.desc(row.updatedAt)]);
    final trimmed = query.trim();
    if (trimmed.isNotEmpty) {
      statement.where(
        (row) => row.title.contains(trimmed) | row.content.contains(trimmed),
      );
    }
    return statement.get();
  }

  Future<Note?> byId(int id) => (_database.select(
    _database.notes,
  )..where((row) => row.id.equals(id))).getSingleOrNull();

  Future<int> create({
    required String title,
    String content = '',
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    return _database
        .into(_database.notes)
        .insert(
          NotesCompanion.insert(
            title: _title(title),
            content: Value(content),
            createdAt: at,
            updatedAt: at,
          ),
        );
  }

  Future<void> updateNote(
    Note note, {
    required String title,
    required String content,
    DateTime? now,
  }) =>
      (_database.update(
        _database.notes,
      )..where((row) => row.id.equals(note.id))).write(
        NotesCompanion(
          title: Value(_title(title)),
          content: Value(content),
          updatedAt: Value(now ?? DateTime.now()),
        ),
      );

  Future<int> delete(int id) => (_database.delete(
    _database.notes,
  )..where((row) => row.id.equals(id))).go();

  Future<void> deleteAll() => _database.delete(_database.notes).go();

  static String _title(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? 'Untitled note' : trimmed;
  }
}
