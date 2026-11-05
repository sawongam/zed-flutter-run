import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../../common/console.dart';
import '../../common/errors.dart';
import '../../common/files.dart';
import '../../common/global_options.dart';
import '../../common/host_environment.dart';
import '../../common/json_types.dart';
import '../json_merge.dart';
import '../keymap.dart';
import '../project_detect.dart';
import '../templates.dart';

/// `flutter_run init`: writes `.zed/debug.json` and `.zed/tasks.json` and
/// prints the keymap snippet, the key table and the PATH check.
class InitCommand extends Command<int> {
  InitCommand({
    required HostEnvironment env,
    required Console console,
    required String? Function() findFlutterRunOnPath,
    required String pathFixHint,
  }) : _env = env,
       _console = console,
       _findOnPath = findFlutterRunOnPath,
       _pathFixHint = pathFixHint {
    GlobalOptions.addTo(argParser);
    argParser
      ..addFlag(
        'force',
        negatable: false,
        help:
            'Replace .zed files that cannot be edited safely (a .bak copy is kept).',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Show what would be written without writing anything.',
      );
  }

  final HostEnvironment _env;
  final Console _console;
  final String? Function() _findOnPath;
  final String _pathFixHint;

  @override
  String get name => 'init';

  @override
  String get description =>
      'Write .zed/debug.json and .zed/tasks.json for this project.';

  @override
  Future<int> run() async {
    final force = argResults!['force'] as bool;
    final dryRun = argResults!['dry-run'] as bool;
    final options = GlobalOptions.of(this);
    final project = detectProject(
      options.project ?? _env.currentDirectory,
      _env,
    );
    final ctx = _env.pathContext;
    final zedDir = ctx.join(project.root, '.zed');

    _console.out(_projectLine(project));
    if (project.usesFvm) _console.out(_fvmLine);

    var manualSteps = 0;
    final files = <(String, List<Json>)>[
      ('debug.json', debugScenarios(project)),
      ('tasks.json', zedTasks(project)),
    ];
    for (final (fileName, entries) in files) {
      final outcome = await _handleFile(
        path: ctx.join(zedDir, fileName),
        shownName: '.zed/$fileName',
        entries: entries,
        force: force,
        dryRun: dryRun,
      );
      if (outcome) manualSteps++;
    }

    if (dryRun) _console.out(_dryRunLine);

    _console
      ..out('')
      ..out(keyTable())
      ..out('')
      ..out(_keymapStepsLine);
    _console
      ..out(keymapSnippet(_env.os))
      ..out('')
      ..out(_optionalSnippetLine)
      ..out(keymapSnippet(_env.os, keepZedRestartKey: true));
    if (_env.os == HostOs.macos) {
      _console
        ..out('')
        ..out(macosKeyNote());
    }
    _console
      ..out('')
      ..out(_consoleTabLine);

    final onPath = _findOnPath();
    if (onPath != null) {
      _console.out('flutter_run on PATH: yes ($onPath)');
    } else {
      _console
        ..out('flutter_run on PATH: no')
        ..out(_notOnPathLine);
      for (final line in _pathFixHint.split('\n')) {
        _console.out(line);
      }
    }
    _console
      ..out('')
      ..out(_commitNote);

    if (manualSteps > 0) {
      _console
        ..out('')
        ..out(_doneWithManual(manualSteps));
      return ExitCodes.manualActionRequired;
    }
    return ExitCodes.ok;
  }

