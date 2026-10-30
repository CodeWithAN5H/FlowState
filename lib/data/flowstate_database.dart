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

@DriftDatabase(tables: [Tasks, FocusSessions])
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
  int get schemaVersion => 2;

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
    },
  );
}
