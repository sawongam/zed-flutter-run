import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_run/src/common/clock.dart';
import 'package:flutter_run/src/dap/injected_requests.dart';
import 'package:flutter_run/src/dap/messages.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  late List<DapJson> sent;
  setUp(() => sent = []);

  Future<DapJson> dispatch(
    InjectedRequests injected,
    String command, {
    Map<String, Object?>? arguments,
    Duration? timeout,
    FakeAsync? async,
  }) => injected.dispatch(
    command,
    arguments,
    timeout,
    clock: async == null ? const SystemClock() : FakeClock(async),
    send: sent.add,
  );

  test('allocates seqs from 1e9 and builds the request message', () {
    final injected = InjectedRequests();
    unawaited(dispatch(injected, 'hotReload', arguments: {'reason': 'manual'}));
    unawaited(dispatch(injected, 'terminate'));
    expect(sent[0], {
      'seq': 1000000000,
      'type': 'request',
      'command': 'hotReload',
      'arguments': {'reason': 'manual'},
    });
    expect(sent[1]['seq'], 1000000001);
    expect(sent[1].containsKey('arguments'), isFalse);
  });

  test('responses to injected requests are consumed and complete', () async {
    final injected = InjectedRequests();
    final future = dispatch(injected, 'hotReload');
    final response = {
      'type': 'response',
      'request_seq': sent.single['seq'],
      'success': true,
    };
    expect(injected.consumeResponse(response), isTrue);
    expect(await future, response);
    expect(injected.consumeResponse(response), isFalse);
  });

  test('client responses and unknown seqs are left alone', () {
    final injected = InjectedRequests();
    unawaited(dispatch(injected, 'x'));
    expect(
      injected.consumeResponse({'type': 'response', 'request_seq': 7}),
      isFalse,
    );
    expect(injected.consumeResponse({'type': 'response'}), isFalse);
  });

  test('a timeout fails the request and its late response is swallowed '
      'once', () {
    fakeAsync((async) {
      final injected = InjectedRequests();
      Object? error;
      dispatch(
        injected,
        'hotReload',
        timeout: const Duration(seconds: 1),
        async: async,
      ).catchError((Object e) {
        error = e;
        return <String, Object?>{};
      });
      async.elapse(const Duration(seconds: 1));
      expect(error, isA<TimeoutException>());
      final late = {'type': 'response', 'request_seq': sent.single['seq']};
      expect(injected.consumeResponse(late), isTrue);
      expect(injected.consumeResponse(late), isFalse);
    });
  });

  test('the late set is bounded to 64', () {
    fakeAsync((async) {
      final injected = InjectedRequests();
      for (var i = 0; i < 70; i++) {
        dispatch(
          injected,
          'x',
          timeout: const Duration(seconds: 1),
          async: async,
        ).ignore();
      }
      async.elapse(const Duration(seconds: 1));
      expect(
        injected.consumeResponse({
          'type': 'response',
          'request_seq': sent.first['seq'],
        }),
        isFalse,
      );
      expect(
        injected.consumeResponse({
          'type': 'response',
          'request_seq': sent.last['seq'],
        }),
        isTrue,
      );
    });
  });

  test(
    'failPending fails waiting requests and swallows their answers',
    () async {
      final injected = InjectedRequests();
      final future = dispatch(injected, 'hotReload');
      injected.failPending(StateError('ended'));
      await expectLater(future, throwsStateError);
      expect(
        injected.consumeResponse({
          'type': 'response',
          'request_seq': sent.single['seq'],
        }),
        isTrue,
      );
    },
  );

  test('client seq at or above the range is flagged', () {
    final injected = InjectedRequests();
    expect(injected.clientSeqCollides({'seq': 1000000000}), isTrue);
    expect(injected.clientSeqCollides({'seq': 999999999}), isFalse);
    expect(injected.clientSeqCollides({'command': 'x'}), isFalse);
  });

  test('synthetic seqs start at 1e9 and are independent', () {
    final injected = InjectedRequests();
    unawaited(dispatch(injected, 'x'));
    expect(injected.nextSyntheticSeq(), 1000000000);
    expect(injected.nextSyntheticSeq(), 1000000001);
  });
}
