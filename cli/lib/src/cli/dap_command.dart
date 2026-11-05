import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../common/errors.dart';
import '../common/global_options.dart';
import '../common/json_types.dart';
import '../common/logger.dart';
import '../common/paths.dart';
import '../common/version.dart';
import '../control/control_server.dart';
import '../control/session_info.dart';
import '../control/session_store.dart';
import '../dap/channel.dart';
import '../dap/launch_rewriter.dart';
import '../dap/messages.dart';
import '../dap/notices.dart';
import '../dap/proxy.dart';
import '../dap/proxy_state.dart';
import '../devtools/devtools_opener.dart';
import '../devtools/pages.dart';
import '../sdk/managed_process.dart';
import '../sdk/process_spec.dart';
import '../sdk/sdk_resolver.dart';
import '../watch/reload_config.dart';
import '../watch/reload_on_save_watcher.dart';
import 'path_notice.dart';
import 'wiring.dart';

/// First sequence number of messages the proxy makes up itself.
const int _syntheticSeq = 1000000000;

/// Answers the client's first request with a failure, mirrors the text to the
/// client's console (stderr category) and closes the channel.
///
/// Zed only shows "adapter exited" when the proxy dies silently, so this is
/// how startup problems (no SDK, adapter cannot be started) reach the user.
Future<void> answerStartupFailure(
  DapChannel client,
  String text, {
  Duration wait = const Duration(seconds: 2),
}) async {
  DapJson? first;
  try {
    first = await client.messages.firstWhere(isRequest).timeout(wait);
  } on TimeoutException {
    // The client sent nothing; still write the console text.
  } on StateError {
    // The client closed its output.
  }
  if (first != null) {
    final seq = first['seq'];
    client.send(
      makeResponse(
        requestSeq: seq is int ? seq : 0,
        command: first['command'] as String? ?? 'initialize',
        success: false,
        message: text,
        seq: _syntheticSeq,
      ),
    );
  }
  client.send(
    makeOutputEvent(
      formatNotice(text, NoticeLevel.error),
      category: 'stderr',
      seq: _syntheticSeq + 1,
    ),
  );
  await client.flush();
  await client.close();
}

/// `flutter_run dap`: the DAP proxy that Zed starts for a debug session.
class DapCommand extends Command<int> {
  DapCommand(
    this._wiring, {
    Stream<List<int>>? input,
    StreamSink<List<int>>? output,
    IOSink? errorSink,
    String? resolvedExecutable,
    this.attachWatchdog = const Duration(seconds: 15),
    this.startupResponseWait = const Duration(seconds: 2),
    this.sessionWriteDebounce = const Duration(milliseconds: 50),
    Stream<ProcessSignal> Function(ProcessSignal signal)? signalSource,
  }) : _signalSource = signalSource ?? ((signal) => signal.watch()),
       _input = input,
       _output = output,
       _errorSink = errorSink,
       _resolvedExecutable = resolvedExecutable {
    GlobalOptions.addTo(argParser);
    argParser
      ..addOption(
        'cwd',
        valueHelp: 'dir',
        help: 'Working directory of the debug session (required).',
      )
      ..addOption(
        'kind',
        allowed: ['flutter', 'dart'],
        defaultsTo: 'flutter',
        help: 'Which debug adapter to start.',
      )
      ..addOption(
        'request',
        allowed: ['launch', 'attach'],
        defaultsTo: 'launch',
        help: 'The kind of session the editor will start.',
      )
      ..addFlag(
        'use-fvm',
        negatable: false,
        help: 'Require the Flutter SDK that fvm selected for the project.',
      )
      ..addOption(
        'log-file',
        valueHelp: 'path',
        help: 'Write the debug log and all DAP traffic to this file.',
      )
      ..addOption(
        'client-version',
        valueHelp: 'x.y.z',
        help: 'Version of the Zed extension that started this command.',
      );
  }

  final Wiring _wiring;
  final Stream<ProcessSignal> Function(ProcessSignal signal) _signalSource;
  final Stream<List<int>>? _input;
  final StreamSink<List<int>>? _output;
  final IOSink? _errorSink;
  final String? _resolvedExecutable;
  final Duration attachWatchdog;
  final Duration startupResponseWait;
  final Duration sessionWriteDebounce;

  @override
  String get name => 'dap';

  @override
  String get description =>
      'Debug adapter proxy (started by the Zed extension, not by hand).';

  @override
  bool get hidden => false;

