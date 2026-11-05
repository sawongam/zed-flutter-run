import 'dart:async';
import 'dart:io' show IOSink;

import '../common/logger.dart';
import 'framing.dart';
import 'messages.dart';

/// A bidirectional stream of DAP messages.
abstract interface class DapChannel {
  /// Ends when the input closes; a framing problem arrives as a
  /// [DapFramingException] error event followed by the end of the stream.
  Stream<DapJson> get messages;

  void send(DapJson message);

  Future<void> flush();

  Future<void> close();
}

/// A [DapChannel] over raw byte streams (stdio or a child process).
class StreamDapChannel implements DapChannel {
  StreamDapChannel(
    Stream<List<int>> input,
    StreamSink<List<int>> output, {
    Logger? logger,
    String label = '',
  }) : _output = output,
       _logger = logger ?? Logger.silent(),
       _label = label {
    _controller = StreamController<DapJson>(
      onPause: () => _subscription?.pause(),
      onResume: () => _subscription?.resume(),
      onCancel: () => _subscription?.cancel(),
    );
    _subscription = input.listen(
      _onData,
      onError: (Object e, StackTrace st) {
        if (!_controller.isClosed) _controller.addError(e, st);
      },
      onDone: _closeMessages,
      cancelOnError: false,
    );
    final sink = output;
    if (sink is IOSink) {
      // A broken pipe is reported here, asynchronously; without a listener it
      // would surface as an uncaught error.
      sink.done.then<void>(
        (_) => _outputClosed = true,
        onError: (Object e) {
          _outputClosed = true;
          _logger.debug('The $_label channel closed: $e');
        },
      );
    }
  }

  static const Duration _ioTimeout = Duration(seconds: 2);

  final StreamSink<List<int>> _output;
  final Logger _logger;
  final String _label;
  final DapFrameDecoder _decoder = DapFrameDecoder();
  late final StreamController<DapJson> _controller;
  StreamSubscription<List<int>>? _subscription;
  bool _outputClosed = false;

  @override
  Stream<DapJson> get messages => _controller.stream;

  void _onData(List<int> chunk) {
    if (_controller.isClosed) return;
    try {
      for (final message in _decoder.add(chunk)) {
        _logger.dap('$_label<', message);
        _controller.add(message);
      }
    } on DapFramingException catch (e) {
      _controller.addError(e);
      _subscription?.cancel().ignore();
      _closeMessages();
    }
  }

  void _closeMessages() {
    if (!_controller.isClosed) _controller.close().ignore();
  }

  @override
  void send(DapJson message) {
    if (_outputClosed) return;
    final List<int> bytes;
    try {
      bytes = encodeDapMessage(message);
    } on Object catch (e) {
      _logger.error('Dropped a $_label message that could not be encoded', e);
      return;
    }
    _logger.dap('$_label>', message);
    try {
      _output.add(bytes);
    } on Object catch (e) {
      _outputClosed = true;
      _logger.debug('Could not write to the $_label channel: $e');
    }
  }

  @override
  Future<void> flush() async {
    if (_outputClosed) return;
    final output = _output;
    try {
      if (output is IOSink) {
        await output.flush().timeout(_ioTimeout, onTimeout: () {});
      }
    } on Object catch (e) {
      _logger.debug('Could not flush the $_label channel: $e');
    }
  }

  @override
  Future<void> close() async {
    if (!_outputClosed) {
      _outputClosed = true;
      try {
        await _output.close().timeout(_ioTimeout, onTimeout: () {});
      } on Object catch (e) {
        _logger.debug('Could not close the $_label channel: $e');
      }
    }
    _closeMessages();
  }
}

/// What the proxy needs from the adapter child process. The composition root
/// adapts its process wrapper to this interface.
abstract interface class AdapterConnection {
  DapChannel get channel;

  int get pid;

  Future<int> get exitCode;

  /// Already decoded lines; the proxy mirrors and logs them.
  Stream<String> get stderrLines;

  /// POSIX: descendants of the adapter. Windows: just the adapter pid.
  Future<Set<int>> snapshotDescendants();

  /// [crashed]: the adapter died on its own, so [extraPids] may include
  /// reparented processes (shared daemons must be spared).
  Future<void> terminateTree({
    Set<int> extraPids = const {},
    bool crashed = false,
  });
}
