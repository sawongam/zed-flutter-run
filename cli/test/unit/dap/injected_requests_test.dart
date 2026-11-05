import 'package:flutter_run/src/dap/injected_requests.dart';
import 'package:test/test.dart';

void main() {
  test('allocates seqs from 1e9 and builds the request message', () {
    final injected = InjectedRequests();
    final a = injected.create('hotReload', {'reason': 'manual'});
    final b = injected.create('terminate', null);
    expect(a.seq, 1000000000);
    expect(b.seq, 1000000001);
    expect(a.message, {
      'seq': 1000000000,
      'type': 'request',
      'command': 'hotReload',
      'arguments': {'reason': 'manual'},
    });
    expect(b.message.containsKey('arguments'), isFalse);
  });

  test('responses to injected requests are consumed and complete', () async {
    final injected = InjectedRequests();
    final a = injected.create('hotReload', null);
    final response = {
      'type': 'response',
      'request_seq': a.seq,
      'success': true,
    };
    expect(injected.consumeResponse(response), isTrue);
    expect(await a.response, response);
    expect(injected.consumeResponse(response), isFalse);
  });

  test('client responses and unknown seqs are left alone', () {
    final injected = InjectedRequests();
    injected.create('x', null);
    expect(
      injected.consumeResponse({'type': 'response', 'request_seq': 7}),
      isFalse,
    );
    expect(injected.consumeResponse({'type': 'response'}), isFalse);
  });

  test('a late response after markTimedOut is swallowed once', () {
    final injected = InjectedRequests();
    final a = injected.create('hotReload', null);
    injected.markTimedOut(a.seq);
    final late = {'type': 'response', 'request_seq': a.seq};
    expect(injected.consumeResponse(late), isTrue);
    expect(injected.consumeResponse(late), isFalse);
  });

  test('the late set is bounded to 64', () {
    final injected = InjectedRequests();
    final seqs = [for (var i = 0; i < 70; i++) injected.create('x', null).seq];
    seqs.forEach(injected.markTimedOut);
    expect(
      injected.consumeResponse({'type': 'response', 'request_seq': seqs.first}),
      isFalse,
    );
    expect(
      injected.consumeResponse({'type': 'response', 'request_seq': seqs.last}),
      isTrue,
    );
  });

  test('client seq at or above the range is flagged', () {
    final injected = InjectedRequests();
    expect(injected.clientSeqCollides({'seq': 1000000000}), isTrue);
    expect(injected.clientSeqCollides({'seq': 999999999}), isFalse);
    expect(injected.clientSeqCollides({'command': 'x'}), isFalse);
  });

  test('synthetic seqs start at 1e9 and are independent', () {
    final injected = InjectedRequests();
    injected.create('x', null);
    expect(injected.nextSyntheticSeq(), 1000000000);
    expect(injected.nextSyntheticSeq(), 1000000001);
  });
}
