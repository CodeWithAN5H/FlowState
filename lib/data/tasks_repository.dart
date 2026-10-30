import 'package:drift/drift.dart';

import 'flowstate_database.dart';

class TasksRepository {
  TasksRepository(this._database);

  final FlowStateDatabase _database;

  Stream<List<Task>> watchTasks() =>
      (_database.select(_database.tasks)..orderBy([
            (table) => OrderingTerm.desc(table.isCompleted),
            (table) => OrderingTerm.asc(table.dueAt),
            (table) => OrderingTerm.desc(table.priority),
            (table) => OrderingTerm.desc(table.createdAt),
          ]))
          .watch();

  Future<int> create({
    required String title,
    String? description,
    DateTime? dueAt,
    int priority = 0,
  }) {
    final now = DateTime.now();
    return _database
        .into(_database.tasks)
        .insert(
          TasksCompanion.insert(
            title: title.trim(),
            description: Value(_normalizeDescription(description)),
            dueAt: Value(dueAt),
            priority: Value(priority.clamp(0, 2)),
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  Future<int> updateTask(
    Task task, {
    required String title,
    String? description,
    DateTime? dueAt,
    int priority = 0,
  }) {
    return (_database.update(
      _database.tasks,
    )..where((row) => row.id.equals(task.id))).write(
      TasksCompanion(
        title: Value(title.trim()),
        description: Value(_normalizeDescription(description)),
        dueAt: Value(dueAt),
        priority: Value(priority.clamp(0, 2)),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> setCompleted(Task task, bool completed, {DateTime? now}) async {
    final at = now ?? DateTime.now();
    await (_database.update(
      _database.tasks,
    )..where((row) => row.id.equals(task.id))).write(
      TasksCompanion(
        isCompleted: Value(completed),
        completedAt: Value(completed ? at : null),
        updatedAt: Value(at),
      ),
    );
  }

  Future<int> delete(int id) => (_database.delete(
    _database.tasks,
  )..where((row) => row.id.equals(id))).go();

  Future<List<Task>> todayTasks(DateTime now) async {
    final start = DateTime(now.year, now.month, now.day);
    final end = start.add(const Duration(days: 1));
    return (_database.select(_database.tasks)
          ..where(
            (row) =>
                row.isCompleted.equals(false) &
                (row.dueAt.isNull() |
                    (row.dueAt.isBiggerOrEqualValue(start) &
                        row.dueAt.isSmallerThanValue(end))),
          )
          ..orderBy([(row) => OrderingTerm.asc(row.dueAt)]))
        .get();
  }

  Future<int> completedToday(DateTime now) async {
    final start = DateTime(now.year, now.month, now.day);
    final end = start.add(const Duration(days: 1));
    final row =
        await (_database.selectOnly(_database.tasks)
              ..addColumns([_database.tasks.id.count()])
              ..where(
                _database.tasks.completedAt.isBiggerOrEqualValue(start) &
                    _database.tasks.completedAt.isSmallerThanValue(end),
              ))
            .getSingle();
    return row.read(_database.tasks.id.count()) ?? 0;
  }

  static String? _normalizeDescription(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
