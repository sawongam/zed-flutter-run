import 'dart:convert';
import 'dart:io';

import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/common/paths.dart';
import 'package:flutter_run/src/devices/device_store.dart';
import 'package:json_schema/json_schema.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/build_exe.dart';
import 'support/cli_runner.dart';
import 'support/scenarios.dart';
import 'support/temp_project.dart';

void main() {
  late TempWorkspace ws;
  late String exe;

  setUpAll(() async {
    exe = await ensureFlutterRunExe();
  });

  setUp(() {
    ws = TempWorkspace.create();
    addTearDown(ws.dispose);
  });

  Future<CliRun> cli(List<String> args, {String? cwd, int? expectExit}) =>
      runCli(
        exe,
        args,
        stateDir: ws.stateDir,
        workingDirectory: cwd,
        expectExit: expectExit,
      );

  /// A minimal Flutter project: the sample app's pubspec and entry point.
  Directory flutterProject() {
    final fixtures = p.join(repoRoot().path, 'fixtures', 'sample_app');
    final dir = Directory(p.join(ws.projectsDir, 'init_app'))
      ..createSync(recursive: true);
    File(
      p.join(fixtures, 'pubspec.yaml'),
    ).copySync(p.join(dir.path, 'pubspec.yaml'));
    Directory(p.join(dir.path, 'lib')).createSync();
    File(
      p.join(fixtures, 'lib', 'main.dart'),
    ).copySync(p.join(dir.path, 'lib', 'main.dart'));
    return Directory(dir.resolveSymbolicLinksSync());
  }

  group('without a debug session', () {
    test(
      'init writes valid debug.json and tasks.json, and is idempotent',
      () async {
        final project = flutterProject();
        final first = await cli(['init'], cwd: project.path, expectExit: 0);
        expect(first.stdout, contains('Created .zed/debug.json'));

        final debugFile = File(p.join(project.path, '.zed', 'debug.json'));
        final tasksFile = File(p.join(project.path, '.zed', 'tasks.json'));
        expect(debugFile.existsSync(), isTrue);
        expect(tasksFile.existsSync(), isTrue);

        // Strict JSON (no comments) that the schema accepts entry by entry.
        final scenarios =
            jsonDecode(debugFile.readAsStringSync()) as List<Object?>;
        expect(scenarios, isNotEmpty);
        jsonDecode(tasksFile.readAsStringSync());
        final schemaFile = File(
          p.join(
            repoRoot().path,
            'extension',
            'debug_adapter_schemas',
            'FlutterRun.json',
          ),
        );
        final schema = JsonSchema.create(
          jsonDecode(schemaFile.readAsStringSync()) as Map<String, Object?>,
        );
        for (final entry in scenarios) {
          final result = schema.validate(entry);
          expect(result.isValid, isTrue, reason: '$entry: ${result.errors}');
          expect((entry! as Map)['adapter'], 'FlutterRun');
        }

        // A second run adds nothing and changes nothing.
        final debugBefore = debugFile.readAsBytesSync();
        final tasksBefore = tasksFile.readAsBytesSync();
        final second = await cli(['init'], cwd: project.path, expectExit: 0);
        expect(second.stdout, contains('Added 0 entries'));
        expect(debugFile.readAsBytesSync(), debugBefore);
        expect(tasksFile.readAsBytesSync(), tasksBefore);
      },
    );

    test('init leaves a tasks.json with comments alone and exits 9', () async {
      final project = flutterProject();
      final tasksFile = File(p.join(project.path, '.zed', 'tasks.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('// my tasks\n[\n  // keep me\n]\n');
      final before = tasksFile.readAsStringSync();
      final result = await cli(['init'], cwd: project.path, expectExit: 9);
      expect(tasksFile.readAsStringSync(), before);
      expect(result.combined, contains('tasks.json'));
    });

    test('status with no sessions exits 0', () async {
      final result = await cli(['status'], expectExit: 0);
      expect(result.stdout, contains('No running debug sessions'));
    });

    test('reload and restart with no session exit 3 with guidance', () async {
      final project = flutterProject();
      for (final command in ['reload', 'restart']) {
        final result = await cli([
          command,
          '--project',
          project.path,
        ], expectExit: 3);
        expect(
          result.combined,
          contains('No running Flutter app found for ${project.path}'),
        );
        expect(result.combined, contains('Start one from the debugger first'));
      }
    });

    test(
      'doctor reports the Flutter SDK, or exits 6 when there is none',
      () async {
        final project = flutterProject();
        // This group also runs in CI jobs that only have a Dart SDK. A Flutter
        // project then correctly has no Flutter SDK, so doctor exits 6.
        final env = HostEnvironment.system();
        final hasFlutter =
            findExecutableOnPath('flutter', env) != null ||
            (env.env('FLUTTER_ROOT') ?? '').isNotEmpty;
        final result = await cli([
          'doctor',
          '--project',
          project.path,
        ], expectExit: hasFlutter ? 0 : 6);
        if (hasFlutter) {
          expect(result.stdout, contains('Dart version:'));
          expect(result.stdout, matches(RegExp(r'Flutter SDK: (?!not found)')));
        } else {
          expect(
            result.stdout,
            contains('How the Flutter SDK was looked for:'),
          );
          expect(result.stdout, contains('Flutter SDK: not found'));
        }
      },
    );

    test('version prints the package version', () async {
      final result = await cli(['version'], expectExit: 0);
      expect(result.stdout.trim(), 'flutter_run 0.1.0');
    });

    test('status prunes a session file whose proxy is gone', () async {
      final project = flutterProject();
      // A port nobody listens on: bind, remember, close.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close();
      final sessions = Directory(ws.sessionsDir)..createSync(recursive: true);
      final file = File(p.join(sessions.path, '999999.json'))
        ..writeAsStringSync(
          jsonEncode({
            'version': 1,
            'pid': 999999,
            'port': deadPort,
            'token': 'AAAA',
            'projectRoot': project.path,
            'cwd': project.path,
            'kind': 'flutter',
            'request': 'launch',
            'startedAt': DateTime.now().toUtc().toIso8601String(),
            'appStarted': true,
          }),
        );
      final result = await cli([
        'status',
        '--json',
        '--project',
        project.path,
      ], expectExit: 0);
      final listed = (jsonDecode(result.stdout) as Map)['sessions'] as List;
      expect(listed, isEmpty, reason: result.stdout);
      expect(file.existsSync(), isFalse, reason: 'the stale file is deleted');
    });
  }, tags: ['integration-dart']);

  group('with the Flutter tool', () {
    test('devices --json is non-interactive and lists devices', () async {
      final project = flutterProject();
      final result = await cli([
        'devices',
        '--json',
        '--project',
        project.path,
      ], expectExit: 0);
      final decoded = jsonDecode(result.stdout) as Map<String, Object?>;
      expect(decoded['devices'], isA<List<Object?>>());
      expect(decoded.containsKey('saved'), isTrue);
    });

    test(
      'select-device rejects an id that is not connected (exit 7)',
      () async {
        final project = flutterProject();
        // flutter-tester only shows up with --show-test-device.
        final result = await cli([
          'select-device',
          '--device',
          'flutter-tester',
          '--project',
          project.path,
        ], expectExit: 7);
        expect(result.combined, contains('flutter-tester'));
      },
    );

    test('select-device without a terminal exits 2', () async {
      final project = flutterProject();
      final result = await cli([
        'select-device',
        '--project',
        project.path,
      ], expectExit: 2);
      expect(result.combined, contains('needs a terminal'));
    });

    test('a saved device is injected as -d on the next launch', () async {
      await preparedFixture('sample_app');
      final app = await ws.copyFixture('sample_app');
      final env = HostEnvironment(
        os: HostOs.linux,
        environment: {'FLUTTER_RUN_STATE_DIR': ws.stateDir},
        currentDirectory: app.path,
      );
      await DeviceStore(env).write(
        app.path,
        SavedDevice(
          deviceId: 'flutter-tester',
          name: 'Flutter test device',
          platform: 'flutter-tester',
          savedAt: DateTime.now(),
        ),
      );
      final s = await FlutterLaunch.start(
        ws,
        app: app,
        toolArgs: showTesterOnly,
        launchArgs: {'reloadOnSave': 'off'},
      );
      final launch = s.harness.forwarded('launch').single['arguments'] as Map;
      expect(launch['toolArgs'], [...showTesterOnly, '-d', 'flutter-tester']);
      expect(
        s.client.countOutputs('Using device flutter-tester (saved selection).'),
        1,
      );
      await s.harness.zedStop();
    });
  }, tags: ['integration']);
}
