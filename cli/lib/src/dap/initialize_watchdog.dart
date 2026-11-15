import 'dart:async';

import '../common/clock.dart';

/// The adapter must answer `initialize` in time. After a while one notice says
/// Flutter is still starting; after the limit the session fails with a clear
/// message.
class InitializeWatchdog {
  InitializeWatchdog({
    required Clock clock,
    required this.timeout,
    required this.noticeAfter,
    required bool Function() isEnded,
    required void Function() onSlow,
    required void Function(String reason) onTimeout,
  }) : _clock = clock,
       _isEnded = isEnded,
       _onSlow = onSlow,
       _onTimeout = onTimeout;

  final Clock _clock;
  final Duration timeout;
  final Duration noticeAfter;
  final bool Function() _isEnded;
  final void Function() _onSlow;
  final void Function(String reason) _onTimeout;

  Object? _seq;
  bool _answered = false;
  Timer? _timeoutTimer;
  Timer? _noticeTimer;

  /// The sequence number of the client's `initialize`, if one was seen.
  Object? get seq => _seq;

  /// True once the request was answered or the start-up already failed.
  bool get answered => _answered;

  /// True while an `initialize` was seen and nothing answered it yet.
  bool get isPending => _seq != null && !_answered;

  /// Starts watching the client's `initialize` request [seq].
  void arm(Object? seq) {
    _seq = seq;
    cancel();
    _noticeTimer = _clock.timer(noticeAfter, () {
      if (_answered || _isEnded()) return;
      _onSlow();
    });
    _timeoutTimer = _clock.timer(timeout, () {
      if (_answered || _isEnded()) return;
      _onTimeout(
        'The Flutter debug adapter did not answer within '
        '${_describe(timeout)}.',
      );
    });
  }

  /// Marks the start-up as answered when [requestSeq] is the `initialize`
  /// being watched. Returns true when it was.
  bool onResponse(Object? requestSeq) {
    if (_seq == null || requestSeq != _seq || _answered) return false;
    markAnswered();
    return true;
  }

  /// Ends the watch (answered, failed or crashed).
  void markAnswered() {
    _answered = true;
    cancel();
  }

  /// Stops both timers without changing [answered].
  void cancel() {
    _timeoutTimer?.cancel();
    _noticeTimer?.cancel();
    _timeoutTimer = null;
    _noticeTimer = null;
  }
}

String _describe(Duration d) => d.inSeconds >= 1
    ? '${d.inSeconds} seconds'
    : '${d.inMilliseconds} milliseconds';
