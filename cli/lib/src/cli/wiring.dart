import 'dart:async';
import 'dart:convert';

import '../common/clock.dart';
import '../common/console.dart';
import '../common/host_environment.dart';
import '../common/json_types.dart';
import '../common/logger.dart';
import '../common/version.dart';
import '../control/control_client.dart';
import '../control/control_protocol.dart';
import '../control/session_matcher.dart';
import '../control/session_store.dart';
import '../dap/channel.dart';
import '../dap/hot_actions.dart';
import '../devices/device_lister.dart';
import '../devices/device_store.dart';
import '../devices/flutter_runner_factory.dart';
import '../devtools/browser_opener.dart';
import '../devtools/vm_service_target_resolver.dart';
import '../sdk/managed_process.dart';
import '../sdk/process_runner.dart';
import '../sdk/process_spec.dart';
import '../sdk/sdk_resolver.dart';
import '../watch/reload_on_save_watcher.dart';
import 'signal_source.dart';

/// Shared objects, built once, and the adapters between modules.
class Wiring {
  Wiring({
    required this.env,
    required this.console,
    required this.logger,
    this.clock = const SystemClock(),
    this.signals = const SystemSignalSource(),
    ProcessRunner? processRunner,
    SdkResolver? sdkResolver,
    SessionStore? sessionStore,
    ControlClient? controlClient,
    DeviceStore? deviceStore,
    BrowserOpener? browserOpener,
  }) : processRunner = processRunner ?? SystemProcessRunner(env),
       sdkResolver = sdkResolver ?? SdkResolver(env, logger: logger),
       controlClient = controlClient ?? ControlClient(env: env),
       deviceStore =
           deviceStore ?? DeviceStore(env, logger: logger, clock: clock),
       browserOpener =
           browserOpener ?? SystemBrowserOpener(env, logger: logger) {
    // The store pings sessions with the same client the commands use.
    this.sessionStore =
        sessionStore ??
        SessionStore(
          env,
          logger: logger,
          probe: this.controlClient,
          clock: clock,
        );
    flutterRunnerFactory = createFlutterRunnerFactory(
      currentDirectory: env.currentDirectory,
      resolveExecutable: ({projectDir, explicitSdk}) async {
        final resolution = await this.sdkResolver.resolveOrThrow(
          projectDir: projectDir ?? env.currentDirectory,
          explicitSdkPath: explicitSdk,
        );
        return resolution.flutter!.flutterExecutable;
      },
      execute: (flutter, args, {workingDirectory, required timeout}) async {
        final base = buildProcessSpec(flutter, args, env);
        final result = await this.processRunner.run(
          ProcessSpec(
            base.executable,
            base.arguments,
            workingDirectory: workingDirectory,
          ),
          timeout: timeout,
          logger: logger,
        );
        return FlutterToolResult(result.exitCode, result.stdout, result.stderr);
      },
    );
    vmServiceTargetResolver = createVmServiceTargetResolver((directory) async {
      final records = await findSessionsFor(this.sessionStore, directory, env);
      return [
        for (final r in records)
          RunningSession(
            vmServiceUri: r.info.vmServiceUri,
            startedAt: r.info.startedAt,
            pid: r.info.pid,
            deviceId: r.info.deviceId,
            kind: r.info.kind,
            unresponsive: r.unresponsive,
          ),
      ];
    });
  }

  /// The real process environment. `--verbose` raises the log level to debug,
  /// otherwise `FLUTTER_RUN_LOG_LEVEL` decides; `FLUTTER_RUN_LOG` names a file.
  factory Wiring.system({bool verbose = false}) {
    final env = HostEnvironment.system();
    final level = verbose
        ? LogLevel.debug
        : Logger.levelFromName(env.env('FLUTTER_RUN_LOG_LEVEL'));
    return Wiring(
      env: env,
      console: SystemConsole(),
      logger: Logger(level: level, logFilePath: env.env('FLUTTER_RUN_LOG')),
    );
  }

