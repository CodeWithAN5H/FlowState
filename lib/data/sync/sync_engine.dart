import 'dart:convert';

import '../flowstate_database.dart';
import 'remote_backend.dart';
import 'sync_models.dart';
import 'sync_store.dart';

/// Outcome of one drain pass.
class SyncRunResult {
  const SyncRunResult({required this.acknowledged, this.failure});

  final int acknowledged;

  /// Set when the pass stopped early. Every run is single-pass: there is no timer
  /// and no retry loop here, so nothing happens unless a caller asks for it.
  final SyncFailure? failure;

  bool get isSuccess => failure == null;
}

/// Pushes queued operations to a [RemoteBackend], one at a time, in order.
///
/// Deliberately minimal for Milestone 2B: no networking, no scheduling, no
/// background work. It exists so the ordering, acknowledgement and failure rules
/// are real code with tests rather than a document. Personal productivity never
/// calls it.
class SyncEngine {
  SyncEngine({
    required FlowStateDatabase database,
    required SyncQueue queue,
    required SyncMetadataStore metadata,
    required RemoteBackend backend,
    DateTime Function()? clock,
  }) : _database = database,
       _queue = queue,
       _metadata = metadata,
       _backend = backend,
       _clock = clock ?? DateTime.now;

  final FlowStateDatabase _database;
  final SyncQueue _queue;
  final SyncMetadataStore _metadata;
  final RemoteBackend _backend;
  final DateTime Function() _clock;

  /// Claims and pushes queued operations oldest first.
  ///
  /// The pass stops at the first failure. That is what keeps related operations
  /// in a valid order: a later update for the same record is never sent while an
  /// earlier operation for it is still unacknowledged, even when the failure is
  /// retryable.
  Future<SyncRunResult> drainOnce({int limit = 50}) async {
    if (!_backend.isConfigured) {
      return SyncRunResult(
        acknowledged: 0,
        failure: const SyncFailure(
          SyncFailureKind.offline,
          message: 'No sync backend is configured.',
        ),
      );
    }

    final operations = await _queue.pending(now: _clock(), limit: limit);
    var acknowledged = 0;

    for (final operation in operations) {
      final entity = SyncEntity.tryParse(operation.entity);
      final kind = SyncOperationKind.tryParse(operation.operation);
      if (entity == null || kind == null) {
        final failure = SyncFailure(
          SyncFailureKind.invalidRequest,
          message:
              'Unsupported operation ${operation.operation} '
              'for ${operation.entity}.',
        );
        await _queue.recordFailure(operation, failure, now: _clock());
        return SyncRunResult(acknowledged: acknowledged, failure: failure);
      }

      await _queue.markInFlight(operation.id);
      try {
        final result = await _backend.push(
          RemoteWriteRequest(
            operationId: operation.operationId,
            entity: entity,
            entityUuid: operation.entityUuid,
            kind: kind,
            payload: _decodePayload(operation.payload),
            localRevision: operation.localRevision,
          ),
        );
        await _queue.acknowledge(
          operation,
          remoteId: result.remoteId,
          remoteRevision: result.revision,
          now: _clock(),
        );
        await _metadata.recordSuccess(entity: entity, now: _clock());
        acknowledged += 1;
      } on SyncFailure catch (failure) {
        await _queue.recordFailure(operation, failure, now: _clock());
        await _metadata.recordFailure(
          entity: entity,
          failure: failure,
          now: _clock(),
        );
        return SyncRunResult(acknowledged: acknowledged, failure: failure);
      }
    }

    return SyncRunResult(acknowledged: acknowledged);
  }

  /// Local data is untouched by sync; this only makes the dependency explicit.
  FlowStateDatabase get database => _database;

  Map<String, Object?> _decodePayload(String payload) {
    if (payload.trim().isEmpty) return const <String, Object?>{};
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // A malformed payload is a local bug, not a reason to lose the operation.
      return const <String, Object?>{};
    }
    return const <String, Object?>{};
  }
}