  @override
  Future<int> run() {
    final cwdOption = argResults!['cwd'] as String?;
    if (cwdOption == null || cwdOption.isEmpty) {
      usageException('The option --cwd is required.');
    }
    final errorSink = _errorSink ?? stderr;
    final done = Completer<int>();
    runZonedGuarded(
      () async {
        try {
          done.complete(await _run(cwdOption));
        } on Object catch (e, st) {
          _wiring.logger.error('The debug proxy failed unexpectedly', e, st);
          if (!done.isCompleted) done.complete(ExitCodes.internal);
        }
      },
      (e, st) => _wiring.logger.error('Unexpected error in the proxy', e, st),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => errorSink.writeln(line),
      ),
    );
    return done.future;
  }

  Future<int> _run(String cwdOption) async {
    final env = _wiring.env;
    final options = GlobalOptions.of(this);
    final kind = argResults!['kind'] == 'dart' ? DapKind.dart : DapKind.flutter;
    final request = argResults!['request'] as String;
    final useFvm = argResults!['use-fvm'] as bool;
    final clientVersion = argResults!['client-version'] as String?;
    final logFile = argResults!['log-file'] as String?;

    final Logger logger;
    var ownLogger = false;
    if (logFile != null && logFile.isNotEmpty) {
      logger = Logger(
        level: options.verbose ? LogLevel.debug : _wiring.logger.level,
        logFilePath: logFile,
      );
      ownLogger = true;
    } else {
      logger = _wiring.logger;
    }

    final client = StreamDapChannel(
      _input ?? stdin,
      _output ?? stdout,
      logger: logger,
      label: 'C',
    );
    final cwd = env.pathContext.normalize(env.pathContext.absolute(cwdOption));

    final ManagedProcess process;
    try {
      final resolution = await _wiring.sdkResolver.resolveOrThrow(
        projectDir: cwd,
        kind: kind == DapKind.dart ? SdkKind.dart : SdkKind.flutter,
        explicitSdkPath: options.flutterSdk,
        strictFvm: useFvm,
      );
      final executable = kind == DapKind.dart
          ? resolution.dartExecutable!
          : resolution.flutter!.flutterExecutable;
      // Attaching must not start a second DDS (it would outlive the session,
      // see the attach probe). Only the Flutter adapter has the flag.
      final args = <String>[
        'debug_adapter',
        if (kind == DapKind.flutter && request == 'attach') '--no-dds',
      ];
      final base = buildProcessSpec(executable, args, env);
      process = await ManagedProcess.start(
        ProcessSpec(base.executable, base.arguments, workingDirectory: cwd),
        logger: logger,
      );
    } on FlutterRunException catch (e) {
      logger.error('Could not start the debug adapter: ${e.message}');
      final hint = e.hint;
      await answerStartupFailure(
        client,
        hint == null ? e.message : '${e.message}\n$hint',
        wait: startupResponseWait,
      );
      if (ownLogger) await logger.close();
      return e is SdkNotFoundException ? ExitCodes.sdkNotFound : 1;
    } on ArgumentError catch (e) {
      await answerStartupFailure(
        client,
        'The debug adapter could not be started: ${e.message}',
        wait: startupResponseWait,
      );
      if (ownLogger) await logger.close();
      return 1;
    }

    final session = _DapSession(
      wiring: _wiring,
      logger: logger,
      client: client,
      adapter: ManagedAdapterConnection(process, logger: logger),
      kind: kind,
      request: request,
      cwd: cwd,
      clientVersion: clientVersion,
      resolvedExecutable: _resolvedExecutable ?? Platform.resolvedExecutable,
      attachWatchdog: attachWatchdog,
      sessionWriteDebounce: sessionWriteDebounce,
    );
    // SIGTERM/SIGHUP/SIGINT run the same cleanup as a closed stdin. SIGKILL
    // cannot be handled (known issue, ADR 0007 P1).
    final signals = <StreamSubscription<ProcessSignal>>[];
    for (final signal in [
      ProcessSignal.sigint,
      if (!env.isWindows) ProcessSignal.sigterm,
      if (!env.isWindows) ProcessSignal.sighup,
    ]) {
      try {
        signals.add(
          _signalSource(
            signal,
          ).listen((_) => session.requestShutdown('signal ${signal.name}')),
        );
      } on Object catch (e) {
        logger.debug('Cannot watch ${signal.name}: $e');
      }
    }
    final code = await session.run();
    for (final sub in signals) {
      await sub.cancel();
    }
    if (ownLogger) await logger.close();
    return code;
  }
}

/// One running debug session: the proxy plus everything around it.
class _DapSession {
  _DapSession({
    required this.wiring,
    required this.logger,
    required this.client,
    required this.adapter,
    required this.kind,
    required this.request,
    required this.cwd,
    required this.clientVersion,
    required this.resolvedExecutable,
    required this.attachWatchdog,
    required this.sessionWriteDebounce,
  });

  final Wiring wiring;
  final Logger logger;
  final DapChannel client;
  final ManagedAdapterConnection adapter;
  final DapKind kind;
  final String request;
  final String cwd;
  final String? clientVersion;
  final String resolvedExecutable;
  final Duration attachWatchdog;
  final Duration sessionWriteDebounce;

  late final String projectRoot;
  late final DapProxy proxy;
  late final ProxySessionControl control;
  ControlServer? _server;
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

