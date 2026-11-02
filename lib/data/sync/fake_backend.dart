import 'remote_backend.dart';
import 'sync_models.dart';

/// In-memory [RemoteBackend] used by tests, and by nothing in the app.
///
/// It exists so the queue, ordering, acknowledgement and failure behaviour can be
/// exercised without a network, an account, or Supabase. Scripted failures are
/// queued with [failNext].
class FakeRemoteBackend implements RemoteBackend {
  FakeRemoteBackend({this.isConfigured = true});

  @override
  final bool isConfigured;

  /// Requests that reached the backend, in the order they arrived.
  final List<RemoteWriteRequest> pushed = <RemoteWriteRequest>[];

  final Map<String, int> _revisions = <String, int>{};
  final List<SyncFailure> _scriptedFailures = <SyncFailure>[];
  int _nextRemoteId = 1;

  int get pushCount => pushed.length;

  List<String> get pushedOperationIds => [
    for (final request in pushed) request.operationId,
  ];

  /// Makes the next [push] throw [failure].
  void failNext(SyncFailure failure) => _scriptedFailures.add(failure);

  @override
  Future<RemoteWriteResult> push(RemoteWriteRequest request) async {
    if (_scriptedFailures.isNotEmpty) {
      throw _scriptedFailures.removeAt(0);
    }
    pushed.add(request);
    final key = '${request.entity.wireName}:${request.entityUuid}';
    final revision = (_revisions[key] ?? 0) + 1;
    _revisions[key] = revision;
    return RemoteWriteResult(
      remoteId: 'remote-${_nextRemoteId++}',
      revision: revision,
    );
  }

  @override
  Future<RemotePullResult> pull({
    required SyncEntity entity,
    String? cursor,
  }) async => const RemotePullResult(records: <RemoteRecord>[]);
}
