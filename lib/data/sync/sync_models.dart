/// Vocabulary for the local synchronization scaffolding.
///
/// Nothing here knows about Supabase, HTTP, or accounts. A future remote backend
/// implements [RemoteBackend] and this layer keeps working unchanged, which is
/// what keeps personal productivity independent of any remote service.
library;

/// Records that can be synchronized. Only the four user-facing record types carry
/// stable identifiers in schema v4; habit history and preferences follow later.
enum SyncEntity {
  task('task'),
  habit('habit'),
  note('note'),
  focusSession('focusSession');

  const SyncEntity(this.wireName);

  final String wireName;

  static SyncEntity? tryParse(String value) {
    for (final entity in values) {
      if (entity.wireName == value) return entity;
    }
    return null;
  }
}

/// What happened locally to a record.
enum SyncOperationKind {
  create('create'),
  update('update'),
  delete('delete');

  const SyncOperationKind(this.wireName);

  final String wireName;

  static SyncOperationKind? tryParse(String value) {
    for (final kind in values) {
      if (kind.wireName == value) return kind;
    }
    return null;
  }
}

enum SyncOperationStatus {
  /// Waiting to be claimed.
  pending,

  /// Claimed by a run that has not finished; treated as pending again after a
  /// restart, because the remote outcome is unknown.
  inFlight,

  /// Attempted and not acknowledged. Whether it will be retried is expressed by
  /// `nextAttemptAt`, not by the status alone.
  failed,

  /// Delivered and recorded locally. Kept as evidence rather than deleted.
  acknowledged,
}

/// Why a remote operation did not succeed.
///
/// These are deliberately distinct: "you are offline" needs a different response
/// from "your session expired", and neither is a reason to hide or invalidate the
/// local record.
enum SyncFailureKind {
  /// No request was made: no backend configured, or the device is offline.
  offline,

  /// 401: the session expired or was never established.
  authenticationRequired,

  /// 403: authenticated, but not allowed (for example, removed from a room).
  permissionDenied,

  /// 409: the remote revision moved on.
  conflict,

  /// 429: slow down.
  rateLimited,

  /// 5xx other than 503.
  serverError,

  /// 503: the backend is paused or otherwise temporarily unavailable.
  backendPaused,

  /// Any other 4xx: the request itself is wrong and retrying will not help.
  invalidRequest;

  bool get isRetryable => switch (this) {
    offline || rateLimited || serverError || backendPaused => true,
    authenticationRequired ||
    permissionDenied ||
    conflict ||
    invalidRequest => false,
  };

  /// The status this kind represents, when it came from a response.
  int? get httpStatus => switch (this) {
    authenticationRequired => 401,
    permissionDenied => 403,
    conflict => 409,
    rateLimited => 429,
    serverError => 500,
    backendPaused => 503,
    offline || invalidRequest => null,
  };

  static SyncFailureKind fromName(String? name) {
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return SyncFailureKind.serverError;
  }
}

/// A refusal from the remote side, or the absence of one.
class SyncFailure implements Exception {
  const SyncFailure(
    this.kind, {
    this.message,
    this.statusCode,
    this.retryAfter,
  });

  /// Maps an HTTP status to a distinguishable outcome. 503 is separated from the
  /// other 5xx codes because a paused backend is expected to come back.
  factory SyncFailure.fromHttpStatus(
    int statusCode, {
    String? message,
    Duration? retryAfter,
  }) {
    final kind = switch (statusCode) {
      401 => SyncFailureKind.authenticationRequired,
      403 => SyncFailureKind.permissionDenied,
      409 => SyncFailureKind.conflict,
      429 => SyncFailureKind.rateLimited,
      503 => SyncFailureKind.backendPaused,
      >= 500 => SyncFailureKind.serverError,
      >= 400 => SyncFailureKind.invalidRequest,
      _ => SyncFailureKind.serverError,
    };
    return SyncFailure(
      kind,
      message: message,
      statusCode: statusCode,
      retryAfter: retryAfter,
    );
  }

  static const offline = SyncFailure(
    SyncFailureKind.offline,
    message: 'No connection to the sync backend.',
  );

  final SyncFailureKind kind;
  final String? message;
  final int? statusCode;

  /// Honoured in preference to the exponential backoff when the server sends one.
  final Duration? retryAfter;

  bool get isRetryable => kind.isRetryable;

  @override
  String toString() =>
      'SyncFailure(${kind.name}'
      '${statusCode == null ? '' : ', status $statusCode'}'
      '${message == null ? '' : ': $message'})';
}

/// Exponential backoff for a failed operation: 1s, 2s, 4s, … capped at five
/// minutes. Pure, so it can be tested without a clock.
Duration retryDelayFor(int attemptCount) {
  final exponent = (attemptCount - 1).clamp(0, 8);
  final candidate = Duration(seconds: 1 << exponent);
  const cap = Duration(minutes: 5);
  return candidate > cap ? cap : candidate;
}
