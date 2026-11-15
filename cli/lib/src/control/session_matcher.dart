import '../common/host_environment.dart';
import '../common/paths.dart';
import 'session_store.dart';

/// Sessions whose project root contains [directory] or lies inside it
/// (case-insensitive on Windows and macOS). Order is preserved.
List<T> matchSessions<T>(
  List<T> sessions,
  String Function(T) projectRootOf,
  String directory,
  HostEnvironment env,
) => [
  for (final session in sessions)
    if (isWithin(projectRootOf(session), directory, env) ||
        isWithin(directory, projectRootOf(session), env))
      session,
];

/// Live sessions (stale files are pruned) whose project matches [directory],
/// oldest first. Unresponsive sessions are included; check
/// [SessionRecord.unresponsive].
Future<List<SessionRecord>> findSessionsFor(
  SessionStore store,
  String directory,
  HostEnvironment env,
) async => matchSessions<SessionRecord>(
  await store.list(),
  (r) => r.info.projectRoot,
  canonicalDirectory(directory, env),
  env,
);
