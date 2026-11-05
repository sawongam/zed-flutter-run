import 'dart:convert';

import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/init/keymap.dart';
import 'package:flutter_run/src/init/project_detect.dart';
import 'package:flutter_run/src/init/templates.dart';
import 'package:test/test.dart';

/// Keys of Zed's TaskTemplate (crates/task/src/task_template.rs).
const _taskKeys = {
  'label',
  'command',
  'args',
  'env',
  'cwd',
  'use_new_terminal',
  'allow_concurrent_runs',
  'reveal',
  'reveal_target',
  'hide',
  'tags',
  'shell',
  'show_summary',
  'show_command',
  'save',
  'hooks',
};

const _flutter = ProjectInfo(
  root: '/p',
  name: 'app',
  kind: ProjectKind.flutter,
  usesFvm: false,
  dartEntry: 'lib/main.dart',
);
const _dart = ProjectInfo(
  root: '/p',
  name: 'tool',
  kind: ProjectKind.dart,
  usesFvm: false,
  dartEntry: 'bin/tool.dart',
);

void main() {
  group('debugScenarios', () {
    test('Flutter labels, adapter and reloadOnSave', () {
      final s = debugScenarios(_flutter);
      expect(s.map((e) => e['label']), [
        'Flutter: Debug',
        'Flutter: Run (no debug)',
        'Flutter: Profile',
        'Flutter: Attach',
      ]);
      for (final e in s) {
        expect(e['adapter'], 'FlutterRun');
        expect(e['cwd'], r'$ZED_WORKTREE_ROOT');
      }
      for (final label in [
        'Flutter: Debug',
        'Flutter: Run (no debug)',
        'Flutter: Attach',
      ]) {
        expect(
          s.firstWhere((e) => e['label'] == label)['reloadOnSave'],
          'changed',
        );
      }
      expect(s[1]['noDebug'], isTrue);
      expect(s[2]['toolArgs'], ['--profile']);
      expect(s[3]['request'], 'attach');
      expect(s[0]['request'], 'launch');
      expect(s[0]['type'], 'flutter');
      expect(s[0]['program'], 'lib/main.dart');
    });

    test('Dart package gets one scenario', () {
      final s = debugScenarios(_dart);
      expect(s, hasLength(1));
      expect(s.single, {
        'label': 'Dart: Debug bin/tool.dart',
        'adapter': 'FlutterRun',
        'request': 'launch',
        'type': 'dart',
        'program': 'bin/tool.dart',
        'cwd': r'$ZED_WORKTREE_ROOT',
      });
    });

    test('round-trips as JSON', () {
      expect(
        jsonDecode(jsonEncode(debugScenarios(_flutter))),
        isA<List<Object?>>(),
      );
    });
  });

  group('zedTasks', () {
    final tasks = zedTasks(_flutter);
    Map<String, Object?> byLabel(String l) =>
        tasks.firstWhere((t) => t['label'] == l);

    test('labels are unique and exactly the planned ones', () {
      expect(tasks.map((t) => t['label']).toList(), [
        'Flutter: Hot Reload',
        'Flutter: Hot Restart',
        'Flutter: Select Device',
        'Flutter: Launch Emulator',
        'Flutter: Devices',
        'Flutter: Open DevTools',
        'Flutter: DevTools Inspector',
        'Flutter: DevTools Performance',
        'Flutter: Doctor',
      ]);
      expect(tasks.map((t) => t['label']).toSet(), hasLength(tasks.length));
    });

    test('only Zed TaskTemplate keys, command and cwd', () {
      for (final t in tasks) {
        expect(_taskKeys.containsAll(t.keys), isTrue, reason: '${t['label']}');
        expect(t['command'], 'flutter_run');
        expect(t['cwd'], r'$ZED_WORKTREE_ROOT');
      }
    });

    test('args', () {
      expect(byLabel('Flutter: Hot Reload')['args'], ['reload']);
      expect(byLabel('Flutter: Hot Restart')['args'], ['restart']);
      expect(byLabel('Flutter: Select Device')['args'], ['select-device']);
      expect(byLabel('Flutter: Launch Emulator')['args'], ['emulators']);
      expect(byLabel('Flutter: Devices')['args'], ['devices']);
      expect(byLabel('Flutter: Open DevTools')['args'], ['devtools']);
      expect(byLabel('Flutter: DevTools Inspector')['args'], [
        'devtools',
        'inspector',
      ]);
      expect(byLabel('Flutter: DevTools Performance')['args'], [
        'devtools',
        'performance',
      ]);
      expect(byLabel('Flutter: Doctor')['args'], ['doctor']);
    });

    test('reveal / hide / terminal settings', () {
      for (final l in ['Flutter: Hot Reload', 'Flutter: Hot Restart']) {
        final t = byLabel(l);
        expect(t['reveal'], 'no_focus');
        expect(t['hide'], 'on_success');
        expect(t['use_new_terminal'], isTrue);
        expect(t['allow_concurrent_runs'], isTrue);
        expect(t['show_summary'], isFalse);
        expect(t['show_command'], isFalse);
        expect(t['save'], 'all');
      }
      for (final l in ['Flutter: Select Device', 'Flutter: Launch Emulator']) {
        final t = byLabel(l);
        expect(t['reveal'], 'always');
        expect(t['hide'], 'never');
        expect(t['use_new_terminal'], isTrue);
        expect(t['allow_concurrent_runs'], isFalse);
      }
      final devices = byLabel('Flutter: Devices');
      expect(devices['use_new_terminal'], isFalse);
      expect(devices['allow_concurrent_runs'], isTrue);
      expect(devices['reveal'], 'always');
      expect(devices['hide'], 'never');
      for (final l in [
        'Flutter: Open DevTools',
        'Flutter: DevTools Inspector',
        'Flutter: DevTools Performance',
      ]) {
        final t = byLabel(l);
        expect(t['reveal'], 'no_focus');
        expect(t['hide'], 'on_success');
        expect(t['use_new_terminal'], isTrue);
        expect(t['allow_concurrent_runs'], isTrue);
      }
      final doctor = byLabel('Flutter: Doctor');
      expect(doctor['use_new_terminal'], isFalse);
      expect(doctor['reveal'], 'always');
      expect(doctor['hide'], 'never');
    });

    test('Dart package only gets Doctor', () {
      final t = zedTasks(_dart);
      expect(t.map((e) => e['label']), ['Flutter: Doctor']);
    });
  });

  group('keymap', () {
    const verifiedContext = 'Workspace && debugger_session';

    for (final os in HostOs.values) {
      test('snippet for $os parses and uses only task::Spawn', () {
        final decoded = jsonDecode(keymapSnippet(os)) as List<Object?>;
        expect(decoded, hasLength(1));
        final block = decoded.single! as Map<String, Object?>;
        expect(block['context'], verifiedContext);
        final bindings = block['bindings']! as Map<String, Object?>;
        final labels = <String>{
          'Flutter: Hot Reload',
          'Flutter: Hot Restart',
          'Flutter: Open DevTools',
        };
        for (final v in bindings.values) {
          final action = v! as List<Object?>;
          expect(action[0], 'task::Spawn');
          expect(
            labels,
            contains((action[1]! as Map<String, Object?>)['task_name']),
          );
        }
        expect(bindings.keys, contains('ctrl-f5'));
        expect(bindings.keys, contains('ctrl-alt-shift-d'));
        expect(
          bindings.keys,
          contains(os == HostOs.macos ? 'shift-cmd-f5' : 'ctrl-shift-f5'),
        );
      });

      test('keepZedRestartKey omits the restart binding on $os', () {
        final decoded =
            jsonDecode(keymapSnippet(os, keepZedRestartKey: true))
                as List<Object?>;
        final bindings =
            ((decoded.single! as Map<String, Object?>)['bindings'])!
                as Map<String, Object?>;
        expect(bindings.keys, isNot(contains('ctrl-shift-f5')));
        expect(bindings.keys, isNot(contains('shift-cmd-f5')));
        expect(bindings.keys, containsAll(['ctrl-f5', 'ctrl-alt-shift-d']));
      });
    }

    test('key table text', () {
      final t = keyTable();
      expect(t, contains('F4'));
      expect(t, contains('F5'));
      expect(t, contains('Shift+F5'));
      expect(t, contains('Ctrl+F5'));
      expect(t, contains('Ctrl+Shift+F5'));
      expect(t, contains('F5 does nothing while the app runs'));
      expect(t, contains('Flutter: Run (no debug)'));
      expect(t, isNot(contains('\r')));
    });

    test('macOS note mentions fn key', () {
      expect(macosKeyNote(), contains('fn'));
      expect(macosKeyNote(), contains('Use F1, F2'));
    });
  });
}
