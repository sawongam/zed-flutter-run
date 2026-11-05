import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../common/errors.dart';
import '../common/host_environment.dart';
import '../common/logger.dart';
import 'process_spec.dart';
import 'process_tree.dart';

/// A child process we started and may have to clean up with its descendants.
class ManagedProcess {
  ManagedProcess._(this._process, this._host, this._logger, this._spec) {
    _exited = false;
    _process.exitCode.then((_) => _exited = true, onError: (Object _) {});
  }

  final Process _process;
  final HostEnvironment _host;
  final Logger _logger;
  final ProcessSpec _spec;
  late bool _exited;
  final Map<int, String> _startTimes = <int, String>{};

  /// Starts [spec] directly (never through a shell). [environment] is added to
  /// the inherited environment.
  static Future<ManagedProcess> start(
    ProcessSpec spec, {
    Map<String, String>? environment,
    Logger? logger,
  }) async {
    final log = logger ?? Logger.silent();
    try {
      final process = await Process.start(
        spec.executable,
        spec.arguments,
        workingDirectory: spec.workingDirectory,
        environment: environment,
        runInShell: false,
      );
      log.debug('Started ${spec.executable} (pid ${process.pid}).');
      return ManagedProcess._(process, HostEnvironment.system(), log, spec);
    } on ProcessException catch (e) {
      throw ExternalToolException(
        'Could not start ${spec.executable}: ${e.message}',
        hint:
            'Check that the file exists and can be run, then try again. Run "flutter_run doctor" to see which SDK was chosen.',
        cause: e,
      );
    }
  }

  int get pid => _process.pid;
  Stream<List<int>> get stdout => _process.stdout;
  Stream<List<int>> get stderr => _process.stderr;
  IOSink get stdin => _process.stdin;
  Future<int> get exitCode => _process.exitCode;

  /// Pids of all current descendants (from `ps` on POSIX, PowerShell/wmic on
  /// Windows). Just this pid when the process table cannot be read.
  Future<Set<int>> snapshotDescendants() async {
    final table = await readProcessTable(_host);
    if (table.byPid.isEmpty) return <int>{pid}; // table unreadable
    final descendants = collectDescendants(table.childrenOf, pid);
    for (final d in descendants) {
      final start = table.byPid[d]?.startTime;
      if (start != null) _startTimes[d] = start;
    }
    final rootStart = table.byPid[pid]?.startTime;
    if (rootStart != null) _startTimes[pid] = rootStart;
    // Forget processes that no longer exist so the map stays bounded.
    _startTimes.removeWhere((pid, _) => !table.byPid.containsKey(pid));
    return descendants;
  }

  /// Last resort: kills this process (if it is still alive), its current
  /// descendants and [extraPids] (the caller's snapshot). With [crashed],
  /// [extraPids] may have been reparented after a crash; those that are
  /// shared daemons (adb, Gradle, Kotlin, Dart tooling daemon) are spared.
  Future<void> terminateTree({
    Set<int> extraPids = const <int>{},
    Duration grace = const Duration(seconds: 2),
    bool crashed = false,
  }) async {
    if (!_exited) {
      try {
        await snapshotDescendants();
      } on Object catch (e) {
        _logger.debug('Could not snapshot the process tree: $e');
      }
    }
    var all = <int>{...extraPids};
    if (crashed && all.isNotEmpty) {
      final commands = await readCommandLines(all, _host);
      all = {
        for (final pid in all)
          if (commands[pid] != null && !isSharedDaemonCommand(commands[pid]!))
            pid,
      };
    }
    final root = _exited ? -1 : pid;
    _logger.debug(
      'Terminating process tree of pid $pid (${all.length} others).',
    );
    await killTree(root, all, _host, grace: grace, startTimes: _startTimes);
    if (!_exited) {
      try {
        await _process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        _logger.warn('Process $pid did not exit after being killed.');
      }
    }
  }

  @override
  String toString() => 'ManagedProcess(${_spec.executable}, pid $pid)';
}

class ToolOutput {
  const ToolOutput(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Runs [spec] to completion and collects its output. On [timeout] the whole
/// process tree is killed and an [ExternalToolException] is thrown.
Future<ToolOutput> runTool(
  ProcessSpec spec, {
  Map<String, String>? environment,
  Duration timeout = const Duration(seconds: 60),
  Logger? logger,
}) async {
  final process = await ManagedProcess.start(
    spec,
    environment: environment,
    logger: logger,
  );
  unawaited(process.stdin.close().catchError((Object _) {}));
  final out = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final err = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  try {
    final code = await process.exitCode.timeout(timeout);
    return ToolOutput(code, await out, await err);
  } on TimeoutException {
    await process.terminateTree();
    unawaited(out.then((_) {}, onError: (Object _) {}));
    unawaited(err.then((_) {}, onError: (Object _) {}));
    throw ExternalToolException(
      '${spec.executable} did not finish within ${timeout.inSeconds} seconds and was stopped.',
      hint:
          'Try again; if it keeps happening run the same command in a terminal to see what it waits for.',
    );
  }
}
