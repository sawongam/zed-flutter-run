import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// A DAP message as decoded JSON.
typedef Msg = Map<String, Object?>;

/// Initial `Content-Length` framing decoder (kept independent of the code
/// under test).
class _Decoder {
  final List<int> _buf = [];

  List<Msg> add(List<int> chunk) {
    _buf.addAll(chunk);
    final out = <Msg>[];
    while (true) {
      final end = _indexOfHeaderEnd();
      if (end < 0) break;
      final header = ascii.decode(_buf.sublist(0, end), allowInvalid: true);
      final match = RegExp(
        r'content-length:\s*(\d+)',
        caseSensitive: false,
      ).firstMatch(header);
      if (match == null) {
        throw StateError('Frame without Content-Length: $header');
      }
      final length = int.parse(match.group(1)!);
      final start = end + 4;
      if (_buf.length < start + length) break;
      final body = utf8.decode(_buf.sublist(start, start + length));
      _buf.removeRange(0, start + length);
      out.add((jsonDecode(body) as Map).cast<String, Object?>());
    }
    return out;
  }

  int _indexOfHeaderEnd() {
    for (var i = 0; i + 3 < _buf.length; i++) {
      if (_buf[i] == 13 &&
          _buf[i + 1] == 10 &&
          _buf[i + 2] == 13 &&
          _buf[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }
}

class _Waiter {
  _Waiter(this.test, this.from);
  final bool Function(Msg) test;
  final int from;
  final Completer<Msg> completer = Completer<Msg>();
}

/// Pretends to be Zed: sends Zed's exact `initialize` arguments, numbers its
/// own requests from 1, answers reverse requests with an error and waits for
/// events with explicit timeouts (never sleeps).
class FakeDapClient {
  FakeDapClient(Stream<List<int>> fromProxy, this._toProxy, this._context) {
    _sub = fromProxy.listen(
      (chunk) {
        try {
          for (final m in _decoder.add(chunk)) {
            _onMessage(m);
          }
        } on Object catch (e) {
          _failAll('Could not decode proxy output: $e');
        }
      },
      onDone: () {
        _closed = true;
        _failAll('The proxy closed its stdout.');
      },
      onError: (Object e) => _failAll('proxy stdout error: $e'),
    );
  }

  final IOSink _toProxy;
  final String Function() _context;
  final _Decoder _decoder = _Decoder();
  late final StreamSubscription<List<int>> _sub;
  final List<String> _transcript = [];
  final Map<int, Completer<Msg>> _responses = {};
  final List<_Waiter> _waiters = [];
  final StreamController<Msg> _eventController = StreamController.broadcast(
    sync: true,
  );
  int _seq = 1;
  bool _closed = false;
  final Stopwatch _clock = Stopwatch()..start();

  /// All events received so far, in order.
  final List<Msg> events = [];

  /// Text of all `output` events received so far, in order.
  final List<String> outputs = [];

  /// Categories matching [outputs].
  final List<String?> outputCategories = [];
  final List<int> _outputEventIndex = [];

  /// Every response, by `request_seq`.
  final Map<int, Msg> responses = {};

  bool get closed => _closed;

  Stream<Msg> get eventStream => _eventController.stream;

  int get eventMark => events.length;
  int get outputMark => outputs.length;

  /// The last 50 messages in both directions plus proxy stderr.
  String describe() {
    final tail = _transcript.length > 50
        ? _transcript.sublist(_transcript.length - 50)
        : _transcript;
    return '--- last ${tail.length} DAP messages (C = fake client, P = proxy) ---\n'
        '${tail.join('\n')}\n--- proxy ---\n${_context()}';
  }

  void _log(String dir, Msg m) {
    // Hundreds of these per launch; they only bury the useful lines.
    final event = m['event'];
    if (event is String && event.startsWith('dart.service')) return;
    final text = jsonEncode(m);
    _transcript.add(
      '[${_clock.elapsedMilliseconds.toString().padLeft(6)}ms] $dir '
      '${text.length > 600 ? '${text.substring(0, 600)}...' : text}',
    );
  }

  void _onMessage(Msg m) {
    _log('P>C', m);
    switch (m['type']) {
      case 'response':
        final seq = m['request_seq'];
        if (seq is int) {
          responses[seq] = m;
          _responses.remove(seq)?.complete(m);
        }
      case 'event':
        events.add(m);
        if (m['event'] == 'output') {
          final body = m['body'];
          if (body is Map) {
            _outputEventIndex.add(events.length - 1);
            outputs.add('${body['output']}');
            outputCategories.add(body['category'] as String?);
          }
        }
        _eventController.add(m);
        for (final w in List.of(_waiters)) {
          if (!w.completer.isCompleted && w.test(m)) {
            _waiters.remove(w);
            w.completer.complete(m);
          }
        }
      case 'request':
        // Zed answers only runInTerminal / startDebugging; we refuse both.
        _send(<String, Object?>{
          'seq': _seq++,
          'type': 'response',
          'request_seq': m['seq'],
          'success': false,
          'command': m['command'],
          'message': 'The test client does not support ${m['command']}.',
        });
    }
  }

  void _failAll(String why) {
    for (final c in _responses.values) {
      if (!c.isCompleted) c.completeError(StateError(why));
    }
    _responses.clear();
    for (final w in _waiters) {
      if (!w.completer.isCompleted) w.completer.completeError(StateError(why));
    }
    _waiters.clear();
  }

  void _send(Msg m) {
    _log('C>P', m);
    final body = utf8.encode(jsonEncode(m));
    try {
      _toProxy
        ..add(ascii.encode('Content-Length: ${body.length}\r\n\r\n'))
        ..add(body);
    } on Object catch (_) {
      // The proxy may already be gone; the waiters report that.
    }
  }

  /// Sends a request and returns the future of its response (never throws on
  /// `success: false`).
  Future<Msg> request(String command, [Msg? arguments]) {
    final seq = _seq++;
    final c = Completer<Msg>();
    _responses[seq] = c;
    _send(<String, Object?>{
      'seq': seq,
      'type': 'request',
      'command': command,
      'arguments': ?arguments,
    });
    return c.future;
  }

  /// Sends a request, waits for the response and requires `success: true`.
  Future<Msg> call(
    String command, [
    Msg? arguments,
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    final response = await request(command, arguments).timeout(
      timeout,
      onTimeout: () => fail(
        'Timed out after ${timeout.inSeconds} s waiting for the response to '
        '"$command".\n${describe()}',
      ),
    );
    if (response['success'] != true) {
      fail('"$command" failed: ${jsonEncode(response)}\n${describe()}');
    }
    return response;
  }

  /// Zed's exact `initialize` arguments (zed-dap-client-behaviour Q3).
  Future<Msg> initialize({String adapterId = 'FlutterRun'}) =>
      call('initialize', {
        'clientID': 'zed',
        'clientName': 'Zed',
        'adapterID': adapterId,
        'locale': 'en-US',
        'pathFormat': 'path',
        'linesStartAt1': true,
        'columnsStartAt1': true,
        'supportsVariableType': true,
        'supportsVariablePaging': false,
        'supportsRunInTerminalRequest': true,
        'supportsStartDebuggingRequest': true,
        'supportsMemoryReferences': true,
        'supportsProgressReporting': false,
        'supportsInvalidatedEvent': false,
        'supportsMemoryEvent': false,
        'supportsArgsCanBeInterpretedByShell': false,
        'supportsANSIStyling': true,
      });

  /// Waits for an event matching [test] at or after event index [from].
  Future<Msg> waitForEvent(
    bool Function(Msg) test, {
    int from = 0,
    required Duration timeout,
    required String what,
  }) {
    for (var i = from; i < events.length; i++) {
      if (test(events[i])) return Future.value(events[i]);
    }
    final w = _Waiter(test, from);
    _waiters.add(w);
    return w.completer.future
        .timeout(
          timeout,
          onTimeout: () {
            _waiters.remove(w);
            fail(
              'Timed out after ${timeout.inSeconds} s waiting for $what.\n'
              '${describe()}',
            );
          },
        )
        .catchError((Object e) {
          if (e is TestFailure) throw e;
          fail('While waiting for $what: $e\n${describe()}');
        });
  }

  Future<Msg> waitForEventNamed(
    String name, {
    int from = 0,
    Duration timeout = const Duration(seconds: 60),
  }) => waitForEvent(
    (e) => e['event'] == name,
    from: from,
    timeout: timeout,
    what: 'the "$name" event',
  );

  Future<Msg> waitForStopped({
    int from = 0,
    String reason = 'breakpoint',
    Duration timeout = const Duration(seconds: 180),
  }) => waitForEvent(
    (e) => e['event'] == 'stopped' && (e['body'] as Map)['reason'] == reason,
    from: from,
    timeout: timeout,
    what: 'a stopped event (reason $reason)',
  );

  /// Waits for an `output` event whose text contains [needle], starting at
  /// output index [from]; returns its index.
  Future<int> waitForOutput(
    String needle, {
    int from = 0,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    for (var i = from; i < outputs.length; i++) {
      if (outputs[i].contains(needle)) return i;
    }
    final fromEvent = from < _outputEventIndex.length
        ? _outputEventIndex[from]
        : events.length;
    final event = await waitForEvent(
      (e) {
        if (e['event'] != 'output') return false;
        final o = (e['body'] as Map)['output'];
        return o is String && o.contains(needle);
      },
      from: fromEvent,
      timeout: timeout,
      what: 'output containing "$needle"',
    );
    return outputs.indexOf('${(event['body'] as Map)['output']}', from);
  }

  /// Number of outputs at or after [from] containing [needle].
  int countOutputs(String needle, {int from = 0}) => [
    for (var i = from; i < outputs.length; i++)
      if (outputs[i].contains(needle)) i,
  ].length;

  String outputText({int from = 0}) => outputs.sublist(from).join();

  /// Top stack frame of [threadId]: `{name, path, line}`.
  Future<({String name, String? path, int line})> topFrame(int threadId) async {
    final r = await call('stackTrace', {
      'threadId': threadId,
      'startFrame': 0,
      'levels': 5,
    });
    final frames = ((r['body']! as Map)['stackFrames']! as List);
    final top = frames.first as Map;
    final source = top['source'] as Map?;
    return (
      name: '${top['name']}',
      path: source?['path'] as String?,
      line: top['line'] as int,
    );
  }

  Future<void> close() async {
    try {
      await _toProxy.close();
    } on Object catch (_) {}
  }

  Future<void> dispose() async {
    await _sub.cancel();
    await _eventController.close();
  }
}

/// Resumes every breakpoint stop it sees (like a user pressing Continue) and
/// records the top frame of each, so reload/restart tests need not script
/// every stop.
class AutoResume {
  AutoResume(this._client) {
    _sub = _client.eventStream.listen((e) {
      if (e['event'] != 'stopped') return;
      final body = e['body']! as Map;
      if (body['reason'] != 'breakpoint') return;
      final threadId = body['threadId'];
      if (threadId is! int) return;
      _pending.add(_handle(threadId));
    });
  }

  final FakeDapClient _client;
  late final StreamSubscription<Msg> _sub;
  final List<Future<void>> _pending = [];

  /// `path:line` of the top frame at each stop handled so far.
  final List<String> stops = [];

  Future<void> _handle(int threadId) async {
    try {
      final top = await _client.topFrame(threadId);
      stops.add('${top.path}:${top.line}');
      await _client.request('continue', {'threadId': threadId});
    } on Object catch (_) {
      // The session may be ending; the test's own waits report that.
    }
  }

  Future<void> stop() async {
    await _sub.cancel();
    await Future.wait(List.of(_pending));
  }
}
