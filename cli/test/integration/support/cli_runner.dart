import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// A running `flutter_run` CLI process whose output can be awaited.
class CliRun {
  CliRun._(this.process, this.args) {
    final outDone = process.stdout.transform(utf8.decoder).listen((s) {
      _out.write(s);
      _poke();
    }).asFuture<void>();
    final errDone = process.stderr.transform(utf8.decoder).listen((s) {
      _err.write(s);
      _poke();
    }).asFuture<void>();
    _streamsDone = Future.wait([outDone, errDone]);
    exitCode = process.exitCode;
  }

  /// Starts [exe] with [args]. The state directory is isolated by [stateDir].
  static Future<CliRun> start(
    String exe,
    List<String> args, {
    required String stateDir,
    Map<String, String> env = const {},
    String? workingDirectory,
  }) async {
    final process = await Process.start(
      exe,
      args,
      workingDirectory: workingDirectory,
      environment: {'FLUTTER_RUN_STATE_DIR': stateDir, 'NO_COLOR': '1', ...env},
    );
    // No terminal and nothing to read.
    unawaited(process.stdin.close().catchError((Object _) {}));
    return CliRun._(process, args);
  }

  final Process process;
  final List<String> args;
  final StringBuffer _out = StringBuffer();
  final StringBuffer _err = StringBuffer();
  final List<Completer<void>> _pokes = [];
  late final Future<int> exitCode;
  late final Future<void> _streamsDone;

  String get stdout => _out.toString();
  String get stderr => _err.toString();
  String get combined => '$stdout$stderr';

  String describe() =>
      'flutter_run ${args.join(' ')}\n--- stdout ---\n$stdout\n--- stderr ---\n$stderr';

  void _poke() {
    for (final c in List.of(_pokes)) {
      if (!c.isCompleted) c.complete();
    }
    _pokes.clear();
  }

  /// Waits until stdout or stderr contains [needle].
  Future<void> waitForText(
    String needle, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!combined.contains(needle)) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) {
        fail('Timed out waiting for "$needle" in CLI output.\n${describe()}');
      }
      final c = Completer<void>();
      _pokes.add(c);
      await c.future.timeout(remaining, onTimeout: () {});
    }
  }

  /// Waits for exit and returns the exit code (fails after [timeout]).
  Future<int> wait({Duration timeout = const Duration(seconds: 120)}) {
    return exitCode
        .then((code) async {
          await _streamsDone;
          return code;
        })
        .timeout(
          timeout,
          onTimeout: () {
            process.kill(ProcessSignal.sigkill);
            fail(
              'flutter_run ${args.join(' ')} did not exit within '
              '${timeout.inSeconds} s.\n${describe()}',
            );
          },
        );
  }

  void kill() => process.kill(ProcessSignal.sigkill);
}

/// Runs the CLI to completion.
Future<CliRun> runCli(
  String exe,
  List<String> args, {
  required String stateDir,
  Map<String, String> env = const {},
  String? workingDirectory,
  Duration timeout = const Duration(seconds: 120),
  int? expectExit,
}) async {
  final run = await CliRun.start(
    exe,
    args,
    stateDir: stateDir,
    env: env,
    workingDirectory: workingDirectory,
  );
  final code = await run.wait(timeout: timeout);
  if (expectExit != null && code != expectExit) {
    fail('Expected exit $expectExit, got $code.\n${run.describe()}');
  }
  return run;
}
