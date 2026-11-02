import 'dart:convert';

import 'package:drift/drift.dart';

import '../flowstate_database.dart';
import '../ids.dart';
import 'sync_models.dart';

/// The local queue of work for a remote backend.
///
/// Claim order is `id ASC`, which is the order operations were enqueued, so a
/// replay after a restart cannot reorder a create before its update.
class SyncQueue {
  SyncQueue(this._database);

  final FlowStateDatabase _database;

  Future<OutboxEntry> enqueue({
    required SyncEntity entity,
    required String entityUuid,
    required SyncOperationKind kind,
    Map<String, Object?> payload = const <String, Object?>{},
    int localRevision = 1,
    DateTime? now,
    String? operationId,
  }) async {
    final entry = await _database
        .into(_database.syncOutbox)
        .insertReturning(
          SyncOutboxCompanion.insert(
            operationId: operationId ?? generateUuidV4(),
            entity: entity.wireName,
            entityUuid: entityUuid,
            operation: kind.wireName,
            payload: Value(jsonEncode(payload)),
            localRevision: Value(localRevision),
            createdAt: now ?? DateTime.now(),
          ),
        );
    return entry;
  }

  /// Operations that may be attempted now, oldest first.
  ///
  /// A failed row is eligible only when it carries a `nextAttemptAt` that has
  /// arrived; a non-retryable failure has none and therefore stays put until
  /// [retryNow] is called, rather than spinning in the background.
  Future<List<OutboxEntry>> pending({DateTime? now, int limit = 50}) {
    final at = now ?? DateTime.now();
    return (_database.select(_database.syncOutbox)
          ..where(
            (row) =>
                row.status.equals(SyncOperationStatus.pending.name) |
                (row.status.equals(SyncOperationStatus.failed.name) &
                    row.nextAttemptAt.isNotNull() &
                    row.nextAttemptAt.isSmallerOrEqualValue(at)),
          )
          ..orderBy([(row) => OrderingTerm.asc(row.id)])
          ..limit(limit))
        .get();
  }

  Future<List<OutboxEntry>> all() => (_database.select(
    _database.syncOutbox,
  )..orderBy([(row) => OrderingTerm.asc(row.id)])).get();

  Future<int> pendingCount({DateTime? now}) async =>
      (await pending(now: now, limit: 1000)).length;

  Future<OutboxEntry?> byId(int id) => (_database.select(
    _database.syncOutbox,
  )..where((row) => row.id.equals(id))).getSingleOrNull();

  Future<void> markInFlight(int id) =>
      (_database.update(
        _database.syncOutbox,
      )..where((row) => row.id.equals(id))).write(
        SyncOutboxCompanion(status: Value(SyncOperationStatus.inFlight.name)),
      );

  /// Marks an operation delivered and records the remote identity in the same
  /// transaction.
  ///
  /// The outbox row is updated *before* the link row is written, both inside one
  /// transaction: either the acknowledgement and the local state change are both
  /// persisted, or neither is, and the operation is retried. Nothing is deleted,
  /// so the evidence of delivery survives as well.
  Future<void> acknowledge(
    OutboxEntry operation, {
    required String remoteId,
    required int remoteRevision,
    DateTime? now,
  }) {
    return _database.transaction(() async {
      final updated =
          await (_database.update(
            _database.syncOutbox,
          )..where((row) => row.id.equals(operation.id))).write(
            SyncOutboxCompanion(
              status: Value(SyncOperationStatus.acknowledged.name),
              attemptCount: Value(operation.attemptCount + 1),
              nextAttemptAt: const Value(null),
              lastErrorKind: const Value(null),
              lastErrorMessage: const Value(null),
            ),
          );
      if (updated != 1) {
        // Aborts the transaction, so the link is not written either.
        throw StateError('Outbox operation ${operation.id} disappeared');
      }

      final kind = SyncOperationKind.tryParse(operation.operation);
      if (kind == SyncOperationKind.delete) return;

      final entity = SyncEntity.tryParse(operation.entity);
      if (entity == null) return;

      // The conflict target is explicit because this table is unique on
      // (entity, local_uuid) and has no primary key of its own: without a target
      // the statement is a plain insert and a second acknowledgement of the same
      // record would fail instead of updating the revision.
      final link = RemoteLinksCompanion.insert(
        entity: entity.wireName,
        localUuid: operation.entityUuid,
        remoteId: remoteId,
        remoteRevision: Value(remoteRevision),
        baseRevision: Value(remoteRevision),
        linkedAt: now ?? DateTime.now(),
      );
      await _database
          .into(_database.remoteLinks)
          .insert(
            link,
            onConflict: DoUpdate(
              (_) => link,
              target: [
                _database.remoteLinks.entity,
                _database.remoteLinks.localUuid,
              ],
            ),
          );
    });
  }

  /// Records an unsuccessful attempt, keeping the operation queued.
  ///
  /// Retryability lives in `nextAttemptAt`: retryable failures get a backoff
  /// deadline, non-retryable ones get none and wait for an explicit [retryNow].
  Future<void> recordFailure(
    OutboxEntry operation,
    SyncFailure failure, {
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final attemptCount = operation.attemptCount + 1;
    final delay = failure.retryAfter ?? retryDelayFor(attemptCount);
    await (_database.update(
      _database.syncOutbox,
    )..where((row) => row.id.equals(operation.id))).write(
      SyncOutboxCompanion(
        status: Value(SyncOperationStatus.failed.name),
        attemptCount: Value(attemptCount),
        lastErrorKind: Value(failure.kind.name),
        lastErrorMessage: Value(failure.message),
        nextAttemptAt: Value(failure.isRetryable ? at.add(delay) : null),
      ),
    );
  }

  /// Puts a failed operation back in the queue, for example after the user signs
  /// in again or resolves a conflict.
  Future<void> retryNow(int id) =>
      (_database.update(
        _database.syncOutbox,
      )..where((row) => row.id.equals(id))).write(
        const SyncOutboxCompanion(
          status: Value('pending'),
          nextAttemptAt: Value(null),
        ),
      );
}

/// Remote links, per-entity sync state, conflicts and tombstones.
class SyncMetadataStore {
  SyncMetadataStore(this._database);

