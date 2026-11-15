import 'dart:async';

import '../common/clock.dart';
import '../common/json_types.dart';
import '../common/logger.dart';
import 'bounded.dart';
import 'channel.dart';
import 'messages.dart';
import 'proxy_options.dart';
import 'session_phase.dart';

/// What the [ShutdownCoordinator] needs from the proxy that owns it.
abstract interface class ShutdownHost {
  /// True when the client started the program with `launch` (so the proxy
  /// owns it and must stop it); false for `attach`.
  bool get isLaunchSession;

  /// The program already ended (a `terminated` or `exited` event was seen).
  bool get programEnded;

  /// An exit code forced by an earlier error, if any.
  int? get exitCodeOverride;

  void sendToClient(DapJson message);

  void sendToAdapter(DapJson message);

  void notice(String text);

  int nextSyntheticSeq();

  /// Sends a request of the proxy's own to the adapter (see `inject`).
  Future<DapJson> inject(String command, Json arguments, Duration timeout);

  Future<void> flushClient();

  /// Ends the session with [code] (the proxy's final teardown).
  Future<void> finish(int code);

  /// Runs [body] so that a failure is logged and ends the session.
  void guard(Future<void> Function() body, String what);
}

/// Progress of one stop request (`terminate` or `disconnect`).
enum StopFlow { idle, requested, finishing, finished }

/// Owns every way a session stops: the editor's `terminate` and `disconnect`
/// (their answers are held back until the cleanup is done), a shutdown after
/// EOF or a signal, the descendant snapshots taken beforehand and the sweep
/// that kills what survived. Zed's real stop path is `terminate`, then
/// `disconnect`, then EOF.
class ShutdownCoordinator {
  ShutdownCoordinator({
    required this.host,
    required this.adapter,
    required this.phase,
    required this.clock,
    required this.options,
    required Logger log,
    Future<void> Function()? onShutdownStarted,
    Future<void> Function()? onShutdownCleanup,
  }) : _log = log,
       _onShutdownStarted = onShutdownStarted,
       _onShutdownCleanup = onShutdownCleanup;

  final ShutdownHost host;
  final AdapterConnection adapter;
  final SessionPhaseMachine phase;
  final Clock clock;
  final ProxyOptions options;
  final Logger _log;
  final Future<void> Function()? _onShutdownStarted;
  final Future<void> Function()? _onShutdownCleanup;

  ProxyTimings get _t => options.timings;

  // adapter facts
  bool _adapterExited = false;
  bool _crashed = false;
  bool _treeKilled = false;
  final Completer<void> _adapterExit = Completer<void>();
  final Completer<void> _terminatedSeen = Completer<void>();

  // terminate flow
  StopFlow _terminate = StopFlow.idle;
  Object? _terminateSeq;
  DapJson? _heldTerminateResponse;
  bool _terminateDeadline = false;
  final Completer<void> _terminateDone = Completer<void>();
  Timer? _terminateTimer;
  Timer? _stoppingTimer;

  // disconnect flow
  StopFlow _disconnect = StopFlow.idle;
  Object? _disconnectSeq;
  DapJson? _heldDisconnectResponse;
  Timer? _disconnectTimer;

  bool _shutdownRequested = false;
  bool _finishing = false;

  // shared plumbing
  Future<Set<int>>? _startFuture;
  Future<void>? _cleanupFuture;
  Future<void>? _shutdownFuture;

  // descendant snapshots
  final List<Set<int>> _recent = [];
  bool _snapshotRunning = false;
  Timer? _snapshotTimer;
  Timer? _firstSnapshotTimer;

  bool get terminatedSeen => _terminatedSeen.isCompleted;

  StopFlow get terminateFlow => _terminate;

  StopFlow get disconnectFlow => _disconnect;

  bool get terminateRequested => _terminate != StopFlow.idle;

  bool get disconnectRequested => _disconnect != StopFlow.idle;

