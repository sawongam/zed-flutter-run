import 'dart:async';

import '../common/errors.dart';
import '../common/host_environment.dart';
import '../common/paths.dart';
import 'flutter_device.dart';

/// Result of running one `flutter` command.
class FlutterToolResult {
  const FlutterToolResult(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Runs `flutter <args>`. Throws [TimeoutException] when [timeout] elapses.
typedef FlutterRunner =
    Future<FlutterToolResult> Function(
      List<String> flutterArgs, {
      String? workingDirectory,
      Duration? timeout,
    });

/// Resolves the Flutter SDK and returns a [FlutterRunner] (wired by the CLI).
typedef FlutterRunnerFactory =
    Future<FlutterRunner> Function({String? projectDir, String? explicitSdk});

/// How long `flutter devices` and `flutter emulators` may take.
const Duration deviceListTimeout = Duration(seconds: 60);

/// Shown when there is nothing to choose from.
const String noDevicesMessage =
    'No devices found. Start an emulator or simulator (task "Flutter: Launch '
    'Emulator"), connect a phone, or enable Chrome/desktop with "flutter '
    'config --enable-<platform>-desktop". A simulator can take a few seconds '
    'to appear.';

/// Runs `flutter devices --machine` and parses the result.
Future<List<FlutterDevice>> listDevices(
  FlutterRunner run, {
  String? workingDirectory,
}) async {
  final result = await runFlutterChecked(run, const <String>[
    'devices',
    '--machine',
  ], workingDirectory: workingDirectory);
  return parseDevicesMachineOutput(result.stdout);
}

/// Runs [args], mapping a timeout and a non-zero exit to
/// [ExternalToolException].
Future<FlutterToolResult> runFlutterChecked(
  FlutterRunner run,
  List<String> args, {
  String? workingDirectory,
  bool Function(FlutterToolResult)? acceptFailure,
}) async {
  final FlutterToolResult result;
  try {
    result = await run(
      args,
      workingDirectory: workingDirectory,
      timeout: deviceListTimeout,
    );
  } on TimeoutException {
    throw ExternalToolException(timeoutMessage(args.first));
  }
  if (result.exitCode != 0 && !(acceptFailure?.call(result) ?? false)) {
    throw ExternalToolException(
      failureMessage(args.first, result.exitCode, result.stderr),
    );
  }
  return result;
}

/// Message for a `flutter` command that did not answer in time.
String timeoutMessage(String subcommand) =>
    'The command "flutter $subcommand" did not finish within '
    '${deviceListTimeout.inSeconds} seconds. Another running flutter command '
    'may be holding the Flutter startup lock; wait for it to finish or close '
    'it, then try again.';

/// Message for a `flutter` command that failed.
String failureMessage(String subcommand, int exitCode, String stderr) {
  final lines = stderr
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  final tail = lines.isEmpty ? '' : ' It said: ${lines.last}';
  return 'The command "flutter $subcommand" failed with exit code '
      '$exitCode.$tail Run it yourself to see the full output.';
}

/// Nearest project root of [project] (or the current directory), or null.
String? findProjectRootFor(String? project, HostEnvironment env) =>
    findProjectRoot(project ?? env.currentDirectory, env);

/// Throws [ProjectNotFoundException] when there is no project.
String requireProjectRoot(String? project, HostEnvironment env) {
  final root = findProjectRootFor(project, env);
  if (root == null) {
    throw const ProjectNotFoundException(
      'No pubspec.yaml was found in this folder or any folder above it.',
      hint:
          'Run the command inside a Flutter project, or pass --project <dir>.',
    );
  }
  return canonicalDirectory(root, env);
}
