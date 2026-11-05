import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_run/src/dap/hot_actions.dart';
import 'package:flutter_run/src/dap/messages.dart';
import 'package:flutter_run/src/dap/notices.dart';
import 'package:test/test.dart';

class FakeInjector implements RequestInjector {
  @override
  bool appStarted = true;
  final List<({String command, Object? args, Completer<DapJson> c})> calls = [];
  final List<(String, NoticeLevel)> notices = [];

  @override
  Future<DapJson> inject(
    String command, [
    Map<String, Object?>? arguments,
    Duration? timeout,
  ]) {
    final c = Completer<DapJson>();
    calls.add((command: command, args: arguments, c: c));
    return c.future;
  }

  @override
  void notice(String text, [NoticeLevel level = NoticeLevel.info]) =>
      notices.add((text, level));

  void ok(int index) => calls[index].c.complete({'success': true});

  void fail(int index, String message) =>
      calls[index].c.complete({'success': false, 'message': message});
}

void main() {
  late FakeInjector injector;
  late HotActions hot;

  void setUpHot({Duration timeout = const Duration(seconds: 120)}) {
    injector = FakeInjector();
    hot = HotActions(injector, timeout: timeout);
  }

  test('not started: no request, notStarted and a notice', () {
    fakeAsync((fa) {
      setUpHot();
      injector.appStarted = false;
      HotResult? r;
      hot.reload().then((v) => r = v);
      fa.flushMicrotasks();
      expect(r!.error, HotError.notStarted);
      expect(injector.calls, isEmpty);
      expect(injector.notices.single.$1, contains('still starting'));
    });
  });

  test('reload sends hotReload with the reason and succeeds', () {
    fakeAsync((fa) {
      setUpHot();
      HotResult? r;
      hot.reload(reason: 'save').then((v) => r = v);
      fa.flushMicrotasks();
      expect(injector.calls.single.command, 'hotReload');
      expect(injector.calls.single.args, {'reason': 'save'});
      expect(hot.busy, isTrue);
      injector.ok(0);
      fa.flushMicrotasks();
      expect(r!.ok, isTrue);
      expect(r!.coalesced, isFalse);
      expect(hot.busy, isFalse);
      // Save-triggered reloads get a notice.
      expect(injector.notices.single.$1, contains('after saving'));
    });
  });

  test('a manual successful reload adds no notice', () {
    fakeAsync((fa) {
      setUpHot();
      hot.reload();
      fa.flushMicrotasks();
      injector.ok(0);
      fa.flushMicrotasks();
      expect(injector.notices, isEmpty);
    });
  });

  test('a reload during a reload joins it (coalesced), one request', () {
    fakeAsync((fa) {
      setUpHot();
      HotResult? first, second;
      hot.reload(reason: 'save').then((v) => first = v);
      fa.flushMicrotasks();
      hot.reload().then((v) => second = v);
      fa.flushMicrotasks();
      expect(injector.calls, hasLength(1));
      injector.ok(0);
      fa.flushMicrotasks();
      expect(first!.ok, isTrue);
      expect(first!.coalesced, isFalse);
      expect(second!.ok, isTrue);
      expect(second!.coalesced, isTrue);
    });
  });

  test('restart during a reload is busy', () {
    fakeAsync((fa) {
      setUpHot();
      hot.reload();
      fa.flushMicrotasks();
      HotResult? r;
      hot.restart().then((v) => r = v);
      fa.flushMicrotasks();
      expect(r!.error, HotError.busy);
      expect(injector.calls, hasLength(1));
    });
  });

  test('restart during a restart is busy', () {
    fakeAsync((fa) {
      setUpHot();
      hot.restart();
      fa.flushMicrotasks();
      HotResult? r;
      hot.restart().then((v) => r = v);
      fa.flushMicrotasks();
      expect(r!.error, HotError.busy);
    });
  });

  test('a manual reload during a restart is busy', () {
    fakeAsync((fa) {
      setUpHot();
      hot.restart();
      fa.flushMicrotasks();
      HotResult? r;
      hot.reload().then((v) => r = v);
      fa.flushMicrotasks();
      expect(r!.error, HotError.busy);
      expect(injector.calls.single.command, 'hotRestart');
    });
  });

  test('a save reload during a restart waits and then runs', () {
    fakeAsync((fa) {
      setUpHot();
      hot.restart();
      fa.flushMicrotasks();
      HotResult? r;
      hot.reload(reason: 'save').then((v) => r = v);
      fa.flushMicrotasks();
      expect(injector.calls, hasLength(1));
      expect(r, isNull);
      injector.ok(0);
      fa.flushMicrotasks();
      expect(injector.calls, hasLength(2));
      expect(injector.calls[1].command, 'hotReload');
      injector.ok(1);
      fa.flushMicrotasks();
      expect(r!.ok, isTrue);
    });
  });

  test('client restart flag: manual is busy, save queues behind it', () {
    fakeAsync((fa) {
      setUpHot();
      hot.noteClientRestart(started: true);
      expect(hot.busy, isTrue);
      HotResult? manual, save, restart;
      hot.reload().then((v) => manual = v);
      hot.restart().then((v) => restart = v);
      hot.reload(reason: 'save').then((v) => save = v);
      fa.flushMicrotasks();
      expect(manual!.error, HotError.busy);
      expect(restart!.error, HotError.busy);
      expect(save, isNull);
      expect(injector.calls, isEmpty);
      hot.noteClientRestart(started: false);
      fa.flushMicrotasks();
      expect(injector.calls.single.command, 'hotReload');
      injector.ok(0);
      fa.flushMicrotasks();
      expect(save!.ok, isTrue);
      expect(hot.busy, isFalse);
    });
  });

  test('timeout: result is timeout, busy until the late response arrives', () {
    fakeAsync((fa) {
      setUpHot(timeout: const Duration(seconds: 10));
      HotResult? r;
      hot.reload().then((v) => r = v);
      fa.flushMicrotasks();
      fa.elapse(const Duration(seconds: 10));
      expect(r!.error, HotError.timeout);
      expect(hot.busy, isTrue);

      HotResult? next;
      hot.reload().then((v) => next = v);
      fa.flushMicrotasks();
      expect(next!.error, HotError.busy);
      expect(injector.calls, hasLength(1));

      injector.ok(0);
      fa.flushMicrotasks();
      expect(hot.busy, isFalse);
      hot.reload();
      fa.flushMicrotasks();
      expect(injector.calls, hasLength(2));
    });
  });

  test('a timed out action stops counting as in flight after 10 minutes', () {
    fakeAsync((fa) {
      setUpHot(timeout: const Duration(seconds: 10));
      hot.reload();
      fa.flushMicrotasks();
      fa.elapse(const Duration(seconds: 11));
      expect(hot.busy, isTrue);
      fa.elapse(const Duration(minutes: 10));
      expect(hot.busy, isFalse);
    });
  });

  test('waiting notice after 3 s, once', () {
    fakeAsync((fa) {
      setUpHot();
      hot.reload();
      fa.flushMicrotasks();
      fa.elapse(const Duration(seconds: 2));
      expect(injector.notices, isEmpty);
      fa.elapse(const Duration(seconds: 2));
      expect(
        injector.notices.single.$1,
        'Reload is waiting for the debugger to resume.',
      );
      fa.elapse(const Duration(seconds: 30));
      expect(injector.notices, hasLength(1));
      injector.ok(0);
      fa.flushMicrotasks();
    });
  });

  test('no waiting notice when the response is fast', () {
    fakeAsync((fa) {
      setUpHot();
      hot.reload();
      fa.flushMicrotasks();
      injector.ok(0);
      fa.flushMicrotasks();
      fa.elapse(const Duration(seconds: 10));
      expect(injector.notices, isEmpty);
    });
  });

  test('adapter failure: error notice with the restart hint', () {
    fakeAsync((fa) {
      setUpHot();
      HotResult? r;
      hot.reload().then((v) => r = v);
      fa.flushMicrotasks();
      injector.fail(0, 'Some compile error.');
      fa.flushMicrotasks();
      expect(r!.error, HotError.adapterError);
      expect(r!.message, 'Some compile error');
      expect(injector.notices.single.$2, NoticeLevel.error);
      expect(
        injector.notices.single.$1,
        'Hot reload failed: Some compile error. Try the task "Flutter: Hot Restart".',
      );
    });
  });

  test('"not supported" gets the web hint', () {
    fakeAsync((fa) {
      setUpHot();
      hot.reload();
      fa.flushMicrotasks();
      injector.fail(0, 'Hot reload is not supported by this device');
      fa.flushMicrotasks();
      expect(
        injector.notices.single.$1,
        'Hot reload is not supported here. Try the task "Flutter: Hot Restart" instead.',
      );
    });
  });

  test('restart failure notice', () {
    fakeAsync((fa) {
      setUpHot();
      HotResult? r;
      hot.restart().then((v) => r = v);
      fa.flushMicrotasks();
      injector.fail(0, 'boom');
      fa.flushMicrotasks();
      expect(r!.error, HotError.adapterError);
      expect(injector.notices.single.$1, 'Hot restart failed: boom.');
    });
  });

  test('session ended (StateError) maps to sessionEnded', () {
    fakeAsync((fa) {
      setUpHot();
      HotResult? r;
      hot.reload().then((v) => r = v);
      fa.flushMicrotasks();
      injector.calls[0].c.completeError(StateError('closed'));
      fa.flushMicrotasks();
      expect(r!.error, HotError.sessionEnded);
      expect(hot.busy, isFalse);
    });
  });

  test('an injector TimeoutException maps to timeout', () {
    fakeAsync((fa) {
      setUpHot();
      HotResult? r;
      hot.reload().then((v) => r = v);
      fa.flushMicrotasks();
      injector.calls[0].c.completeError(TimeoutException('x'));
      fa.flushMicrotasks();
      expect(r!.error, HotError.timeout);
    });
  });

  test('a save-triggered reload does not time out while paused', () {
    fakeAsync((fa) {
      setUpHot(timeout: const Duration(seconds: 10));
      HotResult? r;
      hot.reload(reason: 'save').then((v) => r = v);
      fa.flushMicrotasks();
      fa.elapse(const Duration(minutes: 5));
      expect(r, isNull);
      expect(hot.busy, isTrue);
      injector.ok(0);
      fa.flushMicrotasks();
      expect(r!.ok, isTrue);
    });
  });

  test('a save reload joining a running reload reports coalesced', () {
    fakeAsync((fa) {
      setUpHot();
      hot.reload();
      fa.flushMicrotasks();
      HotResult? r;
      hot.reload(reason: 'save').then((v) => r = v);
      fa.flushMicrotasks();
      injector.ok(0);
      fa.flushMicrotasks();
      expect(r!.coalesced, isTrue);
    });
  });
}
