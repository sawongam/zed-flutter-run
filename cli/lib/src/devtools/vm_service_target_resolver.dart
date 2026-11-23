import '../common/errors.dart';

/// The running app a DevTools page is opened for.
class VmServiceTarget {
  const VmServiceTarget({
    required this.vmServiceUri,
    this.deviceId,
    required this.sessionPid,
    this.kind,
  });

  final String vmServiceUri;
  final String? deviceId;
  final int sessionPid;

  /// Session kind (`flutter` or `dart`); null when unknown.
  final String? kind;
}

/// Finds the session for [directory] (most recent `startedAt` with a
/// `vmServiceUri`). Throws [NoSessionException] (exit 3) or
/// [SessionRequestException] (exit 4, app still starting).
typedef VmServiceTargetResolver = Future<VmServiceTarget> Function({
  required String directory,
});

/// A running debug session as DevTools needs to know it (supplied by the CLI).
class RunningSession {
  const RunningSession({
    required this.vmServiceUri,
    required this.startedAt,
    required this.pid,
    this.deviceId,
    this.kind,
    this.unresponsive = false,
  });

  /// Null while the app is still starting.
  final String? vmServiceUri;
  final DateTime startedAt;
  final int pid;
  final String? deviceId;
  final String? kind;
  final bool unresponsive;
}

/// The session DevTools should open for: the most recent live session of the
/// directory that already has a VM service address.
VmServiceTargetResolver createVmServiceTargetResolver(
  Future<List<RunningSession>> Function(String directory) findSessions,
) {
  return ({required String directory}) async {
    final all = await findSessions(directory);
    final live = all.where((r) => !r.unresponsive).toList();
    if (live.isEmpty) {
      throw NoSessionException(
        'No running Flutter app found for $directory.',
        hint:
            'Start one from the debugger first (F4 opens the debug '
            'picker in Zed).',
      );
    }
    final withUri = live.where((r) => r.vmServiceUri != null).toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    if (withUri.isEmpty) {
      throw const SessionRequestException(
        'The app is still starting. Try again in a moment.',
      );
    }
    final best = withUri.first;
    return VmServiceTarget(
      vmServiceUri: best.vmServiceUri!,
      deviceId: best.deviceId,
      sessionPid: best.pid,
      kind: best.kind,
    );
  };
}
