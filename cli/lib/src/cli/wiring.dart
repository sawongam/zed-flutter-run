import 'dart:async';
import 'dart:convert';

import '../common/console.dart';
import '../common/errors.dart';
import '../common/host_environment.dart';
import '../common/json_types.dart';
import '../common/logger.dart';
import '../common/version.dart';
import '../control/control_client.dart';
import '../control/control_protocol.dart';
import '../control/find_sessions.dart';
import '../control/session_store.dart';
import '../dap/channel.dart';
import '../dap/hot_actions.dart';
import '../devices/device_lister.dart';
import '../devices/device_store.dart';
import '../devtools/browser_opener.dart';
import '../devtools/commands/devtools_command.dart';
import '../sdk/managed_process.dart';
import '../sdk/process_spec.dart';
import '../sdk/sdk_resolver.dart';
import '../watch/reload_on_save_watcher.dart';

/// Shared objects, built once, and the adapters between modules.
class Wiring {
  Wiring({
    required this.env,
    required this.console,
    required this.logger,
    SdkResolver? sdkResolver,
    SessionStore? sessionStore,
    ControlClient? controlClient,
    DeviceStore? deviceStore,
    BrowserOpener? browserOpener,
  }) : sdkResolver = sdkResolver ?? SdkResolver(env, logger: logger),
       sessionStore = sessionStore ?? SessionStore(env, logger: logger),
       controlClient = controlClient ?? ControlClient(),
       deviceStore = deviceStore ?? DeviceStore(env, logger: logger),
       browserOpener =
           browserOpener ?? SystemBrowserOpener(env, logger: logger);

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
  final SessionStore sessionStore;
  final ControlClient controlClient;
  final DeviceStore deviceStore;
  final BrowserOpener browserOpener;

  /// Resolves the Flutter SDK and returns a runner for `flutter <args>`.
  FlutterRunner _flutterRunner(String flutterExecutable) {
    return (
      List<String> args, {
      String? workingDirectory,
      Duration? timeout,
    }) async {
      final ProcessSpec base;
      try {
        base = buildProcessSpec(flutterExecutable, args, env);
      } on ArgumentError catch (e) {
        throw ExternalToolException(
          'flutter_run refused to run "flutter ${args.join(' ')}": ${e.message}',
        );
      }
      final spec = ProcessSpec(
        base.executable,
        base.arguments,
        workingDirectory: workingDirectory,
      );
      try {
        final result = await runTool(
          spec,
          timeout: timeout ?? const Duration(seconds: 60),
          logger: logger,
        );
        return FlutterToolResult(result.exitCode, result.stdout, result.stderr);
      } on ExternalToolException catch (e) {
        // `runTool` reports a timeout as an ExternalToolException without a
        // cause; the devices module expects a TimeoutException instead. A
        // spawn failure carries its ProcessException as the cause.
        if (e.cause == null) {
          throw TimeoutException(e.message, timeout);
        }
        rethrow;
      }
    };
  }

  FlutterRunnerFactory get flutterRunnerFactory =>
      ({String? projectDir, String? explicitSdk}) async {
        final resolution = await sdkResolver.resolveOrThrow(
          projectDir: projectDir ?? env.currentDirectory,
          explicitSdkPath: explicitSdk,
        );
        return _flutterRunner(resolution.flutter!.flutterExecutable);
      };

  /// The session DevTools should open for: the most recent live session of
  /// the directory that already has a VM service address.
  VmServiceTargetResolver get vmServiceTargetResolver =>
      ({required String directory}) async {
        final all = await findSessionsFor(sessionStore, directory, env);
        final live = all.where((r) => !r.unresponsive).toList();
        if (live.isEmpty) {
          throw NoSessionException(
            'No running Flutter app found for $directory.',
            hint:
                'Start one from the debugger first (F4 opens the debug '
                'picker in Zed).',
          );
        }
        final withUri = live.where((r) => r.info.vmServiceUri != null).toList()
          ..sort((a, b) => b.info.startedAt.compareTo(a.info.startedAt));
        if (withUri.isEmpty) {
          throw const SessionRequestException(
            'The app is still starting. Try again in a moment.',
          );
        }
        final best = withUri.first.info;
        return VmServiceTarget(
          vmServiceUri: best.vmServiceUri!,
          deviceId: best.deviceId,
          sessionPid: best.pid,
          kind: best.kind,
        );
      };
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
  ProxySessionControl(this._hot, {int? pid}) : _pid = pid;

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
        'Another hot reload or restart is still running.',
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
