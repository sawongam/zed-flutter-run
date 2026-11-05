import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'process_checks.dart';
import 'wait.dart';

/// `flutter run --machine` started by hand, like a user running the app in a
/// terminal before attaching the debugger to it.
class MachineApp {
  MachineApp._(this.process) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          _lines.add(line);
          if (!line.startsWith('[')) return;
          try {
            final decoded = jsonDecode(line);
            if (decoded is List) {
              for (final m in decoded) {
                if (m is Map && m['event'] is String) {
                  final event = (m['event'] as String);
                  final params =
                      (m['params'] as Map?)?.cast<String, Object?>() ?? {};
                  events.add((event, params));
                  final waiters = _waiters[event];
                  if (waiters != null) {
                    for (final w in waiters) {
                      if (!w.isCompleted) w.complete(params);
                    }
                    waiters.clear();
                  }
                }
              }
            }
          } on FormatException {
            // Not machine output.
          }
        });
    process.stderr.transform(utf8.decoder).listen(_stderr.write);
    unawaited(process.stdin.done.catchError((Object _) {}));
  }

  static Future<MachineApp> start(Directory app) async {
    final process = await Process.start(
      'flutter',
      ['run', '--machine', '-d', 'flutter-tester', '--show-test-device'],
      workingDirectory: app.path,
      runInShell: Platform.isWindows,
    );
    return MachineApp._(process);
  }

  final Process process;
  final List<String> _lines = [];
  final StringBuffer _stderr = StringBuffer();
  final List<(String, Map<String, Object?>)> events = [];
  final Map<String, List<Completer<Map<String, Object?>>>> _waiters = {};
  final Set<int> tree = {};

  String describe() =>
      'flutter run --machine stdout (last 30):\n'
      '${_lines.length > 30 ? _lines.sublist(_lines.length - 30).join('\n') : _lines.join('\n')}'
      '\nstderr:\n$_stderr';

  Future<Map<String, Object?>> waitForEvent(
    String name, {
    Duration timeout = const Duration(seconds: 180),
  }) {
    for (final e in events) {
      if (e.$1 == name) return Future.value(e.$2);
    }
    final c = Completer<Map<String, Object?>>();
    _waiters.putIfAbsent(name, () => []).add(c);
    return within(
      c.future,
      timeout,
      'the "$name" machine event',
      context: describe,
    );
  }

  /// Remembers the process tree (flutter tool, DDS, flutter_tester, ...).
  Future<void> trackTree() async {
    tree
      ..add(process.pid)
      ..addAll(await descendantsOf(process.pid));
  }

  /// Asks the app to stop over the machine protocol, like pressing `q`.
  Future<void> stopApp(String appId) async {
    process.stdin.writeln(
      jsonEncode([
        {
          'id': 1,
          'method': 'app.stop',
          'params': {'appId': appId},
        },
      ]),
    );
    await process.stdin.flush();
  }

  Future<int> get exitCode => process.exitCode;

  Future<void> dispose() async {
    try {
      await trackTree();
    } on Object catch (_) {}
    killAll(tree);
    process.kill(ProcessSignal.sigkill);
  }
}
