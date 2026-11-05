import 'dart:async';

import '../common/json_types.dart';
import '../common/logger.dart';
import 'channel.dart';
import 'device_hints.dart';
import 'framing.dart';
import 'hot_actions.dart';
import 'injected_requests.dart';
import 'launch_rewriter.dart';
import 'messages.dart';
import 'notices.dart';
import 'proxy_state.dart';

class ProxyOptions {
  const ProxyOptions({
    required this.kind,
    required this.cwd,
    this.terminateTimeout = const Duration(seconds: 5),
    this.exitWait = const Duration(seconds: 5),
    this.initializeTimeout = const Duration(seconds: 120),
    this.initializeNoticeAfter = const Duration(seconds: 10),
    this.snapshotInterval = const Duration(seconds: 2),
  });

  final DapKind kind;
  final String cwd;

  /// Upper bound for the adapter to finish a `terminate` (also used for the
  /// injected one).
  final Duration terminateTimeout;

  /// Upper bound for the adapter to exit after `disconnect`.
  final Duration exitWait;

  /// Upper bound for the adapter's answer to `initialize`.
  final Duration initializeTimeout;

  /// After this long without an `initialize` answer, one notice says that
  /// Flutter is still starting (ADR 0007 P2).
  final Duration initializeNoticeAfter;

  /// How often the adapter's descendants are recorded while it runs (reading
  /// the process table is slower on Windows, so the caller may raise this).
  final Duration snapshotInterval;
}

/// The Dart-side DAP proxy between the editor and the debug adapter.
///
/// Client messages pass through untouched except `launch`/`attach` arguments;
/// injected requests use a disjoint sequence range; shutdown follows Zed's
/// real stop path (ADR 0006 D2).
class DapProxy implements RequestInjector {
  DapProxy({
    required DapChannel client,
    required AdapterConnection adapter,
    required ProxyOptions options,
    required LaunchRewriter rewriter,
    Future<void> Function()? onShutdownStarted,
    Future<void> Function()? onShutdownCleanup,
    Logger? logger,
  }) : _client = client,
       _adapter = adapter,
       _options = options,
       _rewriter = rewriter,
       _onShutdownStarted = onShutdownStarted,
       _onShutdownCleanup = onShutdownCleanup,
       _log = logger ?? Logger.silent(),
       _state = ProxyState(
         request: 'launch',
         kind: options.kind,
         cwd: options.cwd,
       ) {
    _closed.future.then<void>((_) {
      for (final pending in List.of(_pendingInjects)) {
        if (!pending.isCompleted) {
          pending.completeError(StateError('The debug session has ended.'));
        }
      }
      _pendingInjects.clear();
    });
  }

  static const int _stderrTailLines = 20;
  static const Duration _stoppingNoticeAfter = Duration(seconds: 1);
  static const Duration _drainWait = Duration(seconds: 2);
  static const Duration _snapshotWait = Duration(seconds: 3);
  static const Duration _disconnectGrace = Duration(milliseconds: 500);
  static const Duration _adapterExitGrace = Duration(milliseconds: 800);
  static const Duration _sweepGrace = Duration(milliseconds: 300);
  static const Duration _hookWait = Duration(seconds: 2);
  static const Duration _sweepWait = Duration(seconds: 3);
  static const Duration _sweepWaitLate = Duration(seconds: 1);

  final DapChannel _client;
  final AdapterConnection _adapter;
  final ProxyOptions _options;
  final LaunchRewriter _rewriter;
  final Future<void> Function()? _onShutdownStarted;
  final Future<void> Function()? _onShutdownCleanup;
  final Logger _log;
  final InjectedRequests _injected = InjectedRequests();
  final StreamController<ProxyEvent> _events =
      StreamController<ProxyEvent>.broadcast();

  /// The hot reload / restart coordinator for this session.
  late final HotActions hotActions = HotActions(this);

