import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../common/json_types.dart';
import '../common/version.dart';
import 'control_protocol.dart';
import 'session_info.dart';

/// The answer to one control request.
class ControlResponse {
  const ControlResponse({
    required this.ok,
    this.result,
    this.errorCode,
    this.errorMessage,
  });

  final bool ok;
  final Json? result;
  final ControlErrorCode? errorCode;
  final String? errorMessage;
}

enum PingOutcome {
  /// A session answered the ping.
  alive,

  /// The process is certainly gone: connection refused, the token is
  /// rejected (another process uses the port) or the pid differs. The session
  /// file is left over.
  stale,

  /// Not proven dead: no reply in time, connect timeout, reset, premature
  /// close or a reply that is not the protocol. The file is kept.
  unresponsive,
}

enum ControlClientFailure {
  /// Nothing listens on the port (connection refused).
  refused,

  /// Could not connect for another reason (for example a connect timeout).
  unreachable,

  /// Connected, but no complete reply within the timeout.
  timeout,

  /// The connection failed or closed before a full reply arrived.
  protocol,

  /// A reply arrived but it is not the control protocol (another service
  /// uses the port).
  notProtocol,
}

/// Transport-level failure of [ControlClient.send].
class ControlClientException implements Exception {
  const ControlClientException(this.failure, this.message);

  final ControlClientFailure failure;
  final String message;

  @override
  String toString() => 'ControlClientException(${failure.name}): $message';
}

bool _isRefused(Object e) {
  if (e is! SocketException) return false;
  final code = e.osError?.errorCode;
  // ECONNREFUSED: Linux 111, macOS/BSD 61, Windows WSAECONNREFUSED 10061 or
  // ERROR_CONNECTION_REFUSED 1225 (what Dart reports for loopback).
  return code == 111 || code == 61 || code == 10061 || code == 1225;
}

typedef SocketConnector =
    Future<Socket> Function(String host, int port, Duration timeout);

Future<Socket> _defaultConnector(String host, int port, Duration timeout) =>
    Socket.connect(host, port, timeout: timeout);

/// Windows can take 2 s or more to report a refused loopback connection (the
/// SYN is retried), so a 2 s limit would turn "refused" into a timeout and
/// keep stale session files forever.
final Duration defaultConnectTimeout = Platform.isWindows
    ? const Duration(seconds: 6)
    : const Duration(seconds: 2);

/// Talks to a session's [ControlServer] over loopback.
class ControlClient {
  ControlClient({Duration? connectTimeout, SocketConnector? connector})
    : _connectTimeout = connectTimeout ?? defaultConnectTimeout,
      _connector = connector ?? _defaultConnector;

  final Duration _connectTimeout;
  final SocketConnector _connector;
  int _nextId = 1;

  /// Sends one request and returns the answer. Throws
  /// [ControlClientException] when no protocol answer arrives.
  Future<ControlResponse> send(
    SessionInfo session,
    String command, {
    Json args = const {},
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final id = _nextId++;
    final request = jsonEncode(<String, Object?>{
      'v': controlProtocolVersion,
      'token': session.token,
      'id': id,
      'command': command,
      'args': args,
    });
    final line = await _exchange(session.port, request, timeout);
    return _parse(line);
  }

  Future<PingOutcome> ping(
    SessionInfo session, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final response = await send(session, 'ping', timeout: timeout);
      if (response.ok) {
        final pid = response.result?['pid'];
        if (pid is int && pid != session.pid) return PingOutcome.stale;
        return PingOutcome.alive;
      }
      // A different flutter_run process reuses the port: our token is wrong.
      if (response.errorCode == ControlErrorCode.unauthorized) {
        return PingOutcome.stale;
      }
      return PingOutcome.alive;
    } on ControlClientException catch (e) {
      // A refused connection, or a reply that is not our protocol (another
      // service took the port), proves the proxy is gone. Anything else
      // (connect timeout, reset, premature close, connection cap) may be a
      // live but busy session, so its file is kept.
      return e.failure == ControlClientFailure.refused ||
              e.failure == ControlClientFailure.notProtocol
          ? PingOutcome.stale
          : PingOutcome.unresponsive;
    }
  }

  ControlResponse _parse(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      throw const ControlClientException(
        ControlClientFailure.notProtocol,
        'The reply was not valid JSON.',
      );
    }
    if (decoded is! Map<String, Object?> ||
        decoded['v'] != controlProtocolVersion ||
        decoded['ok'] is! bool) {
      throw const ControlClientException(
        ControlClientFailure.notProtocol,
        'The reply was not a flutter_run control reply.',
      );
    }
    if (decoded['ok'] == true) {
      final result = decoded['result'];
      return ControlResponse(
        ok: true,
        result: result is Map<String, Object?> ? result : <String, Object?>{},
      );
    }
    final error = decoded['error'];
    final code = error is Map<String, Object?>
        ? ControlErrorCode.fromWire(error['code'] as String?)
        : null;
    final message = error is Map<String, Object?>
        ? error['message'] as String?
        : null;
    return ControlResponse(
      ok: false,
      errorCode: code ?? ControlErrorCode.internal,
      errorMessage: message ?? 'The session reported an error.',
    );
  }

  Future<String> _exchange(int port, String request, Duration timeout) async {
    final Socket socket;
    try {
      socket = await _connector('127.0.0.1', port, _connectTimeout);
    } on Object catch (e) {
      throw ControlClientException(
        _isRefused(e)
            ? ControlClientFailure.refused
            : ControlClientFailure.unreachable,
        'Could not connect to port $port: $e',
      );
    }
    final reply = Completer<String>();
    // The connection can fail while the request is still being sent, before
    // anyone awaits the reply (seen on Windows); that must not be unhandled.
    unawaited(reply.future.then((_) {}, onError: (Object _) {}));
    final buffer = BytesBuilder(copy: false);
    final subscription = socket.listen(
      (Uint8List chunk) {
        if (reply.isCompleted) return;
        final newline = chunk.indexOf(10);
        final end = newline < 0 ? chunk.length : newline;
        buffer.add(Uint8List.sublistView(chunk, 0, end));
        if (buffer.length > 4 * maxControlLineBytes) {
          reply.completeError(
            const ControlClientException(
              ControlClientFailure.notProtocol,
              'The reply was too large.',
            ),
          );
        } else if (newline >= 0) {
          try {
            reply.complete(utf8.decode(buffer.takeBytes()));
          } on FormatException {
            reply.completeError(
              const ControlClientException(
                ControlClientFailure.notProtocol,
                'The reply was not valid UTF-8.',
              ),
            );
          }
        }
      },
      onError: (Object e) {
        if (!reply.isCompleted) {
          reply.completeError(
            ControlClientException(
              ControlClientFailure.protocol,
              'The connection failed: $e',
            ),
          );
        }
      },
      onDone: () {
        if (!reply.isCompleted) {
          reply.completeError(
            const ControlClientException(
              ControlClientFailure.protocol,
              'The session closed the connection without a reply.',
            ),
          );
        }
      },
      cancelOnError: true,
    );
    try {
      try {
        socket.add(utf8.encode('$request\n'));
        await socket.flush();
      } on Object catch (e) {
        throw ControlClientException(
          ControlClientFailure.protocol,
          'Could not send the request: $e',
        );
      }
      return await reply.future.timeout(
        timeout,
        onTimeout: () => throw const ControlClientException(
          ControlClientFailure.timeout,
          'The session did not answer in time.',
        ),
      );
    } finally {
      unawaited(subscription.cancel());
      socket.destroy();
    }
  }
}
