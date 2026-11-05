import '../common/host_environment.dart';
import '../common/paths.dart';

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
