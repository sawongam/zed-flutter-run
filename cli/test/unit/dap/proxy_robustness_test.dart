import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_run/src/dap/hot_actions.dart';
import 'package:flutter_run/src/dap/launch_rewriter.dart';
import 'package:flutter_run/src/dap/proxy.dart';
import 'package:test/test.dart';

import 'proxy_support.dart';

void main() {
  group('robustness (code review)', () {
    test(
      'C1: a client whose flush never completes still shuts down and cleans up',
      () {
        fakeAsync((fa) {
          final h = Harness();
          h.client.hangFlush = true;
          h.request(1, 'launch', {});
          fa.flushMicrotasks();
          h.client.incoming.close();
          fa.flushMicrotasks();
          h.adapter.die(0);
          fa.elapse(const Duration(seconds: 15));
          expect(h.exitCode, 0);
          expect(h.order, contains('hook:cleanup'));
        });
      },
    );

    test('C1: a held terminate response is released although flush hangs', () {
      fakeAsync((fa) {
        final h = Harness();
        h.client.hangFlush = true;
        h.request(10, 'terminate');
        fa.flushMicrotasks();
        h.adapter.respond(h.adapter.lastRequest('terminate'));
        h.adapter.event('terminated');
        fa.elapse(const Duration(seconds: 2));
        fa.flushMicrotasks();
        expect(h.client.sentWhere('response', 'terminate'), hasLength(1));
        h.client.incoming.close();
        h.adapter.die(0);
        fa.elapse(const Duration(seconds: 15));
        expect(h.exitCode, 0);
      });
    });

    DapProxy build(
      FakeChannel client,
      FakeAdapter adapter, {
      String? Function()? saved,
      ProxyOptions options = const ProxyOptions(
        kind: DapKind.flutter,
        cwd: '/p',
      ),
      Future<void> Function()? started,
      Future<void> Function()? cleanup,
    }) => DapProxy(
      client: client,
      adapter: adapter,
      options: options,
      rewriter: LaunchRewriter(
        kind: DapKind.flutter,
        cwd: '/p',
        environment: const {},
        savedDevice: saved ?? () => null,
      ),
      onShutdownStarted: started,
      onShutdownCleanup: cleanup,
    );

    test(
      'C2: a throwing savedDevice answers launch with an error response',
      () {
        fakeAsync((fa) {
          final client = FakeChannel();
          final adapter = FakeAdapter();
          build(
            client,
            adapter,
            saved: () => throw const FormatException('corrupt device file'),
          ).run();
          client.incoming.add({
            'seq': 4,
            'type': 'request',
            'command': 'launch',
          });
          fa.flushMicrotasks();
          final response = client.sentWhere('response', 'launch').single;
          expect(response['success'], isFalse);
          expect(response['request_seq'], 4);
          expect(response['message'], contains('corrupt device file'));
          expect(client.outputs.single, contains('Error: '));
          expect(adapter.received, isEmpty);
          client.incoming.add({
            'seq': 5,
            'type': 'request',
            'command': 'threads',
          });
          fa.flushMicrotasks();
          expect(adapter.received.single['seq'], 5);
        });
      },
    );

    test('C2: throwing hooks do not stop terminate', () {
      fakeAsync((fa) {
        final client = FakeChannel();
        final adapter = FakeAdapter();
        build(
          client,
          adapter,
          started: () async => throw StateError('hook failed'),
          cleanup: () async => throw StateError('cleanup failed'),
        ).run();
        client.incoming.add({
          'seq': 10,
          'type': 'request',
          'command': 'terminate',
        });
        fa.flushMicrotasks();
        adapter.respond(adapter.lastRequest('terminate'));
        adapter.event('terminated');
        fa.elapse(const Duration(seconds: 2));
        fa.flushMicrotasks();
        expect(
          client.sentWhere('response', 'terminate').single['success'],
          isTrue,
        );
      });
    });

    test('C5: terminate is not forwarded after its own deadline fired', () {
      fakeAsync((fa) {
        final client = FakeChannel();
        final adapter = FakeAdapter();
        build(
          client,
          adapter,
          options: const ProxyOptions(
            kind: DapKind.flutter,
            cwd: '/p',
            terminateTimeout: Duration(seconds: 1),
          ),
          started: () => Completer<void>().future,
        ).run();
        client.incoming.add({
          'seq': 10,
          'type': 'request',
          'command': 'terminate',
        });
        fa.elapse(const Duration(seconds: 5));
        expect(client.sentWhere('response', 'terminate'), hasLength(1));
        expect(adapter.receivedRequest('terminate'), isFalse);
      });
    });

    test(
      'C6: a pending terminate does not block a later shutdown after a crash',
      () {
        fakeAsync((fa) {
          final h = Harness();
          h.request(10, 'terminate');
          fa.flushMicrotasks();
          h.adapter.die(9);
          fa.elapse(const Duration(seconds: 10));
          expect(h.exitCode, isNotNull);
          var done = false;
          h.proxy.shutdown().then((_) => done = true);
          fa.flushMicrotasks();
          expect(done, isTrue);
        });
      },
    );

    test('C7: a failing adapter exitCode future does not escape', () {
      fakeAsync((fa) {
        final h = Harness();
        h.adapter.exit.completeError(StateError('no exit code'));
        fa.elapse(const Duration(seconds: 10));
        expect(h.exitCode, isNotNull);
      });
    });

    test('C13: hot actions give inject a bounded timeout', () {
      fakeAsync((fa) {
        final h = Harness();
        h.adapter.event('flutter.appStarted');
        fa.flushMicrotasks();
        h.proxy.hotActions.reload();
        fa.flushMicrotasks();
        fa.elapse(const Duration(minutes: 11));
        expect(h.proxy.hotActions.busy, isFalse);
        h.adapter.respond(h.adapter.lastRequest('hotReload'));
        fa.flushMicrotasks();
        expect(h.client.sentWhere('response'), isEmpty);
      });
    });
  });

  group('process cleanup (phase 6)', () {
    test(
      'R2: after a crash only the last two polls are swept, flagged crashed',
      () {
        fakeAsync((fa) {
          final h = Harness();
          h.adapter.descendants = {41}; // detached long ago
          fa.elapse(const Duration(milliseconds: 500));
          h.adapter.descendants = {};
          fa.elapse(const Duration(seconds: 6));
          h.adapter.descendants = {42}; // reparented by the crash
          fa.elapse(const Duration(seconds: 2));
          h.adapter.die(-9);
          fa.elapse(const Duration(seconds: 3));
          expect(h.adapter.terminateTreeCalls, [
            {42},
          ]);
          expect(h.adapter.terminateTreeCrashed, [true]);
        });
      },
    );

    test('R9: hot actions are refused once shutdown starts', () {
      fakeAsync((fa) {
        final h = Harness();
        h.adapter.event('flutter.appStarted');
        h.request(10, 'terminate');
        fa.flushMicrotasks();
        HotResult? r;
        h.proxy.hotActions.reload(reason: 'save').then((v) => r = v);
        fa.flushMicrotasks();
        expect(r!.error, HotError.sessionEnded);
        expect(h.adapter.receivedRequest('hotReload'), isFalse);
      });
    });

    test(
      'R13: no crash report when the program ended and the adapter exited 0',
      () {
        fakeAsync((fa) {
          final h = Harness();
          h.adapter.event('terminated');
          fa.flushMicrotasks();
          h.adapter.die(0);
          fa.elapse(const Duration(seconds: 3));
          expect(h.exitCode, 0);
          expect(h.client.outputs, isEmpty);
          expect(h.client.sentWhere('event', 'terminated'), hasLength(1));
        });
      },
    );

    test('R15: a response without request_seq does not answer initialize', () {
      fakeAsync((fa) {
        final h = Harness(
          options: const ProxyOptions(
            kind: DapKind.flutter,
            cwd: '/proj',
            initializeTimeout: Duration(seconds: 5),
          ),
        );
        h.adapter.emit({'seq': 1, 'type': 'response', 'success': true});
        h.request(1, 'initialize', {});
        fa.flushMicrotasks();
        fa.elapse(const Duration(seconds: 6));
        expect(h.exitCode, 1);
      });
    });

    test('R14: EOF waits for earlier queued messages', () {
      fakeAsync((fa) {
        final h = Harness();
        h.request(1, 'launch', {});
        h.request(2, 'disconnect');
        h.client.incoming.close();
        fa.flushMicrotasks();
        // The disconnect was handled first, so shutdown follows its flow.
        expect(h.adapter.receivedRequest('terminate'), isTrue);
        h.adapter.respond(h.adapter.lastRequest('terminate'));
        fa.flushMicrotasks();
        expect(h.adapter.lastRequest('disconnect')['seq'], 2);
        h.adapter.die(0);
        fa.elapse(const Duration(seconds: 5));
        expect(h.exitCode, 0);
        expect(
          h.adapter.received.where(
            (m) =>
                m['command'] == 'disconnect' &&
                (m['seq']! as int) >= injectedBase,
          ),
          isEmpty,
        );
      });
    });

    test('R11: finished injected requests are not retained', () {
      fakeAsync((fa) {
        final h = Harness();
        for (var i = 0; i < 50; i++) {
          h.proxy.inject('hotReload');
          fa.flushMicrotasks();
          h.adapter.respond(h.adapter.lastRequest('hotReload'));
          fa.flushMicrotasks();
        }
        expect(h.client.sent, isEmpty);
        // Pending ones still fail cleanly when the session ends.
        Object? error;
        h.proxy
            .inject('hotReload')
            .then<void>(
              (_) {},
              onError: (Object e) {
                error = e;
              },
            );
        fa.flushMicrotasks();
        h.adapter.die(1);
        fa.elapse(const Duration(seconds: 3));
        expect(error, isA<StateError>());
      });
    });

    test('S5: an unsafe device id is not injected and a warning is shown', () {
      fakeAsync((fa) {
        final client = FakeChannel();
        final adapter = FakeAdapter();
        DapProxy(
          client: client,
          adapter: adapter,
          options: const ProxyOptions(kind: DapKind.flutter, cwd: '/p'),
          rewriter: LaunchRewriter(
            kind: DapKind.flutter,
            cwd: '/p',
            environment: const {},
            savedDevice: () => null,
            isSafeDeviceId: RegExp(r'^[A-Za-z0-9._:\-@]+$').hasMatch,
          ),
        ).run();
        client.incoming.add({
          'seq': 3,
          'type': 'request',
          'command': 'launch',
          'arguments': {'deviceId': 'x & calc'},
        });
        fa.flushMicrotasks();
        final args = adapter.received.single['arguments']! as Map;
        expect(args.containsKey('toolArgs'), isFalse);
        expect(client.outputs.single, contains('Warning: '));
        expect(client.outputs.single, contains('x & calc'));
      });
    });
  });
}
