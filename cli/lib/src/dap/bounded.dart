import 'dart:async';

import '../common/clock.dart';

/// Completes when [future] completes (value or error) or after [limit], never
/// with an error. Uses [clock] so tests control the wait.
Future<void> bounded(Clock clock, Future<Object?> future, Duration limit) {
  final completer = Completer<void>();
  final timer = clock.timer(limit, () {
    if (!completer.isCompleted) completer.complete();
  });
  void done() {
    timer.cancel();
    if (!completer.isCompleted) completer.complete();
  }

  // The outcome is delivered through [completer]; this chain only signals it.
  unawaited(future.then<void>((_) => done(), onError: (Object _) => done()));
  return completer.future;
}

/// Completes after [duration] on [clock] (like `Future.delayed`).
Future<void> pause(Clock clock, Duration duration) {
  final completer = Completer<void>();
  clock.timer(duration, completer.complete);
  return completer.future;
}

/// Like `Future.timeout`, but the timer comes from [clock]. Without
/// [onTimeout] a [TimeoutException] is thrown.
Future<T> withTimeout<T>(
  Clock clock,
  Future<T> future,
  Duration limit, {
  FutureOr<T> Function()? onTimeout,
}) {
  final completer = Completer<T>();
  final timer = clock.timer(limit, () {
    if (completer.isCompleted) return;
    if (onTimeout == null) {
      completer.completeError(TimeoutException(null, limit));
    } else {
      completer.complete(Future<T>.sync(onTimeout));
    }
  });
  // The outcome is delivered through [completer]; this chain only forwards it.
  unawaited(
    future.then<void>(
      (value) {
        timer.cancel();
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object e, StackTrace st) {
        timer.cancel();
        if (!completer.isCompleted) completer.completeError(e, st);
      },
    ),
  );
  return completer.future;
}
