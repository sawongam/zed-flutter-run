import 'dart:async';

import '../common/clock.dart';
import '../common/json_types.dart';
import '../common/logger.dart';
import 'bounded.dart';
import 'channel.dart';
import 'failure_reporter.dart';
import 'framing.dart';
import 'hot_actions.dart';
import 'initialize_watchdog.dart';
import 'injected_requests.dart';
import 'launch_rewriter.dart';
import 'messages.dart';
import 'notices.dart';
import 'proxy_options.dart';
import 'proxy_state.dart';
import 'session_phase.dart';
import 'session_tracker.dart';
import 'shutdown_coordinator.dart';
import 'stderr_tail.dart';

export 'proxy_options.dart';

/// The Dart-side DAP proxy between the editor and the debug adapter.
///
/// Client messages pass through untouched except `launch`/`attach` arguments;
/// injected requests use a disjoint sequence range; shutdown follows Zed's
/// real stop path and lives in [ShutdownCoordinator].
class DapProxy implements RequestInjector {
  DapProxy({
    required DapChannel client,
    required AdapterConnection adapter,
    required ProxyOptions options,
    required LaunchRewriter rewriter,
    Future<void> Function()? onShutdownStarted,
    Future<void> Function()? onShutdownCleanup,
    Logger? logger,
    Clock clock = const SystemClock(),
  }) : _client = client,
       _adapter = adapter,
       _options = options,
       _rewriter = rewriter,
       _clock = clock,
       _log = logger ?? Logger.silent() {
    _phase = SessionPhaseMachine(logger: _log);
    _tracker = SessionTracker(
      kind: options.kind,
      onNotice: notice,
      onProcessActivity: () => _coordinator.refreshSnapshot(),
    );
    _coordinator = ShutdownCoordinator(
      host: _Host(this),
      adapter: adapter,
      phase: _phase,
      clock: clock,
      options: options,
      log: _log,
      onShutdownStarted: onShutdownStarted,
      onShutdownCleanup: onShutdownCleanup,
    );
    _watchdog = InitializeWatchdog(
      clock: clock,
      timeout: options.initializeTimeout,
      noticeAfter: options.initializeNoticeAfter,
      isEnded: () => _phase.isFinishing,
      onSlow: () => notice(
        'Flutter is still starting. The first run after an upgrade, or '
        'another flutter command holding the startup lock, can take a while.',
      ),
      onTimeout: (reason) =>
          _guard(() => _failStartup(reason), 'Startup failure'),
    );
    _failures = FailureReporter(
      watchdog: _watchdog,
      stderrTail: _stderrTail,
      send: _sendToClient,
      nextSeq: _injected.nextSyntheticSeq,
      notice: notice,
    );
    // Fire-and-forget: reacts to the session ending, nothing awaits it.
    unawaited(
      _closed.future.then<void>(
        (_) =>
            _injected.failPending(StateError('The debug session has ended.')),
      ),
    );
  }

  final DapChannel _client;
  final AdapterConnection _adapter;
  final ProxyOptions _options;
  final LaunchRewriter _rewriter;
  final Clock _clock;
  final Logger _log;
  final InjectedRequests _injected = InjectedRequests();
  late final SessionTracker _tracker;
  late final FailureReporter _failures;
  late final SessionPhaseMachine _phase;
  late final ShutdownCoordinator _coordinator;
  late final InitializeWatchdog _watchdog;

  /// The hot reload / restart coordinator for this session.
  late final HotActions hotActions = HotActions(this, clock: _clock);

  bool _clientGone = false;
  int? _exitCodeOverride;

  final Completer<int> _done = Completer<int>();
  final Completer<void> _closed = Completer<void>();
  final Completer<void> _adapterMessagesDone = Completer<void>();

  StreamSubscription<DapJson>? _clientSub;
  StreamSubscription<DapJson>? _adapterSub;
  StreamSubscription<String>? _stderrSub;
  Future<void> _clientQueue = Future<void>.value();
  final StderrTail _stderrTail = StderrTail();

