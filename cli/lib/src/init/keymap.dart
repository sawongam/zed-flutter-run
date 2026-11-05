import '../common/host_environment.dart';
import 'json_merge.dart';

/// The keymap snippet for [os] (a JSON array, never written to disk).
/// [keepZedRestartKey] leaves out the hot restart binding so that Zed's own
/// restart key stays as it is.
String keymapSnippet(HostOs os, {bool keepZedRestartKey = false}) {
  Object? spawn(String task) => <Object?>[
    'task::Spawn',
    <String, Object?>{'task_name': task},
  ];
  final restartKey = os == HostOs.macos ? 'shift-cmd-f5' : 'ctrl-shift-f5';
  final bindings = <String, Object?>{
    'ctrl-f5': spawn('Flutter: Hot Reload'),
    if (!keepZedRestartKey) restartKey: spawn('Flutter: Hot Restart'),
    'ctrl-alt-shift-d': spawn('Flutter: Open DevTools'),
  };
  return encodeJsonFile(<Object?>[
    <String, Object?>{
      'context': 'Workspace && debugger_session',
      'bindings': bindings,
    },
  ]).trimRight();
}

/// Zed's debugger keys plus ours.
String keyTable() => [
  'Keys in Zed:',
  '  F4              Start or choose a debug scenario (first time).',
  '  F5              Run the last scenario again; Continue when paused.',
  '  Shift+F5        Stop.',
  '  Ctrl+F5         Hot reload (needs the keymap snippet below).',
  '  Ctrl+Shift+F5   Hot restart (needs the keymap snippet below).',
  'F5 does nothing while the app runs. Ctrl+F5 and Ctrl+Shift+F5 only work while a debug session is running.',
  'Zed has no key for "run without debugging": pick "Flutter: Run (no debug)" with F4.',
].join('\n');

/// Extra advice for macOS.
String macosKeyNote() => [
  'On macOS the F keys also need the fn key unless you turn on "Use F1, F2, etc. keys as standard function keys" in System Settings > Keyboard.',
  'If a key does nothing, check System Settings > Keyboard > Keyboard Shortcuts for a conflicting shortcut. Hot restart uses Shift+Cmd+F5 there.',
].join('\n');
