import 'dart:io';

import 'package:yaml/yaml.dart';

import '../common/errors.dart';
import '../common/host_environment.dart';
import '../common/paths.dart';
import 'jsonc.dart';

enum ProjectKind { flutter, dart }

/// What `init` needs to know about the project.
class ProjectInfo {
  const ProjectInfo({
    required this.root,
    required this.name,
    required this.kind,
    required this.usesFvm,
    required this.dartEntry,
    this.launchTargets = const [],
    this.packageGlobs = const [],
    this.missingMain = false,
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

  /// Flutter entry points found in `.vscode/launch.json` or as
  /// `lib/main_<flavor>.dart`. Empty means the plain `lib/main.dart` set.
  final List<LaunchTarget> launchTargets;

  /// `reloadOnSaveGlobs` for local path packages inside [root], so that
  /// saving a file in `packages/` reloads too.
  final List<String> packageGlobs;

  /// True for a Flutter app with no entry point found at all.
  final bool missingMain;
}

/// One Flutter entry point to launch.
class LaunchTarget {
  const LaunchTarget({
    required this.name,
    required this.program,
    this.toolArgs = const [],
    this.flutterMode,
    this.noDebug = false,
    this.env = const {},
    this.fromLaunchJson = false,
  });

  /// Shown after "Flutter: " in the scenario label.
  final String name;

  /// Relative to the project root, with `/` separators.
  final String program;
  final List<String> toolArgs;
  final String? flutterMode;
  final bool noDebug;
  final Map<String, String> env;

  /// True when it was read from `.vscode/launch.json`.
  final bool fromLaunchJson;
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
      hint: 'Run this command inside a Flutter or Dart project, or pass --project with the project folder.',
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

  final isFlutter = _isFlutter(pubspec);
  final targets = isFlutter
      ? _launchTargets(root, env)
      : const <LaunchTarget>[];
  return ProjectInfo(
    root: root,
    name: name,
    kind: isFlutter ? ProjectKind.flutter : ProjectKind.dart,
    usesFvm:
        findUpwards(root, '.fvmrc', env) != null ||
        findUpwards(root, '.fvm', env) != null,
    dartEntry: _dartEntry(root, name, env),
    launchTargets: targets,
    packageGlobs: _packageGlobs(root, pubspec, env),
    missingMain:
        isFlutter && targets.isEmpty && !_exists(root, 'lib/main.dart', env),
  );
}

bool _exists(String root, String relative, HostEnvironment env) {
  final ctx = env.pathContext;
  return File(ctx.join(root, ctx.joinAll(relative.split('/')))).existsSync();
}

String? _readText(String root, String relative, HostEnvironment env) {
  final ctx = env.pathContext;
  try {
    return File(ctx.join(root, ctx.joinAll(relative.split('/'))))
        .readAsStringSync();
  } on FileSystemException {
    return null;
  }
}

// A project's own launch.json is the best record of how it is started
// (flavors, targets, dart-defines), so it wins over guessing from file names.
List<LaunchTarget> _launchTargets(String root, HostEnvironment env) {
  final fromVsCode = _vsCodeTargets(root, env);
  if (fromVsCode.isNotEmpty) return fromVsCode;
  if (_exists(root, 'lib/main.dart', env)) return const [];

  final lib = Directory(env.pathContext.join(root, 'lib'));
  if (!lib.existsSync()) return const [];
  final flavors =
      lib
          .listSync(followLinks: false)
          .whereType<File>()
          .map((f) => env.pathContext.basename(f.path))
          .map(RegExp(r'^main_([A-Za-z0-9_]+)\.dart$').firstMatch)
          .whereType<RegExpMatch>()
          .map((m) => m.group(1)!)
          .toList()
        ..sort();
  return [
    for (final flavor in flavors)
      LaunchTarget(
        name: flavor,
        program: 'lib/main_$flavor.dart',
        toolArgs: _hasNativeFlavor(root, flavor, env)
            ? ['--flavor', flavor]
            : const [],
      ),
  ];
}

/// True when Android or iOS defines a build flavor called [flavor]. A
/// `main_<name>.dart` file alone does not mean there is a native flavor, and
/// `--flavor` for a flavor that does not exist fails the build.
bool _hasNativeFlavor(String root, String flavor, HostEnvironment env) {
  final word = RegExp('\\b${RegExp.escape(flavor)}\\b');
  for (final gradle in [
    'android/app/build.gradle',
    'android/app/build.gradle.kts',
  ]) {
    final text = _readText(root, gradle, env);
    if (text == null) continue;
    final at = text.indexOf('productFlavors');
    if (at >= 0 && word.hasMatch(text.substring(at))) return true;
  }
  for (final platform in ['ios', 'macos']) {
    if (_exists(
      root,
      '$platform/Runner.xcodeproj/xcshareddata/xcschemes/$flavor.xcscheme',
      env,
    )) {
      return true;
    }
  }
  return false;
}

const _workspaceFolder = r'${workspaceFolder}';

List<LaunchTarget> _vsCodeTargets(String root, HostEnvironment env) {
  final text = _readText(root, '.vscode/launch.json', env);
  if (text == null) return const [];
  Object? decoded;
  try {
    decoded = decodeJsonc(text);
  } on FormatException {
    return const [];
  }
  if (decoded is! Map<String, Object?>) return const [];
  final configs = decoded['configurations'];
  if (configs is! List<Object?>) return const [];

  String? relativePath(Object? value) {
    if (value is! String) return null;
    var v = value.replaceAll(r'\', '/');
    if (v.startsWith('$_workspaceFolder/')) {
      v = v.substring(_workspaceFolder.length + 1);
    }
    // Other VS Code variables have no Zed equivalent here.
    if (v.contains(r'${') || v.startsWith('/') || v.startsWith('..')) {
      return null;
    }
    return v;
  }

  final targets = <LaunchTarget>[];
  for (final config in configs) {
    if (config is! Map<String, Object?>) continue;
    final name = config['name'];
    if (config['type'] != 'dart' || name is! String || name.trim().isEmpty) {
      continue;
    }
    if ((config['request'] ?? 'launch') != 'launch') continue;
    final cwd = config['cwd'];
    if (cwd != null && cwd != _workspaceFolder && cwd != '.' && cwd != '') {
      continue;
    }
    final program = config.containsKey('program')
        ? relativePath(config['program'])
        : 'lib/main.dart';
    if (program == null) continue;

    final mode = config['flutterMode'];
    final rawEnv = config['env'];
    targets.add(
      LaunchTarget(
        name: name.trim(),
        program: program,
        toolArgs: [
          ..._stringList(config['toolArgs']),
          ..._withoutTarget(_stringList(config['args'])),
        ],
        flutterMode: mode is String && mode != 'debug' ? mode : null,
        noDebug: config['noDebug'] == true,
        env: {
          if (rawEnv is Map<String, Object?>)
            for (final e in rawEnv.entries)
              if (e.value is String) e.key: e.value! as String,
        },
        fromLaunchJson: true,
      ),
    );
  }
  return targets;
}

List<String> _stringList(Object? value) =>
    value is List<Object?> ? value.whereType<String>().toList() : const [];

// `program` already sets the target, and Flutter refuses a second one.
List<String> _withoutTarget(List<String> args) {
  final out = <String>[];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '-t' || a == '--target') {
      i++;
      continue;
    }
    if (a.startsWith('--target=')) continue;
    out.add(a);
  }
  return out;
}

List<String> _packageGlobs(String root, YamlMap pubspec, HostEnvironment env) {
  final paths = <String>[];
  for (final section in [
    'dependencies',
    'dev_dependencies',
    'dependency_overrides',
  ]) {
    final deps = pubspec[section];
    if (deps is! YamlMap) continue;
    for (final dep in deps.values) {
      if (dep is YamlMap && dep['path'] is String) {
        paths.add(dep['path'] as String);
      }
    }
  }
  final workspace = pubspec['workspace'];
  if (workspace is YamlList) paths.addAll(workspace.whereType<String>());

  final ctx = env.pathContext;
  final globs = <String>{};
  for (final raw in paths) {
    var path = raw.replaceAll(r'\', '/');
    while (path.startsWith('./')) {
      path = path.substring(2);
    }
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    // Only folders inside the project can be watched.
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.split('/').contains('..') ||
        RegExp(r'^[A-Za-z]:').hasMatch(path)) {
      continue;
    }
    if (!Directory(ctx.join(root, ctx.joinAll(path.split('/')))).existsSync()) {
      continue;
    }
    globs.add('$path/lib/**.dart');
  }
  return globs.toList()..sort();
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