  /// The editor, a signal or an error asked the session to stop.
  bool get stopRequested =>
      terminateRequested || disconnectRequested || _shutdownRequested;

  /// The snapshot step ran (or is running): a stop is under way.
  bool get shutdownStarted => _startFuture != null;

  /// The adapter exited; its messages are still being drained.
  void markAdapterExited() {
    _adapterExited = true;
    if (!_adapterExit.isCompleted) _adapterExit.complete();
    _snapshotTimer?.cancel();
  }

  void markCrashed() => _crashed = true;

  /// The adapter reported `terminated`.
  void markTerminatedSeen() {
    if (!_terminatedSeen.isCompleted) _terminatedSeen.complete();
  }

  /// The proxy ended the session itself (for example a failed start-up).
  void markShutdownRequested() {
    _shutdownRequested = true;
    phase.beginStopping();
  }

  /// Begins recording the adapter's descendants while it runs, so a killed
  /// adapter's reparented children can still be swept (also on Windows,
  /// where `taskkill /T` alone needs a live parent).
  void startSnapshots() {
    _firstSnapshotTimer = clock.timer(_t.firstSnapshotDelay, refreshSnapshot);
    _snapshotTimer = clock.periodic(
      options.snapshotInterval,
      (_) => refreshSnapshot(),
    );
  }

  void refreshSnapshot() {
    if (_adapterExited || phase.isFinishing || _startFuture != null) return;
    if (host.programEnded || _snapshotRunning) return;
    _snapshotRunning = true;
    // Fire-and-forget periodic snapshot; failures are logged, not propagated.
    unawaited(
      withTimeout(clock, adapter.snapshotDescendants(), _t.snapshotWait)
          .then<void>((pids) {
            if (_adapterExited || _startFuture != null) return;
            _recent.add(pids);
            if (_recent.length > 2) _recent.removeAt(0);
          }, onError: (Object e) => _log.debug('Periodic snapshot failed: $e'))
          .whenComplete(() => _snapshotRunning = false),
    );
  }

  Future<void> handleTerminate(DapMessage message) async {
    // The final teardown already began: nothing to stop any more, and a new
    // flow would leave timers and a late synthetic answer behind.
    if (_finishing || phase.isFinishing) return;
    if (terminateRequested) {
      host.sendToAdapter(message.raw);
      return;
    }
    _terminate = StopFlow.requested;
    _terminateSeq = message.seq;
    phase.beginStopping();
    _terminateTimer = clock.timer(options.terminateTimeout, () {
      _terminateDeadline = true;
      host.guard(_finishTerminate, 'Finishing terminate');
    });
    _stoppingTimer = clock.timer(_t.stoppingNoticeAfter, () {
      if (_terminate != StopFlow.finished) host.notice('Stopping the app...');
    });
    await startShutdown();
    if (_terminate.index >= StopFlow.finishing.index || phase.isFinishing) {
      return;
    }
    if (_adapterExited) {
      await _finishTerminate();
      return;
    }
    host.sendToAdapter(message.raw);
  }

  /// Finishes the terminate once the adapter answered it and the program
  /// reported `terminated`.
  void maybeFinishTerminate() {
    if (!terminateRequested || _terminate.index >= StopFlow.finishing.index) {
      return;
    }
    if (_heldTerminateResponse != null && terminatedSeen) {
      host.guard(_finishTerminate, 'Finishing terminate');
    }
  }

  Future<void> _finishTerminate() async {
    if (_terminate.index >= StopFlow.finishing.index) {
      return _terminateDone.future;
    }
    _terminate = StopFlow.finishing;
    _terminateTimer?.cancel();
    _stoppingTimer?.cancel();
    try {
      await cleanup();
      final held = _heldTerminateResponse;
      if (held != null) {
        host.sendToClient(held);
      } else {
        host.sendToClient(_answer(DapCommands.terminate, _terminateSeq));
      }
      await host.flushClient();
    } on Object catch (e, st) {
      _log.error('Finishing terminate failed', e, st);
    } finally {
      _terminate = StopFlow.finished;
      if (!_terminateDone.isCompleted) _terminateDone.complete();
    }
  }

