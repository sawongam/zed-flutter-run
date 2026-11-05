import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../common/json_types.dart';
import '../common/logger.dart';
import '../common/version.dart';
import 'control_protocol.dart';

/// Compares two strings in time that depends only on the longer length.
bool constantTimeEquals(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  var diff = x.length ^ y.length;
  final length = max(x.length, y.length);
  for (var i = 0; i < length; i++) {
    final left = i < x.length ? x[i] : 0;
    final right = i < y.length ? y[i] : 0;
    diff |= left ^ right;
  }
  return diff == 0;
}

/// Loopback-only control server: one JSON request line per connection, a
/// token on every request, a fixed command set.
class ControlServer {
  ControlServer._(
    this._server,
    this._control,
    this._logger,
    this._requestLineTimeout,
    this.token,
  );

  /// Maximum number of simultaneously open connections.
  static const int maxConnections = 64;

  /// Maximum number of connections that have not yet sent a full request
  /// line. Keeps a local process from holding every slot with idle sockets.
  ///
  /// Security note: the token is the only credential. It lives in the session
  /// file, and the sessions directory is mode 0700 (POSIX) or under the
  /// per-user profile (Windows), so other users cannot read it. A process of
  /// the same user could read it anyway, so there is nothing further to
  /// defend against; the limits above only keep the port from being stalled.
  static const int maxPendingConnections = 16;

  static Future<ControlServer> start({
    required SessionControl control,
    Logger? logger,
    Duration requestLineTimeout = const Duration(seconds: 3),
    String? tokenOverrideForTests,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final instance = ControlServer._(
      server,
      control,
      logger ?? Logger.silent(),
      requestLineTimeout,
      tokenOverrideForTests ?? _generateToken(),
    );
    server.listen(instance._accept, onError: (Object _) {});
    return instance;
  }

  final ServerSocket _server;
  final SessionControl _control;
  final Logger _logger;
  final Duration _requestLineTimeout;
  final Set<_Connection> _connections = {};
  bool _closed = false;

  /// Base64url (no padding) of 32 random bytes.
  final String token;

  int get port => _server.port;

  /// Connections currently open (for tests and diagnostics).
  int get connectionCount => _connections.length;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final closing = _server.close();
    for (final connection in _connections.toList()) {
      connection.destroy();
    }
    await closing;
  }

  static String _generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  void _accept(Socket socket) {
    if (_closed) {
      socket.destroy();
      return;
    }
    if (_connections.length >= maxConnections ||
        _connections.where((c) => !c.lineDone).length >=
            maxPendingConnections) {
      unawaited(_rejectBusy(socket));
      return;
    }
    final connection = _Connection(this, socket);
    _connections.add(connection);
    connection.start();
  }

  Future<void> _rejectBusy(Socket socket) async {
    try {
      socket.add(
        utf8.encode(
          '${jsonEncode({
            'v': controlProtocolVersion,
            'id': null,
            'ok': false,
            'error': {'code': ControlErrorCode.busy.wire, 'message': 'The session has too many open connections.'},
          })}\n',
        ),
      );
      await socket.flush().timeout(const Duration(seconds: 1));
      // Half-close and drain instead of destroying: a client that already
      // sent its request would otherwise get a reset (Windows) that discards
      // the busy reply.
      final closed = Completer<void>();
      socket.listen(
        (_) {},
        onError: (Object _) {
          if (!closed.isCompleted) closed.complete();
        },
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
        cancelOnError: true,
      );
      await socket.close().timeout(const Duration(seconds: 1));
      await closed.future.timeout(const Duration(seconds: 2));
    } on Object {
      // Best effort.
    } finally {
      socket.destroy();
    }
  }

  Future<Json> _dispatch(String command, Json args) async {
    switch (command) {
      case 'ping':
        return _control.ping();
      case 'reload':
        return _control.reload(args);
      case 'restart':
        return _control.restart(args);
    }
    throw ControlException(
      ControlErrorCode.unknownCommand,
      'Unknown command "$command".',
    );
  }
}

class _Connection {
  _Connection(this._owner, this._socket);

  final ControlServer _owner;
  final Socket _socket;
  final BytesBuilder _line = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? _subscription;
  Timer? _lineTimer;
  Timer? _graceTimer;
  bool _lineDone = false;
  bool get lineDone => _lineDone;
  bool _responded = false;
  bool _destroyed = false;

