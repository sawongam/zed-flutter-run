import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fake_dap_client.dart';
import 'process_checks.dart';
import 'temp_project.dart';
import 'wait.dart';

/// First sequence number of messages the proxy makes up itself.
const int syntheticSeqBase = 1000000000;

/// Spawns `flutter_run dap` exactly as the Zed extension does (argv from
/// `extension/src/proxy_args.rs`) and drives it with a [FakeDapClient].
class ProxyHarness {
  ProxyHarness._(
    this.process,
    this.workspace,
    this.logFile,
    this.kind,
    this.request,
  ) {
    process.stderr.transform(utf8.decoder).listen(_stderr.write);
    // Writing to a killed proxy must not become an uncaught error.
    unawaited(process.stdin.done.catchError((Object _) {}));
    client = FakeDapClient(process.stdout, process.stdin, describeProxy);
  }

  static Future<ProxyHarness> start({
    required String exe,
    required TempWorkspace workspace,
    required Directory cwd,
    String kind = 'flutter',
    String request = 'launch',
    Map<String, String> env = const {},
    List<String> extraArgs = const [],
  }) async {
    final logFile = p.join(
      workspace.root.path,
      'proxy-${DateTime.now().microsecondsSinceEpoch}.log',
    );
    final args = [
      'dap',
      '--cwd',
      cwd.path,
      '--kind',
      kind,
      '--request',
      request,
      ...extraArgs,
      '--log-file',
      logFile,
      '--client-version',
      '0.1.0',
    ];
    final process = await Process.start(
      exe,
      args,
      environment: {'FLUTTER_RUN_STATE_DIR': workspace.stateDir, ...env},
    );
    final harness = ProxyHarness._(process, workspace, logFile, kind, request);
    harness._exit = process.exitCode;
    return harness;
  }

  final Process process;
  final TempWorkspace workspace;
  final String logFile;
  final String kind;
  final String request;
  late final FakeDapClient client;
  late final Future<int> _exit;
  final StringBuffer _stderr = StringBuffer();
  final Set<int> _known = {};
  bool _stopped = false;

  int get pid => process.pid;
  String get stderrText => _stderr.toString();
  Future<int> get exitCode => _exit;

  /// Proxy stderr plus the tail of the DAP log, for failure messages.
  String describeProxy() {
    final log = logText;
    final lines = LineSplitter.split(log).toList();
    final tail = lines.length > 40 ? lines.sublist(lines.length - 40) : lines;
    return 'proxy stderr:\n$stderrText\nproxy log tail:\n${tail.join('\n')}';
  }

  String get logText {
    try {
      return File(logFile).readAsStringSync();
    } on FileSystemException {
      return '';
    }
  }

  // ---------------------------------------------------------- session files

  File get sessionFile => File(p.join(workspace.sessionsDir, '$pid.json'));

  List<Map<String, Object?>> sessions() {
    final dir = Directory(workspace.sessionsDir);
    if (!dir.existsSync()) return const [];
    final out = <Map<String, Object?>>[];
    for (final e in dir.listSync()) {
      if (e is File && e.path.endsWith('.json')) {
        try {
          out.add((jsonDecode(e.readAsStringSync()) as Map).cast());
        } on Object catch (_) {
          // Being replaced; the next poll sees it.
        }
      }
    }
    return out;
  }

  Map<String, Object?>? ownSession() {
    for (final s in sessions()) {
      if (s['pid'] == pid) return s;
    }
    return null;
  }

  /// Waits (polling the file) for this proxy's session file to satisfy [test].
  Future<Map<String, Object?>> waitForSession(
    bool Function(Map<String, Object?>) test, {
    Duration timeout = const Duration(seconds: 60),
    String what = 'the session file',
  }) => pollFor<Map<String, Object?>>(
    () {
      final s = ownSession();
      return s != null && test(s) ? s : null;
    },
    timeout: timeout,
    what: what,
    context: client.describe,
  );

  // ---------------------------------------------------------------- DAP log

