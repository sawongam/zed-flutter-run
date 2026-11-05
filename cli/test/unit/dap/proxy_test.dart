import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_run/src/dap/framing.dart';
import 'package:flutter_run/src/dap/hot_actions.dart';
import 'package:flutter_run/src/dap/launch_rewriter.dart';
import 'package:flutter_run/src/dap/messages.dart';
import 'package:flutter_run/src/dap/notices.dart';
import 'package:flutter_run/src/dap/proxy.dart';
import 'package:flutter_run/src/dap/proxy_state.dart';
import 'package:test/test.dart';

import 'fakes.dart';

const int injectedBase = 1000000000;

class Harness {
  Harness({
    DapKind kind = DapKind.flutter,
    String? saved,
    ProxyOptions? options,
  }) {
    client = FakeChannel(onSend: (m) => order.add('client:${_label(m)}'));
    adapter = FakeAdapter(onSend: (m) => order.add('adapter:${_label(m)}'));
    proxy = DapProxy(
      client: client,
      adapter: adapter,
      options: options ?? ProxyOptions(kind: kind, cwd: '/proj'),
      rewriter: LaunchRewriter(
        kind: kind,
        cwd: '/proj',
        environment: const {},
        savedDevice: () => saved,
      ),
      onShutdownStarted: () async => order.add('hook:started'),
      onShutdownCleanup: () async => order.add('hook:cleanup'),
    );
    proxy.events.listen(events.add);
    proxy.run().then((c) => exitCode = c);
  }

  late final FakeChannel client;
  late final FakeAdapter adapter;
  late final DapProxy proxy;
  final List<String> order = [];
  final List<ProxyEvent> events = [];
  int? exitCode;

  static String _label(DapJson m) {
    final type = m['type'];
    if (type == 'event') return '${m['event']}';
    return '${m['command']}';
  }

  /// Sends [message] from the client side.
  void fromClient(DapJson message) => client.incoming.add(message);

  void request(int seq, String command, [Object? arguments]) => fromClient({
    'seq': seq,
    'type': 'request',
    'command': command,
    'arguments': ?arguments,
  });
}

