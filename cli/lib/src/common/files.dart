import 'dart:io';
import 'dart:math';

import 'errors.dart';
import 'host_environment.dart';

final Random _random = Random.secure();

/// Writes [content] (UTF-8) to [path] via a temp file in the same directory
/// and a rename, so readers never see a partial file. Windows refuses a
/// rename over a file another process has open (ERROR_ACCESS_DENIED /
/// ERROR_SHARING_VIOLATION), so the rename is retried with a growing delay
/// (10 ms doubling to 200 ms, about 5 s in total) before giving up.
Future<void> atomicWriteString(
  String path,
  String content, {
  HostEnvironment? env,
}) async {
  // Keep symlinked targets (e.g. dotfiles-managed files) intact: write next
  // to the resolved file and rename over that, not over the link.
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.link) {
    try {
      path = File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      final ctx = env?.pathContext;
      final link = Link(path).targetSync();
      path = ctx == null
          ? File(path).parent.uri.resolve(link).toFilePath()
          : ctx.normalize(ctx.join(ctx.dirname(path), link));
    }
  }
  final target = File(path);
  await target.parent.create(recursive: true);
  final suffix = List.generate(
    8,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final temp = File('$path.tmp-$suffix');
  try {
    await temp.writeAsString(content, flush: true);
    for (var attempt = 1; ; attempt++) {
      try {
        await temp.rename(path);
        return;
      } on FileSystemException {
        if (attempt >= 30) rethrow;
        await Future<void>.delayed(
          Duration(milliseconds: min(200, 10 << min(attempt - 1, 5))),
        );
      }
    }
  } on Object {
    try {
      if (temp.existsSync()) temp.deleteSync();
    } on FileSystemException {
      // Best effort.
    }
    rethrow;
  }
}

/// Creates [path] (and parents) and restricts it to the current user (mode
/// 0700) on POSIX. Windows relies on the per-user profile ACL.
Future<void> ensureOwnerOnlyDirectory(String path, HostEnvironment env) async {
  FileSystemEntityType typeOf() =>
      FileSystemEntity.typeSync(path, followLinks: false);
  FlutterRunException refuse() => FlutterRunException(
    'The folder $path is a link or not a normal folder, so it is not used.',
    hint:
        'Remove it, or set FLUTTER_RUN_STATE_DIR to another folder that only you can write to.',
  );
  var type = typeOf();
  if (type != FileSystemEntityType.notFound &&
      type != FileSystemEntityType.directory) {
    throw refuse();
  }
  if (type == FileSystemEntityType.notFound) {
    await Directory(path).create(recursive: true);
    type = typeOf();
    if (type != FileSystemEntityType.directory) throw refuse();
  }
  if (env.isWindows) return;
  final result = await Process.run('/bin/chmod', ['700', path]);
  if (result.exitCode != 0) {
    throw FlutterRunException(
      'Could not restrict the folder $path to your user.',
      exitCode: ExitCodes.internal,
      hint:
          'Check that you own the folder, or set FLUTTER_RUN_STATE_DIR to another one.',
    );
  }
}
