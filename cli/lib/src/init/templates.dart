import '../common/json_types.dart';
import '../common/version.dart';
import 'project_detect.dart';

const String _adapter = adapterName;
const String _root = r'$ZED_WORKTREE_ROOT';

/// VM service address in the generated attach entry; the user replaces it.
const attachUriPlaceholder = 'ws://127.0.0.1:PORT/TOKEN=/ws';

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
  final watch = <String, Object?>{
    'reloadOnSave': 'changed',
    if (p.packageGlobs.isNotEmpty) 'reloadOnSaveGlobs': p.packageGlobs,
  };
  Json launch(String label, String program, Json extra) => <String, Object?>{
    'label': label,
    'adapter': _adapter,
    'request': 'launch',
    'type': 'flutter',
    'program': program,
    'cwd': _root,
    ...extra,
  };
  final launches = p.launchTargets.isEmpty
      ? <Json>[
          launch('Flutter: Debug', 'lib/main.dart', watch),
          launch('Flutter: Run (no debug)', 'lib/main.dart', {
            'noDebug': true,
            ...watch,
          }),
          launch('Flutter: Profile', 'lib/main.dart', {
            'toolArgs': <String>['--profile'],
          }),
        ]
      : <Json>[
          for (final t in p.launchTargets)
            ..._targetScenarios(t, launch, watch),
        ];
  return <Json>[
    ...launches,
    <String, Object?>{
      'label': 'Flutter: Attach',
      'adapter': _adapter,
      'request': 'attach',
      'type': 'flutter',
      'cwd': _root,
      // Replace with the VM service URI that `flutter run` prints. Attach
      // without one waits forever (see docs/CONFIGURATION.md).
      'vmServiceUri': attachUriPlaceholder,
      ...watch,
    },
  ];
}

// A launch.json entry becomes one scenario as it is. A main_<flavor>.dart
// file gets a debug and a no-debug scenario, like the plain set.
List<Json> _targetScenarios(
  LaunchTarget t,
  Json Function(String label, String program, Json extra) launch,
  Json watch,
) {
  Json extra({bool noDebug = false}) => <String, Object?>{
    if (t.toolArgs.isNotEmpty) 'toolArgs': t.toolArgs,
    if (t.flutterMode != null) 'flutterMode': t.flutterMode,
    if (t.env.isNotEmpty) 'env': t.env,
    if (noDebug) 'noDebug': true,
    if (t.flutterMode == null || t.flutterMode == 'debug') ...watch,
  };
  if (t.fromLaunchJson) {
    return [launch('Flutter: ${t.name}', t.program, extra(noDebug: t.noDebug))];
  }
  return [
    launch('Flutter: Debug ${t.name}', t.program, extra()),
    launch(
      'Flutter: Run ${t.name} (no debug)',
      t.program,
      extra(noDebug: true),
    ),
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
