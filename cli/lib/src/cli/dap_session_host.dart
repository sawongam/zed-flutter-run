import 'dart:async';
import 'dart:io' as io;

import '../common/clock.dart';
import '../common/host_environment.dart';
import '../common/json_types.dart';
import '../common/logger.dart';
import '../common/paths.dart';
import '../control/control_server.dart';
import '../control/session_info.dart';
import '../control/session_store.dart';
import '../dap/channel.dart';
import '../dap/launch_rewriter.dart';
import '../dap/notices.dart';
import '../dap/proxy.dart';
import '../dap/proxy_state.dart';
import '../devices/device_store.dart';
import '../devtools/browser_opener.dart';
import '../sdk/process_spec.dart';
import '../watch/reload_config.dart';
import '../watch/reload_on_save_watcher.dart';
import 'control_endpoint.dart';
import 'session_notices.dart';
import 'signal_source.dart';
import 'wiring.dart';

/// One running debug session: the proxy plus everything around it (control
/// server, session file, reload on save, DevTools, signals).
class DapSessionHost {
  DapSessionHost({
    required this.env,
    required this.clock,
    required this.logger,
    required this.signals,
    required this.sessionStore,
    required this.deviceStore,
    required this.browserOpener,
    required this.client,
    required this.adapter,
    required this.kind,
    required this.request,
    required this.cwd,
    required this.clientVersion,
    required this.resolvedExecutable,
    required this.attachWatchdog,
    required this.sessionWriteDebounce,
    int? pid,
    ControlServerStarter? startControlServer,
  }) : pid = pid ?? io.pid,
       _startControlServer =
           startControlServer ??
           (({required control, logger}) async => ServerEndpoint(
             await ControlServer.start(
               control: control,
               logger: logger,
               clock: clock,
             ),
           ));

  final HostEnvironment env;
  final Clock clock;
  final Logger logger;
  final SignalSource signals;
  final SessionStore sessionStore;
  final DeviceStore deviceStore;
  final BrowserOpener browserOpener;
  final DapChannel client;
  final AdapterConnection adapter;
  final DapKind kind;
  final String request;
  final String cwd;
  final String? clientVersion;
  final String resolvedExecutable;
  final Duration attachWatchdog;
  final Duration sessionWriteDebounce;
  final int pid;
  final ControlServerStarter _startControlServer;

  late final String projectRoot;
  late final DapProxy proxy;
  late final ProxySessionControl control;
  late final SessionNotices _notices = SessionNotices(
    env: env,
    logger: logger,
    browserOpener: browserOpener,
    kind: kind,
    clientVersion: clientVersion,
    resolvedExecutable: resolvedExecutable,
    notice: (text, [level = NoticeLevel.info]) => proxy.notice(text, level),
  );
  ControlEndpoint? _server;
  SessionHandle? _handle;
  SessionInfo? _info;
  ReloadOnSaveWatcher? _watcher;
  Future<void>? _watcherStart;
  StreamSubscription<ProxyEvent>? _events;
  Timer? _writeTimer;
  Timer? _watchdog;
  Json _ownConfig = const <String, Object?>{};
  bool _startNoticesShown = false;
  bool _ending = false;
  String? _setupProblem;

  bool _proxyReady = false;
  String? _signalReason;

  /// Starts the orderly shutdown (called from signal handlers).
  void requestShutdown(String reason) {
    _signalReason ??= reason;
    if (_proxyReady) _shutdownForSignal();
  }

  void _shutdownForSignal() {
    logger.info('Received $_signalReason; shutting down.');
    proxy.shutdown(reason: _signalReason!).ignore();
  }

  /// SIGTERM/SIGHUP/SIGINT run the same cleanup as a closed stdin. SIGKILL
  /// cannot be handled (known issue, ADR 0007 P1).
  List<StreamSubscription<io.ProcessSignal>> _watchSignals() {
    final subscriptions = <StreamSubscription<io.ProcessSignal>>[];
    for (final signal in [
      io.ProcessSignal.sigint,
      if (!env.isWindows) io.ProcessSignal.sigterm,
      if (!env.isWindows) io.ProcessSignal.sighup,
    ]) {
      try {
        subscriptions.add(
          signals
              .watch(signal)
              .listen((_) => requestShutdown('signal ${signal.name}')),
        );
      } on Object catch (e) {
        logger.debug('Cannot watch ${signal.name}: $e');
      }
    }
    return subscriptions;
  }

  /// Runs the session until the proxy ends; returns its exit code.
  Future<int> run() async {
    final subscriptions = _watchSignals();
    try {
      return await _runProxy();
    } finally {
      for (final sub in subscriptions) {
        await sub.cancel();
      }
    }
  }

  Future<int> _runProxy() async {
    projectRoot = canonicalDirectory(findProjectRoot(cwd, env) ?? cwd, env);
    proxy = DapProxy(
      client: client,
      adapter: adapter,
      options: ProxyOptions(
        kind: kind,
        cwd: cwd,
        snapshotInterval: env.isWindows
            ? const Duration(seconds: 6)
            : const Duration(seconds: 2),
      ),
      rewriter: LaunchRewriter(
        isSafeDeviceId: safeIdPattern.hasMatch,
        kind: kind,
        cwd: cwd,
        environment: env.environment,
        savedDevice: () => deviceStore.readSync(projectRoot)?.deviceId,
        logger: logger,
      ),
      onShutdownStarted: _onShutdownStarted,
      onShutdownCleanup: _onShutdownCleanup,
      logger: logger,
    );
    control = ProxySessionControl(proxy.hotActions, pid: pid);
    _proxyReady = true;
    if (_signalReason != null) _shutdownForSignal();
    await _startControl();
    _events = proxy.events.listen(_onEvent);

    final code = await proxy.run();

    await _onShutdownStarted();
    await _onShutdownCleanup();
    // Not awaited: cancelling a plain in-process subscription does no I/O.
    unawaited(_events?.cancel());
    await client.flush();
    return code;
  }

