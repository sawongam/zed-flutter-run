import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../common/console.dart';
import '../common/errors.dart';
import '../common/global_options.dart';
import '../common/host_environment.dart';
import '../common/paths.dart';
import '../common/style.dart';
import '../common/version.dart';
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
    required this._env,
    required this._console,
    this._resolvedExecutable,
  }) : _sdk = sdkResolver,
       _sessions = sessionStore {
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
      ..out(_style.bold('$toolName $packageVersion'))
      ..out(
        _kv(
          'Operating system',
          '${_env.os.name} (${Platform.operatingSystemVersion})',
        ),
      )
      ..out(_kv('Executable', exe))
      ..out('');

    ProjectInfo? project;
    try {
      project = detectProject(dir, _env);
      _console.out(
        _kv(
          'Project',
          '${project.root} (${project.kind.name} project "${project.name}")',
        ),
      );
    } on FlutterRunException catch (e) {
      _console.out(_kv('Project', _style.yellow(e.message)));
    }
    final projectDir = project?.root ?? dir;

    final sdkFound = await _printSdk(
      projectDir,
      project?.kind == ProjectKind.dart ? SdkKind.dart : SdkKind.flutter,
      options.flutterSdk,
    );
    _console.out('');
    _printPathStatus(exe);
    await _printSessions();
    _console.out('');
    _printZedFile(projectDir, 'debug.json', project, isDebug: true);
    _printZedFile(projectDir, 'tasks.json', project, isDebug: false);
    _console.out('');
    _printOverrides();

    return sdkFound ? ExitCodes.ok : ExitCodes.sdkNotFound;
  }

  /// Prints how the SDK was looked for and what was found. Returns whether
  /// the SDK that [kind] needs was found.
  Future<bool> _printSdk(
    String projectDir,
    SdkKind kind,
    String? explicitSdkPath,
  ) async {
    final resolution = await _sdk.resolve(
      projectDir: projectDir,
      kind: kind,
      explicitSdkPath: explicitSdkPath,
    );
    _console
      ..out('')
      ..out(
        _style.heading(
          'How the ${kind == SdkKind.dart ? 'Dart' : 'Flutter'} SDK was '
          'looked for:',
        ),
      );
    for (final line in resolution.describeTrace().split('\n')) {
      _console.out('  ${_traceLine(line)}');
    }
    final flutter = resolution.flutter;
    final found = kind == SdkKind.flutter
        ? flutter != null
        : resolution.dartExecutable != null;
    if (flutter != null) {
      _console
        ..out(
          _kv(
            'Flutter SDK',
            '${_style.green(flutter.root ?? flutter.flutterExecutable)} '
                '(found by step "${flutter.sourceStep}")',
          ),
        )
        ..out(_kv('Flutter version', flutter.flutterVersion ?? 'unknown'));
    } else {
      _console.out(_kv('Flutter SDK', _style.red('not found')));
    }
    if (kind == SdkKind.dart) {
      final dart = resolution.dartExecutable;
      _console.out(
        _kv(
          'Dart executable',
          dart == null ? _style.red('not found') : _style.green(dart),
        ),
      );
    }
    _console.out(_kv('Dart version', flutter?.dartVersion ?? 'unknown'));
    if (!found) {
      _console
        ..out('')
        ..out('${_style.error('No SDK was found.')} $sdkSearchHint');
    }
    return found;
  }

  void _printPathStatus(String exe) {
    final onPath = findExecutableOnPath(toolName, _env);
    if (onPath != null) {
      _console.out(
        _kv('flutter_run on PATH', '${_style.green('yes')} ($onPath)'),
      );
      return;
    }
    _console.out(_kv('flutter_run on PATH', _style.yellow('no')));
    final ctx = _env.pathContext;
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

  void _printOverrides() {
    final overrides = [
      for (final entry in _env.environment.entries)
        if (entry.key.startsWith(envPrefix)) '${entry.key}=${entry.value}',
    ]..sort();
    if (overrides.isEmpty) {
      _console.out(_kv('Environment overrides', _style.dim('none')));
    } else {
      _console.out(_style.bold('Environment overrides:'));
      for (final line in overrides) {
        _console.out('  $line');
      }
    }
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
      _kv(
        'Sessions folder',
        '$directory ($live running, '
            '${unresponsive > 0 ? _style.red('$unresponsive not answering') : '$unresponsive not answering'}, '
            '${stale < 0 ? 0 : stale} stale)',
      ),
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
      _console.out(
        _zed(fileName, _style.yellow('not found'), '(run "flutter_run init")'),
      );
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on Object {
      _console.out(
        _zed(
          fileName,
          _style.yellow('found, but it is not plain JSON'),
          '(comments or trailing commas?), so its entries were not checked',
        ),
      );
      return;
    }
    if (decoded is! List) {
      _console.out(
        _zed(fileName, _style.yellow('found, but it is not a list'), ''),
      );
      return;
    }
    final present = <String>{
      for (final entry in decoded)
        if (entry is Map && entry['label'] is String) entry['label'] as String,
    };
    if (project == null) {
      _console.out(
        _zed(fileName, _style.green('found'), '(${decoded.length} entries)'),
      );
      return;
    }
    final expected = [
      for (final entry in isDebug ? debugScenarios(project) : zedTasks(project))
        entry['label'] as String,
    ];
    final missing = expected.where((l) => !present.contains(l)).toList();
    if (missing.length == expected.length) {
      _console.out(
        _zed(
          fileName,
          _style.yellow('found, but none of the flutter_run entries are in it'),
          '(run "flutter_run init" to add them)',
        ),
      );
    } else if (missing.isEmpty) {
      _console.out(
        _zed(fileName, _style.green('found, with all flutter_run entries'), ''),
      );
    } else {
      _console.out(
        _zed(
          fileName,
          _style.yellow('found, missing ${missing.length} flutter_run entries'),
          '(run "flutter_run init" to add them)',
        ),
      );
    }
  }

  Style get _style => _console.style;

  /// "Label: value" with a bold label.
  String _kv(String label, String value) => '${_style.bold('$label:')} $value';

  String _zed(String fileName, String status, String note) =>
      '${_style.bold('.zed/$fileName:')} $status${note.isEmpty ? '' : ' $note'}';

  /// Colours one line of the SDK search trace: green when that step found
  /// the SDK, dim when it was skipped.
  String _traceLine(String line) {
    final found = line.indexOf(' - found');
    if (found >= 0) {
      return line.substring(0, found + 3) +
          _style.green(line.substring(found + 3));
    }
    if (line.contains(' - skipped')) return _style.dim(line);
    return line;
  }
}
