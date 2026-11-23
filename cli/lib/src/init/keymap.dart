import '../common/host_environment.dart';

/// Every binding sits behind this context, so the keys only change while a
/// debug session runs and Zed's own meaning of them comes back afterwards.
const String keymapContext = 'Workspace && debugger_session';

const String hotReloadTask = 'Flutter: Hot Reload';
const String hotRestartTask = 'Flutter: Hot Restart';
const String devToolsTask = 'Flutter: Open DevTools';

/// The keys to bind; a null key is left out.
class KeyChoice {
  const KeyChoice({this.reload, this.restart, this.devTools});

  /// Ctrl+F5 for hot reload matches the Dart extension for VS Code.
  factory KeyChoice.defaults(HostOs os, {bool keepZedRestartKey = false}) =>
      KeyChoice(
        reload: 'ctrl-f5',
        restart: keepZedRestartKey
            ? null
            : os == HostOs.macos
            ? 'shift-cmd-f5'
            : 'ctrl-shift-f5',
        devTools: 'ctrl-alt-shift-d',
      );

  final String? reload;
  final String? restart;
  final String? devTools;

  /// Task name for each chosen key, in a fixed order.
  Map<String, String> get bindings => <String, String>{
    ?reload: hotReloadTask,
    ?restart: hotRestartTask,
    ?devTools: devToolsTask,
  };
}

/// The keymap block for [keys] as a JSON object.
Map<String, Object?> keymapBlock(KeyChoice keys) => <String, Object?>{
  'context': keymapContext,
  'bindings': <String, Object?>{
    for (final MapEntry(:key, :value) in keys.bindings.entries)
      key: <Object?>[
        'task::Spawn',
        <String, Object?>{'task_name': value},
      ],
  },
};

const Set<String> _modifiers = {
  'ctrl',
  'alt',
  'shift',
  'cmd',
  'super',
  'win',
  'fn',
  'secondary',
};

/// [raw] in Zed's keystroke form (`ctrl-shift-s`), or null when it is not a
/// key. Accepts `Ctrl+Shift+S` too, since that is how people write keys.
String? normalizeKey(String raw) {
  final strokes = raw.trim().toLowerCase().split(RegExp(r'\s+'));
  final out = <String>[];
  for (final stroke in strokes) {
    if (stroke.isEmpty) return null;
    final parts = stroke.replaceAll('+', '-').split('-');
    if (parts.any((p) => p.isEmpty)) return null;
    final key = parts.removeLast();
    if (_modifiers.contains(key)) return null;
    if (parts.any((m) => !_modifiers.contains(m))) return null;
    if (parts.toSet().length != parts.length) return null;
    out.add([...parts, key].join('-'));
  }
  return out.join(' ');
}

/// `ctrl-shift-f5` as `Ctrl+Shift+F5`.
String displayKey(String key) => key
    .split(' ')
    .map(
      (stroke) => stroke
          .split('-')
          .map(
            (p) => switch (p) {
              'cmd' => 'Cmd',
              'ctrl' => 'Ctrl',
              'alt' => 'Alt',
              'shift' => 'Shift',
              _ when p.length == 1 => p.toUpperCase(),
              _ when RegExp(r'^f\d+$').hasMatch(p) => p.toUpperCase(),
              _ => p[0].toUpperCase() + p.substring(1),
            },
          )
          .join('+'),
    )
    .join(' ');

String _sorted(String key) => (key.split('-')..sort()).join('-');

bool _same(String a, String b) => _sorted(a) == _sorted(b);

/// What the user's Zed setup already does with [key], as sentences. Based on
/// Zed's default and base keymaps and on common OS shortcuts. A binding in
/// the user's keymap wins over Zed's at the same level, but an editor-level
/// binding (Sublime Text, Emacs, Vim) wins over ours while the cursor is in
/// a file, so those are the conflicts that break a key.
List<String> keyConflicts(
  String key,
  HostOs os, {
  String? baseKeymap,
  bool vimMode = false,
}) {
  final base = baseKeymap?.toLowerCase();
  final notes = <String>[];
  final shown = displayKey(key);
  if (_same(key, 'ctrl-f5')) {
    if (os == HostOs.macos && base == 'sublimetext') {
      notes.add(
        'The Sublime Text keymap uses $shown to sort lines while the cursor '
        'is in a file, and that wins over this key. Pick another key.',
      );
    }
    if (os == HostOs.macos) {
      notes.add(
        'macOS may use $shown to move focus to the toolbar. If the key does '
        'nothing, turn that off in System Settings > Keyboard > Keyboard '
        'Shortcuts > Keyboard.',
      );
    }
    if (os == HostOs.linux) {
      notes.add(
        'Some Linux desktops, such as Xfce, use $shown to switch workspace. '
        'If the key does nothing, free it in your desktop\'s keyboard '
        'settings or pick another key.',
      );
    }
    if (base == 'jetbrains') {
      notes.add(
        'The JetBrains keymap uses $shown to rerun the last task. This '
        'binding replaces it during a debug session.',
      );
    }
  }
  final save = os == HostOs.macos ? 'cmd-s' : 'ctrl-s';
  final saveAs = os == HostOs.macos ? 'cmd-shift-s' : 'ctrl-shift-s';
  if (_same(key, save)) {
    notes.add(
      '$shown is Save. During a debug session it saves all files and then '
      'runs the task.',
    );
  }
  if (_same(key, saveAs)) {
    notes.add('$shown is Save As. It does not work during a debug session.');
  }
  if (_same(key, 'ctrl-s') && base == 'emacs') {
    notes.add(
      'The Emacs keymap uses $shown to search while the cursor is in a file, '
      'and that wins over this key. Pick another key.',
    );
  }
  if (_same(key, 'ctrl-s') && vimMode) {
    notes.add(
      'Vim mode uses $shown in insert mode, and that wins over this key '
      'there.',
    );
  }
  if (_same(key, os == HostOs.macos ? 'shift-cmd-f5' : 'ctrl-shift-f5')) {
    notes.add(
      '$shown is Zed\'s "restart debug session". This binding replaces it '
      'during a debug session; use --keep-zed-restart-key to keep it.',
    );
  }
  return notes;
}

/// Zed's debugger keys plus ours.
String keyTable(KeyChoice keys) {
  final reload = keys.reload == null ? null : displayKey(keys.reload!);
  final restart = keys.restart == null ? null : displayKey(keys.restart!);
  return [
    'Keys in Zed:',
    '  F4              Start or choose a debug scenario.',
    '  F5              Run the last scenario again; Continue when paused.',
    '  Shift+F5        Stop.',
    if (reload != null) '  ${reload.padRight(16)}Hot reload.',
    if (restart != null) '  ${restart.padRight(16)}Hot restart.',
    'The hot reload and restart keys only work while a debug session runs.',
    'Zed has no key for "run without debugging": pick a "(no debug)" scenario with F4.',
  ].join('\n');
}

/// Extra advice for macOS.
String macosKeyNote() => [
  'On macOS the F keys also need the fn key unless you turn on "Use F1, F2, etc. keys as standard function keys" in System Settings > Keyboard.',
  'If a key does nothing, check System Settings > Keyboard > Keyboard Shortcuts for a conflicting shortcut.',
].join('\n');

/// Advice for laptops, whose F keys often send media keys.
String functionKeyNote() =>
    'On many laptops the F keys control volume or brightness unless you hold '
    'Fn or turn on Fn Lock.';