  Future<int> run() async {
    final env = wiring.env;
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
        savedDevice: () => wiring.deviceStore.readSync(projectRoot)?.deviceId,
        logger: logger,
      ),
      onShutdownStarted: _onShutdownStarted,
      onShutdownCleanup: _onShutdownCleanup,
      logger: logger,
    );
    _proxyReady = true;
    if (_signalReason != null) _shutdownForSignal();
    control = ProxySessionControl(proxy.hotActions, pid: pid);
    await _startControl();
    _events = proxy.events.listen(_onEvent);

    final code = await proxy.run();

    await _onShutdownStarted();
    await _onShutdownCleanup();
    await _events?.cancel();
    await client.flush();
    return code;
  }

  Future<void> _startControl() async {
    try {
      final server = await ControlServer.start(
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
        startedAt: DateTime.now().toUtc(),
      );
      _info = info;
      _handle = await wiring.sessionStore.create(info);
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
        unawaited(_openDevTools(event));
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
      _showStartNotices(event.result);
    }
    if (event.request == 'attach') {
      _watchdog?.cancel();
      _watchdog = Timer(attachWatchdog, () {
        if (_ending || proxy.state.appStarted) return;
        proxy.notice(
          'Still waiting for the app. Start it with "flutter run", or set '
          '"vmServiceUri" in .zed/debug.json.',
        );
      });
    }
  }

  void _showStartNotices(RewriteResult result) {
    final version = clientVersion;
    if (version != null && version.isNotEmpty && version != packageVersion) {
      proxy.notice(
        'The Zed extension is version $version but the flutter_run command is '
        '$packageVersion. Update flutter_run to match (see the README install '
        'section).',
        NoticeLevel.warn,
      );
    }
    if (_pathNoticeNeeded()) {
      proxy.notice(
        pathNoticeText(wiring.env, resolvedExecutable, _isCompiledExe),
        NoticeLevel.warn,
      );
    }
    final problem = _setupProblem;
    if (problem != null) proxy.notice(problem, NoticeLevel.warn);
    if (kind == DapKind.flutter) {
      final id = result.deviceId;
      switch (result.deviceSource) {
        case DeviceSource.saved:
          proxy.notice('Using device $id (saved selection).');
        case DeviceSource.env:
          proxy.notice(
            'Using device $id (environment variable '
            '${LaunchRewriter.deviceEnvVariable}).',
          );
        case DeviceSource.none:
          proxy.notice(
            'No device was chosen, so Flutter will pick one. If it cannot, '
            'run the task "Flutter: Select Device".',
          );
        case DeviceSource.config || DeviceSource.toolArgs:
          break;
      }
    }
  }

  bool get _isCompiledExe {
    final base = wiring.env.pathContext
        .basename(resolvedExecutable)
        .toLowerCase();
    return base != 'dart' && base != 'dart.exe';
  }

  bool _pathNoticeNeeded() {
    final found = findExecutableOnPath(toolName, wiring.env);
    if (found == null) return true;
    if (!_isCompiledExe) return false;
    return !_samePath(found, resolvedExecutable);
  }

  bool _samePath(String a, String b) {
    String real(String path) {
      try {
        return File(path).resolveSymbolicLinksSync();
      } on FileSystemException {
        return path;
      }
    }

    return pathsEqual(real(a), real(b), wiring.env);
  }

  // ---------------------------------------------------------- session file

  void _scheduleSessionWrite() {
    if (_handle == null || _ending) return;
    _writeTimer ??= Timer(sessionWriteDebounce, () {
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

  // ----------------------------------------------------- reload on save etc.

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
        env: wiring.env,
        reload: () => reloadForSave(proxy.hotActions),
        notice: _watcherNotice,
        logger: logger,
      );
      _watcher = watcher;
      await watcher.start();
    } on Object catch (e, st) {
      logger.error('Could not start reload on save', e, st);
      proxy.notice('Reload on save could not be started: $e', NoticeLevel.warn);
    }
  }

  void _watcherNotice(String text, {required bool isError}) {
    var level = isError ? NoticeLevel.error : NoticeLevel.info;
    var message = text;
    if (message.startsWith('Error: ')) {
      message = message.substring('Error: '.length);
      level = NoticeLevel.error;
    } else if (message.startsWith('Warning: ')) {
      message = message.substring('Warning: '.length);
      level = NoticeLevel.warn;
    }
    proxy.notice(message, level);
  }

  Future<void> _openDevTools(DebuggerUris event) async {
    if (!event.isFirst) return;
    final value = _ownConfig['openDevTools'];
    if (value is! String || value == 'never') return;
    final page = DevToolsPage.parse(value);
    if (page == null) {
      proxy.notice(
        'The launch entry has openDevTools "$value", which is not a DevTools '
        'page. Use "never" or one of: ${DevToolsPage.names}.',
        NoticeLevel.warn,
      );
      return;
    }
    try {
      final url = await openDevToolsOnce(
        event.vmServiceUri,
        page,
        wiring.browserOpener,
        logger: logger,
        isDartSession: kind == DapKind.dart,
      );
      proxy.notice('Opened DevTools: $url');
    } on FlutterRunException catch (e) {
      // DevToolsOpenException already includes the address to open by hand.
      proxy.notice(e.message, NoticeLevel.warn);
    }
  }
}
