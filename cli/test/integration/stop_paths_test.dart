import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/cli_runner.dart';
import 'support/process_checks.dart';
import 'support/proxy_harness.dart';
import 'support/scenarios.dart';
import 'support/temp_project.dart';
import 'support/wait.dart';

void main() {
  late TempWorkspace ws;
  late String exe;

  setUpAll(() async {
    exe = await exeOrFail();
    await preparedFixture('dart_console');
  });

  setUp(() {
    ws = TempWorkspace.create();
    addTearDown(ws.dispose);
  });

  /// The proxy must exit by itself within [timeout] and leave nothing behind.
  Future<void> expectCleanExit(
    ProxyHarness h,
    Duration timeout, {
    bool checkOrphans = true,
  }) async {
    final code = await within(
      h.exitCode,
      timeout,
      'the proxy to exit',
      context: h.describeProxy,
    );
    printOnFailure('proxy exit code: $code');
    expect(h.sessionFile.existsSync(), isFalse, reason: 'stale session file');
    if (!checkOrphans) return;
    await expectAllGone(
      h.knownTree,
      what: 'descendants after the proxy exited',
      context: h.describeProxy,
    );
  }

  /// Kills the adapter like a crash and checks what the client sees.
  Future<void> adapterCrash(
    ProxyHarness h, {
    required bool checkOrphans,
  }) async {
    final c = h.client;
    final adapter = await h.adapterPid();
    expect(
      adapter,
      isNotNull,
      reason: 'no adapter process\n${h.describeProxy()}',
    );
    await h.trackTree();
    final mark = c.eventMark;
    final outMark = c.outputMark;
    Process.killPid(adapter!, ProcessSignal.sigkill);
    await c.waitForEventNamed(
      'terminated',
      from: mark,
      timeout: const Duration(seconds: 30),
    );
    await c.waitForOutput(
      'Error: ',
      from: outMark,
      timeout: const Duration(seconds: 30),
    );
    expect(
      c.outputText(from: outMark),
      contains('debug adapter stopped unexpectedly'),
    );
    await expectCleanExit(
      h,
      const Duration(seconds: 20),
      checkOrphans: checkOrphans,
    );
  }

  group('Dart adapter', () {
    test(
      'adapter crash: Error notice, terminated, proxy exits, no session file',
      () async {
        final s = await startDartConsole(ws);
        await adapterCrash(s.harness, checkOrphans: false);
      },
    );

    test('adapter crash: the debuggee does not outlive the proxy', () async {
      final s = await startDartConsole(ws);
      await adapterCrash(s.harness, checkOrphans: true);
    });

    test('stdin EOF: the proxy cleans up and exits within 20 s', () async {
      final s = await startDartConsole(ws);
      await s.harness.trackTree();
      expect(s.harness.knownTree, isNotEmpty);
      await s.client.close();
      await expectCleanExit(s.harness, const Duration(seconds: 20));
    });

    test(
      'a killed proxy leaves a stale session file that status prunes',
      () async {
        final s = await startDartConsole(ws);
        final h = s.harness;
        await h.trackTree();
        expect(h.sessionFile.existsSync(), isTrue);
        h.process.kill(ProcessSignal.sigkill);
        await within(
          h.exitCode,
          const Duration(seconds: 10),
          'the killed proxy',
        );
        expect(
          h.sessionFile.existsSync(),
          isTrue,
          reason: 'nobody could clean up',
        );

        final status = await runCli(
          exe,
          ['status', '--json', '--project', s.app.path],
          stateDir: ws.stateDir,
          expectExit: 0,
        );
        expect((jsonDecode(status.stdout) as Map)['sessions'], isEmpty);
        expect(h.sessionFile.existsSync(), isFalse, reason: 'pruned by status');
        // The orphaned adapter and debuggee are cleaned up by the harness.
      },
    );
  }, tags: ['integration-dart']);

  group('Flutter adapter', () {
    test('adapter crash: processes the adapter started are swept', () async {
      await preparedFixture('sample_app');
      final s = await FlutterLaunch.start(
        ws,
        launchArgs: {'reloadOnSave': 'off'},
      );
      final tree = await s.harness.trackTree();
      final lines = (await commandLines(tree)).values.join('\n');
      printOnFailure('tree before crash:\n$lines');
      expect(lines, contains('flutter_tester'));
      await adapterCrash(s.harness, checkOrphans: true);
    });

    test('stdin EOF: the proxy stops the app and exits within 20 s', () async {
      await preparedFixture('sample_app');
      final s = await FlutterLaunch.start(
        ws,
        launchArgs: {'reloadOnSave': 'off'},
      );
      final tree = await s.harness.trackTree();
      expect(
        (await commandLines(tree)).values.join('\n'),
        contains('flutter_tester'),
      );
      await s.client.close();
      await expectCleanExit(s.harness, const Duration(seconds: 20));
    });
  }, tags: ['integration']);
}
