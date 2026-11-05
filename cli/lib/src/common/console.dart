import 'dart:collection';
import 'dart:io';

/// User-facing CLI output and input. Diagnostics go through `Logger`.
abstract interface class Console {
  void out(String line);
  void err(String line);

  /// True when stdin AND stdout are terminals.
  bool get isInteractive;

  /// True when stdout is a terminal and `NO_COLOR` is unset.
  bool get useColor;

  /// Reads one line; null at end of input.
  Future<String?> readLine();
}

class SystemConsole implements Console {
  SystemConsole({bool? color}) : _color = color;

  final bool? _color;

  @override
  void out(String line) => stdout.writeln(line);

  @override
  void err(String line) => stderr.writeln(line);

  @override
  bool get isInteractive => stdin.hasTerminal && stdout.hasTerminal;

  @override
  bool get useColor {
    final forced = _color;
    if (forced != null) return forced;
    final noColor = Platform.environment['NO_COLOR'];
    return stdout.hasTerminal && (noColor == null || noColor.isEmpty);
  }

  @override
  Future<String?> readLine() async => stdin.readLineSync();
}

/// In-memory console for tests.
class MemoryConsole implements Console {
  MemoryConsole({List<String> input = const [], bool interactive = false})
    : _input = Queue<String>.of(input),
      _interactive = interactive;

  final Queue<String> _input;
  final bool _interactive;
  final List<String> outLines = [];
  final List<String> errLines = [];

  @override
  void out(String line) => outLines.add(line);

  @override
  void err(String line) => errLines.add(line);

  @override
  bool get isInteractive => _interactive;

  @override
  bool get useColor => false;

  @override
  Future<String?> readLine() async =>
      _input.isEmpty ? null : _input.removeFirst();
}
