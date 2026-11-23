import 'dart:io';

import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/init/project_detect.dart';
import 'package:flutter_run/src/init/templates.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _flutterPubspec =
    'name: app\ndependencies:\n  flutter:\n    sdk: flutter\n';

void main() {
  late Directory tmp;
  late HostEnvironment env;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rd_init_targets_');
    env = HostEnvironment(
      os: HostEnvironment.system().os,
      environment: const {},
      currentDirectory: tmp.path,
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(String relative, String content) {
    final f = File(p.joinAll([tmp.path, ...relative.split('/')]));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  ProjectInfo detect() => detectProject(tmp.path, env);

  test('lib/main.dart means the plain set', () {
    write('pubspec.yaml', _flutterPubspec);
    write('lib/main.dart', '');
    write('lib/main_dev.dart', '');
    final info = detect();
    expect(info.launchTargets, isEmpty);
    expect(info.missingMain, isFalse);
  });

  test('no entry point at all is reported', () {
    write('pubspec.yaml', _flutterPubspec);
    expect(detect().missingMain, isTrue);
  });

  test('main_<flavor>.dart gets --flavor only with a native flavor', () {
    write('pubspec.yaml', _flutterPubspec);
    write('lib/main_dev.dart', '');
    write('lib/main_staging.dart', '');
    write(
      'android/app/build.gradle.kts',
      'android {\n  productFlavors {\n    create("dev") {}\n  }\n}\n',
    );
    final targets = detect().launchTargets;
    expect(targets.map((t) => t.name), ['dev', 'staging']);
    expect(targets[0].program, 'lib/main_dev.dart');
    expect(targets[0].toolArgs, ['--flavor', 'dev']);
    expect(targets[1].toolArgs, isEmpty);
    expect(detect().missingMain, isFalse);
  });

  test('an iOS scheme counts as a native flavor', () {
    write('pubspec.yaml', _flutterPubspec);
    write('lib/main_prod.dart', '');
    write('ios/Runner.xcodeproj/xcshareddata/xcschemes/prod.xcscheme', '');
    expect(detect().launchTargets.single.toolArgs, ['--flavor', 'prod']);
  });

  test('.vscode/launch.json wins and is read as JSONC', () {
    write('pubspec.yaml', _flutterPubspec);
    write('lib/main_dev.dart', '');
    write('.vscode/launch.json', r'''
{
  // VS Code writes comments here.
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Launch dev",
      "request": "launch",
      "type": "dart",
      "program": "${workspaceFolder}/lib/main_dev.dart",
      "args": ["--flavor", "dev", "--target", "lib/main_dev.dart"],
      "toolArgs": ["--dart-define=A=1"],
      "env": {"X": "1"},
    },
    {"name": "Profile", "type": "dart", "flutterMode": "profile"},
    {"name": "Attach", "type": "dart", "request": "attach"},
    {"name": "Other app", "type": "dart", "cwd": "apps/other"},
    {"name": "Node", "type": "node", "program": "x.js"},
    {"name": "Odd", "type": "dart", "program": "${file}"},
  ],
}
''');
    final targets = detect().launchTargets;
    expect(targets.map((t) => t.name), ['Launch dev', 'Profile']);
    final dev = targets.first;
    expect(dev.fromLaunchJson, isTrue);
    expect(dev.program, 'lib/main_dev.dart');
    expect(dev.toolArgs, ['--dart-define=A=1', '--flavor', 'dev']);
    expect(dev.env, {'X': '1'});
    expect(targets[1].program, 'lib/main.dart');
    expect(targets[1].flutterMode, 'profile');
  });

  test('an unreadable launch.json is ignored', () {
    write('pubspec.yaml', _flutterPubspec);
    write('lib/main.dart', '');
    write('.vscode/launch.json', '{ not json');
    expect(detect().launchTargets, isEmpty);
  });

  test('local path packages inside the project become watch globs', () {
    write('pubspec.yaml', '''
name: app
dependencies:
  flutter:
    sdk: flutter
  app_ui:
    path: packages/app_ui/
  shared:
    path: ../shared
  missing:
    path: packages/missing
dev_dependencies:
  app_test:
    path: ./packages/app_test
workspace:
  - packages/app_ui
''');
    Directory(p.join(tmp.path, 'packages', 'app_ui'))
        .createSync(recursive: true);
    Directory(p.join(tmp.path, 'packages', 'app_test'))
        .createSync(recursive: true);
    expect(detect().packageGlobs, [
      'packages/app_test/lib/**.dart',
      'packages/app_ui/lib/**.dart',
    ]);
  });

  group('scenarios from targets', () {
    const flavors = ProjectInfo(
      root: '/p',
      name: 'app',
      kind: ProjectKind.flutter,
      usesFvm: false,
      dartEntry: 'lib/main.dart',
      launchTargets: [
        LaunchTarget(
          name: 'dev',
          program: 'lib/main_dev.dart',
          toolArgs: ['--flavor', 'dev'],
        ),
      ],
      packageGlobs: ['packages/a/lib/**.dart'],
    );

    test('a flavor file gets debug, no-debug and attach', () {
      final s = debugScenarios(flavors);
      expect(s.map((e) => e['label']), [
        'Flutter: Debug dev',
        'Flutter: Run dev (no debug)',
        'Flutter: Attach',
      ]);
      expect(s[0]['program'], 'lib/main_dev.dart');
      expect(s[0]['toolArgs'], ['--flavor', 'dev']);
      expect(s[0]['reloadOnSaveGlobs'], ['packages/a/lib/**.dart']);
      expect(s[1]['noDebug'], isTrue);
      expect(s[2]['reloadOnSaveGlobs'], ['packages/a/lib/**.dart']);
    });

    test('a launch.json entry keeps its name; profile has no reload', () {
      const info = ProjectInfo(
        root: '/p',
        name: 'app',
        kind: ProjectKind.flutter,
        usesFvm: false,
        dartEntry: 'lib/main.dart',
        launchTargets: [
          LaunchTarget(
            name: 'Profile',
            program: 'lib/main.dart',
            flutterMode: 'profile',
            fromLaunchJson: true,
          ),
        ],
      );
      final s = debugScenarios(info).first;
      expect(s['label'], 'Flutter: Profile');
      expect(s['flutterMode'], 'profile');
      expect(s.containsKey('reloadOnSave'), isFalse);
    });
  });
}
