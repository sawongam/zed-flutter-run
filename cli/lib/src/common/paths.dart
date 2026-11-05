import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'errors.dart';
import 'host_environment.dart';
import 'version.dart';

/// Absolute, normalised form of [path] without trailing separators. Symlinks
/// are resolved when the directory exists and [env] is the real host OS.
String canonicalDirectory(String path, HostEnvironment env) {
  final ctx = env.pathContext;
  var result = ctx.normalize(ctx.absolute(path));
  final isHost = env.os == HostEnvironment.system().os;
  if (isHost) {
    try {
      if (Directory(result).existsSync()) {
        result = ctx.normalize(Directory(result).resolveSymbolicLinksSync());
      }
    } on FileSystemException {
      // Keep the lexically normalised path.
    }
  }
  return result;
}

/// Key for comparing paths: normalised, absolute, and lower-case where the
/// file system is case-insensitive (Windows and macOS). Purely lexical.
String pathKey(String path, HostEnvironment env) {
  final ctx = env.pathContext;
  final normalized = ctx.normalize(ctx.absolute(path));
  return env.pathsCaseInsensitive ? normalized.toLowerCase() : normalized;
}

bool pathsEqual(String a, String b, HostEnvironment env) =>
    pathKey(a, env) == pathKey(b, env);

/// True when [child] is [parent] or lies inside it.
bool isWithin(String parent, String child, HostEnvironment env) {
  final ctx = env.pathContext;
  final p = pathKey(parent, env);
  final c = pathKey(child, env);
  return p == c || ctx.isWithin(p, c);
}

/// Nearest ancestor (inclusive) of [startDir] that contains `pubspec.yaml`.
String? findProjectRoot(String startDir, HostEnvironment env) {
  final found = findUpwards(startDir, 'pubspec.yaml', env);
  return found == null ? null : env.pathContext.dirname(found);
}

/// Searches [startDir] and its ancestors for [relativePath]; returns the full
/// path of the first hit (files, directories and links count), else null.
String? findUpwards(String startDir, String relativePath, HostEnvironment env) {
  final ctx = env.pathContext;
  var dir = ctx.normalize(ctx.absolute(startDir));
  while (true) {
    final candidate = ctx.join(dir, relativePath);
    if (FileSystemEntity.typeSync(candidate, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return candidate;
    }
    final parent = ctx.dirname(dir);
    if (parent == dir) return null;
    dir = parent;
  }
}

/// First 16 hex characters of sha256([pathKey]).
String projectRootHash(String projectRoot, HostEnvironment env) => sha256
    .convert(utf8.encode(pathKey(projectRoot, env)))
    .toString()
    .substring(0, 16);

/// Searches `PATH` for [name]. On Windows `PATHEXT` is honoured (default
/// `.exe;.bat;.cmd`), in order. [isExecutableFile] is a test seam.
String? findExecutableOnPath(
  String name,
  HostEnvironment env, {
  bool Function(String path)? isExecutableFile,
}) {
  final pathValue = env.env('PATH');
  if (pathValue == null || pathValue.isEmpty || name.isEmpty) return null;
  final ctx = env.pathContext;
  final check = isExecutableFile ?? (path) => _isExecutableFile(path, env);
  final separator = env.isWindows ? ';' : ':';

  var extensions = <String>[''];
  if (env.isWindows) {
    final raw = env.env('PATHEXT');
    final listed = (raw == null || raw.trim().isEmpty ? '.exe;.bat;.cmd' : raw)
        .split(';')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();
    final lowerName = name.toLowerCase();
    final hasKnownExtension = listed.any((e) => lowerName.endsWith(e));
    extensions = hasKnownExtension ? <String>['', ...listed] : listed;
  }

  for (var dir in pathValue.split(separator)) {
    dir = dir.trim();
    if (dir.length >= 2 && dir.startsWith('"') && dir.endsWith('"')) {
      dir = dir.substring(1, dir.length - 1);
    }
    if (dir.isEmpty) continue;
    for (final ext in extensions) {
      final candidate = ctx.join(dir, '$name$ext');
      if (check(candidate)) return candidate;
    }
  }
  return null;
}

bool _isExecutableFile(String path, HostEnvironment env) {
  try {
    final stat = FileStat.statSync(path);
    if (stat.type != FileSystemEntityType.file) return false;
    if (env.isWindows) return true;
    return (stat.mode & 0x49) != 0; // any execute bit
  } on FileSystemException {
    return false;
  }
}

/// Per-user state directory: `$FLUTTER_RUN_STATE_DIR`, else XDG state dir on
/// Linux, `~/Library/Application Support/flutter_run` on macOS and
/// `%LOCALAPPDATA%\flutter_run` on Windows.
String stateBaseDirectory(HostEnvironment env) {
  final ctx = env.pathContext;
  final override = env.env(stateDirEnv);
  if (override != null && override.isNotEmpty) return override;
  final home = env.home;
  switch (env.os) {
    case HostOs.linux:
      final xdg = env.env('XDG_STATE_HOME');
      if (xdg != null && xdg.isNotEmpty) return ctx.join(xdg, toolName);
      if (home != null) return ctx.join(home, '.local', 'state', toolName);
    case HostOs.macos:
      if (home != null) {
        return ctx.join(home, 'Library', 'Application Support', toolName);
      }
    case HostOs.windows:
      final local = env.env('LOCALAPPDATA');
      if (local != null && local.isNotEmpty) return ctx.join(local, toolName);
      if (home != null) return ctx.join(home, 'AppData', 'Local', toolName);
  }
  throw const FlutterRunException(
    'Could not find a folder for flutter_run state files.',
    hint:
        'Set the FLUTTER_RUN_STATE_DIR environment variable to a writable folder.',
  );
}
