import '../common/host_environment.dart';

/// What to start: always the target itself, never a shell.
class ProcessSpec {
  const ProcessSpec(this.executable, this.arguments, {this.workingDirectory});

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
}

/// Device and emulator ids that are safe to pass to a `.bat` target.
final RegExp safeIdPattern = RegExp(r'^[A-Za-z0-9._:\-@]+$');

bool isBatchFile(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.bat') || lower.endsWith('.cmd');
}

const String _unsafeBatchChars = '\n\r"%^&|<>!(),;\u0000';

/// Throws [ArgumentError] when [arg] could be reinterpreted by `cmd.exe`.
void validateBatchArgument(String arg) {
  for (final unit in arg.split('')) {
    if (_unsafeBatchChars.contains(unit) || unit.codeUnitAt(0) < 0x20) {
      final shown = unit == '\n'
          ? r'\n'
          : unit == '\r'
          ? r'\r'
          : unit.codeUnitAt(0) < 0x20
          ? '(control character)'
          : unit;
      throw ArgumentError.value(
        arg,
        'arg',
        'contains "$shown", which cmd.exe would interpret when the target is a .bat file',
      );
    }
  }
  if (arg.endsWith(r'\')) {
    throw ArgumentError.value(
      arg,
      'arg',
      r'ends with a backslash, which cmd.exe would treat as an escape',
    );
  }
}

/// Builds the spec for starting [executable]. For `.bat`/`.cmd` targets on
/// Windows every argument is validated. No shell command string is created.
ProcessSpec buildProcessSpec(
  String executable,
  List<String> args,
  HostEnvironment env,
) {
  if (env.isWindows && isBatchFile(executable)) {
    for (final unit in const ['%', '!', '^']) {
      if (executable.contains(unit)) {
        throw ArgumentError.value(
          executable,
          'executable',
          'contains "$unit", which cmd.exe would interpret in a .bat path',
        );
      }
    }
    args.forEach(validateBatchArgument);
  }
  return ProcessSpec(executable, List<String>.unmodifiable(args));
}
