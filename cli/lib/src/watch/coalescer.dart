import 'dart:async';

/// Outcome of one reload attempt.
enum ReloadResult { done, busy }

/// Trailing-edge debounce plus "one in flight, one follow-up" coalescing.
class ReloadCoalescer {
  ReloadCoalescer({
    required Duration debounce,
    required Future<ReloadResult> Function() reload,
    void Function(Object, StackTrace)? onError,
  }) : _debounce = debounce,
       _reload = reload,
       _onError = onError;

  final Duration _debounce;
  final Future<ReloadResult> Function() _reload;
  final void Function(Object, StackTrace)? _onError;

  static const Duration _maxBusyDelay = Duration(seconds: 2);

  Timer? _timer;
  bool _inFlight = false;
  bool _pendingAfter = false;
  bool _disposed = false;
  int _busyRetries = 0;

  bool get inFlight => _inFlight;

  /// Records a change: restarts the debounce, or, while a reload runs, asks
  /// for exactly one more reload afterwards.
  void notifyChange() {
    if (_disposed) return;
    if (_inFlight) {
      _pendingAfter = true;
      return;
    }
    _busyRetries = 0;
    _arm(_debounce);
  }

  void _arm(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      if (_disposed || _inFlight) return;
      unawaited(_run());
    });
  }

  Future<void> _run() async {
    _inFlight = true;
    try {
      while (!_disposed) {
        _pendingAfter = false;
        ReloadResult? result;
        try {
          result = await _reload();
        } on Object catch (e, st) {
          _onError?.call(e, st);
        }
        if (result == ReloadResult.busy) {
          // Something else (a restart, a manual reload) is running: try again
          // shortly, backing off, until it has finished.
          _pendingAfter = false;
          final factor = 1 << (_busyRetries < 6 ? _busyRetries : 6);
          _busyRetries++;
          var delay = _debounce * factor;
          if (delay > _maxBusyDelay) delay = _maxBusyDelay;
          _inFlight = false;
          if (!_disposed) _arm(delay);
          return;
        }
        _busyRetries = 0;
        if (!_pendingAfter) break;
      }
    } finally {
      _inFlight = false;
    }
  }

  /// Cancels pending work. A reload that is already running is not awaited
  /// (it may never complete when the adapter is going away); its result is
  /// ignored and no follow-up starts.
  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pendingAfter = false;
  }
}
