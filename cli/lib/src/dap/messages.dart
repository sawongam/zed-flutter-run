import '../common/json_types.dart';

/// A decoded DAP message (request, response or event).
typedef DapJson = Map<String, Object?>;

bool isRequest(DapJson m) => m['type'] == 'request';

bool isResponse(DapJson m) => m['type'] == 'response';

bool isEvent(DapJson m) => m['type'] == 'event';

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
