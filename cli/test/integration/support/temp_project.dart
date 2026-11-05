import 'dart:io';

import 'package:path/path.dart' as p;

import 'build_exe.dart';

/// Scratch space for one test: a state directory for `FLUTTER_RUN_STATE_DIR`
/// and temp copies of the fixtures. The checked-in fixtures are never used
/// directly.
class TempWorkspace {
  TempWorkspace._(this.root)
    : stateDir = p.join(root.path, 'state'),
      projectsDir = p.join(root.path, 'projects') {
    Directory(stateDir).createSync(recursive: true);
    Directory(projectsDir).createSync(recursive: true);
  }

  /// A fresh workspace under the system temp directory (canonical path).
  static TempWorkspace create() {
    final dir = Directory.systemTemp.createTempSync('frd_it_');
    return TempWorkspace._(Directory(dir.resolveSymbolicLinksSync()));
  }

  final Directory root;
  final String stateDir;
  final String projectsDir;

  String get sessionsDir => p.join(stateDir, 'sessions');

  /// Copies a prepared fixture to `<projects>/<name>` and returns it.
  Future<Directory> copyFixture(
    String fixture, {
    String? name,
    String? under,
  }) async {
    final prepared = await preparedFixture(fixture);
    final dest = Directory(p.join(under ?? projectsDir, name ?? fixture))
      ..createSync(recursive: true);
    copyTree(prepared, dest);
    return Directory(dest.resolveSymbolicLinksSync());
  }

  void dispose() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort; a lingering process may still hold a file on Windows.
    }
  }
}

/// Copies [from] into [to], skipping `build/`.
void copyTree(Directory from, Directory to) {
  for (final entity in from.listSync(followLinks: false)) {
    final name = p.basename(entity.path);
    if (entity is Directory) {
      if (name == 'build') continue;
      final target = Directory(p.join(to.path, name))
        ..createSync(recursive: true);
      copyTree(entity, target);
    } else if (entity is File) {
      if (name == '.prepared') continue;
      entity.copySync(p.join(to.path, name));
    }
  }
}

final Map<String, Future<Directory>> _prepared = {};

/// A copy of `fixtures/<name>` (without `build/`) on which `pub get` ran once
/// in this checkout; per-test copies are made from it.
Future<Directory> preparedFixture(String name) {
  return _prepared.putIfAbsent(name, () => _prepare(name));
}

Future<Directory> _prepare(String name) async {
  final source = Directory(p.join(repoRoot().path, 'fixtures', name));
  if (!source.existsSync()) {
    throw StateError('Fixture ${source.path} does not exist.');
  }
  final dest = Directory(p.join(testCacheDirectory().path, 'prepared', name));
  final stamp = File(p.join(dest.path, '.prepared'));
  final pubspec = File(p.join(source.path, 'pubspec.yaml')).readAsStringSync();
  final lock = File(p.join(source.path, 'pubspec.lock'));
  final key = '$pubspec\n${lock.existsSync() ? lock.readAsStringSync() : ''}';
  if (stamp.existsSync() && stamp.readAsStringSync() == key) return dest;

  if (dest.existsSync()) dest.deleteSync(recursive: true);
  dest.createSync(recursive: true);
  for (final entity in source.listSync(followLinks: false)) {
    final base = p.basename(entity.path);
    if (base == 'build' || base == '.dart_tool') continue;
    if (entity is Directory) {
      final target = Directory(p.join(dest.path, base))
        ..createSync(recursive: true);
      copyTree(entity, target);
    } else if (entity is File) {
      entity.copySync(p.join(dest.path, base));
    }
  }
  final isFlutter =
      pubspec.contains('flutter:') && pubspec.contains('sdk: flutter');
  final tool = isFlutter ? 'flutter' : Platform.resolvedExecutable;
  const args = ['pub', 'get', '--offline'];
  var result = await Process.run(
    tool,
    args,
    workingDirectory: dest.path,
    runInShell: Platform.isWindows,
  );
  if (result.exitCode != 0) {
    // Not in the pub cache yet: allow the network once.
    result = await Process.run(
      tool,
      ['pub', 'get'],
      workingDirectory: dest.path,
      runInShell: Platform.isWindows,
    );
  }
  if (result.exitCode != 0) {
    throw StateError(
      'pub get failed in ${dest.path}:\n${result.stdout}\n${result.stderr}',
    );
  }
  stamp.writeAsStringSync(key);
  return dest;
}

/// 1-based line number of the first line containing `BREAKPOINT_TARGET`.
int breakpointLine(File file) {
  final lines = file.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].contains('BREAKPOINT_TARGET')) return i + 1;
  }
  throw StateError('No BREAKPOINT_TARGET marker in ${file.path}.');
}
