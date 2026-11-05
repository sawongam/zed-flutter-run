import 'dart:async';

import '../common/json_types.dart';
import 'messages.dart';
import 'notices.dart';

/// What [HotActions] needs from the proxy.
///
/// Contract: [inject] returns the adapter's response map INCLUDING
/// `success:false` responses; it throws only [TimeoutException] (no response
/// in time) and [StateError] (session closed).
abstract interface class RequestInjector {
  Future<DapJson> inject(String command, [Json? arguments, Duration? timeout]);

  bool get appStarted;

  void notice(String text, [NoticeLevel level = NoticeLevel.info]);
}

enum HotError { notStarted, busy, adapterError, timeout, sessionEnded }

class HotResult {
  const HotResult({
    required this.ok,
    this.error,
    this.message,
    this.duration = Duration.zero,
    this.coalesced = false,
  });

  final bool ok;
  final HotError? error;
  final String? message;
  final Duration duration;
  final bool coalesced;

  HotResult _asCoalesced() => HotResult(
    ok: ok,
    error: error,
    message: message,
    duration: duration,
    coalesced: true,
  );

  @override
  String toString() =>
      'HotResult(ok: $ok, error: $error, message: $message, '
      'coalesced: $coalesced)';
}

enum _Action { reload, restart }

class _Flight {
  _Flight(this.action);

  final _Action action;
  final Completer<HotResult> result = Completer<HotResult>();
  bool timedOut = false;
}

/// Hot reload / hot restart with coalescing and a single action in flight.
class HotActions {
  HotActions(
    this._injector, {
    this.timeout = const Duration(seconds: 120),
    this.waitingNoticeAfter = const Duration(seconds: 3),
  });

  static const Duration _lateLimit = Duration(minutes: 10);

  final RequestInjector _injector;
  final Duration timeout;
  final Duration waitingNoticeAfter;

  _Flight? _current;
  bool _clientRestart = false;
  Completer<void>? _clientRestartDone;

  bool get busy => _current != null || _clientRestart;

  Future<HotResult> reload({String reason = 'manual'}) =>
      _request(_Action.reload, reason);

  Future<HotResult> restart({String reason = 'manual'}) =>
      _request(_Action.restart, reason);

  /// Called by the proxy when the client sends `restart` (started) and when
  /// the response arrives (not started).
  void noteClientRestart({required bool started}) {
    if (started) {
      _clientRestart = true;
      _clientRestartDone ??= Completer<void>();
      return;
    }
    _clientRestart = false;
    final done = _clientRestartDone;
    _clientRestartDone = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  Future<HotResult> _request(_Action action, String reason) async {
    final name = action == _Action.reload ? 'reload' : 'restart';
    final waitsForRestart = action == _Action.reload && reason == 'save';
    while (true) {
      if (!_injector.appStarted) {
        _injector.notice(
          'Hot $name skipped: the app is still starting. Try again in a '
          'moment.',
        );
        return const HotResult(ok: false, error: HotError.notStarted);
      }
      if (_clientRestart) {
        if (!waitsForRestart) return _busy();
        final done = _clientRestartDone;
        if (done != null) {
          await done.future.timeout(timeout, onTimeout: () {});
        }
        if (_clientRestart) return _busy();
        continue;
      }
      final flight = _current;
      if (flight == null) return _run(action, reason);
      if (flight.timedOut) return _busy();
      if (flight.action == _Action.reload && action == _Action.reload) {
        final shared = await flight.result.future;
        return shared._asCoalesced();
      }
      if (flight.action == _Action.restart && waitsForRestart) {
        await flight.result.future;
        continue;
      }
      return _busy();
    }
  }

  HotResult _busy() => const HotResult(
    ok: false,
    error: HotError.busy,
    message: 'Another hot reload or restart is still running.',
  );

  Future<HotResult> _run(_Action action, String reason) {
    final flight = _Flight(action);
    _current = flight;
    final watch = Stopwatch()..start();
    final isReload = action == _Action.reload;
    final command = isReload ? 'hotReload' : 'hotRestart';
    final noun = isReload ? 'Reload' : 'Restart';
    Timer? waitingTimer;
    Timer? timeoutTimer;
    Timer? lateTimer;

    void finish() {
      waitingTimer?.cancel();
      timeoutTimer?.cancel();
      lateTimer?.cancel();
      if (identical(_current, flight)) _current = null;
    }

    void complete(HotResult result) {
      if (!flight.result.isCompleted) flight.result.complete(result);
    }

    waitingTimer = Timer(waitingNoticeAfter, () {
      if (flight.result.isCompleted) return;
      _injector.notice('$noun is waiting for the debugger to resume.');
    });
    // A save-triggered reload keeps waiting (the app may be paused at a
    // breakpoint); the late limit in the injector still bounds it.
    final noTimeout = isReload && reason == 'save';
    if (!noTimeout) {
      timeoutTimer = Timer(timeout, () {
        if (flight.result.isCompleted) return;
        flight.timedOut = true;
        final seconds = timeout.inSeconds;
        _injector.notice(
          'Hot ${noun.toLowerCase()} did not finish within $seconds seconds.',
          NoticeLevel.warn,
        );
        complete(
          HotResult(
            ok: false,
            error: HotError.timeout,
            message: 'No answer from the app within $seconds seconds.',
            duration: watch.elapsed,
          ),
        );
      });
    }
    lateTimer = Timer(_lateLimit, finish);

    Future<DapJson> pending;
    try {
      pending = _injector.inject(command, <String, Object?>{
        'reason': reason,
      }, _lateLimit);
    } on Object catch (e) {
      pending = Future<DapJson>.error(e);
    }
    pending.then(
      (response) {
        watch.stop();
        final timedOut = flight.timedOut;
        finish();
        if (timedOut) return;
        complete(_fromResponse(action, reason, response, watch.elapsed));
      },
      onError: (Object e) {
        watch.stop();
        finish();
        if (e is TimeoutException) {
          complete(
            HotResult(
              ok: false,
              error: HotError.timeout,
              message: 'No answer from the app in time.',
              duration: watch.elapsed,
            ),
          );
        } else {
          complete(
            HotResult(
              ok: false,
              error: HotError.sessionEnded,
              message: 'The debug session has ended.',
              duration: watch.elapsed,
            ),
          );
        }
      },
    );
    return flight.result.future;
  }

  HotResult _fromResponse(
    _Action action,
    String reason,
    DapJson response,
    Duration duration,
  ) {
    final isReload = action == _Action.reload;
    if (response['success'] == true) {
      if (isReload && reason == 'save') {
        _injector.notice(
          'Hot reload after saving finished in ${duration.inMilliseconds} ms.',
        );
      }
      return HotResult(ok: true, duration: duration);
    }
    final raw = response['message'];
    var message = raw is String && raw.trim().isNotEmpty
        ? raw.trim()
        : 'the adapter gave no reason';
    message = message.replaceFirst(RegExp(r'\.+$'), '');
    if (isReload && message.toLowerCase().contains('not supported')) {
      _injector.notice(
        'Hot reload is not supported here. Try the task '
        '"Flutter: Hot Restart" instead.',
        NoticeLevel.error,
      );
    } else if (isReload) {
      _injector.notice(
        'Hot reload failed: $message. Try the task "Flutter: Hot Restart".',
        NoticeLevel.error,
      );
    } else {
      _injector.notice('Hot restart failed: $message.', NoticeLevel.error);
    }
    return HotResult(
      ok: false,
      error: HotError.adapterError,
      message: message,
      duration: duration,
    );
  }
}