  /// `request_seq`s of `restart` requests the client sent itself.
  final Set<Object?> _clientRestartSeqs = {};

  Stream<ProxyEvent> get events => _tracker.events;

  ProxyState get state => _tracker.state;

  /// Where the session is in its life (starting, running, stopping, ...).
  SessionPhase get phase => _phase.phase;

  @override
  bool get appStarted => _tracker.state.appStarted;

  /// Runs the proxy; completes with the exit code once fully shut down.
  Future<int> run() {
    if (!_phase.transition(SessionPhase.running)) return _done.future;
    _clientSub = _client.messages.listen(
      _onClientMessage,
      onError: (Object e, StackTrace st) => _onClientError(e),
      onDone: _onClientEof,
    );
    _adapterSub = _adapter.channel.messages.listen(
      _onAdapterMessage,
      onError: (Object e, StackTrace st) => _onAdapterError(e),
      onDone: () {
        if (!_adapterMessagesDone.isCompleted) _adapterMessagesDone.complete();
      },
    );
    _stderrSub = _adapter.stderrLines.listen((line) {
      _stderrTail.add(line);
      _log.debug('adapter stderr: $line');
    }, onError: (Object e) => _log.debug('adapter stderr error: $e'));
    _coordinator.startSnapshots();
    // Fire-and-forget: reacts to the adapter exiting; errors go through _guard.
    unawaited(
      _adapter.exitCode.then<void>(
        (code) => _guard(() => _onAdapterExit(code), 'Handling adapter exit'),
        onError: (Object e, StackTrace st) {
          _log.error('Could not read the adapter exit code', e, st);
          _guard(() => _onAdapterExit(1), 'Handling adapter exit');
        },
      ),
    );
    return _done.future;
  }

  /// Orderly shutdown (same cleanup as a stdin EOF). Idempotent.
  Future<void> shutdown({String reason = 'requested'}) =>
      _coordinator.shutdown(reason, done: _done.future);

  @override
  Future<DapJson> inject(String command, [Json? arguments, Duration? timeout]) {
    if (_closed.isCompleted || _phase.isFinishing) {
      return Future<DapJson>.error(StateError('The debug session has ended.'));
    }
    if (!injectionSupported(_options.kind, command)) {
      return Future<DapJson>.value(_failures.hotUnsupported(command, null));
    }
    if (gatedInjections.contains(command) &&
        (_coordinator.shutdownStarted || _coordinator.stopRequested)) {
      return Future<DapJson>.error(StateError('The debug session is ending.'));
    }
    return _injected.dispatch(
      command,
      arguments,
      timeout,
      clock: _clock,
      send: (message) {
        _log.dap('INJ', message);
        _sendToAdapter(message);
      },
    );
  }

  @override
  void notice(String text, [NoticeLevel level = NoticeLevel.info]) {
    _sendToClient(
      makeOutputEvent(
        formatNotice(text, level),
        seq: _injected.nextSyntheticSeq(),
      ),
    );
  }

  void _onClientMessage(DapJson message) {
    _clientQueue = _clientQueue
        .then<void>((_) => _handleClient(message))
        .catchError((Object e, StackTrace st) {
          _log.error('Error handling a client message', e, st);
        });
  }

  void _onClientError(Object error) => _onChannelError(
    error,
    who: 'the editor',
    log: 'Bad framing from the editor',
    reason: 'client framing error',
  );

  /// A framing problem on either channel ends the session; other errors are
  /// only logged.
  void _onChannelError(
    Object error, {
    required String who,
    required String log,
    required String reason,
  }) {
    if (error is! DapFramingException) {
      _log.error('Channel error from $who', error);
      return;
    }
    _log.error('$log: ${error.message}');
    notice(
      '${who[0].toUpperCase()}${who.substring(1)} sent a message that could '
      'not be read (${error.message}). Closing the debug session.',
      NoticeLevel.error,
    );
    _exitCodeOverride ??= 1;
    _guard(() => shutdown(reason: reason), 'Shutdown');
  }

