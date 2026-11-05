import 'package:flutter_run/src/dap/device_hints.dart';
import 'package:flutter_run/src/dap/launch_rewriter.dart';
import 'package:flutter_run/src/dap/notices.dart';
import 'package:test/test.dart';

LaunchRewriter rewriter({
  DapKind kind = DapKind.flutter,
  Map<String, String> env = const {},
  String? saved,
}) => LaunchRewriter(
  kind: kind,
  cwd: '/proj',
  environment: env,
  savedDevice: () => saved,
);

void main() {
  group('LaunchRewriter own keys', () {
    test('ownKeys has the twelve documented keys', () {
      expect(LaunchRewriter.ownKeys, {
        'flutterSdkPath',
        'deviceId',
        'reloadOnSave',
        'reloadOnSaveGlobs',
        'reloadOnSaveDebounceMs',
        'openDevTools',
        'logFile',
        'useFvm',
        'adapter',
        'label',
        'flutterMode',
        'platform',
      });
    });

    for (final key in LaunchRewriter.ownKeys) {
      test('strips "$key" and returns it in ownConfig', () {
        final result = rewriter().rewrite('launch', {
          key: key == 'deviceId' ? 'dev1' : 'value',
          'program': 'lib/x.dart',
        });
        expect(result.arguments.containsKey(key), isFalse);
        expect(result.ownConfig[key], key == 'deviceId' ? 'dev1' : 'value');
      });
    }

    test('unknown and pass-through keys are untouched', () {
      final input = {
        'type': 'dart',
        'request': 'launch',
        'program': 'lib/main.dart',
        'cwd': '/elsewhere',
        'env': {'A': '1'},
        'args': ['--x'],
        'noDebug': true,
        'stopOnEntry': false,
        'vmServiceUri': 'http://127.0.0.1:1/x=/',
        'debugExternalPackageLibraries': true,
        'evaluateGettersInDebugViews': true,
        'sendLogsToClient': true,
        'somethingNew': {'a': 1},
      };
      final result = rewriter().rewrite('launch', input);
      expect(result.arguments, input);
      expect(result.deviceSource, DeviceSource.none);
      expect(result.ownConfig, isEmpty);
    });

    test('does not mutate the input', () {
      final input = <String, Object?>{
        'deviceId': 'a',
        'toolArgs': <Object?>['x'],
      };
      rewriter().rewrite('launch', input);
      expect(input['deviceId'], 'a');
      expect(input['toolArgs'], ['x']);
    });
  });

  group('toolArgs hardening (C10)', () {
    test('a non-list toolArgs is ignored with a note', () {
      final r = rewriter(saved: 's').rewrite('launch', {'toolArgs': '-d x'});
      expect(r.notes.single, contains('toolArgs must be a list'));
      expect(r.arguments['toolArgs'], ['-d', 's']);
      final r2 = rewriter().rewrite('launch', {'toolArgs': 5});
      expect(r2.arguments.containsKey('toolArgs'), isFalse);
      expect(r2.notes, isNotEmpty);
    });

    test('a device id in toolArgs is trimmed', () {
      final r = rewriter().rewrite('launch', {
        'toolArgs': ['-d', ' emu-1 '],
      });
      expect(r.deviceId, 'emu-1');
    });
  });

  group('S5 device id validation', () {
    LaunchRewriter strict({
      Map<String, String> env = const {},
      String? saved,
    }) => LaunchRewriter(
      kind: DapKind.flutter,
      cwd: '/proj',
      environment: env,
      savedDevice: () => saved,
      isSafeDeviceId: RegExp(r'^[A-Za-z0-9._:\-@]+$').hasMatch,
    );

    test('config, env and saved ids are validated', () {
      for (final r in [
        strict().rewrite('launch', {'deviceId': 'a b'}),
        strict(env: {'FLUTTER_RUN_DEVICE': 'a;b'}).rewrite('launch', {}),
        strict(saved: r'a$(x)').rewrite('launch', {}),
      ]) {
        expect(r.deviceId, isNull);
        expect(r.deviceSource, DeviceSource.none);
        expect(r.arguments.containsKey('toolArgs'), isFalse);
        expect(r.notes.single, contains('not allowed'));
      }
    });

    test('a safe id is injected', () {
      final r = strict().rewrite('launch', {'deviceId': 'emulator-5554'});
      expect(r.arguments['toolArgs'], ['-d', 'emulator-5554']);
    });
  });

  group('defaults', () {
    test('cwd and program are filled for flutter launch', () {
      final result = rewriter().rewrite('launch', {});
      expect(result.arguments['cwd'], '/proj');
      expect(result.arguments['program'], 'lib/main.dart');
    });

    test('program is not defaulted for attach or dart', () {
      expect(
        rewriter().rewrite('attach', {}).arguments.containsKey('program'),
        isFalse,
      );
      expect(
        rewriter(
          kind: DapKind.dart,
        ).rewrite('launch', {}).arguments.containsKey('program'),
        isFalse,
      );
      expect(
        rewriter(kind: DapKind.dart).rewrite('launch', {}).arguments['cwd'],
        '/proj',
      );
    });
  });

  group('device precedence', () {
    test('config > env > saved > none', () {
      final all = rewriter(env: {'FLUTTER_RUN_DEVICE': 'e'}, saved: 's');
      var r = all.rewrite('launch', {'deviceId': 'c'});
      expect(r.deviceId, 'c');
      expect(r.deviceSource, DeviceSource.config);
      expect(r.arguments['toolArgs'], ['-d', 'c']);

      r = all.rewrite('launch', {});
      expect(r.deviceId, 'e');
      expect(r.deviceSource, DeviceSource.env);

      r = rewriter(saved: 's').rewrite('launch', {});
      expect(r.deviceId, 's');
      expect(r.deviceSource, DeviceSource.saved);
      expect(r.arguments['toolArgs'], ['-d', 's']);

      r = rewriter().rewrite('launch', {});
      expect(r.deviceId, isNull);
      expect(r.deviceSource, DeviceSource.none);
      expect(r.arguments.containsKey('toolArgs'), isFalse);
    });

    test('the device is appended after existing toolArgs', () {
      final r = rewriter(saved: 's').rewrite('launch', {
        'toolArgs': ['--flavor', 'dev'],
      });
      expect(r.arguments['toolArgs'], ['--flavor', 'dev', '-d', 's']);
    });

    test('blank values are ignored', () {
      final r = rewriter(
        env: {'FLUTTER_RUN_DEVICE': ' '},
        saved: 's',
      ).rewrite('launch', {'deviceId': ''});
      expect(r.deviceSource, DeviceSource.saved);
    });

    test('savedDevice is not consulted when an earlier source wins', () {
      var calls = 0;
      final r = LaunchRewriter(
        kind: DapKind.flutter,
        cwd: '/p',
        environment: const {},
        savedDevice: () {
          calls++;
          return 's';
        },
      ).rewrite('launch', {'deviceId': 'c'});
      expect(r.deviceSource, DeviceSource.config);
      expect(calls, 0);
    });

    for (final args in [
      ['-d', 'x'],
      ['--device-id', 'x'],
      ['--device-id=x'],
      ['-dx'],
    ]) {
      test('toolArgs $args suppress injection', () {
        final r = rewriter(
          env: {'FLUTTER_RUN_DEVICE': 'e'},
          saved: 's',
        ).rewrite('launch', {'deviceId': 'c', 'toolArgs': args});
        expect(r.deviceSource, DeviceSource.toolArgs);
        expect(r.deviceId, 'x');
        expect(r.arguments['toolArgs'], args);
      });
    }

    test('--debug-url style flags do not count as a device', () {
      final r = rewriter(saved: 's').rewrite('launch', {
        'toolArgs': ['--dart-define=A=1'],
      });
      expect(r.deviceSource, DeviceSource.saved);
    });

    test('attach uses the same precedence, even with vmServiceUri (4.2a)', () {
      final env = {'FLUTTER_RUN_DEVICE': 'e'};
      var r = rewriter(
        env: env,
        saved: 's',
      ).rewrite('attach', {'vmServiceUri': 'http://127.0.0.1:1/x=/'});
      expect(r.deviceSource, DeviceSource.env);
      expect(r.arguments['toolArgs'], ['-d', 'e']);
      expect(r.arguments['vmServiceUri'], 'http://127.0.0.1:1/x=/');

      r = rewriter(env: env, saved: 's').rewrite('attach', {'deviceId': 'c'});
      expect(r.deviceSource, DeviceSource.config);

      r = rewriter(saved: 's').rewrite('attach', {});
      expect(r.deviceSource, DeviceSource.saved);

      r = rewriter().rewrite('attach', {});
      expect(r.deviceSource, DeviceSource.none);
    });

    test('kind dart never injects a device or a mode', () {
      final r = rewriter(
        kind: DapKind.dart,
        env: {'FLUTTER_RUN_DEVICE': 'e'},
        saved: 's',
      ).rewrite('launch', {'deviceId': 'c', 'flutterMode': 'release'});
      expect(r.deviceSource, DeviceSource.none);
      expect(r.deviceId, isNull);
      expect(r.arguments.containsKey('toolArgs'), isFalse);
      expect(r.ownConfig['deviceId'], 'c');
    });
  });

  group('flutterMode', () {
    test('profile and release append the flag', () {
      var r = rewriter().rewrite('launch', {'flutterMode': 'profile'});
      expect(r.arguments['toolArgs'], ['--profile']);
      r = rewriter().rewrite('launch', {
        'flutterMode': 'release',
        'toolArgs': ['--x'],
      });
      expect(r.arguments['toolArgs'], ['--x', '--release']);
    });

    test('debug adds nothing', () {
      final r = rewriter().rewrite('launch', {'flutterMode': 'debug'});
      expect(r.arguments.containsKey('toolArgs'), isFalse);
    });

    for (final flag in [
      '--debug',
      '--profile',
      '--release',
      '--debug-foo',
      '--profile-bar',
    ]) {
      test('toolArgs $flag wins and nothing is duplicated', () {
        final r = rewriter().rewrite('launch', {
          'flutterMode': 'release',
          'toolArgs': [flag],
        });
        expect(r.arguments['toolArgs'], [flag]);
        expect(r.notes, isNotEmpty);
      });
    }

    test('mode flag comes before the device flag', () {
      final r = rewriter(
        saved: 's',
      ).rewrite('launch', {'flutterMode': 'profile'});
      expect(r.arguments['toolArgs'], ['--profile', '-d', 's']);
    });

    test('an unknown value is ignored with a note', () {
      final r = rewriter().rewrite('launch', {'flutterMode': 'turbo'});
      expect(r.arguments.containsKey('toolArgs'), isFalse);
      expect(r.notes.single, contains('turbo'));
    });

    test('is not applied for attach', () {
      final r = rewriter().rewrite('attach', {'flutterMode': 'release'});
      expect(r.arguments.containsKey('toolArgs'), isFalse);
      expect(r.ownConfig['flutterMode'], 'release');
    });
  });

  group('deviceHintFor', () {
    test('several devices', () {
      for (final text in [
        'More than one device connected; please specify a device with the '
            "'-d <deviceId>' flag, or use '-d all' to act on all devices.",
        'more than one device connected',
      ]) {
        expect(deviceHintFor(text), contains('Flutter: Select Device'));
        expect(deviceHintFor(text), contains('deviceId'));
      }
    });

    test('no devices', () {
      for (final text in [
        'No supported devices connected.',
        'No devices found.',
        'Error: no connected devices',
      ]) {
        expect(deviceHintFor(text), startsWith('No devices found.'));
        expect(deviceHintFor(text), contains('Flutter: Launch Emulator'));
      }
    });

    test('non matches return null', () {
      expect(
        deviceHintFor('Launching lib/main.dart on Linux in debug mode'),
        isNull,
      );
      expect(deviceHintFor(''), isNull);
    });
  });

  group('formatNotice', () {
    test('info', () {
      expect(
        formatNotice('hello', NoticeLevel.info),
        '\x1b[36m[flutter_run] hello\x1b[0m\n',
      );
    });

    test('warn and error carry the words', () {
      expect(
        formatNotice('x', NoticeLevel.warn),
        '\x1b[33m[flutter_run] Warning: x\x1b[0m\n',
      );
      expect(
        formatNotice('x', NoticeLevel.error),
        '\x1b[31m[flutter_run] Error: x\x1b[0m\n',
      );
    });

    test('multi-line text prefixes each line and ends with one newline', () {
      final out = formatNotice('a\nb\n\n', NoticeLevel.info);
      expect(
        out,
        '\x1b[36m[flutter_run] a\x1b[0m\n\x1b[36m[flutter_run] b\x1b[0m\n',
      );
    });
  });
}
