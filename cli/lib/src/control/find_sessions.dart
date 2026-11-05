import '../common/host_environment.dart';
import '../common/paths.dart';
import 'session_matcher.dart';
import 'session_store.dart';

/// Live sessions (stale files are pruned) whose project matches [directory],
/// oldest first. Unresponsive sessions are included; check
/// [SessionRecord.unresponsive].
Future<List<SessionRecord>> findSessionsFor(
  SessionStore store,
  String directory,
  HostEnvironment env,
) async {
  final all = await store.list();
  return matchSessions<SessionRecord>(
    all,
    (r) => r.info.projectRoot,
    canonicalDirectory(directory, env),
    env,
  );
}
