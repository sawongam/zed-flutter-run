import 'dart:io';

import 'package:path/path.dart' as p;

/// The `cli/` directory (tests run with it as the working directory).
Directory cliDirectory() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 4; i++) {
    final pubspec = File(p.join(dir.path, 'pubspec.yaml'));
    if (pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('name: flutter_run')) {
      return dir;
    }
    dir = dir.parent;
  }
  throw StateError('Run the tests from the cli/ directory.');
}

/// The repository root (parent of `cli/`).
Directory repoRoot() => cliDirectory().parent;

/// Scratch area for compiled binaries and prepared fixture copies.
Directory testCacheDirectory() {
  final dir = Directory(
    p.join(cliDirectory().path, '.dart_tool', 'flutter_run_test'),
  )..createSync(recursive: true);
  return dir;
}

DateTime _newestSource(Directory cli) {
  var newest = DateTime.fromMillisecondsSinceEpoch(0);
  void scan(Directory dir) {
    if (!dir.existsSync()) return;
    for (final e in dir.listSync(recursive: true, followLinks: false)) {
      if (e is File && e.path.endsWith('.dart')) {
        final m = e.lastModifiedSync();
        if (m.isAfter(newest)) newest = m;
      }
    }
  }

  scan(Directory(p.join(cli.path, 'lib')));
  scan(Directory(p.join(cli.path, 'bin')));
  final pubspec = File(p.join(cli.path, 'pubspec.yaml')).lastModifiedSync();
  return pubspec.isAfter(newest) ? pubspec : newest;
}

String? _built;

/// Path of the compiled `flutter_run` executable, built once per run.
///
/// `FLUTTER_RUN_TEST_EXE` overrides it. The build is cached by the newest
/// modification time of `lib/`, `bin/` and `pubspec.yaml`.
Future<String> ensureFlutterRunExe() async {
  final cached = _built;
  if (cached != null) return cached;
  final override = Platform.environment['FLUTTER_RUN_TEST_EXE'];
  if (override != null && override.isNotEmpty) {
    if (!File(override).existsSync()) {
      throw StateError('FLUTTER_RUN_TEST_EXE does not exist: $override');
    }
    return _built = override;
  }
  final cli = cliDirectory();
  final out = p.join(
    testCacheDirectory().path,
    Platform.isWindows ? 'flutter_run.exe' : 'flutter_run',
  );
  final file = File(out);
  if (file.existsSync() &&
      file.lastModifiedSync().isAfter(_newestSource(cli))) {
    return _built = out;
  }
  // Compile to a private name first so parallel runs never see a half file.
  final tmp = '$out.$pid.tmp';
  final result = await Process.run(Platform.resolvedExecutable, [
    'compile',
    'exe',
    p.join('bin', 'flutter_run.dart'),
    '-o',
    tmp,
  ], workingDirectory: cli.path);
  if (result.exitCode != 0) {
    throw StateError(
      'dart compile exe failed (${result.exitCode}):\n'
      '${result.stdout}\n${result.stderr}',
    );
  }
  File(tmp).renameSync(out);
  return _built = out;
}
