/// A monotonic source of elapsed time used by [FocusTimer].
abstract interface class MonotonicClock {
  Duration get elapsed;
  void start();
  void stop();
  void reset();
}

/// Production clock backed by Dart's monotonic Stopwatch.
class StopwatchClock implements MonotonicClock {
  final Stopwatch _stopwatch = Stopwatch();

  @override
  Duration get elapsed => _stopwatch.elapsed;

  @override
  void start() => _stopwatch.start();

  @override
  void stop() => _stopwatch.stop();

  @override
  void reset() => _stopwatch.reset();
}

/// Tracks an in-memory focus stopwatch independently of UI refresh intervals.
///
/// The elapsed value comes from a monotonic clock, not periodic counter
/// decrements. Persistence and recovery are intentionally left for a later
/// milestone.
class FocusTimer {
  FocusTimer({MonotonicClock Function()? clockFactory})
      : _clockFactory = clockFactory ?? StopwatchClock.new,
        _clock = (clockFactory ?? StopwatchClock.new)();

  final MonotonicClock Function() _clockFactory;
  MonotonicClock _clock;
  Duration _elapsedBeforeCurrentRun = Duration.zero;

  bool hasStarted = false;
  bool isRunning = false;

  Duration get elapsed => _elapsedBeforeCurrentRun + _clock.elapsed;

  void startOrResume() {
    if (isRunning) return;
    hasStarted = true;
    isRunning = true;
    _clock.start();
  }

  void pause() {
    if (!isRunning) return;
    _elapsedBeforeCurrentRun += _clock.elapsed;
    _clock.stop();
    _clock.reset();
    isRunning = false;
  }

  /// Stops and clears the timer, returning its elapsed duration if active.
  Duration? finish() => _endSession();

  /// Stops and clears the timer as interrupted, returning its elapsed duration.
  Duration? cancel() => _endSession();

  Duration? _endSession() {
    if (!hasStarted) return null;
    final duration = elapsed;
    _clock.stop();
    _clock.reset();
    _clock = _clockFactory();
    _elapsedBeforeCurrentRun = Duration.zero;
    hasStarted = false;
    isRunning = false;
    return duration;
  }
}
