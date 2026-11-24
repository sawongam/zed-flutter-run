import 'dart:collection';
import 'dart:io';

import 'style.dart';

/// User-facing CLI output and input. Diagnostics go through `Logger`.
abstract interface class Console {
  void out(String line);
  void err(String line);

  /// True when stdin AND stdout are terminals.
  bool get isInteractive;

  /// True when stdout gets colour (see [colorWanted]).
  bool get useColor;

  /// Styling for text written with [out].
  Style get style;

  /// Styling for text written with [err]. Stderr can be a terminal while
  /// stdout is a pipe, so it is decided on its own.
  Style get errStyle;

  /// Reads one line; null at end of input.
  Future<String?> readLine();
}

class SystemConsole implements Console {
  SystemConsole({this._color});

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
    return colorWanted(
      isTerminal: stdout.hasTerminal,
      environment: Platform.environment,
    );
  }

  @override
  Style get style => Style(useColor);

  @override
  Style get errStyle => Style(
    _color ??
        colorWanted(
          isTerminal: stderr.hasTerminal,
          environment: Platform.environment,
        ),
  );

  @override
  Future<String?> readLine() async => stdin.readLineSync();
}

/// In-memory console for tests.
class MemoryConsole implements Console {
  MemoryConsole({
    List<String> input = const [],
    this._interactive = false,
    this._color = false,
  }) : _input = Queue<String>.of(input);

  final Queue<String> _input;
  final bool _interactive;
  final bool _color;
  final List<String> outLines = [];
  final List<String> errLines = [];

  @override
  void out(String line) => outLines.add(line);

  @override
  void err(String line) => errLines.add(line);

  @override
  bool get isInteractive => _interactive;

  @override
  bool get useColor => _color;

  @override
  Style get style => Style(_color);

  @override
  Style get errStyle => Style(_color);

  @override
  Future<String?> readLine() async =>
      _input.isEmpty ? null : _input.removeFirst();
}
