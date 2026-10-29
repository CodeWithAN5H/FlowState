import 'package:flutter_test/flutter_test.dart';
import 'package:flowstate/focus_timer.dart';

void main() {
  test('restores running elapsed time and continues monotonically', () {
    final clock = FakeClock();
    final timer = FocusTimer(clockFactory: () => clock);

    timer.restore(const Duration(minutes: 4, seconds: 30), running: true);
    expect(timer.hasStarted, isTrue);
    expect(timer.isRunning, isTrue);
    expect(timer.elapsed, const Duration(minutes: 4, seconds: 30));

    clock.advance(const Duration(seconds: 8));
    expect(timer.elapsed, const Duration(minutes: 4, seconds: 38));
  });

  test(
    'restores paused elapsed time and resumes without counting pause time',
    () {
      final clock = FakeClock();
      final timer = FocusTimer(clockFactory: () => clock);

      timer.restore(const Duration(minutes: 6), running: false);
      clock.advance(const Duration(minutes: 10));
      expect(timer.elapsed, const Duration(minutes: 6));

      timer.startOrResume();
      clock.advance(const Duration(seconds: 12));
      expect(timer.elapsed, const Duration(minutes: 6, seconds: 12));
    },
  );
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
