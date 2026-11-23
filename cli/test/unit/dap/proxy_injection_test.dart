import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_run/src/dap/hot_actions.dart';
import 'package:flutter_run/src/dap/messages.dart';
import 'package:test/test.dart';

import 'proxy_support.dart';

void main() {
  group('injected requests', () {
    test('seq >= 1e9, response swallowed, completes the future', () {
      fakeAsync((fa) {
        final h = Harness();
        DapJson? response;
        h.proxy
            .inject('hotReload', {'reason': 'manual'})
            .then((r) => response = r);
        fa.flushMicrotasks();
        final sent = h.adapter.received.single;
        expect(sent['seq'], injectedBase);
        expect(sent['command'], 'hotReload');
        h.adapter.respond(sent);
        fa.flushMicrotasks();
        expect(response!['success'], isTrue);
        expect(h.client.sent, isEmpty);
      });
    });

    test('a late response after a timeout is swallowed', () {
      fakeAsync((fa) {
        final h = Harness();
        Object? error;
        h.proxy
            .inject('hotReload', null, const Duration(seconds: 2))
            .then<void>(
              (_) {},
              onError: (Object e) {
                error = e;
              },
            );
        fa.flushMicrotasks();
        fa.elapse(const Duration(seconds: 3));
        expect(error, isA<TimeoutException>());
        h.adapter.respond(h.adapter.received.single);
        fa.flushMicrotasks();
        expect(h.client.sent, isEmpty);
      });
    });

    test('inject after the session ended throws StateError', () {
      fakeAsync((fa) {
        final h = Harness();
        h.adapter.die(0);
        fa.elapse(const Duration(seconds: 5));
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
        expect(error, isA<StateError>());
      });
    });

    test(
      'a pending injected request fails with StateError when the adapter dies',
      () {
        fakeAsync((fa) {
          final h = Harness();
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
      },
    );

    test('hotActions drives the proxy end to end', () {
      fakeAsync((fa) {
        final h = Harness();
        h.adapter.event('flutter.appStarted');
        fa.flushMicrotasks();
        HotResult? result;
        h.proxy.hotActions.reload().then((r) => result = r);
        fa.flushMicrotasks();
        h.adapter.respond(h.adapter.lastRequest('hotReload'));
        fa.flushMicrotasks();
        expect(result!.ok, isTrue);
      });
    });

    test('a client restart marks the restart flag until its response', () {
      fakeAsync((fa) {
        final h = Harness();
        h.adapter.event('flutter.appStarted');
        h.request(8, 'restart');
        fa.flushMicrotasks();
        expect(h.proxy.hotActions.busy, isTrue);
        HotResult? manual;
        h.proxy.hotActions.reload().then((r) => manual = r);
        fa.flushMicrotasks();
        // The reload waits for the client restart instead of failing.
        expect(manual, isNull);
        h.adapter.respond(h.adapter.lastRequest('restart'));
        fa.flushMicrotasks();
        expect(h.client.sentWhere('response', 'restart'), hasLength(1));
        h.adapter.respond(h.adapter.lastRequest('hotReload'));
        fa.flushMicrotasks();
        expect(manual!.ok, isTrue);
        expect(h.proxy.hotActions.busy, isFalse);
      });
    });
  });
}