  void start() {
    _lineTimer = Timer(_owner._requestLineTimeout, () {
      _owner._logger.debug('control: closing a connection that sent no line');
      destroy();
    });
    _subscription = _socket.listen(
      _onData,
      onError: (Object _) => destroy(),
      onDone: _onDone,
      cancelOnError: true,
    );
  }

  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _lineTimer?.cancel();
    _graceTimer?.cancel();
    _subscription?.cancel();
    _socket.destroy();
    _owner._connections.remove(this);
  }

  void _onDone() {
    // The client closed its side. Before the line is complete there is
    // nothing to answer; afterwards the response is still written.
    if (!_lineDone || _responded) destroy();
  }

  void _onData(Uint8List chunk) {
    if (_lineDone) return; // One request per connection; ignore the rest.
    final newline = chunk.indexOf(10);
    final end = newline < 0 ? chunk.length : newline;
    if (_line.length + end > maxControlLineBytes) {
      _lineDone = true;
      _lineTimer?.cancel();
      unawaited(
        _respond(
          null,
          error: const ControlException(
            ControlErrorCode.payloadTooLarge,
            'The request is larger than 65536 bytes.',
          ),
        ),
      );
      return;
    }
    _line.add(Uint8List.sublistView(chunk, 0, end));
    if (newline >= 0) {
      _lineDone = true;
      _lineTimer?.cancel();
      unawaited(_handle(_line.takeBytes()));
    }
  }

  Future<void> _handle(Uint8List bytes) async {
    Object? id;
    try {
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes));
      } on FormatException {
        throw const ControlException(
          ControlErrorCode.badRequest,
          'The request is not valid JSON.',
        );
      }
      if (decoded is! Map<String, Object?>) {
        throw const ControlException(
          ControlErrorCode.badRequest,
          'The request must be a JSON object.',
        );
      }
      final token = decoded['token'];
      if (token is! String || !constantTimeEquals(token, _owner.token)) {
        throw const ControlException(
          ControlErrorCode.unauthorized,
          'The token is missing or wrong.',
        );
      }
      final rawId = decoded['id'];
      if (rawId == null || rawId is int || rawId is String) id = rawId;
      if (rawId != null && rawId is! int && rawId is! String) {
        throw const ControlException(
          ControlErrorCode.badRequest,
          '"id" must be a number or a string.',
        );
      }
      final version = decoded['v'];
      if (version is! int) {
        throw const ControlException(
          ControlErrorCode.badRequest,
          '"v" must be an integer.',
        );
      }
      if (version != controlProtocolVersion) {
        throw ControlException(
          ControlErrorCode.unsupportedVersion,
          'Protocol version $version is not supported; use '
          '$controlProtocolVersion.',
        );
      }
      final command = decoded['command'];
      if (command is! String) {
        throw const ControlException(
          ControlErrorCode.badRequest,
          '"command" must be a string.',
        );
      }
      if (!controlCommands.contains(command)) {
        throw ControlException(
          ControlErrorCode.unknownCommand,
          'Unknown command "$command".',
        );
      }
      final rawArgs = decoded['args'];
      if (rawArgs != null && rawArgs is! Map<String, Object?>) {
        throw const ControlException(
          ControlErrorCode.badRequest,
          '"args" must be an object.',
        );
      }
      final args = rawArgs == null
          ? <String, Object?>{}
          : Map<String, Object?>.of(rawArgs as Map<String, Object?>);
      final result = await _owner._dispatch(command, args);
      _owner._logger.debug('control: $command ok');
      await _respond(id, result: result);
    } on ControlException catch (e) {
      _owner._logger.debug('control: rejected (${e.code.wire})');
      await _respond(id, error: e);
    } on Object catch (e, st) {
      _owner._logger.error('control: handler failed', e, st);
      await _respond(
        id,
        error: const ControlException(
          ControlErrorCode.internal,
          'The session failed to handle the request.',
        ),
      );
    }
  }

  Future<void> _respond(
    Object? id, {
    Json? result,
    ControlException? error,
  }) async {
    if (_responded || _destroyed) return;
    _responded = true;
    final body = <String, Object?>{
      'v': controlProtocolVersion,
      'id': id,
      if (error == null) ...{
        'ok': true,
        'result': result ?? <String, Object?>{},
      } else ...{
        'ok': false,
        'error': {'code': error.code.wire, 'message': error.message},
      },
    };
    try {
      _socket.add(utf8.encode('${jsonEncode(body)}\n'));
      await _socket.flush();
      // Half-close and keep draining, so a client that is still sending does
      // not get a reset that would discard our answer.
      _graceTimer = Timer(const Duration(seconds: 2), destroy);
      await _socket.close();
    } on Object {
      destroy();
    }
  }
}
