import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

part 'flowstate_database.g.dart';

class Tasks extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text().withLength(min: 1, max: 200)();
  TextColumn get description => text().nullable()();
  DateTimeColumn get dueAt => dateTime().nullable()();
  IntColumn get priority => integer().withDefault(const Constant(0))();
  BoolColumn get isCompleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get completedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}

class FocusSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  IntColumn get durationMillis => integer().withDefault(const Constant(0))();
  TextColumn get status => text()();
  IntColumn get runningSinceMillis => integer().nullable()();
}

class Habits extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 120)();
  TextColumn get details => text().nullable()();
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}

/// One row per habit and calendar day. The unique key is what makes completing
/// a habit twice on the same day a no-op instead of a duplicate.
class HabitCompletions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get habitId =>
      integer().references(Habits, #id, onDelete: KeyAction.cascade)();

  /// The calendar day that was completed, normalized to local midnight.
  DateTimeColumn get completedOn => dateTime()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {habitId, completedOn},
  ];
}

class Notes extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text()();
  TextColumn get content => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}

/// Small key/value store for app preferences and settings.
class Preferences extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(
  tables: [Tasks, FocusSessions, Habits, HabitCompletions, Notes, Preferences],
)
class FlowStateDatabase extends _$FlowStateDatabase {
  FlowStateDatabase()
    : super(
        driftDatabase(
          name: 'flowstate',
          native: DriftNativeOptions(
            // Application data belongs in the app support directory, not in the
            // user's Documents: Documents is protected by Windows Controlled
            // Folder Access, where SQLite cannot create the database file.
            databaseDirectory: getApplicationSupportDirectory,
          ),
        ),
      );

  FlowStateDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator migrator) => migrator.createAll(),
    onUpgrade: (Migrator migrator, int from, int to) async {
      if (from < 2) {
        await migrator.addColumn(tasks, tasks.description);
        await migrator.addColumn(tasks, tasks.dueAt);
        await migrator.addColumn(tasks, tasks.priority);
        await migrator.addColumn(tasks, tasks.completedAt);
        await migrator.addColumn(
          focusSessions,
          focusSessions.runningSinceMillis,
        );
      }
      if (from < 3) {
        // Purely additive: existing tasks and sessions are left untouched.
        await migrator.createTable(habits);
        await migrator.createTable(habitCompletions);
        await migrator.createTable(notes);
        await migrator.createTable(preferences);
      }
    },
    beforeOpen: (details) async {
      // Habit history is deleted with its habit instead of being orphaned.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
