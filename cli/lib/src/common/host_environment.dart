import 'dart:io';

import 'package:path/path.dart' as p;

enum HostOs { linux, macos, windows }

/// The operating system, environment variables and working directory, passed
/// explicitly so that Windows rules can be tested on any host.
class HostEnvironment {
  HostEnvironment({
    required this.os,
    required Map<String, String> environment,
    required this.currentDirectory,
    String? homeOverride,
  }) : environment = Map<String, String>.unmodifiable(environment),
       _homeOverride = homeOverride;

  factory HostEnvironment.system() => HostEnvironment(
    os: Platform.isWindows
        ? HostOs.windows
        : Platform.isMacOS
        ? HostOs.macos
        : HostOs.linux,
    environment: Platform.environment,
    currentDirectory: Directory.current.path,
  );

  final HostOs os;
  final Map<String, String> environment;
  final String currentDirectory;
  final String? _homeOverride;

  bool get isWindows => os == HostOs.windows;

  /// Windows and macOS file systems are case-insensitive by default.
  bool get pathsCaseInsensitive => os != HostOs.linux;

  /// Looks up an environment variable; case-insensitive on Windows.
  String? env(String name) {
    final exact = environment[name];
    if (exact != null || !isWindows) return exact;
    final lower = name.toLowerCase();
    for (final entry in environment.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }

  /// `HOME` (POSIX) or `USERPROFILE` (Windows), unless overridden.
  String? get home {
    if (_homeOverride != null) return _homeOverride;
    final value = env(isWindows ? 'USERPROFILE' : 'HOME');
    return (value == null || value.isEmpty) ? null : value;
  }

  /// Path rules matching [os], rooted at [currentDirectory].
  p.Context get pathContext => p.Context(
    style: isWindows ? p.Style.windows : p.Style.posix,
    current: currentDirectory,
  );

  HostEnvironment copyWith({
    HostOs? os,
    Map<String, String>? environment,
    String? currentDirectory,
  }) => HostEnvironment(
    os: os ?? this.os,
    environment: environment ?? this.environment,
    currentDirectory: currentDirectory ?? this.currentDirectory,
    homeOverride: _homeOverride,
  );
}
