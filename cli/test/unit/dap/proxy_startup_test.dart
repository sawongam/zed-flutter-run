import 'package:fake_async/fake_async.dart';
import 'package:flutter_run/src/dap/hot_actions.dart';
import 'package:flutter_run/src/dap/launch_rewriter.dart';
import 'package:flutter_run/src/dap/proxy.dart';
import 'package:flutter_run/src/dap/proxy_state.dart';
import 'package:test/test.dart';

import 'proxy_support.dart';

void main() {
  group('adapter crash', () {
    test('stderr tail, error notice, terminated event, flush, exit code', () {
      fakeAsync((fa) {
        final h = Harness();
        h.request(1, 'initialize', {});
        h.request(2, 'launch', {});
        fa.flushMicrotasks();
        h.adapter.respond(h.adapter.lastRequest('initialize'));
        for (var i = 0; i < 25; i++) {
          h.adapter.stderrController.add('line $i');
        }
        fa.flushMicrotasks();
        h.order.clear();
        h.adapter.die(137);
        fa.elapse(const Duration(seconds: 3));
        expect(h.exitCode, 137);
        final outputs = h.client.sentWhere('event', 'output').toList();
        final stderrEvent = outputs.firstWhere(
          (m) => (m['body']! as Map)['category'] == 'stderr',
        );
        final text = (stderrEvent['body']! as Map)['output']! as String;
        expect(text.split('\n').where((l) => l.isNotEmpty), hasLength(20));
        expect(text, contains('line 24'));
        expect(text, isNot(contains('line 4\n')));
        expect(
          h.client.outputs.last,
          contains('Error: The Flutter debug adapter stopped unexpectedly'),
        );
        final terminated = h.client.sentWhere('event', 'terminated').single;
        expect(terminated['body'], isA<Map<String, Object?>>());
        expect(
          h.order.indexOf('client:terminated'),
          greaterThan(h.order.lastIndexWhere((e) => e == 'client:output')),
        );
        expect(h.client.flushCount, greaterThan(0));
        expect(h.order, contains('hook:cleanup'));
        expect(h.proxy.state.ended, isTrue);
      });
    });

    test('output the adapter wrote before dying is still forwarded', () {
      fakeAsync((fa) {
        final h = Harness();
        h.adapter.event('output', {'category': 'stdout', 'output': 'bye\n'});
        h.adapter.die(1);
        fa.elapse(const Duration(seconds: 3));
        expect(h.client.sentWhere('event', 'output').first['body'], {
          'category': 'stdout',
          'output': 'bye\n',
        });
      });
    });

    test(
      'an adapter that dies before initialize fails the initialize request',
      () {
        fakeAsync((fa) {
          final h = Harness();
          h.request(1, 'initialize', {});
          fa.flushMicrotasks();
          h.adapter.stderrController.add('Unable to find flutter');
          fa.flushMicrotasks();
          h.adapter.die(1);
          fa.elapse(const Duration(seconds: 3));
          final response = h.client.sentWhere('response', 'initialize').single;
          expect(response['success'], isFalse);
          expect(response['message'], 'Unable to find flutter');
          expect(h.exitCode, 1);
        });
      },
    );
  });

  group('initialize timeout', () {
    test('a slow start gets one notice at 10 s and fails only at 120 s', () {
      fakeAsync((fa) {
        final h = Harness();
        h.request(1, 'initialize', {});
        fa.flushMicrotasks();
        fa.elapse(const Duration(seconds: 9));
        expect(h.client.sent, isEmpty);
        fa.elapse(const Duration(seconds: 2));
        expect(h.client.outputs.single, contains('Flutter is still starting'));
        fa.elapse(const Duration(seconds: 100));
        expect(h.client.outputs, hasLength(1));
        expect(h.exitCode, isNull);
        fa.elapse(const Duration(seconds: 15));
        expect(
          h.client.sentWhere('response', 'initialize').single['success'],
          isFalse,
        );
        expect(h.exitCode, 1);
      });
    });

    test('no response in 10 s fails the request, notifies and exits 1', () {
      fakeAsync((fa) {
        final h = Harness(
          options: const ProxyOptions(
            kind: DapKind.flutter,
            initializeTimeout: Duration(seconds: 10),
            initializeNoticeAfter: Duration(seconds: 20),
          ),
        );
        h.request(1, 'initialize', {});
        fa.flushMicrotasks();
        h.adapter.stderrController.add('slow start');
        fa.elapse(const Duration(seconds: 9));
        expect(h.client.sent, isEmpty);
        fa.elapse(const Duration(seconds: 2));
        final response = h.client.sentWhere('response', 'initialize').single;
        expect(response['success'], isFalse);
        expect(response['request_seq'], 1);
        expect(response['message'], contains('10 seconds'));
        expect(response['message'], contains('slow start'));
        final output = h.client.sentWhere('event', 'output').single;
        expect((output['body']! as Map)['category'], 'stderr');
        expect(h.exitCode, 1);
        expect(h.order, contains('hook:cleanup'));
      });
    });

    test('an initialize response cancels the watchdog', () {
      fakeAsync((fa) {
        final h = Harness();
        h.request(1, 'initialize', {});
        fa.flushMicrotasks();
        h.adapter.respond(h.adapter.lastRequest('initialize'));
        fa.elapse(const Duration(seconds: 30));
        expect(h.exitCode, isNull);
        expect(
          h.client.sentWhere('response', 'initialize').single['success'],
          isTrue,
        );
      });
    });
  });

  group('early snapshots and dart kind', () {
    test('a crash sweeps descendants captured while the adapter ran', () {
      fakeAsync((fa) {
        final h = Harness();
        h.adapter.descendants = {11, 12};
        h.adapter.event('flutter.appStart', {'appId': 'a'});
        fa.flushMicrotasks();
        // After SIGKILL the children are reparented and no longer found.
        h.adapter.descendants = {};
        h.adapter.die(-9);
        fa.elapse(const Duration(seconds: 5));
        expect(h.exitCode, -9);
        expect(h.adapter.terminateTreeCalls, [
          {11, 12},
        ]);
      });
    });

    test('snapshots are refreshed periodically and stop at shutdown', () {
      fakeAsync((fa) {
        final h = Harness();
        h.adapter.descendants = {21};
        fa.elapse(const Duration(milliseconds: 500));
        expect(h.adapter.snapshotCalls, 1);
        fa.elapse(const Duration(seconds: 6));
        expect(h.adapter.snapshotCalls, greaterThanOrEqualTo(3));
        h.adapter.die(-9);
        fa.elapse(const Duration(seconds: 3));
        final calls = h.adapter.snapshotCalls;
        fa.elapse(const Duration(seconds: 10));
        expect(h.adapter.snapshotCalls, calls);
        expect(h.adapter.terminateTreeCalls, [
          {21},
        ]);
      });
    });

    test('dart.debuggerUris and thread events trigger a snapshot', () {
      fakeAsync((fa) {
        final h = Harness();
        h.adapter.event('dart.debuggerUris', {'vmServiceUri': 'ws://x'});
        fa.flushMicrotasks();
        expect(h.adapter.snapshotCalls, 1);
        h.adapter.event('thread', {'reason': 'started'});
        fa.flushMicrotasks();
        expect(h.adapter.snapshotCalls, 2);
      });
    });

    test('kind dart: the first debuggerUris means the app started', () {
      fakeAsync((fa) {
        final h = Harness(kind: DapKind.dart);
        expect(h.proxy.appStarted, isFalse);
        h.adapter.event('dart.debuggerUris', {'vmServiceUri': 'ws://x'});
        fa.flushMicrotasks();
        expect(h.proxy.state.appStarted, isTrue);
        expect(h.events.whereType<AppStarted>(), hasLength(1));
        expect(h.proxy.state.vmServiceUri, 'ws://x');
        h.adapter.event('dart.debuggerUris', {'vmServiceUri': 'ws://y'});
        fa.flushMicrotasks();
        expect(h.events.whereType<AppStarted>(), hasLength(1));
        HotResult? r;
        h.proxy.hotActions.reload().then((v) => r = v);
        fa.flushMicrotasks();
        h.adapter.respond(h.adapter.lastRequest('hotReload'));
        fa.flushMicrotasks();
        expect(r!.ok, isTrue);
      });
    });

    test('kind flutter: debuggerUris alone does not start the app', () {
      fakeAsync((fa) {
        final h = Harness();
        h.adapter.event('dart.debuggerUris', {'vmServiceUri': 'ws://x'});
        fa.flushMicrotasks();
        expect(h.proxy.state.appStarted, isFalse);
      });
    });

    test('kind dart: restart is refused with a friendly error', () {
      fakeAsync((fa) {
        final h = Harness(kind: DapKind.dart);
        h.adapter.event('dart.debuggerUris', {'vmServiceUri': 'ws://x'});
        h.request(9, 'restart');
        fa.flushMicrotasks();
        expect(h.adapter.receivedRequest('restart'), isFalse);
        final response = h.client.sentWhere('response', 'restart').single;
        expect(response['success'], isFalse);
        expect(response['request_seq'], 9);
        expect(
          response['message'],
          'Hot restart is only available for Flutter apps. Stop and start '
          'the program instead.',
        );
        expect(h.proxy.hotActions.busy, isFalse);

        HotResult? r;
        h.proxy.hotActions.restart().then((v) => r = v);
        fa.flushMicrotasks();
        expect(h.adapter.receivedRequest('hotRestart'), isFalse);
        expect(r!.error, HotError.adapterError);
        expect(r!.message, contains('only available for Flutter apps'));
      });
    });
  });
}
