import '../common/json_types.dart';
import 'project_detect.dart';

const String _adapter = 'FlutterRun';
const String _root = r'$ZED_WORKTREE_ROOT';

/// Debug scenarios for `.zed/debug.json` (pure, deterministic order).
List<Json> debugScenarios(ProjectInfo p) {
  if (p.kind == ProjectKind.dart) {
    return <Json>[
      <String, Object?>{
        'label': 'Dart: Debug ${p.dartEntry}',
        'adapter': _adapter,
        'request': 'launch',
        'type': 'dart',
        'program': p.dartEntry,
        'cwd': _root,
      },
    ];
  }
  Json launch(String label, Json extra) => <String, Object?>{
    'label': label,
    'adapter': _adapter,
    'request': 'launch',
    'type': 'flutter',
    'program': 'lib/main.dart',
    'cwd': _root,
    ...extra,
  };
  return <Json>[
    launch('Flutter: Debug', {'reloadOnSave': 'changed'}),
    launch('Flutter: Run (no debug)', {
      'noDebug': true,
      'reloadOnSave': 'changed',
    }),
    launch('Flutter: Profile', {
      'toolArgs': <String>['--profile'],
    }),
    <String, Object?>{
      'label': 'Flutter: Attach',
      'adapter': _adapter,
      'request': 'attach',
      'type': 'flutter',
      'cwd': _root,
      'reloadOnSave': 'changed',
    },
  ];
}

/// Tasks for `.zed/tasks.json` (pure, deterministic order).
List<Json> zedTasks(ProjectInfo p) {
  Json task(String label, List<String> args, Json extra) => <String, Object?>{
    'label': label,
    'command': 'flutter_run',
    'args': args,
    'cwd': _root,
    ...extra,
  };

  final doctor = task(
    'Flutter: Doctor',
    ['doctor'],
    {'use_new_terminal': false, 'reveal': 'always', 'hide': 'never'},
  );
  if (p.kind == ProjectKind.dart) return <Json>[doctor];

  final hot = <String, Object?>{
    'use_new_terminal': true,
    'allow_concurrent_runs': true,
    'reveal': 'no_focus',
    'hide': 'on_success',
    'show_summary': false,
    'show_command': false,
    'save': 'all',
  };
  final picker = <String, Object?>{
    'use_new_terminal': true,
    'allow_concurrent_runs': false,
    'reveal': 'always',
    'hide': 'never',
  };
  final devtools = <String, Object?>{
    'use_new_terminal': true,
    'allow_concurrent_runs': true,
    'reveal': 'no_focus',
    'hide': 'on_success',
  };
  return <Json>[
    task('Flutter: Hot Reload', ['reload'], hot),
    task('Flutter: Hot Restart', ['restart'], hot),
    task('Flutter: Select Device', ['select-device'], picker),
    task('Flutter: Launch Emulator', ['emulators'], picker),
    task(
      'Flutter: Devices',
      ['devices'],
      {
        'use_new_terminal': false,
        'allow_concurrent_runs': true,
        'reveal': 'always',
        'hide': 'never',
      },
    ),
    task('Flutter: Open DevTools', ['devtools'], devtools),
    task('Flutter: DevTools Inspector', ['devtools', 'inspector'], devtools),
    task('Flutter: DevTools Performance', [
      'devtools',
      'performance',
    ], devtools),
    doctor,
  ];
}
