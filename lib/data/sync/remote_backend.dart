import 'sync_models.dart';

/// One operation on its way to whatever remote backend is configured.
class RemoteWriteRequest {
  const RemoteWriteRequest({
    required this.operationId,
    required this.entity,
    required this.entityUuid,
    required this.kind,
    required this.payload,
    required this.localRevision,
  });

  final String operationId;
  final SyncEntity entity;
  final String entityUuid;
  final SyncOperationKind kind;

  /// The fields as they were when the operation was queued, so a later local edit
  /// cannot rewrite history.
  final Map<String, Object?> payload;
  final int localRevision;
}

/// What the remote said after accepting a write.
class RemoteWriteResult {
  const RemoteWriteResult({required this.remoteId, required this.revision});

  final String remoteId;

  /// The server's monotonically increasing revision for this record. It becomes
  /// the base revision for the next update.
  final int revision;
}

class RemoteRecord {
  const RemoteRecord({
    required this.entityUuid,
    required this.remoteId,
    required this.revision,
    required this.payload,
    this.deleted = false,
  });

  final String entityUuid;
  final String remoteId;
  final int revision;
  final Map<String, Object?> payload;
  final bool deleted;
}

class RemotePullResult {
  const RemotePullResult({required this.records, this.cursor});

  final List<RemoteRecord> records;
  final String? cursor;
}

/// The seam between FlowState and any remote service.
///
/// Milestone 2B ships no implementation that talks to a network. The engine is
/// written against this interface so that adding Supabase later is a matter of
/// implementing it, not of changing the application or the local schema.
///
/// A backend signals failure by throwing a [SyncFailure]; the engine maps that to
/// retry and status behaviour.
abstract class RemoteBackend {
  /// False when nothing is configured, which is the normal state for a local-only
  /// user. The engine reports that as `SyncFailureKind.offline` without calling
  /// anything.
  bool get isConfigured;

  Future<RemoteWriteResult> push(RemoteWriteRequest request);

  /// Optional pull support; unused in this milestone, present so the interface
  /// does not need reshaping later.
  Future<RemotePullResult> pull({required SyncEntity entity, String? cursor});
}