  Future<void> handleDisconnect(DapMessage message) async {
    if (disconnectRequested) {
      host.sendToAdapter(message.raw);
      return;
    }
    _disconnect = StopFlow.requested;
    _disconnectSeq = message.seq;
    phase.beginStopping();
    await startShutdown();
    if (terminateRequested && _terminate != StopFlow.finished) {
      await _terminateDone.future;
    } else if (!terminateRequested &&
        host.isLaunchSession &&
        !terminatedSeen &&
        !_adapterExited) {
      await bounded(
        clock,
        Future.any<void>([
          _injectQuietly(DapCommands.terminate),
          _terminatedSeen.future,
        ]),
        options.terminateTimeout,
      );
    }
    if (_adapterExited || phase.isFinishing) {
      await _finishDisconnect();
      return;
    }
    host.sendToAdapter(message.raw);
    _disconnectTimer = clock.timer(options.exitWait, () {
      host.guard(_finishDisconnect, 'Finishing disconnect');
    });
  }

  Future<void> _finishDisconnect() async {
    if (_disconnect.index >= StopFlow.finishing.index) return;
    _disconnect = StopFlow.finishing;
    _disconnectTimer?.cancel();
    await cleanup();
    host.sendToClient(
      _heldDisconnectResponse ??
          _answer(DapCommands.disconnect, _disconnectSeq),
    );
    await host.finish(0);
  }

  DapJson _answer(String command, Object? requestSeq) => makeResponse(
    requestSeq: requestSeq is int ? requestSeq : 0,
    command: command,
    success: true,
    seq: host.nextSyntheticSeq(),
  );

  /// Handles an adapter response to the client's `terminate` or `disconnect`.
  /// Returns true when it was held back (the caller must not forward it).
  bool holdResponse(DapMessage response) {
    final requestSeq = response.requestSeq;
    if (terminateRequested && requestSeq == _terminateSeq) {
      if (_terminate == StopFlow.finished) return true;
      _heldTerminateResponse = response.raw;
      maybeFinishTerminate();
      return true;
    }
    if (disconnectRequested && requestSeq == _disconnectSeq) {
      _heldDisconnectResponse = response.raw;
      if (_finishing) return true;
      // The adapter answered: do not make the editor wait for it to exit.
      _disconnectTimer?.cancel();
      _disconnectTimer = clock.timer(_t.disconnectGrace, () {
        host.guard(_finishDisconnect, 'Finishing disconnect');
      });
      return true;
    }
    return false;
  }

  /// After an orderly adapter exit: answer what is still open and end.
  Future<void> finishAfterAdapterExit() async {
    if (terminateRequested && _terminate != StopFlow.finished) {
      await _finishTerminate();
    }
    if (disconnectRequested) {
      await _finishDisconnect();
    } else if (!_shutdownRequested) {
      await host.finish(0);
    }
  }

  /// Orderly shutdown (same cleanup as a stdin EOF). Idempotent.
  Future<void> shutdown(String reason, {required Future<int> done}) =>
      _shutdownFuture ??= _shutdownImpl(reason, done);

  Future<void> _shutdownImpl(String reason, Future<int> done) async {
    _log.info('Shutting down: $reason');
    markShutdownRequested();
    await startShutdown();
    if (disconnectRequested) {
      await done;
      return;
    }
    if (terminateRequested && _terminate != StopFlow.finished) {
      await _terminateDone.future;
    }
    if (!_adapterExited && !phase.isFinishing) {
      if (!terminateRequested && host.isLaunchSession && !terminatedSeen) {
        await bounded(
          clock,
          Future.any<void>([
            _injectQuietly(DapCommands.terminate),
            _terminatedSeen.future,
            _adapterExit.future,
          ]),
          options.terminateTimeout,
        );
      }
      if (!_adapterExited) {
        unawaited(_injectQuietly(DapCommands.disconnect));
        await bounded(clock, _adapterExit.future, options.exitWait);
      }
    }
    await host.finish(host.exitCodeOverride ?? 0);
  }

