import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_run/src/watch/coalescer.dart';
import 'package:test/test.dart';

const _debounce = Duration(milliseconds: 200);

void main() {
  late List<Completer<ReloadResult>> calls;
  late int concurrent;
  late int maxConcurrent;
  late List<Object> errors;
  late Future<ReloadResult> Function() behaviour;

  ReloadCoalescer make() => ReloadCoalescer(
    debounce: _debounce,
    reload: () async {
      concurrent++;
      if (concurrent > maxConcurrent) maxConcurrent = concurrent;
      try {
        return await behaviour();
      } finally {
        concurrent--;
      }
    },
    onError: (e, _) => errors.add(e),
  );

  setUp(() {
    calls = [];
    concurrent = 0;
    maxConcurrent = 0;
    errors = [];
    behaviour = () {
      final c = Completer<ReloadResult>();
      calls.add(c);
      return c.future;
    };
  });

  test('a burst of changes produces one reload after the debounce', () {
    fakeAsync((async) {
      final c = make();
      for (var i = 0; i < 20; i++) {
        c.notifyChange();
        async.elapse(const Duration(milliseconds: 50));
      }
      expect(calls, isEmpty);
      async.elapse(_debounce);
      expect(calls, hasLength(1));
      expect(c.inFlight, isTrue);
      calls.single.complete(ReloadResult.done);
      async.flushMicrotasks();
      expect(c.inFlight, isFalse);
      async.elapse(const Duration(seconds: 5));
      expect(calls, hasLength(1));
    });
  });

  test('each change restarts the debounce', () {
    fakeAsync((async) {
      final c = make()..notifyChange();
      async.elapse(const Duration(milliseconds: 150));
      c.notifyChange();
      async.elapse(const Duration(milliseconds: 150));
      expect(calls, isEmpty);
      async.elapse(const Duration(milliseconds: 60));
      expect(calls, hasLength(1));
    });
  });

  test('changes during a reload cause exactly one follow-up', () {
    fakeAsync((async) {
      final c = make()..notifyChange();
      async.elapse(_debounce);
      expect(calls, hasLength(1));
      for (var i = 0; i < 10; i++) {
        c.notifyChange();
        async.elapse(const Duration(milliseconds: 30));
      }
      expect(calls, hasLength(1));
      calls[0].complete(ReloadResult.done);
      async.flushMicrotasks();
      expect(calls, hasLength(2));
      calls[1].complete(ReloadResult.done);
      async.elapse(const Duration(seconds: 5));
      expect(calls, hasLength(2));
      expect(maxConcurrent, 1);
    });
  });

  test('a failing reload is reported and does not stop the coalescer', () {
    fakeAsync((async) {
      var n = 0;
      behaviour = () async {
        n++;
        if (n == 1) throw StateError('first fails');
        return ReloadResult.done;
      };
      final c = make()..notifyChange();
      async.elapse(_debounce);
      expect(errors, hasLength(1));
      expect(c.inFlight, isFalse);
      c.notifyChange();
      async.elapse(_debounce);
      expect(n, 2);
      expect(errors, hasLength(1));
    });
  });

  test('a failure still runs the queued follow-up', () {
    fakeAsync((async) {
      final c = make()..notifyChange();
      async.elapse(_debounce);
      c.notifyChange();
      calls[0].completeError(StateError('x'));
      async.flushMicrotasks();
      expect(errors, hasLength(1));
      expect(calls, hasLength(2));
    });
  });

  test('busy retries later without an error', () {
    fakeAsync((async) {
      var n = 0;
      behaviour = () async {
        n++;
        return n < 3 ? ReloadResult.busy : ReloadResult.done;
      };
      final c = make()..notifyChange();
      async.elapse(_debounce);
      expect(n, 1);
      expect(c.inFlight, isFalse);
      async.elapse(const Duration(seconds: 10));
      expect(n, 3);
      expect(errors, isEmpty);
      async.elapse(const Duration(seconds: 10));
      expect(n, 3);
    });
  });

  test('a change while waiting to retry restarts the debounce', () {
    fakeAsync((async) {
      var n = 0;
      behaviour = () async => ++n == 1 ? ReloadResult.busy : ReloadResult.done;
      final c = make()..notifyChange();
      async.elapse(_debounce);
      expect(n, 1);
      c.notifyChange();
      async.elapse(_debounce);
      expect(n, 2);
    });
  });

  test('dispose cancels a pending reload', () {
    fakeAsync((async) {
      final c = make()..notifyChange();
      c.dispose();
      async.elapse(const Duration(seconds: 5));
      expect(calls, isEmpty);
      c.notifyChange();
      async.elapse(const Duration(seconds: 5));
      expect(calls, isEmpty);
    });
  });

  test('dispose does not wait for a hanging reload and skips follow-ups', () {
    fakeAsync((async) {
      final c = make()..notifyChange();
      async.elapse(_debounce);
      c.notifyChange();
      var disposed = false;
      c.dispose().then((_) => disposed = true);
      async.flushMicrotasks();
      expect(disposed, isTrue);
      calls[0].complete(ReloadResult.done);
      async.elapse(const Duration(seconds: 5));
      expect(calls, hasLength(1));
    });
  });

  test(
    'a very slow reload is not an error and keeps exactly one follow-up',
    () {
      fakeAsync((async) {
        final c = make()..notifyChange();
        async.elapse(_debounce);
        for (var i = 0; i < 30; i++) {
          c.notifyChange();
          async.elapse(const Duration(seconds: 30));
        }
        expect(calls, hasLength(1));
        expect(errors, isEmpty);
        expect(c.inFlight, isTrue);
        calls[0].complete(ReloadResult.done);
        async.flushMicrotasks();
        expect(calls, hasLength(2));
        calls[1].complete(ReloadResult.done);
        async.elapse(const Duration(minutes: 1));
        expect(calls, hasLength(2));
        expect(maxConcurrent, 1);
      });
    },
  );

  test('a change in the same turn the reload completes is not dropped', () {
    fakeAsync((async) {
      final c = make()..notifyChange();
      async.elapse(_debounce);
      calls[0].complete(ReloadResult.done);
      c.notifyChange(); // before the completion microtask has run
      async.flushMicrotasks();
      async.elapse(_debounce);
      expect(calls, hasLength(2));
    });
  }, skip: false);
}
