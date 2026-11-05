import '../common/json_types.dart';
import '../common/version.dart';

/// What a running `flutter_run dap` process publishes in its session file
/// (schema version 1, see the implementation plan section 4.3).
class SessionInfo {
  const SessionInfo({
    required this.pid,
    required this.port,
    required this.token,
    required this.projectRoot,
    required this.cwd,
    required this.kind,
    required this.request,
    required this.startedAt,
    this.deviceId,
    this.mode,
    this.vmServiceUri,
    this.appStarted = false,
  });

  /// Reads a session file object. Throws [FormatException] when a required
  /// key is missing or mistyped, or when `version` is not
  /// [sessionFileVersion]. Unknown keys are ignored.
  factory SessionInfo.fromJson(Json json) {
    final version = json['version'];
    if (version != sessionFileVersion) {
      throw FormatException('Unsupported session file version: $version.');
    }
    int integer(String key) {
      final value = json[key];
      if (value is int) return value;
      throw FormatException('Session file key "$key" must be an integer.');
    }

    String string(String key) {
      final value = json[key];
      if (value is String) return value;
      throw FormatException('Session file key "$key" must be a string.');
    }

    String? optionalString(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is String) return value;
      throw FormatException('Session file key "$key" must be a string.');
    }

    final appStarted = json['appStarted'];
    if (appStarted != null && appStarted is! bool) {
      throw const FormatException(
        'Session file key "appStarted" must be a boolean.',
      );
    }
    return SessionInfo(
      pid: integer('pid'),
      port: integer('port'),
      token: string('token'),
      projectRoot: string('projectRoot'),
      cwd: string('cwd'),
      kind: string('kind'),
      request: string('request'),
      startedAt: DateTime.parse(string('startedAt')),
      deviceId: optionalString('deviceId'),
      mode: optionalString('mode'),
      vmServiceUri: optionalString('vmServiceUri'),
      appStarted: appStarted == true,
    );
  }

  final int pid;
  final int port;
  final String token;
  final String projectRoot;
  final String cwd;

  /// `flutter` or `dart`.
  final String kind;

  /// `launch` or `attach`.
  final String request;
  final DateTime startedAt;
  final String? deviceId;
  final String? mode;
  final String? vmServiceUri;
  final bool appStarted;

  Json toJson() => <String, Object?>{
    'version': sessionFileVersion,
    'pid': pid,
    'port': port,
    'token': token,
    'projectRoot': projectRoot,
    'cwd': cwd,
    'kind': kind,
    'request': request,
    'startedAt': startedAt.toUtc().toIso8601String(),
    if (deviceId != null) 'deviceId': deviceId,
    if (mode != null) 'mode': mode,
    if (vmServiceUri != null) 'vmServiceUri': vmServiceUri,
    'appStarted': appStarted,
  };

  SessionInfo copyWith({
    int? pid,
    int? port,
    String? token,
    String? projectRoot,
    String? cwd,
    String? kind,
    String? request,
    DateTime? startedAt,
    String? deviceId,
    String? mode,
    String? vmServiceUri,
    bool? appStarted,
  }) => SessionInfo(
    pid: pid ?? this.pid,
    port: port ?? this.port,
    token: token ?? this.token,
    projectRoot: projectRoot ?? this.projectRoot,
    cwd: cwd ?? this.cwd,
    kind: kind ?? this.kind,
    request: request ?? this.request,
    startedAt: startedAt ?? this.startedAt,
    deviceId: deviceId ?? this.deviceId,
    mode: mode ?? this.mode,
    vmServiceUri: vmServiceUri ?? this.vmServiceUri,
    appStarted: appStarted ?? this.appStarted,
  );
}
