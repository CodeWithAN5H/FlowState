import 'package:drift/drift.dart';

import 'flowstate_database.dart';

class RecoveredFocusSession {
  const RecoveredFocusSession({
    required this.id,
    required this.startedAt,
    required this.elapsed,
    required this.isRunning,
  });

  final int id;
  final DateTime startedAt;
  final Duration elapsed;
  final bool isRunning;
}

class FocusSessionsRepository {
  FocusSessionsRepository(this._database);

  final FlowStateDatabase _database;

  Future<RecoveredFocusSession?> recover({DateTime? now}) async {
    final session =
        await (_database.select(_database.focusSessions)
              ..where((row) => row.status.equals('active'))
              ..orderBy([(row) => OrderingTerm.desc(row.id)])
              ..limit(1))
            .getSingleOrNull();
    if (session == null) return null;

    final currentTime = now ?? DateTime.now();
    var elapsedMillis = session.durationMillis;
    if (session.runningSinceMillis case final anchor?) {
      final delta = currentTime.millisecondsSinceEpoch - anchor;
      // A clock moved backwards: never subtract already accumulated time.
      elapsedMillis += delta.clamp(0, 1000 * 60 * 60 * 24 * 365 * 10);
    }
    return RecoveredFocusSession(
      id: session.id,
      startedAt: session.startedAt,
      elapsed: Duration(milliseconds: elapsedMillis),
      isRunning: session.runningSinceMillis != null,
    );
  }

  Future<int> start({DateTime? now}) async {
    final current = now ?? DateTime.now();
    final currentEpoch = current.millisecondsSinceEpoch;
    final existing = await recover(now: current);
    if (existing != null) {
      await (_database.update(
        _database.focusSessions,
      )..where((row) => row.id.equals(existing.id))).write(
        FocusSessionsCompanion(
          durationMillis: Value(existing.elapsed.inMilliseconds),
          runningSinceMillis: Value(currentEpoch),
        ),
      );
      return existing.id;
    }
    return _database
        .into(_database.focusSessions)
        .insert(
          FocusSessionsCompanion.insert(
            startedAt: current,
            status: 'active',
            runningSinceMillis: Value(currentEpoch),
          ),
        );
  }

  Future<RecoveredFocusSession?> pause({DateTime? now}) async {
    final session = await recover(now: now);
    if (session == null) return null;
    await (_database.update(
      _database.focusSessions,
    )..where((row) => row.id.equals(session.id))).write(
      FocusSessionsCompanion(
        durationMillis: Value(session.elapsed.inMilliseconds),
        runningSinceMillis: const Value(null),
      ),
    );
    return RecoveredFocusSession(
      id: session.id,
      startedAt: session.startedAt,
      elapsed: session.elapsed,
      isRunning: false,
    );
  }

  Future<RecoveredFocusSession?> resume({DateTime? now}) =>
      start(now: now).then((_) => recover(now: now));

  Future<RecoveredFocusSession?> finish({DateTime? now}) =>
      _end(status: 'completed', now: now);

  Future<RecoveredFocusSession?> cancel({DateTime? now}) =>
      _end(status: 'interrupted', now: now);

  Future<RecoveredFocusSession?> _end({
    required String status,
    DateTime? now,
  }) async {
    final session = await recover(now: now);
    if (session == null) return null;
    final endTime = now ?? DateTime.now();
    await (_database.update(
      _database.focusSessions,
    )..where((row) => row.id.equals(session.id))).write(
      FocusSessionsCompanion(
        durationMillis: Value(session.elapsed.inMilliseconds),
        endedAt: Value(endTime),
        status: Value(status),
        runningSinceMillis: const Value(null),
      ),
    );
    return RecoveredFocusSession(
      id: session.id,
      startedAt: session.startedAt,
      elapsed: session.elapsed,
      isRunning: false,
    );
  }

  Future<List<FocusSession>> completedBetween(DateTime start, DateTime end) =>
      (_database.select(_database.focusSessions)
            ..where(
              (row) =>
                  row.status.equals('completed') &
                  row.startedAt.isBiggerOrEqualValue(start) &
                  row.startedAt.isSmallerThanValue(end),
            )
            ..orderBy([(row) => OrderingTerm.desc(row.startedAt)]))
          .get();

  Future<Duration> completedDurationBetween(
    DateTime start,
    DateTime end,
  ) async {
    final sessions = await completedBetween(start, end);
    return Duration(
      milliseconds: sessions.fold<int>(
        0,
        (total, session) => total + session.durationMillis,
      ),
    );
  }

  /// Checkpoints the active wall-clock interval without changing timer state.
  Future<void> checkpoint({DateTime? now}) async {
    final session = await recover(now: now);
    if (session == null || !session.isRunning) return;
    final checkpointAt = now ?? DateTime.now();
    await (_database.update(
      _database.focusSessions,
    )..where((row) => row.id.equals(session.id))).write(
      FocusSessionsCompanion(
        durationMillis: Value(session.elapsed.inMilliseconds),
        runningSinceMillis: Value(checkpointAt.millisecondsSinceEpoch),
      ),
    );
  }
}
