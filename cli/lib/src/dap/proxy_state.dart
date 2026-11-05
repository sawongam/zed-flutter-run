import 'launch_rewriter.dart';

/// Immutable snapshot of what the proxy has observed about the session.
class ProxyState {
  const ProxyState({
    required this.request,
    required this.kind,
    required this.cwd,
    this.deviceId,
    this.mode,
    this.appId,
    this.vmServiceUri,
    this.appStarted = false,
    this.ended = false,
  });

  /// `launch` until the client's `launch`/`attach` request is seen.
  final String request;
  final DapKind kind;
  final String cwd;
  final String? deviceId;
  final String? mode;
  final String? appId;
  final String? vmServiceUri;
  final bool appStarted;
  final bool ended;

  ProxyState copyWith({
    String? request,
    String? deviceId,
    String? mode,
    String? appId,
    String? vmServiceUri,
    bool? appStarted,
    bool? ended,
  }) {
    return ProxyState(
      request: request ?? this.request,
      kind: kind,
      cwd: cwd,
      deviceId: deviceId ?? this.deviceId,
      mode: mode ?? this.mode,
      appId: appId ?? this.appId,
      vmServiceUri: vmServiceUri ?? this.vmServiceUri,
      appStarted: appStarted ?? this.appStarted,
      ended: ended ?? this.ended,
    );
  }
}

sealed class ProxyEvent {}

class LaunchRewritten extends ProxyEvent {
  LaunchRewritten(this.request, this.result);

  final String request;
  final RewriteResult result;
}

class StateChanged extends ProxyEvent {
  StateChanged(this.state);

  final ProxyState state;
}

class DebuggerUris extends ProxyEvent {
  DebuggerUris(this.vmServiceUri, {required this.isFirst});

  final String vmServiceUri;
  final bool isFirst;
}

class AppStarted extends ProxyEvent {}

class SessionEnded extends ProxyEvent {}
