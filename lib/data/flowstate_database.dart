import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'ids.dart';

part 'flowstate_database.g.dart';

/// Unique identifiers are enforced per table with an explicitly named index, so
/// a migrated database and a freshly created one end up with the same index.
@TableIndex(name: 'tasks_uuid_unique', columns: {#uuid}, unique: true)
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

  /// Stable identifier for synchronization. The integer primary key stays the
  /// local key: it is what every query and relation already uses, and replacing
  /// it would rewrite the whole application for no benefit.
  TextColumn get uuid => text().nullable().clientDefault(generateUuidV4)();
}

@TableIndex(name: 'focus_sessions_uuid_unique', columns: {#uuid}, unique: true)
class FocusSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  IntColumn get durationMillis => integer().withDefault(const Constant(0))();
  TextColumn get status => text()();
  IntColumn get runningSinceMillis => integer().nullable()();
  TextColumn get uuid => text().nullable().clientDefault(generateUuidV4)();
}

@TableIndex(name: 'habits_uuid_unique', columns: {#uuid}, unique: true)
class Habits extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 120)();
  TextColumn get details => text().nullable()();
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get uuid => text().nullable().clientDefault(generateUuidV4)();
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

@TableIndex(name: 'notes_uuid_unique', columns: {#uuid}, unique: true)
class Notes extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text()();
  TextColumn get content => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get uuid => text().nullable().clientDefault(generateUuidV4)();
}

/// Small key/value store for app preferences and settings.
class Preferences extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// Pending synchronization work, in local sequence order.
///
/// The auto-incrementing id *is* the ordering: operations are claimed with
/// `ORDER BY id` so replay is deterministic across restarts. Rows are never
/// removed on success, only marked acknowledged, so recognition of a delivered
/// operation can never be lost to a crash between the remote call and the local
/// update.
@DataClassName('OutboxEntry')
@TableIndex(name: 'sync_outbox_status_id', columns: {#status, #id})
class SyncOutbox extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Unique identifier for this operation, so a retry can be recognised.
  TextColumn get operationId => text().unique()();
  TextColumn get entity => text()();
  TextColumn get entityUuid => text()();
  TextColumn get operation => text()();

  /// JSON snapshot of the fields the operation needs, so a later edit cannot
  /// change the meaning of an operation that is already queued.
  TextColumn get payload => text().withDefault(const Constant('{}'))();
  IntColumn get localRevision => integer().withDefault(const Constant(1))();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();

  /// Null for a non-retryable failure, which is why such a row is never claimed
  /// again until it is explicitly re-queued.
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();
  TextColumn get lastErrorKind => text().nullable()();
  TextColumn get lastErrorMessage => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
}

/// Per-entity synchronization state: what succeeded, what failed, and when to
/// try again. Kept apart from the local data so a backend problem can never make
/// personal records look invalid.
@DataClassName('SyncStateEntry')
class SyncState extends Table {
  TextColumn get entity => text()();
  TextColumn get status => text().withDefault(const Constant('idle'))();
  TextColumn get cursor => text().nullable()();
  DateTimeColumn get lastSyncedAt => dateTime().nullable()();
  TextColumn get lastErrorKind => text().nullable()();
  TextColumn get lastErrorMessage => text().nullable()();
  IntColumn get consecutiveFailures =>
      integer().withDefault(const Constant(0))();
  DateTimeColumn get retryAfter => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {entity};
}

/// Local UUID to remote identifier. Separate on purpose: the local record never
/// depends on a remote row existing, and a remote id is meaningless without the
/// local record it belongs to.
@DataClassName('RemoteLink')
class RemoteLinks extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get entity => text()();
  TextColumn get localUuid => text()();
  TextColumn get remoteId => text()();
  IntColumn get remoteRevision => integer().withDefault(const Constant(0))();

  /// The server revision this local copy was based on. A later update must send
  /// it back, which is how a stale write is detected instead of overwriting
  /// newer remote data.
  IntColumn get baseRevision => integer().withDefault(const Constant(0))();
  DateTimeColumn get linkedAt => dateTime()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {entity, localUuid},
  ];
}

/// Records a disagreement between a local and a remote revision. Both payloads
/// are kept verbatim so a later phase can present or resolve them; nothing in
/// this milestone decides a winner.
@DataClassName('SyncConflict')
class SyncConflicts extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get entity => text()();
  TextColumn get entityUuid => text()();

  /// The scalar field in dispute, when the conflict is field-sized rather than a
  /// whole-record copy.
  TextColumn get field => text().nullable()();
  IntColumn get localRevision => integer().withDefault(const Constant(0))();
  IntColumn get remoteRevision => integer().withDefault(const Constant(0))();
  TextColumn get localPayload => text().nullable()();
  TextColumn get remotePayload => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('open'))();
  DateTimeColumn get detectedAt => dateTime()();
  DateTimeColumn get resolvedAt => dateTime().nullable()();
}

/// Durable record that a record was deleted locally.
///
/// Deletions are physical, so the row itself is gone; this table is what a future
/// backend can still be told about, and it survives until the deletion has been
/// acknowledged.
@DataClassName('SyncTombstone')
class SyncTombstones extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get entity => text()();
  TextColumn get entityUuid => text()();
  DateTimeColumn get deletedAt => dateTime()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {entity, entityUuid},
  ];
}

