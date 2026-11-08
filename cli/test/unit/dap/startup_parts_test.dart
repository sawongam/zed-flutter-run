import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_run/src/dap/bounded.dart';
import 'package:flutter_run/src/dap/initialize_watchdog.dart';
import 'package:flutter_run/src/dap/injected_requests.dart';
import 'package:flutter_run/src/dap/launch_rewriter.dart';
import 'package:flutter_run/src/dap/messages.dart';
import 'package:flutter_run/src/dap/stderr_tail.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  group('InitializeWatchdog', () {
    InitializeWatchdog make(
      FakeAsync fa,
      List<String> log, {
      bool ended = false,
    }) => InitializeWatchdog(
      clock: FakeClock(fa),
      timeout: const Duration(seconds: 120),
      noticeAfter: const Duration(seconds: 10),
      isEnded: () => ended,
      onSlow: () => log.add('slow'),
      onTimeout: (reason) => log.add('timeout: $reason'),
    );

    test('warns once at the notice time and fails at the limit', () {
      fakeAsync((fa) {
        final log = <String>[];
        final w = make(fa, log)..arm(1);
        expect(w.isPending, isTrue);
        fa.elapse(const Duration(seconds: 11));
        expect(log, ['slow']);
        fa.elapse(const Duration(seconds: 110));
        expect(log, [
          'slow',
          'timeout: The Flutter debug adapter did not answer within 120 seconds.',
        ]);
      });
    });

    test('the matching response cancels both timers', () {
      fakeAsync((fa) {
        final log = <String>[];
        final w = make(fa, log)..arm(1);
        expect(w.onResponse(2), isFalse);
        expect(w.onResponse(1), isTrue);
        expect(w.answered, isTrue);
        fa.elapse(const Duration(seconds: 200));
        expect(log, isEmpty);
        expect(
          w.onResponse(1),
          isFalse,
          reason: 'only the first answer counts',
        );
      });
    });

    test('stays quiet once the session is ending', () {
      fakeAsync((fa) {
        final log = <String>[];
        make(fa, log, ended: true).arm(1);
        fa.elapse(const Duration(seconds: 200));
        expect(log, isEmpty);
      });
    });
  });

  group('StderrTail', () {
    test('keeps only the last lines', () {
      final tail = StderrTail(maxLines: 2);
      expect(tail.isEmpty, isTrue);
      expect(tail.last, isNull);
      tail
        ..add('a')
        ..add('b')
        ..add('c');
      expect(tail.text, 'b\nc');
      expect(tail.last, 'c');
    });
  });

  group('bounded and withTimeout', () {
    test('bounded gives up after the limit', () {
      fakeAsync((fa) {
        var done = false;
        bounded(
          FakeClock(fa),
          Completer<void>().future,
          const Duration(seconds: 2),
        ).then((_) => done = true);
        fa.elapse(const Duration(seconds: 1));
        expect(done, isFalse);
        fa.elapse(const Duration(seconds: 2));
        expect(done, isTrue);
      });
    });

    test('bounded swallows the error of the future', () {
      fakeAsync((fa) {
        var done = false;
        bounded(
          FakeClock(fa),
          Future<void>.error(StateError('x')),
          const Duration(seconds: 2),
        ).then((_) => done = true);
        fa.flushMicrotasks();
        expect(done, isTrue);
      });
    });

    test('withTimeout throws a TimeoutException or uses onTimeout', () {
      fakeAsync((fa) {
        Object? error;
        withTimeout<int>(
          FakeClock(fa),
          Completer<int>().future,
          const Duration(seconds: 1),
        ).then<void>((_) {}, onError: (Object e) => error = e);
        int? value;
        withTimeout<int>(
          FakeClock(fa),
          Completer<int>().future,
          const Duration(seconds: 1),
          onTimeout: () => 7,
        ).then((v) => value = v);
        fa.elapse(const Duration(seconds: 2));
        expect(error, isA<TimeoutException>());
        expect(value, 7);
      });
    });
  });

  group('injection capability table', () {
    test('flutter supports hot reload and restart, dart only reload', () {
      expect(
        injectionSupported(DapKind.flutter, DapCommands.hotRestart),
        isTrue,
      );
      expect(
        injectionSupported(DapKind.flutter, DapCommands.hotReload),
        isTrue,
      );
      expect(injectionSupported(DapKind.dart, DapCommands.hotReload), isTrue);
      expect(injectionSupported(DapKind.dart, DapCommands.hotRestart), isFalse);
    });

    test('commands outside the table are never refused', () {
      expect(injectionSupported(DapKind.dart, DapCommands.terminate), isTrue);
      expect(injectionSupported(DapKind.dart, 'evaluate'), isTrue);
    });
  });
}
