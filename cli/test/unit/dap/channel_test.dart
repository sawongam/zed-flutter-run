import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_run/src/dap/channel.dart';
import 'package:flutter_run/src/dap/framing.dart';
import 'package:test/test.dart';

import 'framing_test.dart' show frame;

void main() {
  test('StreamDapChannel decodes input and encodes output', () async {
    final input = StreamController<List<int>>();
    final output = StreamController<List<int>>();
    final written = <int>[];
    output.stream.listen(written.addAll);
    final channel = StreamDapChannel(input.stream, output.sink);
    final received = <Map<String, Object?>>[];
    channel.messages.listen(received.add);

    input.add(frame({'seq': 1}));
    input.add(frame({'seq': 2}));
    await pumpEventQueue();
    expect(received.map((m) => m['seq']), [1, 2]);

    channel.send({'seq': 5, 'text': 'é'});
    await pumpEventQueue();
    expect(DapFrameDecoder().add(written), [
      {'seq': 5, 'text': 'é'},
    ]);

    await input.close();
    await pumpEventQueue();
    await channel.close();
  });

  test('framing errors arrive as stream errors then the stream ends', () async {
    final input = StreamController<List<int>>();
    final output = StreamController<List<int>>();
    final channel = StreamDapChannel(input.stream, output.sink);
    final errors = <Object>[];
    var done = false;
    channel.messages.listen(
      (_) {},
      onError: errors.add,
      onDone: () => done = true,
    );
    input.add('Content-Length: x\r\n\r\n'.codeUnits);
    await pumpEventQueue();
    expect(errors.single, isA<DapFramingException>());
    expect(done, isTrue);
  });

  test('send after the output closed does not throw', () async {
    final input = StreamController<List<int>>();
    final output = StreamController<List<int>>();
    output.stream.listen((_) {});
    final channel = StreamDapChannel(input.stream, output.sink);
    await channel.close();
    channel.send({'seq': 1});
    await channel.flush();
  });

  test(
    'C1/C3: a sink that fails with a broken pipe does not hang flush',
    () async {
      final input = StreamController<List<int>>();
      final sink = _BrokenIoSink();
      final channel = StreamDapChannel(input.stream, sink);
      channel.send({'seq': 1});
      sink.breakPipe();
      await pumpEventQueue();
      await channel.flush().timeout(const Duration(seconds: 1));
      channel.send({'seq': 2});
      expect(sink.written, 1);
    },
  );

  test('C1: a flush that never completes is bounded', () {
    fakeAsync((fa) {
      final input = StreamController<List<int>>();
      final channel = StreamDapChannel(input.stream, _HangingIoSink());
      var done = false;
      channel.flush().then((_) => done = true);
      fa.elapse(const Duration(seconds: 3));
      expect(done, isTrue);
    });
  });

  test(
    'C4: an unencodable message is dropped without closing the channel',
    () async {
      final input = StreamController<List<int>>();
      final output = StreamController<List<int>>();
      final written = <int>[];
      output.stream.listen(written.addAll);
      final channel = StreamDapChannel(input.stream, output.sink);
      channel.send({'seq': 1, 'bad': Object()});
      channel.send({'seq': 2});
      await pumpEventQueue();
      expect(DapFrameDecoder().add(written).map((m) => m['seq']), [2]);
    },
  );
}

class _BrokenIoSink implements IOSink {
  final Completer<void> _done = Completer<void>();
  int written = 0;

  void breakPipe() => _done.completeError(
    const FileSystemException('writeFrom failed: Broken pipe'),
  );

  @override
  Future<void> get done => _done.future;

  @override
  void add(List<int> data) => written++;

  @override
  Future<void> flush() => Completer<void>().future;

  @override
  Future<void> close() => _done.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _HangingIoSink implements IOSink {
  @override
  Future<void> get done => Completer<void>().future;

  @override
  void add(List<int> data) {}

  @override
  Future<void> flush() => Completer<void>().future;

  @override
  Future<void> close() => Completer<void>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
