import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../common/console.dart';
import '../common/errors.dart';
import '../common/global_options.dart';
import '../common/host_environment.dart';
import '../common/paths.dart';
import '../common/version.dart';
import '../control/session_paths.dart';
import '../control/session_store.dart';
import '../init/project_detect.dart';
import '../init/templates.dart';
import '../sdk/sdk_resolver.dart';
import 'path_notice.dart';

/// `flutter_run doctor`: a plain text report of the environment.
class DoctorCommand extends Command<int> {
  DoctorCommand({
    required SdkResolver sdkResolver,
    required SessionStore sessionStore,
    required HostEnvironment env,
    required Console console,
    String? resolvedExecutable,
  }) : _sdk = sdkResolver,
       _sessions = sessionStore,
       _env = env,
       _console = console,
       _resolvedExecutable = resolvedExecutable {
    GlobalOptions.addTo(argParser);
  }

  final SdkResolver _sdk;
  final SessionStore _sessions;
  final HostEnvironment _env;
  final Console _console;
  final String? _resolvedExecutable;

  @override
  String get name => 'doctor';

  @override
  String get description =>
      'Show how flutter_run sees your environment (SDK, PATH, sessions, '
      '.zed files).';

  @override
  Future<int> run() async {
    final options = GlobalOptions.of(this);
    final ctx = _env.pathContext;
    final dir = ctx.normalize(
      ctx.absolute(options.project ?? _env.currentDirectory),
    );
    final exe = _resolvedExecutable ?? Platform.resolvedExecutable;

    _console
      ..out('$toolName $packageVersion')
      ..out(
        'Operating system: ${_env.os.name} (${Platform.operatingSystemVersion})',
      )
      ..out('Executable: $exe')
      ..out('');

    // Project.
    ProjectInfo? project;
    try {
      project = detectProject(dir, _env);
      _console.out(
        'Project: ${project.root} (${project.kind.name} project "${project.name}")',
      );
    } on FlutterRunException catch (e) {
      _console.out('Project: ${e.message}');
    }
    final projectDir = project?.root ?? dir;

    // SDK.
    final kind = project?.kind == ProjectKind.dart
        ? SdkKind.dart
        : SdkKind.flutter;
    final resolution = await _sdk.resolve(
      projectDir: projectDir,
      kind: kind,
      explicitSdkPath: options.flutterSdk,
    );
    _console
      ..out('')
      ..out(
        'How the ${kind == SdkKind.dart ? 'Dart' : 'Flutter'} SDK was looked for:',
      );
    for (final line in resolution.describeTrace().split('\n')) {
      _console.out('  $line');
    }
    final flutter = resolution.flutter;
    final resolved = kind == SdkKind.flutter
        ? flutter != null
        : resolution.dartExecutable != null;
    if (flutter != null) {
      _console
        ..out(
          'Flutter SDK: ${flutter.root ?? flutter.flutterExecutable} '
          '(found by step "${flutter.sourceStep}")',
        )
        ..out('Flutter version: ${flutter.flutterVersion ?? 'unknown'}');
    } else {
      _console.out('Flutter SDK: not found');
    }
    if (kind == SdkKind.dart) {
      _console.out(
        'Dart executable: ${resolution.dartExecutable ?? 'not found'}',
      );
    }
    _console.out('Dart version: ${flutter?.dartVersion ?? 'unknown'}');
    if (!resolved) {
      _console
        ..out('')
        ..out(
          'No SDK was found. Set flutterSdkPath in the launch entry (or pass '
          '--flutter-sdk), set the FLUTTER_RUN_FLUTTER_SDK environment '
          'variable, or put flutter on your PATH.',
        );
    }

    // PATH.
    _console.out('');
    final onPath = findExecutableOnPath(toolName, _env);
    if (onPath != null) {
      _console.out('flutter_run on PATH: yes ($onPath)');
    } else {
      _console.out('flutter_run on PATH: no');
      final base = ctx.basename(exe).toLowerCase();
      if (base == 'dart' || base == 'dart.exe') {
        _console.out(
          'This is a run from source, so there is no installed command. '
          'See the README section "Install".',
        );
      } else {
        for (final line in pathFixHint(_env.os, ctx.dirname(exe)).split('\n')) {
          _console.out(line);
        }
      }
    }

    // Sessions.
    await _printSessions();

    // Zed files.
    _console.out('');
    _printZedFile(projectDir, 'debug.json', project, isDebug: true);
    _printZedFile(projectDir, 'tasks.json', project, isDebug: false);

    // Overrides.
    final overrides = [
      for (final entry in _env.environment.entries)
        if (entry.key.startsWith(envPrefix)) '${entry.key}=${entry.value}',
    ]..sort();
    _console.out('');
    if (overrides.isEmpty) {
      _console.out('Environment overrides: none');
    } else {
      _console.out('Environment overrides:');
      for (final line in overrides) {
        _console.out('  $line');
      }
    }

    return resolved ? ExitCodes.ok : ExitCodes.sdkNotFound;
  }

  Future<void> _printSessions() async {
    final directory = sessionsDirectory(_env);
    final files = Directory(directory).existsSync()
        ? Directory(directory)
              .listSync(followLinks: false)
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))
              .length
        : 0;
    final records = await _sessions.list(prune: false);
    final unresponsive = records.where((r) => r.unresponsive).length;
    final live = records.length - unresponsive;
    final stale = files - records.length;
    _console.out(
      'Sessions folder: $directory ($live running, $unresponsive not '
      'answering, ${stale < 0 ? 0 : stale} stale)',
    );
  }

  void _printZedFile(
    String projectDir,
    String fileName,
    ProjectInfo? project, {
    required bool isDebug,
  }) {
    final path = _env.pathContext.join(projectDir, '.zed', fileName);
    final file = File(path);
    if (!file.existsSync()) {
      _console.out('.zed/$fileName: not found (run "flutter_run init")');
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on Object {
      _console.out(
        '.zed/$fileName: found, but it is not plain JSON (comments or '
        'trailing commas?), so its entries were not checked',
      );
      return;
    }
    if (decoded is! List) {
      _console.out('.zed/$fileName: found, but it is not a list');
      return;
    }
    final present = <String>{
      for (final entry in decoded)
        if (entry is Map && entry['label'] is String) entry['label'] as String,
    };
    if (project == null) {
      _console.out('.zed/$fileName: found (${decoded.length} entries)');
      return;
    }
    final expected = [
      for (final entry in isDebug ? debugScenarios(project) : zedTasks(project))
        entry['label'] as String,
    ];
    final missing = expected.where((l) => !present.contains(l)).toList();
    if (missing.length == expected.length) {
      _console.out(
        '.zed/$fileName: found, but none of the flutter_run entries are in it '
        '(run "flutter_run init" to add them)',
      );
    } else if (missing.isEmpty) {
      _console.out('.zed/$fileName: found, with all flutter_run entries');
    } else {
      _console.out(
        '.zed/$fileName: found, missing ${missing.length} flutter_run entries '
        '(run "flutter_run init" to add them)',
      );
    }
  }
}
