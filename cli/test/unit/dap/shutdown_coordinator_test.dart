import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_run/src/common/json_types.dart';
import 'package:flutter_run/src/common/logger.dart';
import 'package:flutter_run/src/dap/launch_rewriter.dart';
import 'package:flutter_run/src/dap/messages.dart';
import 'package:flutter_run/src/dap/proxy_options.dart';
import 'package:flutter_run/src/dap/session_phase.dart';
import 'package:flutter_run/src/dap/shutdown_coordinator.dart';
import 'package:test/test.dart';

import 'fakes.dart';

class FakeHost implements ShutdownHost {
  @override
  bool isLaunchSession = true;

  @override
  bool programEnded = false;

  @override
  int? exitCodeOverride;

  final List<DapJson> toClient = [];
  final List<DapJson> toAdapter = [];
  final List<String> notices = [];
  final List<String> injected = [];
  final List<int> finished = [];
  int _seq = 9000;

  /// How an injected request is answered; null leaves it pending.
  Future<DapJson> Function(String command)? injectHandler;

  @override
  void sendToClient(DapJson message) => toClient.add(message);

  @override
  void sendToAdapter(DapJson message) => toAdapter.add(message);

  @override
  void notice(String text) => notices.add(text);

  @override
  int nextSyntheticSeq() => _seq++;

  @override
  Future<DapJson> inject(String command, Json arguments, Duration timeout) {
    injected.add(command);
    return injectHandler?.call(command) ?? Completer<DapJson>().future;
  }

  @override
  Future<void> flushClient() async {}

  @override
  Future<void> finish(int code) async => finished.add(code);

  @override
  void guard(Future<void> Function() body, String what) {
    unawaited(body());
  }
}

DapMessage request(int seq, String command) =>
    DapMessage({'seq': seq, 'type': 'request', 'command': command});

DapMessage response(int requestSeq, String command) => DapMessage({
  'seq': 700 + requestSeq,
  'type': 'response',
  'request_seq': requestSeq,
  'success': true,
  'command': command,
});

class Rig {
  Rig(
    FakeAsync fa, {
    this.options = const ProxyOptions(kind: DapKind.flutter),
    Future<void> Function()? onStarted,
    Future<void> Function()? onCleanup,
  }) {
    adapter = FakeAdapter();
    phase = SessionPhaseMachine(strict: true)..transition(SessionPhase.running);
    coordinator = ShutdownCoordinator(
      host: host,
      adapter: adapter,
      phase: phase,
      clock: FakeClock(fa),
      options: options,
      log: Logger.silent(),
      onShutdownStarted: onStarted,
      onShutdownCleanup: onCleanup,
    );
  }

  final ProxyOptions options;
  final FakeHost host = FakeHost();
  late final FakeAdapter adapter;
  late final SessionPhaseMachine phase;
  late final ShutdownCoordinator coordinator;
  final Completer<int> done = Completer<int>();

  Iterable<DapJson> clientResponses(String command) =>
      host.toClient.where((m) => m['command'] == command);
}

