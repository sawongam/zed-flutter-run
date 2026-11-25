import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import '../../common/console.dart';
import '../../common/errors.dart';
import '../../common/files.dart';
import '../../common/global_options.dart';
import '../../common/host_environment.dart';
import '../json_merge.dart';
import '../jsonc.dart';
import '../keymap.dart';

/// `flutter_run keymap`: adds the hot reload, hot restart and DevTools keys
/// to the user's Zed keymap. Zed extensions cannot add key bindings, and a
/// snippet to paste by hand was the step people skipped.
class KeymapCommand extends Command<int> {
  KeymapCommand({required this._env, required this._console}) {
    GlobalOptions.addTo(argParser);
    argParser
      ..addOption(
        'reload-key',
        valueHelp: 'key',
        help:
            'Key for hot reload, such as ctrl-f5 or Ctrl+R (default: ctrl-f5).',
      )
      ..addOption(
        'restart-key',
        valueHelp: 'key',
        help:
            'Key for hot restart (default: ctrl-shift-f5, or shift-cmd-f5 on '
            'macOS).',
      )
      ..addOption(
        'devtools-key',
        valueHelp: 'key',
        help: 'Key for opening DevTools (default: ctrl-alt-shift-d).',
      )
      ..addFlag(
        'keep-zed-restart-key',
        negatable: false,
        help:
            'Leave out the hot restart key, so Zed\'s own restart key stays '
            'as it is.',
      )
      ..addOption(
        'file',
        valueHelp: 'path',
        help:
            'The Zed keymap file (default: the one Zed uses on this computer).',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Show what would be written without writing anything.',
      );
  }

  final HostEnvironment _env;
  final Console _console;

  @override
  String get name => 'keymap';

  @override
  String get description =>
      'Add the hot reload, hot restart and DevTools keys to your Zed keymap.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final dryRun = results['dry-run'] as bool;
    final keys = _keyChoice(results);
    final keymapPath = _keymapPath(results['file'] as String?);
    final settings = _readSettings(_env.pathContext.dirname(keymapPath));

    final file = File(keymapPath);
    final existing = file.existsSync() ? file.readAsStringSync() : null;
    final block = keymapBlock(keys);
    final snippet = encodeJsonFile(<Object?>[block]).trimRight();

    String content;
    if (existing == null || existing.trim().isEmpty) {
      content = encodeJsonFile(<Object?>[block]);
    } else {
      Object? decoded;
      try {
        decoded = decodeJsonc(existing);
      } on FormatException {
        return _manual(keymapPath, 'it is not valid JSON', snippet);
      }
      if (decoded is! List<Object?>) {
        return _manual(keymapPath, 'it is not a JSON array', snippet);
      }
      final already = _existingBindings(decoded);
      if (already.isNotEmpty) {
        final style = _console.style;
        _console.out(
          '${style.bold(keymapPath)} ${style.green('already has Flutter keys')}:',
        );
        _printBindings(already);
        _console
          ..out('')
          ..out(style.dim(_alreadyLine));
        return ExitCodes.ok;
      }
      final appended = appendToJsoncArray(existing, encodeJsonFile(block));
      if (appended == null) {
        return _manual(keymapPath, 'it is not a JSON array', snippet);
      }
      content = appended;
    }

