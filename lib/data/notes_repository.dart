import 'package:drift/drift.dart';

import 'flowstate_database.dart';

class NotesRepository {
  NotesRepository(this._database);

  /// Shown instead of an empty title so a saved note is always findable.
  static const untitled = 'Untitled note';

  final FlowStateDatabase _database;

  Stream<List<Note>> watchNotes({String query = ''}) {
    final statement = _database.select(_database.notes)
      ..orderBy([(row) => OrderingTerm.desc(row.updatedAt)]);
    final trimmed = query.trim().toLowerCase();
    if (trimmed.isNotEmpty) {
      final pattern = '%$trimmed%';
      statement.where(
        (row) =>
            row.title.lower().like(pattern) | row.content.lower().like(pattern),
      );
    }
    return statement.watch();
  }

  Future<List<Note>> notes() => (_database.select(
    _database.notes,
  )..orderBy([(row) => OrderingTerm.desc(row.updatedAt)])).get();

  Future<int> create({
    required String title,
    required String content,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    return _database
        .into(_database.notes)
        .insert(
          NotesCompanion.insert(
            title: normalizeTitle(title),
            content: content,
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
          title: Value(normalizeTitle(title)),
          content: Value(content),
          updatedAt: Value(now ?? DateTime.now()),
        ),
      );

  Future<int> delete(int id) => (_database.delete(
    _database.notes,
  )..where((row) => row.id.equals(id))).go();

  Future<void> deleteAll() => _database.delete(_database.notes).go();

  static String normalizeTitle(String title) {
    final trimmed = title.trim();
    return trimmed.isEmpty ? untitled : trimmed;
  }
}
