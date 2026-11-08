import '../common/logger.dart';
import 'managed_process.dart';
import 'process_spec.dart';

/// Starts external tools; the seam between callers and `Process.start`.
abstract interface class ProcessRunner {
  /// Starts [spec] (never through a shell) and keeps a handle for cleanup.
  Future<ManagedProcess> start(
    ProcessSpec spec, {
    Map<String, String>? environment,
    Logger? logger,
  });

  /// Runs [spec] to completion; on [timeout] the process tree is killed and an
  /// `ExternalToolException` is thrown.
  Future<ToolOutput> run(
    ProcessSpec spec, {
    Map<String, String>? environment,
    Duration timeout,
    Logger? logger,
  });
}

/// Real processes, through [ManagedProcess.start] and [runTool].
class SystemProcessRunner implements ProcessRunner {
  const SystemProcessRunner();

  @override
  Future<ManagedProcess> start(
    ProcessSpec spec, {
    Map<String, String>? environment,
    Logger? logger,
  }) => ManagedProcess.start(spec, environment: environment, logger: logger);

  @override
  Future<ToolOutput> run(
    ProcessSpec spec, {
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 60),
    Logger? logger,
  }) =>
      runTool(spec, environment: environment, timeout: timeout, logger: logger);
}