  Future<void> _startControl() async {
    try {
      final server = await _startControlServer(
        control: control,
        logger: logger,
      );
      _server = server;
      final info = SessionInfo(
        pid: pid,
        port: server.port,
        token: server.token,
        projectRoot: projectRoot,
        cwd: cwd,
        kind: kind.name,
        request: request,
        startedAt: clock.now().toUtc(),
      );
      _info = info;
      final handle = await sessionStore.create(info);
      _handle = handle;
      // A signal that came in while the file was being created has already
      // run the shutdown hook, which found nothing to delete.
      if (_ending) await handle.delete();
    } on Object catch (e, st) {
      logger.error('Could not publish the session for the reload tasks', e, st);
      _setupProblem =
          'The tasks "Flutter: Hot Reload" and "Hot Restart" cannot find this '
          'debug session ($e). Debugging itself still works.';
    }
  }

  // ------------------------------------------------------------- shutdown

  Future<void> _onShutdownStarted() async {
    if (_ending) return;
    _ending = true;
    control.markEnding();
    final watcher = _watcher;
    _watcher = null;
    try {
      await watcher?.stop();
    } on Object catch (e) {
      logger.warn('Could not stop the file watcher: $e');
    }
    _watchdog?.cancel();
    _writeTimer?.cancel();
    try {
      await _handle?.delete();
    } on Object catch (e) {
      logger.warn('Could not delete the session file: $e');
    }
  }

  Future<void> _onShutdownCleanup() async {
    final start = _watcherStart;
    if (start != null) {
      try {
        await start;
      } on Object catch (_) {
        // Already logged by the starter.
      }
    }
    try {
      await _watcher?.stop();
    } on Object catch (e) {
      logger.warn('Could not stop the file watcher: $e');
    }
    _watcher = null;
    try {
      await _server?.close();
    } on Object catch (e) {
      logger.warn('Could not close the control server: $e');
    }
    _server = null;
  }

  // --------------------------------------------------------------- events

  void _onEvent(ProxyEvent event) {
    switch (event) {
      case LaunchRewritten():
        _onLaunch(event);
      case StateChanged():
        _scheduleSessionWrite();
      case DebuggerUris():
        unawaited(_notices.openDevTools(event, _ownConfig));
      case AppStarted():
        _watchdog?.cancel();
        _writeTimer?.cancel();
        unawaited(_writeSession());
        _watcherStart = _armWatcher();
        unawaited(_watcherStart);
      case SessionEnded():
        _watchdog?.cancel();
    }
  }

  void _onLaunch(LaunchRewritten event) {
    _ownConfig = event.result.ownConfig;
    if (!_startNoticesShown) {
      _startNoticesShown = true;
      _notices.showStart(event.result, setupProblem: _setupProblem);
    }
    if (event.request == 'attach') {
      _watchdog?.cancel();
      _watchdog = clock.timer(attachWatchdog, () {
        if (_ending || proxy.state.appStarted) return;
        proxy.notice(
          'Still waiting for the app. Start it with "flutter run", or set '
          '"vmServiceUri" in .zed/debug.json.',
        );
      });
    }
  }

  // ---------------------------------------------------------- session file

  void _scheduleSessionWrite() {
    if (_handle == null || _ending) return;
    _writeTimer ??= clock.timer(sessionWriteDebounce, () {
      _writeTimer = null;
      unawaited(_writeSession());
    });
  }

  Future<void> _writeSession() async {
    final handle = _handle;
    final base = _info;
    if (handle == null || base == null || _ending) return;
    final state = proxy.state;
    final next = base.copyWith(
      request: state.request,
      deviceId: state.deviceId,
      mode: state.mode,
      vmServiceUri: state.vmServiceUri,
      appStarted: state.appStarted,
    );
    _info = next;
    try {
      await handle.update(next);
    } on Object catch (e) {
      logger.warn('Could not update the session file: $e');
    }
  }

  // ------------------------------------------------------- reload on save

  Future<void> _armWatcher() async {
    try {
      final config = ReloadOnSaveConfig.fromOwnConfig(_ownConfig);
      if (config.mode == ReloadOnSaveMode.off) return;
      final mode = proxy.state.mode;
      if (mode == 'profile' || mode == 'release' || mode == 'jit_release') {
        proxy.notice(
          'Reload on save is off because the app runs in $mode mode (hot '
          'reload needs debug mode).',
        );
        return;
      }
      if (_ending) return;
      final watcher = ReloadOnSaveWatcher(
        projectRoot: projectRoot,
        isDartProgram: kind == DapKind.dart,
        config: config,
        env: env,
        reload: () => reloadForSave(proxy.hotActions),
        notice: _notices.watcherNotice,
        logger: logger,
      );
      _watcher = watcher;
      await watcher.start();
    } on Object catch (e, st) {
      logger.error('Could not start reload on save', e, st);
      proxy.notice('Reload on save could not be started: $e', NoticeLevel.warn);
    }
  }
}
