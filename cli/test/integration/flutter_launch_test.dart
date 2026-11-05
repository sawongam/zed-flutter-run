@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/cli_runner.dart';
import 'support/fake_dap_client.dart';
import 'support/process_checks.dart';
import 'support/proxy_harness.dart';
import 'support/scenarios.dart';
import 'support/temp_project.dart';

/// Keeps file edits from triggering reload on save, so these tests exercise
/// only the CLI path.
const noSave = <String, Object?>{'reloadOnSave': 'off'};

void main() {
  late TempWorkspace ws;
  late String exe;

  setUpAll(() async {
    exe = await exeOrFail();
    await preparedFixture('sample_app');
    await preparedFixture('dart_console');
  });

  setUp(() {
    ws = TempWorkspace.create();
    addTearDown(ws.dispose);
  });

  Future<CliRun> cli(List<String> args, {int? expectExit}) =>
      runCli(exe, args, stateDir: ws.stateDir, expectExit: expectExit);

  test(
    'launch, breakpoint, status, reload, restart, DevTools, then no orphans',
    () async {
      final s = await FlutterLaunch.start(ws, launchArgs: noSave);
      final c = s.client;
      final h = s.harness;

      expect(c.outputs.join(), contains('GREETING: Hello v1'));
      final session = h.ownSession()!;
      expect(session['kind'], 'flutter');
      expect(session['request'], 'launch');
      expect(session['appStarted'], isTrue);
      expect(session['mode'], 'debug');
      expect(session['deviceId'], 'flutter-tester');
      expect(
        session['vmServiceUri'],
        matches(RegExp(r'^ws://127\.0\.0\.1:\d+/')),
      );

      // The extension-built command line prints the start notices once.
      expect(
        c.countOutputs('flutter_run command is not on your PATH'),
        lessThanOrEqualTo(1),
      );
      expect(c.countOutputs('Reload on save is on for'), 0);

      // status --json lists the live session.
      final status = await cli([
        'status',
        '--json',
        '--project',
        s.app.path,
      ], expectExit: 0);
      final listed = (jsonDecode(status.stdout) as Map)['sessions'] as List;
      final mine = listed.cast<Map<String, Object?>>().singleWhere(
        (e) => e['pid'] == h.pid,
      );
      expect(mine['matches'], isTrue);
      expect(mine['appStarted'], isTrue);

      // Hot reload through the CLI: new string, breakpoint hit again.
      final resume = AutoResume(c);
      setGreeting(s.mainFile, 'v2');
      var mark = c.outputMark;
      final reload = await cli([
        'reload',
        '--project',
        s.app.path,
      ], expectExit: 0);
      expect(
        reload.stdout,
        matches(RegExp(r'Hot reload: flutter-tester \S+ ok in [\d.]+ s')),
      );
      await c.waitForOutput('Reloaded', from: mark);
      await c.waitForOutput('GREETING: Hello v2', from: mark);
      expect(resume.stops, isNotEmpty, reason: 'reassemble() hits bump()');
      expect(resume.stops.last, endsWith('lib/main.dart:${s.bpLine}'));
      final stopsAfterReload = resume.stops.length;

      // Hot restart: main() runs again and the breakpoint is hit again.
      mark = c.outputMark;
      final restart = await cli([
        'restart',
        '--project',
        s.app.path,
      ], expectExit: 0);
      expect(
        restart.stdout,
        matches(RegExp(r'Hot restart: flutter-tester \S+ ok in')),
      );
      await c.waitForOutput('Restarted application', from: mark);
      await c.waitForOutput('GREETING: Hello v2', from: mark);
      await c.waitForOutput('BUMP: 2', from: mark);
      expect(resume.stops.length, greaterThan(stopsAfterReload));
      await resume.stop();

      // The proxy's own requests never leak to the client.
      expect(h.injected('hotReload', reason: 'manual'), hasLength(1));
      expect(h.injected('hotRestart', reason: 'manual'), hasLength(1));
      expect(
        c.responses.keys.where((k) => k >= syntheticSeqBase),
        isEmpty,
        reason: 'responses to injected requests must be swallowed',
      );

      // DevTools URL from the CLI answers over HTTP.
      final dev = await cli([
        'devtools',
        '--print',
        '--project',
        s.app.path,
      ], expectExit: 0);
      final url = dev.stdout.trim();
      expect(
        url,
        matches(
          RegExp(
            r'^http://127\.0\.0\.1:\d+/[^/]+/devtools/inspector\?uri=ws%3A%2F%2F',
          ),
        ),
      );
      final http = HttpClient()..findProxy = (_) => 'DIRECT';
      try {
        final response = await (await http.getUrl(Uri.parse(url))).close();
        final body = await utf8.decodeStream(response);
        expect(response.statusCode, 200);
        expect(body, contains('flutter_bootstrap.js'));
      } finally {
        http.close(force: true);
      }

      // Stop like Zed: terminate, kill the proxy; nothing may survive.
      final tree = await h.trackTree();
      final lines = (await commandLines(tree)).values.join('\n');
      printOnFailure('process tree before stop:\n$lines');
      expect(lines, contains('flutter_tester'));
      await h.zedStop();
    },
  );

  test('deviceId in the launch entry is injected as -d', () async {
    final s = await FlutterLaunch.start(
      ws,
      toolArgs: showTesterOnly,
      launchArgs: {'deviceId': 'flutter-tester'},
    );
    final launch = s.harness.forwarded('launch').single['arguments'] as Map;
    expect(launch['toolArgs'], [...showTesterOnly, '-d', 'flutter-tester']);
    expect(launch.containsKey('deviceId'), isFalse);
    expect(launch.containsKey('adapter'), isFalse);
    expect(launch.containsKey('label'), isFalse);
    await s.harness.zedStop(command: 'disconnect');
  });

  test('reload that hits a breakpoint finishes once the user resumes', () async {
    // Flutter 3.47.9 answers hotReload about 2 s after the stop even when the
    // user has not resumed, so the proxy's 3 s "Waiting..." line cannot be
    // provoked here (see the report). This test pins what must hold: the stop
    // arrives during the reload, resuming it is accepted, and the CLI exits 0.
    final s = await FlutterLaunch.start(ws, launchArgs: noSave);
    final c = s.client;
    setGreeting(s.mainFile, 'v2');
    final mark = c.eventMark;
    final outMark = c.outputMark;
    final reload = await CliRun.start(exe, [
      'reload',
      '--project',
      s.app.path,
    ], stateDir: ws.stateDir);
    addTearDown(reload.kill);
    final stopped = await c.waitForStopped(
      from: mark,
      timeout: const Duration(seconds: 60),
    );
    final threadId = (stopped['body']! as Map)['threadId']! as int;
    final top = await c.topFrame(threadId);
    expect(top.line, s.bpLine);
    expect(top.name, contains('bump'));
    await c.call('continue', {'threadId': threadId});
    expect(
      await reload.wait(timeout: const Duration(seconds: 60)),
      0,
      reason: reload.describe(),
    );
    expect(reload.stdout, contains('ok in'));
    await c.waitForOutput('Reloaded', from: outMark);
    await s.harness.zedStop();
  });

  test('reload before the app has started says it is still starting', () async {
    final launch = await FlutterLaunch.begin(ws, launchArgs: noSave);
    final h = launch.session.harness;
    // configurationDone is withheld, so the app cannot finish starting.
    final early = await h.waitForSession((s) => s['appStarted'] == false);
    expect(early['kind'], 'flutter');
    final result = await cli([
      'reload',
      '--project',
      launch.session.app.path,
    ], expectExit: 4);
    expect(result.combined, contains('still starting'));
    final restart = await cli([
      'restart',
      '--project',
      launch.session.app.path,
    ], expectExit: 4);
    expect(restart.combined, contains('still starting'));
    final s = await launch.finishStartup();
    final after = await cli([
      'reload',
      '--project',
      s.app.path,
    ]).then((r) => r.stdout);
    expect(after, isNotEmpty);
    await s.harness.zedStop();
  });

  test(
    'one reload from a parent folder reloads every Flutter app below it',
    () async {
      final parent = Directory('${ws.projectsDir}/monorepo')..createSync();
      final app1 = await ws.copyFixture(
        'sample_app',
        name: 'app_one',
        under: parent.path,
      );
      final app2 = await ws.copyFixture(
        'sample_app',
        name: 'app_two',
        under: parent.path,
      );
      final one = await FlutterLaunch.start(ws, app: app1, launchArgs: noSave);
      final two = await FlutterLaunch.start(ws, app: app2, launchArgs: noSave);
      final dart = await startDartConsole(ws, under: parent.path);

      final resume1 = AutoResume(one.client);
      final resume2 = AutoResume(two.client);
      final mark1 = one.client.outputMark;
      final mark2 = two.client.outputMark;
      final result = await cli([
        'reload',
        '--project',
        parent.path,
      ], expectExit: 0);
      final okLines = RegExp(
        r'Hot reload: flutter-tester \S+ ok in',
      ).allMatches(result.stdout);
      expect(okLines, hasLength(2), reason: result.describe());
      expect(result.stdout, contains('app_one'));
      expect(result.stdout, contains('app_two'));
      expect(
        result.stderr,
        contains(
          'Skipped pid ${dart.harness.pid}: it is a Dart console session',
        ),
      );
      await one.client.waitForOutput('Reloaded', from: mark1);
      await two.client.waitForOutput('Reloaded', from: mark2);
      await resume1.stop();
      await resume2.stop();

      await dart.harness.zedStop();
      await one.harness.zedStop();
      await two.harness.zedStop();
    },
  );
}