  final FlowStateDatabase _database;

  Future<SyncStateEntry?> state(SyncEntity entity) => (_database.select(
    _database.syncState,
  )..where((row) => row.entity.equals(entity.wireName))).getSingleOrNull();

  Future<List<SyncStateEntry>> allState() =>
      _database.select(_database.syncState).get();

  Future<void> recordSuccess({
    required SyncEntity entity,
    String? cursor,
    DateTime? now,
  }) async {
    final existing = await state(entity);
    final values = SyncStateCompanion.insert(
      entity: entity.wireName,
      status: const Value('idle'),
      cursor: Value(cursor ?? existing?.cursor),
      lastSyncedAt: Value(now ?? DateTime.now()),
      lastErrorKind: const Value(null),
      lastErrorMessage: const Value(null),
      consecutiveFailures: const Value(0),
      retryAfter: const Value(null),
    );
    await _database
        .into(_database.syncState)
        .insert(
          values,
          onConflict: DoUpdate(
            (_) => values,
            target: [_database.syncState.entity],
          ),
        );
  }

  Future<void> recordFailure({
    required SyncEntity entity,
    required SyncFailure failure,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final existing = await state(entity);
    final attempts = (existing?.consecutiveFailures ?? 0) + 1;
    final delay = failure.retryAfter ?? retryDelayFor(attempts);
    final values = SyncStateCompanion.insert(
      entity: entity.wireName,
      status: const Value('error'),
      lastSyncedAt: Value(existing?.lastSyncedAt),
      lastErrorKind: Value(failure.kind.name),
      lastErrorMessage: Value(failure.message),
      consecutiveFailures: Value(attempts),
      retryAfter: Value(failure.isRetryable ? at.add(delay) : null),
    );
    await _database
        .into(_database.syncState)
        .insert(
          values,
          onConflict: DoUpdate(
            (_) => values,
            target: [_database.syncState.entity],
          ),
        );
  }

  Future<RemoteLink?> linkFor({
    required SyncEntity entity,
    required String localUuid,
  }) =>
      (_database.select(_database.remoteLinks)..where(
            (row) =>
                row.entity.equals(entity.wireName) &
                row.localUuid.equals(localUuid),
          ))
          .getSingleOrNull();

  Future<List<RemoteLink>> linksFor(SyncEntity entity) => (_database.select(
    _database.remoteLinks,
  )..where((row) => row.entity.equals(entity.wireName))).get();

  Future<int> recordConflict({
    required SyncEntity entity,
    required String entityUuid,
    required int localRevision,
    required int remoteRevision,
    Map<String, Object?>? localPayload,
    Map<String, Object?>? remotePayload,
    String? field,
    DateTime? now,
  }) => _database
      .into(_database.syncConflicts)
      .insert(
        SyncConflictsCompanion.insert(
          entity: entity.wireName,
          entityUuid: entityUuid,
          field: Value(field),
          localRevision: Value(localRevision),
          remoteRevision: Value(remoteRevision),
          localPayload: Value(
            localPayload == null ? null : jsonEncode(localPayload),
          ),
          remotePayload: Value(
            remotePayload == null ? null : jsonEncode(remotePayload),
          ),
          detectedAt: now ?? DateTime.now(),
        ),
      );

  Future<List<SyncConflict>> conflictsFor({
    required SyncEntity entity,
    required String entityUuid,
  }) =>
      (_database.select(_database.syncConflicts)..where(
            (row) =>
                row.entity.equals(entity.wireName) &
                row.entityUuid.equals(entityUuid),
          ))
          .get();

  Future<List<SyncConflict>> openConflicts() => (_database.select(
    _database.syncConflicts,
  )..where((row) => row.status.equals('open'))).get();

  /// Marks a conflict resolved without discarding either payload, so the losing
  /// side stays inspectable.
  Future<void> resolveConflict(int id, {DateTime? now}) =>
      (_database.update(
        _database.syncConflicts,
      )..where((row) => row.id.equals(id))).write(
        SyncConflictsCompanion(
          status: const Value('resolved'),
          resolvedAt: Value(now ?? DateTime.now()),
        ),
      );

  Future<List<SyncTombstone>> tombstones() => (_database.select(
    _database.syncTombstones,
  )..orderBy([(row) => OrderingTerm.asc(row.id)])).get();
}

/// Records that a locally deleted record must still be reported to a backend.
///
/// The row itself is removed, so this is the only durable evidence that it ever
/// existed. Idempotent per entity and identifier because a repeated delete must
/// not create a second tombstone.
Future<void> recordLocalDeletion(
  FlowStateDatabase database, {
  required SyncEntity entity,
  required String? entityUuid,
  DateTime? now,
}) async {
  if (entityUuid == null || entityUuid.isEmpty) return;
  await database
      .into(database.syncTombstones)
      .insert(
        SyncTombstonesCompanion.insert(
          entity: entity.wireName,
          entityUuid: entityUuid,
          deletedAt: now ?? DateTime.now(),
        ),
        mode: InsertMode.insertOrReplace,
      );
}