  void _onClientEof() {
    _clientGone = true;
    _log.info('Client closed its output; shutting down.');
    // Queue behind messages that arrived before the EOF (a final disconnect).
    _clientQueue = _clientQueue.whenComplete(
      () => _guard(() => shutdown(reason: 'client closed'), 'Shutdown'),
    );
  }

  Future<void> _handleClient(DapJson raw) async {
    final message = DapMessage(raw);
    try {
      await _dispatchClient(message);
    } on Object catch (e, st) {
      _log.error('Could not handle a client message', e, st);
      if (message.isRequest) _failures.requestFailed(message, e);
    }
  }

  Future<void> _dispatchClient(DapMessage message) async {
    if (_phase.isFinished) return;
    if (!message.isRequest) {
      _sendToAdapter(message.raw);
      return;
    }
    if (_injected.clientSeqCollides(message.raw)) {
      _log.error(
        'The client sent seq ${message.seq}, which collides with the '
        'proxy range.',
      );
      notice(
        'The editor used message number ${message.seq}, which clashes '
        'with this tool. Some replies may be lost.',
        NoticeLevel.error,
      );
    }
    final command = message.command;
    switch (command) {
      case DapCommands.initialize:
        _watchdog.arm(message.seq);
        _sendToAdapter(message.raw);
      case DapCommands.launch || DapCommands.attach:
        final rewritten = _rewriteLaunch(command!, message);
        if (rewritten != null) _sendToAdapter(rewritten);
      case DapCommands.restart
          when !injectionSupported(_options.kind, DapCommands.hotRestart):
        _sendToClient(
          _failures.hotUnsupported(DapCommands.restart, message.seq),
        );
      case DapCommands.restart:
        _clientRestartSeqs.add(message.seq);
        hotActions.noteClientRestart(started: true);
        _sendToAdapter(message.raw);
      case DapCommands.terminate:
        await _coordinator.handleTerminate(message);
      case DapCommands.disconnect:
        await _coordinator.handleDisconnect(message);
      default:
        _sendToAdapter(message.raw);
    }
  }

  /// The request to forward, or null when it was refused (the client already
  /// got an error that says what to fix).
  DapJson? _rewriteLaunch(String command, DapMessage message) {
    final result = _rewriter.rewrite(command, message.arguments);
    final rejection = result.rejection;
    if (rejection != null) {
      _tracker.requestSeen(command);
      _failures.requestRejected(message, rejection);
      return null;
    }
    for (final note in result.notes) {
      notice(note, NoticeLevel.warn);
    }
    _tracker.launchRewritten(command, result);
    return <String, Object?>{...message.raw, 'arguments': result.arguments};
  }

  Future<void> _failStartup(String reason) async {
    if (!_failures.startupFailed(reason)) return;
    _exitCodeOverride ??= 1;
    _coordinator.markShutdownRequested();
    await _finish(1);
  }

  void _onAdapterError(Object error) => _onChannelError(
    error,
    who: 'the Flutter debug adapter',
    log: 'Bad framing from the adapter',
    reason: 'adapter framing error',
  );

  void _onAdapterMessage(DapJson raw) {
    final message = DapMessage(raw);
    if (message.isResponse) {
      _onAdapterResponse(message);
    } else if (message.isEvent) {
      _onAdapterEvent(message);
    } else {
      _sendToClient(raw);
    }
  }

  void _onAdapterResponse(DapMessage response) {
    if (_injected.consumeResponse(response.raw)) return;
    if (_clientRestartSeqs.remove(response.requestSeq)) {
      hotActions.noteClientRestart(started: false);
    }
    if (_coordinator.holdResponse(response)) return;
    _watchdog.onResponse(response.requestSeq);
    _sendToClient(response.raw);
    final command = response.command;
    if (response.failed &&
        (command == DapCommands.launch || command == DapCommands.attach)) {
      _tracker.launchFailed(response);
    }
  }

  void _onAdapterEvent(DapMessage event) {
    _sendToClient(event.raw);
    final terminated = event.event == DapEvents.terminated;
    if (terminated) _coordinator.markTerminatedSeen();
    _tracker.onEvent(event);
    if (terminated) _coordinator.maybeFinishTerminate();
  }