  Future<void> _injectQuietly(String command) async {
    try {
      await host.inject(command, <String, Object?>{}, options.terminateTimeout);
    } on Object catch (e) {
      _log.debug('Injected $command ended without a response: $e');
    }
  }

  /// Step 1 and 2 of every stop: tell the owner (session file) and snapshot
  /// the adapter's descendants before anything is signalled.
  Future<Set<int>> startShutdown() => _startFuture ??= () async {
    _snapshotTimer?.cancel();
    try {
      await withTimeout<void>(
        clock,
        Future<void>.sync(() => _onShutdownStarted?.call()),
        _t.hookWait,
        onTimeout: () {},
      );
    } on Object catch (e, st) {
      _log.error('onShutdownStarted failed', e, st);
    }
    if (!_adapterExited) {
      // A normal stop targets what is a descendant right now, nothing older.
      try {
        return await withTimeout(
          clock,
          adapter.snapshotDescendants(),
          _t.snapshotWait,
        );
      } on Object catch (e) {
        _log.debug('Could not snapshot adapter descendants: $e');
        return <int>{};
      }
    }
    // The adapter crashed: its children were reparented, so use what the
    // last polls saw (the sweep spares shared daemons and guards PID reuse).
    return _crashed ? {for (final s in _recent) ...s} : <int>{};
  }();

  /// Runs the owner's cleanup hook, then sweeps. Runs once.
  Future<void> cleanup() => _cleanupFuture ??= () async {
    final snapshot = await startShutdown();
    try {
      await withTimeout<void>(
        clock,
        Future<void>.sync(() => _onShutdownCleanup?.call()),
        _t.hookWait,
        onTimeout: () {},
      );
    } on Object catch (e, st) {
      _log.error('onShutdownCleanup failed', e, st);
    }
    await _sweep(snapshot);
  }();

  /// Last resort: only when processes may have survived the graceful stop.
  Future<void> _sweep(Set<int> snapshot) async {
    if (!_adapterExited && !_terminateDeadline && !_crashed) {
      // Most adapters exit by themselves once the app is stopped.
      await bounded(clock, _adapterExit.future, _t.adapterExitGrace);
    }
    final candidates = snapshot.difference(<int>{adapter.pid});
    if (candidates.isEmpty && _adapterExited) return;
    if (candidates.isNotEmpty && !_terminateDeadline) {
      // Give descendants that are already exiting a moment to finish.
      await pause(clock, _t.sweepGrace);
    }
    await _killTree(candidates);
  }

  Future<void> _killTree(Set<int> extraPids) async {
    if (!_adapterExited) _treeKilled = true;
    try {
      await withTimeout(
        clock,
        adapter.terminateTree(extraPids: extraPids, crashed: _crashed),
        _terminateDeadline ? _t.sweepWaitLate : _t.sweepWait,
      );
    } on Object catch (e) {
      _log.warn('Sweeping adapter processes failed: $e');
    }
  }

  /// Called when the final teardown begins: stops every timer and releases
  /// anyone waiting for the terminate.
  void beginFinish() {
    _snapshotTimer?.cancel();
    _firstSnapshotTimer?.cancel();
    _terminateTimer?.cancel();
    _stoppingTimer?.cancel();
    _disconnectTimer?.cancel();
    _finishing = true;
    if (terminateRequested) _terminate = StopFlow.finished;
    if (!_terminateDone.isCompleted) _terminateDone.complete();
  }

  /// Teardown: the cleanup, then a last tree kill if none happened yet.
  Future<void> cleanupAndKill() async {
    await cleanup();
    if (!_adapterExited && !_treeKilled) {
      final snapshot = await startShutdown();
      await _killTree(snapshot.difference(<int>{adapter.pid}));
    }
  }
}