void main() {
  group('ShutdownCoordinator terminate', () {
    test('forwards, holds the answer until terminated, then releases it', () {
      fakeAsync((fa) {
        final rig = Rig(fa);
        rig.adapter.descendants = {7};
        unawaited(rig.coordinator.handleTerminate(request(5, 'terminate')));
        fa.flushMicrotasks();
        expect(rig.phase.phase, SessionPhase.stopping);
        expect(rig.coordinator.terminateFlow, StopFlow.requested);
        expect(rig.host.toAdapter.single['command'], 'terminate');

        expect(rig.coordinator.holdResponse(response(5, 'terminate')), isTrue);
        fa.flushMicrotasks();
        expect(rig.host.toClient, isEmpty, reason: 'waits for terminated');

        rig.coordinator.markTerminatedSeen();
        rig.coordinator.maybeFinishTerminate();
        fa.elapse(const Duration(seconds: 2));
        expect(rig.coordinator.terminateFlow, StopFlow.finished);
        expect(rig.clientResponses('terminate').single['request_seq'], 5);
        expect(rig.adapter.terminateTreeCalls.single, {7});
      });
    });

    test('says that it is stopping after one second', () {
      fakeAsync((fa) {
        final rig = Rig(fa);
        unawaited(rig.coordinator.handleTerminate(request(5, 'terminate')));
        fa.elapse(const Duration(milliseconds: 900));
        expect(rig.host.notices, isEmpty);
        fa.elapse(const Duration(milliseconds: 200));
        expect(rig.host.notices, ['Stopping the app...']);
      });
    });

    test('the deadline answers success itself and sweeps without waiting', () {
      fakeAsync((fa) {
        final rig = Rig(fa);
        unawaited(rig.coordinator.handleTerminate(request(5, 'terminate')));
        fa.elapse(const Duration(seconds: 4));
        expect(rig.clientResponses('terminate'), isEmpty);
        fa.elapse(const Duration(seconds: 2));
        final answer = rig.clientResponses('terminate').single;
        expect(answer['success'], isTrue);
        expect(answer['request_seq'], 5);
        expect(rig.adapter.terminateTreeCalls, hasLength(1));
      });
    });

    test('a repeated terminate is forwarded, not handled twice', () {
      fakeAsync((fa) {
        final rig = Rig(fa);
        unawaited(rig.coordinator.handleTerminate(request(5, 'terminate')));
        fa.flushMicrotasks();
        unawaited(rig.coordinator.handleTerminate(request(6, 'terminate')));
        fa.flushMicrotasks();
        expect(rig.host.toAdapter, hasLength(2));
        expect(rig.adapter.snapshotCalls, 1);
      });
    });

    test('an exited adapter answers the terminate without forwarding it', () {
      fakeAsync((fa) {
        final rig = Rig(fa);
        rig.coordinator.markAdapterExited();
        unawaited(rig.coordinator.handleTerminate(request(5, 'terminate')));
        fa.elapse(const Duration(seconds: 1));
        expect(rig.host.toAdapter, isEmpty);
        expect(rig.clientResponses('terminate').single['success'], isTrue);
      });
    });
  });

  group('ShutdownCoordinator finishing window', () {
    test(
      'a terminate after beginFinish starts nothing and leaves no timers',
      () {
        fakeAsync((fa) {
          final rig = Rig(fa);
          rig.phase.transition(SessionPhase.finishing);
          rig.coordinator.beginFinish();
          unawaited(rig.coordinator.handleTerminate(request(5, 'terminate')));
          fa.elapse(const Duration(seconds: 30));
          expect(rig.host.notices, isEmpty);
          expect(rig.host.toClient, isEmpty);
          expect(rig.host.toAdapter, isEmpty);
          expect(rig.coordinator.terminateRequested, isFalse);
          expect(fa.pendingTimers, isEmpty);
        });
      },
    );

    test('an adapter disconnect answer after beginFinish re-arms no timer', () {
      fakeAsync((fa) {
        final rig = Rig(fa);
        rig.host.isLaunchSession = false;
        unawaited(rig.coordinator.handleDisconnect(request(8, 'disconnect')));
        fa.flushMicrotasks();
        rig.phase.transition(SessionPhase.finishing);
        rig.coordinator.beginFinish();
        expect(rig.coordinator.holdResponse(response(8, 'disconnect')), isTrue);
        fa.elapse(const Duration(seconds: 30));
        expect(rig.host.finished, isEmpty);
        expect(rig.clientResponses('disconnect'), isEmpty);
      });
    });
  });

  group('ShutdownCoordinator disconnect', () {
    test('an answered disconnect is released after the grace period', () {
      fakeAsync((fa) {
        final rig = Rig(fa);
        rig.host.isLaunchSession = false;
        unawaited(rig.coordinator.handleDisconnect(request(8, 'disconnect')));
        fa.flushMicrotasks();
        expect(rig.host.toAdapter.single['command'], 'disconnect');
        expect(rig.coordinator.disconnectFlow, StopFlow.requested);

        expect(rig.coordinator.holdResponse(response(8, 'disconnect')), isTrue);
        fa.elapse(const Duration(milliseconds: 400));
        expect(rig.host.finished, isEmpty);
        fa.elapse(const Duration(seconds: 3));
        expect(rig.clientResponses('disconnect').single['request_seq'], 8);
        expect(rig.host.finished, [0]);
      });
    });

    test('an unanswered disconnect ends after exitWait', () {
      fakeAsync((fa) {
        final rig = Rig(fa);
        rig.host.isLaunchSession = false;
        unawaited(rig.coordinator.handleDisconnect(request(8, 'disconnect')));
        fa.elapse(const Duration(seconds: 4));
        expect(rig.host.finished, isEmpty);
        fa.elapse(const Duration(seconds: 3));
        expect(rig.clientResponses('disconnect').single['success'], isTrue);
        expect(rig.host.finished, [0]);
      });
    });

    test('on launch it injects a terminate first', () {
      fakeAsync((fa) {
        final rig = Rig(fa);
        rig.host.injectHandler = (_) async => {'success': true};
        unawaited(rig.coordinator.handleDisconnect(request(8, 'disconnect')));
        fa.flushMicrotasks();
        expect(rig.host.injected, ['terminate']);
        expect(rig.host.toAdapter.single['command'], 'disconnect');
      });
    });

    test('unrelated responses are not held', () {
      fakeAsync((fa) {
        final rig = Rig(fa);
        expect(rig.coordinator.holdResponse(response(3, 'next')), isFalse);
      });
    });
  });

  group('ShutdownCoordinator shutdown', () {
    test(
      'injects terminate and disconnect, then finishes with the override',
      () {
        fakeAsync((fa) {
          final rig = Rig(fa);
          rig.host.exitCodeOverride = 1;
          unawaited(rig.coordinator.shutdown('test', done: rig.done.future));
          fa.flushMicrotasks();
          expect(rig.host.injected, ['terminate']);
          // The terminate gets no answer: it is bounded by terminateTimeout.
          fa.elapse(const Duration(seconds: 5));
          expect(rig.host.injected, ['terminate', 'disconnect']);
          expect(rig.host.finished, isEmpty);
          fa.elapse(const Duration(seconds: 5));
          expect(rig.host.finished, [1]);
        });
      },
    );

    test('is idempotent', () {
      fakeAsync((fa) {
        final rig = Rig(fa);
        final a = rig.coordinator.shutdown('one', done: rig.done.future);
        final b = rig.coordinator.shutdown('two', done: rig.done.future);
        expect(identical(a, b), isTrue);
      });
    });

    test('attach sessions get a disconnect only', () {
      fakeAsync((fa) {
        final rig = Rig(fa);
        rig.host.isLaunchSession = false;
        unawaited(rig.coordinator.shutdown('eof', done: rig.done.future));
        fa.flushMicrotasks();
        expect(rig.host.injected, ['disconnect']);
      });
    });

    test('a finished adapter ends it straight away', () {
      fakeAsync((fa) {
        final rig = Rig(fa);
        rig.coordinator.markAdapterExited();
        unawaited(rig.coordinator.shutdown('eof', done: rig.done.future));
        fa.flushMicrotasks();
        expect(rig.host.injected, isEmpty);
        expect(rig.host.finished, [0]);
      });
    });

    test('a pending disconnect lets the shutdown wait for done', () {
      fakeAsync((fa) {
        final rig = Rig(fa);
        unawaited(rig.coordinator.handleDisconnect(request(8, 'disconnect')));
        fa.flushMicrotasks();
        var returned = false;
        rig.coordinator
            .shutdown('eof', done: rig.done.future)
            .then((_) => returned = true);
        fa.flushMicrotasks();
        expect(returned, isFalse);
        rig.done.complete(0);
        fa.flushMicrotasks();
        expect(returned, isTrue);
        expect(rig.host.finished, isEmpty);
      });
    });
  });

  group('ShutdownCoordinator hooks and sweep', () {
    test('hooks run in order, once, before the sweep', () {
      fakeAsync((fa) {
        final order = <String>[];
        final rig = Rig(
          fa,
          onStarted: () async => order.add('started'),
          onCleanup: () async => order.add('cleanup'),
        );
        unawaited(rig.coordinator.startShutdown());
        unawaited(rig.coordinator.startShutdown());
        unawaited(rig.coordinator.cleanup());
        unawaited(rig.coordinator.cleanup());
        fa.elapse(const Duration(seconds: 5));
        expect(order, ['started', 'cleanup']);
      });
    });

    test('a hook that never returns is abandoned after hookWait', () {
      fakeAsync((fa) {
        final rig = Rig(
          fa,
          onStarted: () => Completer<void>().future,
          onCleanup: () => Completer<void>().future,
        );
        var cleaned = false;
        rig.coordinator.cleanup().then((_) => cleaned = true);
        fa.elapse(const Duration(seconds: 3));
        expect(cleaned, isFalse);
        fa.elapse(const Duration(seconds: 6));
        expect(cleaned, isTrue);
      });
    });

    test('a throwing hook does not stop the cleanup', () {
      fakeAsync((fa) {
        final rig = Rig(
          fa,
          onStarted: () async => throw StateError('boom'),
          onCleanup: () async => throw StateError('boom'),
        );
        var cleaned = false;
        rig.coordinator.cleanup().then((_) => cleaned = true);
        fa.elapse(const Duration(seconds: 5));
        expect(cleaned, isTrue);
      });
    });

    test('after a crash the sweep uses the last two polls', () {
      fakeAsync((fa) {
        final rig = Rig(fa);
        rig.coordinator.startSnapshots();
        rig.adapter.descendants = {1};
        fa.elapse(const Duration(milliseconds: 400));
        rig.adapter.descendants = {2};
        fa.elapse(const Duration(seconds: 2));
        rig.adapter.descendants = {3};
        fa.elapse(const Duration(seconds: 2));
        rig.coordinator.markAdapterExited();
        rig.coordinator.markCrashed();
        unawaited(rig.coordinator.cleanup());
        fa.elapse(const Duration(seconds: 5));
        expect(rig.adapter.terminateTreeCalls.single, {2, 3});
        expect(rig.adapter.terminateTreeCrashed.single, isTrue);
      });
    });

    test('beginFinish stops the periodic snapshots', () {
      fakeAsync((fa) {
        final rig = Rig(fa);
        rig.coordinator.startSnapshots();
        fa.elapse(const Duration(seconds: 3));
        final before = rig.adapter.snapshotCalls;
        expect(before, greaterThan(0));
        rig.coordinator.beginFinish();
        fa.elapse(const Duration(seconds: 10));
        expect(rig.adapter.snapshotCalls, before);
      });
    });

    test('custom timings are honoured', () {
      fakeAsync((fa) {
        final rig = Rig(
          fa,
          options: const ProxyOptions(
            kind: DapKind.flutter,
            timings: ProxyTimings(stoppingNoticeAfter: Duration(seconds: 10)),
          ),
        );
        unawaited(rig.coordinator.handleTerminate(request(5, 'terminate')));
        fa.elapse(const Duration(seconds: 4));
        expect(rig.host.notices, isEmpty);
      });
    });
  });
}
