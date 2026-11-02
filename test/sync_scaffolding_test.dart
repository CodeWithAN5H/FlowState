import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flowstate/data/flowstate_database.dart';
import 'package:flowstate/data/habits_repository.dart';
import 'package:flowstate/data/ids.dart';
import 'package:flowstate/data/notes_repository.dart';
import 'package:flowstate/data/sync/fake_backend.dart';
import 'package:flowstate/data/sync/sync_engine.dart';
import 'package:flowstate/data/sync/sync_models.dart';
import 'package:flowstate/data/sync/sync_store.dart';
import 'package:flowstate/data/tasks_repository.dart';

void main() {
  late FlowStateDatabase database;
  late SyncQueue queue;
  late SyncMetadataStore metadata;

  setUp(() {
    database = FlowStateDatabase.forTesting(NativeDatabase.memory());
    queue = SyncQueue(database);
    metadata = SyncMetadataStore(database);
  });

  tearDown(() async => database.close());

  group('outbox', () {
    test(
      'operations keep their local order and are claimed oldest first',
      () async {
        final first = generateUuidV4();
        final second = generateUuidV4();
        final create = await queue.enqueue(
          entity: SyncEntity.task,
          entityUuid: first,
          kind: SyncOperationKind.create,
        );
        final update = await queue.enqueue(
          entity: SyncEntity.task,
          entityUuid: first,
          kind: SyncOperationKind.update,
          payload: {'title': 'Renamed'},
        );
        final remove = await queue.enqueue(
          entity: SyncEntity.task,
          entityUuid: first,
          kind: SyncOperationKind.delete,
        );
        final otherCreate = await queue.enqueue(
          entity: SyncEntity.note,
          entityUuid: second,
          kind: SyncOperationKind.create,
        );

        final pending = await queue.pending();
        expect(
          [for (final entry in pending) entry.id],
          [create.id, update.id, remove.id, otherCreate.id],
        );
        expect(
          [for (final entry in pending) entry.operation],
          ['create', 'update', 'delete', 'create'],
        );
        expect(pending[1].entityUuid, first);
        expect(jsonDecode(pending[1].payload), {'title': 'Renamed'});
        expect(await queue.pendingCount(), 4);
      },
    );

    test('an acknowledgement is persisted with the remote link, and the row is kept', () async {
      final uuid = generateUuidV4();
      final operation = await queue.enqueue(
        entity: SyncEntity.task,
        entityUuid: uuid,
        kind: SyncOperationKind.create,
      );

      await queue.acknowledge(
        operation,
        remoteId: 'remote-9',
        remoteRevision: 3,
        now: DateTime(2026, 11, 2, 9),
      );

      final stored = (await queue.all()).single;
      expect(stored.status, SyncOperationStatus.acknowledged.name);
      expect(stored.attemptCount, 1);
      expect(stored.lastErrorKind, isNull);
      expect(await queue.pending(), isEmpty, reason: 'nothing left to send');

      final link = await metadata.linkFor(
        entity: SyncEntity.task,
        localUuid: uuid,
      );
      expect(link!.remoteId, 'remote-9');
      expect(link.remoteRevision, 3);
      expect(link.baseRevision, 3);
      expect(link.linkedAt, DateTime(2026, 11, 2, 9));
    });

    test('acknowledging a vanished operation writes no link', () async {
      final operation = await queue.enqueue(
        entity: SyncEntity.task,
        entityUuid: generateUuidV4(),
        kind: SyncOperationKind.create,
      );
      await database.delete(database.syncOutbox).go();

      await expectLater(
        queue.acknowledge(operation, remoteId: 'remote-1', remoteRevision: 1),
        throwsStateError,
      );
      expect(
        await database.select(database.remoteLinks).get(),
        isEmpty,
        reason: 'the failed transaction must not leave a half-written link',
      );
    });

    test('a retryable failure stays queued with backoff metadata', () async {
      final now = DateTime(2026, 11, 2, 9);
      final operation = await queue.enqueue(
        entity: SyncEntity.task,
        entityUuid: generateUuidV4(),
        kind: SyncOperationKind.update,
        now: now,
      );
      await queue.markInFlight(operation.id);

      await queue.recordFailure(
        operation,
        SyncFailure.fromHttpStatus(429, message: 'Slow down'),
        now: now,
      );

      final stored = (await queue.all()).single;
      expect(stored.status, SyncOperationStatus.failed.name);
      expect(stored.attemptCount, 1);
      expect(stored.lastErrorKind, SyncFailureKind.rateLimited.name);
      expect(stored.lastErrorMessage, 'Slow down');
      expect(stored.nextAttemptAt, now.add(const Duration(seconds: 1)));
      expect(
        await queue.pending(now: now),
        isEmpty,
        reason: 'a backoff deadline in the future must not be claimed',
      );
      expect(
        await queue.pending(now: now.add(const Duration(seconds: 2))),
        hasLength(1),
      );
    });

    test('a non-retryable failure waits for an explicit retry', () async {
      final now = DateTime(2026, 11, 2, 9);
      final operation = await queue.enqueue(
        entity: SyncEntity.habit,
        entityUuid: generateUuidV4(),
        kind: SyncOperationKind.create,
        now: now,
      );

      await queue.recordFailure(
        operation,
        SyncFailure.fromHttpStatus(401),
        now: now,
      );

      final stored = (await queue.all()).single;
      expect(stored.lastErrorKind, SyncFailureKind.authenticationRequired.name);
      expect(stored.nextAttemptAt, isNull);
      expect(
        await queue.pending(now: now.add(const Duration(days: 1))),
        isEmpty,
        reason: 'an expired session is not fixed by waiting',
      );

      await queue.retryNow(operation.id);
      expect(
        await queue.pending(now: now.add(const Duration(days: 1))),
        hasLength(1),
      );
    });

    test('attempts are counted so backoff can grow', () async {
      final now = DateTime(2026, 11, 2, 9);
      var operation = await queue.enqueue(
        entity: SyncEntity.note,
        entityUuid: generateUuidV4(),
        kind: SyncOperationKind.create,
        now: now,
      );
      for (var attempt = 1; attempt <= 3; attempt++) {
        await queue.recordFailure(operation, SyncFailure.offline, now: now);
        operation = (await queue.all()).single;
        expect(operation.attemptCount, attempt);
      }
      expect(operation.nextAttemptAt, now.add(const Duration(seconds: 4)));
    });
  });

  group('failure modelling', () {
    test('each remote outcome is distinguishable', () {
      expect(
        SyncFailure.fromHttpStatus(401).kind,
        SyncFailureKind.authenticationRequired,
      );
      expect(
        SyncFailure.fromHttpStatus(403).kind,
        SyncFailureKind.permissionDenied,
      );
      expect(SyncFailure.fromHttpStatus(409).kind, SyncFailureKind.conflict);
      expect(SyncFailure.fromHttpStatus(429).kind, SyncFailureKind.rateLimited);
      expect(SyncFailure.fromHttpStatus(500).kind, SyncFailureKind.serverError);
      expect(SyncFailure.fromHttpStatus(502).kind, SyncFailureKind.serverError);
      expect(
        SyncFailure.fromHttpStatus(503).kind,
        SyncFailureKind.backendPaused,
      );
      expect(
        SyncFailure.fromHttpStatus(400).kind,
        SyncFailureKind.invalidRequest,
      );
      expect(SyncFailure.offline.kind, SyncFailureKind.offline);

      expect(SyncFailure.fromHttpStatus(503).isRetryable, isTrue);
      expect(SyncFailure.fromHttpStatus(429).isRetryable, isTrue);
      expect(SyncFailure.fromHttpStatus(401).isRetryable, isFalse);
      expect(SyncFailure.fromHttpStatus(409).isRetryable, isFalse);
      expect(SyncFailure.offline.isRetryable, isTrue);
    });

    test('backoff doubles and is capped', () {
      expect(retryDelayFor(1), const Duration(seconds: 1));
      expect(retryDelayFor(2), const Duration(seconds: 2));
      expect(retryDelayFor(3), const Duration(seconds: 4));
      expect(retryDelayFor(4), const Duration(seconds: 8));
      expect(retryDelayFor(20), const Duration(seconds: 256));
      expect(retryDelayFor(0), const Duration(seconds: 1));
    });
  });

  group('tombstones', () {
    test('deleting a task hides it and keeps the deletion', () async {
      final tasks = TasksRepository(database);
      final id = await tasks.create(title: 'Delete me', dueAt: DateTime.now());
      final uuid = (await database.select(database.tasks).get()).single.uuid;

      expect(await tasks.delete(id), 1);

      expect(await database.select(database.tasks).get(), isEmpty);
      expect(await tasks.todayTasks(DateTime.now()), isEmpty);
      expect(await tasks.completedToday(DateTime.now()), 0);

      final tombstone = (await metadata.tombstones()).single;
      expect(tombstone.entity, SyncEntity.task.wireName);
      expect(tombstone.entityUuid, uuid);
      expect(tombstone.deletedAt, isNotNull);
    });

    test(
      'deleting a habit keeps its tombstone and takes history with it',
      () async {
        final habits = HabitsRepository(database);
        final id = await habits.create(name: 'Walk');
        await habits.setCompletedOn(
          id,
          day: DateTime(2026, 11, 2),
          completed: true,
        );
        final uuid = (await database.select(database.habits).get()).single.uuid;
        expect(
          await database.select(database.habitCompletions).get(),
          hasLength(1),
        );

        expect(await habits.delete(id), 1);

        expect(await database.select(database.habits).get(), isEmpty);
        expect(await database.select(database.habitCompletions).get(), isEmpty);
        final tombstone = (await metadata.tombstones()).single;
        expect(tombstone.entity, SyncEntity.habit.wireName);
        expect(tombstone.entityUuid, uuid);
      },
    );

    test('deleting a note keeps its tombstone', () async {
      final notes = NotesRepository(database);
      final id = await notes.create(title: 'Plan', content: 'Body');
      final uuid = (await database.select(database.notes).get()).single.uuid;

      expect(await notes.delete(id), 1);

      expect(await notes.notes(), isEmpty);
      expect((await metadata.tombstones()).single.entityUuid, uuid);
    });

    test(
      'deleting a missing record returns zero and records nothing',
      () async {
        expect(await TasksRepository(database).delete(404), 0);
        expect(await NotesRepository(database).delete(404), 0);
        expect(await HabitsRepository(database).delete(404), 0);
        expect(await database.select(database.syncTombstones).get(), isEmpty);
      },
    );
  });

  group('sync metadata', () {
    test('local and remote identity stay separate, with revisions', () async {
      final uuid = generateUuidV4();
      final create = await queue.enqueue(
        entity: SyncEntity.task,
        entityUuid: uuid,
        kind: SyncOperationKind.create,
      );
      await queue.acknowledge(create, remoteId: 'remote-77', remoteRevision: 4);

      final link = await metadata.linkFor(
        entity: SyncEntity.task,
        localUuid: uuid,
      );
      expect(link!.localUuid, uuid);
      expect(link.remoteId, 'remote-77');
      expect(link.localUuid, isNot(link.remoteId));

      final update = await queue.enqueue(
        entity: SyncEntity.task,
        entityUuid: uuid,
        kind: SyncOperationKind.update,
      );
      await queue.acknowledge(update, remoteId: 'remote-77', remoteRevision: 5);

      final links = await metadata.linksFor(SyncEntity.task);
      expect(links, hasLength(1), reason: 'one link per local record');
      expect(links.single.baseRevision, 5);
      expect(links.single.remoteRevision, 5);
    });

    test('sync state records success and failure across restarts', () async {
      final at = DateTime(2026, 11, 2, 10);
      await metadata.recordSuccess(
        entity: SyncEntity.task,
        cursor: 'cursor-1',
        now: at,
      );

      var state = await metadata.state(SyncEntity.task);
      expect(state!.status, 'idle');
      expect(state.lastSyncedAt, at);
      expect(state.cursor, 'cursor-1');
      expect(state.consecutiveFailures, 0);

      await metadata.recordFailure(
        entity: SyncEntity.task,
        failure: SyncFailure.fromHttpStatus(503, message: 'Paused'),
        now: at.add(const Duration(minutes: 1)),
      );

      // A new store on the same database sees the same state: nothing is held in
      // memory only.
      state = await SyncMetadataStore(database).state(SyncEntity.task);
      expect(state!.status, 'error');
      expect(state.lastErrorKind, SyncFailureKind.backendPaused.name);
      expect(state.lastErrorMessage, 'Paused');
      expect(state.consecutiveFailures, 1);
      expect(state.retryAfter, at.add(const Duration(minutes: 1, seconds: 1)));
      expect(
        state.cursor,
        'cursor-1',
        reason: 'a failure must not lose progress',
      );

      await metadata.recordSuccess(entity: SyncEntity.task, now: at);
      state = await metadata.state(SyncEntity.task);
      expect(state!.consecutiveFailures, 0);
      expect(state.lastErrorKind, isNull);
      expect(state.retryAfter, isNull);
    });

    test('a conflict keeps both sides until it is resolved', () async {
      final uuid = generateUuidV4();
      final id = await metadata.recordConflict(
        entity: SyncEntity.note,
        entityUuid: uuid,
        localRevision: 2,
        remoteRevision: 5,
        field: 'title',
        localPayload: {'title': 'My local title'},
        remotePayload: {'title': 'Someone else title'},
        now: DateTime(2026, 11, 2, 11),
      );

      final conflicts = await metadata.conflictsFor(
        entity: SyncEntity.note,
        entityUuid: uuid,
      );
      expect(conflicts, hasLength(1));
      expect(conflicts.single.localRevision, 2);
      expect(conflicts.single.remoteRevision, 5);
      expect(conflicts.single.field, 'title');
      expect(conflicts.single.status, 'open');
      expect(jsonDecode(conflicts.single.localPayload!), {
        'title': 'My local title',
      });
      expect(jsonDecode(conflicts.single.remotePayload!), {
        'title': 'Someone else title',
      });
      expect(await metadata.openConflicts(), hasLength(1));

      await metadata.resolveConflict(id, now: DateTime(2026, 11, 2, 12));
      final resolved = (await metadata.conflictsFor(
        entity: SyncEntity.note,
        entityUuid: uuid,
      )).single;
      expect(resolved.status, 'resolved');
      expect(resolved.resolvedAt, DateTime(2026, 11, 2, 12));
      expect(jsonDecode(resolved.localPayload!), {'title': 'My local title'});
      expect(await metadata.openConflicts(), isEmpty);
    });
  });

  group('engine', () {
    late DateTime now;
    late FakeRemoteBackend backend;
    late SyncEngine engine;

    setUp(() {
      now = DateTime(2026, 11, 2, 12);
      backend = FakeRemoteBackend();
      engine = SyncEngine(
        database: database,
        queue: queue,
        metadata: metadata,
        backend: backend,
        clock: () => now,
      );
    });

    test('drains queued operations in order and acknowledges each', () async {
      final uuid = generateUuidV4();
      final create = await queue.enqueue(
        entity: SyncEntity.task,
        entityUuid: uuid,
        kind: SyncOperationKind.create,
        payload: {'title': 'First'},
      );
      final update = await queue.enqueue(
        entity: SyncEntity.task,
        entityUuid: uuid,
        kind: SyncOperationKind.update,
        payload: {'title': 'Second'},
      );
      final note = await queue.enqueue(
        entity: SyncEntity.note,
        entityUuid: generateUuidV4(),
        kind: SyncOperationKind.create,
      );

      final result = await engine.drainOnce();

      expect(result.isSuccess, isTrue);
      expect(result.acknowledged, 3);
      expect(backend.pushedOperationIds, [
        create.operationId,
        update.operationId,
        note.operationId,
      ]);
      expect(backend.pushed.first.payload, {'title': 'First'});
      expect(
        [
          for (final entry in await queue.all())
            (entry.operationId, entry.status),
        ],
        [
          (create.operationId, SyncOperationStatus.acknowledged.name),
          (update.operationId, SyncOperationStatus.acknowledged.name),
          (note.operationId, SyncOperationStatus.acknowledged.name),
        ],
      );
      final link = await metadata.linkFor(
        entity: SyncEntity.task,
        localUuid: uuid,
      );
      expect(link!.remoteRevision, 2);
      expect(link.baseRevision, 2);
      expect((await metadata.state(SyncEntity.task))!.lastSyncedAt, now);
    });

    test('stops at the first failure and retries it later, in order', () async {
      final uuid = generateUuidV4();
      final first = await queue.enqueue(
        entity: SyncEntity.task,
        entityUuid: uuid,
        kind: SyncOperationKind.create,
      );
      final second = await queue.enqueue(
        entity: SyncEntity.task,
        entityUuid: uuid,
        kind: SyncOperationKind.update,
      );
      final third = await queue.enqueue(
        entity: SyncEntity.note,
        entityUuid: generateUuidV4(),
        kind: SyncOperationKind.create,
      );
      backend.failNext(SyncFailure.fromHttpStatus(429, message: 'Slow down'));

      final failed = await engine.drainOnce();

      expect(failed.acknowledged, 0);
      expect(failed.failure!.kind, SyncFailureKind.rateLimited);
      expect(backend.pushedOperationIds, isEmpty);
      final entries = await queue.all();
      expect(entries[0].status, SyncOperationStatus.failed.name);
      expect(entries[1].status, SyncOperationStatus.pending.name);
      expect(entries[2].status, SyncOperationStatus.pending.name);
      expect(
        (await metadata.state(SyncEntity.task))!.lastErrorKind,
        SyncFailureKind.rateLimited.name,
      );

      // Later, after the backoff, nothing is skipped or reordered.
      now = now.add(const Duration(seconds: 30));
      final recovered = await engine.drainOnce();
      expect(recovered.acknowledged, 3);
      expect(backend.pushedOperationIds, [
        first.operationId,
        second.operationId,
        third.operationId,
      ]);
    });

    test('a second run does not resend acknowledged work', () async {
      await queue.enqueue(
        entity: SyncEntity.task,
        entityUuid: generateUuidV4(),
        kind: SyncOperationKind.create,
      );

      await engine.drainOnce();
      final again = await engine.drainOnce();

      expect(again.acknowledged, 0);
      expect(backend.pushCount, 1);
    });

    test('a delete is acknowledged without a remote link', () async {
      final uuid = generateUuidV4();
      final operation = await queue.enqueue(
        entity: SyncEntity.habit,
        entityUuid: uuid,
        kind: SyncOperationKind.delete,
      );

      await engine.drainOnce();

      expect(
        (await queue.all()).single.status,
        SyncOperationStatus.acknowledged.name,
      );
      expect(await database.select(database.remoteLinks).get(), isEmpty);
      expect((await queue.all()).single.operationId, operation.operationId);
    });

    test(
      'without a configured backend nothing is sent and nothing is lost',
      () async {
        engine = SyncEngine(
          database: database,
          queue: queue,
          metadata: metadata,
          backend: FakeRemoteBackend(isConfigured: false),
          clock: () => now,
        );
        await queue.enqueue(
          entity: SyncEntity.note,
          entityUuid: generateUuidV4(),
          kind: SyncOperationKind.create,
        );

        final result = await engine.drainOnce();

        expect(result.acknowledged, 0);
        expect(result.failure!.kind, SyncFailureKind.offline);
        expect(
          (await queue.all()).single.status,
          SyncOperationStatus.pending.name,
        );
      },
    );
  });
}