@DriftDatabase(
  tables: [
    Tasks,
    FocusSessions,
    Habits,
    HabitCompletions,
    Notes,
    Preferences,
    SyncOutbox,
    SyncState,
    RemoteLinks,
    SyncConflicts,
    SyncTombstones,
  ],
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
  int get schemaVersion => 4;

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
      if (from < 4) {
        // Also additive. The UUID columns are added empty, filled in for every
        // existing row, and only then indexed as unique, so no row is ever left
        // without an identifier and no relation is rebuilt.
        // habits and notes already carry their uuid when this upgrade also
        // created them from a pre-v3 database, so only add the column to tables
        // that existed before v4.
        await migrator.addColumn(tasks, tasks.uuid);
        await migrator.addColumn(focusSessions, focusSessions.uuid);
        if (from >= 3) {
          await migrator.addColumn(habits, habits.uuid);
          await migrator.addColumn(notes, notes.uuid);
        }

        await migrator.createTable(syncOutbox);
        await migrator.createTable(syncState);
        await migrator.createTable(remoteLinks);
        await migrator.createTable(syncConflicts);
        await migrator.createTable(syncTombstones);

        await _assignMissingUuids();
        await _createUuidIndexes();
      }
    },
    beforeOpen: (details) async {
      // Habit history is deleted with its habit instead of being orphaned.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// Fills in a UUID for every pre-v4 row.
  ///
  /// Generated in SQL rather than by walking tables in Dart because the migration
  /// runs before any generated accessor is available, and because a single
  /// statement per table cannot half-apply. The expression produces an RFC 4122
  /// version 4 value: `randomblob` supplies the entropy, the version nibble is a
  /// literal `4`, and the variant nibble is drawn from `89ab`.
  Future<void> _assignMissingUuids() async {
    const expression = '''
      lower(
        substr(hex(randomblob(4)), 1, 8) || '-' ||
        substr(hex(randomblob(2)), 1, 4) || '-4' ||
        substr(hex(randomblob(2)), 2, 3) || '-' ||
        substr('89ab', abs(random()) % 4 + 1, 1) ||
        substr(hex(randomblob(2)), 2, 3) || '-' ||
        substr(hex(randomblob(6)), 1, 12)
      )
    ''';
    for (final table in const <String>[
      'tasks',
      'habits',
      'notes',
      'focus_sessions',
    ]) {
      await customStatement(
        'UPDATE $table SET uuid = $expression WHERE uuid IS NULL',
      );
    }
  }

  /// Created explicitly because [Migrator.addColumn] does not add indexes. The
  /// names match the `@TableIndex` declarations above, so a migrated database and
  /// a newly created one agree.
  Future<void> _createUuidIndexes() async {
    const indexes = <String, String>{
      'tasks_uuid_unique': 'tasks',
      'habits_uuid_unique': 'habits',
      'notes_uuid_unique': 'notes',
      'focus_sessions_uuid_unique': 'focus_sessions',
    };
    for (final entry in indexes.entries) {
      await customStatement(
        'CREATE UNIQUE INDEX IF NOT EXISTS ${entry.key} '
        'ON ${entry.value} (uuid)',
      );
    }
  }
}
