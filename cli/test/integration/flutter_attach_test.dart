@Tags(['integration'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/cli_runner.dart';
import 'support/fake_dap_client.dart';
import 'support/machine_app.dart';
import 'support/process_checks.dart';
import 'support/proxy_harness.dart';
import 'support/scenarios.dart';
import 'support/temp_project.dart';
import 'support/wait.dart';

/// `http://H:P/TOKEN=/` form of the VM service address from `app.debugPort`
/// (the form the README tells users to copy; docs/research/attach-probe.md).
String _httpForm(String wsUri) {
  final u = Uri.parse(wsUri);
  final path = u.path.endsWith('/ws')
      ? u.path.substring(0, u.path.length - 2)
      : u.path;
  return u.replace(scheme: 'http', path: path).toString();
}

void main() {
  late TempWorkspace ws;
  late String exe;

  setUpAll(() async {
    exe = await exeOrFail();
    await preparedFixture('sample_app');
  });

  setUp(() {
    ws = TempWorkspace.create();
    addTearDown(ws.dispose);
  });

  /// Starts the app by hand and attaches the proxy to it.
  Future<(MachineApp, String, ProxyHarness, Directory)> attach({
    Map<String, Object?> extra = const {},
  }) async {
    final app = await ws.copyFixture('sample_app');
    final machine = await MachineApp.start(app);
    addTearDown(machine.dispose);
    final port = await machine.waitForEvent('app.debugPort');
    await machine.waitForEvent('app.started');
    final appId = port['appId']! as String;
    final vmUri = _httpForm(port['wsUri']! as String);

    final harness = await ProxyHarness.start(
      exe: exe,
      workspace: ws,
      cwd: app,
      request: 'attach',
    );
    addTearDown(harness.dispose);
    final c = harness.client;
    await c.initialize();
    final attachResponse = c.request('attach', {
      'adapter': 'FlutterRun',
      'label': 'Flutter: Attach (integration test)',
      'request': 'attach',
      'cwd': app.path,
      'vmServiceUri': vmUri,
      'toolArgs': testerToolArgs,
      ...extra,
    });
    await c.waitForEventNamed('initialized');
    await c.call('setBreakpoints', {
      'source': {'path': p.join(app.path, 'lib', 'main.dart')},
      'breakpoints': [
        {'line': breakpointLine(File(p.join(app.path, 'lib', 'main.dart')))},
      ],
    });
    await c.call('configurationDone');
    await c.waitForEventNamed(
      'flutter.appStarted',
      timeout: const Duration(seconds: 120),
    );
    final response = await attachResponse.timeout(
      const Duration(seconds: 60),
      onTimeout: () => fail('No attach response.\n${c.describe()}'),
    );
    expect(response['success'], isTrue, reason: '$response');
    await harness.waitForSession(
      (s) => s['appStarted'] == true && s['request'] == 'attach',
      what: 'an attach session file with appStarted',
    );
    return (machine, appId, harness, app);
  }

  /// After the proxy is gone the app must still run; then stop it for real.
  Future<void> expectAppSurvivesThenStop(
    MachineApp machine,
    String appId,
  ) async {
    expect(isAlive(machine.process.pid), isTrue, reason: machine.describe());
    final lines = (await commandLines(machine.tree)).values.join('\n');
    expect(lines, contains('flutter_tester'));
    final testers = [
      for (final e in (await commandLines(machine.tree)).entries)
        if (e.value.contains('flutter_tester')) e.key,
    ];
    for (final pid in testers) {
      expect(isAlive(pid), isTrue, reason: 'flutter_tester $pid must survive');
    }

    await machine.stopApp(appId);
    await within(
      machine.exitCode,
      const Duration(seconds: 60),
      'flutter run to exit after app.stop',
      context: machine.describe,
    );
    await expectAllGone(
      machine.tree,
      what: 'processes of the hand-started app',
      timeout: const Duration(seconds: 30),
    );
  }

  test(
    'attach by vmServiceUri: reload, reload on save, stop keeps the app',
    () async {
      final (machine, appId, h, app) = await attach();
      final c = h.client;
      final resume = AutoResume(c);
      addTearDown(resume.stop);

      // The proxy started the adapter without its own DDS.
      final adapter = await h.adapterPid();
      expect(adapter, isNotNull);
      final adapterLine = (await commandLines([adapter!])).values.single;
      final adapterTree = (await commandLines(
        await descendantsOf(h.pid),
      )).values.join('\n');
      expect('$adapterLine\n$adapterTree', contains('--no-dds'));

      final session = h.ownSession()!;
      expect(session['request'], 'attach');
      expect(session['kind'], 'flutter');
      expect(c.countOutputs('Reload on save is on for lib/'), 1);

      // Manual reload through the CLI (no file change): reassemble hits bump().
      var mark = c.outputMark;
      final reload = await runCli(
        exe,
        ['reload', '--project', app.path],
        stateDir: ws.stateDir,
        expectExit: 0,
      );
      expect(reload.stdout, matches(RegExp(r'Hot reload: \S+ \S+ ok in')));
      await c.waitForOutput('Reloaded', from: mark);
      expect(resume.stops, isNotEmpty);
      expect(resume.stops.last, endsWith('lib/main.dart:7'));

      // Reload on save works in attach mode too.
      mark = c.outputMark;
      setGreeting(File(p.join(app.path, 'lib', 'main.dart')), 'v2');
      await c.waitForOutput('Hot reload on save: lib/main.dart', from: mark);
      await c.waitForOutput('GREETING: Hello v2', from: mark);
      expect(h.injected('hotReload', reason: 'save'), hasLength(1));
      await resume.stop();

      // Stop like Zed; the app is not ours to kill.
      await machine.trackTree();
      await h.zedStop();
      await expectAppSurvivesThenStop(machine, appId);
    },
  );

  test(
    'disconnect-only stop in attach mode also leaves the app running',
    () async {
      final (machine, appId, h, _) = await attach(
        extra: {'reloadOnSave': 'off'},
      );
      await machine.trackTree();
      await h.zedStop(command: 'disconnect');
      await expectAppSurvivesThenStop(machine, appId);
    },
  );
}