  Future<void> _onAdapterExit(int code) async {
    _coordinator.markAdapterExited();
    if (!_closed.isCompleted) _closed.complete();
    _log.info('The adapter exited with code $code.');
    await bounded(
      _clock,
      _adapterMessagesDone.future,
      _options.timings.drainWait,
    );
    if (_phase.isFinishing) return;
    if (!_coordinator.stopRequested) {
      if (_coordinator.terminatedSeen && code == 0) {
        // The program ended and the adapter followed; nothing went wrong.
        await _finish(0);
      } else {
        _coordinator.markCrashed();
        await _handleCrash(code);
      }
      return;
    }
    await _coordinator.finishAfterAdapterExit();
  }

  Future<void> _handleCrash(int code) async {
    _failures.adapterCrashed(code);
    _tracker.markEnded();
    await _finish(code);
  }

  Future<void> _finish(int code) async {
    if (_phase.isFinishing) {
      await _done.future;
      return;
    }
    _phase.transition(SessionPhase.finishing);
    _watchdog.cancel();
    _coordinator.beginFinish();
    await _coordinator.cleanupAndKill();
    await _flushClient();
    if (!_closed.isCompleted) _closed.complete();
    unawaited(_clientSub?.cancel());
    unawaited(_adapterSub?.cancel());
    unawaited(_stderrSub?.cancel());
    try {
      await _adapter.channel.close();
    } on Object catch (e) {
      _log.debug('Closing the adapter channel failed: $e');
    }
    _tracker.close();
    _phase.transition(SessionPhase.finished);
    if (!_done.isCompleted) _done.complete(code);
  }

  /// Runs [body] without letting an error escape as an uncaught async error;
  /// a failure is logged and ends the session through [_finish].
  void _guard(Future<void> Function() body, String what) {
    // Errors are handled inside; the session ends through [_finish].
    unawaited(
      Future<void>.sync(body).catchError((Object e, StackTrace st) {
        _log.error('$what failed', e, st);
        if (!_phase.isFinishing) {
          return _finish(_exitCodeOverride ?? 1).catchError((Object e2) {
            _log.error('Ending the session failed', e2);
          });
        }
      }),
    );
  }

  Future<void> _flushClient() async {
    try {
      await withTimeout<void>(
        _clock,
        _client.flush(),
        _options.timings.hookWait,
        onTimeout: () {},
      );
    } on Object catch (e) {
      _log.debug('Could not flush the client: $e');
    }
  }

  void _sendToAdapter(DapJson message) {
    try {
      _adapter.channel.send(message);
    } on Object catch (e) {
      _log.debug('Could not send to the adapter: $e');
    }
  }

  void _sendToClient(DapJson message) {
    if (_clientGone) return;
    try {
      _client.send(message);
    } on Object catch (e) {
      _log.debug('Could not send to the client: $e');
    }
  }
}

/// The proxy's side of the [ShutdownHost] contract, kept off its public API.
class _Host implements ShutdownHost {
  _Host(this._p);

  final DapProxy _p;

  @override
  bool get isLaunchSession => _p._tracker.state.request == DapCommands.launch;

  @override
  bool get programEnded => _p._tracker.state.ended;

  @override
  int? get exitCodeOverride => _p._exitCodeOverride;

  @override
  void sendToClient(DapJson message) => _p._sendToClient(message);

  @override
  void sendToAdapter(DapJson message) => _p._sendToAdapter(message);

  @override
  void notice(String text) => _p.notice(text);

  @override
  int nextSyntheticSeq() => _p._injected.nextSyntheticSeq();

  @override
  Future<DapJson> inject(String command, Json arguments, Duration timeout) =>
      _p.inject(command, arguments, timeout);

  @override
  Future<void> flushClient() => _p._flushClient();

  @override
  Future<void> finish(int code) => _p._finish(code);

  @override
  void guard(Future<void> Function() body, String what) =>
      _p._guard(body, what);
}
