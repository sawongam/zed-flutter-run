import 'dart:async';

import 'package:flutter_run/src/dap/channel.dart';
import 'package:flutter_run/src/dap/messages.dart';

/// In-memory [DapChannel]. `incoming` feeds `messages`; `sent` records output.
class FakeChannel implements DapChannel {
  FakeChannel({this.onSend});

  final StreamController<DapJson> incoming = StreamController<DapJson>();
  final List<DapJson> sent = [];
  final void Function(DapJson message)? onSend;
  int flushCount = 0;
  bool closed = false;
  bool hangFlush = false;

  @override
  Stream<DapJson> get messages => incoming.stream;

  @override
  void send(DapJson message) {
    sent.add(message);
    onSend?.call(message);
  }

  @override
  Future<void> flush() async {
    flushCount++;
    if (hangFlush) await Completer<void>().future;
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!incoming.isClosed) unawaited(incoming.close());
  }

  Iterable<DapJson> sentWhere(String type, [String? name]) => sent.where(
    (m) =>
        m['type'] == type &&
        (name == null || m['command'] == name || m['event'] == name),
  );

  /// Texts of `output` events.
  List<String> get outputs => sentWhere('event', 'output')
      .map((m) => (m['body']! as Map<String, Object?>)['output']! as String)
      .toList();
}

class FakeAdapter implements AdapterConnection {
  FakeAdapter({void Function(DapJson message)? onSend})
    : fakeChannel = FakeChannel(onSend: onSend);

  final FakeChannel fakeChannel;
  final Completer<int> exit = Completer<int>();
  final StreamController<String> stderrController = StreamController<String>();
  Set<int> descendants = {};
  final List<Set<int>> terminateTreeCalls = [];
  final List<bool> terminateTreeCrashed = [];
  int snapshotCalls = 0;

  @override
  DapChannel get channel => fakeChannel;

  @override
  int get pid => 4242;

  @override
  Future<int> get exitCode => exit.future;

  @override
  Stream<String> get stderrLines => stderrController.stream;

  @override
  Future<Set<int>> snapshotDescendants() async {
    snapshotCalls++;
    return descendants;
  }

  @override
  Future<void> terminateTree({
    Set<int> extraPids = const {},
    bool crashed = false,
  }) async {
    terminateTreeCalls.add(extraPids);
    terminateTreeCrashed.add(crashed);
  }

  /// Messages the proxy sent to the adapter.
  List<DapJson> get received => fakeChannel.sent;

  DapJson lastRequest(String command) => received.lastWhere(
    (m) => m['type'] == 'request' && m['command'] == command,
  );

  bool receivedRequest(String command) =>
      received.any((m) => m['type'] == 'request' && m['command'] == command);

  void emit(DapJson message) => fakeChannel.incoming.add(message);

  void respond(DapJson request, {bool success = true, String? message}) {
    emit({
      'seq': 500 + (request['seq']! as int) % 1000000,
      'type': 'response',
      'request_seq': request['seq'],
      'success': success,
      'command': request['command'],
      'message': ?message,
    });
  }

  void event(String name, [Map<String, Object?> body = const {}]) =>
      emit({'seq': 900, 'type': 'event', 'event': name, 'body': body});

  /// The process ends: stdout closes and the exit code completes.
  void die(int code) {
    if (!fakeChannel.incoming.isClosed) fakeChannel.incoming.close();
    if (!exit.isCompleted) exit.complete(code);
  }
}
