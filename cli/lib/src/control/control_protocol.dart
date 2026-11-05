import '../common/json_types.dart';

enum ControlErrorCode {
  badRequest('bad_request'),
  unsupportedVersion('unsupported_version'),
  unauthorized('unauthorized'),
  payloadTooLarge('payload_too_large'),
  unknownCommand('unknown_command'),
  appNotStarted('app_not_started'),
  busy('busy'),
  adapterError('adapter_error'),
  timeout('timeout'),
  sessionEnded('session_ended'),
  internal('internal');

  const ControlErrorCode(this.wire);

  /// The value used in the JSON protocol.
  final String wire;

  /// Null when [wire] is not a known code.
  static ControlErrorCode? fromWire(String? wire) {
    for (final code in values) {
      if (code.wire == wire) return code;
    }
    return null;
  }
}

/// Thrown by a [SessionControl] to answer with a protocol error.
class ControlException implements Exception {
  const ControlException(this.code, this.message);

  final ControlErrorCode code;
  final String message;

  @override
  String toString() => 'ControlException(${code.wire}): $message';
}

/// Longest accepted request line (without the newline).
const int maxControlLineBytes = 64 * 1024;

/// The fixed set of commands the server understands.
const Set<String> controlCommands = {'ping', 'reload', 'restart'};

/// Implemented by the composition root on top of the DAP proxy.
abstract interface class SessionControl {
  /// Throws [ControlException].
  Future<Json> reload(Json args);

  /// Throws [ControlException].
  Future<Json> restart(Json args);

  Json ping();
}
