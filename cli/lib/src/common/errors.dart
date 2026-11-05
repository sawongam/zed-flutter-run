/// Process exit codes (documented in `--help`).
abstract final class ExitCodes {
  static const int ok = 0;
  static const int internal = 1;
  static const int usage = 2;
  static const int noSession = 3;
  static const int sessionError = 4;
  static const int timeout = 5;
  static const int sdkNotFound = 6;
  static const int deviceError = 7;
  static const int projectNotFound = 8;
  static const int manualActionRequired = 9;
  static const int externalToolFailed = 10;
  static const int interrupted = 130;
}

/// An expected failure with a user-facing message and an optional hint
/// (a full sentence that says what to do next).
class FlutterRunException implements Exception {
  const FlutterRunException(
    this.message, {
    this.exitCode = ExitCodes.internal,
    this.hint,
    this.cause,
  });

  final String message;
  final int exitCode;
  final String? hint;
  final Object? cause;

  @override
  String toString() => message;
}

/// Bad flags or arguments (exit 2).
class UsageError extends FlutterRunException {
  const UsageError(super.message, {super.hint})
    : super(exitCode: ExitCodes.usage);
}

/// No Flutter debug session found (exit 3).
class NoSessionException extends FlutterRunException {
  const NoSessionException(super.message, {super.hint})
    : super(exitCode: ExitCodes.noSession);
}

/// A session failed or could not act (exit 4).
class SessionRequestException extends FlutterRunException {
  const SessionRequestException(super.message, {super.hint})
    : super(exitCode: ExitCodes.sessionError);
}

/// A session did not answer in time (exit 5).
class RequestTimeoutException extends FlutterRunException {
  const RequestTimeoutException(super.message, {super.hint})
    : super(exitCode: ExitCodes.timeout);
}

/// Flutter/Dart SDK could not be resolved (exit 6).
class SdkNotFoundException extends FlutterRunException {
  const SdkNotFoundException(
    super.message, {
    this.tried = const <String>[],
    super.hint,
  }) : super(exitCode: ExitCodes.sdkNotFound);

  /// Human-readable descriptions of every location that was tried.
  final List<String> tried;
}

/// No devices or an unknown device id (exit 7).
class DeviceException extends FlutterRunException {
  const DeviceException(super.message, {super.hint})
    : super(exitCode: ExitCodes.deviceError);
}

/// No pubspec.yaml found (exit 8).
class ProjectNotFoundException extends FlutterRunException {
  const ProjectNotFoundException(super.message, {super.hint})
    : super(exitCode: ExitCodes.projectNotFound);
}

/// A file could not be edited safely (exit 9).
class ManualActionRequired extends FlutterRunException {
  const ManualActionRequired(super.message, {super.hint})
    : super(exitCode: ExitCodes.manualActionRequired);
}

/// A `flutter`/`dart`/browser subprocess failed (exit 10).
class ExternalToolException extends FlutterRunException {
  const ExternalToolException(super.message, {super.hint, super.cause})
    : super(exitCode: ExitCodes.externalToolFailed);
}
