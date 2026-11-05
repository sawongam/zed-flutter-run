import 'dart:convert';
import 'dart:io';

import 'package:flutter_run/src/cli/runner.dart';
import 'package:flutter_run/src/common/errors.dart';
import 'package:flutter_run/src/init/project_detect.dart';
import 'package:flutter_run/src/init/templates.dart';
import 'package:test/test.dart';

import '../sdk/fake_sdk.dart';
import 'support.dart';

void main() {
  late TestWiring t;
  late FlutterRunRunner runner;
  late String project;

  setUp(() {
    t = TestWiring();
    runner = FlutterRunRunner(wiring: t.wiring, flushOutput: () async {});
    project = '${t.dir.path}/app';
    Directory(project).createSync();
    File('$project/pubspec.yaml').writeAsStringSync(
      'name: app\ndependencies:\n  flutter:\n    sdk: flutter\n',
    );
  });

  tearDown(() => t.dispose());

  String out() => t.console.outLines.join('\n');

  test('without an SDK it prints the trace and exits 6', () async {
    File('$project/.fvmrc').writeAsStringSync('{"flutter":"3.99.0"}');
    final code = await runner.execute(['doctor', '--project', project]);
    expect(code, ExitCodes.sdkNotFound);
    expect(out(), contains('flutter_run 0.1.0'));
    expect(out(), contains('How the Flutter SDK was looked for:'));
    expect(out(), contains('.fvmrc'));
    expect(out(), contains('Flutter SDK: not found'));
    expect(out(), contains('flutter_run on PATH: no'));
    expect(out(), contains('.zed/debug.json: not found'));
    expect(out(), contains('FLUTTER_RUN_STATE_DIR='));
  });

  test('with an SDK it names it and exits 0', () async {
    final sdk = makeFakeSdk('${t.dir.path}/sdk');
    final code = await runner.execute([
      'doctor',
      '--project',
      project,
      '--flutter-sdk',
      sdk,
    ]);
    expect(code, 0);
    final shown = t.wiring.env.pathContext.normalize(sdk);
    expect(out(), contains('Flutter SDK: $shown (found by step "explicit")'));
    expect(out(), contains('Flutter version: 3.99.0'));
    expect(out(), contains('Dart version: 3.99.1'));
    expect(out(), contains('Sessions folder:'));
    expect(out(), contains('0 running'));
  });

  test('reports the .zed files written by init and their labels', () async {
    final sdk = makeFakeSdk('${t.dir.path}/sdk');
    final info = detectProject(project, t.wiring.env);
    Directory('$project/.zed').createSync();
    File(
      '$project/.zed/debug.json',
    ).writeAsStringSync(jsonEncode(debugScenarios(info)));
    File(
      '$project/.zed/tasks.json',
    ).writeAsStringSync(jsonEncode([zedTasks(info).first]));
    await runner.execute([
      'doctor',
      '--project',
      project,
      '--flutter-sdk',
      sdk,
    ]);
    expect(
      out(),
      contains('.zed/debug.json: found, with all flutter_run entries'),
    );
    expect(out(), contains('.zed/tasks.json: found, missing'));
  });

  test('a .zed file with comments is reported, not edited', () async {
    final sdk = makeFakeSdk('${t.dir.path}/sdk');
    Directory('$project/.zed').createSync();
    const text = '// my tasks\n[]\n';
    File('$project/.zed/tasks.json').writeAsStringSync(text);
    await runner.execute([
      'doctor',
      '--project',
      project,
      '--flutter-sdk',
      sdk,
    ]);
    expect(out(), contains('.zed/tasks.json: found, but it is not plain JSON'));
    expect(File('$project/.zed/tasks.json').readAsStringSync(), text);
  });

  test('a binary on the PATH is reported as found', () async {
    final bin = Directory('${t.dir.path}/bin')..createSync();
    final exe = File('${bin.path}/flutter_run')
      ..writeAsStringSync('#!/bin/sh\n');
    Process.runSync('chmod', ['+x', exe.path]);
    final tt = TestWiring(env: {'PATH': bin.path});
    addTearDown(tt.dispose);
    final sdk = makeFakeSdk('${tt.dir.path}/sdk');
    final r = FlutterRunRunner(wiring: tt.wiring, flushOutput: () async {});
    expect(
      await r.execute(['doctor', '--project', project, '--flutter-sdk', sdk]),
      0,
    );
    expect(
      tt.console.outLines.join('\n'),
      isNot(contains('flutter_run on PATH: no')),
    );
  }, skip: Platform.isWindows ? 'uses a shell script' : false);
}
