import 'dart:io';

import 'package:yaml/yaml.dart';

import '../common/errors.dart';
import '../common/host_environment.dart';
import '../common/paths.dart';

enum ProjectKind { flutter, dart }

/// What `init` needs to know about the project.
class ProjectInfo {
  const ProjectInfo({
    required this.root,
    required this.name,
    required this.kind,
    required this.usesFvm,
    required this.dartEntry,
  });

  /// Directory that contains `pubspec.yaml`.
  final String root;

  /// Package name from `pubspec.yaml`.
  final String name;
  final ProjectKind kind;

  /// True when an fvm marker (`.fvmrc` or `.fvm/`) exists at or above [root].
  final bool usesFvm;

  /// Program of a Dart package, relative to [root], with `/` separators.
  final String dartEntry;
}

/// Finds and classifies the project at or above [projectDir].
///
/// Throws [ProjectNotFoundException] (exit 8) when there is no pubspec.
ProjectInfo detectProject(String projectDir, HostEnvironment env) {
  final ctx = env.pathContext;
  final start = ctx.normalize(ctx.absolute(projectDir));
  final root = findProjectRoot(start, env);
  if (root == null) {
    throw ProjectNotFoundException(
      'No pubspec.yaml was found at or above $start.',
      hint:
          'Run this command inside a Flutter or Dart project, or pass --project with the project folder.',
    );
  }

  final pubspecPath = ctx.join(root, 'pubspec.yaml');
  Object? doc;
  try {
    doc = loadYaml(File(pubspecPath).readAsStringSync());
  } on Object catch (e) {
    throw ProjectNotFoundException(
      'Could not read $pubspecPath ($e).',
      hint: 'Fix the file so that it is valid YAML, then run this again.',
    );
  }
  final pubspec = doc is YamlMap ? doc : YamlMap();

  final nameValue = pubspec['name'];
  final name = nameValue is String && nameValue.isNotEmpty
      ? nameValue
      : ctx.basename(root);

  return ProjectInfo(
    root: root,
    name: name,
    kind: _isFlutter(pubspec) ? ProjectKind.flutter : ProjectKind.dart,
    usesFvm:
        findUpwards(root, '.fvmrc', env) != null ||
        findUpwards(root, '.fvm', env) != null,
    dartEntry: _dartEntry(root, name, env),
  );
}

bool _isFlutter(YamlMap pubspec) {
  final deps = pubspec['dependencies'];
  if (deps is YamlMap) {
    final flutter = deps['flutter'];
    if (flutter is YamlMap && flutter['sdk'] == 'flutter') return true;
  }
  if (pubspec.containsKey('flutter')) return true;
  final environment = pubspec['environment'];
  return environment is YamlMap && environment.containsKey('flutter');
}

String _dartEntry(String root, String name, HostEnvironment env) {
  final ctx = env.pathContext;
  bool exists(String relative) =>
      File(ctx.join(root, ctx.joinAll(relative.split('/')))).existsSync();

  if (exists('bin/$name.dart')) return 'bin/$name.dart';
  if (exists('bin/main.dart')) return 'bin/main.dart';
  final bin = Directory(ctx.join(root, 'bin'));
  if (bin.existsSync()) {
    final files =
        bin
            .listSync(followLinks: false)
            .whereType<File>()
            .map((f) => ctx.basename(f.path))
            .where((n) => n.endsWith('.dart'))
            .toList()
          ..sort();
    if (files.isNotEmpty) return 'bin/${files.first}';
  }
  return 'lib/main.dart';
}
