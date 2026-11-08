import 'dart:async';

import '../common/errors.dart';
import 'device_lister.dart';

/// Runs the Flutter launcher at [flutterExecutable] with [args] (supplied by
/// the CLI). May throw [ArgumentError] when an argument is unsafe to pass,
/// and [ExternalToolException] on a spawn failure (with a cause) or a timeout
/// (without one).
typedef FlutterToolExecutor =
    Future<FlutterToolResult> Function(
      String flutterExecutable,
      List<String> args, {
      String? workingDirectory,
      required Duration timeout,
    });

/// Finds the `flutter` launcher for a project.
typedef FlutterExecutableResolver =
    Future<String> Function({String? projectDir, String? explicitSdk});

/// Builds a [FlutterRunnerFactory] from an SDK resolver and a process
/// executor, both wired by the CLI.
FlutterRunnerFactory createFlutterRunnerFactory({
  required FlutterExecutableResolver resolveExecutable,
  required FlutterToolExecutor execute,
  required String currentDirectory,
}) {
  return ({String? projectDir, String? explicitSdk}) async {
    final flutter = await resolveExecutable(
      projectDir: projectDir ?? currentDirectory,
      explicitSdk: explicitSdk,
    );
    return (
      List<String> args, {
      String? workingDirectory,
      Duration? timeout,
    }) async {
      final limit = timeout ?? const Duration(seconds: 60);
      try {
        return await execute(
          flutter,
          args,
          workingDirectory: workingDirectory,
          timeout: limit,
        );
      } on ArgumentError catch (e) {
        throw ExternalToolException(
          'flutter_run refused to run "flutter ${args.join(' ')}": ${e.message}',
        );
      } on ExternalToolException catch (e) {
        // A timeout is an ExternalToolException without a cause; the devices
        // module expects a TimeoutException instead. A spawn failure carries
        // its ProcessException as the cause.
        if (e.cause == null) {
          throw TimeoutException(e.message, limit);
        }
        rethrow;
      }
    };
  };
}
