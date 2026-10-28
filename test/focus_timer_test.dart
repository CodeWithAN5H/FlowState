import 'package:flutter_test/flutter_test.dart';
import 'package:flowstate/focus_timer.dart';

void main() {
  late FakeClock clock;
  late FocusTimer timer;

  setUp(() {
    clock = FakeClock();
    timer = FocusTimer(clockFactory: () => clock);
  });

  test('starts and measures from its monotonic clock', () {
    timer.startOrResume();
    clock.advance(const Duration(seconds: 42));

    expect(timer.isRunning, isTrue);
    expect(timer.elapsed, const Duration(seconds: 42));
  });

  test('pause preserves elapsed time and resume continues it', () {
    timer.startOrResume();
    clock.advance(const Duration(seconds: 20));
    timer.pause();
    clock.advance(const Duration(minutes: 3));

    expect(timer.isRunning, isFalse);
    expect(timer.elapsed, const Duration(seconds: 20));

    timer.startOrResume();
    clock.advance(const Duration(seconds: 10));
    expect(timer.elapsed, const Duration(seconds: 30));
  });

  test('finish returns duration and resets the timer', () {
    timer.startOrResume();
    clock.advance(const Duration(minutes: 5, seconds: 7));
    timer.pause();

    expect(timer.finish(), const Duration(minutes: 5, seconds: 7));
    expect(timer.hasStarted, isFalse);
    expect(timer.isRunning, isFalse);
    expect(timer.elapsed, Duration.zero);
    expect(timer.finish(), isNull);
  });

  test('cancel returns interrupted duration and clears the timer', () {
    timer.startOrResume();
    clock.advance(const Duration(seconds: 13));

    expect(timer.cancel(), const Duration(seconds: 13));
    expect(timer.hasStarted, isFalse);
    expect(timer.elapsed, Duration.zero);
  });

  test('pause and resume while idle are harmless', () {
    timer.pause();
    timer.startOrResume();
    timer.startOrResume();
    clock.advance(const Duration(seconds: 2));
    timer.pause();
    timer.pause();

    expect(timer.elapsed, const Duration(seconds: 2));
  });
}

class FakeClock implements MonotonicClock {
  Duration _elapsed = Duration.zero;
  bool _running = false;

  @override
  Duration get elapsed => _elapsed;

  void advance(Duration duration) {
    if (_running) _elapsed += duration;
  }

  @override
  void start() => _running = true;

  @override
  void stop() => _running = false;

  @override
  void reset() => _elapsed = Duration.zero;
}