  /// Returns true when the file needs a manual step.
  Future<bool> _handleFile({
    required String path,
    required String shownName,
    required List<Json> entries,
    required bool force,
    required bool dryRun,
  }) async {
    final file = File(path);
    String? existing;
    var unreadable = false;
    if (file.existsSync()) {
      try {
        existing = utf8.decode(file.readAsBytesSync());
      } on FormatException {
        unreadable = true;
      }
    }
    final result = unreadable
        ? MergeNeedsManual(
            reason: 'it is not valid UTF-8 text',
            snippet: encodeJsonFile(entries).trimRight(),
          )
        : mergeLabeledArray(existing, entries);

    switch (result) {
      case MergeCreated(:final content):
        _console.out(
          dryRun
              ? _wouldCreate(shownName, entries.length)
              : _created(shownName, entries.length),
        );
        if (dryRun) {
          _console.out(content.trimRight());
        } else {
          await atomicWriteString(path, content, env: _env);
        }
        return false;
      case MergeUpdated(:final content, :final added, :final kept):
        _console.out(
          dryRun
              ? _wouldMerge(shownName, added, kept)
              : _merged(shownName, added, kept),
        );
        if (dryRun) {
          _console.out(content.trimRight());
        } else if (added > 0) {
          await atomicWriteString(path, content, env: _env);
        }
        return false;
      case MergeNeedsManual(:final reason, :final snippet):
        if (!force) {
          _console
            ..out(_couldNotEdit(shownName, reason))
            ..out(snippet);
          if (reason.contains('comments')) _console.out(_templateNote);
          return true;
        }
        final fresh = encodeJsonFile(entries);
        final backup = _backupPath(path);
        final backupName = _env.pathContext.basename(backup);
        if (dryRun) {
          _console
            ..out(_wouldBackUp(shownName, backupName))
            ..out(fresh.trimRight());
        } else {
          await file.copy(backup);
          await atomicWriteString(path, fresh, env: _env);
          _console
            ..out(_backedUp(backupName))
            ..out(_replaced(shownName, entries.length));
        }
        return false;
    }
  }

  String _backupPath(String path) {
    var candidate = '$path.bak';
    for (var n = 1; File(candidate).existsSync(); n++) {
      candidate = '$path.bak.$n';
    }
    return candidate;
  }

  // User-facing text.

  static const String _fvmLine =
      'Found an fvm setup. flutter_run uses the Flutter version that fvm selects.';
  static const String _dryRunLine = 'Dry run: nothing was written.';
  static const String _keymapStepsLine =
      'Open the command palette, run "zed: open keymap file", and paste the snippet.';
  static const String _optionalSnippetLine =
      'To keep Zed\'s default restart key, paste this snippet instead (it leaves out the hot restart key):';
  static const String _consoleTabLine =
      'Output and reload results appear in the Console tab of the Debug panel.';
  static const String _notOnPathLine =
      'Warning: Zed tasks cannot start flutter_run until it is on your PATH.';
  static const String _templateNote =
      'If the comments are only the template text that Zed puts in new files, delete them and run this again.';
  static const String _commitNote =
      'The .zed folder is usually committed. Teammates without flutter_run on their PATH can still debug, but the tasks fail for them; "Flutter: Doctor" explains why.';

  static String _projectLine(ProjectInfo p) => switch (p.kind) {
    ProjectKind.flutter => 'Flutter app "${p.name}" in ${p.root}',
    ProjectKind.dart => 'Dart package "${p.name}" in ${p.root}',
  };

  static String _entries(int n) => n == 1 ? '1 entry' : '$n entries';

  static String _created(String file, int n) =>
      'Created $file with ${_entries(n)}.';
  static String _wouldCreate(String file, int n) =>
      'Would create $file with ${_entries(n)}:';

  static String _added(int added, int kept) {
    final addedText = 'Added ${_entries(added)}';
    final keptText = kept == 1
        ? 'kept 1 that was already there'
        : 'kept $kept that were already there';
    return '$addedText, $keptText.';
  }

  static String _merged(String file, int added, int kept) =>
      '$file: ${_added(added, kept)}';
  static String _wouldMerge(String file, int added, int kept) =>
      '$file: Would do this: ${_added(added, kept)} The result would be:';

  static String _couldNotEdit(String file, String reason) =>
      'Could not safely edit $file ($reason). Nothing was changed. Paste these entries into the file:';
  static String _wouldBackUp(String file, String backup) =>
      '$file cannot be edited safely. Would back it up to $backup and write a fresh file:';
  static String _backedUp(String backup) => 'Backed up to $backup';
  static String _replaced(String file, int n) =>
      'Replaced $file with a fresh file with ${_entries(n)}.';

  static String _doneWithManual(int n) =>
      n == 1 ? 'Done with 1 manual step.' : 'Done with $n manual steps.';
}
