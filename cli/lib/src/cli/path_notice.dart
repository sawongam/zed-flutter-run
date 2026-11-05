import '../common/host_environment.dart';

/// How to put [dir] on the PATH, as lines for `init` and `doctor`.
String pathFixHint(HostOs os, String dir) => switch (os) {
  HostOs.windows =>
    'Add this folder to your PATH: $dir\n'
        'Open Settings > System > About > Advanced system settings > '
        'Environment Variables, select Path and add the folder.',
  HostOs.linux || HostOs.macos =>
    'Add this folder to your PATH: $dir\n'
        'In your shell profile (for example ~/.bashrc or ~/.zshrc) add the '
        'line: export PATH="$dir:\$PATH"',
};

String _shortHowTo(HostOs os, String dir) => switch (os) {
  HostOs.windows =>
    'Settings > System > About > Advanced system settings > Environment '
        'Variables > Path',
  HostOs.linux || HostOs.macos =>
    'for example with export PATH="$dir:\$PATH" in your shell profile',
};

const String _tasks =
    'the tasks "Flutter: Hot Reload", "Hot Restart", "Select Device" and '
    '"Open DevTools"';

/// The text of the one-time console notice (shown as a warning) for a
/// `flutter_run` that is not on the PATH (ADR 0006 D1).
///
/// [isCompiledExe] is false when this process runs from source
/// (`dart run`), in which case there is no folder to add to the PATH.
String pathNoticeText(
  HostEnvironment env,
  String resolvedExecutable,
  bool isCompiledExe,
) {
  if (!isCompiledExe) {
    return 'the flutter_run command is not installed, so $_tasks cannot run. '
        'This debug session runs from source ($resolvedExecutable). Install '
        'flutter_run as described in the README section "Install". Hot '
        "restart with Zed's own Rerun Session key still works.";
  }
  final dir = env.pathContext.dirname(resolvedExecutable);
  return 'the flutter_run command is not on your PATH, so $_tasks cannot run. '
      'This debug session is using $resolvedExecutable. Add $dir to your PATH '
      '(${_shortHowTo(env.os, dir)}) and see the README section "Install". '
      "Hot restart with Zed's own Rerun Session key still works.";
}