    final style = _console.style;
    if (dryRun) {
      _console
        ..out(
          '${style.yellow('Would add')} these keys to '
          '${style.bold(keymapPath)}:',
        )
        ..out(snippet)
        ..out(style.yellow('Dry run: nothing was written.'));
    } else {
      await atomicWriteString(keymapPath, content, env: _env);
      _console.out(
        '${style.green('Added')} these keys to ${style.bold(keymapPath)}:',
      );
    }
    _printBindings(keys.bindings);
    _printNotes(keys, settings);
    return ExitCodes.ok;
  }

  void _printBindings(Map<String, String> bindings) {
    final style = _console.style;
    for (final MapEntry(:key, :value) in bindings.entries) {
      // Pad before styling so the escape codes do not break the alignment.
      _console.out('  ${style.cyan(displayKey(key).padRight(17))} $value');
    }
  }

  KeyChoice _keyChoice(ArgResults results) {
    final defaults = KeyChoice.defaults(
      _env.os,
      keepZedRestartKey: results['keep-zed-restart-key'] as bool,
    );
    String? pick(String option, String? fallback) {
      final raw = results[option] as String?;
      if (raw == null) return fallback;
      final key = normalizeKey(raw);
      if (key == null) {
        throw UsageError(
          '"$raw" is not a key. Write it like ctrl-shift-r or Ctrl+Shift+R.',
        );
      }
      return key;
    }

    final keys = KeyChoice(
      reload: pick('reload-key', defaults.reload),
      restart: pick('restart-key', defaults.restart),
      devTools: pick('devtools-key', defaults.devTools),
    );
    final chosen = [keys.reload, keys.restart, keys.devTools].nonNulls;
    if (chosen.toSet().length != chosen.length) {
      throw const UsageError('Each action needs its own key.');
    }
    return keys;
  }

  /// Where Zed keeps `keymap.json` on this computer.
  String _keymapPath(String? override) {
    final ctx = _env.pathContext;
    if (override != null && override.trim().isNotEmpty) {
      return ctx.normalize(ctx.absolute(override));
    }
    final home = _env.home;
    if (_env.isWindows) {
      final appData = _env.env('APPDATA');
      if (appData != null && appData.isNotEmpty) {
        return ctx.join(appData, 'Zed', 'keymap.json');
      }
    }
    if (home == null) {
      throw const UsageError(
        'Could not find your home folder. Pass the keymap file with --file.',
      );
    }
    if (_env.isWindows) {
      return ctx.join(home, 'AppData', 'Roaming', 'Zed', 'keymap.json');
    }
    final xdg = _env.os == HostOs.linux ? _env.env('XDG_CONFIG_HOME') : null;
    final standard = ctx.join(
      xdg != null && xdg.isNotEmpty ? xdg : ctx.join(home, '.config'),
      'zed',
    );
    // Zed installed through Flatpak keeps its settings inside the sandbox.
    final flatpak = ctx.join(
      home,
      '.var',
      'app',
      'dev.zed.Zed',
      'config',
      'zed',
    );
    if (_env.os == HostOs.linux &&
        !Directory(standard).existsSync() &&
        Directory(flatpak).existsSync()) {
      return ctx.join(flatpak, 'keymap.json');
    }
    return ctx.join(standard, 'keymap.json');
  }

  /// `base_keymap` and `vim_mode` from Zed's settings, when readable.
  ({String? baseKeymap, bool vimMode}) _readSettings(String zedDir) {
    try {
      final text = File(_env.pathContext.join(zedDir, 'settings.json'))
          .readAsStringSync();
      final decoded = decodeJsonc(text);
      if (decoded is Map<String, Object?>) {
        final base = decoded['base_keymap'];
        return (
          baseKeymap: base is String ? base : null,
          vimMode: decoded['vim_mode'] == true,
        );
      }
    } on FileSystemException {
      // No settings file: Zed's defaults apply.
    } on FormatException {
      // Unreadable settings: warn about nothing rather than guess.
    }
    return (baseKeymap: null, vimMode: false);
  }

  /// Keys in [keymap] that already start one of our tasks.
  static Map<String, String> _existingBindings(List<Object?> keymap) {
    const ours = {hotReloadTask, hotRestartTask, devToolsTask};
    final found = <String, String>{};
    for (final section in keymap) {
      if (section is! Map<String, Object?>) continue;
      final bindings = section['bindings'];
      if (bindings is! Map<String, Object?>) continue;
      for (final MapEntry(:key, :value) in bindings.entries) {
        if (value is List<Object?> &&
            value.length == 2 &&
            value[0] == 'task::Spawn' &&
            value[1] is Map<String, Object?>) {
          final task = (value[1]! as Map<String, Object?>)['task_name'];
          if (task is String && ours.contains(task)) found[key] = task;
        }
      }
    }
    return found;
  }

  void _printNotes(
    KeyChoice keys,
    ({String? baseKeymap, bool vimMode}) settings,
  ) {
    final notes = <String>[
      for (final key in keys.bindings.keys)
        ...keyConflicts(
          key,
          _env.os,
          baseKeymap: settings.baseKeymap,
          vimMode: settings.vimMode,
        ),
    ];
    final usesFunctionKeys = keys.bindings.keys.any(
      (k) => RegExp(r'(^|-)f\d+$').hasMatch(k),
    );
    final style = _console.style;
    _console
      ..out('')
      ..out(keyTable(keys, style: style));
    if (notes.isNotEmpty) {
      _console.out('');
      for (final note in notes) {
        _console.out('${style.yellow('Note:')} $note');
      }
    }
    if (usesFunctionKeys) {
      _console
        ..out('')
        ..out(
          style.dim(
            _env.os == HostOs.macos ? macosKeyNote() : functionKeyNote(),
          ),
        );
    }
    _console
      ..out('')
      ..out(style.dim(_tasksLine))
      ..out(style.dim(_restartZedLine));
  }

  int _manual(String path, String reason, String snippet) {
    _console
      ..out(
        _console.style.yellow(
          'Could not safely edit $path ($reason). Nothing was changed. Open '
          'it with "zed: open keymap file" and add this:',
        ),
      )
      ..out(snippet);
    return ExitCodes.manualActionRequired;
  }

  static const String _alreadyLine =
      'Nothing was changed. To use other keys, edit them in Zed '
      '("zed: open keymap") or delete them from the file and run this again.';
  static const String _tasksLine =
      'The keys start tasks that "flutter_run init" adds to each project, so '
      'run init in every project where you want them.';
  static const String _restartZedLine =
      'Zed reloads the keymap by itself. If a key still does its old job, '
      'restart Zed.';
}
