import 'dart:io';

import 'package:path/path.dart' as p;

/// Outcome of one SDK resolution step.
enum StepOutcome { skipped, notFound, invalid, found }

/// One recorded step of the SDK walk (shown by `doctor` and in errors).
class ResolutionStep {
  const ResolutionStep(this.id, this.description, this.outcome, [this.detail]);

  final String id;
  final String description;
  final StepOutcome outcome;
  final String? detail;

  @override
  String toString() {
    final label = switch (outcome) {
      StepOutcome.skipped => 'skipped',
      StepOutcome.notFound => 'not found',
      StepOutcome.invalid => 'invalid',
      StepOutcome.found => 'found',
    };
    final extra = (detail == null || detail!.isEmpty) ? '' : ': $detail';
    return '$description - $label$extra';
  }
}

/// File system access used by the resolver; a seam so that Windows layouts can
/// be tested on any host.
abstract class SdkFileSystem {
  bool isFile(String path);
  bool isDirectory(String path);

  /// True for a file, directory or (possibly broken) link; links not followed.
  bool exists(String path);

  /// True when [path] is a file that can be executed.
  bool isExecutableFile(String path);

  /// Fully resolved real path of [path], or the link target when the link is
  /// broken; null when nothing is there.
  String? resolveLink(String path);

  String? readText(String path);
}

class LocalSdkFileSystem implements SdkFileSystem {
  const LocalSdkFileSystem();

  @override
  bool isFile(String path) => FileSystemEntity.isFileSync(path);

  @override
  bool isDirectory(String path) => FileSystemEntity.isDirectorySync(path);

  @override
  bool exists(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  @override
  bool isExecutableFile(String path) {
    try {
      final stat = FileStat.statSync(path);
      if (stat.type != FileSystemEntityType.file) return false;
      if (Platform.isWindows) return true;
      return (stat.mode & 0x49) != 0;
    } on FileSystemException {
      return false;
    }
  }

  @override
  String? resolveLink(String path) {
    try {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.directory) {
        return Directory(path).resolveSymbolicLinksSync();
      }
      if (type == FileSystemEntityType.file) {
        return File(path).resolveSymbolicLinksSync();
      }
    } on FileSystemException {
      // Fall through to the raw link target.
    }
    try {
      if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.link) {
        final target = Link(path).targetSync();
        return p.normalize(p.join(p.dirname(path), target));
      }
    } on FileSystemException {
      // Unreadable link.
    }
    return null;
  }

  @override
  String? readText(String path) {
    try {
      return File(path).readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }
}
