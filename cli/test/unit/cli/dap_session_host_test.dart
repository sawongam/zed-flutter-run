import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_run/src/cli/dap_session_host.dart';
import 'package:flutter_run/src/common/clock.dart';
import 'package:flutter_run/src/common/errors.dart';
import 'package:flutter_run/src/common/logger.dart';
import 'package:flutter_run/src/control/control_protocol.dart';
import 'package:flutter_run/src/control/session_info.dart';
import 'package:flutter_run/src/control/session_store.dart';
import 'package:flutter_run/src/dap/launch_rewriter.dart';
import 'package:flutter_run/src/devtools/browser_opener.dart';
import 'package:test/test.dart';

import '../dap/fakes.dart';
import 'support.dart';

/// A [Clock] on a `fake_async` zone: timers are the zone's fake timers, `now`
/// is the fake time.
class _FakeAsyncClock implements Clock {
  _FakeAsyncClock(this._fa);

  final FakeAsync _fa;

  @override
  DateTime now() => _fa.getClock(DateTime.utc(2026)).now();

  @override
  Timer timer(Duration d, void Function() cb) => Timer(d, cb);

  @override
  Timer periodic(Duration d, void Function(Timer) cb) => Timer.periodic(d, cb);

  @override
  Future<void> delay(Duration d) {
    final c = Completer<void>();
    timer(d, c.complete);
    return c.future;
  }

  @override
  Stopwatch stopwatch() => _fa.getClock(DateTime.utc(2026)).stopwatch();
}

/// Records the order of cleanup steps across fakes.
class _Trace {
  final List<String> steps = [];

  int indexOf(String step) => steps.indexOf(step);
}

class _FakeEndpoint implements ControlEndpoint {
  _FakeEndpoint(this._trace);

  final _Trace _trace;
  int closeCount = 0;

  @override
  int get port => 4711;

  @override
  String get token => 'secret-token';

  @override
  Future<void> close() async {
    closeCount++;
    _trace.steps.add('server:closed');
  }
}

class _FakeHandle implements SessionHandle {
  _FakeHandle(this._trace, this.updates);

  final _Trace _trace;
  final List<SessionInfo> updates;
  int deleteCount = 0;

  @override
  String get path => '/sessions/4321.json';

  @override
  Future<void> update(SessionInfo info) async {
    updates.add(info);
  }

  @override
  Future<void> delete() async {
    deleteCount++;
    _trace.steps.add('session:deleted');
  }
}

class _FakeStore implements SessionStore {
  _FakeStore(this._trace);

  final _Trace _trace;
  final List<SessionInfo> created = [];
  final List<SessionInfo> updates = [];
  _FakeHandle? handle;

