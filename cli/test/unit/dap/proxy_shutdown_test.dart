import 'package:fake_async/fake_async.dart';
import 'package:flutter_run/src/dap/launch_rewriter.dart';
import 'package:flutter_run/src/dap/proxy.dart';
import 'package:test/test.dart';

import 'proxy_support.dart';

void main() {
  group('terminate path', () {
    Harness started(
      FakeAsync fa, {
      ProxyOptions? options,
      DapKind kind = DapKind.flutter,
    }) {
      final h = Harness(options: options, kind: kind);
      h.request(1, 'initialize', {});
      h.request(2, 'launch', {});
      fa.flushMicrotasks();
      h.adapter.respond(h.adapter.lastRequest('initialize'));
      h.adapter.respond(h.adapter.lastRequest('launch'));
      h.adapter.event('flutter.appStarted');
      fa.flushMicrotasks();
      h.order.clear();
      return h;
    }

    test(
      'forwards terminate after onShutdownStarted, holds the response until terminated, cleans up first',
      () {
        fakeAsync((fa) {
          final h = started(fa);
          h.request(10, 'terminate');
          fa.flushMicrotasks();
          expect(h.order, ['hook:started', 'adapter:terminate']);
          expect(h.adapter.received.last['seq'], 10);
          expect(h.adapter.snapshotCalls, 1);

          h.adapter.respond(h.adapter.lastRequest('terminate'));
          fa.elapse(const Duration(seconds: 2));
          expect(h.client.sentWhere('response', 'terminate'), isEmpty);

          h.adapter.event('terminated');
          fa.elapse(const Duration(seconds: 1));
          fa.flushMicrotasks();
          expect(h.order, [
            'hook:started',
            'adapter:terminate',
            'client:output', // "Stopping the app..." after 1 s
            'client:terminated',
            'hook:cleanup',
            'client:terminate',
          ]);
          final response = h.client.sentWhere('response', 'terminate').single;
          expect(response['request_seq'], 10);
          expect(response['success'], isTrue);
          expect(h.exitCode, isNull);
        });
      },
    );

    test(
      'the response is relayed after 5 s even if terminated never comes',
      () {
        fakeAsync((fa) {
          final h = started(fa);
          h.request(10, 'terminate');
          fa.flushMicrotasks();
          h.adapter.respond(h.adapter.lastRequest('terminate'));
          fa.elapse(const Duration(milliseconds: 4900));
          expect(h.client.sentWhere('response', 'terminate'), isEmpty);
          fa.elapse(const Duration(milliseconds: 200));
          expect(h.client.sentWhere('response', 'terminate'), hasLength(1));
          expect(
            h.order.indexOf('hook:cleanup'),
            lessThan(h.order.indexOf('client:terminate')),
          );
        });
      },
    );

    test('a synthesized success is sent when the adapter never answers', () {
      fakeAsync((fa) {
        final h = started(fa);
        h.request(10, 'terminate');
        fa.elapse(const Duration(seconds: 6));
        final response = h.client.sentWhere('response', 'terminate').single;
        expect(response['success'], isTrue);
        expect(response['request_seq'], 10);
        // A late response from the adapter must not produce a duplicate.
        h.adapter.respond(h.adapter.lastRequest('terminate'));
        fa.flushMicrotasks();
        expect(h.client.sentWhere('response', 'terminate'), hasLength(1));
      });
    });

    test(
      'a synthesized success is sent when the adapter dies without answering',
      () {
        fakeAsync((fa) {
          final h = started(fa);
          h.request(10, 'terminate');
          fa.flushMicrotasks();
          h.adapter.die(0);
          fa.elapse(const Duration(seconds: 3));
          final response = h.client.sentWhere('response', 'terminate').single;
          expect(response['success'], isTrue);
          expect(h.exitCode, 0);
          // An orderly stop is not reported as a crash.
          expect(
            h.client.outputs.where((t) => t.contains('unexpectedly')),
            isEmpty,
          );
        });
      },
    );

    test('Stopping the app... appears after 1 s and not before', () {
      fakeAsync((fa) {
        final h = started(fa);
        h.request(10, 'terminate');
        fa.flushMicrotasks();
        fa.elapse(const Duration(milliseconds: 900));
        expect(h.client.outputs, isEmpty);
        fa.elapse(const Duration(milliseconds: 200));
        expect(h.client.outputs.single, contains('Stopping the app...'));
      });
    });

    test('no Stopping notice when terminate finishes quickly', () {
      fakeAsync((fa) {
        final h = started(fa);
        h.request(10, 'terminate');
        fa.flushMicrotasks();
        h.adapter.respond(h.adapter.lastRequest('terminate'));
        h.adapter.event('terminated');
        fa.flushMicrotasks();
        fa.elapse(const Duration(seconds: 3));
        expect(h.client.outputs, isEmpty);
      });
    });

    test(
      'terminateTree runs over surviving descendants before the response',
      () {
        fakeAsync((fa) {
          final h = started(fa);
          h.adapter.descendants = {11, 12};
          h.request(10, 'terminate');
          fa.flushMicrotasks();
          h.adapter.respond(h.adapter.lastRequest('terminate'));
          h.adapter.event('terminated');
          fa.flushMicrotasks();
          expect(h.adapter.terminateTreeCalls, isEmpty);
          fa.elapse(const Duration(seconds: 2));
          expect(h.adapter.terminateTreeCalls, [
            {11, 12},
          ]);
          expect(h.client.sentWhere('response', 'terminate'), hasLength(1));
        });
      },
    );

    test(
      'R1: an adapter that exits by itself after terminate is not killed',
      () {
        fakeAsync((fa) {
          final h = started(fa);
          h.request(10, 'terminate');
          fa.flushMicrotasks();
          h.adapter.respond(h.adapter.lastRequest('terminate'));
          h.adapter.event('terminated');
          fa.elapse(const Duration(milliseconds: 200));
          h.adapter.die(0);
          fa.elapse(const Duration(seconds: 3));
          expect(h.adapter.terminateTreeCalls, isEmpty);
          expect(h.client.sentWhere('response', 'terminate'), hasLength(1));
        });
      },
    );

    test(
      'R1: a still-alive adapter with no descendants is killed before the response',
      () {
        fakeAsync((fa) {
          final h = started(fa);
          h.request(10, 'terminate');
          fa.flushMicrotasks();
          h.adapter.respond(h.adapter.lastRequest('terminate'));
          h.adapter.event('terminated');
          fa.elapse(const Duration(seconds: 2));
          expect(h.adapter.terminateTreeCalls, [<int>{}]);
          expect(h.adapter.terminateTreeCrashed, [false]);
          expect(h.client.sentWhere('response', 'terminate'), hasLength(1));
          expect(
            h.order.indexOf('hook:cleanup'),
            lessThan(h.order.indexOf('client:terminate')),
          );
        });
      },
    );

    test('R2: a normal stop signals only current descendants, not history', () {
      fakeAsync((fa) {
        final h = started(fa);
        h.adapter.descendants = {31, 32}; // seen by polls
        fa.elapse(const Duration(seconds: 5));
        h.adapter.descendants = {32}; // 31 detached (a daemon) long ago
        h.request(10, 'terminate');
        fa.flushMicrotasks();
        h.adapter.respond(h.adapter.lastRequest('terminate'));
        h.adapter.event('terminated');
        fa.elapse(const Duration(seconds: 3));
        expect(h.adapter.terminateTreeCalls, [
          {32},
        ]);
        expect(h.adapter.terminateTreeCrashed, [false]);
      });
    });
  });

  group('disconnect', () {
    Harness launched(FakeAsync fa, String request, {ProxyOptions? options}) {
      final h = Harness(options: options);
      h.request(1, request, request == 'attach' ? attachArgs : {});
      fa.flushMicrotasks();
      h.adapter.event('flutter.appStarted');
      fa.flushMicrotasks();
      h.order.clear();
      return h;
    }

    test(
      'launch: injects terminate, waits for its response, then forwards disconnect',
      () {
        fakeAsync((fa) {
          final h = launched(fa, 'launch');
          h.request(20, 'disconnect');
          fa.flushMicrotasks();
          expect(h.order, ['hook:started', 'adapter:terminate']);
          final injectedTerminate = h.adapter.lastRequest('terminate');
          expect(injectedTerminate['seq'], greaterThanOrEqualTo(injectedBase));
          expect(h.adapter.receivedRequest('disconnect'), isFalse);

          h.adapter.respond(injectedTerminate);
          fa.flushMicrotasks();
          expect(h.adapter.lastRequest('disconnect')['seq'], 20);

          h.adapter.respond(h.adapter.lastRequest('disconnect'));
          fa.flushMicrotasks();
          expect(h.client.sentWhere('response', 'disconnect'), isEmpty);
          h.adapter.die(0);
          fa.elapse(const Duration(seconds: 3));
          expect(h.client.sentWhere('response'), hasLength(1));
          expect(
            h.client.sentWhere('response', 'disconnect').single['request_seq'],
            20,
          );
          // The injected terminate response was swallowed.
          expect(h.client.sentWhere('response', 'terminate'), isEmpty);
          expect(
            h.order.indexOf('hook:cleanup'),
            lessThan(h.order.indexOf('client:disconnect')),
          );
          expect(h.exitCode, 0);
        });
      },
    );

    test('launch: a terminated event also releases the wait', () {
      fakeAsync((fa) {
        final h = launched(fa, 'launch');
        h.request(20, 'disconnect');
        fa.flushMicrotasks();
        h.adapter.event('terminated');
        fa.flushMicrotasks();
        expect(h.adapter.receivedRequest('disconnect'), isTrue);
      });
    });

    test('launch: disconnect is forwarded after 5 s without any answer', () {
      fakeAsync((fa) {
        final h = launched(fa, 'launch');
        h.request(20, 'disconnect');
        fa.elapse(const Duration(seconds: 4));
        expect(h.adapter.receivedRequest('disconnect'), isFalse);
        fa.elapse(const Duration(seconds: 2));
        expect(h.adapter.receivedRequest('disconnect'), isTrue);
      });
    });

    test('attach: disconnect is forwarded straight away without terminate', () {
      fakeAsync((fa) {
        final h = launched(fa, 'attach');
        h.request(20, 'disconnect');
        fa.flushMicrotasks();
        expect(h.adapter.receivedRequest('terminate'), isFalse);
        expect(h.adapter.lastRequest('disconnect')['seq'], 20);
      });
    });

    test('after a client terminate no terminate is injected', () {
      fakeAsync((fa) {
        final h = launched(fa, 'launch');
        h.request(10, 'terminate');
        fa.flushMicrotasks();
        h.adapter.respond(h.adapter.lastRequest('terminate'));
        h.adapter.event('terminated');
        fa.elapse(const Duration(seconds: 2));
        fa.flushMicrotasks();
        h.request(11, 'disconnect');
        fa.flushMicrotasks();
        final terminates = h.adapter.received.where(
          (m) => m['command'] == 'terminate',
        );
        expect(terminates, hasLength(1));
        expect(terminates.single['seq'], 10);
        expect(h.adapter.lastRequest('disconnect')['seq'], 11);
      });
    });

    test('no terminate is injected when the app already ended', () {
      fakeAsync((fa) {
        final h = launched(fa, 'launch');
        h.adapter.event('terminated');
        fa.flushMicrotasks();
        h.request(20, 'disconnect');
        fa.flushMicrotasks();
        expect(h.adapter.receivedRequest('terminate'), isFalse);
        expect(h.adapter.receivedRequest('disconnect'), isTrue);
      });
    });

    test(
      'the disconnect response is synthesized when the adapter exits first',
      () {
        fakeAsync((fa) {
          final h = launched(fa, 'attach');
          h.request(20, 'disconnect');
          fa.flushMicrotasks();
          h.adapter.die(0);
          fa.elapse(const Duration(seconds: 3));
          final response = h.client.sentWhere('response', 'disconnect').single;
          expect(response['success'], isTrue);
          expect(h.exitCode, 0);
        });
      },
    );

    test(
      'C8: an answered disconnect is released after a short grace even if the adapter lingers',
      () {
        fakeAsync((fa) {
          final h = launched(fa, 'attach');
          h.request(20, 'disconnect');
          fa.flushMicrotasks();
          h.adapter.respond(h.adapter.lastRequest('disconnect'));
          fa.elapse(const Duration(milliseconds: 400));
          expect(h.client.sentWhere('response', 'disconnect'), isEmpty);
          fa.elapse(const Duration(seconds: 2));
          expect(h.client.sentWhere('response', 'disconnect'), hasLength(1));
          expect(h.adapter.terminateTreeCalls, isNotEmpty);
          expect(h.exitCode, 0);
        });
      },
    );
  });

  group('EOF and shutdown', () {
    test('client EOF: same cleanup as terminate, then exit', () {
      fakeAsync((fa) {
        final h = Harness();
        h.request(1, 'launch', {});
        fa.flushMicrotasks();
        h.adapter.event('flutter.appStarted');
        fa.flushMicrotasks();
        h.order.clear();
        h.client.incoming.close();
        fa.flushMicrotasks();
        expect(h.order.take(2), ['hook:started', 'adapter:terminate']);
        final injected = h.adapter.lastRequest('terminate');
        expect(injected['seq'], greaterThanOrEqualTo(injectedBase));
        h.adapter.respond(injected);
        fa.flushMicrotasks();
        expect(h.adapter.receivedRequest('disconnect'), isTrue);
        h.adapter.die(0);
        fa.elapse(const Duration(seconds: 3));
        expect(h.exitCode, 0);
        expect(h.order, contains('hook:cleanup'));
        expect(h.client.flushCount, greaterThan(0));
      });
    });

    test(
      'EOF with an unresponsive adapter ends within the bounds and kills it',
      () {
        fakeAsync((fa) {
          final h = Harness();
          h.request(1, 'launch', {});
          fa.flushMicrotasks();
          h.client.incoming.close();
          fa.elapse(const Duration(seconds: 20));
          expect(h.exitCode, 0);
          expect(h.adapter.terminateTreeCalls, isNotEmpty);
        });
      },
    );

    test('EOF after a client terminate does not inject another terminate', () {
      fakeAsync((fa) {
        final h = Harness();
        h.request(1, 'launch', {});
        fa.flushMicrotasks();
        h.request(10, 'terminate');
        fa.flushMicrotasks();
        h.adapter.respond(h.adapter.lastRequest('terminate'));
        h.adapter.event('terminated');
        fa.flushMicrotasks();
        h.client.incoming.close();
        fa.flushMicrotasks();
        expect(
          h.adapter.received.where((m) => m['command'] == 'terminate'),
          hasLength(1),
        );
        h.adapter.die(0);
        fa.elapse(const Duration(seconds: 3));
        expect(h.exitCode, 0);
      });
    });

    test('shutdown is idempotent', () {
      fakeAsync((fa) {
        final h = Harness();
        final a = h.proxy.shutdown(reason: 'a');
        final b = h.proxy.shutdown(reason: 'b');
        expect(identical(a, b), isTrue);
        fa.flushMicrotasks();
        h.adapter.die(0);
        fa.elapse(const Duration(seconds: 10));
        expect(h.exitCode, 0);
        expect(h.order.where((e) => e == 'hook:started'), hasLength(1));
        expect(h.order.where((e) => e == 'hook:cleanup'), hasLength(1));
        var again = false;
        h.proxy.shutdown().then((_) => again = true);
        fa.flushMicrotasks();
        expect(again, isTrue);
      });
    });

    test('attach EOF does not inject terminate but does inject disconnect', () {
      fakeAsync((fa) {
        final h = Harness();
        h.request(1, 'attach', attachArgs);
        fa.flushMicrotasks();
        h.client.incoming.close();
        fa.flushMicrotasks();
        expect(h.adapter.receivedRequest('terminate'), isFalse);
        expect(h.adapter.receivedRequest('disconnect'), isTrue);
        h.adapter.die(0);
        fa.elapse(const Duration(seconds: 3));
        expect(h.exitCode, 0);
      });
    });
  });
}
