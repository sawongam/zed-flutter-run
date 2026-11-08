import 'package:fake_async/fake_async.dart';
import 'package:flutter_run/src/dap/framing.dart';
import 'package:flutter_run/src/dap/launch_rewriter.dart';
import 'package:flutter_run/src/dap/notices.dart';
import 'package:flutter_run/src/dap/proxy.dart';
import 'package:flutter_run/src/dap/proxy_state.dart';
import 'package:flutter_run/src/dap/session_phase.dart';
import 'package:test/test.dart';

import 'proxy_support.dart';

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

  group('attach validation', () {
    test(
      'a placeholder address is refused with a clear error, not forwarded',
      () {
        fakeAsync((fa) {
          final h = Harness();
          h.request(4, 'attach', {
            'vmServiceUri': 'ws://127.0.0.1:PORT/TOKEN=/ws',
          });
          fa.flushMicrotasks();
          expect(h.adapter.received, isEmpty);
          final response = h.client.sentWhere('response', 'attach').single;
          expect(response['success'], isFalse);
          expect(response['request_seq'], 4);
          expect(response['seq'], injectedBase);
          final error = (response['body']! as Map)['error']! as Map;
          expect(error['showUser'], isTrue);
          expect(error['format'], contains('flutter run'));
          expect(
            h.proxy.state.request,
            'attach',
            reason: 'the kind is recorded',
          );
        });
      },
    );

    test(
      'a refused attach is recorded as an attach, and terminate is prompt',
      () {
        fakeAsync((fa) {
          final h = Harness();
          h.request(4, 'attach', {
            'vmServiceUri': 'ws://127.0.0.1:PORT/TOKEN=/ws',
          });
          fa.flushMicrotasks();
          expect(h.proxy.state.request, 'attach');
          h.request(5, 'terminate');
          fa.flushMicrotasks();
          fa.elapse(const Duration(seconds: 1));
          expect(
            h.adapter.received.where((m) => (m['seq']! as int) >= injectedBase),
            isEmpty,
            reason: 'no injected terminate: the adapter never attached',
          );
          h.adapter.respond(h.adapter.lastRequest('terminate'));
          h.adapter.event('terminated');
          fa.elapse(const Duration(seconds: 1));
          final answer = h.client.sentWhere('response', 'terminate');
          expect(answer, hasLength(1));
          expect(answer.single['request_seq'], 5);
        });
      },
    );

    test('a non-string command is forwarded unchanged, never dropped', () {
      fakeAsync((fa) {
        final h = Harness();
        final odd = <String, Object?>{
          'seq': 9,
          'type': 'request',
          'command': 5,
        };
        h.fromClient(odd);
        fa.flushMicrotasks();
        expect(h.adapter.received.single, odd);
      });
    });

    test('a malformed adapter message is forwarded unchanged', () {
      fakeAsync((fa) {
        final h = Harness();
        final odd = <String, Object?>{'seq': 9, 'type': 7, 'event': 1};
        h.adapter.emit(odd);
        fa.flushMicrotasks();
        expect(h.client.sent.last, odd);
      });
    });

    test('a dart attach without any address is refused', () {
      fakeAsync((fa) {
        final h = Harness(kind: DapKind.dart);
        h.request(4, 'attach', {});
        fa.flushMicrotasks();
        expect(h.adapter.received, isEmpty);
        expect(
          h.client.sentWhere('response', 'attach').single['success'],
          false,
        );
      });
    });

    test('a real address is forwarded', () {
      fakeAsync((fa) {
        final h = Harness();
        h.request(4, 'attach', attachArgs);
        fa.flushMicrotasks();
        expect(h.adapter.received.single['command'], 'attach');
      });
    });
  });

  group('injected clock and timings', () {
    test('the initialize watchdog follows the options and the clock', () {
      fakeAsync((fa) {
        final h = Harness(
          options: const ProxyOptions(
            kind: DapKind.flutter,
            cwd: '/proj',
            initializeTimeout: Duration(seconds: 3),
            initializeNoticeAfter: Duration(seconds: 1),
            timings: ProxyTimings(drainWait: Duration(milliseconds: 10)),
          ),
          clock: FakeClock(fa),
        );
        h.request(1, 'initialize');
        fa.elapse(const Duration(milliseconds: 1500));
        expect(h.client.outputs.single, contains('still starting'));
        fa.elapse(const Duration(seconds: 3));
        expect(
          h.client.sentWhere('response', 'initialize').single['success'],
          false,
        );
        expect(h.exitCode, 1);
        expect(h.proxy.phase, SessionPhase.finished);
      });
    });
  });
}
