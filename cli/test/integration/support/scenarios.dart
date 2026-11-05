import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'build_exe.dart';
import 'fake_dap_client.dart';
import 'proxy_harness.dart';
import 'temp_project.dart';

/// `-d flutter-tester --show-test-device`: the headless device, selected
/// explicitly because several devices are connected on dev machines.
const List<String> testerToolArgs = [
  '-d',
  'flutter-tester',
  '--show-test-device',
];

/// Only `--show-test-device`: used when the device comes from elsewhere.
const List<String> showTesterOnly = ['--show-test-device'];

/// A running Flutter launch session driven through the proxy.
class FlutterSession {
  FlutterSession(this.harness, this.app, this.bpLine);

  final ProxyHarness harness;
  final Directory app;
  final int bpLine;

  FakeDapClient get client => harness.client;
  File get mainFile => File(p.join(app.path, 'lib', 'main.dart'));
  String get mainPath => mainFile.path;
}

Future<String> exeOrFail() => ensureFlutterRunExe();

/// Copies sample_app, starts the proxy and drives it to a launched app.
///
/// Mirrors a Zed session: `initialize`, un-awaited `launch`, `initialized`,
/// `setBreakpoints`, `configurationDone`, breakpoint stop in `main()`, then
/// `continue`. Pass [holdConfigurationDone] to stop right after
/// `setBreakpoints` and finish later with [FlutterSession.finishStartup].
class FlutterLaunch {
  FlutterLaunch._(this.session, this.launchResponse, this.bpLine);

  final FlutterSession session;
  final Future<Msg> launchResponse;
  final int bpLine;

  static Future<FlutterLaunch> begin(
    TempWorkspace ws, {
    Directory? app,
    Map<String, Object?> launchArgs = const {},
    List<String> toolArgs = testerToolArgs,
    bool setBreakpoint = true,
    void Function(ProxyHarness)? onHarness,
  }) async {
    final exe = await exeOrFail();
    final dir = app ?? await ws.copyFixture('sample_app');
    final harness = await ProxyHarness.start(exe: exe, workspace: ws, cwd: dir);
    addTearDown(harness.dispose);
    onHarness?.call(harness);
    final line = breakpointLine(File(p.join(dir.path, 'lib', 'main.dart')));
    final client = harness.client;
    await client.initialize();
    final launch = client.request('launch', {
      'adapter': 'FlutterRun',
      'label': 'Flutter (integration test)',
      'request': 'launch',
      'program': 'lib/main.dart',
      'cwd': dir.path,
      'toolArgs': toolArgs,
      ...launchArgs,
    });
    await client.waitForEventNamed('initialized');
    if (setBreakpoint) {
      final r = await client.call('setBreakpoints', {
        'source': {'path': p.join(dir.path, 'lib', 'main.dart')},
        'breakpoints': [
          {'line': line},
        ],
      });
      final bps = (r['body']! as Map)['breakpoints']! as List;
      expect(bps, hasLength(1));
    }
    return FlutterLaunch._(FlutterSession(harness, dir, line), launch, line);
  }

  /// Sends `configurationDone`, waits for the breakpoint stop in `main()`
  /// (if a breakpoint was set), checks the top frame, continues and waits for
  /// `flutter.appStarted`, the launch response and the session file.
  Future<FlutterSession> finishStartup({
    bool expectBreakpoint = true,
    bool resumeFirstStop = true,
  }) async {
    final client = session.client;
    await client.call('configurationDone');
    if (expectBreakpoint) {
      final stopped = await client.waitForStopped();
      final threadId = (stopped['body']! as Map)['threadId']! as int;
      final top = await client.topFrame(threadId);
      expect(top.line, bpLine, reason: 'top frame: ${top.name}');
      expect(top.path, endsWith('main.dart'));
      expect(top.name, contains('bump'));
      if (resumeFirstStop) {
        await client.call('continue', {'threadId': threadId});
      }
    }
    if (resumeFirstStop) {
      await client.waitForEventNamed(
        'flutter.appStarted',
        timeout: const Duration(seconds: 180),
      );
      final response = await launchResponse.timeout(
        const Duration(seconds: 60),
        onTimeout: () => fail('No launch response.\n${client.describe()}'),
      );
      expect(response['success'], isTrue, reason: '$response');
      await session.harness.waitForSession(
        (s) => s['appStarted'] == true && s['vmServiceUri'] != null,
        what: 'a session file with appStarted and vmServiceUri',
      );
    }
    return session;
  }

  /// The common case: everything up to a running app.
  static Future<FlutterSession> start(
    TempWorkspace ws, {
    Directory? app,
    Map<String, Object?> launchArgs = const {},
    List<String> toolArgs = testerToolArgs,
  }) async {
    final launch = await begin(
      ws,
      app: app,
      launchArgs: launchArgs,
      toolArgs: toolArgs,
    );
    return launch.finishStartup();
  }
}

/// A Dart console session paused at the fixture's `BREAKPOINT_TARGET`.
class DartConsoleSession {
  DartConsoleSession(this.harness, this.app, this.line, this.threadId);

  final ProxyHarness harness;
  final Directory app;
  final int line;
  final int threadId;

  FakeDapClient get client => harness.client;
  String get mainPath => p.join(app.path, 'bin', 'main.dart');
}

/// Starts `dap --kind dart` on a temp copy of `fixtures/dart_console` and
/// runs to the first breakpoint stop (not resumed).
Future<DartConsoleSession> startDartConsole(
  TempWorkspace ws, {
  bool setBreakpoint = true,
  String? under,
}) async {
  final exe = await exeOrFail();
  final dir = await ws.copyFixture('dart_console', under: under);
  final harness = await ProxyHarness.start(
    exe: exe,
    workspace: ws,
    cwd: dir,
    kind: 'dart',
  );
  addTearDown(harness.dispose);
  final mainFile = p.join(dir.path, 'bin', 'main.dart');
  final line = breakpointLine(File(mainFile));
  final client = harness.client;
  await client.initialize();
  final launch = client.request('launch', {
    'adapter': 'FlutterRun',
    'label': 'Dart (integration test)',
    'request': 'launch',
    'program': 'bin/main.dart',
    'cwd': dir.path,
  });
  await client.waitForEventNamed('initialized');
  if (setBreakpoint) {
    await client.call('setBreakpoints', {
      'source': {'path': mainFile},
      'breakpoints': [
        {'line': line},
      ],
    });
  }
  await client.call('configurationDone');
  var threadId = 0;
  if (setBreakpoint) {
    final stopped = await client.waitForStopped(
      timeout: const Duration(seconds: 60),
    );
    threadId = (stopped['body']! as Map)['threadId']! as int;
  }
  final response = await launch.timeout(
    const Duration(seconds: 60),
    onTimeout: () => fail('No launch response.\n${client.describe()}'),
  );
  expect(response['success'], isTrue, reason: '$response');
  await harness.waitForSession(
    (s) => s['kind'] == 'dart',
    what: 'the session file of the Dart session',
  );
  return DartConsoleSession(harness, dir, line, threadId);
}

/// Rewrites `kGreeting` in the app's `lib/main.dart` to `Hello <tag>`.
void setGreeting(File mainFile, String tag) {
  final text = mainFile.readAsStringSync();
  mainFile.writeAsStringSync(
    text.replaceFirst(
      RegExp(r"kGreeting = '[^']*'"),
      "kGreeting = 'Hello $tag'",
    ),
  );
}