  ProxyState _state;
  bool _started = false;
  bool _finishing = false;
  bool _clientGone = false;
  bool _seenDebuggerUris = false;
  bool _deviceHintShown = false;
  bool _adapterExited = false;
  bool _treeKilled = false;

  /// The last two periodic snapshots (bounded; dead pids fall out).
  final List<Set<int>> _recent = [];
  bool _crashed = false;
  Timer? _firstSnapshotTimer;
  Timer? _initializeNoticeTimer;
  final Set<Completer<DapJson>> _pendingInjects = {};
  bool _snapshotRunning = false;
  Timer? _snapshotTimer;
  bool _shutdownRequested = false;
  int? _exitCodeOverride;

  final Completer<int> _done = Completer<int>();
  final Completer<void> _closed = Completer<void>();
  final Completer<void> _adapterExit = Completer<void>();
  final Completer<void> _adapterMessagesDone = Completer<void>();
  final Completer<void> _terminatedSeen = Completer<void>();

  StreamSubscription<DapJson>? _clientSub;
  StreamSubscription<DapJson>? _adapterSub;
  StreamSubscription<String>? _stderrSub;
  Future<void> _clientQueue = Future<void>.value();
  final List<String> _stderrTail = [];

  // initialize watchdog
  Object? _initializeSeq;
  bool _initializeAnswered = false;
  Timer? _initializeTimer;

  // client restart tracking
  final Set<Object?> _clientRestartSeqs = {};

  // terminate flow
  bool _terminateReceived = false;
  Object? _terminateSeq;
  DapJson? _heldTerminateResponse;
  bool _terminateFinishing = false;
  bool _terminateFinished = false;
  bool _terminateDeadline = false;
  final Completer<void> _terminateDone = Completer<void>();
  Timer? _terminateTimer;
  Timer? _stoppingTimer;

  // disconnect flow
  bool _disconnectReceived = false;
  Object? _disconnectSeq;
  DapJson? _heldDisconnectResponse;
  bool _disconnectFinishing = false;
  Timer? _disconnectTimer;

  // shared shutdown plumbing
  Future<Set<int>>? _startFuture;
  Future<void>? _cleanupFuture;
  Future<void>? _shutdownFuture;

  Stream<ProxyEvent> get events => _events.stream;

  ProxyState get state => _state;

  @override
  bool get appStarted => _state.appStarted;

