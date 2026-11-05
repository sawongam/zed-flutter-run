import 'dart:convert';
import 'dart:io';

enum LogLevel { error, warn, info, debug, trace }

/// Diagnostic logger. Writes to stderr (or an injected sink) and optionally a
/// log file; never to stdout.
///
/// The file sink always receives `debug` and above (and `trace` when [level]
/// is `trace`), plus DAP traffic from [dap].
class Logger {
  Logger({
    LogLevel level = LogLevel.info,
    IOSink? stderrSink,
    String? logFilePath,
    DateTime Function()? clock,
  }) : _level = level,
       _clock = clock ?? DateTime.now,
       _stderr = stderrSink ?? stderr {
    if (logFilePath != null && logFilePath.isNotEmpty) {
      final problem = _openLogFile(logFilePath);
      if (problem != null) {
        _stderr?.writeln(
          _format(
            LogLevel.warn,
            'Warning: the log file $logFilePath is not used: $problem',
          ),
        );
      }
    }
  }

  Logger._base(this._level) : _clock = DateTime.now;

  factory Logger.silent() = _SilentLogger;

  /// Collects formatted lines into [sink]; for tests.
  factory Logger.capturing(
    List<String> sink, {
    LogLevel level = LogLevel.trace,
  }) => _CapturingLogger(sink, level: level);

  final LogLevel _level;
  final DateTime Function() _clock;
  IOSink? _stderr;
  IOSink? _file;

  LogLevel get level => _level;

  /// Opens [path] for appending, owner-only. Returns a reason when refused.
  String? _openLogFile(String path) {
    if (!path.toLowerCase().endsWith('.log')) {
      return 'its name must end in .log.';
    }
    try {
      final file = File(path);
      if (!file.parent.existsSync()) {
        return 'its folder does not exist.';
      }
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        return 'it is not a regular file.';
      }
      if (type == FileSystemEntityType.notFound) file.createSync();
      if (!Platform.isWindows) {
        final r = Process.runSync('/bin/chmod', ['600', path]);
        if (r.exitCode != 0) {
          return 'it could not be restricted to your user.';
        }
      }
      _file = file.openWrite(mode: FileMode.append);
      return null;
    } on FileSystemException catch (e) {
      return '${e.message}.';
    } on ProcessException catch (e) {
      return '${e.message}.';
    }
  }

  void error(String m, [Object? error, StackTrace? st]) {
    final buffer = StringBuffer(m);
    if (error != null) buffer.write(': $error');
    if (st != null && _level.index >= LogLevel.debug.index) {
      buffer
        ..writeln()
        ..write(st);
    }
    _log(LogLevel.error, buffer.toString());
  }

  void warn(String m) => _log(LogLevel.warn, m);
  void info(String m) => _log(LogLevel.info, m);
  void debug(String m) => _log(LogLevel.debug, m);
  void trace(String m) => _log(LogLevel.trace, m);

  /// File-only DAP traffic line; [direction] is `C>A`, `A>C`, `INJ` or `SYN`.
  void dap(String direction, Object? message) {
    final file = _file;
    if (file == null) return;
    final text = _dapText(message);
    _writeFile(_format(LogLevel.trace, '$direction $text'));
  }

  Future<void> close() async {
    final file = _file;
    _file = null;
    if (file != null) {
      await file.flush();
      await file.close();
    }
  }

  static LogLevel levelFromName(
    String? name, {
    LogLevel fallback = LogLevel.info,
  }) {
    switch (name?.trim().toLowerCase()) {
      case 'error':
        return LogLevel.error;
      case 'warn':
      case 'warning':
        return LogLevel.warn;
      case 'info':
        return LogLevel.info;
      case 'debug':
        return LogLevel.debug;
      case 'trace':
        return LogLevel.trace;
    }
    return fallback;
  }

  void _log(LogLevel at, String message) {
    final line = _format(at, message);
    if (at.index <= _level.index) _writeStderr(line);
    final fileThreshold = _level.index > LogLevel.debug.index
        ? _level.index
        : LogLevel.debug.index;
    if (at.index <= fileThreshold) _writeFile(line);
  }

  String _format(LogLevel at, String message) {
    final t = _clock();
    String two(int n) => n.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    final stamp = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.$ms';
    return '$stamp ${at.name.toUpperCase()} ${_escape(message)}';
  }

  /// Escapes control characters so a line can never start a new line.
  static String _escape(String m) =>
      m.replaceAllMapped(RegExp(r'[\x00-\x1f\x7f]'), (match) {
        final c = match[0]!.codeUnitAt(0);
        switch (c) {
          case 0x0a:
            return r'\n';
          case 0x0d:
            return r'\r';
          case 0x09:
            return r'\t';
        }
        return '\\x${c.toRadixString(16).padLeft(2, '0')}';
      });

  static String _dapText(Object? message) {
    try {
      return message is String ? message : jsonEncode(message);
    } on Object {
      return '<unprintable message>';
    }
  }

  void _writeStderr(String line) {
    try {
      _stderr?.writeln(line);
    } on Object {
      // Logging must never break the caller (stderr may be closed).
    }
  }

  void _writeFile(String line) {
    try {
      _file?.writeln(line);
    } on Object {
      // Ignore file errors.
    }
  }
}

class _SilentLogger extends Logger {
  _SilentLogger() : super._base(LogLevel.error);

  @override
  void _log(LogLevel at, String message) {}

  @override
  void dap(String direction, Object? message) {}
}

class _CapturingLogger extends Logger {
  _CapturingLogger(this.sink, {LogLevel level = LogLevel.trace})
    : super._base(level);

  final List<String> sink;

  @override
  void _log(LogLevel at, String message) {
    if (at.index <= level.index) sink.add(_format(at, message));
  }

  @override
  void dap(String direction, Object? message) {
    final text = Logger._dapText(message);
    if (level.index >= LogLevel.trace.index) {
      sink.add(_format(LogLevel.trace, '$direction $text'));
    }
  }
}
