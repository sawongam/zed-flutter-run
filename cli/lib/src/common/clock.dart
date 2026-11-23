import 'dart:async';

/// Time and timers, injected so that tests control them (for example with
/// `fake_async`) instead of waiting in real time.
abstract interface class Clock {
  DateTime now();

  /// A one-shot timer; like `Timer(d, cb)`.
  Timer timer(Duration d, void Function() cb);

  /// A repeating timer; like `Timer.periodic(d, cb)`.
  Timer periodic(Duration d, void Function(Timer) cb);

  /// Completes after [d] (like `Future.delayed`).
  Future<void> delay(Duration d);

  /// A new, stopped stopwatch.
  Stopwatch stopwatch();
}

/// The real clock.
class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();

  @override
  Timer timer(Duration d, void Function() cb) => Timer(d, cb);

  @override
  Timer periodic(Duration d, void Function(Timer) cb) => Timer.periodic(d, cb);

  @override
  Future<void> delay(Duration d) => Future<void>.delayed(d);

  @override
  Stopwatch stopwatch() => Stopwatch();
}
