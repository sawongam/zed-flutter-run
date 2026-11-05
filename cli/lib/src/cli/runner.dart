import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:meta/meta.dart';

import '../common/errors.dart';
import '../common/global_options.dart';
import '../common/paths.dart';
import '../common/version.dart';
import '../control/reload_command.dart';
import '../control/restart_command.dart';
import '../control/status_command.dart';
import '../devices/commands/devices_command.dart';
import '../devices/commands/emulators_command.dart';
import '../devices/commands/select_device_command.dart';
import '../devtools/commands/devtools_command.dart';
import '../init/commands/init_command.dart';
import 'dap_command.dart';
import 'doctor_command.dart';
import 'path_notice.dart';
import 'version_command.dart';
import 'wiring.dart';

/// True when [args] ask for debug output (`-v` / `--verbose`).
bool verboseRequested(Iterable<String> args) {
  for (final arg in args) {
    if (arg == '--') return false;
    if (arg == '--verbose' || arg == '-v') return true;
  }
  return false;
}

/// The `flutter_run` command line: registers every command and maps failures
/// to exit codes (plan §4.1).
class FlutterRunRunner extends CommandRunner<int> {
  FlutterRunRunner({Wiring? wiring, Future<void> Function()? flushOutput})
    : this._(wiring ?? Wiring.system(), flushOutput);

  /// A runner for the real process; [args] are only looked at for `--verbose`
  /// so the logger level is right before the commands are built.
  factory FlutterRunRunner.create({List<String> args = const []}) =>
      FlutterRunRunner(wiring: Wiring.system(verbose: verboseRequested(args)));

  FlutterRunRunner._(this.wiring, this._flushOutput)
    : super(
        toolName,
        'Flutter Run & Debug: DAP proxy for Zed plus hot reload, devices '
        'and DevTools commands.',
      ) {
    GlobalOptions.addTo(argParser);
    argParser.addFlag(
      'version',
      abbr: 'V',
      negatable: false,
      help: 'Print the flutter_run version.',
    );
    final env = wiring.env;
    final console = wiring.console;
    addCommand(DapCommand(wiring));
    addCommand(
      ReloadCommand(
        store: wiring.sessionStore,
        client: wiring.controlClient,
        env: env,
        console: console,
      ),
    );
    addCommand(
      RestartCommand(
        store: wiring.sessionStore,
        client: wiring.controlClient,
        env: env,
        console: console,
      ),
    );
    addCommand(
      StatusCommand(store: wiring.sessionStore, env: env, console: console),
    );
    addCommand(
      DevicesCommand(
        runnerFor: wiring.flutterRunnerFactory,
        store: wiring.deviceStore,
        env: env,
        console: console,
      ),
    );
    addCommand(
      SelectDeviceCommand(
        runnerFor: wiring.flutterRunnerFactory,
        store: wiring.deviceStore,
        env: env,
        console: console,
      ),
    );
    addCommand(
      EmulatorsCommand(
        runnerFor: wiring.flutterRunnerFactory,
        store: wiring.deviceStore,
        env: env,
        console: console,
      ),
    );
    addCommand(
      DevToolsCommand(
        resolveTarget: wiring.vmServiceTargetResolver,
        opener: wiring.browserOpener,
        env: env,
        console: console,
      ),
    );
    addCommand(
      InitCommand(
        env: env,
        console: console,
        findFlutterRunOnPath: () => findExecutableOnPath(toolName, env),
        pathFixHint: pathFixHint(
          env.os,
          env.pathContext.dirname(Platform.resolvedExecutable),
        ),
      ),
    );
    addCommand(
      DoctorCommand(
        sdkResolver: wiring.sdkResolver,
        sessionStore: wiring.sessionStore,
        env: env,
        console: console,
      ),
    );
    addCommand(VersionCommand(console));
  }

  final Wiring wiring;
  final Future<void> Function()? _flushOutput;

  @override
  String? get usageFooter => '''

Exit codes:
  0    Success.
  1    Unexpected error (run with --verbose for details).
  2    Bad flags or arguments.
  3    No Flutter debug session found for the directory.
  4    A session could not act or failed (reload failed, app still starting).
  5    A session did not answer within --timeout.
  6    Flutter or Dart SDK not found.
  7    No devices, or an unknown device id.
  8    No pubspec.yaml at or above the directory.
  9    "init" could not edit a file safely and printed it for you to paste.
  10   A flutter, dart or browser command failed.
  130  Interrupted (Ctrl+C).''';

  /// True when the command word (first non-option argument) is `dap`.
  @visibleForTesting
  static bool isDapCommand(List<String> args) {
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a == '--project' || a == '--flutter-sdk') {
        i++;
        continue;
      }
      if (a.startsWith('-')) continue;
      return a == 'dap';
    }
    return false;
  }

  /// Runs [args] and returns the exit code; never throws. Output is flushed
  /// before returning so the caller can `exit()` right away.
  Future<int> runWithExit(List<String> args) async {
    final verbose = verboseRequested(args);
    final interrupted = Completer<int>();
    StreamSubscription<ProcessSignal>? sigint;
    if (!isDapCommand(args)) {
      try {
        sigint = ProcessSignal.sigint.watch().listen((_) {
          if (!interrupted.isCompleted) {
            interrupted.complete(ExitCodes.interrupted);
          }
        });
      } on Object {
        // Signals are not available here; Ctrl+C then ends the process.
      }
    }
    final code = await Future.any<int>([
      execute(args, verbose: verbose),
      interrupted.future,
    ]);
    await sigint?.cancel();
    await _flush();
    return code;
  }

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    if (topLevelResults['version'] == true) {
      wiring.console.out('$toolName $packageVersion');
      return ExitCodes.ok;
    }
    return super.runCommand(topLevelResults);
  }

  /// Runs [args] with the top-level error handling of plan §4.1.
  Future<int> execute(Iterable<String> args, {bool verbose = false}) async {
    final console = wiring.console;
    try {
      return await run(args) ?? ExitCodes.ok;
    } on FlutterRunException catch (e) {
      console.err('error: ${e.message}');
      final hint = e.hint;
      if (hint != null) console.err('hint: $hint');
      return e.exitCode;
    } on UsageException catch (e) {
      console
        ..err(e.message)
        ..err('')
        ..err(e.usage);
      return ExitCodes.usage;
    } on Object catch (e, st) {
      console.err('error: unexpected failure: $e');
      if (verbose) {
        console.err(st.toString());
      } else {
        console.err('Run with --verbose for details.');
      }
      return ExitCodes.internal;
    }
  }

  Future<void> _flush() async {
    final custom = _flushOutput;
    if (custom != null) {
      await custom();
      return;
    }
    try {
      await stdout.flush();
      await stderr.flush();
    } on Object {
      // The stream may already be closed (for example a closed pipe).
    }
  }
}
