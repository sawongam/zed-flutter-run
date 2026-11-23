import '../common/json_types.dart';

/// A decoded DAP message (request, response or event).
typedef DapJson = Map<String, Object?>;

/// DAP commands the proxy reads or sends itself.
abstract final class DapCommands {
  static const String initialize = 'initialize';
  static const String launch = 'launch';
  static const String attach = 'attach';
  static const String restart = 'restart';
  static const String terminate = 'terminate';
  static const String disconnect = 'disconnect';
  static const String hotReload = 'hotReload';
  static const String hotRestart = 'hotRestart';
}

/// DAP events the proxy reads or sends itself.
abstract final class DapEvents {
  static const String output = 'output';
  static const String terminated = 'terminated';
  static const String exited = 'exited';
  static const String thread = 'thread';
  static const String debuggerUris = 'dart.debuggerUris';
  static const String flutterAppStart = 'flutter.appStart';
  static const String flutterAppStarted = 'flutter.appStarted';
}

/// A thin, read-only typed view over a raw DAP message. It wraps the decoded
/// map without copying, so forwarding [raw] sends exactly what was received
/// (unknown fields included).
extension type const DapMessage(DapJson raw) {
  /// The sequence number as sent (normally an `int`; kept untyped because
  /// client numbers are echoed back, never renumbered).
  Object? get seq => raw['seq'];

  static String? _string(Object? v) => v is String ? v : null;

  String? get type => _string(raw['type']);

  String? get command => _string(raw['command']);

  Object? get requestSeq => raw['request_seq'];

  /// True only for an explicit `success: false`.
  bool get failed => raw['success'] == false;

  String? get event => _string(raw['event']);

  /// The `arguments` object, or an empty map when absent or not an object.
  Map<String, Object?> get arguments => _object(raw['arguments']);

  /// The `body` object, or an empty map when absent or not an object.
  Map<String, Object?> get body => _object(raw['body']);

  bool get isRequest => type == 'request';

  bool get isResponse => type == 'response';

  bool get isEvent => type == 'event';

  static Map<String, Object?> _object(Object? value) =>
      value is Map<String, Object?> ? value : const <String, Object?>{};
}

/// Builds a failed response with a user-visible error (`showUser`).
DapJson makeErrorResponse({
  required int requestSeq,
  required String command,
  required String message,
  required int seq,
  int errorId = 1,
}) {
  return makeResponse(
    requestSeq: requestSeq,
    command: command,
    success: false,
    message: message,
    seq: seq,
    body: <String, Object?>{
      'error': <String, Object?>{
        'id': errorId,
        'format': message,
        'showUser': true,
      },
    },
  );
}

/// Builds a DAP response message.
DapJson makeResponse({
  required int requestSeq,
  required String command,
  required bool success,
  String? message,
  Json? body,
  required int seq,
}) {
  return <String, Object?>{
    'seq': seq,
    'type': 'response',
    'request_seq': requestSeq,
    'success': success,
    'command': command,
    'message': ?message,
    'body': ?body,
  };
}

/// Builds an `output` event. The event always has a `body` object.
DapJson makeOutputEvent(
  String text, {
  String category = 'console',
  required int seq,
}) {
  return <String, Object?>{
    'seq': seq,
    'type': 'event',
    'event': 'output',
    'body': <String, Object?>{'category': category, 'output': text},
  };
}
