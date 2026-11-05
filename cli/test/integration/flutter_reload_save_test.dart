@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/cli_runner.dart';
import 'support/fake_dap_client.dart';
import 'support/proxy_harness.dart';
import 'support/scenarios.dart';
import 'support/temp_project.dart';
import 'support/wait.dart';

/// The bounded "nothing happens" window used by the negative checks.
const _quiet = Duration(seconds: 3);

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

  int saveReloads(ProxyHarness h) =>
      h.injected('hotReload', reason: 'save').length;

  /// Starts a session with an auto-resume so breakpoint stops during reload do
  /// not block it.
  Future<(FlutterSession, AutoResume)> start({
    Map<String, Object?> launchArgs = const {},
    Directory? app,
  }) async {
    final s = await FlutterLaunch.start(ws, app: app, launchArgs: launchArgs);
    final resume = AutoResume(s.client);
    addTearDown(resume.stop);
    return (s, resume);
  }

  test('a changed file reloads on save; identical content does not', () async {
    final (s, _) = await start();
    final c = s.client;
    final h = s.harness;

    expect(c.countOutputs('Reload on save is on for lib/'), 1);
    expect(c.countOutputs('changed files only'), 1);

    final mark = c.outputMark;
    setGreeting(s.mainFile, 'v3');
    await c.waitForOutput('Hot reload on save: lib/main.dart', from: mark);
    await c.waitForOutput('GREETING: Hello v3', from: mark);
    await c.waitForOutput('Reloaded', from: mark);

    final injected = h.injected('hotReload', reason: 'save');
    expect(injected, hasLength(1));
    expect(injected.single['seq'], greaterThanOrEqualTo(syntheticSeqBase));
    expect((injected.single['arguments']! as Map)['reason'], 'save');
    expect(c.countOutputs('Reload on save is on for'), 1, reason: 'armed once');

    // Same bytes again: the content hash is unchanged, so nothing reloads.
    s.mainFile.writeAsStringSync(s.mainFile.readAsStringSync());
    await expectQuiet(
      () => saveReloads(h) > 1,
      _quiet,
      what: 'a reload after saving identical content',
      context: c.describe,
    );
    await h.zedStop();
  });

  test('reloadOnSave "always" reloads identical content too', () async {
    final (s, _) = await start(launchArgs: {'reloadOnSave': 'always'});
    final h = s.harness;
    setGreeting(s.mainFile, 'v3');
    await pollFor<bool>(
      () => saveReloads(h) >= 1 ? true : null,
      timeout: const Duration(seconds: 60),
      what: 'the first save reload',
      context: s.client.describe,
    );
    s.mainFile.writeAsStringSync(s.mainFile.readAsStringSync());
    await pollFor<bool>(
      () => saveReloads(h) >= 2 ? true : null,
      timeout: const Duration(seconds: 60),
      what: 'a reload for the identical rewrite',
      context: s.client.describe,
    );
    await h.zedStop();
  });

  test('reloadOnSave "off" never watches or reloads', () async {
    final (s, _) = await start(launchArgs: {'reloadOnSave': 'off'});
    final c = s.client;
    final h = s.harness;
    expect(c.countOutputs('Reload on save is on'), 0);
    setGreeting(s.mainFile, 'v3');
    await expectQuiet(
      () => saveReloads(h) > 0 || c.countOutputs('Hot reload on save') > 0,
      _quiet,
      what: 'a reload with reloadOnSave off',
      context: c.describe,
    );
    await h.zedStop();
  });

  test('build, .dart_tool, ios and dot folders never reload', () async {
    final (s, _) = await start();
    final c = s.client;
    final h = s.harness;
    for (final path in [
      'build/gen.dart',
      '.dart_tool/gen.dart',
      'ios/Runner/gen.dart',
      'lib/.hidden/gen.dart',
    ]) {
      final file = File(p.join(s.app.path, path))..createSync(recursive: true);
      file.writeAsStringSync('// $path\n');
    }
    await expectQuiet(
      () => saveReloads(h) > 0,
      _quiet,
      what: 'a reload caused by an ignored folder',
      context: c.describe,
    );
    // Positive control: a "build" folder *inside* lib/ is not ignored.
    final mark = c.outputMark;
    File(p.join(s.app.path, 'lib', 'build', 'x.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('// x\n');
    await c.waitForOutput('Hot reload on save: lib/build/x.dart', from: mark);
    await c.waitForOutput('Reloaded', from: mark);
    expect(saveReloads(h), 1);
    await h.zedStop();
  });

  test('two edits 10 ms apart cause exactly one reload', () async {
    final (s, _) = await start();
    final c = s.client;
    final h = s.harness;
    final mark = c.outputMark;
    setGreeting(s.mainFile, 'v3');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    setGreeting(s.mainFile, 'v4');
    await c.waitForOutput('Reloaded', from: mark);
    await c.waitForOutput('GREETING: Hello v4', from: mark);
    await expectQuiet(
      () => saveReloads(h) > 1,
      const Duration(seconds: 2),
      what: 'a second reload for the second edit',
      context: c.describe,
    );
    expect(saveReloads(h), 1);
    await h.zedStop();
  });

  test('a burst of 200 writes causes one reload (plus at most one)', () async {
    final (s, _) = await start();
    final c = s.client;
    final h = s.harness;
    final mark = c.outputMark;
    final original = s.mainFile.readAsStringSync();
    for (var i = 0; i < 200; i++) {
      s.mainFile.writeAsStringSync('$original\n// burst $i\n');
    }
    setGreeting(s.mainFile, 'v5');
    await c.waitForOutput('GREETING: Hello v5', from: mark);
    await expectQuiet(
      () => saveReloads(h) > 2,
      const Duration(seconds: 2),
      what: 'more than one follow-up reload',
      context: c.describe,
    );
    expect(saveReloads(h), inInclusiveRange(1, 2), reason: c.describe());
    await h.zedStop();
  });

  test('reloadOnSaveGlobs makes assets/*.json trigger a reload', () async {
    final app = await ws.copyFixture('sample_app');
    File(p.join(app.path, 'assets', 'x.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"v":1}\n');
    final (s, _) = await start(
      app: app,
      launchArgs: {
        'reloadOnSaveGlobs': ['assets/**.json'],
      },
    );
    final c = s.client;
    expect(c.countOutputs('assets/'), greaterThan(0), reason: 'armed notice');
    final mark = c.outputMark;
    File(p.join(app.path, 'assets', 'x.json')).writeAsStringSync('{"v":2}\n');
    await c.waitForOutput('Hot reload on save: assets/x.json', from: mark);
    await c.waitForOutput('Reloaded', from: mark);
    expect(saveReloads(s.harness), 1);
    await s.harness.zedStop();
  });

  test('a save during a restart reloads after the restart', () async {
    final (s, _) = await start();
    final c = s.client;
    final h = s.harness;
    final mark = c.outputMark;

    final restart = await CliRun.start(exe, [
      'restart',
      '--project',
      s.app.path,
    ], stateDir: ws.stateDir);
    addTearDown(restart.kill);
    // The restart is in flight from the moment the proxy injects it; edit the
    // file right then so the save reload is requested while it still runs.
    await pollFor<bool>(
      () => h.injected('hotRestart').isNotEmpty ? true : null,
      timeout: const Duration(seconds: 30),
      what: 'the injected hotRestart',
      interval: const Duration(milliseconds: 10),
      context: c.describe,
    );
    setGreeting(s.mainFile, 'v6');
    expect(
      await restart.wait(timeout: const Duration(seconds: 60)),
      0,
      reason: restart.describe(),
    );
    final restarted = await c.waitForOutput(
      'Restarted application',
      from: mark,
    );
    // The queued save reload runs after the restart finished.
    final reloaded = await c.waitForOutput('Reloaded', from: restarted);
    await c.waitForOutput('GREETING: Hello v6', from: restarted);
    expect(reloaded, greaterThan(restarted));
    await pollFor<bool>(
      () => saveReloads(h) >= 1 ? true : null,
      timeout: const Duration(seconds: 60),
      what: 'the save reload that followed the restart',
      context: c.describe,
    );
    final log = h.logText;
    expect(
      log.indexOf('"command":"hotRestart"'),
      lessThan(log.indexOf('"reason":"save"')),
      reason: 'the restart request precedes the save reload',
    );
    await h.zedStop();
  });
}