  /// Injected requests (`INJ` lines) of [command], optionally filtered by the
  /// `reason` argument. Each entry is the decoded request.
  List<Map<String, Object?>> injected(String command, {String? reason}) {
    final out = <Map<String, Object?>>[];
    for (final line in LineSplitter.split(logText)) {
      final i = line.indexOf(' INJ ');
      if (i < 0) continue;
      try {
        final m = (jsonDecode(line.substring(i + 5)) as Map)
            .cast<String, Object?>();
        if (m['command'] != command) continue;
        if (reason != null && (m['arguments'] as Map?)?['reason'] != reason) {
          continue;
        }
        out.add(m);
      } on FormatException {
        continue;
      }
    }
    return out;
  }

  /// Requests the proxy forwarded to the adapter (`A>` lines) of [command].
  List<Map<String, Object?>> forwarded(String command) {
    final out = <Map<String, Object?>>[];
    for (final line in LineSplitter.split(logText)) {
      final i = line.indexOf(' A> ');
      if (i < 0) continue;
      try {
        final m = (jsonDecode(line.substring(i + 4)) as Map)
            .cast<String, Object?>();
        if (m['type'] == 'request' && m['command'] == command) out.add(m);
      } on FormatException {
        continue;
      }
    }
    return out;
  }

  // -------------------------------------------------------------- processes

  /// Remembers every current descendant of the proxy (the adapter, `dart
  /// development-service`, the app, ...) so they can be checked after a stop.
  Future<Set<int>> trackTree() async {
    _known.addAll(await descendantsOf(pid));
    return _known;
  }

  Set<int> get knownTree => Set.of(_known);

  /// The process the proxy started as the debug adapter (a direct child).
  Future<int?> adapterPid() async {
    final kids = await childrenOf(pid);
    final lines = await commandLines(kids);
    for (final e in lines.entries) {
      if (e.value.contains('debug_adapter')) return e.key;
    }
    return null;
  }

  // ------------------------------------------------------------ stop paths

  /// Zed's real stop path (`Session::shutdown`): send `terminate`, and as soon
  /// as its response arrives kill the proxy hard. Then check that the session
  /// file is gone at once and that no descendant outlives the proxy.
  Future<void> zedStop({String command = 'terminate'}) async {
    if (_stopped) return;
    await trackTree();
    final args = command == 'disconnect'
        ? <String, Object?>{'terminateDebuggee': true}
        : null;
    final response = await within(
      client.request(command, args),
      const Duration(seconds: 30),
      'the $command response',
      context: client.describe,
    );
    // Zed kills the adapter process right here.
    _stopped = true;
    process.kill(ProcessSignal.sigkill);
    expect(
      response['success'],
      isTrue,
      reason: '$command was refused: ${jsonEncode(response)}',
    );
    expect(
      sessionFile.existsSync(),
      isFalse,
      reason:
          'The session file must be gone before the $command response is '
          'relayed.\n${describeProxy()}',
    );
    await within(_exit, const Duration(seconds: 15), 'the killed proxy');
    await expectAllGone(
      _known,
      what: 'descendants of the proxy after Zed killed it',
      context: describeProxy,
    );
    expect(
      Directory(workspace.sessionsDir).existsSync()
          ? Directory(
              workspace.sessionsDir,
            ).listSync().where((e) => e.path.endsWith('$pid.json'))
          : const <FileSystemEntity>[],
      isEmpty,
      reason: 'stale session file',
    );
  }

  /// Safety net for `addTearDown`: kills the proxy and everything it started.
  Future<void> dispose() async {
    try {
      await trackTree();
    } on Object catch (_) {}
    process.kill(ProcessSignal.sigkill);
    killAll(_known);
    try {
      await _exit.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      // Nothing more to do.
    }
    try {
      await process.stdin.close();
    } on Object catch (_) {}
    await client.dispose();
    final sessions = File(sessionFile.path);
    if (sessions.existsSync()) {
      try {
        sessions.deleteSync();
      } on FileSystemException {
        // Gone with the temp directory.
      }
    }
    await expectAllGone(_known, what: 'processes left by this test');
  }
}
