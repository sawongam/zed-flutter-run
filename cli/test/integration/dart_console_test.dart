@Tags(['integration-dart'])
library;

import 'dart:io';

import 'package:test/test.dart';

import 'support/fake_dap_client.dart';
import 'support/process_checks.dart';
import 'support/scenarios.dart';
import 'support/temp_project.dart';
import 'support/wait.dart';

void main() {
  late TempWorkspace ws;

  setUpAll(() async {
    await exeOrFail();
    await preparedFixture('dart_console');
  });

  setUp(() {
    ws = TempWorkspace.create();
    addTearDown(ws.dispose);
  });

  Future<List<Object?>> frames(FakeDapClient c, int threadId) async {
    final r = await c.call('stackTrace', {
      'threadId': threadId,
      'startFrame': 0,
      'levels': 10,
    });
    return (r['body']! as Map)['stackFrames']! as List<Object?>;
  }

  test(
    'breakpoint, variables, step, stepIn, evaluate, run to the end',
    () async {
      final s = await startDartConsole(ws);
      final c = s.client;

      final frame0 = (await frames(c, s.threadId)).first as Map;
      expect(frame0['line'], s.line);
      expect((frame0['source'] as Map)['path'], endsWith('main.dart'));
      expect(frame0['name'], contains('computeTotal'));

      // Variables: `total` and `n` are in scope at the breakpoint.
      final scopes = await c.call('scopes', {'frameId': frame0['id']});
      final scopeList = (scopes['body']! as Map)['scopes']! as List;
      final names = <String>{};
      for (final scope in scopeList) {
        final vars = await c.call('variables', {
          'variablesReference': (scope as Map)['variablesReference'],
        });
        for (final v in (vars['body']! as Map)['variables']! as List) {
          names.add((v as Map)['name'] as String);
        }
      }
      expect(names, containsAll(['total', 'n']));

      // next -> stopped(step) on the following line.
      var mark = c.eventMark;
      await c.call('next', {'threadId': s.threadId});
      await c.waitForStopped(
        from: mark,
        reason: 'step',
        timeout: const Duration(seconds: 60),
      );
      expect(((await frames(c, s.threadId)).first! as Map)['line'], s.line + 1);

      // stepIn -> inside square().
      mark = c.eventMark;
      await c.call('stepIn', {'threadId': s.threadId});
      await c.waitForStopped(
        from: mark,
        reason: 'step',
        timeout: const Duration(seconds: 60),
      );
      final inner = (await frames(c, s.threadId)).first as Map;
      expect(inner['name'], contains('square'));

      // evaluate in the frame of square(): n is 1 on the first iteration.
      final eval = await c.call('evaluate', {
        'expression': 'n * 2',
        'frameId': inner['id'],
        'context': 'watch',
      });
      expect((eval['body']! as Map)['result'], '2');

      // Remove the breakpoint and run to the end.
      await c.call('setBreakpoints', {
        'source': {'path': s.mainPath},
        'breakpoints': <Object>[],
      });
      await c.call('continue', {'threadId': s.threadId});
      await c.waitForOutput('TOTAL: 30');
      await c.waitForEventNamed('terminated');
      await s.harness.trackTree();

      // Zed sends disconnect after `terminated`; the proxy exits cleanly.
      await c.call('disconnect', {'terminateDebuggee': true});
      final code = await within(
        s.harness.exitCode,
        const Duration(seconds: 20),
        'the proxy to exit after disconnect',
        context: s.harness.describeProxy,
      );
      expect(code, 0, reason: s.harness.describeProxy());
      expect(s.harness.sessionFile.existsSync(), isFalse);
      await expectAllGone(
        s.harness.knownTree,
        what: 'processes of the session',
      );
    },
  );

  test('session file describes the Dart session', () async {
    final s = await startDartConsole(ws);
    final session = s.harness.ownSession()!;
    expect(session['kind'], 'dart');
    expect(session['request'], 'launch');
    expect(session['version'], 1);
    expect(File(s.mainPath).existsSync(), isTrue);
    await s.harness.zedStop();
  });

  test(
    "Zed's stop path: terminate, then the proxy is killed at once",
    () async {
      final s = await startDartConsole(ws);
      final tree = await s.harness.trackTree();
      expect(tree, isNotEmpty, reason: 'the adapter and debuggee are running');
      await s.harness.zedStop();
    },
  );

  test('disconnect only (no terminate) leaves nothing behind', () async {
    final s = await startDartConsole(ws);
    await s.harness.zedStop(command: 'disconnect');
  });
}