  /// Runs the proxy; completes with the exit code once fully shut down.
  Future<int> run() {
    if (_started) return _done.future;
    _started = true;
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
      if (_stderrTail.length > _stderrTailLines) _stderrTail.removeAt(0);
      _log.debug('adapter stderr: $line');
    }, onError: (Object e) => _log.debug('adapter stderr error: $e'));
    _firstSnapshotTimer = Timer(
      const Duration(milliseconds: 300),
      _refreshSnapshot,
    );
    _snapshotTimer = Timer.periodic(
      _options.snapshotInterval,
      (_) => _refreshSnapshot(),
    );
    _adapter.exitCode.then<void>(
      (code) => _guard(() => _onAdapterExit(code), 'Handling adapter exit'),
      onError: (Object e, StackTrace st) {
        _log.error('Could not read the adapter exit code', e, st);
        _guard(() => _onAdapterExit(1), 'Handling adapter exit');
      },
    );
    return _done.future;
  }

  /// Orderly shutdown (same cleanup as a stdin EOF). Idempotent.
  Future<void> shutdown({String reason = 'requested'}) =>
      _shutdownFuture ??= _shutdownImpl(reason);

  @override
  Future<DapJson> inject(String command, [Json? arguments, Duration? timeout]) {
    if (_closed.isCompleted || _finishing) {
      return Future<DapJson>.error(StateError('The debug session has ended.'));
    }
    if (command == 'hotRestart' && _options.kind == DapKind.dart) {
      return Future<DapJson>.value(_hotRestartUnsupported(null));
    }
    final isHot = command == 'hotReload' || command == 'hotRestart';
    if (isHot &&
        (_startFuture != null ||
            _terminateReceived ||
            _disconnectReceived ||
            _shutdownRequested)) {
      return Future<DapJson>.error(StateError('The debug session is ending.'));
    }
    final request = _injected.create(command, arguments);
    final result = Completer<DapJson>();
    _pendingInjects.add(result);
    Timer? timer;
    request.response.then<void>((response) {
      timer?.cancel();
      _pendingInjects.remove(result);
      if (!result.isCompleted) result.complete(response);
    });
    if (timeout != null) {
      timer = Timer(timeout, () {
        if (result.isCompleted) return;
        _injected.markTimedOut(request.seq);
        _pendingInjects.remove(result);
        result.completeError(
          TimeoutException('No response to $command', timeout),
        );
      });
    }
    _log.dap('INJ', request.message);
    _sendToAdapter(request.message);
    return result.future;
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

  // ---------------------------------------------------------------- client

  void _onClientMessage(DapJson message) {
    _clientQueue = _clientQueue
        .then<void>((_) => _handleClient(message))
        .catchError((Object e, StackTrace st) {
          _log.error('Error handling a client message', e, st);
        });
  }

  void _onClientError(Object error) {
    if (error is DapFramingException) {
      _log.error('Bad framing from the editor: ${error.message}');
      notice(
        'The editor sent a message that could not be read (${error.message}). '
        'Closing the debug session.',
        NoticeLevel.error,
      );
      _exitCodeOverride ??= 1;
      _guard(() => shutdown(reason: 'client framing error'), 'Shutdown');
    } else {
      _log.error('Client channel error', error);
    }
  }

  void _onClientEof() {
    _clientGone = true;
    _log.info('Client closed its output; shutting down.');
    // Queue behind messages that arrived before the EOF (a final disconnect).
    _clientQueue = _clientQueue.whenComplete(
      () => _guard(() => shutdown(reason: 'client closed'), 'Shutdown'),
    );
  }

  Future<void> _handleClient(DapJson message) async {
    try {
      await _dispatchClient(message);
    } on Object catch (e, st) {
      _log.error('Could not handle a client message', e, st);
      if (!isRequest(message)) return;
      final command = '${message['command']}';
      final seq = message['seq'];
      _sendToClient(
        makeResponse(
          requestSeq: seq is int ? seq : 0,
          command: command,
          success: false,
          message:
              'The flutter_run proxy could not handle the "$command" request '
              '($e). Check the log file and try again.',
          seq: _injected.nextSyntheticSeq(),
        ),
      );
      notice(
        'The "$command" request failed inside flutter_run: $e',
        NoticeLevel.error,
      );
    }
  }

  Future<void> _dispatchClient(DapJson message) async {
    if (_finishing && _done.isCompleted) return;
    if (!isRequest(message)) {
      _sendToAdapter(message);
      return;
    }
    if (_injected.clientSeqCollides(message)) {
      _log.error(
        'The client sent seq ${message['seq']}, which collides with the '
        'proxy range.',
      );
      notice(
        'The editor used message number ${message['seq']}, which clashes '
        'with this tool. Some replies may be lost.',
        NoticeLevel.error,
      );
    }
    final command = message['command'];
    switch (command) {
      case 'initialize':
        _initializeSeq = message['seq'];
        _armInitializeTimer();
        _sendToAdapter(message);
      case 'launch' || 'attach':
        _sendToAdapter(_rewriteLaunch(command as String, message));
      case 'restart' when _options.kind == DapKind.dart:
        _sendToClient(_hotRestartUnsupported(message['seq']));
      case 'restart':
        _clientRestartSeqs.add(message['seq']);
        hotActions.noteClientRestart(started: true);
        _sendToAdapter(message);
      case 'terminate':
        await _handleTerminate(message);
      case 'disconnect':
        await _handleDisconnect(message);
      default:
        _sendToAdapter(message);
    }
  }

  DapJson _rewriteLaunch(String command, DapJson message) {
    final raw = message['arguments'];
    final arguments = raw is Map<String, Object?> ? raw : <String, Object?>{};
    final result = _rewriter.rewrite(command, arguments);
    for (final note in result.notes) {
      notice(note, NoticeLevel.warn);
    }
    _state = _state.copyWith(request: command, deviceId: result.deviceId);
    _emit(LaunchRewritten(command, result));
    _emit(StateChanged(_state));
    return <String, Object?>{...message, 'arguments': result.arguments};
  }

  void _armInitializeTimer() {
    _initializeTimer?.cancel();
    _initializeNoticeTimer?.cancel();
    _initializeNoticeTimer = Timer(_options.initializeNoticeAfter, () {
      if (_initializeAnswered || _finishing) return;
      notice(
        'Flutter is still starting. The first run after an upgrade, or '
        'another flutter command holding the startup lock, can take a while.',
      );
    });
    _initializeTimer = Timer(_options.initializeTimeout, () {
      if (_initializeAnswered || _finishing) return;
      _guard(
        () => _failStartup(
          'The Flutter debug adapter did not answer within '
          '${_describe(_options.initializeTimeout)}.',
        ),
        'Startup failure',
      );
    });
  }

  Future<void> _failStartup(String reason) async {
    if (_initializeAnswered) return;
    _initializeAnswered = true;
    _initializeTimer?.cancel();
    final lastLine = _stderrTail.isEmpty ? null : _stderrTail.last;
    final text = StringBuffer(reason)
      ..write(
        ' Check that "flutter debug_adapter" works in a terminal, then try '
        'again.',
      );
    if (lastLine != null) {
      text.write(' The last message from it was: $lastLine');
    }
    final seq = _initializeSeq;
    _sendToClient(
      makeResponse(
        requestSeq: seq is int ? seq : 0,
        command: 'initialize',
        success: false,
        message: text.toString(),
        seq: _injected.nextSyntheticSeq(),
      ),
    );
    _sendToClient(
      makeOutputEvent(
        formatNotice(text.toString(), NoticeLevel.error),
        category: 'stderr',
        seq: _injected.nextSyntheticSeq(),
      ),
    );
    _exitCodeOverride ??= 1;
    _shutdownRequested = true;
    await _finish(1);
  }

  // --------------------------------------------------------------- adapter

  void _onAdapterError(Object error) {
    if (error is DapFramingException) {
      _log.error('Bad framing from the adapter: ${error.message}');
      notice(
        'The Flutter debug adapter sent a message that could not be read '
        '(${error.message}). Closing the debug session.',
        NoticeLevel.error,
      );
      _exitCodeOverride ??= 1;
      _guard(() => shutdown(reason: 'adapter framing error'), 'Shutdown');
    } else {
      _log.error('Adapter channel error', error);
    }
  }

  void _onAdapterMessage(DapJson message) {
    if (isResponse(message)) {
      _onAdapterResponse(message);
    } else if (isEvent(message)) {
      _onAdapterEvent(message);
    } else {
      _sendToClient(message);
    }
  }

  void _onAdapterResponse(DapJson response) {
    if (_injected.consumeResponse(response)) return;
    final requestSeq = response['request_seq'];
    if (_clientRestartSeqs.remove(requestSeq)) {
      hotActions.noteClientRestart(started: false);
    }
    if (_terminateReceived && requestSeq == _terminateSeq) {
      if (_terminateFinished) return;
      _heldTerminateResponse = response;
      _maybeFinishTerminate();
      return;
    }
    if (_disconnectReceived && requestSeq == _disconnectSeq) {
      _heldDisconnectResponse = response;
      // The adapter answered: do not make the editor wait for it to exit.
      _disconnectTimer?.cancel();
      _disconnectTimer = Timer(_disconnectGrace, () {
        _guard(_finishDisconnect, 'Finishing disconnect');
      });
      return;
    }
    if (_initializeSeq != null &&
        requestSeq == _initializeSeq &&
        !_initializeAnswered) {
      _initializeAnswered = true;
      _initializeTimer?.cancel();
      _initializeNoticeTimer?.cancel();
    }
    _sendToClient(response);
    if (response['success'] == false &&
        (response['command'] == 'launch' || response['command'] == 'attach')) {
      final body = response['body'];
      final error = body is Map ? body['error'] : null;
      final format = error is Map ? error['format'] : null;
      _maybeDeviceHint('${response['message'] ?? ''}\n${format ?? ''}');
    }
  }

  void _onAdapterEvent(DapJson event) {
    _sendToClient(event);
    final body = event['body'];
    final fields = body is Map<String, Object?>
        ? body
        : const <String, Object?>{};
    switch (event['event']) {
      case 'output':
        final text = fields['output'];
        if (text is String) _maybeDeviceHint(text);
      case 'dart.debuggerUris':
        final uri = fields['vmServiceUri'];
        if (uri is String) {
          final isFirst = !_seenDebuggerUris;
          _seenDebuggerUris = true;
          // The Dart adapter never sends flutter.appStarted; its debugger
          // URIs (debug mode only) mean the program is running.
          final startsNow = _options.kind == DapKind.dart && !_state.appStarted;
          _setState(
            _state.copyWith(
              vmServiceUri: uri,
              appStarted: startsNow ? true : null,
            ),
          );
          _emit(DebuggerUris(uri, isFirst: isFirst));
          if (startsNow) _emit(AppStarted());
          _refreshSnapshot();
        }
      case 'thread':
        _refreshSnapshot();
      case 'flutter.appStart':
        _refreshSnapshot();
        final appId = fields['appId'];
        final deviceId = fields['deviceId'];
        final mode = fields['mode'];
        _setState(
          _state.copyWith(
            appId: appId is String ? appId : null,
            deviceId: deviceId is String ? deviceId : null,
            mode: mode is String ? mode : null,
          ),
        );
      case 'flutter.appStarted':
        if (!_state.appStarted) {
          _setState(_state.copyWith(appStarted: true));
          _emit(AppStarted());
        }
      case 'terminated':
        if (!_terminatedSeen.isCompleted) _terminatedSeen.complete();
        _markEnded();
        _maybeFinishTerminate();
      case 'exited':
        _markEnded();
    }
  }

  void _markEnded() {
    if (_state.ended) return;
    _setState(_state.copyWith(ended: true));
    _emit(SessionEnded());
  }

  void _maybeDeviceHint(String text) {
    if (_deviceHintShown) return;
    final hint = deviceHintFor(text);
    if (hint == null) return;
    _deviceHintShown = true;
    notice(hint, NoticeLevel.warn);
  }

  void _setState(ProxyState next) {
    _state = next;
    _emit(StateChanged(next));
  }

  void _emit(ProxyEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  Future<void> _onAdapterExit(int code) async {
    _adapterExited = true;
    if (!_adapterExit.isCompleted) _adapterExit.complete();
    if (!_closed.isCompleted) _closed.complete();
    _snapshotTimer?.cancel();
    _log.info('The adapter exited with code $code.');
    await _bounded(_adapterMessagesDone.future, _drainWait);
    if (_finishing) return;
    final orderly =
        _terminateReceived || _disconnectReceived || _shutdownRequested;
    if (!orderly && _terminatedSeen.isCompleted && code == 0) {
      // The program ended and the adapter followed; nothing went wrong.
      await _finish(0);
      return;
    }
    if (!orderly) {
      _crashed = true;
      await _handleCrash(code);
      return;
    }
    if (_terminateReceived && !_terminateFinished) await _finishTerminate();
    if (_disconnectReceived) {
      await _finishDisconnect();
    } else if (!_shutdownRequested) {
      await _finish(0);
    }
  }

  Future<void> _handleCrash(int code) async {
    final tail = _stderrTail.join('\n');
    final seq = _initializeSeq;
    if (seq != null && !_initializeAnswered) {
      _initializeAnswered = true;
      _initializeTimer?.cancel();
      _sendToClient(
        makeResponse(
          requestSeq: seq is int ? seq : 0,
          command: 'initialize',
          success: false,
          message: tail.isEmpty
              ? 'The Flutter debug adapter stopped before it was ready '
                    '(exit code $code).'
              : tail.split('\n').last,
          seq: _injected.nextSyntheticSeq(),
        ),
      );
    }
    if (tail.isNotEmpty) {
      _sendToClient(
        makeOutputEvent(
          '$tail\n',
          category: 'stderr',
          seq: _injected.nextSyntheticSeq(),
        ),
      );
    }
    notice(
      'The Flutter debug adapter stopped unexpectedly (exit code $code). '
      'Start the debug session again.',
      NoticeLevel.error,
    );
    _sendToClient(<String, Object?>{
      'seq': _injected.nextSyntheticSeq(),
      'type': 'event',
      'event': 'terminated',
      'body': <String, Object?>{},
    });
    _markEnded();
    await _finish(code);
  }

  // -------------------------------------------------------------- terminate

  Future<void> _handleTerminate(DapJson message) async {
    if (_terminateReceived) {
      _sendToAdapter(message);
      return;
    }
    _terminateReceived = true;
    _terminateSeq = message['seq'];
    _terminateTimer = Timer(_options.terminateTimeout, () {
      _terminateDeadline = true;
      _guard(_finishTerminate, 'Finishing terminate');
    });
    _stoppingTimer = Timer(_stoppingNoticeAfter, () {
      if (!_terminateFinished) notice('Stopping the app...');
    });
    await _startShutdown();
    if (_terminateFinishing || _finishing) return;
    if (_adapterExited) {
      await _finishTerminate();
      return;
    }
    _sendToAdapter(message);
  }

  void _maybeFinishTerminate() {
    if (!_terminateReceived || _terminateFinishing) return;
    if (_heldTerminateResponse != null && _terminatedSeen.isCompleted) {
      _guard(_finishTerminate, 'Finishing terminate');
    }
  }

  Future<void> _finishTerminate() async {
    if (_terminateFinishing) return _terminateDone.future;
    _terminateFinishing = true;
    _terminateTimer?.cancel();
    _stoppingTimer?.cancel();
    try {
      await _cleanup();
      final held = _heldTerminateResponse;
      if (held != null) {
        _sendToClient(held);
      } else {
        final seq = _terminateSeq;
        _sendToClient(
          makeResponse(
            requestSeq: seq is int ? seq : 0,
            command: 'terminate',
            success: true,
            seq: _injected.nextSyntheticSeq(),
          ),
        );
      }
      await _flushClient();
    } on Object catch (e, st) {
      _log.error('Finishing terminate failed', e, st);
    } finally {
      _terminateFinished = true;
      if (!_terminateDone.isCompleted) _terminateDone.complete();
    }
  }

  // ------------------------------------------------------------- disconnect

  Future<void> _handleDisconnect(DapJson message) async {
    if (_disconnectReceived) {
      _sendToAdapter(message);
      return;
    }
    _disconnectReceived = true;
    _disconnectSeq = message['seq'];
    await _startShutdown();
    if (_terminateReceived && !_terminateFinished) {
      await _terminateDone.future;
    } else if (!_terminateReceived &&
        _state.request == 'launch' &&
        !_terminatedSeen.isCompleted &&
        !_adapterExited) {
      await _bounded(
        Future.any<void>([
          _injectQuietly('terminate', <String, Object?>{}),
          _terminatedSeen.future,
        ]),
        _options.terminateTimeout,
      );
    }
    if (_adapterExited || _finishing) {
      await _finishDisconnect();
      return;
    }
    _sendToAdapter(message);
    _disconnectTimer = Timer(_options.exitWait, () {
      _guard(_finishDisconnect, 'Finishing disconnect');
    });
  }

  Future<void> _finishDisconnect() async {
    if (_disconnectFinishing) return;
    _disconnectFinishing = true;
    _disconnectTimer?.cancel();
    await _cleanup();
    final held = _heldDisconnectResponse;
    final seq = _disconnectSeq;
    _sendToClient(
      held ??
          makeResponse(
            requestSeq: seq is int ? seq : 0,
            command: 'disconnect',
            success: true,
            seq: _injected.nextSyntheticSeq(),
          ),
    );
    await _finish(0);
  }

  // --------------------------------------------------------------- shutdown

  Future<void> _shutdownImpl(String reason) async {
    _log.info('Shutting down: $reason');
    _shutdownRequested = true;
    await _startShutdown();
    if (_disconnectReceived) {
      await _done.future;
      return;
    }
    if (_terminateReceived && !_terminateFinished) {
      await _terminateDone.future;
    }
    if (!_adapterExited && !_finishing) {
      if (!_terminateReceived &&
          _state.request == 'launch' &&
          !_terminatedSeen.isCompleted) {
        await _bounded(
          Future.any<void>([
            _injectQuietly('terminate', <String, Object?>{}),
            _terminatedSeen.future,
            _adapterExit.future,
          ]),
          _options.terminateTimeout,
        );
      }
      if (!_adapterExited) {
        unawaited(_injectQuietly('disconnect', <String, Object?>{}));
        await _bounded(_adapterExit.future, _options.exitWait);
      }
    }
    await _finish(_exitCodeOverride ?? 0);
  }

  Future<void> _injectQuietly(String command, Json arguments) async {
    try {
      await inject(command, arguments, _options.terminateTimeout);
    } on Object catch (e) {
      _log.debug('Injected $command ended without a response: $e');
    }
  }

  /// Step 1 and 2 of every stop: tell the owner (session file) and snapshot
  /// the adapter's descendants before anything is signalled.
  Future<Set<int>> _startShutdown() => _startFuture ??= () async {
    _snapshotTimer?.cancel();
    try {
      await _onShutdownStarted?.call().timeout(_hookWait, onTimeout: () {});
    } on Object catch (e, st) {
      _log.error('onShutdownStarted failed', e, st);
    }
    if (!_adapterExited) {
      // A normal stop targets what is a descendant right now, nothing older.
      try {
        return await _adapter.snapshotDescendants().timeout(_snapshotWait);
      } on Object catch (e) {
        _log.debug('Could not snapshot adapter descendants: $e');
        return <int>{};
      }
    }
    // The adapter crashed: its children were reparented, so use what the
    // last polls saw (the sweep spares shared daemons and guards PID reuse).
    return _crashed ? {for (final s in _recent) ...s} : <int>{};
  }();

  /// Keeps the descendant set fresh while the adapter runs, so a SIGKILLed
  /// adapter's reparented children can still be swept (also on Windows,
  /// where `taskkill /T` alone needs a live parent).
  void _refreshSnapshot() {
    if (_adapterExited || _finishing || _startFuture != null) return;
    if (_state.ended) return;
    if (_snapshotRunning) return;
    _snapshotRunning = true;
    _adapter
        .snapshotDescendants()
        .timeout(_snapshotWait)
        .then<void>((pids) {
          if (_adapterExited || _startFuture != null) return;
          _recent.add(pids);
          if (_recent.length > 2) _recent.removeAt(0);
        }, onError: (Object e) => _log.debug('Periodic snapshot failed: $e'))
        .whenComplete(() => _snapshotRunning = false);
  }

  DapJson _hotRestartUnsupported(Object? requestSeq) => makeResponse(
    requestSeq: requestSeq is int ? requestSeq : 0,
    command: requestSeq == null ? 'hotRestart' : 'restart',
    success: false,
    message:
        'Hot restart is only available for Flutter apps. Stop and start the '
        'program instead.',
    seq: _injected.nextSyntheticSeq(),
  );

  Future<void> _cleanup() => _cleanupFuture ??= () async {
    final snapshot = await _startShutdown();
    try {
      await _onShutdownCleanup?.call().timeout(_hookWait, onTimeout: () {});
    } on Object catch (e, st) {
      _log.error('onShutdownCleanup failed', e, st);
    }
    await _sweep(snapshot);
  }();

  /// Last resort: only when processes may have survived the graceful stop.
  Future<void> _sweep(Set<int> snapshot) async {
    if (!_adapterExited && !_terminateDeadline && !_crashed) {
      // Most adapters exit by themselves once the app is stopped.
      await _bounded(_adapterExit.future, _adapterExitGrace);
    }
    final candidates = snapshot.difference(<int>{_adapter.pid});
    if (candidates.isEmpty && _adapterExited) return;
    if (candidates.isNotEmpty && !_terminateDeadline) {
      // Give descendants that are already exiting a moment to finish.
      await Future<void>.delayed(_sweepGrace);
    }
    await _killTree(candidates);
  }

  Future<void> _killTree(Set<int> extraPids) async {
    if (!_adapterExited) _treeKilled = true;
    try {
      await _adapter
          .terminateTree(extraPids: extraPids, crashed: _crashed)
          .timeout(_terminateDeadline ? _sweepWaitLate : _sweepWait);
    } on Object catch (e) {
      _log.warn('Sweeping adapter processes failed: $e');
    }
  }

  Future<void> _finish(int code) async {
    if (_finishing) {
      await _done.future;
      return;
    }
    _finishing = true;
    _snapshotTimer?.cancel();
    _firstSnapshotTimer?.cancel();
    _initializeNoticeTimer?.cancel();
    _initializeTimer?.cancel();
    _terminateTimer?.cancel();
    _stoppingTimer?.cancel();
    _disconnectTimer?.cancel();
    _terminateFinished = true;
    if (!_terminateDone.isCompleted) _terminateDone.complete();
    await _cleanup();
    if (!_adapterExited && !_treeKilled) {
      final snapshot = await _startShutdown();
      await _killTree(snapshot.difference(<int>{_adapter.pid}));
    }
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
    if (!_events.isClosed) unawaited(_events.close());
    if (!_done.isCompleted) _done.complete(code);
  }

  // ---------------------------------------------------------------- helpers

  /// Runs [body] without letting an error escape as an uncaught async error;
  /// a failure is logged and ends the session through [_finish].
  void _guard(Future<void> Function() body, String what) {
    Future<void>.sync(body).catchError((Object e, StackTrace st) {
      _log.error('$what failed', e, st);
      if (!_finishing) {
        return _finish(_exitCodeOverride ?? 1).catchError((Object e2) {
          _log.error('Ending the session failed', e2);
        });
      }
    });
  }

  Future<void> _flushClient() async {
    try {
      await _client.flush().timeout(_hookWait, onTimeout: () {});
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

  static String _describe(Duration d) => d.inSeconds >= 1
      ? '${d.inSeconds} seconds'
      : '${d.inMilliseconds} milliseconds';

  /// Completes when [future] completes (value or error) or after [limit].
  static Future<void> _bounded(Future<Object?> future, Duration limit) {
    final completer = Completer<void>();
    final timer = Timer(limit, () {
      if (!completer.isCompleted) completer.complete();
    });
    void done() {
      timer.cancel();
      if (!completer.isCompleted) completer.complete();
    }

    future.then<void>((_) => done(), onError: (Object _) => done());
    return completer.future;
  }
}