void main() {
  group('pass-through', () {
    test(
      'client requests, adapter events and reverse requests are untouched',
      () {
        fakeAsync((fa) {
          final h = Harness();
          h.request(5, 'setBreakpoints', {'path': 'a'});
          fa.flushMicrotasks();
          expect(h.adapter.received.single, {
            'seq': 5,
            'type': 'request',
            'command': 'setBreakpoints',
            'arguments': {'path': 'a'},
          });

          final stopped = {
            'seq': 3,
            'type': 'event',
            'event': 'stopped',
            'body': {'reason': 'breakpoint'},
          };
          final reverse = {
            'seq': 4,
            'type': 'request',
            'command': 'runInTerminal',
            'arguments': {
              'args': ['x'],
            },
          };
          h.adapter.emit(stopped);
          h.adapter.emit(reverse);
          fa.flushMicrotasks();
          expect(h.client.sent, [stopped, reverse]);

          final reverseResponse = {
            'seq': 6,
            'type': 'response',
            'request_seq': 4,
            'success': true,
            'command': 'runInTerminal',
          };
          h.fromClient(reverseResponse);
          fa.flushMicrotasks();
          expect(h.adapter.received.last, reverseResponse);
        });
      },
    );

    test('responses and events keep the adapter seq', () {
      fakeAsync((fa) {
        final h = Harness();
        h.request(1, 'threads');
        fa.flushMicrotasks();
        final response = {
          'seq': 77,
          'type': 'response',
          'request_seq': 1,
          'success': true,
          'command': 'threads',
          'body': {'threads': <Object>[]},
        };
        h.adapter.emit(response);
        fa.flushMicrotasks();
        expect(h.client.sent.single, response);
      });
    });

    test(
      'client seq >= 1e9 logs and emits an Error notice but still forwards',
      () {
        fakeAsync((fa) {
          final h = Harness();
          h.request(injectedBase + 5, 'threads');
          fa.flushMicrotasks();
          expect(h.adapter.received.single['seq'], injectedBase + 5);
          expect(h.client.outputs.single, contains('Error: '));
        });
      },
    );
  });

  group('launch and attach rewrite', () {
    test('launch arguments are rewritten and announced', () {
      fakeAsync((fa) {
        final h = Harness(saved: 'dev-1');
        h.request(2, 'launch', {
          'program': 'lib/a.dart',
          'reloadOnSave': 'always',
          'label': 'x',
          'flutterMode': 'profile',
        });
        fa.flushMicrotasks();
        final sent = h.adapter.received.single;
        expect(sent['seq'], 2);
        expect(sent['arguments'], {
          'program': 'lib/a.dart',
          'toolArgs': ['--profile', '-d', 'dev-1'],
          'cwd': '/proj',
        });
        final rewritten = h.events.whereType<LaunchRewritten>().single;
        expect(rewritten.request, 'launch');
        expect(rewritten.result.ownConfig['reloadOnSave'], 'always');
        expect(h.proxy.state.request, 'launch');
        expect(h.proxy.state.deviceId, 'dev-1');
      });
    });

    test('attach is rewritten with the same device precedence', () {
      fakeAsync((fa) {
        final h = Harness(saved: 'dev-1');
        h.request(2, 'attach', {'vmServiceUri': 'http://127.0.0.1:1/a=/'});
        fa.flushMicrotasks();
        final args = h.adapter.received.single['arguments']! as Map;
        expect(args['toolArgs'], ['-d', 'dev-1']);
        expect(args['vmServiceUri'], 'http://127.0.0.1:1/a=/');
        expect(h.proxy.state.request, 'attach');
      });
    });

    test('launch without arguments still gets defaults', () {
      fakeAsync((fa) {
        final h = Harness();
        h.request(2, 'launch');
        fa.flushMicrotasks();
        expect(h.adapter.received.single['arguments'], {
          'cwd': '/proj',
          'program': 'lib/main.dart',
        });
      });
    });
  });

  group('state capture', () {
    test('events are forwarded and observed', () {
      fakeAsync((fa) {
        final h = Harness();
        h.adapter.event('dart.debuggerUris', {
          'vmServiceUri': 'ws://h:1/t=/ws',
        });
        fa.flushMicrotasks();
        expect(h.proxy.state.vmServiceUri, 'ws://h:1/t=/ws');
        h.adapter.event('dart.debuggerUris', {
          'vmServiceUri': 'ws://h:1/t=/ws',
        });
        h.adapter.event('flutter.appStart', {
          'appId': 'app1',
          'deviceId': 'linux',
          'mode': 'debug',
        });
        fa.flushMicrotasks();
        expect(h.proxy.state.appId, 'app1');
        expect(h.proxy.state.deviceId, 'linux');
        expect(h.proxy.state.mode, 'debug');
        expect(h.proxy.state.appStarted, isFalse);
        h.adapter.event('flutter.appStarted');
        fa.flushMicrotasks();
        expect(h.proxy.state.appStarted, isTrue);
        expect(h.proxy.appStarted, isTrue);
        h.adapter.event('terminated');
        fa.flushMicrotasks();
        expect(h.proxy.state.ended, isTrue);

        final uris = h.events.whereType<DebuggerUris>().toList();
        expect(uris.map((e) => e.isFirst), [true, false]);
        expect(h.events.whereType<AppStarted>(), hasLength(1));
        expect(h.events.whereType<SessionEnded>(), hasLength(1));
        expect(h.events.whereType<StateChanged>(), isNotEmpty);
        // All five events reached the client unchanged.
        expect(h.client.sentWhere('event').map((m) => m['event']), [
          'dart.debuggerUris',
          'dart.debuggerUris',
          'flutter.appStart',
          'flutter.appStarted',
          'terminated',
        ]);
      });
    });
  });

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
        expect(manual!.error, HotError.busy);
        h.adapter.respond(h.adapter.lastRequest('restart'));
        fa.flushMicrotasks();
        expect(h.proxy.hotActions.busy, isFalse);
        expect(h.client.sentWhere('response', 'restart'), hasLength(1));
      });
    });
  });

  group('notices', () {
    test('are well formed output events with a body', () {
      fakeAsync((fa) {
        final h = Harness();
        h.proxy.notice('Hello');
        h.proxy.notice('Careful', NoticeLevel.warn);
        fa.flushMicrotasks();
        final first = h.client.sent[0];
        expect(first['type'], 'event');
        expect(first['event'], 'output');
        expect(first['seq'], injectedBase);
        expect(first['body'], {
          'category': 'console',
          'output': '\x1b[36m[flutter_run] Hello\x1b[0m\n',
        });
        expect(h.client.sent[1]['seq'], injectedBase + 1);
        expect(h.client.outputs[1], contains('Warning: Careful'));
        for (final text in h.client.outputs) {
          expect(text, endsWith('\x1b[0m\n'));
          expect(text.endsWith('\n\n'), isFalse);
        }
      });
    });

    test('a device hint appears once for adapter output', () {
      fakeAsync((fa) {
        final h = Harness();
        h.adapter.event('output', {
          'category': 'stderr',
          'output': 'More than one device connected; please specify...\n',
        });
        h.adapter.event('output', {
          'category': 'stderr',
          'output': 'More than one device connected; again\n',
        });
        fa.flushMicrotasks();
        // Two forwarded adapter outputs plus exactly one hint.
        expect(h.client.outputs, hasLength(3));
        expect(h.client.outputs[1], contains('Flutter: Select Device'));
      });
    });

    test('a failed launch response gets a device hint', () {
      fakeAsync((fa) {
        final h = Harness();
        h.request(3, 'launch', {});
        fa.flushMicrotasks();
        h.adapter.respond(
          h.adapter.lastRequest('launch'),
          success: false,
          message: 'No supported devices connected.',
        );
        fa.flushMicrotasks();
        expect(h.client.sentWhere('response', 'launch'), hasLength(1));
        expect(h.client.outputs.single, contains('No devices found.'));
      });
    });
  });

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
      h.request(1, request, {});
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
        h.request(1, 'attach', {});
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
    test(
      'R4: a slow start gets one notice at 10 s and fails only at 120 s',
      () {
        fakeAsync((fa) {
          final h = Harness();
          h.request(1, 'initialize', {});
          fa.flushMicrotasks();
          fa.elapse(const Duration(seconds: 9));
          expect(h.client.sent, isEmpty);
          fa.elapse(const Duration(seconds: 2));
          expect(
            h.client.outputs.single,
            contains('Flutter is still starting'),
          );
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
      },
    );

    test('no response in 10 s fails the request, notifies and exits 1', () {
      fakeAsync((fa) {
        final h = Harness(
          options: const ProxyOptions(
            kind: DapKind.flutter,
            cwd: '/proj',
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

  group('framing errors', () {
    test('a client framing error notifies and shuts down', () {
      fakeAsync((fa) {
        final h = Harness();
        h.client.incoming.addError(DapFramingException('bad'));
        fa.flushMicrotasks();
        expect(h.client.outputs.single, contains('Error: '));
        h.adapter.die(0);
        fa.elapse(const Duration(seconds: 10));
        expect(h.exitCode, 1);
      });
    });
  });

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