  final HostEnvironment env;
  final Console console;
  final Logger logger;
  final SdkResolver sdkResolver;
  late final SessionStore sessionStore;
  final ControlClient controlClient;
  final DeviceStore deviceStore;
  final BrowserOpener browserOpener;
  final Clock clock;
  final SignalSource signals;
  final ProcessRunner processRunner;

  /// Resolves the Flutter SDK and returns a runner for `flutter <args>`.
  late final FlutterRunnerFactory flutterRunnerFactory;

  /// The session DevTools should open for.
  late final VmServiceTargetResolver vmServiceTargetResolver;
}

/// Adapts a [ManagedProcess] running `<flutter|dart> debug_adapter`.
class ManagedAdapterConnection implements AdapterConnection {
  ManagedAdapterConnection(this._process, {Logger? logger})
    : channel = StreamDapChannel(
        _process.stdout,
        _process.stdin,
        logger: logger,
        label: 'A',
      ),
      stderrLines = _process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter()) {
    // Writing to an adapter that already exited must not crash the proxy.
    unawaited(_process.stdin.done.then((_) {}, onError: (Object _) {}));
  }

  final ManagedProcess _process;

  @override
  final DapChannel channel;

  @override
  final Stream<String> stderrLines;

  @override
  int get pid => _process.pid;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  Future<Set<int>> snapshotDescendants() => _process.snapshotDescendants();

  @override
  Future<void> terminateTree({
    Set<int> extraPids = const {},
    bool crashed = false,
  }) => _process.terminateTree(extraPids: extraPids, crashed: crashed);
}

/// Answers control requests from `flutter_run reload|restart` using the
/// proxy's [HotActions].
class ProxySessionControl implements SessionControl {
  ProxySessionControl(this._hot, {this._pid});

  final HotActions _hot;
  final int? _pid;
  bool _ending = false;

  /// After this, hot actions are refused with `session_ended`.
  void markEnding() => _ending = true;

  @override
  Json ping() => <String, Object?>{
    'pid': _pid,
    'version': packageVersion,
    'protocol': controlProtocolVersion,
  };

  @override
  Future<Json> reload(Json args) async {
    _checkAlive();
    final reason = args['reason'];
    final result = await _hot.reload(
      reason: reason is String ? reason : 'manual',
    );
    _throwIfFailed(result);
    return <String, Object?>{
      'durationMs': result.duration.inMilliseconds,
      'coalesced': result.coalesced,
    };
  }

  @override
  Future<Json> restart(Json args) async {
    _checkAlive();
    final result = await _hot.restart();
    _throwIfFailed(result);
    return <String, Object?>{'durationMs': result.duration.inMilliseconds};
  }

  void _checkAlive() {
    if (_ending) {
      throw const ControlException(
        ControlErrorCode.sessionEnded,
        'The debug session is ending.',
      );
    }
  }

  static void _throwIfFailed(HotResult result) {
    if (result.ok) return;
    final message = result.message;
    throw switch (result.error) {
      HotError.notStarted || null => const ControlException(
        ControlErrorCode.appNotStarted,
        'The app is still starting.',
      ),
      HotError.busy => const ControlException(
        ControlErrorCode.busy,
        busyMessage,
      ),
      HotError.adapterError => ControlException(
        ControlErrorCode.adapterError,
        message ?? 'The debug adapter reported an error.',
      ),
      HotError.timeout => ControlException(
        ControlErrorCode.timeout,
        message ?? 'The debug adapter did not answer in time.',
      ),
      HotError.sessionEnded => const ControlException(
        ControlErrorCode.sessionEnded,
        'The debug session has ended.',
      ),
    };
  }
}

/// The reload callback of the reload-on-save watcher.
Future<ReloadOutcome> reloadForSave(HotActions hot) async {
  final result = await hot.reload(reason: 'save');
  return ReloadOutcome(
    ok: result.ok,
    // A timeout means the reload is still pending (for example paused at a
    // breakpoint), which the watcher treats like "busy": not a failure.
    busy: result.error == HotError.busy || result.error == HotError.timeout,
    message: result.message,
    joined: result.coalesced,
  );
}
