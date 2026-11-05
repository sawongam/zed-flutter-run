import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_run/src/common/console.dart';
import 'package:flutter_run/src/common/errors.dart';
import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/devices/commands/devices_command.dart';
import 'package:flutter_run/src/devices/commands/emulators_command.dart';
import 'package:flutter_run/src/devices/commands/select_device_command.dart';
import 'package:flutter_run/src/devices/device_lister.dart';
import 'package:flutter_run/src/devices/device_store.dart';
import 'package:flutter_run/src/devices/emulators.dart';
import 'package:flutter_run/src/devices/flutter_device.dart';
import 'package:flutter_run/src/devices/picker.dart';
import 'package:test/test.dart';

String fixture(String name) =>
    File('test/unit/devices/fixtures/$name').readAsStringSync();

final hostOs = HostEnvironment.system().os;

HostEnvironment hostEnv({
  required String state,
  required String cwd,
  HostOs os = HostOs.linux,
}) => HostEnvironment(
  os: os,
  environment: {'FLUTTER_RUN_STATE_DIR': state, 'HOME': '/home/x'},
  currentDirectory: cwd,
);

void main() {
  group('parseDevicesMachineOutput', () {
    test('real output (Linux + Chrome)', () {
      final devices = parseDevicesMachineOutput(
        fixture('devices_machine.stdout.json'),
      );
      expect(devices.map((d) => d.id), ['linux', 'chrome']);
      expect(devices.first.name, 'Linux');
      expect(devices.first.platform, 'linux-x64');
      expect(devices.last.platform, 'web-javascript');
      expect(devices.first.emulator, isFalse);
      expect(devices.first.isSupported, isTrue);
      expect(devices.first.sdk, contains('Ubuntu'));
    });

    test('real output with --show-test-device', () {
      final devices = parseDevicesMachineOutput(
        fixture('devices_machine_show_test_device.stdout.json'),
      );
      expect(devices.map((d) => d.id), ['flutter-tester', 'linux', 'chrome']);
    });

    test('leading root-user banner is skipped', () {
      final devices = parseDevicesMachineOutput(
        fixture('devices_machine_with_banner.txt'),
      );
      expect(devices.map((d) => d.id), ['linux', 'chrome']);
    });

    test('noise containing brackets before the array is skipped', () {
      final devices = parseDevicesMachineOutput(
        '[!] Something odd [1]\n'
        '[{"name":"A","id":"a","targetPlatform":"android-arm64",'
        '"emulator":true,"category":"mobile","isSupported":false}]\n'
        'trailing note\n',
      );
      expect(devices, hasLength(1));
      expect(devices.single.emulator, isTrue);
      expect(devices.single.category, 'mobile');
      expect(devices.single.isSupported, isFalse);
    });

    test('bracketed text after the array does not confuse the parser', () {
      const json = '[{"name":"A","id":"a","targetPlatform":"x"}]';
      expect(parseDevicesMachineOutput('$json\nnote [1]').single.id, 'a');
      expect(
        parseDevicesMachineOutput('$json\nnote [see docs]').single.id,
        'a',
      );
      expect(
        parseDevicesMachineOutput(
          '[{"name":"a ] [ b","id":"a\\"]","targetPlatform":"x"}]\n[2]',
        ).single.id,
        'a"]',
      );
    });

    test('empty list', () {
      expect(parseDevicesMachineOutput('[]'), isEmpty);
      expect(parseDevicesMachineOutput('banner\n[\n]\n'), isEmpty);
    });

    test('garbage throws ExternalToolException', () {
      expect(
        () => parseDevicesMachineOutput('not json'),
        throwsA(isA<ExternalToolException>()),
      );
      expect(
        () => parseDevicesMachineOutput('[{"id": '),
        throwsA(isA<ExternalToolException>()),
      );
    });

    test('entries without id are dropped', () {
      final devices = parseDevicesMachineOutput(
        '[{"name":"x"},{"name":"B","id":"b"},3]',
      );
      expect(devices.map((d) => d.id), ['b']);
      expect(devices.single.platform, 'unknown');
    });

    test('toJson shape', () {
      final json = const FlutterDevice(
        id: 'i',
        name: 'n',
        platform: 'p',
      ).toJson();
      expect(json.keys, [
        'id',
        'name',
        'platform',
        'category',
        'emulator',
        'sdk',
        'isSupported',
      ]);
    });
  });

  group('emulators parsing', () {
    test('sample output', () {
      final list = parseEmulatorsOutput(fixture('emulators_sample.txt'));
      expect(list.map((e) => e.id), [
        'Pixel_3a_API_30_x86',
        'Pixel_7_API_34',
        'apple_ios_simulator',
      ]);
      expect(list.first.name, 'Pixel 3a API 30 x86');
      expect(list.first.manufacturer, 'Google');
      expect(list.last.platform, 'ios');
    });

    test('real output without emulator sources parses to nothing', () {
      expect(
        parseEmulatorsOutput(fixture('emulators_none.stderr.txt')),
        isEmpty,
      );
    });

    test('unparsable lines are ignored', () {
      expect(parseEmulatorsOutput('hello\n a • b\n'), isEmpty);
    });
  });

  group('DeviceStore', () {
    late Directory tmp;
    late HostEnvironment env;
    late DeviceStore store;
    final saved = SavedDevice(
      deviceId: 'chrome',
      name: 'Chrome',
      platform: 'web-javascript',
      savedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
    );

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('rd_store');
      env = hostEnv(state: '${tmp.path}/state', cwd: tmp.path);
      store = DeviceStore(env);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('round trip, path layout and file content', () async {
      expect(store.readSync('/proj/a'), isNull);
      await store.write('/proj/a', saved);
      final path = store.filePath('/proj/a');
      expect(path, startsWith('${tmp.path}/state/devices/'));
      expect(RegExp(r'/[0-9a-f]{16}\.json$').hasMatch(path), isTrue);
      final json = jsonDecode(File(path).readAsStringSync()) as Map;
      expect(json['version'], 1);
      expect(json['projectRoot'], '/proj/a');
      final read = store.readSync('/proj/a')!;
      expect(read.deviceId, 'chrome');
      expect(read.name, 'Chrome');
      expect(read.platform, 'web-javascript');
      expect(read.savedAt, saved.savedAt);
    });

    test('per-project keying', () async {
      await store.write('/proj/a', saved);
      expect(store.readSync('/proj/b'), isNull);
      expect(store.filePath('/proj/a'), isNot(store.filePath('/proj/b')));
    });

    test('Windows paths differing by case share one file', () async {
      final win = DeviceStore(
        hostEnv(state: '${tmp.path}/w', cwd: r'C:\', os: HostOs.windows),
      );
      expect(
        win.filePath(r'C:\Work\App'),
        isNot(equals(store.filePath(r'C:\Work\App'))),
      );
      expect(win.filePath(r'C:\Work\App'), win.filePath(r'c:\work\app'));
    });

    test('unknown version, malformed and wrong shape give null', () async {
      await store.write('/p', saved);
      final file = File(store.filePath('/p'));
      final good = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;

      file.writeAsStringSync(jsonEncode({...good, 'version': 2}));
      expect(store.readSync('/p'), isNull);
      file.writeAsStringSync('{ not json');
      expect(store.readSync('/p'), isNull);
      file.writeAsStringSync('[]');
      expect(store.readSync('/p'), isNull);
      file.writeAsStringSync(jsonEncode({...good, 'deviceId': 5}));
      expect(store.readSync('/p'), isNull);
      file.writeAsStringSync(jsonEncode({...good, 'projectRoot': '/other'}));
      expect(store.readSync('/p'), isNull);
    });

    test('clear', () async {
      expect(await store.clear('/p'), isFalse);
      await store.write('/p', saved);
      expect(await store.clear('/p'), isTrue);
      expect(store.readSync('/p'), isNull);
      expect(await store.clear('/p'), isFalse);
    });
  });

  group('pickFromList', () {
    final items = ['alpha', 'beta', 'gamma'];
    String label(String s) => s.toUpperCase();

    Future<String?> pick(
      List<String> input, {
      Future<List<String>> Function()? rescan,
      MemoryConsole? console,
      String? savedId,
    }) => pickFromList<String>(
      items,
      label,
      console ?? MemoryConsole(input: input, interactive: true),
      idOf: (s) => s,
      rescan: rescan,
      savedId: savedId,
    );

    test('number', () async => expect(await pick(['2']), 'beta'));
    test('id', () async => expect(await pick(['gamma']), 'gamma'));
    test('q cancels', () async => expect(await pick(['q']), isNull));
    test('empty cancels', () async => expect(await pick(['']), isNull));
    test('end of input cancels', () async => expect(await pick([]), isNull));

    test('r rescans and shows the new list', () async {
      final console = MemoryConsole(input: ['r', '1'], interactive: true);
      final result = await pick(
        [],
        console: console,
        rescan: () async => ['new'],
      );
      expect(result, 'new');
      expect(console.outLines.join('\n'), contains('NEW'));
    });

    test('rescan does not count as invalid', () async {
      final console = MemoryConsole(
        input: ['r', 'r', 'r', 'r', 'x', 'x', '3'],
        interactive: true,
      );
      expect(
        await pick([], console: console, rescan: () async => items),
        'gamma',
      );
    });

    test('invalid then valid', () async {
      expect(await pick(['9', 'zzz', '1']), 'alpha');
    });

    test('three invalid answers throw a usage error', () async {
      await expectLater(
        pick(['0', 'x', '4']),
        throwsA(isA<UsageError>().having((e) => e.exitCode, 'exitCode', 2)),
      );
    });

    test('marks the saved item', () async {
      final console = MemoryConsole(input: ['q'], interactive: true);
      await pick([], console: console, savedId: 'beta');
      expect(
        console.outLines.where((l) => l.contains('BETA')).single,
        contains('(saved)'),
      );
      expect(
        console.outLines.where((l) => l.contains('ALPHA')).single,
        isNot(contains('(saved)')),
      );
    });
  });

  group('commands', () {
    late Directory tmp;
    late String project;
    late HostEnvironment env;
    late DeviceStore store;
    late List<List<String>> calls;
    late FlutterToolResult Function(List<String> args) responder;
    late String? lastWorkingDirectory;
    late String? lastSdk;

    final devicesJson = fixture('devices_machine.stdout.json');

    setUp(() {
      // Canonical: Windows temp paths use 8.3 short names that the commands
      // resolve to the long form.
      tmp = Directory(
        Directory.systemTemp
            .createTempSync('rd_cmd')
            .resolveSymbolicLinksSync(),
      );
      project = '${tmp.path}${Platform.pathSeparator}app';
      Directory('$project/lib').createSync(recursive: true);
      File('$project/pubspec.yaml').writeAsStringSync('name: app\n');
      env = hostEnv(
        state: '${tmp.path}/state',
        cwd: '$project/lib',
        os: hostOs,
      );
      store = DeviceStore(env);
      calls = [];
      lastWorkingDirectory = null;
      lastSdk = null;
      responder = (args) => args.first == 'devices'
          ? FlutterToolResult(0, devicesJson, '')
          : FlutterToolResult(0, fixture('emulators_sample.txt'), '');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<FlutterRunner> runnerFor({String? projectDir, String? explicitSdk}) {
      lastSdk = explicitSdk;
      return Future.value((
        List<String> args, {
        String? workingDirectory,
        Duration? timeout,
      }) async {
        calls.add(args);
        lastWorkingDirectory = workingDirectory;
        return responder(args);
      });
    }

    /// Runs [args]; returns the exit code (exceptions mapped as the runner
    /// does) and records the error text.
    Future<({int code, String? error, String? hint})> exec(
      List<String> args, {
      MemoryConsole? console,
      HostEnvironment? environment,
    }) async {
      final c = console ?? MemoryConsole();
      final e = environment ?? env;
      final runner = CommandRunner<int>('flutter_run', 'test')
        ..addCommand(
          DevicesCommand(
            runnerFor: runnerFor,
            store: store,
            env: e,
            console: c,
          ),
        )
        ..addCommand(
          SelectDeviceCommand(
            runnerFor: runnerFor,
            store: store,
            env: e,
            console: c,
          ),
        )
        ..addCommand(
          EmulatorsCommand(
            runnerFor: runnerFor,
            store: store,
            env: e,
            console: c,
          ),
        );
      try {
        return (code: await runner.run(args) ?? 0, error: null, hint: null);
      } on FlutterRunException catch (ex) {
        return (code: ex.exitCode, error: ex.message, hint: ex.hint);
      } on UsageException catch (ex) {
        return (code: ExitCodes.usage, error: ex.message, hint: null);
      }
    }

    test(
      'devices through a symlinked --project finds the saved device',
      () async {
        final link = Link('${tmp.path}/link')..createSync(project);
        final canonical = Directory(project).resolveSymbolicLinksSync();
        await store.write(
          canonical,
          SavedDevice(
            deviceId: 'chrome',
            name: 'Chrome',
            platform: 'web-javascript',
            savedAt: DateTime.now(),
          ),
        );
        final console = MemoryConsole();
        await exec([
          'devices',
          '--json',
          '--project',
          link.path,
        ], console: console);
        expect((jsonDecode(console.outLines.join()) as Map)['saved'], 'chrome');
      },
    );

    group('devices', () {
      test('table marks the saved device', () async {
        await store.write(
          project,
          SavedDevice(
            deviceId: 'chrome',
            name: 'Chrome',
            platform: 'web-javascript',
            savedAt: DateTime.now(),
          ),
        );
        final console = MemoryConsole();
        final r = await exec(['devices'], console: console);
        expect(r.code, 0);
        expect(calls.single, ['devices', '--machine']);
        expect(lastWorkingDirectory, project);
        final lines = console.outLines;
        expect(lines.firstWhere((l) => l.contains('Linux')), startsWith('  '));
        expect(lines.firstWhere((l) => l.contains('Chrome')), startsWith('*'));
        expect(lines.last, contains('saved device'));
      });

      test('--json shape', () async {
        await store.write(
          project,
          SavedDevice(
            deviceId: 'linux',
            name: 'Linux',
            platform: 'linux-x64',
            savedAt: DateTime.now(),
          ),
        );
        final console = MemoryConsole();
        final r = await exec(['devices', '--json'], console: console);
        expect(r.code, 0);
        final json = jsonDecode(console.outLines.join('\n')) as Map;
        expect(json['saved'], 'linux');
        final list = json['devices'] as List;
        expect(list, hasLength(2));
        expect(
          (list.first as Map).keys,
          containsAll(['id', 'name', 'platform']),
        );
      });

      test('--json without saved device or project gives null', () async {
        final outside = Directory('${tmp.path}/none')..createSync();
        final console = MemoryConsole();
        final r = await exec(
          ['devices', '--json'],
          console: console,
          environment: hostEnv(
            state: '${tmp.path}/state',
            cwd: outside.path,
            os: hostOs,
          ),
        );
        expect(r.code, 0);
        expect((jsonDecode(console.outLines.join()) as Map)['saved'], isNull);
      });

      test('--flutter-sdk is passed to the factory', () async {
        await exec(['devices', '--flutter-sdk', '/sdk']);
        expect(lastSdk, '/sdk');
      });

      test('zero devices exits 7 with the guidance text', () async {
        responder = (_) => const FlutterToolResult(0, '[]', '');
        final r = await exec(['devices']);
        expect(r.code, 7);
        expect(r.error, noDevicesMessage);
        expect(r.error, contains('No devices found.'));
      });

      test('flutter failure exits 10', () async {
        responder = (_) => const FlutterToolResult(1, '', 'boom\nsecond line');
        final r = await exec(['devices']);
        expect(r.code, 10);
        expect(r.error, contains('second line'));
      });

      test('garbage output exits 10', () async {
        responder = (_) => const FlutterToolResult(0, 'nope', '');
        expect((await exec(['devices'])).code, 10);
      });

      test('timeout mentions the startup lock', () async {
        responder = (_) => throw TimeoutException('slow');
        final r = await exec(['devices']);
        expect(r.code, 10);
        expect(r.error, contains('startup lock'));
      });
    });

    group('select-device', () {
      test('--device valid saves and prints the confirmation', () async {
        final console = MemoryConsole();
        final r = await exec([
          'select-device',
          '--device',
          'chrome',
        ], console: console);
        expect(r.code, 0);
        expect(store.readSync(project)!.deviceId, 'chrome');
        expect(console.outLines, [
          'Saved device: Chrome (chrome). It is used the next time you start '
              'the app. The running app keeps its device.',
          'Start the app from the debugger (F4 opens the picker in Zed).',
        ]);
      });

      test('--device from a subfolder keys on the project root', () async {
        await exec(['select-device', '--device', 'linux']);
        expect(store.readSync(project)!.name, 'Linux');
        expect(File(store.filePath(project)).existsSync(), isTrue);
      });

      test('--device unknown exits 7 listing ids', () async {
        final r = await exec(['select-device', '--device', 'nope']);
        expect(r.code, 7);
        expect(r.error, contains('"nope"'));
        expect(r.error, contains('linux, chrome'));
        expect(store.readSync(project), isNull);
      });

      test('non-interactive without --device exits 2', () async {
        final r = await exec(['select-device']);
        expect(r.code, 2);
        expect(r.error, 'select-device needs a terminal; use --device <id>.');
        expect(calls, isEmpty);
      });

      test('no project exits 8', () async {
        final outside = Directory('${tmp.path}/none')..createSync();
        final r = await exec(
          ['select-device', '--device', 'chrome'],
          environment: hostEnv(
            state: '${tmp.path}/state',
            cwd: outside.path,
            os: hostOs,
          ),
        );
        expect(r.code, 8);
      });

      test('--project points at another project', () async {
        final other = Directory('${tmp.path}/other')..createSync();
        File('${other.path}/pubspec.yaml').writeAsStringSync('name: o\n');
        final outside = Directory('${tmp.path}/none')..createSync();
        final r = await exec(
          ['select-device', '--device', 'chrome', '--project', other.path],
          environment: hostEnv(
            state: '${tmp.path}/state',
            cwd: outside.path,
            os: hostOs,
          ),
        );
        expect(r.code, 0);
        expect(
          store.readSync(other.resolveSymbolicLinksSync())?.deviceId,
          'chrome',
        );
      });

      test('zero devices exits 7', () async {
        responder = (_) => const FlutterToolResult(0, '[]', '');
        final r = await exec(['select-device', '--device', 'x']);
        expect(r.code, 7);
        expect(r.error, noDevicesMessage);
      });

      test('--clear removes the saved device', () async {
        await exec(['select-device', '--device', 'chrome']);
        final console = MemoryConsole();
        final r = await exec(['select-device', '--clear'], console: console);
        expect(r.code, 0);
        expect(store.readSync(project), isNull);
        expect(console.outLines.single, contains('Cleared'));
        expect(calls, hasLength(1)); // only the earlier --device listing

        final again = MemoryConsole();
        expect(
          (await exec(['select-device', '--clear'], console: again)).code,
          0,
        );
        expect(again.outLines.single, contains('no saved device'));
      });

      test('--clear with --device is a usage error', () async {
        expect(
          (await exec(['select-device', '--clear', '--device', 'a'])).code,
          2,
        );
      });

      test('interactive: pick by number', () async {
        final console = MemoryConsole(input: ['2'], interactive: true);
        final r = await exec(['select-device'], console: console);
        expect(r.code, 0);
        expect(store.readSync(project)!.deviceId, 'chrome');
        expect(console.outLines.first, contains('Linux (linux)'));
        expect(
          console.outLines,
          contains(contains('Saved device: Chrome (chrome).')),
        );
      });

      test('interactive: pick by id after one invalid answer', () async {
        final console = MemoryConsole(
          input: ['abc', 'linux'],
          interactive: true,
        );
        expect((await exec(['select-device'], console: console)).code, 0);
        expect(store.readSync(project)!.deviceId, 'linux');
      });

      test('interactive: r rescans', () async {
        var first = true;
        responder = (_) {
          if (first) {
            first = false;
            return const FlutterToolResult(
              0,
              '[{"name":"Old","id":"old","targetPlatform":"x"}]',
              '',
            );
          }
          return FlutterToolResult(0, devicesJson, '');
        };
        final console = MemoryConsole(
          input: ['r', 'chrome'],
          interactive: true,
        );
        expect((await exec(['select-device'], console: console)).code, 0);
        expect(calls, hasLength(2));
        expect(store.readSync(project)!.deviceId, 'chrome');
      });

      test('interactive: q and empty cancel with exit 0', () async {
        for (final answer in ['q', '']) {
          final console = MemoryConsole(input: [answer], interactive: true);
          final r = await exec(['select-device'], console: console);
          expect(r.code, 0);
          expect(store.readSync(project), isNull);
          expect(console.outLines.last, contains('Nothing was changed'));
        }
      });

      test('interactive: three invalid answers exit 2', () async {
        final console = MemoryConsole(
          input: ['a', 'b', 'c'],
          interactive: true,
        );
        final r = await exec(['select-device'], console: console);
        expect(r.code, 2);
        expect(store.readSync(project), isNull);
      });

      test('interactive: zero devices exits 7', () async {
        responder = (_) => const FlutterToolResult(0, '[]', '');
        final console = MemoryConsole(input: ['1'], interactive: true);
        expect((await exec(['select-device'], console: console)).code, 7);
      });

      test('interactive: saved device is marked', () async {
        await exec(['select-device', '--device', 'chrome']);
        final console = MemoryConsole(input: ['q'], interactive: true);
        await exec(['select-device'], console: console);
        expect(
          console.outLines.firstWhere((l) => l.contains('Chrome')),
          contains('(saved)'),
        );
      });
    });

    group('emulators', () {
      test('non-interactive lists a table', () async {
        final console = MemoryConsole();
        final r = await exec(['emulators'], console: console);
        expect(r.code, 0);
        expect(calls.single, ['emulators']);
        expect(console.outLines.first, startsWith('Id'));
        expect(console.outLines, hasLength(4));
      });

      test('--json shape', () async {
        final console = MemoryConsole();
        await exec(['emulators', '--json'], console: console);
        final list =
            (jsonDecode(console.outLines.join('\n')) as Map)['emulators']
                as List;
        expect(list, hasLength(3));
        expect(list.first, {
          'id': 'Pixel_3a_API_30_x86',
          'name': 'Pixel 3a API 30 x86',
          'manufacturer': 'Google',
          'platform': 'android',
        });
      });

      test('--launch runs flutter emulators --launch <id>', () async {
        final r = await exec(['emulators', '--launch', 'Pixel_7_API_34']);
        expect(r.code, 0);
        expect(calls.single, ['emulators', '--launch', 'Pixel_7_API_34']);
      });

      test('--launch validates the id', () async {
        for (final bad in ['--cold-boot', 'a b', 'a;rm', r'$(x)', '']) {
          final r = await exec(['emulators', '--launch', bad]);
          expect(r.code, 2, reason: bad);
        }
        expect(calls, isEmpty);
      });

      test('launchEmulator validates too', () {
        expect(
          () => launchEmulator(
            (a, {workingDirectory, timeout}) async =>
                const FlutterToolResult(0, '', ''),
            '-x',
          ),
          throwsA(isA<UsageError>()),
        );
      });

      test('--launch failure exits 10', () async {
        responder = (_) => const FlutterToolResult(1, '', 'no such emulator');
        expect((await exec(['emulators', '--launch', 'x'])).code, 10);
      });

      test('interactive: pick launches the chosen emulator', () async {
        final console = MemoryConsole(input: ['3'], interactive: true);
        final r = await exec(['emulators'], console: console);
        expect(r.code, 0);
        expect(calls.last, ['emulators', '--launch', 'apple_ios_simulator']);
      });

      test('interactive: q launches nothing', () async {
        final console = MemoryConsole(input: ['q'], interactive: true);
        expect((await exec(['emulators'], console: console)).code, 0);
        expect(calls, hasLength(1));
      });

      test('zero emulators exits 7 with the guidance text', () async {
        responder = (_) => const FlutterToolResult(0, 'nothing here', '');
        final r = await exec(['emulators']);
        expect(r.code, 7);
        expect(r.error, noDevicesMessage);
      });

      test('real "no emulator sources" failure counts as empty', () async {
        responder = (_) =>
            FlutterToolResult(1, '', fixture('emulators_none.stderr.txt'));
        expect((await exec(['emulators'])).code, 7);
        expect((await exec(['emulators', '--json'])).code, 0);
      });

      test('other failures exit 10', () async {
        responder = (_) => const FlutterToolResult(2, '', 'bad');
        expect((await exec(['emulators'])).code, 10);
      });

      test('--launch with --json is a usage error', () async {
        expect((await exec(['emulators', '--launch', 'x', '--json'])).code, 2);
      });
    });
  });
}