  @override
  Future<SessionHandle> create(SessionInfo info) async {
    created.add(info);
    updates.add(info);
    _trace.steps.add('session:created');
    return handle = _FakeHandle(_trace, updates);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBrowser implements BrowserOpener {
  final List<Uri> opened = [];

  @override
  Future<void> open(Uri url) async {
    opened.add(url);
  }
}

/// A [DapSessionHost] on fakes, inside a `fake_async` zone.
class _Harness {
  _Harness(
    this.fa,
    this.t, {
    DapKind kind = DapKind.flutter,
    String request = 'launch',
    bool controlFails = false,
    Set<ProcessSignal> unsupported = const {},
  }) {
    signals.unsupported.addAll(unsupported);
    clock = _FakeAsyncClock(fa);
    store = _FakeStore(trace);
    client = FakeChannel();
    adapter = FakeAdapter();
    endpoint = _FakeEndpoint(trace);
    host = DapSessionHost(
      env: t.wiring.env,
      clock: clock,
      logger: Logger.silent(),
      signals: signals,
      sessionStore: store,
      deviceStore: t.wiring.deviceStore,
      browserOpener: browser,
      client: client,
      adapter: adapter,
      kind: kind,
      request: request,
      cwd: '${t.dir.path}/app',
      clientVersion: null,
      resolvedExecutable: '/opt/tools/flutter_run',
      attachWatchdog: const Duration(seconds: 15),
      sessionWriteDebounce: const Duration(milliseconds: 50),
      pid: 4321,
      startControlServer: ({required control, logger}) async {
        if (controlFails) throw const SessionRequestException('no port');
        return endpoint;
      },
    );
    host.run().then((c) => exitCode = c);
    fa.flushMicrotasks();
  }

  final FakeAsync fa;
  final TestWiring t;
  final _Trace trace = _Trace();
  final FakeSignalSource signals = FakeSignalSource();
  final _FakeBrowser browser = _FakeBrowser();
  late final _FakeAsyncClock clock;
  late final _FakeStore store;
  late final FakeChannel client;
  late final FakeAdapter adapter;
  late final _FakeEndpoint endpoint;
  late final DapSessionHost host;
  int? exitCode;

  /// Sends `launch`; reload on save is off unless the test says otherwise,
  /// because its file watcher would do real I/O.
  void launch([Map<String, Object?> args = const {}]) {
    client.incoming.add({
      'seq': 1,
      'type': 'request',
      'command': 'launch',
      'arguments': {'reloadOnSave': 'off', ...args},
    });
    fa.flushMicrotasks();
  }

  void adapterEvent(String name, [Map<String, Object?> body = const {}]) {
    adapter.event(name, body);
    fa.flushMicrotasks();
  }

  void appStarted() => adapterEvent('flutter.appStarted');

  /// The adapter ends and the proxy finishes its shutdown.
  void finish([int code = 0]) {
    adapter.die(code);
    fa.elapse(const Duration(seconds: 10));
  }
}

void main() {
  late TestWiring t;

  setUp(() {
    t = TestWiring();
    Directory('${t.dir.path}/app/lib').createSync(recursive: true);
    File('${t.dir.path}/app/pubspec.yaml').writeAsStringSync('name: app\n');
  });

  tearDown(() => t.dispose());

  void inSession(
    void Function(_Harness h) body, {
    DapKind kind = DapKind.flutter,
    String request = 'launch',
    bool controlFails = false,
  }) {
    fakeAsync((fa) {
      body(
        _Harness(
          fa,
          t,
          kind: kind,
          request: request,
          controlFails: controlFails,
        ),
      );
    });
  }

  group('session file', () {
    test('is written at start with the fake clock and removed on exit', () {
      inSession((h) {
        final info = h.store.created.single;
        expect(info.pid, 4321);
        expect(info.port, 4711);
        expect(info.token, 'secret-token');
        expect(info.kind, 'flutter');
        expect(info.cwd, '${t.dir.path}/app');
        expect(info.startedAt, DateTime.utc(2026));
        expect(h.store.handle!.deleteCount, 0);

        h.client.incoming.close();
        h.fa.flushMicrotasks();
        h.finish();
        expect(h.exitCode, 0);
        expect(h.store.handle!.deleteCount, 1);
      });
    });

    test('is updated at once when the app starts', () {
      inSession((h) {
        h.launch();
        h.adapterEvent('flutter.appStart', {
          'appId': 'a1',
          'deviceId': 'linux',
          'mode': 'debug',
        });
        h.appStarted();
        final last = h.store.updates.last;
        expect(last.appStarted, isTrue);
        expect(last.deviceId, 'linux');
        expect(last.mode, 'debug');
      });
    });

    test('state changes are written once, after the debounce', () {
      inSession((h) {
        h.launch();
        final before = h.store.updates.length;
        h.adapterEvent('flutter.appStart', {'deviceId': 'linux'});
        h.adapterEvent('dart.debuggerUris', {'vmServiceUri': 'ws://x/ws'});
        expect(h.store.updates, hasLength(before));
        h.fa.elapse(const Duration(milliseconds: 49));
        expect(h.store.updates, hasLength(before));
        h.fa.elapse(const Duration(milliseconds: 2));
        expect(h.store.updates, hasLength(before + 1));
        expect(h.store.updates.last.vmServiceUri, 'ws://x/ws');
        expect(h.store.updates.last.deviceId, 'linux');
      });
    });

    test('is not written after the shutdown started', () {
      inSession((h) {
        h.launch();
        h.adapterEvent('flutter.appStart', {'deviceId': 'linux'});
        final before = h.store.updates.length;
        h.client.incoming.close();
        h.fa.flushMicrotasks();
        h.fa.elapse(const Duration(seconds: 1));
        expect(h.store.updates, hasLength(before));
        h.finish();
      });
    });

    test('a control server failure is reported and debugging goes on', () {
      inSession(controlFails: true, (h) {
        expect(h.store.created, isEmpty);
        h.launch();
        expect(
          h.client.outputs.join('\n'),
          contains('cannot find this debug session (no port)'),
        );
        h.client.incoming.close();
        h.fa.flushMicrotasks();
        h.finish();
        expect(h.exitCode, 0);
        expect(h.endpoint.closeCount, 0);
      });
    });
  });

  group('every exit path removes the session file and closes the server', () {
    final paths = <String, void Function(_Harness h)>{
      'client closes stdin': (h) {
        h.client.incoming.close();
        h.fa.flushMicrotasks();
        h.finish();
      },
      'SIGTERM': (h) {
        h.signals.raise(ProcessSignal.sigterm);
        h.fa.flushMicrotasks();
        h.finish();
      },
      'SIGINT': (h) {
        h.signals.raise(ProcessSignal.sigint);
        h.fa.flushMicrotasks();
        h.finish();
      },
      'SIGHUP': (h) {
        h.signals.raise(ProcessSignal.sighup);
        h.fa.flushMicrotasks();
        h.finish();
      },
      'adapter crash': (h) {
        h.finish(1);
      },
      'terminate request': (h) {
        h.client.incoming.add({
          'seq': 9,
          'type': 'request',
          'command': 'terminate',
        });
        h.fa.flushMicrotasks();
        h.adapter.respond(h.adapter.lastRequest('terminate'));
        h.adapterEvent('terminated');
        h.finish();
      },
    };
    for (final MapEntry(key: name, value: trigger) in paths.entries) {
      test(name, () {
        if (name.startsWith('SIG') && Platform.isWindows && name != 'SIGINT') {
          return;
        }
        inSession((h) {
          h.launch();
          h.appStarted();
          trigger(h);
          expect(h.exitCode, isNotNull);
          expect(h.store.handle!.deleteCount, 1);
          expect(h.endpoint.closeCount, 1);
        });
      });
    }
  });

  group('signals', () {
    test('a signal runs the cleanup in order: file, then server', () {
      inSession((h) {
        h.launch();
        h.appStarted();
        // Windows only watches SIGINT.
        h.signals.raise(
          Platform.isWindows ? ProcessSignal.sigint : ProcessSignal.sigterm,
        );
        h.fa.flushMicrotasks();
        // Nothing is torn down until the proxy has started its shutdown...
        h.finish();
        expect(h.exitCode, 0);
        final trace = h.trace.steps;
        expect(trace.first, 'session:created');
        expect(
          h.trace.indexOf('session:deleted'),
          lessThan(h.trace.indexOf('server:closed')),
        );
        expect(h.client.flushCount, greaterThan(0));
        expect(h.adapter.receivedRequest('terminate'), isTrue);
      });
    });

    test('a signal that arrives before the proxy exists is not lost', () {
      fakeAsync((fa) {
        final signals = FakeSignalSource();
        final store = _FakeStore(_Trace());
        final adapter = FakeAdapter();
        final host = DapSessionHost(
          env: t.wiring.env,
          clock: _FakeAsyncClock(fa),
          logger: Logger.silent(),
          signals: signals,
          sessionStore: store,
          deviceStore: t.wiring.deviceStore,
          browserOpener: _FakeBrowser(),
          client: FakeChannel(),
          adapter: adapter,
          kind: DapKind.flutter,
          request: 'launch',
          cwd: '${t.dir.path}/app',
          clientVersion: null,
          resolvedExecutable: '/opt/tools/flutter_run',
          attachWatchdog: const Duration(seconds: 15),
          sessionWriteDebounce: const Duration(milliseconds: 50),
          pid: 1,
          startControlServer: ({required control, logger}) async =>
              _FakeEndpoint(_Trace()),
        );
        int? code;
        host.requestShutdown('signal early');
        host.run().then((c) => code = c);
        fa.flushMicrotasks();
        adapter.die(0);
        fa.elapse(const Duration(seconds: 10));
        expect(code, 0);
        expect(store.handle!.deleteCount, 1);
      });
    });

    test(
      'a signal during start-up marks the control ending before it serves',
      () {
        fakeAsync((fa) {
          final adapter = FakeAdapter();
          SessionControl? served;
          final host = DapSessionHost(
            env: t.wiring.env,
            clock: _FakeAsyncClock(fa),
            logger: Logger.silent(),
            signals: FakeSignalSource(),
            sessionStore: _FakeStore(_Trace()),
            deviceStore: t.wiring.deviceStore,
            browserOpener: _FakeBrowser(),
            client: FakeChannel(),
            adapter: adapter,
            kind: DapKind.flutter,
            request: 'launch',
            cwd: '${t.dir.path}/app',
            clientVersion: null,
            resolvedExecutable: '/opt/tools/flutter_run',
            attachWatchdog: const Duration(seconds: 15),
            sessionWriteDebounce: const Duration(milliseconds: 50),
            pid: 1,
            startControlServer: ({required control, logger}) async {
              served = control;
              return _FakeEndpoint(_Trace());
            },
          );
          host.requestShutdown('signal early');
          host.run();
          fa.flushMicrotasks();
          adapter.die(0);
          fa.elapse(const Duration(seconds: 10));
          expect(served, isNotNull);
          Object? error;
          served!
              .restart(const {})
              .then<void>((_) {}, onError: (Object e) => error = e);
          fa.flushMicrotasks();
          expect(error, isA<ControlException>());
          expect(
            (error! as ControlException).code,
            ControlErrorCode.sessionEnded,
          );
        });
      },
    );

    test('watches the signals while running and releases them after', () {
      inSession((h) {
        expect(h.signals.isWatched(ProcessSignal.sigint), isTrue);
        if (!Platform.isWindows) {
          expect(h.signals.isWatched(ProcessSignal.sigterm), isTrue);
          expect(h.signals.isWatched(ProcessSignal.sighup), isTrue);
        }
        h.client.incoming.close();
        h.fa.flushMicrotasks();
        h.finish();
        expect(h.signals.isWatched(ProcessSignal.sigint), isFalse);
        expect(h.signals.isWatched(ProcessSignal.sigterm), isFalse);
      });
    });

    test('a signal that cannot be watched does not stop the session', () {
      fakeAsync((fa) {
        final h = _Harness(
          fa,
          t,
          unsupported: {ProcessSignal.sigterm, ProcessSignal.sighup},
        );
        expect(h.exitCode, isNull);
        expect(h.signals.isWatched(ProcessSignal.sigint), isTrue);
        h.client.incoming.close();
        fa.flushMicrotasks();
        h.finish();
        expect(h.exitCode, 0);
      });
    });

    test('a second signal does not shut down twice', () {
      inSession((h) {
        h.launch();
        h.signals.raise(ProcessSignal.sigterm);
        h.signals.raise(ProcessSignal.sigint);
        h.fa.flushMicrotasks();
        h.finish();
        expect(
          h.adapter.received.where((m) => m['command'] == 'terminate'),
          hasLength(1),
        );
        expect(h.store.handle!.deleteCount, 1);
      });
    });
  });

  group('DevTools auto-open', () {
    const uri = 'http://127.0.0.1:7/tok=/';

    test('opens the configured page for the first debugger address', () {
      inSession((h) {
        h.launch({'openDevTools': 'inspector'});
        h.adapterEvent('dart.debuggerUris', {'vmServiceUri': uri});
        expect(h.browser.opened, hasLength(1));
        expect(h.browser.opened.single.path, contains('/devtools/inspector'));
        expect(h.client.outputs.join('\n'), contains('Opened DevTools: '));
        h.finish();
      });
    });

    test('opens only once, not for later addresses (hot restart)', () {
      inSession((h) {
        h.launch({'openDevTools': 'performance'});
        h.adapterEvent('dart.debuggerUris', {'vmServiceUri': uri});
        h.adapterEvent('dart.debuggerUris', {'vmServiceUri': uri});
        expect(h.browser.opened, hasLength(1));
        h.finish();
      });
    });

    test('does nothing without openDevTools or with never', () {
      inSession((h) {
        h.launch();
        h.adapterEvent('dart.debuggerUris', {'vmServiceUri': uri});
        expect(h.browser.opened, isEmpty);
        h.finish();
      });
      inSession((h) {
        h.launch({'openDevTools': 'never'});
        h.adapterEvent('dart.debuggerUris', {'vmServiceUri': uri});
        expect(h.browser.opened, isEmpty);
        h.finish();
      });
    });

    test('an unknown page shows a warning and opens nothing', () {
      inSession((h) {
        h.launch({'openDevTools': 'bogus'});
        h.adapterEvent('dart.debuggerUris', {'vmServiceUri': uri});
        expect(h.browser.opened, isEmpty);
        expect(h.client.outputs.join('\n'), contains('not a DevTools page'));
        h.finish();
      });
    });

    test('a Dart session shows the notice but opens no browser', () {
      inSession(kind: DapKind.dart, (h) {
        h.launch({'openDevTools': 'inspector'});
        h.adapterEvent('dart.debuggerUris', {'vmServiceUri': uri});
        expect(h.browser.opened, isEmpty);
        h.finish();
      });
    });
  });

  group('reload on save', () {
    test('is refused with a notice when the app runs in profile mode', () {
      inSession((h) {
        h.launch({'reloadOnSave': 'always'});
        h.adapterEvent('flutter.appStart', {
          'deviceId': 'linux',
          'mode': 'profile',
        });
        h.appStarted();
        expect(h.client.outputs.join('\n'), contains('runs in profile mode'));
        h.finish();
        expect(h.exitCode, 0);
      });
    });
  });

  group('attach watchdog', () {
    test('tells the user the app is not there after 15 seconds', () {
      inSession(request: 'attach', (h) {
        h.client.incoming.add({
          'seq': 1,
          'type': 'request',
          'command': 'attach',
          'arguments': <String, Object?>{},
        });
        h.fa.flushMicrotasks();
        h.fa.elapse(const Duration(seconds: 14));
        expect(h.client.outputs.join('\n'), isNot(contains('Still waiting')));
        h.fa.elapse(const Duration(seconds: 2));
        expect(h.client.outputs.join('\n'), contains('Still waiting'));
        h.finish();
      });
    });

    test('stays quiet when the app starts in time', () {
      inSession(request: 'attach', (h) {
        h.client.incoming.add({
          'seq': 1,
          'type': 'request',
          'command': 'attach',
          'arguments': <String, Object?>{},
        });
        h.fa.flushMicrotasks();
        h.appStarted();
        h.fa.elapse(const Duration(seconds: 30));
        expect(h.client.outputs.join('\n'), isNot(contains('Still waiting')));
        h.finish();
      });
    });
  });
}
